# 发布 App 内公告

App 启动时会静默拉取 `https://lwshanbd.github.io/BeadInventory/announcement.json`，通过 HMAC-SHA256 签名校验后弹窗展示。本文档说明如何发布一条新公告。

## 前置条件

- 本地保存的 HMAC 密钥（用于运行下方的签名脚本）
- 密钥必须与 `BeadInventory/Managers/AnnouncementManager.swift` 中 `hmacKey` 常量完全一致

> ⚠️ 当前密钥**已硬编码在 App 二进制中并随仓库提交**。这是有意为之的设计权衡：足以阻止"替换 GitHub Pages 内容"这类 URL 劫持，但**无法**阻止逆向 App 提取密钥后伪造公告。如果密钥疑似泄露，需要在 `AnnouncementManager.swift` 换新密钥并发布新版 App。

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

2. 提交并推送：

   ```bash
   git add docs/announcement.json
   git commit -m "docs: 发布公告 2026-05-01-v1.9"
   git push
   ```

3. 等待 GitHub Pages 构建完成（通常 1–2 分钟），访问 URL 确认：

   ```
   https://lwshanbd.github.io/BeadInventory/announcement.json
   ```

## 重要约束

- **`id` 字段必须每次不同**。App 会记录已展示过的公告 id，重复 id 不会再弹窗。推荐格式：`YYYY-MM-DD-描述`。
- **时间戳（`ts`）必须在 `[now - 90 天, now + 1 小时]` 之间**。脚本会自动填当前时间戳，但如果公告写好了很久没发，需要重新跑脚本刷新签名。上界设置是为了容忍客户端时钟小偏差，避免"未来时间戳"被用来延长有效期。
- **签名与内容强绑定**。任何字段（`title`/`message` 等）手动改动后必须重新生成签名，否则 App 会静默丢弃。
- **密钥泄露怎么办**：在 `AnnouncementManager.swift` 中换一个新密钥，发布新版 App。旧版 App 会继续用旧密钥，但老密钥一旦泄露理论上仍可用来攻击未升级的用户。
