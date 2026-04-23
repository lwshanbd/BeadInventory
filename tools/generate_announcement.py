#!/usr/bin/env python3
"""
公告 JSON 生成工具

用法:
    python3 generate_announcement.py --title "标题" --message "内容" --id "2024-01-15-update"

生成的 JSON 直接写到 docs/announcement.json 即可。
"""

import argparse
import json
import time


def main():
    parser = argparse.ArgumentParser(description="生成公告 JSON")
    parser.add_argument("--title", required=True, help="公告标题")
    parser.add_argument("--message", required=True, help="公告内容")
    parser.add_argument("--id", required=True, help="公告唯一标识 (如 2024-01-15-update)")
    parser.add_argument("--output", "-o", default=None, help="输出文件路径 (默认打印到终端)")
    args = parser.parse_args()

    announcement = {
        "v": 1,
        "id": args.id,
        "title": args.title,
        "message": args.message,
        "ts": int(time.time()),
    }

    json_str = json.dumps(announcement, ensure_ascii=False, indent=2)

    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(json_str + "\n")
        print(f"✅ 公告已写入: {args.output}")
    else:
        print(json_str)


if __name__ == "__main__":
    main()
