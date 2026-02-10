# Repository Guidelines

## Swift Challenge Branch Requirements
- This `challenge` branch is the Apple Swift Challenge submission branch.
- Be ambitious in product ideas and implementation: prefer advanced Apple platform capabilities on iOS/iPadOS when they improve the experience (for example SwiftUI animations, Vision, Core ML, App Intents, WidgetKit, PencilKit, Metal, RealityKit, and Share Extension workflows).
- Hard requirement: the app must run fully offline in the judging environment.
- Do not depend on runtime network calls, cloud sync, external APIs, external authentication, or server-side inference for core flows.
- Any feature that is online by default must provide an on-device/offline fallback before merge.

## Project Structure & Module Organization
- `BeadInventory/`: main iOS app target (SwiftUI + SwiftData).
- `BeadInventory/Views/`: UI screens by feature (`InventoryView`, `ScanView`, `PlannedProjectsView`, etc.).
- `BeadInventory/Managers/`: business logic and integrations (inventory, backup, OCR/AI, history).
- `BeadInventory/Models/`: domain models and SwiftData schema/migration code.
- `BeadInventory/Assets.xcassets/` and bundled data files (`allcolors.json`, `convert.csv`) hold app resources.
- `ShareExtension/`: share extension target for image import.
- `ci_scripts/`: Xcode Cloud build/version scripts.
- `tools/`: utility scripts (for example, signed announcement JSON generation).

## Build, Test, and Development Commands
```bash
open BeadInventory.xcodeproj
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory -destination 'platform=iOS Simulator,name=iPhone 16' build
xcodebuild -project BeadInventory.xcodeproj -scheme ShareExtension -destination 'platform=iOS Simulator,name=iPhone 16' build
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory -destination 'platform=iOS Simulator,name=iPhone 16' test
python3 tools/generate_announcement.py --title "Title" --message "Message" --id "2026-02-10-update"
```
- Use `open ...` for day-to-day development in Xcode.
- Use `xcodebuild` commands in CI or for reproducible local checks.
- A test command is defined, but there is currently no committed XCTest target.

## Coding Style & Naming Conventions
- Follow Swift conventions: 4-space indentation, `UpperCamelCase` for types, `lowerCamelCase` for properties/functions.
- Keep view files UI-focused; move stateful business rules into `Managers/`.
- For persistence changes, update SwiftData models and migration code together.
- Prefer localized user-facing text (`zh-Hans` and `en`) instead of hardcoded single-language strings.

## Testing Guidelines
- Minimum pre-PR validation: build both `BeadInventory` and `ShareExtension` schemes.
- Run manual smoke tests on key flows: inventory edits, scan/import, project execution, backup/restore.
- If you add automated tests, create an XCTest target and use file names like `InventoryManagerTests.swift`.

## Commit & Pull Request Guidelines
- Match existing commit style: Conventional Commit prefixes such as `fix:`, `feat:`, `perf:`, `docs:`, `refactor:`.
- Keep commit subjects short, imperative, and scoped to one change.
- PRs should include: summary, affected targets, test steps/results, and screenshots for UI changes.
- Call out SwiftData/CloudKit migration or sync risks explicitly, and link related issues.

## Security & Configuration Tips
- Never commit API keys or secrets.
- Configure AI provider keys inside app settings, not source files.
- Keep App Group and URL scheme settings aligned between app and extension (see `SHARE_EXTENSION_SETUP.md`).
