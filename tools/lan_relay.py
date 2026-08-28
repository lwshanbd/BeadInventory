#!/usr/bin/env python3
"""把一个只监听回环的端口暴露到局域网，让真机能连进来。

只在**用安卓模拟器联调**时需要：模拟器的网络是 NAT，外面进不去，得靠
`adb forward tcp:47820 tcp:47820` 把它的端口映射到 Mac 上 —— 但 adb 只绑
127.0.0.1，iPhone 真机在局域网上连不到。这个脚本补上最后一段。

    adb forward tcp:47820 tcp:47820
    tools/.venv/bin/python tools/lan_relay.py --listen 47821 --target 47820

然后 iPhone 填「Mac 的局域网 IP : 47821」。

真投影仪不需要它：那时安卓 App 直接监听在投影仪自己的局域网地址上。
"""

from __future__ import annotations

import argparse
import asyncio
import socket


def local_ipv4() -> str:
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("192.0.2.1", 9))
        return probe.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        probe.close()


async def pump(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        while chunk := await reader.read(65536):
            writer.write(chunk)
            await writer.drain()
    except (ConnectionResetError, BrokenPipeError):
        pass
    finally:
        writer.close()


async def main() -> None:
    parser = argparse.ArgumentParser(description="把回环端口转发到局域网")
    parser.add_argument("--listen", type=int, default=47821)
    parser.add_argument("--target", type=int, default=47820)
    parser.add_argument("--target-host", default="127.0.0.1")
    # 绑具体网卡地址，避免跟已经占着 127.0.0.1 同端口的 adb forward 打架
    parser.add_argument("--bind", default="0.0.0.0")
    args = parser.parse_args()

    async def handle(client_r: asyncio.StreamReader, client_w: asyncio.StreamWriter) -> None:
        peer = client_w.get_extra_info("peername")
        print(f"[中继] {peer} 接入")
        try:
            up_r, up_w = await asyncio.open_connection(args.target_host, args.target)
        except OSError as error:
            print(f"[中继] 连不上 {args.target_host}:{args.target} —— {error}")
            client_w.close()
            return
        # 两个方向各跑一条。return_exceptions 不能省：默认情况下一条抛异常，gather
        # 立刻抛出，另一条就没人等了 —— 连接半开着，两端谁都不知道该收摊。
        await asyncio.gather(pump(client_r, up_w), pump(up_r, client_w),
                             return_exceptions=True)
        print(f"[中继] {peer} 断开")

    server = await asyncio.start_server(handle, args.bind, args.listen)
    print(f"中继已启动：{local_ipv4()}:{args.listen}  ->  "
          f"{args.target_host}:{args.target}")
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
