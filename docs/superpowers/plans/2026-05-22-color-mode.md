# 色彩模式（Color Mode）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 允许用户自定义浅色 / 深色模式下的两层 Surface 基础色（Bg + BgElev），提供 5 个内建预设、自由调色板，并把"我的主题"经由 SwiftData/CloudKit 同步到其它设备。

**Architecture:** 引入 `ThemeManager`（`@Observable` 单例 + Environment 注入），把 `Theme.ColorToken.Surface.background / .elevated` 从静态 Color 改为 computed property，内部通过 `UIColor { trait in ... }` 让系统外观切换继续自动选 light/dark 一面。SwiftData 新增 `SDColorScheme` 表存主题库，UserDefaults 存"当前选中 + 未提交 draft"。业务代码（其余 token 调用点）零改动。

**Tech Stack:** SwiftUI、SwiftData、`@Observable`（iOS 17）、CloudKit（沿用现有 sync 链路）、Combine（debounce）、`Localizable.xcstrings`。

**Spec:** `docs/superpowers/specs/2026-05-22-color-mode-design.md`

---

## File Structure

**新增文件：**
- `BeadInventory/Models/ColorScheme.swift` — `ColorPalette` / `AppColorScheme` struct + hex 工具
- `BeadInventory/Managers/ThemeManager.swift` — 核心 `@Observable` 管理器
- `BeadInventory/Resources/built_in_color_schemes.json` — 5 个内建预设（含固定 UUID）
- `BeadInventory/Views/ColorMode/ColorModeView.swift` — 色彩模式主页面
- `BeadInventoryTests/ColorPaletteHexTests.swift`
- `BeadInventoryTests/ThemeManagerTests.swift`
- `BeadInventoryTests/BuiltinPresetBootstrapTests.swift`
- `BeadInventoryTests/ColorSchemeSyncTests.swift`

**修改文件：**
- `BeadInventory/Models/SwiftDataModels.swift` — 追加 `SDColorScheme`
- `BeadInventory/Models/SwiftDataMigration.swift` — schema 升 1.3.0，注册 `SDColorScheme.self`
- `BeadInventory/Views/DesignSystem/Theme.swift` — `Surface.background / .elevated` 改 computed
- `BeadInventory/Views/MoreView.swift` — 新增"色彩模式"入口
- `BeadInventory/BeadInventoryApp.swift` — 注入 `ThemeManager` + 启动期 bootstrap
- `BeadInventory/Localizable.xcstrings` — 新增 `color_mode.*` 键
- `BeadInventory/Managers/InventoryManager.swift` — sync 链路追加 `SDColorScheme` 差量合并

---

## Constants (used throughout the plan)

App 默认色值（来源于现有 `Palette/Bg.colorset` 与 `Palette/BgElev.colorset` 的 sRGB 分量换算）：

| Slot | sRGB 分量 | Hex |
|---|---|---|
| 浅色 Bg | (0.980, 0.961, 0.925) | `FAF5EC` |
| 浅色 BgElev | (1.000, 0.992, 0.973) | `FFFDF8` |
| 深色 Bg | (0.106, 0.090, 0.078) | `1B1714` |
| 深色 BgElev | (0.145, 0.125, 0.106) | `25201B` |

5 个内建预设的固定 UUID（写死在 JSON 中跨设备一致）：

| 预设 | UUID |
|---|---|
| 奶油拿铁 | `B1A5B100-0000-0000-0000-000000000001` |
| 薄荷晨光 | `B1A5B100-0000-0000-0000-000000000002` |
| 雾蓝海岸 | `B1A5B100-0000-0000-0000-000000000003` |
| 暮色玫瑰 | `B1A5B100-0000-0000-0000-000000000004` |
| 黑金 | `B1A5B100-0000-0000-0000-000000000005` |

构建命令（CLAUDE.md 规定）：

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build

xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test
```

---

# M1. 基础设施

## Task 1: ColorPalette / AppColorScheme struct + hex 工具

**Files:**
- Create: `BeadInventory/Models/ColorScheme.swift`
- Create: `BeadInventoryTests/ColorPaletteHexTests.swift`

- [ ] **Step 1: 写 hex parse 失败 fallback 测试**

文件 `BeadInventoryTests/ColorPaletteHexTests.swift`：

```swift
import XCTest
import SwiftUI
@testable import BeadInventory

final class ColorPaletteHexTests: XCTestCase {

    func test_uiColorFromHex_validHex_returnsCorrectColor() {
        let c = UIColor(themeHex: "FAF5EC")
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(r, 0.980, accuracy: 0.005)
        XCTAssertEqual(g, 0.961, accuracy: 0.005)
        XCTAssertEqual(b, 0.925, accuracy: 0.005)
    }

    func test_uiColorFromHex_invalidHex_returnsFallback() {
        let c = UIColor(themeHex: "ZZZZZZ", fallback: .red)
        XCTAssertEqual(c, .red)
    }

    func test_uiColorFromHex_acceptsLeadingHash() {
        let withHash = UIColor(themeHex: "#FAF5EC")
        let withoutHash = UIColor(themeHex: "FAF5EC")
        XCTAssertEqual(withHash.cgColor, withoutHash.cgColor)
    }

    func test_colorPalette_codableRoundTrip() throws {
        let p = ColorPalette(bg: "FAF5EC", bgElev: "FFFDF8")
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(ColorPalette.self, from: data)
        XCTAssertEqual(p, decoded)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:BeadInventoryTests/ColorPaletteHexTests test
```

Expected: FAIL — `UIColor(themeHex:)` / `ColorPalette` 未定义

- [ ] **Step 3: 创建 `BeadInventory/Models/ColorScheme.swift`**

```swift
//
//  ColorScheme.swift
//  BeadInventory
//
//  色彩模式：调色板与方案的内存模型。
//

import Foundation
import SwiftUI
import UIKit

typealias ColorHex = String   // "RRGGBB" 大写无前缀

struct ColorPalette: Codable, Equatable, Hashable {
    var bg:     ColorHex
    var bgElev: ColorHex
}

struct AppColorScheme: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String           // 内建：本地化 key；自定义：用户输入字符串
    var light: ColorPalette
    var dark:  ColorPalette
    var isBuiltin: Bool
    let createdAt: Date
    var updatedAt: Date
}

extension UIColor {
    /// 从 "RRGGBB" / "#RRGGBB" 解析。非法值返回 fallback（默认 systemBackground）。
    convenience init(themeHex hex: String, fallback: UIColor = .systemBackground) {
        let trimmed = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard trimmed.count == 6,
              let value = UInt32(trimmed, radix: 16) else {
            self.init(cgColor: fallback.cgColor)
            return
        }
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >>  8) & 0xFF) / 255.0
        let b = CGFloat( value        & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}

extension ColorPalette {
    static let defaultLight = ColorPalette(bg: "FAF5EC", bgElev: "FFFDF8")
    static let defaultDark  = ColorPalette(bg: "1B1714", bgElev: "25201B")
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:BeadInventoryTests/ColorPaletteHexTests test
```

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add BeadInventory/Models/ColorScheme.swift BeadInventoryTests/ColorPaletteHexTests.swift
git commit -m "feat(theme): ColorPalette / AppColorScheme struct + hex 工具

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: SDColorScheme SwiftData 模型 + schema 1.3.0

**Files:**
- Modify: `BeadInventory/Models/SwiftDataModels.swift` (追加到文件尾部)
- Modify: `BeadInventory/Models/SwiftDataMigration.swift:17-23`

- [ ] **Step 1: 在 `SwiftDataModels.swift` 末尾追加 `SDColorScheme`**

```swift
// MARK: - 色彩主题模型
@Model
final class SDColorScheme {
    @Attribute(.unique) var id: UUID = UUID()
    var name: String = ""
    var lightBgHex:     String = "FAF5EC"
    var lightBgElevHex: String = "FFFDF8"
    var darkBgHex:      String = "1B1714"
    var darkBgElevHex:  String = "25201B"
    var isBuiltin: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        name: String,
        lightBgHex: String,
        lightBgElevHex: String,
        darkBgHex: String,
        darkBgElevHex: String,
        isBuiltin: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.lightBgHex = lightBgHex
        self.lightBgElevHex = lightBgElevHex
        self.darkBgHex = darkBgHex
        self.darkBgElevHex = darkBgElevHex
        self.isBuiltin = isBuiltin
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    convenience init(from scheme: AppColorScheme) {
        self.init(
            id: scheme.id,
            name: scheme.name,
            lightBgHex: scheme.light.bg,
            lightBgElevHex: scheme.light.bgElev,
            darkBgHex: scheme.dark.bg,
            darkBgElevHex: scheme.dark.bgElev,
            isBuiltin: scheme.isBuiltin,
            createdAt: scheme.createdAt,
            updatedAt: scheme.updatedAt
        )
    }

