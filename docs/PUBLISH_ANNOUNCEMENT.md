# 发布 App 内公告

App 启动时会静默拉取 `https://lwshanbd.github.io/BeadInventory/announcement.json`，通过 HMAC-SHA256 签名校验后弹窗展示。本文档说明如何发布一条新公告。

## 前置条件

- 本地保存的 HMAC 密钥（**不在仓库中**，保密）
- 密钥必须与 `BeadInventory/Managers/AnnouncementManager.swift` 中 `hmacKey` 常量完全一致

## 发布流程

1. 在仓库根目录运行脚本生成签名 JSON：

   ```bash
   python3 tools/generate_announcement.py \
     --id "2026-05-01-v1.9" \
     --title "v1.9 已发布" \
     --message "新增了批量导入、修复了若干 bug。请到 App Store 更新。" \
     --key "你的密钥" \
     --output docs/announcement.json
   ```

2. 校验 JSON：

   ```bash
   cat docs/announcement.json
   ```

3. 提交并推送：

   ```bash
   git add docs/announcement.json
   git commit -m "docs: 发布公告 2026-05-01-v1.9"
   git push
   ```

4. 等待 GitHub Pages 构建完成（通常 1–2 分钟），访问 URL 确认：

   ```
   https://lwshanbd.github.io/BeadInventory/announcement.json
   ```

## 重要约束

- **`id` 字段必须每次不同**。App 会记录已展示过的公告 id，重复 id 不会再弹窗。推荐格式：`YYYY-MM-DD-描述`。
- **时间戳（`ts`）必须在 90 天内**。脚本会自动填当前时间戳，但如果公告写好了很久没发，需要重新跑脚本刷新签名。
- **签名与内容强绑定**。任何字段（`title`/`message` 等）手动改动后必须重新生成签名，否则 App 会静默丢弃。
- **密钥泄露怎么办**：在 `AnnouncementManager.swift` 中换一个新密钥，发布新版 App。旧版 App 会继续用旧密钥，但老密钥一旦泄露理论上仍可用来攻击未升级的用户。
