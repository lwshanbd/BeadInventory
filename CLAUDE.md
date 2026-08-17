# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 第一原则：我们在做一个给人用的 App

BeadInventory 是一个真人每天拿在手上用的 iOS GUI App，不是一个库、不是一个跑分项目。**本文件里其它所有规则，都服从这一条。**

任何改动、任何测试、任何"验证通过"的结论，判定基准只有一个：
> **用户在 App 里能不能更顺、更少困惑、更少返工地把事情做完。**

### 怎么验证一个改动"做好了"

按这个优先级来，能用高优先级的就不要退回低优先级：

1. **在模拟器里真的走一遍用户路径**（iPhone 17 Pro Max），并截图。改了扫描就从选图 → 裁剪 → 识别 → 确认 → 扣库存整条走完；改了库存页就真的滚动、筛选、改数量。
2. **看 UI 本身**：文字有没有截断、深浅色模式、动态字体、空状态、错误态、长列表滚动是否卡。这些用户一眼能感知，单元测试永远测不出来。
3. **单元测试只用于确实会静默出错的纯逻辑**——色号/跨品牌换算、库存加减、撤销回滚、数据迁移。这类地方错了用户看不见，才值得写测试。
4. 拿不准 UI 效果好不好时，截图给用户看，让用户判断；不要自己拍脑袋定"这样更好"。

现有的 `BeadInventoryTests` 照常跑、不要删；这里说的是**不要再新增没人受益的测试**。

### 明确禁止

- **不要为了"有测试"而堆测试。** 不写只是把实现照抄一遍的测试，不追求覆盖率，不把覆盖率写进 PR 描述或验收标准。
- **不要用一堆冷冰冰的数字当交付。** 覆盖率 %、识别准确率 %、耗时毫秒数、内存占用百分比——这些本身不是目标。用户感受不到的指标改善，等于没改善。
  - 反面教材：`phys_footprint` 在模拟器上根本不准，基于它写的"内存优化 X%"结论全是假的。
- **不要用指标代替体验判断。** "准确率从 82% 提到 85%" 不是成果；"识别错了用户两下就能改回来" 才是。
- **不要因为某个指标好看就宣布完成。** 完成 = 用户路径在真机/模拟器里跑通且看着对。

### 什么样的数字才值得提

只有能翻译成一句用户视角的话时才提，并且要那样写出来：

- ✅ "冷启动白屏 3 秒 → 不到 1 秒，打开就能看到库存"
- ✅ "扫 200 颗的图不再卡死被系统杀掉"
- ❌ "内存占用下降 12%"
- ❌ "新增 14 个测试用例，覆盖率 76%"

### 功能与 AI 识别的取向

AI 识别一定会错。设计目标不是把准确率数字堆高，而是**让识别错了也不难受**：

- 结果必须可编辑、可撤销、可重来；
- 不确定的地方要让用户看得见（而不是默默猜一个数写进库存）；
- 宁可多问一句让用户确认，也不要静默改掉用户的库存数据。

同理，任何新功能先回答："用户在哪一步会用到它？少点几下了吗？还是又多了一个要理解的东西？"答不上来就先别做。

### 汇报方式

说清楚用户能看到的变化 + 截图。不要堆数字表格，不要用测试数量证明工作量。做了什么、用户那边变成什么样，讲清楚就够了。

## Build & Run

**模拟器目标：永远使用 `iPhone 17 Pro Max`（最新版本），不要用其它型号（如 iPhone 16）。**
- 命令行 `xcodebuild` 的 `-destination` 必须写 `name=iPhone 17 Pro Max`。
- 通过 `ios-simulator-skill` 等工具启动/截图时，也指定 iPhone 17 Pro Max。
- 用户已经把它作为日常调试机型，切换会破坏现有 booted 实例和 UI 调优。

```bash
# Open project in Xcode
open BeadInventory.xcodeproj

# Build from command line
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build

# Run tests (if any)
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test
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