    func toStruct() -> AppColorScheme {
        AppColorScheme(
            id: id,
            name: name,
            light: ColorPalette(bg: lightBgHex, bgElev: lightBgElevHex),
            dark:  ColorPalette(bg: darkBgHex,  bgElev: darkBgElevHex),
            isBuiltin: isBuiltin,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
```

- [ ] **Step 2: 注册到 schema，bump 版本到 1.3.0**

修改 `BeadInventory/Models/SwiftDataMigration.swift:17-23`：

```swift
enum CurrentSchema: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 3, 0)  // 1.3.0: 添加色彩主题支持

    static var models: [any PersistentModel.Type] {
        [
            SDBrand.self,
            SDBrandStock.self,
            SDProjectRecord.self,
            SDBeadUsage.self,
            SDCustomColor.self,
            SDColorScheme.self
        ]
    }
}
```

并更新文件顶部注释：

```swift
/// - 1.3.0: 添加 SDColorScheme 模型支持色彩主题功能
enum BeadInventoryMigrationPlan: SchemaMigrationPlan {
```

- [ ] **Step 3: Build 验证**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build
```

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add BeadInventory/Models/SwiftDataModels.swift BeadInventory/Models/SwiftDataMigration.swift
git commit -m "feat(theme): SDColorScheme SwiftData 模型 + schema 1.3.0

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: ThemeManager 骨架（仅默认值，无 draft / 无持久化）

**Files:**
- Create: `BeadInventory/Managers/ThemeManager.swift`

- [ ] **Step 1: 创建 `ThemeManager.swift`（最小可用）**

```swift
//
//  ThemeManager.swift
//  BeadInventory
//
//  色彩模式核心：@Observable 单例 + Environment 注入。
//  Theme.ColorToken.Surface 通过 .shared 读色值；视图通过 @Environment(ThemeManager.self) 订阅。
//

import Foundation
import SwiftUI
import SwiftData
import Combine

enum ApplyTarget {
    case both, lightOnly, darkOnly
}

enum ThemeSlot {
    case lightBg, lightElev, darkBg, darkElev
}

struct ThemeDraft {
    let snapshotActiveSchemeID: UUID?
    let snapshotLight: ColorPalette
    let snapshotDark:  ColorPalette
    var isDirty: Bool
}

@Observable
final class ThemeManager {

    static let shared = ThemeManager()

    private(set) var activeSchemeID: UUID?
    private(set) var resolvedLight: ColorPalette
    private(set) var resolvedDark:  ColorPalette
    private(set) var draft: ThemeDraft?

    var isDirty: Bool { draft?.isDirty ?? false }

    init(
        activeSchemeID: UUID? = nil,
        resolvedLight: ColorPalette = .defaultLight,
        resolvedDark:  ColorPalette = .defaultDark
    ) {
        self.activeSchemeID = activeSchemeID
        self.resolvedLight = resolvedLight
        self.resolvedDark = resolvedDark
    }

    // MARK: - 给 Theme.ColorToken 用的 UIColor 工厂
    //
    // 闭包内部读 self.resolvedLight/Dark；@Observable 在 View body 评估期间
    // 读取 .shared.resolvedLight 时建立依赖订阅，色值变化触发整树 re-evaluate body，
    // 产生新的 Color(uiColor:) 实例。闭包本身只在系统 trait 变化时被 iOS 调用一次。

    var dynamicBg: UIColor {
        UIColor { [weak self] trait in
            guard let self else { return UIColor(themeHex: ColorPalette.defaultLight.bg) }
            let hex = trait.userInterfaceStyle == .dark ? self.resolvedDark.bg : self.resolvedLight.bg
            return UIColor(themeHex: hex)
        }
    }

    var dynamicBgElev: UIColor {
        UIColor { [weak self] trait in
            guard let self else { return UIColor(themeHex: ColorPalette.defaultLight.bgElev) }
            let hex = trait.userInterfaceStyle == .dark ? self.resolvedDark.bgElev : self.resolvedLight.bgElev
            return UIColor(themeHex: hex)
        }
    }
}
```

- [ ] **Step 2: Build 验证**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add BeadInventory/Managers/ThemeManager.swift
git commit -m "feat(theme): ThemeManager 骨架 + dynamicBg/Elev UIColor 工厂

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Theme.ColorToken.Surface 改 computed，路由到 ThemeManager

**Files:**
- Modify: `BeadInventory/Views/DesignSystem/Theme.swift:81-86`

- [ ] **Step 1: 把 Surface.background / .elevated 改成 computed**

修改 `Theme.swift:81-86`：

```swift
        enum Surface {
            /// 米奶页面底；运行时由 ThemeManager.shared 提供，自动跟随系统外观
            static var background: Color { Color(uiColor: ThemeManager.shared.dynamicBg) }
            /// 卡片底（偏纯白偏暖）；同上
            static var elevated:   Color { Color(uiColor: ThemeManager.shared.dynamicBgElev) }
            static let subtle  = Color("Palette/Neutral50")
            static let strong  = Color("Palette/SurfaceStrong")
        }
```

注：`subtle` 和 `strong` 保持引用 asset，不在本期改造范围内。

- [ ] **Step 2: Build 验证**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3: 跑现有 ThemeTests 防回归**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:BeadInventoryTests/ThemeTests test
```

Expected: PASS（默认色值 = ThemeManager 默认值 = Asset Catalog 当前值，外观零变化）

- [ ] **Step 4: Commit**

```bash
git add BeadInventory/Views/DesignSystem/Theme.swift
git commit -m "refactor(theme): Surface.background/elevated 改 computed 路由到 ThemeManager

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: App 入口注入 ThemeManager 到 Environment

**Files:**
- Modify: `BeadInventory/BeadInventoryApp.swift`

- [ ] **Step 1: 找到 `ContentView()` 实例化位置，注入 environment**

读 `BeadInventoryApp.swift` 找到 root view（应是 ContentView 或类似），加：

```swift
@State private var themeManager = ThemeManager.shared

var body: some Scene {
    WindowGroup {
        ContentView()
            .environment(themeManager)
            // ... 其它已有 modifier
    }
}
```

如果已有 `@State` 块，把 `themeManager` 加到合适位置。

- [ ] **Step 2: 启动手测**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build
```

在模拟器跑 App，确认：
- 浅色模式下 5 个 Tab 背景仍为米奶色
- 控制中心切深色 → 背景变深咖

Expected: 外观与改造前一致

- [ ] **Step 3: Commit**

```bash
git add BeadInventory/BeadInventoryApp.swift
git commit -m "feat(theme): App 入口注入 ThemeManager.shared 到 Environment

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

# M2. ThemeManager 完整 API + 持久化

## Task 6: apply(scheme, target:) + 测试

**Files:**
- Modify: `BeadInventory/Managers/ThemeManager.swift`
- Create: `BeadInventoryTests/ThemeManagerTests.swift`

- [ ] **Step 1: 写 apply 行为的测试**

```swift
import XCTest
@testable import BeadInventory

final class ThemeManagerTests: XCTestCase {

    private func sampleScheme(id: UUID = UUID(), isBuiltin: Bool = false) -> AppColorScheme {
        AppColorScheme(
            id: id,
            name: "Sample",
            light: ColorPalette(bg: "AABBCC", bgElev: "DDEEFF"),
            dark:  ColorPalette(bg: "112233", bgElev: "445566"),
            isBuiltin: isBuiltin,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    func test_apply_both_setsAllFour_andActiveID() {
        let mgr = ThemeManager()
        let s = sampleScheme()
        mgr.apply(scheme: s, target: .both)
        XCTAssertEqual(mgr.resolvedLight, s.light)
        XCTAssertEqual(mgr.resolvedDark,  s.dark)
        XCTAssertEqual(mgr.activeSchemeID, s.id)
    }

    func test_apply_lightOnly_keepsDark_andActiveIDNil() {
        let mgr = ThemeManager(resolvedLight: .defaultLight, resolvedDark: .defaultDark)
        let originalDark = mgr.resolvedDark
        let s = sampleScheme()
        mgr.apply(scheme: s, target: .lightOnly)
        XCTAssertEqual(mgr.resolvedLight, s.light)
        XCTAssertEqual(mgr.resolvedDark, originalDark)
        XCTAssertNil(mgr.activeSchemeID)
    }

    func test_apply_darkOnly_keepsLight_andActiveIDNil() {
        let mgr = ThemeManager(resolvedLight: .defaultLight, resolvedDark: .defaultDark)
        let originalLight = mgr.resolvedLight
        let s = sampleScheme()
        mgr.apply(scheme: s, target: .darkOnly)
        XCTAssertEqual(mgr.resolvedDark, s.dark)
        XCTAssertEqual(mgr.resolvedLight, originalLight)
        XCTAssertNil(mgr.activeSchemeID)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:BeadInventoryTests/ThemeManagerTests test
```

Expected: FAIL — `apply` 未定义

- [ ] **Step 3: 实现 apply**

在 `ThemeManager.swift` 类内追加：

```swift
    // MARK: - Apply

    func apply(scheme: AppColorScheme, target: ApplyTarget) {
        switch target {
        case .both:
            resolvedLight = scheme.light
            resolvedDark  = scheme.dark
            activeSchemeID = scheme.id
        case .lightOnly:
            resolvedLight = scheme.light
            activeSchemeID = nil
        case .darkOnly:
            resolvedDark = scheme.dark
            activeSchemeID = nil
        }
        if let draftValue = draft {
            draft = ThemeDraft(
                snapshotActiveSchemeID: draftValue.snapshotActiveSchemeID,
                snapshotLight: draftValue.snapshotLight,
                snapshotDark:  draftValue.snapshotDark,
                isDirty: target == .both ? false : true
            )
        }
    }
```

- [ ] **Step 4: 测试通过**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:BeadInventoryTests/ThemeManagerTests test
```

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add BeadInventory/Managers/ThemeManager.swift BeadInventoryTests/ThemeManagerTests.swift
git commit -m "feat(theme): ThemeManager.apply(scheme,target:) + 测试

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: updateSwatch(slot, hex:) + 测试

**Files:**
- Modify: `BeadInventory/Managers/ThemeManager.swift`
- Modify: `BeadInventoryTests/ThemeManagerTests.swift`

- [ ] **Step 1: 追加测试**

```swift
    func test_updateSwatch_lightBg_changesLightBgAndClearsActiveID() {
        let mgr = ThemeManager(activeSchemeID: UUID(),
                               resolvedLight: .defaultLight,
                               resolvedDark: .defaultDark)
        mgr.updateSwatch(.lightBg, hex: "112233")
        XCTAssertEqual(mgr.resolvedLight.bg, "112233")
        XCTAssertEqual(mgr.resolvedLight.bgElev, ColorPalette.defaultLight.bgElev)
        XCTAssertEqual(mgr.resolvedDark, .defaultDark)
        XCTAssertNil(mgr.activeSchemeID)
    }

