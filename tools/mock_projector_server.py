#!/usr/bin/env python3
"""模拟安卓投影接收端，用来在没有安卓设备时联调 iOS 的投影模式。

它按 BeadInventory-Projection/PROTOCOL.md 实现服务端一侧：握手、AES-GCM 加密通道、
控制消息、位图帧。跟真机的区别只有一个 —— 它不画画面，而是把 iPhone 推来的每一帧
**存成 PNG 文件**，这样在 Mac 上就能直接看 iOS 端渲染出来的投影画面对不对。

用法：

    tools/.venv/bin/python tools/mock_projector_server.py

启动后打印配对信息（二维码 URI、6 位短码、IP 端口）。iOS 模拟器没有摄像头扫不了码，
所以调试一律走手输路径：在 App 里填 IP、端口和 6 位短码。

启动后还会在 8080 端口开一个预览页（http://localhost:8080）。用浏览器全屏打开它，
那就是「投影仪屏幕」—— iPhone 推来的画面会实时显示在上面。

跑起来之后可以敲这些命令模拟遥控器：

    corner <tl|tr|br|bl>    切换当前角，发 active
    move <dx> <dy>          当前角移动多少像素，发 quad
    exit                    模拟按返回键，发 exit
    resize <w> <h>          改显示尺寸，发 resize
    state                   打印当前状态
    quit
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import json
import os
import socket
import struct
import sys
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import quote

import websockets
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from websockets.asyncio.server import serve

PROTOCOL_INFO = b"beadprojector-v1"
CORNER_ORDER = ["tl", "tr", "br", "bl"]


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def b64url_decode(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * ((4 - len(text) % 4) % 4))


def local_ipv4() -> str:
    """取一个能被局域网里其它设备连到的地址；拿不到就退回回环。"""
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("192.0.2.1", 9))  # TEST-NET-1，不会真的发包
        return probe.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        probe.close()


class Session:
    """一条已经握手完成的加密连接。"""

    def __init__(self, websocket: Any, key: bytes) -> None:
        self.websocket = websocket
        self.aes = AESGCM(key)
        self.send_prefix = os.urandom(4)
        self.send_counter = 0
        self.receive_prefix: bytes | None = None
        self.receive_counter = -1

    async def send_control(self, message: dict[str, Any]) -> None:
        plaintext = json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode()
        nonce = self.send_prefix + struct.pack(">Q", self.send_counter)
        self.send_counter += 1
        packet = bytes([0x01]) + nonce + self.aes.encrypt(nonce, plaintext, bytes([0x01]))
        await self.websocket.send(packet)

    def decrypt(self, packet: bytes) -> tuple[int, bytes]:
        if len(packet) < 1 + 12 + 16:
            raise ValueError("加密包过短")
        message_type = packet[0]
        if message_type not in (0x01, 0x02):
            raise ValueError(f"未知消息类型 0x{message_type:02x}")
        nonce = packet[1:13]
        prefix, counter = nonce[:4], struct.unpack(">Q", nonce[4:])[0]
        if self.receive_prefix is None:
            self.receive_prefix = prefix
        elif prefix != self.receive_prefix:
            raise ValueError("会话内 nonce 前缀发生变化")
        if counter <= self.receive_counter:
            raise ValueError("nonce 计数器重复或倒退")
        plaintext = self.aes.decrypt(nonce, packet[13:], bytes([message_type]))
        self.receive_counter = counter
        return message_type, plaintext


class MockProjector:
    def __init__(self, args: argparse.Namespace) -> None:
        self.width = args.width
        self.height = args.height
        self.out_dir = Path(args.out)
        self.out_dir.mkdir(parents=True, exist_ok=True)
        self.pairing_secret = os.urandom(32)
        self.short_code = f"{int.from_bytes(os.urandom(4), 'big') % 1_000_000:06d}"
        self.device_id = str(uuid.uuid4())
        self.device_name = args.device_name

        self.session: Session | None = None
        self.loop: asyncio.AbstractEventLoop | None = None
        # 校准状态：iPhone 发 calib 时写进来，遥控器命令在它上面改
        self.quad: list[float] | None = None
        self.active = "tl"
        self.cols = 0
        self.rows = 0
        self.mode = "(未收到)"
        self.frame_count = 0
        self.last_seq = -1
        self.latest_png: bytes | None = None
        self.latest_caption = ""
        self.revision = 0

    # ---------- 配对信息 ----------

    def pairing_uri(self, ip: str, port: int) -> str:
        return (
            f"beadprojector://{ip}:{port}/?s={b64url(self.pairing_secret)}"
            f"&c={self.short_code}&d={self.device_id}&n={quote(self.device_name)}"
        )

    def print_pairing(self, ip: str, port: int) -> None:
        print("=" * 70)
        print(f"  模拟投影端已启动    {self.width}×{self.height}")
        print(f"  地址        {ip}:{port}     （iOS 模拟器请填 127.0.0.1）")
        print(f"  6 位短码    {self.short_code}")
        print(f"  完整密钥    {b64url(self.pairing_secret)}")
        print(f"  二维码 URI  {self.pairing_uri(ip, port)}")
        print(f"  收到的画面会存到 {self.out_dir}/")
        print("=" * 70)

    # ---------- 握手 ----------

    async def handle(self, websocket: Any) -> None:
        peer = websocket.remote_address
        print(f"\n[连接] {peer}")
        try:
            hello_raw = await websocket.recv()
            if not isinstance(hello_raw, str):
                await websocket.send(json.dumps({"t": "denied"}))
                print("[拒绝] hello 不是文本帧")
                return
            hello = json.loads(hello_raw)
            if hello.get("t") != "hello" or hello.get("proto") != 1:
                await websocket.send(json.dumps({"t": "denied"}))
                print(f"[拒绝] hello 格式不对：{hello_raw[:120]}")
                return

            credential = hello.get("cred", "")
            if credential == b64url(self.pairing_secret):
                ikm, path = self.pairing_secret, "密钥"
            elif credential == self.short_code:
                ikm, path = self.short_code.encode(), "短码"
            else:
                await websocket.send(json.dumps({"t": "denied"}))
                print(f"[拒绝] 凭据不匹配：{credential!r}")
                return

            salt = b64url_decode(hello["salt"])
            if len(salt) != 16:
                await websocket.send(json.dumps({"t": "denied"}))
                print(f"[拒绝] salt 长度 {len(salt)}，应为 16")
                return

            key = HKDF(
                algorithm=hashes.SHA256(), length=32, salt=salt, info=PROTOCOL_INFO
            ).derive(ikm)
            await websocket.send(
                json.dumps(
                    {
                        "t": "welcome",
                        "proto": 1,
                        "w": self.width,
                        "h": self.height,
                        "device": self.device_name,
                        "ver": "mock-1.0",
                    },
                    ensure_ascii=False,
                )
            )
            self.session = Session(websocket, key)
            print(f"[握手成功] 走{path}路径，客户端 = {hello.get('device', '?')}")

            async for raw in websocket:
                if isinstance(raw, str):
                    print(f"[错误] 握手后收到文本帧，真机会直接断开：{raw[:120]}")
                    return
                self.on_packet(raw)
        except websockets.ConnectionClosed:
            pass
        except Exception as error:  # noqa: BLE001 - 调试工具，任何异常都要看得见
            print(f"[异常] {type(error).__name__}: {error}")
        finally:
            self.session = None
            print(f"[断开] {peer}")

    # ---------- 收消息 ----------

    def on_packet(self, packet: bytes) -> None:
        assert self.session is not None
        message_type, plaintext = self.session.decrypt(packet)
        if message_type == 0x01:
            self.on_control(json.loads(plaintext.decode()))
        else:
            self.on_bitmap(plaintext)

    def on_control(self, message: dict[str, Any]) -> None:
        kind = message.get("t")
        if kind == "ping":
            asyncio.create_task(self.session.send_control({"t": "pong", "id": message.get("id")}))
            return
        if kind == "mode":
            self.mode = message.get("m", "?")
            print(f"[mode] {self.mode}")
        elif kind == "calib":
            self.quad = [float(v) for v in message["q"]]
            self.active = message.get("c", self.active)
            self.cols = int(message.get("cols", 0))
            self.rows = int(message.get("rows", 0))
            paint = message.get("paint", {})
            print(
                f"[calib] {self.cols}×{self.rows} 当前角={self.active} "
                f"paint={paint.get('style')}/{paint.get('hex')}"
            )
            print(f"        quad={self.format_quad()}")
        elif kind == "caption":
            self.latest_caption = message.get("text", "")
            print(f"[caption] {self.latest_caption!r}")
        else:
            print(f"[控制] {message}")

    def on_bitmap(self, plaintext: bytes) -> None:
        if len(plaintext) < 9:
            print("[位图] 帧过短，丢弃")
            return
        seq, width, height, fmt = struct.unpack(">IHHB", plaintext[:9])
        image = plaintext[9:]
        if fmt != 1:
            print(f"[位图] format={fmt} 非 PNG，真机会丢弃")
            return
        if image[:4] != b"\x89PNG":
            print("[位图] 声明 PNG 但签名不对，真机会丢弃")
            return
        if seq <= self.last_seq:
            print(f"[位图] seq={seq} 不大于已显示的 {self.last_seq}，真机会丢弃")
            return
        self.last_seq = seq
        self.frame_count += 1
        self.latest_png = image
        self.revision += 1
        path = self.out_dir / f"frame-{self.frame_count:03d}-seq{seq}.png"
        path.write_bytes(image)
        note = "" if (width, height) == (self.width, self.height) else "  ← 尺寸与屏幕不一致，真机会最近邻缩放"
        print(f"[位图] seq={seq} {width}×{height} {len(image) / 1024:.1f} KB → {path.name}{note}")

    # ---------- 模拟遥控器 ----------

    def format_quad(self) -> str:
        if not self.quad:
            return "(未设置)"
        pairs = [f"({self.quad[i]:.5f},{self.quad[i + 1]:.5f})" for i in range(0, 8, 2)]
        return " ".join(pairs)

    def send_soon(self, message: dict[str, Any]) -> None:
        if self.session is None or self.loop is None:
            print("！还没有客户端连上")
            return
        asyncio.run_coroutine_threadsafe(self.session.send_control(message), self.loop)

    def command_loop(self) -> None:
        for line in sys.stdin:
            parts = line.split()
            if not parts:
                continue
            command, rest = parts[0], parts[1:]
            if command in ("quit", "exit") and command == "quit":
                os._exit(0)
            elif command == "corner" and rest and rest[0] in CORNER_ORDER:
                self.active = rest[0]
                self.send_soon({"t": "active", "c": self.active})
                print(f"→ active {self.active}")
            elif command == "next":
                self.active = CORNER_ORDER[(CORNER_ORDER.index(self.active) + 1) % 4]
                self.send_soon({"t": "active", "c": self.active})
                print(f"→ active {self.active}")
            elif command == "move" and len(rest) == 2:
                if not self.quad:
                    print("！还没收到 calib，不知道四个角在哪儿")
                    continue
                index = CORNER_ORDER.index(self.active) * 2
                self.quad[index] += float(rest[0]) / self.width
                self.quad[index + 1] += float(rest[1]) / self.width
                self.send_soon({"t": "quad", "q": self.quad})
                print(f"→ quad {self.format_quad()}")
            elif command == "exit":
                self.send_soon({"t": "exit"})
                print("→ exit")
            elif command == "resize" and len(rest) == 2:
                self.width, self.height = int(rest[0]), int(rest[1])
                self.send_soon({"t": "resize", "w": self.width, "h": self.height})
                print(f"→ resize {self.width}×{self.height}")
            elif command == "state":
                print(
                    f"mode={self.mode} 已收 {self.frame_count} 帧 seq={self.last_seq} "
                    f"板={self.cols}×{self.rows} 当前角={self.active}\nquad={self.format_quad()}"
                )
            else:
                print("命令：corner <tl|tr|br|bl> / next / move <dx> <dy> / exit / resize <w> <h> / state / quit")


# ---------- 预览页：把收到的画面显示出来 ----------

PREVIEW_HTML = """<!doctype html>
<meta charset="utf-8"><title>模拟投影仪</title>
<style>
  html,body{margin:0;height:100%;background:#000;overflow:hidden}
  #wrap{height:100%;display:flex;align-items:center;justify-content:center}
  img{max-width:100%;max-height:100%;image-rendering:pixelated}
  #empty{color:#555;font:16px -apple-system,sans-serif}
</style>
<div id="wrap"><div id="empty">等待 iPhone 推送画面</div></div>
<script>
let seen = -1;
async function tick(){
  try{
    const r = await fetch('/rev');
    const {rev} = await r.json();
    if (rev !== seen && rev > 0){
      seen = rev;
      const img = new Image();
      img.onload = () => { document.getElementById('wrap').replaceChildren(img); };
      img.src = '/frame.png?r=' + rev;
    }
  }catch(e){}
  setTimeout(tick, 300);
}
tick();
</script>
"""


class PreviewHandler(BaseHTTPRequestHandler):
    projector: "MockProjector"

    def do_GET(self) -> None:
        if self.path.startswith("/rev"):
            self._send(200, "application/json",
                       json.dumps({"rev": self.projector.revision}).encode())
        elif self.path.startswith("/frame.png"):
            png = self.projector.latest_png
            if png is None:
                self._send(404, "text/plain", b"no frame")
            else:
                self._send(200, "image/png", png)
        else:
            self._send(200, "text/html; charset=utf-8", PREVIEW_HTML.encode())

    def _send(self, code: int, ctype: str, body: bytes) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args: Any) -> None:
        pass    # 每 300ms 一次轮询，打出来会把协议日志淹掉


def start_preview(projector: "MockProjector", port: int) -> None:
    PreviewHandler.projector = projector
    server = ThreadingHTTPServer(("0.0.0.0", port), PreviewHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()


async def main() -> None:
    parser = argparse.ArgumentParser(description="模拟安卓投影接收端")
    parser.add_argument("--port", type=int, default=47820)
    parser.add_argument("--width", type=int, default=1920)
    parser.add_argument("--height", type=int, default=1080)
    parser.add_argument("--device-name", default="模拟投影仪")
    parser.add_argument("--out", default="/tmp/bead-projector-frames")
    parser.add_argument("--preview-port", type=int, default=8080)
    args = parser.parse_args()

    projector = MockProjector(args)
    projector.loop = asyncio.get_running_loop()
    projector.print_pairing(local_ipv4(), args.port)

    start_preview(projector, args.preview_port)
    print(f"  预览页      http://localhost:{args.preview_port}  （浏览器全屏打开当投影仪屏幕）")
    print("=" * 70)

    threading.Thread(target=projector.command_loop, daemon=True).start()
    async with serve(projector.handle, "0.0.0.0", args.port, max_size=32 * 1024 * 1024):
        await asyncio.Future()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
