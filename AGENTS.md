# Repository Guidelines

## 第一原则：我们在做一个给人用的 App

BeadInventory 是真人每天使用的 iOS GUI App。所有改动与验证的判定基准只有一个：**用户在 App 里能不能更顺、更少困惑地把事情做完**，而不是任何指标数字。

完整说明见 [CLAUDE.md「第一原则」](CLAUDE.md)，要点：

- 验证优先级：模拟器里真走一遍用户路径并截图 > 看 UI 本身（截断/深色模式/空态/错误态/滚动）> 只对易静默出错的纯逻辑写单元测试。
- 不为"有测试"而堆测试，不追覆盖率，不把覆盖率/准确率/耗时百分比当验收标准或成果。
- 指标只有能翻译成用户视角的一句话时才值得提（"打开就能看到库存" ✅ / "内存下降 12%" ❌）。
- AI 识别一定会错：目标是让错了也好改（可编辑、可撤销、不确定处可见），而不是刷准确率。

## Project Structure & Module Organization

- `BeadInventory/`: main iOS app (SwiftUI + SwiftData)
  - `Managers/`: business logic (inventory, AI providers, history/undo)
  - `Models/`: domain models + SwiftData conversion/persistence types
  - `Views/`: SwiftUI screens (tabs and detail views)
  - `Assets.xcassets/`: images, colors, app icons
  - `zh-Hans.lproj/`, `en.lproj/`: localized resources (keep both updated)
- `ShareExtension/`: share extension target (sharing images into the Scan flow). Setup notes: `SHARE_EXTENSION_SETUP.md`.
- `BeadInventory.xcodeproj/`: Xcode project/workspace configuration.
- `ci_scripts/`: CI helpers (Xcode Cloud) that update build/version metadata.
- Docs/assets: `README.md`, images in repo root.

## Build, Test, and Development Commands

- 模拟器目标：永远用 `iPhone 17 Pro Max`（详见 CLAUDE.md「Build & Run」）。
- Open in Xcode: `open BeadInventory.xcodeproj`
- Build (CLI): `xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build`
- Test (if/when test targets exist): `xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test`

Requirements: iOS 17.0+, Xcode 15.0+.

## Coding Style & Naming Conventions

- Swift: 4-space indentation; prefer SwiftUI composition over deep view hierarchies.
- Naming: `PascalCase` for types/files (e.g., `InventoryManager.swift`), `lowerCamelCase` for vars/functions.
- Localization: avoid hard-coded user-facing strings; update both `BeadInventory/zh-Hans.lproj/` and `BeadInventory/en.lproj/` when adding UI text.
- State/history: inventory-changing actions should be recorded via `HistoryManager` before mutating persisted state.

## Testing Guidelines

首要判据见上文「第一原则」——测试是为了保护用户体验，不是为了产出数字。

- 默认验证方式是**在模拟器里跑一遍对应的用户路径并截图**，不是加一个测试用例。
- 只在"错了用户看不见"的纯逻辑上写 XCTest（`BeadInventoryTests`）：色号/跨品牌换算、库存加减、撤销回滚、数据迁移。
- UI 测试仅用于关键主流程（Scan、库存增减），且必须是稳定的；易抖动的 UI 测试不如一张截图。
- 现有测试照常跑、不要删；但不要新增只是把实现照抄一遍的测试，也不要在 PR 里汇报覆盖率。
- 已知噪声：多 worktree 并发跑 test 会争用同一台模拟器导致 "signal kill"，那是环境问题不是代码问题。

## Commit & Pull Request Guidelines

- Commit messages follow Conventional Commits: `feat: ...`, `fix: ...`, `refactor: ...`, `perf: ...`, `chore: ...`, `style: ...` (Chinese or English is fine).
- PRs should include: what changed, why, screenshots for UI changes, and notes on localization/Share Extension impacts.

## Security & Configuration Tips

- Never commit API keys (OpenAI/Anthropic/Kimi/Qwen). Use app Settings locally and/or CI secrets where applicable.
- If changing Share Extension identifiers (App Group / URL Scheme), update both targets and keep `SHARE_EXTENSION_SETUP.md` accurate.