    func test_updateSwatch_darkElev_changesOnlyThat() {
        let mgr = ThemeManager(activeSchemeID: UUID(),
                               resolvedLight: .defaultLight,
                               resolvedDark: .defaultDark)
        mgr.updateSwatch(.darkElev, hex: "ABCDEF")
        XCTAssertEqual(mgr.resolvedDark.bgElev, "ABCDEF")
        XCTAssertEqual(mgr.resolvedDark.bg, ColorPalette.defaultDark.bg)
        XCTAssertNil(mgr.activeSchemeID)
    }
```

- [ ] **Step 2: 运行测试确认失败**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:BeadInventoryTests/ThemeManagerTests test
```

Expected: FAIL — `updateSwatch` 未定义

- [ ] **Step 3: 实现 updateSwatch**

在 `ThemeManager.swift` 类内追加：

```swift
    // MARK: - Swatch 编辑

    func updateSwatch(_ slot: ThemeSlot, hex: String) {
        let normalized = normalizeHex(hex)
        switch slot {
        case .lightBg:    resolvedLight.bg     = normalized
        case .lightElev:  resolvedLight.bgElev = normalized
        case .darkBg:     resolvedDark.bg      = normalized
        case .darkElev:   resolvedDark.bgElev  = normalized
        }
        activeSchemeID = nil
        if var d = draft {
            d.isDirty = true
            draft = d
        }
    }

    private func normalizeHex(_ raw: String) -> String {
        let trimmed = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        return trimmed.uppercased()
    }
```

- [ ] **Step 4: 测试通过**

Run: `-only-testing:BeadInventoryTests/ThemeManagerTests test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add BeadInventory/Managers/ThemeManager.swift BeadInventoryTests/ThemeManagerTests.swift
git commit -m "feat(theme): ThemeManager.updateSwatch(slot,hex:) + 测试

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: beginDraft / discardDraft / commitAsNewScheme + 测试

**Files:**
- Modify: `BeadInventory/Managers/ThemeManager.swift`
- Modify: `BeadInventoryTests/ThemeManagerTests.swift`

- [ ] **Step 1: 追加测试**

```swift
    func test_beginDraft_thenUpdate_thenDiscard_restoresSnapshot() {
        let originalID = UUID()
        let mgr = ThemeManager(activeSchemeID: originalID,
                               resolvedLight: .defaultLight,
                               resolvedDark: .defaultDark)
        mgr.beginDraft()
        mgr.updateSwatch(.lightBg, hex: "FF0000")
        XCTAssertTrue(mgr.isDirty)
        XCTAssertNil(mgr.activeSchemeID)
        XCTAssertEqual(mgr.resolvedLight.bg, "FF0000")

        mgr.discardDraft()
        XCTAssertEqual(mgr.resolvedLight, .defaultLight)
        XCTAssertEqual(mgr.activeSchemeID, originalID)
        XCTAssertNil(mgr.draft)
        XCTAssertFalse(mgr.isDirty)
    }

    func test_beginDraft_thenApplyFullPreset_marksClean() {
        let mgr = ThemeManager(activeSchemeID: nil,
                               resolvedLight: .defaultLight,
                               resolvedDark: .defaultDark)
        mgr.beginDraft()
        mgr.updateSwatch(.lightBg, hex: "FF0000")
        XCTAssertTrue(mgr.isDirty)

        let preset = sampleScheme()
        mgr.apply(scheme: preset, target: .both)
        XCTAssertFalse(mgr.isDirty)   // 完整应用预设 = 干净
    }

    func test_commitAsNewScheme_producesSchemeWithCurrentColors() throws {
        let mgr = ThemeManager(activeSchemeID: nil,
                               resolvedLight: ColorPalette(bg: "AAAAAA", bgElev: "BBBBBB"),
                               resolvedDark:  ColorPalette(bg: "111111", bgElev: "222222"))
        mgr.beginDraft()
        let scheme = try mgr.commitAsNewScheme(name: "我的咖啡")
        XCTAssertEqual(scheme.name, "我的咖啡")
        XCTAssertEqual(scheme.light, ColorPalette(bg: "AAAAAA", bgElev: "BBBBBB"))
        XCTAssertEqual(scheme.dark,  ColorPalette(bg: "111111", bgElev: "222222"))
        XCTAssertFalse(scheme.isBuiltin)
        XCTAssertEqual(mgr.activeSchemeID, scheme.id)
        XCTAssertNil(mgr.draft)
    }
```

- [ ] **Step 2: 运行确认失败**

Expected: FAIL — `beginDraft / discardDraft / commitAsNewScheme` 未定义

- [ ] **Step 3: 实现 draft 生命周期方法**

在 `ThemeManager.swift` 类内追加：

```swift
    // MARK: - Draft lifecycle

    func beginDraft() {
        draft = ThemeDraft(
            snapshotActiveSchemeID: activeSchemeID,
            snapshotLight: resolvedLight,
            snapshotDark:  resolvedDark,
            isDirty: false
        )
    }

    func discardDraft() {
        guard let d = draft else { return }
        resolvedLight = d.snapshotLight
        resolvedDark  = d.snapshotDark
        activeSchemeID = d.snapshotActiveSchemeID
        draft = nil
    }

    @discardableResult
    func commitAsNewScheme(name: String) throws -> AppColorScheme {
        let now = Date()
        let scheme = AppColorScheme(
            id: UUID(),
            name: name,
            light: resolvedLight,
            dark:  resolvedDark,
            isBuiltin: false,
            createdAt: now,
            updatedAt: now
        )
        activeSchemeID = scheme.id
        draft = nil
        // 写入 SwiftData 在 Task 9 的 persistence 中完成
        return scheme
    }
```

- [ ] **Step 4: 测试通过**

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add BeadInventory/Managers/ThemeManager.swift BeadInventoryTests/ThemeManagerTests.swift
git commit -m "feat(theme): begin/discard/commit draft 生命周期 + 测试

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: UserDefaults 持久化 + debounce + commitAsNewScheme 写 SwiftData

**Files:**
- Modify: `BeadInventory/Managers/ThemeManager.swift`
- Modify: `BeadInventoryTests/ThemeManagerTests.swift`

- [ ] **Step 1: 追加测试**

```swift
    func test_persistenceKeys_writeAndReadOverride() {
        let defaults = UserDefaults(suiteName: "ThemeManagerTests-\(UUID())")!
        defaults.removePersistentDomain(forName: "ThemeManagerTests")
        let mgr = ThemeManager.test_make(defaults: defaults)
        mgr.updateSwatch(.lightBg, hex: "ABCDEF")
        mgr.flushPersistenceForTests()
        XCTAssertEqual(defaults.string(forKey: "theme.light.bgHex"), "ABCDEF")
        XCTAssertNil(defaults.string(forKey: "theme.activeSchemeID"))
    }

    func test_loadFromPersistence_restoresOverride() {
        let defaults = UserDefaults(suiteName: "ThemeManagerTests-\(UUID())")!
        defaults.set("ABCDEF", forKey: "theme.light.bgHex")
        defaults.set("FFDDCC", forKey: "theme.light.bgElevHex")
        defaults.set("001122", forKey: "theme.dark.bgHex")
        defaults.set("334455", forKey: "theme.dark.bgElevHex")
        let mgr = ThemeManager.test_make(defaults: defaults)
        mgr.loadOverridesFromDefaults()
        XCTAssertEqual(mgr.resolvedLight, ColorPalette(bg: "ABCDEF", bgElev: "FFDDCC"))
        XCTAssertEqual(mgr.resolvedDark,  ColorPalette(bg: "001122", bgElev: "334455"))
    }
```

- [ ] **Step 2: 实现持久化层**

在 `ThemeManager.swift` 中追加：

```swift
    // MARK: - Persistence

    private let defaults: UserDefaults
    private var debounceTask: Task<Void, Never>?
    private static let debounceMs: UInt64 = 250_000_000  // 250ms

