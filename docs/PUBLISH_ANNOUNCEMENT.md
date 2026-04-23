# 发布 App 内公告

App 启动时会静默拉取 `https://lwshanbd.github.io/BeadInventory/announcement.json`，通过格式校验后弹窗展示。本文档说明如何发布一条新公告。

## 发布流程

1. 在仓库根目录运行脚本生成 JSON：

   ```bash
   python3 tools/generate_announcement.py \
     --id "2026-05-01-v1.9" \
     --title "v1.9 已发布" \
     --message "新增了批量导入、修复了若干 bug。请到 App Store 更新。" \
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
- **时间戳（`ts`）必须在 `[now - 90 天, now + 1 小时]` 之间**。脚本会自动填当前时间戳，但如果公告写好了很久没发，需要重新跑脚本刷新。上界是为了容忍客户端时钟小偏差。

## 关于安全

当前实现**不做签名校验**。App 无条件信任从 GitHub Pages 拉到的 JSON。理由：

- 该仓库公开，任何签名密钥都无法真正保密
- iOS 强制 HTTPS 传输，已挡住绝大多数中间人攻击
- 公告 UI 只展示纯文本 + 一个"我知道了"按钮，没有可点击链接，攻击面非常有限
- 对一个非关键的公告系统，简单可靠胜过无效的复杂

如果未来 App 用途发生变化（例如处理支付、医疗数据等），重新评估是否需要引入签名机制。
