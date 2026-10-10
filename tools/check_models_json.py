#!/usr/bin/env python3
"""发布 docs/models.json 前跑一遍：格式、provider 名字、default 是否在列表里。
同时列出相对 origin/main 删掉了哪些模型，提醒「选着它们的用户会被换到默认模型」。"""
import json
import subprocess
import sys

PATH = "docs/models.json"
PROVIDERS = {"Kimi", "OpenAI", "Anthropic", "Qwen", "Gemini"}

catalog = json.load(open(PATH))
errors = []
if catalog.get("v") != 1:
    errors.append("v 必须是 1")
for name, entry in catalog.get("providers", {}).items():
    if name not in PROVIDERS:
        errors.append(f"不认识的 provider：{name}（大小写要跟 App 一致：{sorted(PROVIDERS)}）")
    models, default = entry.get("models"), entry.get("default")
    if not isinstance(models, list) or not models or not all(isinstance(m, str) and m.strip() for m in models):
        errors.append(f"{name}：models 必须是非空的字符串列表")
    elif default not in models:
        errors.append(f"{name}：default「{default}」不在 models 里")

try:
    old = json.loads(subprocess.run(["git", "show", f"origin/main:{PATH}"], capture_output=True, check=True, text=True).stdout)
    for name, entry in old.get("providers", {}).items():
        removed = set(entry["models"]) - set(catalog.get("providers", {}).get(name, {}).get("models", entry["models"]))
        if removed:
            print(f"{name} 删掉了：{', '.join(sorted(removed))}")
except (subprocess.CalledProcessError, json.JSONDecodeError):
    pass

for e in errors:
    print("错误：" + e)
sys.exit(1 if errors else 0)