    enum PrefsKey {
        static let activeSchemeID    = "theme.activeSchemeID"
        static let lightBgHex        = "theme.light.bgHex"
        static let lightBgElevHex    = "theme.light.bgElevHex"
        static let darkBgHex         = "theme.dark.bgHex"
        static let darkBgElevHex     = "theme.dark.bgElevHex"
        static let pendingDraftJSON  = "theme.pendingDraftJSON"
        static let builtinVersion    = "theme.builtinVersion"
    }

    // 测试入口
    static func test_make(defaults: UserDefaults) -> ThemeManager {
        ThemeManager(defaults: defaults)
    }

    private init(
        defaults: UserDefaults,
        activeSchemeID: UUID? = nil,
        resolvedLight: ColorPalette = .defaultLight,
        resolvedDark:  ColorPalette = .defaultDark
    ) {
        self.defaults = defaults
        self.activeSchemeID = activeSchemeID
        self.resolvedLight = resolvedLight
        self.resolvedDark = resolvedDark
    }

    // 公开 init 改为使用 .standard
    convenience init() {
        self.init(defaults: .standard)
    }

    // 注：原文件顶部已有 `static let shared = ThemeManager()` 保留不动

    func loadOverridesFromDefaults() {
        if let id = defaults.string(forKey: PrefsKey.activeSchemeID).flatMap(UUID.init) {
            activeSchemeID = id
        }
        resolvedLight = ColorPalette(
            bg: defaults.string(forKey: PrefsKey.lightBgHex) ?? ColorPalette.defaultLight.bg,
            bgElev: defaults.string(forKey: PrefsKey.lightBgElevHex) ?? ColorPalette.defaultLight.bgElev
        )
        resolvedDark = ColorPalette(
            bg: defaults.string(forKey: PrefsKey.darkBgHex) ?? ColorPalette.defaultDark.bg,
            bgElev: defaults.string(forKey: PrefsKey.darkBgElevHex) ?? ColorPalette.defaultDark.bgElev
        )
    }

    private func schedulePersistResolved() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ThemeManager.debounceMs)
            await MainActor.run { [weak self] in self?.flushPersistResolved() }
        }
    }

    private func flushPersistResolved() {
        defaults.set(activeSchemeID?.uuidString, forKey: PrefsKey.activeSchemeID)
        defaults.set(resolvedLight.bg,     forKey: PrefsKey.lightBgHex)
        defaults.set(resolvedLight.bgElev, forKey: PrefsKey.lightBgElevHex)
        defaults.set(resolvedDark.bg,      forKey: PrefsKey.darkBgHex)
        defaults.set(resolvedDark.bgElev,  forKey: PrefsKey.darkBgElevHex)
    }

    func flushPersistenceForTests() {
        debounceTask?.cancel()
        flushPersistResolved()
    }
```

并在 `apply` 和 `updateSwatch` 末尾追加 `schedulePersistResolved()`：

```swift
    func apply(scheme: AppColorScheme, target: ApplyTarget) {
        // ... 已有实现 ...
        schedulePersistResolved()
    }

    func updateSwatch(_ slot: ThemeSlot, hex: String) {
        // ... 已有实现 ...
        schedulePersistResolved()
    }
```

- [ ] **Step 3: commitAsNewScheme 接 SwiftData 写入**

修改 `commitAsNewScheme` 签名以接收 ModelContext，并实际 insert：

```swift
    @discardableResult
    func commitAsNewScheme(name: String, modelContext: ModelContext? = nil) throws -> AppColorScheme {
        let now = Date()
        let scheme = AppColorScheme(
            id: UUID(),
            name: name,
            light: resolvedLight,
            dark:  resolvedDark,
            isBuiltin: false,
            createdAt: now,
            updatedAt: now
        )
        if let ctx = modelContext {
            let sd = SDColorScheme(from: scheme)
            ctx.insert(sd)
            try ctx.save()
        }
        activeSchemeID = scheme.id
        draft = nil
        schedulePersistResolved()
        return scheme
    }
```

修改对应测试 `test_commitAsNewScheme_producesSchemeWithCurrentColors`：传 `modelContext: nil` 即可，原断言不变。

- [ ] **Step 4: 测试通过**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:BeadInventoryTests/ThemeManagerTests test
```

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add BeadInventory/Managers/ThemeManager.swift BeadInventoryTests/ThemeManagerTests.swift
git commit -m "feat(theme): UserDefaults 持久化 + 250ms debounce + commit 写 SwiftData

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: pendingDraft 落盘 + 进程恢复

**Files:**
- Modify: `BeadInventory/Managers/ThemeManager.swift`
- Modify: `BeadInventoryTests/ThemeManagerTests.swift`

- [ ] **Step 1: 测试**

```swift
    func test_persistPendingDraft_andRestore() {
        let defaults = UserDefaults(suiteName: "ThemeManagerTests-\(UUID())")!
        let mgr = ThemeManager.test_make(defaults: defaults)
        mgr.beginDraft()
        mgr.updateSwatch(.lightBg, hex: "FF0000")
        mgr.flushPersistenceForTests()

        let restored = ThemeManager.test_make(defaults: defaults)
        restored.loadOverridesFromDefaults()
        restored.loadPendingDraftFromDefaults()
        XCTAssertTrue(restored.isDirty)
        XCTAssertEqual(restored.resolvedLight.bg, "FF0000")
        XCTAssertNotNil(restored.draft)
    }

    func test_discardDraft_clearsPersistedPendingDraft() {
        let defaults = UserDefaults(suiteName: "ThemeManagerTests-\(UUID())")!
        let mgr = ThemeManager.test_make(defaults: defaults)
        mgr.beginDraft()
        mgr.updateSwatch(.lightBg, hex: "FF0000")
        mgr.flushPersistenceForTests()
        mgr.discardDraft()
        mgr.flushPersistenceForTests()
        XCTAssertNil(defaults.string(forKey: "theme.pendingDraftJSON"))
    }
```

- [ ] **Step 2: 实现 draft 落盘 / 恢复**

在 `ThemeManager.swift` 中加：

```swift
    // 把 ThemeDraft 编码为 JSON 入 UserDefaults
    private func persistPendingDraft() {
        guard let d = draft, d.isDirty else {
            defaults.removeObject(forKey: PrefsKey.pendingDraftJSON)
            return
        }
        let payload = DraftPayload(
            snapshotActiveSchemeID: d.snapshotActiveSchemeID,
            snapshotLight: d.snapshotLight,
            snapshotDark: d.snapshotDark,
            currentLight: resolvedLight,
            currentDark: resolvedDark
        )
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: PrefsKey.pendingDraftJSON)
        }
    }

    func loadPendingDraftFromDefaults() {
        guard let data = defaults.data(forKey: PrefsKey.pendingDraftJSON),
              let payload = try? JSONDecoder().decode(DraftPayload.self, from: data) else {
            return
        }
        draft = ThemeDraft(
            snapshotActiveSchemeID: payload.snapshotActiveSchemeID,
            snapshotLight: payload.snapshotLight,
            snapshotDark: payload.snapshotDark,
            isDirty: true
        )
        resolvedLight = payload.currentLight
        resolvedDark  = payload.currentDark
        activeSchemeID = nil
    }

    private struct DraftPayload: Codable {
        let snapshotActiveSchemeID: UUID?
        let snapshotLight: ColorPalette
        let snapshotDark: ColorPalette
        let currentLight: ColorPalette
        let currentDark: ColorPalette
    }
```

在 `schedulePersistResolved → flushPersistResolved` 末尾追加 `persistPendingDraft()`，并修改 `discardDraft`、`commitAsNewScheme` 同步清除 pending：

```swift
    func discardDraft() {
        // ... 已有 restore 逻辑 ...
        schedulePersistResolved()  // 触发持久化（pendingDraft 会被清）
    }
```

- [ ] **Step 3: 测试通过**

Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add BeadInventory/Managers/ThemeManager.swift BeadInventoryTests/ThemeManagerTests.swift
git commit -m "feat(theme): pendingDraft JSON 落盘 + 进程被杀后恢复

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

# M3. 内建预设

## Task 11: built_in_color_schemes.json

**Files:**
- Create: `BeadInventory/Resources/built_in_color_schemes.json`

- [ ] **Step 1: 创建 JSON 文件**

```json
{
  "version": 1,
  "schemes": [
    {
      "id": "B1A5B100-0000-0000-0000-000000000001",
      "name_key": "color_mode.preset.cream_latte",
      "light": { "bg": "FAF5EC", "bg_elev": "FFFDF8" },
      "dark":  { "bg": "1B1714", "bg_elev": "25201B" }
    },
    {
      "id": "B1A5B100-0000-0000-0000-000000000002",
      "name_key": "color_mode.preset.mint_dawn",
      "light": { "bg": "EEF6EE", "bg_elev": "FAFFFA" },
      "dark":  { "bg": "0F1A12", "bg_elev": "1A2820" }
    },
    {
      "id": "B1A5B100-0000-0000-0000-000000000003",
      "name_key": "color_mode.preset.mist_coast",
      "light": { "bg": "EAF1F6", "bg_elev": "F8FBFD" },
      "dark":  { "bg": "0D1620", "bg_elev": "172331" }
    },
    {
      "id": "B1A5B100-0000-0000-0000-000000000004",
      "name_key": "color_mode.preset.dusk_rose",
      "light": { "bg": "F6E8EC", "bg_elev": "FFF7F9" },
      "dark":  { "bg": "1E1014", "bg_elev": "2C181F" }
    },
    {
      "id": "B1A5B100-0000-0000-0000-000000000005",
      "name_key": "color_mode.preset.black_gold",
      "light": { "bg": "FBF6EC", "bg_elev": "FFFAF0" },
      "dark":  { "bg": "0E0B07", "bg_elev": "1F1A12" }
    }
  ]
}
```

- [ ] **Step 2: 加入 Xcode target**

在 Xcode 中右键 `Resources/` 文件夹 → "Add Files to BeadInventory" → 选 `built_in_color_schemes.json` → 确保 "Target Membership" 勾选 `BeadInventory`。

如果用命令行验证已加入 bundle，可临时在 ThemeManager 中加：

```swift
print(Bundle.main.url(forResource: "built_in_color_schemes", withExtension: "json") as Any)
```

启动后控制台应输出非 nil URL。验证完毕后删除这行。

- [ ] **Step 3: Build 验证**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build
```

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add BeadInventory/Resources/built_in_color_schemes.json BeadInventory.xcodeproj
git commit -m "feat(theme): 5 个内建预设 JSON（含固定 UUID）

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: bootstrapBuiltinPresets() + 测试

**Files:**
- Modify: `BeadInventory/Managers/ThemeManager.swift`
- Create: `BeadInventoryTests/BuiltinPresetBootstrapTests.swift`

- [ ] **Step 1: 写测试**

```swift
import XCTest
import SwiftData
@testable import BeadInventory

final class BuiltinPresetBootstrapTests: XCTestCase {

