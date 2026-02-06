#!/usr/bin/env python3
"""
公告签名生成工具

用法:
    python3 generate_announcement.py --title "标题" --message "内容" --id "2024-01-15-update"
    python3 generate_announcement.py --title "标题" --message "内容" --id "2024-01-15-update" --key "YOUR_SECRET_KEY"

生成的 JSON 直接上传到你的公告 URL 即可。
"""

import argparse
import hashlib
import hmac
import json
import time
import sys


def generate_signature(v: int, id: str, title: str, message: str, ts: int, key: str) -> str:
    """生成 HMAC-SHA256 签名"""
    payload = f"{v}|{id}|{title}|{message}|{ts}"
    mac = hmac.new(key.encode("utf-8"), payload.encode("utf-8"), hashlib.sha256)
    return mac.hexdigest()


def main():
    parser = argparse.ArgumentParser(description="生成带签名的公告 JSON")
    parser.add_argument("--title", required=True, help="公告标题")
    parser.add_argument("--message", required=True, help="公告内容")
    parser.add_argument("--id", required=True, help="公告唯一标识 (如 2024-01-15-update)")
    parser.add_argument("--key", default="REPLACE_WITH_YOUR_SECRET_KEY_HERE", help="HMAC 密钥 (需与 App 中一致)")
    parser.add_argument("--output", "-o", default=None, help="输出文件路径 (默认打印到终端)")
    args = parser.parse_args()

    if args.key == "REPLACE_WITH_YOUR_SECRET_KEY_HERE":
        print("⚠️  警告: 你正在使用默认密钥，请务必替换为你自己的密钥！", file=sys.stderr)
        print("   使用 --key 参数指定，或修改 AnnouncementManager.swift 中的 hmacKey\n", file=sys.stderr)

    ts = int(time.time())
    sig = generate_signature(1, args.id, args.title, args.message, ts, args.key)

    announcement = {
        "v": 1,
        "id": args.id,
        "title": args.title,
        "message": args.message,
        "ts": ts,
        "sig": sig,
    }

    json_str = json.dumps(announcement, ensure_ascii=False, indent=2)

    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(json_str + "\n")
        print(f"✅ 公告已写入: {args.output}")
    else:
        print(json_str)

    print(f"\n📋 公告信息:", file=sys.stderr)
    print(f"   ID:    {args.id}", file=sys.stderr)
    print(f"   标题:  {args.title}", file=sys.stderr)
    print(f"   时间戳: {ts}", file=sys.stderr)
    print(f"   签名:  {sig[:16]}...", file=sys.stderr)


if __name__ == "__main__":
    main()
