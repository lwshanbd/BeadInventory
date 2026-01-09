# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
# Open project in Xcode
open BeadInventory.xcodeproj

# Build from command line
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory -destination 'platform=iOS Simulator,name=iPhone 16' build

# Run tests (if any)
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory -destination 'platform=iOS Simulator,name=iPhone 16' test
```

Requirements: iOS 17.0+, Xcode 15.0+

## Architecture

BeadInventory is a SwiftUI + SwiftData iOS app for managing perler bead (拼豆) inventory with AI-powered image recognition.

### Core Data Flow

```
SwiftUI Views (@EnvironmentObject)
         │
         ▼
   InventoryManager (ObservableObject)
   - brands, brandStocks, projects, beadColors
         │
    ┌────┼────┐
    ▼    ▼    ▼
SwiftData  HistoryManager  AIServiceManager
(persistence) (undo/redo)  (OpenAI/Anthropic/Kimi)
```

### Key Components

**Managers/** - Business logic layer
- `InventoryManager.swift`: Central state management for brands, stock, projects. All inventory operations flow through here.
- `AIService.swift`: Multi-provider AI integration (Kimi built-in, OpenAI, Anthropic). Handles image recognition for bead counting.
- `HistoryManager.swift`: Singleton tracking all operations with JSON snapshots for undo support.

**Models/** - Dual model pattern
- Struct models (`BeadColor`, `Brand`, `BrandStock`, `ProjectRecord`): In-memory, Codable
- SwiftData models (`SDBrand`, `SDBrandStock`, `SDProjectRecord`): Persistent, with bi-directional conversion methods

**Views/** - 5 main tabs
- `InventoryView`: Stock display with per-brand filtering, sorting, low-stock highlighting
- `ScanView`: Image → crop → AI recognition → confirmation → deduct/plan
- `PlannedProjectsView`: Project planning with merge/archive
- `StatisticsView`: Usage analytics and project history
- `MoreView`: Settings, History, About navigation hub

### Data Files
- `color.json`: MARD color codes → hex mappings
- `convert.csv`: Cross-brand color code conversion table

## Git 操作规则

**重要：未经用户明确允许，禁止执行 `git push`！**

- 可以自由执行 `git commit`
- 执行 `git push` 前必须征得用户同意
- 用户说 "push" 或 "推送" 时才可以推送

## Code Conventions

- All user-facing strings use localization (zh-Hans primary, English secondary)
- History operations must call `HistoryManager.shared.addRecord()` before modifying state
- Stock operations are keyed by brand ID - always specify which brand when modifying inventory
- SwiftData models have `.toStruct()` and `init(from:)` for conversion