    private func makeInMemoryContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: SDColorScheme.self, configurations: config)
        return ModelContext(container)
    }

    private func sampleBuiltinJSON() -> Data {
        """
        {
          "version": 1,
          "schemes": [
            {"id": "B1A5B100-0000-0000-0000-000000000001",
             "name_key": "color_mode.preset.cream_latte",
             "light": {"bg": "FAF5EC", "bg_elev": "FFFDF8"},
             "dark":  {"bg": "1B1714", "bg_elev": "25201B"}}
          ]
        }
        """.data(using: .utf8)!
    }

    func test_bootstrap_freshDB_insertsAllPresets() throws {
        let defaults = UserDefaults(suiteName: "Bootstrap-\(UUID())")!
        let ctx = try makeInMemoryContext()
        let mgr = ThemeManager.test_make(defaults: defaults)
        try mgr.bootstrapBuiltinPresets(jsonData: sampleBuiltinJSON(), modelContext: ctx)

        let all = try ctx.fetch(FetchDescriptor<SDColorScheme>())
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id.uuidString, "B1A5B100-0000-0000-0000-000000000001")
        XCTAssertTrue(all.first?.isBuiltin ?? false)
        XCTAssertEqual(defaults.integer(forKey: "theme.builtinVersion"), 1)
    }

    func test_bootstrap_sameVersion_skips() throws {
        let defaults = UserDefaults(suiteName: "Bootstrap-\(UUID())")!
        defaults.set(1, forKey: "theme.builtinVersion")
        let ctx = try makeInMemoryContext()
        let mgr = ThemeManager.test_make(defaults: defaults)
        try mgr.bootstrapBuiltinPresets(jsonData: sampleBuiltinJSON(), modelContext: ctx)
        let all = try ctx.fetch(FetchDescriptor<SDColorScheme>())
        XCTAssertEqual(all.count, 0)   // skip 时不写
    }

    func test_bootstrap_higherVersion_upserts() throws {
        // 旧 builtin 已存在
        let defaults = UserDefaults(suiteName: "Bootstrap-\(UUID())")!
        defaults.set(0, forKey: "theme.builtinVersion")
        let ctx = try makeInMemoryContext()
        let oldID = UUID(uuidString: "B1A5B100-0000-0000-0000-000000000001")!
        ctx.insert(SDColorScheme(
            id: oldID, name: "OldName",
            lightBgHex: "000000", lightBgElevHex: "000000",
            darkBgHex: "000000", darkBgElevHex: "000000",
            isBuiltin: true
        ))
        try ctx.save()

        let mgr = ThemeManager.test_make(defaults: defaults)
        try mgr.bootstrapBuiltinPresets(jsonData: sampleBuiltinJSON(), modelContext: ctx)

        let all = try ctx.fetch(FetchDescriptor<SDColorScheme>())
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.lightBgHex, "FAF5EC")  // 被强制覆盖
        XCTAssertEqual(all.first?.name, "color_mode.preset.cream_latte")
    }
}
```

- [ ] **Step 2: 实现 bootstrap**

在 `ThemeManager.swift` 加：

```swift
    // MARK: - Builtin presets bootstrap

    private struct BuiltinFile: Decodable {
        let version: Int
        let schemes: [BuiltinScheme]
    }
    private struct BuiltinScheme: Decodable {
        let id: UUID
        let name_key: String
        let light: BuiltinPalette
        let dark:  BuiltinPalette
    }
    private struct BuiltinPalette: Decodable {
        let bg: String
        let bg_elev: String
    }

    func bootstrapBuiltinPresets(modelContext: ModelContext) throws {
        guard let url = Bundle.main.url(forResource: "built_in_color_schemes", withExtension: "json") else {
            return
        }
        let data = try Data(contentsOf: url)
        try bootstrapBuiltinPresets(jsonData: data, modelContext: modelContext)
    }

    func bootstrapBuiltinPresets(jsonData: Data, modelContext: ModelContext) throws {
        let file = try JSONDecoder().decode(BuiltinFile.self, from: jsonData)
        let stored = defaults.integer(forKey: PrefsKey.builtinVersion)
        guard file.version > stored else { return }

        let now = Date()
        for s in file.schemes {
            let existing = try modelContext.fetch(
                FetchDescriptor<SDColorScheme>(predicate: #Predicate { $0.id == s.id })
            ).first

            if let existing {
                existing.name = s.name_key
                existing.lightBgHex     = s.light.bg.uppercased()
                existing.lightBgElevHex = s.light.bg_elev.uppercased()
                existing.darkBgHex      = s.dark.bg.uppercased()
                existing.darkBgElevHex  = s.dark.bg_elev.uppercased()
                existing.isBuiltin = true
                existing.updatedAt = now
            } else {
                modelContext.insert(SDColorScheme(
                    id: s.id,
                    name: s.name_key,
                    lightBgHex:     s.light.bg.uppercased(),
                    lightBgElevHex: s.light.bg_elev.uppercased(),
                    darkBgHex:      s.dark.bg.uppercased(),
                    darkBgElevHex:  s.dark.bg_elev.uppercased(),
                    isBuiltin: true,
                    createdAt: now,
                    updatedAt: now
                ))
            }
        }
        try modelContext.save()
        defaults.set(file.version, forKey: PrefsKey.builtinVersion)
    }
```

- [ ] **Step 3: 测试通过**

```bash
xcodebuild ... -only-testing:BeadInventoryTests/BuiltinPresetBootstrapTests test
```

Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add BeadInventory/Managers/ThemeManager.swift BeadInventoryTests/BuiltinPresetBootstrapTests.swift
git commit -m "feat(theme): bootstrapBuiltinPresets 版本比对 + 固定 UUID upsert

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 13: App 启动调用 bootstrap + loadFromPersistence

**Files:**
- Modify: `BeadInventory/BeadInventoryApp.swift`

- [ ] **Step 1: 在 ContentView appear 时调用 bootstrap**

读 `BeadInventoryApp.swift` 找到能拿到 `modelContext` 的位置，最简洁的方式是在根 ContentView 上加 `.task`：

```swift
ContentView()
    .environment(themeManager)
    .task {
        let ctx = ModelContext(/* 项目里现有 ModelContainer */)
        try? themeManager.bootstrapBuiltinPresets(modelContext: ctx)
        themeManager.loadOverridesFromDefaults()
        themeManager.loadPendingDraftFromDefaults()
    }
```

（具体 ModelContainer 获取方式参考项目现有 `BeadInventoryApp.swift` 中已有的 `.modelContainer(...)` 调用，复用同一实例的 mainContext。）

- [ ] **Step 2: 启动手测**

跑模拟器，App 启动后：
- 第一次启动：UserDefaults `theme.builtinVersion` 写入 1，SwiftData 出现 5 条 `SDColorScheme isBuiltin=true`
- 第二次启动：版本号已是 1，bootstrap skip，5 条不变
- 浅色 / 深色显示与改造前一致

可用 Xcode Console 临时加打印验证。

- [ ] **Step 3: Commit**

```bash
git add BeadInventory/BeadInventoryApp.swift
git commit -m "feat(theme): App 启动期 bootstrap 内建预设 + 恢复持久化偏好

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

# M4. UI - ColorModeView

## Task 14: ColorModeView 骨架 + MoreView 入口

**Files:**
- Create: `BeadInventory/Views/ColorMode/ColorModeView.swift`
- Modify: `BeadInventory/Views/MoreView.swift`

- [ ] **Step 1: 创建 `ColorModeView.swift`（最小骨架）**

```swift
//
//  ColorModeView.swift
//  BeadInventory
//
//  色彩模式主页面
//

import SwiftUI
import SwiftData

struct ColorModeView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \SDColorScheme.createdAt) private var allSchemes: [SDColorScheme]

    @State private var previewSchemeOverride: SwiftUI.ColorScheme?  // 🌞⇄🌜
    @State private var showingSaveDialog = false
    @State private var newName: String = ""

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                currentSchemeLabel
                swatchRow
                Divider()
                presetsSection
                Divider()
                mySchemesSection
            }
            .padding(Theme.Spacing.lg)
        }
        .navigationTitle(Text("color_mode.title"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) { resetToDefault() } label: {
                    Text("color_mode.button.reset")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    previewSchemeOverride = (previewSchemeOverride == .dark) ? .light : .dark
                } label: {
                    Image(systemName: previewSchemeOverride == .dark ? "moon.fill" : "sun.max.fill")
                }
            }
        }
        .preferredColorScheme(previewSchemeOverride)
        .background(Theme.ColorToken.Surface.background.ignoresSafeArea())
        .onAppear { themeManager.beginDraft() }
        .interactiveDismissDisabled(themeManager.isDirty)
    }

    private var currentSchemeLabel: some View {
        let activeID = themeManager.activeSchemeID
        let activeName = activeID.flatMap { id in allSchemes.first { $0.id == id }?.name } ?? ""
        return HStack {
            Text("color_mode.label.current_scheme")
                .foregroundStyle(Theme.ColorToken.Text.secondary)
            Spacer()
            Text(activeID == nil
                 ? String(localized: "color_mode.label.custom_unsaved")
                 : activeName)
                .foregroundStyle(Theme.ColorToken.Text.primary)
        }
    }

    private var swatchRow: some View { Text("[swatch row - Task 15]") }
    private var presetsSection: some View { Text("[presets - Task 16]") }
    private var mySchemesSection: some View { Text("[my schemes - Task 17]") }

    private func resetToDefault() { /* Task 18 */ }
}
```

- [ ] **Step 2: 在 MoreView 加入口**

打开 `BeadInventory/Views/MoreView.swift`，找到合适位置（紧挨"关于"行上方），追加：

```swift
NavigationLink {
    ColorModeView()
} label: {
    MoreRow(
        title: String(localized: "color_mode.title"),
        systemImage: "paintpalette"
    )
}
```

（具体 `MoreRow` 调用形式按文件中已有同构行复制；图标用 SF Symbol `paintpalette`。）

- [ ] **Step 3: Build + 手测**

```bash
xcodebuild ... build
```

启动 App → "更多" Tab → 看到"色彩模式" → 点进去 → 看到占位文本 + 重置按钮 + 🌞⇄🌜 toggle。
🌞⇄🌜 切到深色 → 本页背景与导航栏变深，退回 MoreView 仍跟随系统。

Expected: 入口可点击，页面显示标题与占位

- [ ] **Step 4: Commit**

```bash
git add BeadInventory/Views/ColorMode/ColorModeView.swift BeadInventory/Views/MoreView.swift
git commit -m "feat(theme): ColorModeView 骨架 + MoreView 入口 + 🌞⇄🌜 预览 toggle

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 15: 4 swatch 行 + ColorPicker

**Files:**
- Modify: `BeadInventory/Views/ColorMode/ColorModeView.swift`

- [ ] **Step 1: 替换 `swatchRow` 实现**

```swift
    private var swatchRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            swatchTile(slot: .lightBg,
                       label: String(localized: "color_mode.swatch.light_bg"),
                       hex: themeManager.resolvedLight.bg)
            swatchTile(slot: .lightElev,
                       label: String(localized: "color_mode.swatch.light_elev"),
                       hex: themeManager.resolvedLight.bgElev)
            swatchTile(slot: .darkBg,
                       label: String(localized: "color_mode.swatch.dark_bg"),
                       hex: themeManager.resolvedDark.bg)
            swatchTile(slot: .darkElev,
                       label: String(localized: "color_mode.swatch.dark_elev"),
                       hex: themeManager.resolvedDark.bgElev)
        }
    }

    @ViewBuilder
    private func swatchTile(slot: ThemeSlot, label: String, hex: String) -> some View {
        SwatchTile(
            label: label,
            hex: hex,
            onPick: { newHex in themeManager.updateSwatch(slot, hex: newHex) }
        )
    }
