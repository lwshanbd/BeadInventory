# Repository Guidelines

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

- Use XCTest (`BeadInventoryTests` / `BeadInventoryUITests`) when adding tests.
- Prefer fast, deterministic tests for `Managers/` logic; add UI tests only for critical flows (Scan, inventory adjustments).

## Commit & Pull Request Guidelines

- Commit messages follow Conventional Commits: `feat: ...`, `fix: ...`, `refactor: ...`, `perf: ...`, `chore: ...`, `style: ...` (Chinese or English is fine).
- PRs should include: what changed, why, screenshots for UI changes, and notes on localization/Share Extension impacts.

## Security & Configuration Tips

- Never commit API keys (OpenAI/Anthropic/Kimi/Qwen). Use app Settings locally and/or CI secrets where applicable.
- If changing Share Extension identifiers (App Group / URL Scheme), update both targets and keep `SHARE_EXTENSION_SETUP.md` accurate.