```

- [ ] **Step 2: 实现 `SwatchTile` 子组件（同文件底部）**

```swift
private struct SwatchTile: View {
    let label: String
    let hex: String
    let onPick: (String) -> Void

    @State private var showingPicker = false

    var body: some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(Color(uiColor: UIColor(themeHex: hex)))
                .frame(height: 56)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
                )
                .contentShape(Rectangle())
                .onTapGesture { showingPicker = true }
            Text(label)
                .font(Theme.Typography.metadata)
                .foregroundStyle(Theme.ColorToken.Text.secondary)
            Text("#\(hex)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.Text.tertiary)
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showingPicker) {
            SwatchPickerSheet(initialHex: hex, onCommit: { newHex in
                onPick(newHex)
                showingPicker = false
            })
            .presentationDetents([.medium])
        }
    }
}

private struct SwatchPickerSheet: View {
    let initialHex: String
    let onCommit: (String) -> Void

    @State private var color: Color

    init(initialHex: String, onCommit: @escaping (String) -> Void) {
        self.initialHex = initialHex
        self.onCommit = onCommit
        let ui = UIColor(themeHex: initialHex)
        _color = State(initialValue: Color(uiColor: ui))
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            ColorPicker("color_mode.picker.title", selection: $color, supportsOpacity: false)
                .padding()
            Spacer()
        }
        .onChange(of: color) { _, newColor in
            onCommit(newColor.toThemeHex())
        }
    }
}

extension Color {
    func toThemeHex() -> String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        let ri = Int((r * 255).rounded())
        let gi = Int((g * 255).rounded())
        let bi = Int((b * 255).rounded())
        return String(format: "%02X%02X%02X", ri, gi, bi)
    }
}
```

- [ ] **Step 3: 手测**

进入色彩模式页 → 看到 4 个 swatch → 点浅色 Bg → 弹 ColorPicker → 拖色 → 整个 App 背景实时变化 → 关闭 sheet → 标题切到"自定义（未保存）"。

- [ ] **Step 4: Commit**

```bash
git add BeadInventory/Views/ColorMode/ColorModeView.swift
git commit -m "feat(theme): 4 swatch 行 + ColorPicker sheet 实时全局生效

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 16: 预设区 + 三选一 ActionSheet

**Files:**
- Modify: `BeadInventory/Views/ColorMode/ColorModeView.swift`

- [ ] **Step 1: 实现 `presetsSection`**

```swift
    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("color_mode.section.presets")
                .font(Theme.Typography.sectionHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: Theme.Spacing.md)],
                      spacing: Theme.Spacing.md) {
                ForEach(allSchemes.filter { $0.isBuiltin }) { sd in
                    PresetCard(scheme: sd, isActive: sd.id == themeManager.activeSchemeID) {
                        pendingPreset = sd.toStruct()
                    }
                }
            }
        }
        .confirmationDialog(
            Text("color_mode.preset.apply_target_prompt"),
            isPresented: Binding(get: { pendingPreset != nil },
                                 set: { if !$0 { pendingPreset = nil } }),
            titleVisibility: .visible
        ) {
            Button("color_mode.preset.apply_both") {
                if let s = pendingPreset { themeManager.apply(scheme: s, target: .both) }
                pendingPreset = nil
            }
            Button("color_mode.preset.apply_light_only") {
                if let s = pendingPreset { themeManager.apply(scheme: s, target: .lightOnly) }
                pendingPreset = nil
            }
            Button("color_mode.preset.apply_dark_only") {
                if let s = pendingPreset { themeManager.apply(scheme: s, target: .darkOnly) }
                pendingPreset = nil
            }
            Button("common.cancel", role: .cancel) { pendingPreset = nil }
        }
    }
```

在 ColorModeView 顶部 `@State` 区加：

```swift
    @State private var pendingPreset: AppColorScheme?
```

- [ ] **Step 2: 实现 `PresetCard` 子组件（同文件）**

```swift
private struct PresetCard: View {
    let scheme: SDColorScheme
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                HStack(spacing: 0) {
                    Color(uiColor: UIColor(themeHex: scheme.lightBgHex))
                    Color(uiColor: UIColor(themeHex: scheme.lightBgElevHex))
                    Color(uiColor: UIColor(themeHex: scheme.darkBgHex))
                    Color(uiColor: UIColor(themeHex: scheme.darkBgElevHex))
                }
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, Theme.ColorToken.Interactive.primaryFallback)
                        .font(.title2)
                }
            }
            .frame(height: 56)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
            )
            Text(LocalizedStringKey(scheme.name))
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.ColorToken.Text.primary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}
```

- [ ] **Step 3: 手测**

回到色彩模式页 → 看到 5 个预设卡片，每个左右各两色（light Bg / light Elev / dark Bg / dark Elev 四等分）→ 当前选中的卡片右上角对勾 → 点"黑金" → ActionSheet 弹出三选一 → 选"仅应用深色" → 浅色不变、深色变黑金、标题切到"自定义（未保存）"。

- [ ] **Step 4: Commit**

```bash
git add BeadInventory/Views/ColorMode/ColorModeView.swift
git commit -m "feat(theme): 预设区网格 + 三选一 ActionSheet（全应用/仅浅色/仅深色）

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 17: "我的主题"区 + 保存为新主题 + ⋯ 菜单

**Files:**
- Modify: `BeadInventory/Views/ColorMode/ColorModeView.swift`

- [ ] **Step 1: 实现 `mySchemesSection`**

```swift
    private var mySchemesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("color_mode.section.my_themes")
                .font(Theme.Typography.sectionHeader)

            Button {
                newName = ""
                showingSaveDialog = true
            } label: {
                Label("color_mode.button.save_as_new", systemImage: "plus.circle")
            }
            .buttonStyle(.bordered)
            .disabled(!themeManager.isDirty)

            let myThemes = allSchemes.filter { !$0.isBuiltin }
            if myThemes.isEmpty {
                Text("color_mode.empty.no_my_themes")
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(Theme.ColorToken.Text.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: Theme.Spacing.md)],
                          spacing: Theme.Spacing.md) {
                    ForEach(myThemes) { sd in
                        MyThemeCard(
                            scheme: sd,
                            isActive: sd.id == themeManager.activeSchemeID,
                            onApply: { themeManager.apply(scheme: sd.toStruct(), target: .both) },
                            onRename: { newName in
                                sd.name = newName
                                sd.updatedAt = Date()
                                try? modelContext.save()
                            },
                            onDelete: {
                                if themeManager.activeSchemeID == sd.id {
                                    themeManager.apply(scheme: defaultCreamLatteOrFallback(), target: .both)
                                }
                                modelContext.delete(sd)
                                try? modelContext.save()
                            }
                        )
                    }
                }
            }
        }
        .alert("color_mode.dialog.save_title", isPresented: $showingSaveDialog) {
            TextField("color_mode.dialog.save_placeholder", text: $newName)
            Button("common.save") {
                let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                _ = try? themeManager.commitAsNewScheme(name: trimmed, modelContext: modelContext)
            }
            Button("common.cancel", role: .cancel) {}
        }
    }

    private func defaultCreamLatteOrFallback() -> AppColorScheme {
        if let s = allSchemes.first(where: { $0.id == UUID(uuidString: "B1A5B100-0000-0000-0000-000000000001") }) {
            return s.toStruct()
        }
        return AppColorScheme(
            id: UUID(),
            name: "color_mode.preset.cream_latte",
            light: .defaultLight, dark: .defaultDark,
            isBuiltin: true,
            createdAt: Date(), updatedAt: Date()
        )
    }
```

- [ ] **Step 2: 实现 `MyThemeCard`（同文件）**

```swift
private struct MyThemeCard: View {
    let scheme: SDColorScheme
    let isActive: Bool
    let onApply: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void

    @State private var showingRename = false
    @State private var renameDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Color(uiColor: UIColor(themeHex: scheme.lightBgHex))
                Color(uiColor: UIColor(themeHex: scheme.lightBgElevHex))
                Color(uiColor: UIColor(themeHex: scheme.darkBgHex))
                Color(uiColor: UIColor(themeHex: scheme.darkBgElevHex))
            }
            .frame(height: 56)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))

            HStack {
                Text(scheme.name)
                    .font(Theme.Typography.cardTitle)
                Spacer()
                Menu {
                    Button("color_mode.menu.apply", action: onApply)
                    Button("color_mode.menu.rename") {
                        renameDraft = scheme.name
                        showingRename = true
                    }
                    Button("color_mode.menu.delete", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .contextMenu {
            Button("color_mode.menu.apply", action: onApply)
            Button("color_mode.menu.rename") {
                renameDraft = scheme.name
                showingRename = true
            }
            Button("color_mode.menu.delete", role: .destructive, action: onDelete)
        }
        .alert("color_mode.dialog.rename_title", isPresented: $showingRename) {
            TextField("color_mode.dialog.rename_placeholder", text: $renameDraft)
            Button("common.save") {
                let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                onRename(trimmed)
            }
            Button("common.cancel", role: .cancel) {}
        }
    }
}
```

- [ ] **Step 3: 手测**

色彩模式页 → 改色 → "保存为新主题"按钮亮起 → 点 → 输入"咖啡" → 保存 → 出现"我的主题"卡片 → ⋯ 菜单 → 重命名 / 删除均生效；contextMenu 长按也能弹同样菜单。

- [ ] **Step 4: Commit**

```bash
git add BeadInventory/Views/ColorMode/ColorModeView.swift
git commit -m "feat(theme): 我的主题区 + 保存为新主题对话框 + ⋯/contextMenu

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 18: 重置按钮 + 保存/放弃 confirmationDialog

**Files:**
- Modify: `BeadInventory/Views/ColorMode/ColorModeView.swift`

- [ ] **Step 1: 实现 `resetToDefault()` + 离开页保护**

```swift
    private func resetToDefault() {
        themeManager.apply(scheme: defaultCreamLatteOrFallback(), target: .both)
    }
```

在 body 顶部加返回手势拦截，用 `NavigationStack` 的 `.toolbar` + 自定义返回按钮替换默认返回（因为 SwiftUI 默认返回手势无法在 dirty 时拦截）：

```swift
    .navigationBarBackButtonHidden(themeManager.isDirty)
    .toolbar {
        if themeManager.isDirty {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingLeaveDialog = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("common.back")
                    }
                }
            }
        }
    }
    .confirmationDialog(
        Text("color_mode.dialog.leave_title"),
        isPresented: $showingLeaveDialog,
        titleVisibility: .visible
    ) {
        Button("color_mode.button.save_as_new") {
            showingLeaveDialog = false
            newName = ""
            showingSaveDialog = true
        }
        Button("color_mode.button.discard", role: .destructive) {
            themeManager.discardDraft()
            showingLeaveDialog = false
            dismiss()
        }
        Button("common.cancel", role: .cancel) { showingLeaveDialog = false }
    }
```

新增 `@State`：

```swift
    @State private var showingLeaveDialog = false
```

并在保存对话框的"保存"按钮闭包末尾追加 `dismiss()`，让"保存为新主题"路径也自动返回上一页。

- [ ] **Step 2: 处理"切 Tab"场景**

SwiftUI 的 TabView 切换 ColorModeView 不会触发 dismiss。最朴素的方案：在 `onDisappear` 时如果 `isDirty` 则把 draft 强制 commit 落盘 `pendingDraftJSON`（已在 Task 10 完成）。下次回到此页可继续编辑或被启动恢复 alert 兜住。

不做"拦截 Tab 切换"，会过度复杂。

- [ ] **Step 3: 手测**

进入色彩模式 → 改色 → 点左上返回 → 弹三选一 → 选"保存为新主题"→ 输入名 → 保存 → 自动回到 MoreView，列表多出"咖啡"项目。
重做：进入 → 改色 → 返回 → 选"放弃改动" → 颜色还原 → 回 MoreView。

- [ ] **Step 4: Commit**

```bash
git add BeadInventory/Views/ColorMode/ColorModeView.swift
git commit -m "feat(theme): 重置 + 离开页面 confirmationDialog（保存/放弃/继续）

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

# M5. 进程恢复 UI

## Task 19: 启动期恢复 alert

**Files:**
- Modify: `BeadInventory/BeadInventoryApp.swift`（或主 ContentView）

- [ ] **Step 1: 在 root 视图加恢复 alert**

```swift
struct ContentView: View {
    @Environment(ThemeManager.self) private var themeManager
    @State private var showingRecoveryAlert = false

    var body: some View {
        TabView {
            // ... 已有 tabs ...
        }
        .onAppear {
            if themeManager.isDirty {
                showingRecoveryAlert = true
            }
        }
        .alert("color_mode.dialog.recover_title", isPresented: $showingRecoveryAlert) {
            Button("color_mode.dialog.recover_keep") { /* 留着 draft */ }
            Button("color_mode.dialog.recover_discard", role: .destructive) {
                themeManager.discardDraft()
            }
        } message: {
            Text("color_mode.dialog.recover_message")
        }
    }
}
```

- [ ] **Step 2: 手测**

色彩模式页改色 → 不保存 → 后台杀进程（模拟器 Cmd+Shift+H 两下右滑） → 重启 App → 启动 alert 弹出 → 选"放弃" → 颜色还原 → 选"保留" → 仍为修改后色，回到色彩模式可继续编辑。

- [ ] **Step 3: Commit**

```bash
git add BeadInventory/BeadInventoryApp.swift
git commit -m "feat(theme): 启动期恢复 alert（保留 / 放弃 未提交 draft）

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

# M6. 云同步

## Task 20: SDColorScheme 差量合并接入 InventoryManager 同步

**Files:**
- Modify: `BeadInventory/Managers/InventoryManager.swift`（参考 `1838-1865` 行 `SDCustomColor` 同步段）
- Create: `BeadInventoryTests/ColorSchemeSyncTests.swift`

- [ ] **Step 1: 写同步测试**

```swift
import XCTest
import SwiftData
@testable import BeadInventory

final class ColorSchemeSyncTests: XCTestCase {

    private func makeCtx() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: SDColorScheme.self, configurations: config))
    }

    func test_remoteNewScheme_pulledLocal_whenNotInBaseline() {
        // 见 InventoryManager.swift:1838-1865 同构断言
        // 这里走 InventoryManager 公共同步接口（如不易隔离，可在 InventoryManager 中
        // 抽出 syncColorSchemes(...) 内部函数后单测）
        // TODO 实测时若无法单测 InventoryManager，改成把 syncColorSchemes 抽成 free function
        XCTFail("PENDING: 接入后再补完")
    }
}
```

注：现有 `InventoryManager` 同步代码可能并非易测的纯函数。**实现前先评估**：若内部已用 closure 形式接 `SDCustomColor` 合并，可直接添加 `SDColorScheme` 分支；若需要重构，把 4-way 差量合并抽成泛型 free function `mergeSyncable<Entity>(...)` 是优解（但属于本任务额外重构）。

- [ ] **Step 2: 实现 `SDColorScheme` 同步合并**

在 `InventoryManager.swift` 现有 `SDCustomColor` 同步段后追加平行段（伪代码，需依据现有结构调整变量名）：

```swift
// === 色彩主题同步（与 SDCustomColor 同构）===
let existingSchemes = try? modelContext.fetch(FetchDescriptor<SDColorScheme>())
let existingSchemeByID = Dictionary(uniqueKeysWithValues:
    (existingSchemes ?? []).map { ($0.id, $0) })
let baselineSchemes = baselineSnapshot?.colorSchemes ?? [:]   // baseline 需补充字段

for remote in remoteColorSchemes {
    if let existing = existingSchemeByID[remote.id] {
        // 双方都有 → updatedAt 较新者胜
        if remote.updatedAt > existing.updatedAt {
            existing.name           = remote.name
            existing.lightBgHex     = remote.lightBgHex
            existing.lightBgElevHex = remote.lightBgElevHex
            existing.darkBgHex      = remote.darkBgHex
            existing.darkBgElevHex  = remote.darkBgElevHex
            existing.isBuiltin      = remote.isBuiltin
            existing.updatedAt      = remote.updatedAt
        }
    } else if baselineSchemes[remote.id] != nil {
        // baseline 有 + 本地无 = 本地已删除，跳过
        continue
    } else {
        // 远端新增 → 拉到本地
        modelContext.insert(SDColorScheme(from: remote))
    }
}

for (id, local) in existingSchemeByID {
    if remoteColorSchemes.first(where: { $0.id == id }) == nil,
       baselineSchemes[id] != nil {
        // 远端没了 + baseline 有 → 远端删除，本地同删
        modelContext.delete(local)
    }
}
```

具体的 `remoteColorSchemes` / `baselineSnapshot` 数据源接入要按 `InventoryManager` 现有 CloudKit 同步 channel（如已经为 `SDCustomColor` 拉过来，复用同一 fetch）。

- [ ] **Step 3: 测试 + 多设备手测**

两台模拟器 / 一台模拟器 + 一台真机登录同一 iCloud：
- A 保存"咖啡" → 等同步 → B 进入色彩模式 → 我的主题中出现"咖啡"
- B 重命名"咖啡" → "拿铁咖啡" → A 看到名字更新
- A 删除"拿铁咖啡" → B 看到该项消失

Expected: 跨设备一致

- [ ] **Step 4: Commit**

```bash
git add BeadInventory/Managers/InventoryManager.swift BeadInventoryTests/ColorSchemeSyncTests.swift
git commit -m "feat(theme): SDColorScheme 差量合并接入 CloudKit 同步链路

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

# M7. 国际化

## Task 21: Localizable.xcstrings 加 color_mode.* 键

**Files:**
- Modify: `BeadInventory/Localizable.xcstrings`

- [ ] **Step 1: 在 Xcode 中打开 Localizable.xcstrings，逐条添加键**

| Key | zh-Hans | en |
|---|---|---|
| `color_mode.title` | 色彩模式 | Color Mode |
| `color_mode.label.current_scheme` | 当前方案 | Current Scheme |
| `color_mode.label.custom_unsaved` | 自定义（未保存） | Custom (unsaved) |
| `color_mode.section.presets` | 预设方案 | Presets |
| `color_mode.section.my_themes` | 我的主题 | My Themes |
| `color_mode.empty.no_my_themes` | 调出喜欢的配色后，点击「保存为新主题」可加入此处 | Save a tweak as a new theme to see it here. |
| `color_mode.button.reset` | 重置 | Reset |
| `color_mode.button.save_as_new` | 保存为新主题… | Save as new theme… |
| `color_mode.button.discard` | 放弃改动 | Discard Changes |
| `color_mode.swatch.light_bg` | 浅色 Bg | Light Bg |
| `color_mode.swatch.light_elev` | 浅色 Elev | Light Elev |
| `color_mode.swatch.dark_bg` | 深色 Bg | Dark Bg |
| `color_mode.swatch.dark_elev` | 深色 Elev | Dark Elev |
| `color_mode.picker.title` | 选择颜色 | Pick Color |
| `color_mode.preset.apply_target_prompt` | 应用到哪一面？ | Apply to which mode? |
| `color_mode.preset.apply_both` | 全应用 | Apply Both |
| `color_mode.preset.apply_light_only` | 仅应用浅色 | Apply Light Only |
| `color_mode.preset.apply_dark_only` | 仅应用深色 | Apply Dark Only |
| `color_mode.preset.cream_latte` | 奶油拿铁 | Cream Latte |
| `color_mode.preset.mint_dawn` | 薄荷晨光 | Mint Dawn |
| `color_mode.preset.mist_coast` | 雾蓝海岸 | Mist Coast |
| `color_mode.preset.dusk_rose` | 暮色玫瑰 | Dusk Rose |
| `color_mode.preset.black_gold` | 黑金 | Black Gold |
| `color_mode.menu.apply` | 应用 | Apply |
| `color_mode.menu.rename` | 重命名 | Rename |
| `color_mode.menu.delete` | 删除 | Delete |
| `color_mode.dialog.save_title` | 保存为新主题 | Save as New Theme |
| `color_mode.dialog.save_placeholder` | 主题名字 | Theme name |
| `color_mode.dialog.rename_title` | 重命名 | Rename |
| `color_mode.dialog.rename_placeholder` | 新名字 | New name |
| `color_mode.dialog.leave_title` | 你有未保存的色彩改动 | You have unsaved color changes |
| `color_mode.dialog.recover_title` | 恢复上次未保存的色彩改动？ | Restore unsaved color changes? |
| `color_mode.dialog.recover_message` | 上次退出时还没保存到主题。 | These weren't saved as a theme last time. |
| `color_mode.dialog.recover_keep` | 保留 | Keep |
| `color_mode.dialog.recover_discard` | 放弃 | Discard |
| `common.save` | 保存 | Save |
| `common.cancel` | 取消 | Cancel |
| `common.back` | 返回 | Back |

（`common.*` 三个如果项目里已存在则跳过。）

- [ ] **Step 2: Build + 启动手测两个语言**

```bash
xcodebuild ... build
```

设备语言切英文 → 进入色彩模式 → 所有文案为英文。

- [ ] **Step 3: Commit**

```bash
git add BeadInventory/Localizable.xcstrings
git commit -m "feat(theme): color_mode.* 文案（zh-Hans + en）

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

# 收尾

## Task 22: 全局回归

**Files:** N/A

- [ ] **Step 1: 跑全部测试**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test
```

Expected: 全部 PASS

- [ ] **Step 2: 手测清单**

- [ ] 4 swatch 拖动 ColorPicker 60fps（Instruments → Animation Hitches）
- [ ] 改色 → 切 Tab → 返回 ColorModeView，状态保持
- [ ] 改色 → 后台杀进程 → 重启 → 恢复 alert 出现
- [ ] 浅色系统下 🌞⇄🌜 toggle 切深色预览 → ColorPicker 弹窗也跟着变
- [ ] 系统外观切换实时跟随
- [ ] iCloud 多设备同步主题
- [ ] 5 个内建预设全应用 / 仅浅色 / 仅深色 都正确
- [ ] "我的主题"重命名 / 删除生效
- [ ] 重置按钮 → 回到奶油拿铁
- [ ] 切系统语言 → 文案切换

- [ ] **Step 3: 整体提交（如果还有零散改动）**

Commit 应该已经分布在前面的任务里，本步骤只是确认 working tree 干净：

```bash
git status
```

Expected: nothing to commit, working tree clean

---

## 风险与回退

- **若 `@Observable` 在 `Theme.ColorToken` 静态访问点未能建立依赖订阅** —— 这是 §6 解析链的命门。回退方案：把 `Surface.background` 改成 `View modifier`，强制视图通过 `@Environment(ThemeManager.self)` 获取，再换成 `Color`。代价是改造面变大，但保留可行性。
- **CloudKit 同步出现重复内建** —— bootstrap 使用固定 UUID，理论上不会。若线上观察到，运行一次"清理脏内建"工具（重写 bootstrap 加 dedupe pass）。
- **ColorPicker debounce 250ms 体感卡顿** —— 改为 onChange + dispatch async + sheet onDismiss 兜底；不写 pendingDraftJSON 的中间态。
