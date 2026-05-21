# UI 设计系统重构实施计划（BIDS v1）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落地 [BIDS 设计系统设计文档](../specs/2026-05-20-ui-design-system-refactor-design.md)：三层颜色 Token、`Views/DesignSystem/` 组件库、六条交互公约。

**Architecture:** 渐进式 9-commit 重构。先建 Theme/调色板基础（无视觉变化），再注入 Tab 风味色，然后逐批抽取共享组件并迁移调用点，最后落地多选 / 扫描 / 导航 / 触觉四类交互改造。每个 commit 自包含、可编译、可单独回归。

**Tech Stack:** Swift 5.9+ / SwiftUI / SwiftData / Xcode 15+ / iOS 17+

**关键文件参考：**
- 设计文档：`docs/superpowers/specs/2026-05-20-ui-design-system-refactor-design.md`
- 测试 target：`BeadInventoryTests/`（已存在但稀疏）
- 已有共享组件：`BeadInventory/Views/Components/` (`EmptyStateView`, `BrandPicker`, `DeductionItemRow`, `SimilarColorSheet`)
- 新建设计系统目录：`BeadInventory/Views/DesignSystem/`
- 资源目录：`BeadInventory/Assets.xcassets/`

**执行约定：**
- 每个 Task 对应一个 commit。
- "编译验证" 命令：`xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory -destination 'platform=iOS Simulator,name=iPhone 16' build`（下文简写为 `BUILD_CMD`）。
- "运行验证" 必要时启动模拟器人工对照截图；本计划中明确指出验证点。
- 视觉回归 baseline：在执行 Task 1 前，先在 main 分支跑一遍模拟器截图存档（5 Tab + 主要 Sheet）。
- **禁止跳过任何"验证步骤"**。如果编译失败先停下来修，不要进下一步。

---

## Task 0：建立视觉基线（一次性，非 commit）

**Files:**
- 临时输出目录：`~/Desktop/bids-baseline-screenshots/`（不入仓）

- [ ] **Step 1：在 main 分支用模拟器对每个 Tab 截一张图**

   操作步骤：在 Xcode 选 iPhone 16 模拟器跑起来 → 依次切到库存 / 扫描 / 计划 / 统计 / 更多 5 个 Tab → 每个截一张图保存到 `~/Desktop/bids-baseline-screenshots/`，文件名 `01-inventory.png` … `05-more.png`。

- [ ] **Step 2：再补 4 张关键 Sheet 截图**

   分别打开并截图：
   - 库存"+"FAB → AddInventoryView：`06-add-inventory.png`
   - 库存色号 tap → EditStockSheet：`07-edit-stock.png`
   - 扫描手动录入 → ManualEntrySheet：`08-manual-entry.png`
   - 更多 → 设置 → SettingsView：`09-settings.png`

- [ ] **Step 3：确认 baseline 已经全部存档**

   ```bash
   ls -1 ~/Desktop/bids-baseline-screenshots/ | wc -l
   ```
   期望输出：`9`

后续每个 Task 完成后，对照同一视图重新截图，确认"语义一致、风味色合理变更、布局零回归"。

---

## Task 1：Theme 基础 + Asset Catalog 调色板与语义色集

**Files:**
- Create: `BeadInventory/Views/DesignSystem/Theme.swift`
- Create: `BeadInventory/Assets.xcassets/Palette/Contents.json`
- Create: `BeadInventory/Assets.xcassets/Palette/Peach.colorset/Contents.json`
- Create: `BeadInventory/Assets.xcassets/Palette/Coral.colorset/Contents.json`
- Create: `BeadInventory/Assets.xcassets/Palette/Lavender.colorset/Contents.json`
- Create: `BeadInventory/Assets.xcassets/Palette/Mint.colorset/Contents.json`
- Create: `BeadInventory/Assets.xcassets/Palette/Sky.colorset/Contents.json`
- Create: `BeadInventory/Assets.xcassets/Palette/Lemon.colorset/Contents.json`
- Create: `BeadInventory/Assets.xcassets/Palette/Rose.colorset/Contents.json`
- Create: `BeadInventory/Assets.xcassets/Palette/Neutral50.colorset/Contents.json`（同样 100/200/400/600/900 五档）
- Create: `BeadInventory/Assets.xcassets/Palette/Neutral100.colorset/Contents.json`
- Create: `BeadInventory/Assets.xcassets/Palette/Neutral200.colorset/Contents.json`
- Create: `BeadInventory/Assets.xcassets/Palette/Neutral400.colorset/Contents.json`
- Create: `BeadInventory/Assets.xcassets/Palette/Neutral600.colorset/Contents.json`
- Create: `BeadInventory/Assets.xcassets/Palette/Neutral900.colorset/Contents.json`
- Create: `BeadInventory/Assets.xcassets/Semantic/Contents.json`
- Create: `BeadInventory/Assets.xcassets/Semantic/Success.colorset/Contents.json`
- Create: `BeadInventory/Assets.xcassets/Semantic/Warning.colorset/Contents.json`
- Create: `BeadInventory/Assets.xcassets/Semantic/Error.colorset/Contents.json`
- Create: `BeadInventory/Assets.xcassets/Semantic/Info.colorset/Contents.json`
- Test: `BeadInventoryTests/ThemeTests.swift`

**目标：建立基础 token 体系，无视觉变化（旧调用点没动）。本 commit 不动任何 Views/*.swift。**

- [ ] **Step 1：建 Palette 与 Semantic 子文件夹的 namespace 占位**

   每个子文件夹根目录写 `Contents.json`：

   `BeadInventory/Assets.xcassets/Palette/Contents.json`:
   ```json
   {
     "info" : {
       "author" : "xcode",
       "version" : 1
     },
     "properties" : {
       "provides-namespace" : true
     }
   }
   ```

   `BeadInventory/Assets.xcassets/Semantic/Contents.json`: 内容相同。

- [ ] **Step 2：写七个风味色 + 储备色的 colorset**

   每个 colorset 是一个目录，包含一个 `Contents.json`。模板（Light + Dark 两套）：

   ```json
   {
     "colors" : [
       {
         "color" : {
           "color-space" : "srgb",
           "components" : {
             "alpha" : "1.000",
             "red"   : "{R_LIGHT}",
             "green" : "{G_LIGHT}",
             "blue"  : "{B_LIGHT}"
           }
         },
         "idiom" : "universal"
       },
       {
         "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ],
         "color" : {
           "color-space" : "srgb",
           "components" : {
             "alpha" : "1.000",
             "red"   : "{R_DARK}",
             "green" : "{G_DARK}",
             "blue"  : "{B_DARK}"
           }
         },
         "idiom" : "universal"
       }
     ],
     "info" : { "author" : "xcode", "version" : 1 }
   }
   ```

   填入下列七组数值（srgb 浮点 0–1）：

   | 命名 | Light RGB | Dark RGB |
   |---|---|---|
   | Peach    | 0.984 / 0.612 / 0.616 | 0.984 / 0.682 / 0.686 |
   | Coral    | 0.984 / 0.541 / 0.396 | 0.984 / 0.612 / 0.467 |
   | Lavender | 0.737 / 0.671 / 0.953 | 0.792 / 0.722 / 0.961 |
   | Mint     | 0.529 / 0.835 / 0.741 | 0.580 / 0.871 / 0.788 |
   | Sky      | 0.471 / 0.745 / 0.949 | 0.561 / 0.792 / 0.961 |
   | Lemon    | 0.984 / 0.871 / 0.490 | 0.984 / 0.894 / 0.561 |
   | Rose     | 0.953 / 0.522 / 0.682 | 0.961 / 0.604 / 0.737 |

- [ ] **Step 3：写五档中性灰**

   命名 `Neutral50/100/200/400/600/900`，6 个 colorset，同样的模板。值：

   | 命名 | Light RGB | Dark RGB |
   |---|---|---|
   | Neutral50  | 0.969 / 0.969 / 0.969 | 0.106 / 0.106 / 0.114 |
   | Neutral100 | 0.937 / 0.937 / 0.941 | 0.149 / 0.149 / 0.157 |
   | Neutral200 | 0.878 / 0.878 / 0.882 | 0.231 / 0.231 / 0.239 |
   | Neutral400 | 0.624 / 0.624 / 0.631 | 0.514 / 0.514 / 0.525 |
   | Neutral600 | 0.388 / 0.388 / 0.400 | 0.722 / 0.722 / 0.733 |
   | Neutral900 | 0.110 / 0.110 / 0.118 | 0.949 / 0.949 / 0.953 |

- [ ] **Step 4：写四个语义色 colorset（Success/Warning/Error/Info）**

   | 命名 | Light RGB | Dark RGB |
   |---|---|---|
   | Success | 0.298 / 0.741 / 0.522 | 0.376 / 0.804 / 0.580 |
   | Warning | 0.984 / 0.694 / 0.298 | 0.988 / 0.749 / 0.404 |
   | Error   | 0.910 / 0.349 / 0.349 | 0.937 / 0.439 / 0.439 |
   | Info    | 0.314 / 0.620 / 0.918 | 0.439 / 0.694 / 0.937 |

- [ ] **Step 5：创建 `Theme.swift`**

   `BeadInventory/Views/DesignSystem/Theme.swift`:

   ```swift
   import SwiftUI

   enum Theme {

       // MARK: - Spacing
       enum Spacing {
           static let xs:  CGFloat = 4
           static let sm:  CGFloat = 8
           static let md:  CGFloat = 12
           static let lg:  CGFloat = 16
           static let xl:  CGFloat = 20
           static let xxl: CGFloat = 24
       }

       // MARK: - Radius
       enum Radius {
           static let sm:   CGFloat = 8
           static let md:   CGFloat = 12
           static let lg:   CGFloat = 16
           static let pill: CGFloat = 999
       }

       // MARK: - Typography
       enum Typography {
           static let pageTitle:     Font = .largeTitle.weight(.bold)
           static let sectionHeader: Font = .headline
           static let cardTitle:     Font = .title3.weight(.semibold)
           static let body:          Font = .body
           static let metadata:      Font = .caption
           static let number:        Font = .title2.monospacedDigit().weight(.semibold)
       }

       // MARK: - Color tokens
       enum ColorToken {

           // Palette accessors（仅 Theme 内部可访问，业务代码不应直接用）
           fileprivate enum Palette {
               static let peach    = Color("Palette/Peach")
               static let coral    = Color("Palette/Coral")
               static let lavender = Color("Palette/Lavender")
               static let mint     = Color("Palette/Mint")
               static let sky      = Color("Palette/Sky")
               static let lemon    = Color("Palette/Lemon")
               static let rose     = Color("Palette/Rose")

               static let n50  = Color("Palette/Neutral50")
               static let n100 = Color("Palette/Neutral100")
               static let n200 = Color("Palette/Neutral200")
               static let n400 = Color("Palette/Neutral400")
               static let n600 = Color("Palette/Neutral600")
               static let n900 = Color("Palette/Neutral900")
           }

           // Semantic tokens
           enum Status {
               static let success = Color("Semantic/Success")
               static let warning = Color("Semantic/Warning")
               static let error   = Color("Semantic/Error")
               static let info    = Color("Semantic/Info")
           }

           enum Text {
               static let primary   = Palette.n900
               static let secondary = Palette.n600
               static let tertiary  = Palette.n400
               static let onAccent  = Color.white
           }

           enum Surface {
               static let background = Color(.systemGroupedBackground)
               static let elevated   = Color(.systemBackground)
               static let subtle     = Palette.n50
           }

           enum Border {
               static let `default` = Palette.n200
               static let divider   = Palette.n100
               // emphasis 依赖 TabFlavor，留到 Task 2 再补
           }

           enum Interactive {
               // primary / secondary 依赖 TabFlavor 环境，留到 Task 2
               static let destructive = Status.error
           }
       }
   }
   ```

- [ ] **Step 6：写 `ThemeTests.swift` —— 断言 token 不为透明色（兜底 asset 名拼写）**

   `BeadInventoryTests/ThemeTests.swift`:
   ```swift
   import XCTest
   import SwiftUI
   @testable import BeadInventory

   final class ThemeTests: XCTestCase {

       func test_status_tokens_are_resolvable() {
           // 不严格比颜色值，只要不是默认的 placeholder 即可
           let tokens: [Color] = [
               Theme.ColorToken.Status.success,
               Theme.ColorToken.Status.warning,
               Theme.ColorToken.Status.error,
               Theme.ColorToken.Status.info,
               Theme.ColorToken.Surface.background,
               Theme.ColorToken.Surface.elevated,
               Theme.ColorToken.Surface.subtle,
               Theme.ColorToken.Text.primary,
               Theme.ColorToken.Text.secondary,
               Theme.ColorToken.Text.tertiary,
               Theme.ColorToken.Border.default,
               Theme.ColorToken.Border.divider,
           ]
           XCTAssertEqual(tokens.count, 12, "全部 token 都应被引用")
       }

       func test_spacing_scale_monotonic() {
           XCTAssertLessThan(Theme.Spacing.xs, Theme.Spacing.sm)
           XCTAssertLessThan(Theme.Spacing.sm, Theme.Spacing.md)
           XCTAssertLessThan(Theme.Spacing.md, Theme.Spacing.lg)
           XCTAssertLessThan(Theme.Spacing.lg, Theme.Spacing.xl)
           XCTAssertLessThan(Theme.Spacing.xl, Theme.Spacing.xxl)
       }

       func test_radius_scale_monotonic() {
           XCTAssertLessThan(Theme.Radius.sm, Theme.Radius.md)
           XCTAssertLessThan(Theme.Radius.md, Theme.Radius.lg)
           XCTAssertLessThan(Theme.Radius.lg, Theme.Radius.pill)
       }
   }
   ```

- [ ] **Step 7：把 `Theme.swift` 和 `ThemeTests.swift` 加入 Xcode 工程的对应 target**

   用 Xcode 打开 `BeadInventory.xcodeproj`，把 `Theme.swift` 拖入 `BeadInventory` target（Group 路径 `Views/DesignSystem`），把 `ThemeTests.swift` 拖入 `BeadInventoryTests` target。Xcode 不会自动识别新 colorset，但 `xcassets` 文件夹整体已经在 target 里，新增的 colorset 子目录会被自动包含。

- [ ] **Step 8：编译并跑测试**

   ```bash
   xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
       -destination 'platform=iOS Simulator,name=iPhone 16' build
   ```
   期望：BUILD SUCCEEDED。

   ```bash
   xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
       -destination 'platform=iOS Simulator,name=iPhone 16' test
   ```
   期望：`ThemeTests` 3 个用例全部 PASS。

- [ ] **Step 9：跑模拟器对比 baseline**

   重新跑模拟器，依次截 5 个 Tab 与 4 个 Sheet。逐张与 `~/Desktop/bids-baseline-screenshots/` 对比 —— **应当看不出任何区别**（没动 Views）。

- [ ] **Step 10：Commit**

   ```bash
   git add BeadInventory/Views/DesignSystem/Theme.swift \
           BeadInventory/Assets.xcassets/Palette \
           BeadInventory/Assets.xcassets/Semantic \
           BeadInventoryTests/ThemeTests.swift \
           BeadInventory.xcodeproj/project.pbxproj
   git commit -m "feat(theme): 引入 Theme.swift + Asset Catalog 调色板与语义色集

   建立 BIDS v1 的基础调色板（7 风味色 + 6 灰阶）和 4 个语义色，封装
   Spacing/Radius/Typography/ColorToken 四类 token。本 commit 仅新增，不
   迁移业务代码，视觉应当无差异。

   Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
   ```

---

## Task 2：TabFlavor 环境注入 + TabBar 跟随选中 tint

**Files:**
- Create: `BeadInventory/Views/DesignSystem/TabFlavor.swift`
- Modify: `BeadInventory/Views/DesignSystem/Theme.swift`（补 `Interactive.primary/secondary` 与 `Border.emphasis` 的环境读取版本）
- Modify: `BeadInventory/ContentView.swift`（注入风味色 + TabBar tint 跟随）
- Test: `BeadInventoryTests/TabFlavorTests.swift`

**目标：让 5 个 Tab 各自带专属"风味色"，TabBar 选中色跟着变。其余视图保持原样（主按钮还没接，到 Task 4 再接）。**

- [ ] **Step 1：创建 `TabFlavor.swift`**

   `BeadInventory/Views/DesignSystem/TabFlavor.swift`:
   ```swift
   import SwiftUI

   /// 5 个 Tab 的"风味色"，仅作用于：TabBar 选中色、FAB、空状态、页眉强调、Interactive.primary。
   enum TabFlavor: Int, CaseIterable {
       case inventory = 0
       case scan      = 1
       case plan      = 2
       case statistics = 3
       case more      = 4

       var color: Color {
           switch self {
           case .inventory:  return Color("Palette/Peach")
           case .scan:       return Color("Palette/Coral")
           case .plan:       return Color("Palette/Lavender")
           case .statistics: return Color("Palette/Mint")
           case .more:       return Color("Palette/Sky")
           }
       }
   }

   private struct TabFlavorKey: EnvironmentKey {
       static let defaultValue: TabFlavor = .inventory
   }

   extension EnvironmentValues {
       var tabFlavor: TabFlavor {
           get { self[TabFlavorKey.self] }
           set { self[TabFlavorKey.self] = newValue }
       }
   }
   ```

- [ ] **Step 2：在 `Theme.swift` 补"读取环境的颜色访问 ViewModifier"**

   在 `Theme.swift` 末尾追加：

   ```swift
   // MARK: - 环境感知颜色访问

   /// 用法：`.foregroundStyle(.themePrimary)` —— 在 View 修饰链中拿到当前 Tab 风味色
   extension ShapeStyle where Self == Color {
       static var themePrimary: Color { @Environment(\.tabFlavor) var f; return f.color } // 占位写法不行
   }
   ```

   ⚠️ SwiftUI 的 `extension ShapeStyle` 不能直接读环境。改用 ViewModifier + Helper View：

   覆盖上面那段，写成：

   ```swift
   // MARK: - 环境感知颜色访问

   /// 用 SwiftUI 视图修饰链拿到当前 Tab 风味色：
   ///   `BIPrimaryButton(...)` 内部 `@Environment(\.tabFlavor) var flavor`，
   ///   然后 `flavor.color` 即可。
   ///
   /// 这里不需要再封 helper —— 直接用 `@Environment(\.tabFlavor)` 就够。

   extension Theme.ColorToken.Interactive {
       /// 业务代码请用 `@Environment(\.tabFlavor)` 自行读取后再 `.color`。
       /// 这里只暴露非环境感知的兜底色，深层 push 视图意外丢失环境时用。
       static var primaryFallback: Color { Color("Palette/Peach") }
       static var secondary:       Color { Color("Palette/Neutral200") }
   }

   extension Theme.ColorToken.Border {
       static var emphasisFallback: Color { Color("Palette/Peach") }
   }
   ```

- [ ] **Step 3：改 `ContentView.swift` — 给每个 Tab 注入 flavor + TabBar tint 跟随**

   先 grep 当前 `ContentView.swift` 看 TabView 结构：

   ```bash
   grep -n "TabView\|.tag(\|.tabItem" BeadInventory/ContentView.swift
   ```

   预期能看到 `TabView(selection: $selectedTab)` 与 5 个 `.tag(0..4)`。

   编辑 `ContentView.swift`：

   1. 找到 `TabView(selection: $selectedTab) { ... }` 的整段。
   2. 在每个子 View 后面加 `.environment(\.tabFlavor, .inventory)` 等。例如：
      ```swift
      InventoryView()
          .environment(\.tabFlavor, .inventory)
          .tabItem { Label("库存", systemImage: "square.grid.3x3.fill") }
          .tag(0)
      ```
      对 5 个 Tab 都加。
   3. 把外层 `.tint(Color("AccentColor"))` 改成基于当前选中 Tab：
      ```swift
      let currentFlavor = TabFlavor(rawValue: selectedTab) ?? .inventory
      TabView(selection: $selectedTab) { ... }
          .tint(currentFlavor.color)
      ```

   完整改动样例（贴在 `ContentView.swift` 适当位置）：
   ```swift
   var body: some View {
       let currentFlavor = TabFlavor(rawValue: selectedTab) ?? .inventory
       ZStack(alignment: .bottomTrailing) {
           TabView(selection: $selectedTab) {
               InventoryView()
                   .environment(\.tabFlavor, .inventory)
                   .tabItem { Label("库存", systemImage: "square.grid.3x3.fill") }
                   .tag(0)
               ScanView()
                   .environment(\.tabFlavor, .scan)
                   .tabItem { Label("扫描", systemImage: "doc.text.viewfinder") }
                   .tag(1)
               PlannedProjectsView()
                   .environment(\.tabFlavor, .plan)
                   .tabItem { Label("计划", systemImage: "calendar.badge.clock") }
                   .tag(2)
               StatisticsView()
                   .environment(\.tabFlavor, .statistics)
                   .tabItem { Label("统计", systemImage: "chart.bar.fill") }
                   .tag(3)
               MoreView()
                   .environment(\.tabFlavor, .more)
                   .tabItem { Label("更多", systemImage: "ellipsis.circle.fill") }
                   .tag(4)
           }
           .tint(currentFlavor.color)
           // ... 保留原 FAB 等 overlay
       }
   }
   ```

   ⚠️ 如果原来 FAB 也用了 `Color("AccentColor")`，本 commit **暂不动**，留到 Task 3 / 4 迁移到 BIPrimaryButton 时再换。

- [ ] **Step 4：写 `TabFlavorTests.swift`**

   `BeadInventoryTests/TabFlavorTests.swift`:
   ```swift
   import XCTest
   import SwiftUI
   @testable import BeadInventory

   final class TabFlavorTests: XCTestCase {
       func test_rawValues_match_tab_indices() {
           XCTAssertEqual(TabFlavor.inventory.rawValue, 0)
           XCTAssertEqual(TabFlavor.scan.rawValue, 1)
           XCTAssertEqual(TabFlavor.plan.rawValue, 2)
           XCTAssertEqual(TabFlavor.statistics.rawValue, 3)
           XCTAssertEqual(TabFlavor.more.rawValue, 4)
       }

       func test_all_flavors_resolve_to_distinct_assets() {
           // 不比对具体颜色值，仅断言全部能拿到 Color 且枚举完整
           XCTAssertEqual(TabFlavor.allCases.count, 5)
       }
   }
   ```

- [ ] **Step 5：把新文件加入工程**

   Xcode 把 `TabFlavor.swift` 加入 BeadInventory target，`TabFlavorTests.swift` 加入 BeadInventoryTests target。

- [ ] **Step 6：编译 + 测试**

   ```bash
   xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
       -destination 'platform=iOS Simulator,name=iPhone 16' build
   ```
   期望：BUILD SUCCEEDED。

   ```bash
   xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
       -destination 'platform=iOS Simulator,name=iPhone 16' test
   ```
   期望：TabFlavorTests 2 个用例 + ThemeTests 3 个用例全部 PASS。

- [ ] **Step 7：模拟器手动验证**

   打开模拟器，依次点 5 个 Tab，**观察 TabBar 选中色随之变化**：库存=桃粉、扫描=珊瑚、计划=薰衣草、统计=薄荷、更多=天蓝。其它视图内容应当与 baseline 一致（FAB 还是原来的紫蓝，主按钮还没换，那是 Task 4 的事）。

- [ ] **Step 8：Commit**

   ```bash
   git add BeadInventory/Views/DesignSystem/TabFlavor.swift \
           BeadInventory/Views/DesignSystem/Theme.swift \
           BeadInventory/ContentView.swift \
           BeadInventoryTests/TabFlavorTests.swift \
           BeadInventory.xcodeproj/project.pbxproj
   git commit -m "feat(theme): TabFlavor 环境注入 + TabBar 跟随选中 tint

   每个 Tab 注入专属风味色（Peach/Coral/Lavender/Mint/Sky），TabBar 选中
   色随当前 Tab 切换。业务视图的主按钮 / FAB 暂未接入，留到 Task 4。

   Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
   ```

---

## Task 3：BIRow / BIBadge / BIColorSwatch 抽取与核心迁移

**Files:**
- Create: `BeadInventory/Views/DesignSystem/Components/BIRow.swift`
- Create: `BeadInventory/Views/DesignSystem/Components/BIBadge.swift`
- Create: `BeadInventory/Views/DesignSystem/Components/BIColorSwatch.swift`
- Modify: `BeadInventory/Views/InventoryView.swift`（迁移主列表行/网格 cell 中的 swatch 与 badge）
- Modify: `BeadInventory/Views/PlannedProjectsView.swift`（迁移项目卡片内的色号 row 与状态 badge）
- Modify: `BeadInventory/Views/StatisticsView.swift`（迁移色号使用排行的 row）
- Test: `BeadInventoryTests/DesignSystemComponentsTests.swift`

**目标：抽出 3 个最高复用度的视觉组件，把 3 个 Tab 主页面的"列表行"和"徽章/色块"切到新组件。Sheet 类深层视图本任务不动，留到 Task 8 兜底。**

- [ ] **Step 1：先写 `BIBadge`（最简单的）**

   `BeadInventory/Views/DesignSystem/Components/BIBadge.swift`:
   ```swift
   import SwiftUI

   enum BIBadgeStyle {
       case success, warning, error, info, accent, neutral
       case custom(background: Color, foreground: Color)
   }

   struct BIBadge: View {
       let text: String
       let style: BIBadgeStyle

       @Environment(\.tabFlavor) private var flavor

       init(_ text: String, style: BIBadgeStyle = .neutral) {
           self.text = text
           self.style = style
       }

       var body: some View {
           Text(text)
               .font(Theme.Typography.metadata)
               .foregroundStyle(foreground)
               .padding(.horizontal, Theme.Spacing.md)
               .padding(.vertical, Theme.Spacing.xs)
               .background(background, in: RoundedRectangle(cornerRadius: Theme.Radius.pill))
       }

       private var background: Color {
           switch style {
           case .success: return Theme.ColorToken.Status.success.opacity(0.18)
           case .warning: return Theme.ColorToken.Status.warning.opacity(0.18)
           case .error:   return Theme.ColorToken.Status.error.opacity(0.18)
           case .info:    return Theme.ColorToken.Status.info.opacity(0.18)
           case .accent:  return flavor.color.opacity(0.18)
           case .neutral: return Theme.ColorToken.Surface.subtle
           case .custom(let bg, _): return bg
           }
       }
       private var foreground: Color {
           switch style {
           case .success: return Theme.ColorToken.Status.success
           case .warning: return Theme.ColorToken.Status.warning
           case .error:   return Theme.ColorToken.Status.error
           case .info:    return Theme.ColorToken.Status.info
           case .accent:  return flavor.color
           case .neutral: return Theme.ColorToken.Text.secondary
           case .custom(_, let fg): return fg
           }
       }
   }

   #Preview {
       VStack(spacing: 8) {
           BIBadge("成功", style: .success)
           BIBadge("低库存", style: .warning)
           BIBadge("不足", style: .error)
           BIBadge("提示", style: .info)
           BIBadge("强调", style: .accent)
           BIBadge("中性", style: .neutral)
       }
       .padding()
   }
   ```

- [ ] **Step 2：写 `BIColorSwatch`**

   `BeadInventory/Views/DesignSystem/Components/BIColorSwatch.swift`:
   ```swift
   import SwiftUI

   /// 拼豆色号方块。内置文字明度自适应。
   struct BIColorSwatch: View {
       let hex: String
       let code: String?
       let size: CGFloat

       init(hex: String, code: String? = nil, size: CGFloat = 40) {
           self.hex = hex
           self.code = code
           self.size = size
       }

       var body: some View {
           let fill = Color(hex: hex) ?? Theme.ColorToken.Surface.subtle
           ZStack {
               RoundedRectangle(cornerRadius: Theme.Radius.sm)
                   .fill(fill)
                   .frame(width: size, height: size)
                   .overlay(
                       RoundedRectangle(cornerRadius: Theme.Radius.sm)
                           .stroke(Theme.ColorToken.Border.default, lineWidth: 0.5)
                   )
               if let code {
                   Text(code)
                       .font(.system(size: size * 0.28, weight: .semibold, design: .monospaced))
                       .foregroundStyle(textColor(on: fill))
               }
           }
       }

       private func textColor(on background: Color) -> Color {
           // 简化：用 UIColor 亮度近似
           let ui = UIColor(background)
           var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
           ui.getRed(&r, green: &g, blue: &b, alpha: &a)
           let luminance = 0.299*r + 0.587*g + 0.114*b
           return luminance > 0.6 ? .black : .white
       }
   }

   #Preview {
       HStack {
           BIColorSwatch(hex: "#FF6B9D", code: "H1")
           BIColorSwatch(hex: "#FFFFFF", code: "W1")
           BIColorSwatch(hex: "#000000", code: "K1")
           BIColorSwatch(hex: "#A0C8E8", code: "B5", size: 56)
       }
       .padding()
   }
   ```

   ⚠️ 该组件依赖一个 `Color(hex:)` init。grep 看是否已存在：
   ```bash
   grep -rn "init(hex:" BeadInventory --include="*.swift" | head -5
   ```
   若已有（很可能在 `CustomColorEditView.swift` 周边），直接复用。若不存在，把下面这段贴到 `BIColorSwatch.swift` 末尾：

   ```swift
   private extension Color {
       init?(hex: String) {
           let s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
                       .replacingOccurrences(of: "#", with: "")
           guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
           self.init(
               red:   Double((v >> 16) & 0xFF) / 255,
               green: Double((v >>  8) & 0xFF) / 255,
               blue:  Double( v        & 0xFF) / 255
           )
       }
   }
   ```

- [ ] **Step 3：写 `BIRow`**

   `BeadInventory/Views/DesignSystem/Components/BIRow.swift`:
   ```swift
   import SwiftUI

   /// 通用列表行：leading + title/subtitle + trailing。
   /// 三个 slot 都可选；padding/spacing 走 Theme 常量。
   struct BIRow<Leading: View, Trailing: View>: View {
       private let title: String
       private let subtitle: String?
       private let leading: () -> Leading
       private let trailing: () -> Trailing

       init(
           title: String,
           subtitle: String? = nil,
           @ViewBuilder leading: @escaping () -> Leading = { EmptyView() },
           @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
       ) {
           self.title = title
           self.subtitle = subtitle
           self.leading = leading
           self.trailing = trailing
       }

       var body: some View {
           HStack(spacing: Theme.Spacing.md) {
               leading()
               VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                   Text(title)
                       .font(Theme.Typography.body)
                       .foregroundStyle(Theme.ColorToken.Text.primary)
                   if let subtitle {
                       Text(subtitle)
                           .font(Theme.Typography.metadata)
                           .foregroundStyle(Theme.ColorToken.Text.secondary)
                   }
               }
               Spacer(minLength: 0)
               trailing()
           }
           .padding(.vertical, Theme.Spacing.sm)
       }
   }

   #Preview {
       List {
           BIRow(title: "DA001", subtitle: "玫瑰红 · 库存 200") {
               BIColorSwatch(hex: "#FF6B9D", code: "DA1", size: 32)
           } trailing: {
               BIBadge("低", style: .warning)
           }
           BIRow(title: "项目示例", subtitle: "12 色 · 计划中") {
               Image(systemName: "calendar.badge.clock")
                   .foregroundStyle(Theme.ColorToken.Status.info)
           } trailing: {
               BIBadge("进行中", style: .info)
           }
       }
   }
   ```

- [ ] **Step 4：编译验证组件本身**

   把三个新文件加入 Xcode target，跑 `BUILD_CMD`。期望 BUILD SUCCEEDED。

- [ ] **Step 5：写组件单元测试**

   `BeadInventoryTests/DesignSystemComponentsTests.swift`:
   ```swift
   import XCTest
   import SwiftUI
   @testable import BeadInventory

   final class DesignSystemComponentsTests: XCTestCase {
       func test_badge_renders_each_style() throws {
           // 仅断言 View 可被实例化（编译期）
           _ = BIBadge("ok",   style: .success)
           _ = BIBadge("warn", style: .warning)
           _ = BIBadge("err",  style: .error)
           _ = BIBadge("info", style: .info)
           _ = BIBadge("acc",  style: .accent)
           _ = BIBadge("",     style: .neutral)
       }

       func test_color_swatch_handles_invalid_hex() throws {
           // 不应崩溃
           _ = BIColorSwatch(hex: "not-a-hex", code: "?")
       }

       func test_row_with_all_slots() throws {
           _ = BIRow(title: "a", subtitle: "b") {
               Image(systemName: "star")
           } trailing: {
               BIBadge("ok", style: .success)
           }
       }
   }
   ```

- [ ] **Step 6：迁移 InventoryView 中色号网格 cell 的徽章**

   先 grep 定位旧色号徽章 / 低库存 badge：
   ```bash
   grep -n "padding(.horizontal, 12)\|padding(.vertical, 6)\|cornerRadius(16)" BeadInventory/Views/InventoryView.swift
   ```

   找到的"色号 badge"模式（约 InventoryView:195–216）— 把如下形式：
   ```swift
   Text(code)
       .font(.caption)
       .padding(.horizontal, 12)
       .padding(.vertical, 6)
       .background(Color.accentColor.opacity(0.15))
       .cornerRadius(16)
   ```
   替换为：
   ```swift
   BIBadge(code, style: .accent)
   ```

   找到"低库存"提示（用 orange）改为：
   ```swift
   BIBadge("低库存", style: .warning)
   ```

   找到色号小色块（手写的 RoundedRectangle + fill）替换为：
   ```swift
   BIColorSwatch(hex: color.hex, code: color.code, size: 40)
   ```

   每改一处编译一次（`BUILD_CMD`）。

- [ ] **Step 7：迁移 InventoryView 列表行整体到 `BIRow`（如果可行）**

   只在"形态简单"的列表行（一行 title + 一行 subtitle + 右侧 badge）做迁移；复杂行（带多列数字、可编辑控件）**不强行**塞进 `BIRow`，保留原状即可 —— `BIRow` 的目标是 DRY，不是消灭所有列表行。

   完成后 `BUILD_CMD`。

- [ ] **Step 8：迁移 PlannedProjectsView 中色号 row 与状态 badge**

   ```bash
   grep -n "padding(.horizontal, 12)\|cornerRadius(16)" BeadInventory/Views/PlannedProjectsView.swift
   ```

   把项目卡片内"已用/总量"类徽章换成 `BIBadge`；把展开列表里的色号小行换成 `BIRow + BIColorSwatch`。同样不强求 100% 迁移，覆盖主流形态即可。

   `BUILD_CMD`。

- [ ] **Step 9：迁移 StatisticsView 中色号使用排行 row**

   把"色号 + 使用量 + 百分比"的行迁到 `BIRow` 形式：leading = BIColorSwatch，title = 色号，subtitle = 名称，trailing = `BIBadge(percent + "%", style: .info)`。

   `BUILD_CMD`。

- [ ] **Step 10：模拟器视觉回归**

   依次截库存 / 计划 / 统计三个 Tab，与 baseline 对比。允许变化点：色号 badge 字号/圆角细节、低库存色彩从原始 `.orange` 调到 `Status.warning`。**布局尺寸不应漂移**（行高、缩进、间距视觉上一致）。

- [ ] **Step 11：跑测试**

   ```bash
   xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
       -destination 'platform=iOS Simulator,name=iPhone 16' test
   ```
   期望：本任务的 `DesignSystemComponentsTests` 3 用例 + 上游全部 PASS。

- [ ] **Step 12：Commit**

   ```bash
   git add BeadInventory/Views/DesignSystem/Components/ \
           BeadInventory/Views/InventoryView.swift \
           BeadInventory/Views/PlannedProjectsView.swift \
           BeadInventory/Views/StatisticsView.swift \
           BeadInventoryTests/DesignSystemComponentsTests.swift \
           BeadInventory.xcodeproj/project.pbxproj
   git commit -m "refactor(ds): 抽 BIRow / BIBadge / BIColorSwatch 并迁移核心调用点

   抽取 3 个高复用度组件到 Views/DesignSystem/Components/，迁移库存/计划/
   统计三个 Tab 主页面的色号 badge、低库存徽章与色块。Sheet 类深层视图
   留到 Task 8 兜底。

   Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
   ```

---

## Task 4：BIStatCard + BIPrimary/Secondary/DestructiveButton

**Files:**
- Create: `BeadInventory/Views/DesignSystem/Components/BIStatCard.swift`
- Create: `BeadInventory/Views/DesignSystem/Components/BIPrimaryButton.swift`
- Create: `BeadInventory/Views/DesignSystem/Components/BISecondaryButton.swift`
- Create: `BeadInventory/Views/DesignSystem/Components/BIDestructiveButton.swift`
- Modify: `BeadInventory/Views/InventoryView.swift`（替换 StatCard）
- Modify: `BeadInventory/Views/StatisticsView.swift`（替换 OverviewCard）
- Modify: `BeadInventory/Views/ScanView.swift`（"扣减库存" / "创建计划" 主次按钮 — 仅样式替换，行为不动，主流程改造留到 Task 7）
- Modify: `BeadInventory/Views/SettingsView.swift`（删除模型 = `BIDestructiveButton`；本地模型选择 = `BISecondaryButton`）
- Modify: `BeadInventory/ContentView.swift`（库存 FAB 换成统一组件 - 仅样式 / fillColor）
- Test: 追加用例到 `BeadInventoryTests/DesignSystemComponentsTests.swift`

**目标：所有 Tab 主页面的"主操作按钮"和"统计卡"形态统一；主按钮自动随 Tab 风味色变。**

- [ ] **Step 1：写 `BIPrimaryButton`**

   ```swift
   // BeadInventory/Views/DesignSystem/Components/BIPrimaryButton.swift
   import SwiftUI

   struct BIPrimaryButton: View {
       let title: String
       let systemImage: String?
       let action: () -> Void

       @Environment(\.tabFlavor) private var flavor
       @Environment(\.isEnabled) private var isEnabled

       init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
           self.title = title
           self.systemImage = systemImage
           self.action = action
       }

       var body: some View {
           Button(action: action) {
               HStack(spacing: Theme.Spacing.sm) {
                   if let systemImage { Image(systemName: systemImage) }
                   Text(title).font(Theme.Typography.cardTitle)
               }
               .frame(maxWidth: .infinity)
               .frame(height: 56)
               .foregroundStyle(.white)
               .background(
                   (isEnabled ? flavor.color : Theme.ColorToken.Text.tertiary),
                   in: RoundedRectangle(cornerRadius: Theme.Radius.md)
               )
           }
           .buttonStyle(.plain)
       }
   }
   ```

- [ ] **Step 2：写 `BISecondaryButton`**

   ```swift
   // BeadInventory/Views/DesignSystem/Components/BISecondaryButton.swift
   import SwiftUI

   struct BISecondaryButton: View {
       let title: String
       let systemImage: String?
       let action: () -> Void

       @Environment(\.tabFlavor) private var flavor

       init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
           self.title = title
           self.systemImage = systemImage
           self.action = action
       }

       var body: some View {
           Button(action: action) {
               HStack(spacing: Theme.Spacing.sm) {
                   if let systemImage { Image(systemName: systemImage) }
                   Text(title).font(Theme.Typography.body.weight(.medium))
               }
               .frame(maxWidth: .infinity)
               .frame(height: 44)
               .foregroundStyle(flavor.color)
               .background(
                   flavor.color.opacity(0.12),
                   in: RoundedRectangle(cornerRadius: Theme.Radius.md)
               )
           }
           .buttonStyle(.plain)
       }
   }
   ```

- [ ] **Step 3：写 `BIDestructiveButton`**

   ```swift
   // BeadInventory/Views/DesignSystem/Components/BIDestructiveButton.swift
   import SwiftUI

   struct BIDestructiveButton: View {
       let title: String
       let systemImage: String?
       let action: () -> Void

       init(_ title: String, systemImage: String? = "trash", action: @escaping () -> Void) {
           self.title = title
           self.systemImage = systemImage
           self.action = action
       }

       var body: some View {
           Button(role: .destructive, action: action) {
               HStack(spacing: Theme.Spacing.sm) {
                   if let systemImage { Image(systemName: systemImage) }
                   Text(title).font(Theme.Typography.body.weight(.medium))
               }
               .frame(maxWidth: .infinity)
               .frame(height: 44)
               .foregroundStyle(.white)
               .background(
                   Theme.ColorToken.Status.error,
                   in: RoundedRectangle(cornerRadius: Theme.Radius.md)
               )
           }
           .buttonStyle(.plain)
       }
   }
   ```

- [ ] **Step 4：写 `BIStatCard`**

   ```swift
   // BeadInventory/Views/DesignSystem/Components/BIStatCard.swift
   import SwiftUI

   struct BIStatCard: View {
       let icon: String      // SF Symbol name
       let title: String
       let value: String
       let accent: Color?

       @Environment(\.tabFlavor) private var flavor

       init(icon: String, title: String, value: String, accent: Color? = nil) {
           self.icon = icon
           self.title = title
           self.value = value
           self.accent = accent
       }

       var body: some View {
           VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
               HStack {
                   Image(systemName: icon)
                       .foregroundStyle(accent ?? flavor.color)
                       .font(.title3)
                   Spacer()
               }
               Text(value)
                   .font(Theme.Typography.number)
                   .foregroundStyle(Theme.ColorToken.Text.primary)
               Text(title)
                   .font(Theme.Typography.metadata)
                   .foregroundStyle(Theme.ColorToken.Text.secondary)
           }
           .padding(Theme.Spacing.md)
           .frame(maxWidth: .infinity, alignment: .leading)
           .background(
               Theme.ColorToken.Surface.elevated,
               in: RoundedRectangle(cornerRadius: Theme.Radius.md)
           )
       }
   }
   ```

- [ ] **Step 5：把 4 个新文件加入 target，编译**

   `BUILD_CMD`，期望 BUILD SUCCEEDED。

- [ ] **Step 6：迁移 InventoryView 中的 `StatCard` 头部**

   grep 定位：
   ```bash
   grep -n "struct StatCard\|StatCard(" BeadInventory/Views/InventoryView.swift
   ```

   把 `StatCard(...)` 全部替换为 `BIStatCard(...)`。删除 `struct StatCard` 定义（约 InventoryView:525-552）。`BUILD_CMD`。

- [ ] **Step 7：迁移 StatisticsView 的 `OverviewCard`**

   ```bash
   grep -n "struct OverviewCard\|OverviewCard(" BeadInventory/Views/StatisticsView.swift
   ```

   `OverviewCard(icon:, title:, value:, …)` → `BIStatCard(icon:, title:, value:)`。如果 OverviewCard 有"环形进度"等额外能力，**保留**那个组件，只把无进度的纯文本卡片迁移；让 OverviewCard 内部也用 BIStatCard 的视觉规格（cornerRadius=md, padding=md, font=Typography.number）。`BUILD_CMD`。

- [ ] **Step 8：迁移 ScanView 的"创建计划" / "扣减库存"按钮样式**

   ⚠️ **本任务只换样式，不改流程**（流程改在 Task 7）。

   grep:
   ```bash
   grep -n "创建计划\|扣减库存" BeadInventory/Views/ScanView.swift
   ```

   - "扣减库存"按钮（约 ScanView:340-350）→ 替换为 `BIPrimaryButton("扣减库存", systemImage: "minus.circle.fill") { ... 原 action ... }`
   - "创建计划"按钮（约 ScanView:320-335）→ 替换为 `BISecondaryButton("创建计划", systemImage: "calendar.badge.plus") { ... 原 action ... }`

   `BUILD_CMD`。

- [ ] **Step 9：迁移 SettingsView 中删除/重置按钮**

   ```bash
   grep -n "删除模型\|重置库存\|borderedProminent\|tint(.red)" BeadInventory/Views/SettingsView.swift
   ```

   把"删除模型"等用 `BIDestructiveButton`。把"本地模型 - 选择"按钮（`.buttonStyle(.borderedProminent)`，约 SettingsView:359/408）替换为 `BISecondaryButton`。`BUILD_CMD`。

- [ ] **Step 10：迁移 ContentView 中的库存 FAB**

   `BUILD_CMD` 前先确认 FAB 现在写在 `ContentView.swift`，grep:
   ```bash
   grep -n "ZStack\|FAB\|plus.circle\|Color(\"AccentColor\")" BeadInventory/ContentView.swift
   ```

   把 FAB（60×60 圆形）的填充色换成"当前 Tab 风味色"：
   ```swift
   // 在 ZStack overlay 中：
   if selectedTab == 0 {
       Button { showAddInventory = true } label: {
           Image(systemName: "plus")
               .font(.title2.weight(.bold))
               .foregroundStyle(.white)
               .frame(width: 60, height: 60)
               .background(TabFlavor.inventory.color, in: Circle())
               .shadow(radius: 4, y: 2)
       }
       .padding(.trailing, Theme.Spacing.lg)
       .padding(.bottom, Theme.Spacing.xl)
   }
   ```

   `BUILD_CMD`。

- [ ] **Step 11：追加测试**

   在 `BeadInventoryTests/DesignSystemComponentsTests.swift` 末尾追加：
   ```swift
   func test_buttons_compile() {
       _ = BIPrimaryButton("a") {}
       _ = BISecondaryButton("b") {}
       _ = BIDestructiveButton("c") {}
   }
   func test_stat_card_compiles() {
       _ = BIStatCard(icon: "star", title: "T", value: "9")
   }
   ```

   ```bash
   xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
       -destination 'platform=iOS Simulator,name=iPhone 16' test
   ```
   期望全 PASS。

- [ ] **Step 12：模拟器视觉回归**

   - 库存 Tab：StatCard 视觉应保持卡片感，颜色用 Peach
   - 统计 Tab：OverviewCard 用 Mint
   - 扫描 Tab："扣减库存"全宽 56pt 主按钮、"创建计划"次按钮，色用 Coral
   - 设置：删除模型按钮变红色全宽
   - 库存 FAB：从原紫蓝改为 Peach

- [ ] **Step 13：Commit**

   ```bash
   git add BeadInventory/Views/DesignSystem/Components/BIStatCard.swift \
           BeadInventory/Views/DesignSystem/Components/BIPrimaryButton.swift \
           BeadInventory/Views/DesignSystem/Components/BISecondaryButton.swift \
           BeadInventory/Views/DesignSystem/Components/BIDestructiveButton.swift \
           BeadInventory/Views/InventoryView.swift \
           BeadInventory/Views/StatisticsView.swift \
           BeadInventory/Views/ScanView.swift \
           BeadInventory/Views/SettingsView.swift \
           BeadInventory/ContentView.swift \
           BeadInventoryTests/DesignSystemComponentsTests.swift \
           BeadInventory.xcodeproj/project.pbxproj
   git commit -m "refactor(ds): BIStatCard + BIPrimary/Secondary/DestructiveButton

   抽 4 个按钮 / 卡片组件并迁移核心调用点：StatCard / OverviewCard 收口到
   BIStatCard；ScanView / SettingsView 主次按钮统一；库存 FAB 用风味色。
   扫描流程改造留到 Task 7。

   Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
   ```

---

## Task 5：空状态收口 + 中文裸字符串本地化抽检

**Files:**
- Modify: `BeadInventory/Views/StatisticsView.swift`（空状态收口）
- Modify: `BeadInventory/Views/BrandManagerView.swift`（空状态收口）
- Modify: `BeadInventory/Views/InventoryView.swift`（空状态收口 + 中文裸字符串本地化）
- Modify: `BeadInventory/Localizable.xcstrings`（追加新条目）

**目标：把 3 处手写的空状态全部收口到已有的 `EmptyStateView`，并清理本次涉及视图中的中文裸字符串。**

- [ ] **Step 1：检查 EmptyStateView 现有签名**

   ```bash
   sed -n '1,60p' BeadInventory/Views/Components/EmptyStateView.swift
   ```

   记下 init 参数（推断为：`icon: String`, `title: String`, `description: String?`, `action: (() -> Void)?`, `actionTitle: String?`）。若实际签名不同，下文 replace 时按实际签名写。

- [ ] **Step 2：收口 StatisticsView 空状态**

   ```bash
   grep -n "Image(systemName:\|没有.*数据\|暂无" BeadInventory/Views/StatisticsView.swift | head -20
   ```

   定位 StatisticsView:79-87 附近的手写空状态（Image + Text + Text 三件套），替换为：
   ```swift
   EmptyStateView(
       icon: "chart.bar",
       title: NSLocalizedString("尚无使用数据", comment: "Statistics empty state title"),
       description: NSLocalizedString("开始扣减或拼图后，统计就会出现在这里", comment: "Statistics empty state description")
   )
   ```

- [ ] **Step 3：收口 BrandManagerView 空状态**

   定位 BrandManagerView:28-31 手写的"还没有品牌"，替换为：
   ```swift
   EmptyStateView(
       icon: "tag.slash",
       title: NSLocalizedString("还没有品牌", comment: "Brand manager empty state title"),
       description: NSLocalizedString("点击右上角添加你的第一个品牌", comment: "Brand manager empty state description")
   )
   ```

- [ ] **Step 4：收口 InventoryView 空状态 + 顺带清理裸字符串**

   定位 InventoryView:372-377 与 line:213：
   - "请先创建品牌" 空状态 → EmptyStateView
   - `Text("分组")` (line 213) → `Text(NSLocalizedString("分组", comment: "Inventory grouping toggle label"))`

   ```swift
   // line 213 改为
   Text("分组")  // 原
   // ↓
   Text(LocalizedStringKey("分组"))

   // line 372-377 改为
   EmptyStateView(
       icon: "square.grid.3x3",
       title: NSLocalizedString("请先创建品牌", comment: "Inventory needs brand"),
       description: NSLocalizedString("到「品牌管理」中添加品牌后再开始记录库存", comment: "Inventory needs brand description")
   )
   ```

- [ ] **Step 5：在 Localizable.xcstrings 中补对应英文翻译**

   用 Xcode 打开 `Localizable.xcstrings`，找到新增的 4 个 key，填英文：
   - 尚无使用数据 → No usage data yet
   - 开始扣减或拼图后，统计就会出现在这里 → Stats appear here once you scan or build something
   - 还没有品牌 → No brands yet
   - 点击右上角添加你的第一个品牌 → Tap the top-right to add your first brand
   - 请先创建品牌 → Please create a brand first
   - 到「品牌管理」中添加品牌后再开始记录库存 → Add a brand in "Brand Manager" before tracking inventory
   - 分组 → Group

- [ ] **Step 6：编译**

   `BUILD_CMD`，期望 BUILD SUCCEEDED。

- [ ] **Step 7：本地化抽检**

   在模拟器设置 → 通用 → 语言切换为 English，重启 App，依次进入：
   - 统计 Tab（无数据品牌切换）→ 应当显示英文空状态
   - 设置 → 品牌管理 → 删空 → 英文空状态
   - 库存 Tab（无品牌时）→ 英文空状态 + Group 切英文
   切回中文确认中文也对。

- [ ] **Step 8：Commit**

   ```bash
   git add BeadInventory/Views/StatisticsView.swift \
           BeadInventory/Views/BrandManagerView.swift \
           BeadInventory/Views/InventoryView.swift \
           BeadInventory/Localizable.xcstrings
   git commit -m "refactor(empty): 收口三处手写空状态 + 中文裸字符串本地化

   StatisticsView/BrandManagerView/InventoryView 中三处手写的空状态统一
   迁移到已有的 EmptyStateView；顺带把 InventoryView 中遗留的中文裸字符
   串转为 LocalizedStringKey 并补英文翻译。

   Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
   ```

---

## Task 6：多选公约统一 — BISelectableCell + MultiSelectActionBar + 四处迁移

**Files:**
- Create: `BeadInventory/Views/DesignSystem/Components/BISelectableCell.swift`
- Create: `BeadInventory/Views/DesignSystem/Components/MultiSelectActionBar.swift`
- Create: `BeadInventory/Views/DesignSystem/SelectionContext.swift`（多选状态容器）
- Modify: `BeadInventory/Views/InventoryView.swift`（**新增**多选）
- Modify: `BeadInventory/Views/PlannedProjectsView.swift`（**替换**现有 isSelectMode）
- Modify: `BeadInventory/Views/ScanView.swift` 中的 `ManualEntrySheetNew`（统一多选）
- Modify: `BeadInventory/Views/HistoryView.swift`（**新增**多选回滚）
- Test: `BeadInventoryTests/SelectionContextTests.swift`

**⚠️ 这是高风险 task。如果在 Step 4–7 中发现单 commit 改动过大，允许在 Step 7 之后拆出一个独立 commit"6a: 库存+计划"先落地，剩下"6b: 扫描手动录入+历史"再落第二个 commit。总 commit 数仍 ≤ 10。**

- [ ] **Step 1：写 `SelectionContext` 通用容器**

   `BeadInventory/Views/DesignSystem/SelectionContext.swift`:
   ```swift
   import SwiftUI

   /// 多选状态容器。被多选页面内嵌：
   ///   @StateObject var sel = SelectionContext<UUID>()
   /// 视图层调用 sel.isActive / sel.toggle / sel.exit 即可。
   @MainActor
   final class SelectionContext<ID: Hashable>: ObservableObject {
       @Published private(set) var isActive: Bool = false
       @Published private(set) var selected: Set<ID> = []

       func enter(initial: ID? = nil) {
           isActive = true
           if let id = initial { selected.insert(id) }
       }

       func exit() {
           isActive = false
           selected.removeAll()
       }

       func toggle(_ id: ID) {
           if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
       }

       func contains(_ id: ID) -> Bool { selected.contains(id) }

       var count: Int { selected.count }
   }
   ```

- [ ] **Step 2：写 `BISelectableCell`**

   `BeadInventory/Views/DesignSystem/Components/BISelectableCell.swift`:
   ```swift
   import SwiftUI

   struct BISelectableCell<Content: View>: View {
       let isActive: Bool
       let isSelected: Bool
       let onLongPress: () -> Void
       let onTapInSelectMode: () -> Void
       @ViewBuilder let content: () -> Content

       @Environment(\.tabFlavor) private var flavor

       var body: some View {
           content()
               .overlay(alignment: .topTrailing) {
                   if isActive {
                       Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                           .font(.title3)
                           .foregroundStyle(isSelected ? flavor.color : Theme.ColorToken.Text.tertiary)
                           .padding(Theme.Spacing.xs)
                           .background(
                               Circle().fill(Theme.ColorToken.Surface.elevated.opacity(0.85))
                           )
                           .padding(Theme.Spacing.xs)
                       .sensoryFeedback(.selection, trigger: isSelected)
                   }
               }
               .overlay {
                   if isActive && isSelected {
                       RoundedRectangle(cornerRadius: Theme.Radius.md)
                           .strokeBorder(flavor.color, lineWidth: 2)
                   }
               }
               .opacity(isActive && !isSelected ? 0.85 : 1.0)
               .contentShape(Rectangle())
               .onTapGesture {
                   if isActive { onTapInSelectMode() }
               }
               .onLongPressGesture(minimumDuration: 0.4) {
                   if !isActive { onLongPress() }
               }
       }
   }
   ```

- [ ] **Step 3：写 `MultiSelectActionBar`**

   `BeadInventory/Views/DesignSystem/Components/MultiSelectActionBar.swift`:
   ```swift
   import SwiftUI

   struct MultiSelectActionBar<Actions: View>: View {
       let count: Int
       @ViewBuilder let actions: () -> Actions

       var body: some View {
           HStack(spacing: Theme.Spacing.md) {
               Text("已选 \(count)")
                   .font(Theme.Typography.body.weight(.medium))
                   .foregroundStyle(Theme.ColorToken.Text.primary)
               Spacer()
               actions()
           }
           .padding(.horizontal, Theme.Spacing.lg)
           .padding(.vertical, Theme.Spacing.md)
           .background(.ultraThinMaterial)
           .overlay(alignment: .top) {
               Rectangle()
                   .fill(Theme.ColorToken.Border.divider)
                   .frame(height: 0.5)
           }
       }
   }
   ```

- [ ] **Step 4：写测试**

   `BeadInventoryTests/SelectionContextTests.swift`:
   ```swift
   import XCTest
   @testable import BeadInventory

   @MainActor
   final class SelectionContextTests: XCTestCase {
       func test_enter_exit_lifecycle() {
           let ctx = SelectionContext<Int>()
           XCTAssertFalse(ctx.isActive)
           ctx.enter(initial: 7)
           XCTAssertTrue(ctx.isActive)
           XCTAssertTrue(ctx.contains(7))
           ctx.exit()
           XCTAssertFalse(ctx.isActive)
           XCTAssertEqual(ctx.count, 0)
       }
       func test_toggle_adds_then_removes() {
           let ctx = SelectionContext<Int>()
           ctx.enter()
           ctx.toggle(1); ctx.toggle(2); ctx.toggle(1)
           XCTAssertEqual(ctx.selected, [2])
       }
   }
   ```

- [ ] **Step 5：把新文件加入 target + 编译 + 跑测试**

   `BUILD_CMD` 与 `xcodebuild ... test`，期望全 PASS。

- [ ] **Step 6：迁移 PlannedProjectsView 现有多选**

   1. 删掉 `@State private var isSelectMode = false` 与 `@State private var selectedProjects: Set<UUID> = []`（line 33–34）。
   2. 新增 `@StateObject private var sel = SelectionContext<UUID>()`。
   3. 找到 `if isSelectMode && !selectedProjects.isEmpty { ... }` (line 62 起) 整段行内按钮，**全部删除**。
   4. 在 `body` 最外层 NavigationStack 内尾部追加：
      ```swift
      .safeAreaInset(edge: .bottom) {
          if sel.isActive {
              MultiSelectActionBar(count: sel.count) {
                  BISecondaryButton("合并", systemImage: "rectangle.stack.badge.plus") {
                      // 复用现有 merge action
                  }
                  BISecondaryButton("库存确认", systemImage: "checkmark.circle") {
                      // 复用现有 stock check action
                  }
                  BIDestructiveButton("删除") {
                      // 复用现有 delete action
                  }
              }
          }
      }
      ```
   5. 工具栏改为：
      ```swift
      .toolbar {
          if sel.isActive {
              ToolbarItem(placement: .topBarLeading) { Button("取消") { sel.exit() } }
              ToolbarItem(placement: .topBarTrailing) { Button("完成") { sel.exit() } }
          } else {
              ToolbarItem(placement: .topBarTrailing) {
                  Button("选择") { sel.enter() }
              }
          }
      }
      ```
   6. 项目行包装：把原 `ProjectCard` 之类的子 View 用 `BISelectableCell` 包：
      ```swift
      BISelectableCell(
          isActive: sel.isActive,
          isSelected: sel.contains(project.id),
          onLongPress: { sel.enter(initial: project.id) },
          onTapInSelectMode: { sel.toggle(project.id) }
      ) {
          ProjectCard(...)  // 原内容
      }
      ```
   7. swipeActions 与 selectMode 互斥：若 `sel.isActive`，禁用 swipeActions（或在 swipe handlers 里加 `guard !sel.isActive`）。

   `BUILD_CMD`。

- [ ] **Step 7：迁移 InventoryView 新增多选**

   InventoryView 原本没多选。加入：
   1. `@StateObject private var sel = SelectionContext<UUID>()`（用色号 BeadColor.id）。
   2. 在主 grid/list 里把每个 cell 用 `BISelectableCell` 包。
   3. `.safeAreaInset(edge: .bottom)` 挂 `MultiSelectActionBar`，操作：批量隐藏、批量调整低库存阈值（弹 sheet 输入数字）、批量加入计划（跳到计划新建 sheet）。
   4. Toolbar 同上加 "选择" / "取消"。

   `BUILD_CMD`。

   ⚠️ 如果到这里改动量已经接近 600 行 diff，**停下来先 commit 6a**，剩下两处放 commit 6b：
   ```
   git add ... && git commit -m "feat(select): 多选公约 — 引入 SelectionContext + 迁移库存/计划 (6a)"
   ```

- [ ] **Step 8：迁移 ScanView.ManualEntrySheetNew 多选**

   定位 (ScanView:1434+)。把 `@State private var selectedColors: Set<UUID>` 与现有 toggle 逻辑改成 `SelectionContext<UUID>`，并在 Sheet 内底部用 `MultiSelectActionBar` 替代现有的"已选 N + 确认"。

   `BUILD_CMD`。

- [ ] **Step 9：迁移 HistoryView，新增多选批量回滚**

   `BeadInventory/Views/HistoryView.swift` 加 `SelectionContext<UUID>`，把每条历史行包 `BISelectableCell`，底 Bar 一个按钮："回滚选中"。复用原有单条回滚的 action。

   `BUILD_CMD`。

- [ ] **Step 10：模拟器逐处回归**

   | 场景 | 验证 |
   |---|---|
   | 计划 Tab 长按项目 | 进入选择模式，被长按项已选，左下角"取消"，右下角"完成"，底部 ActionBar 出现 |
   | 计划批量合并 | 选 ≥ 2 个，点合并 → 走原合并流程 |
   | 库存 Tab 长按色号 | 进入选择模式，能多选 |
   | 库存批量隐藏 | 选若干，点"隐藏" → 全部消失 |
   | 扫描手动录入 | 进入 sheet 长按色号 → 多选 |
   | 历史 Tab 长按 | 多选 → 批量回滚 |
   | 触觉 | 真机选中时有轻微震动 |

- [ ] **Step 11：Commit（如果走 6a/6b 拆分，这里是 6 或 6b）**

   ```bash
   git add BeadInventory/Views/DesignSystem/ \
           BeadInventory/Views/InventoryView.swift \
           BeadInventory/Views/PlannedProjectsView.swift \
           BeadInventory/Views/ScanView.swift \
           BeadInventory/Views/HistoryView.swift \
           BeadInventoryTests/SelectionContextTests.swift \
           BeadInventory.xcodeproj/project.pbxproj
   git commit -m "feat(select): 统一多选公约 — 库存/计划/扫描手动录入/历史

   引入 SelectionContext + BISelectableCell + MultiSelectActionBar 三件套，
   长按进入选择模式，底部浮动 ActionBar 承载批量操作。库存与历史为新增多
   选；计划替换现有 isSelectMode；扫描手动录入对齐统一形态。

   Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
   ```

---

## Task 7：扫描流去歧义 — 单主 CTA + Stepper + 取消嵌套 sheet

**Files:**
- Create: `BeadInventory/Views/DesignSystem/Components/BIStepper.swift`（三段式状态指示器，**纯视觉**，不要混淆 SwiftUI 内置 Stepper）
- Modify: `BeadInventory/Views/ScanView.swift`（主流程改造）
- Create: `BeadInventory/Views/DeductionReviewView.swift`（把原 `DeductionReviewSheet` 内的 sheet 拆成可 push 的 View）

**⚠️ 这也是高风险 task。允许必要时拆 7a（Stepper + 主 CTA 重新布局）与 7b（DeductionReview 由 sheet 改 push）。**

- [ ] **Step 1：写 `BIStepper`（三段进度指示器）**

   `BeadInventory/Views/DesignSystem/Components/BIStepper.swift`:
   ```swift
   import SwiftUI

   struct BIStepper: View {
       let steps: [String]
       let currentIndex: Int

       @Environment(\.tabFlavor) private var flavor

       var body: some View {
           HStack(spacing: Theme.Spacing.sm) {
               ForEach(Array(steps.enumerated()), id: \.offset) { idx, label in
                   stepDot(idx: idx, label: label)
                   if idx < steps.count - 1 {
                       Rectangle()
                           .fill(idx < currentIndex ? flavor.color : Theme.ColorToken.Border.divider)
                           .frame(height: 2)
                   }
               }
           }
           .padding(.horizontal, Theme.Spacing.lg)
       }

       private func stepDot(idx: Int, label: String) -> some View {
           VStack(spacing: Theme.Spacing.xs) {
               ZStack {
                   Circle()
                       .fill(idx <= currentIndex ? flavor.color : Theme.ColorToken.Surface.subtle)
                       .frame(width: 24, height: 24)
                   if idx < currentIndex {
                       Image(systemName: "checkmark")
                           .font(.caption.weight(.bold))
                           .foregroundStyle(.white)
                   } else {
                       Text("\(idx + 1)")
                           .font(.caption.weight(.bold))
                           .foregroundStyle(idx == currentIndex ? .white : Theme.ColorToken.Text.tertiary)
                   }
               }
               Text(label)
                   .font(Theme.Typography.metadata)
                   .foregroundStyle(idx <= currentIndex ? Theme.ColorToken.Text.primary : Theme.ColorToken.Text.tertiary)
           }
       }
   }
   ```

- [ ] **Step 2：把 `DeductionReviewSheet` 拆成可 push 的 View**

   先看现状：
   ```bash
   grep -n "struct DeductionReviewSheet\|sheet(item:" BeadInventory/Views/ScanView.swift | head
   ```

   1. 新建 `BeadInventory/Views/DeductionReviewView.swift`，把原 `DeductionReviewSheet` 的 body 完整搬过来，删掉它顶层的 `NavigationStack` 包装（因为 push 进来已经在导航栈里了），删掉 toolbar 中的 leading "取消"（push 流自带返回）。
   2. 把原 ScanView 里 `.sheet(item: $deductionContext)` 替换为 `NavigationLink(value: ...)`，或在 ScanView 的 `body` 末尾加 `.navigationDestination(item: $deductionContext) { ctx in DeductionReviewView(context: ctx) }`。

   `BUILD_CMD`。

- [ ] **Step 3：重排 ScanView 顶层布局**

   ScanView body 改为（伪代码骨架）：
   ```swift
   NavigationStack {
       VStack(spacing: 0) {
           BIStepper(
               steps: ["识别", "调整", "确认"],
               currentIndex: stepperIndex
           )
           .padding(.top, Theme.Spacing.md)

           ScrollView {
               // 原图像区 + 识别结果区
           }

           Spacer(minLength: 0)
       }
       .safeAreaInset(edge: .bottom) {
           if hasRecognizedItems {
               BIPrimaryButton("扣减库存", systemImage: "minus.circle.fill") {
                   triggerDeduct()
               }
               .padding(.horizontal, Theme.Spacing.lg)
               .padding(.bottom, Theme.Spacing.sm)
           }
       }
       .toolbar {
           ToolbarItem(placement: .topBarTrailing) {
               Menu {
                   Button("仅创建计划，不扣减", systemImage: "calendar.badge.plus", action: createPlanOnly)
                   Button("重新拍照", systemImage: "arrow.counterclockwise", action: resetAll)
                   Button("清空当前识别", systemImage: "trash", role: .destructive, action: clearRecognized)
               } label: {
                   Image(systemName: "ellipsis.circle")
               }
           }
       }
       .navigationDestination(item: $deductionContext) { ctx in
           DeductionReviewView(context: ctx)
       }
   }
   ```

   `stepperIndex` 的状态机：
   - 无图像 / 未识别 → 0
   - 有识别结果且未点 "扣减" → 1
   - 已点 "扣减"（或正在 DeductionReview）→ 2

- [ ] **Step 4：把"扣减库存"action 的两个分支接好**

   - 全部色号已匹配 → alert "确认扣减 N 颗" → 执行 → success haptic
   - 存在未匹配 → 设置 `deductionContext = ctx`，触发上面 `navigationDestination` push 到 DeductionReviewView

   伪代码：
   ```swift
   func triggerDeduct() {
       let unresolved = recognizedItems.filter { !$0.matchedToInventory }
       if unresolved.isEmpty {
           showConfirmAlert = true
       } else {
           deductionContext = DeductionContext(items: recognizedItems)
       }
   }
   ```

- [ ] **Step 5：DeductionReviewView 完成后回到主流程**

   DeductionReviewView 顶部有"确认"按钮 → 执行扣减 → pop 回 ScanView → 触发 success toast。如果原 sheet 用 dismiss 回调，改为 `@Environment(\.dismiss)`，配合 ScanView 端 `.onChange(of: deductionContext)` 重置状态。

   `BUILD_CMD`。

- [ ] **Step 6：模拟器完整回归扫描流**

   - 拍一张图 → 识别 → stepper 走到 ②
   - 全部匹配：点"扣减库存" → 弹 alert → 确认 → 成功 toast，stepper 到 ③，再点"重新拍照"复位
   - 存在未匹配：点"扣减库存" → push 到 DeductionReviewView → 改色号 → 确认 → 回 ScanView 显示成功
   - "仅创建计划"：点 ... menu → "仅创建计划" → 创建项目，无扣减
   - 全程不再有 sheet 嵌套 sheet 的现象

- [ ] **Step 7：Commit**

   ```bash
   git add BeadInventory/Views/DesignSystem/Components/BIStepper.swift \
           BeadInventory/Views/DeductionReviewView.swift \
           BeadInventory/Views/ScanView.swift \
           BeadInventory.xcodeproj/project.pbxproj
   git commit -m "feat(scan): 扫描流去歧义 — 单主 CTA + Stepper + 取消嵌套 sheet

   ScanView 顶部加三段 Stepper（识别/调整/确认），底部 sticky 仅保留\"扣减
   库存\"主 CTA；\"仅创建计划\"降为 toolbar Menu 次级。DeductionReviewSheet
   重构为可 push 的 DeductionReviewView，消除 sheet-in-sheet 嵌套。

   Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
   ```

---

## Task 8：Toolbar 公约 + 导航策略整改 + 颜色裸写全局清扫

**Files:**
- Modify: 全部 `BeadInventory/Views/*.swift`（按 grep 结果逐文件清理）
- Modify: 必要时调整工程文件

**目标：把现存的 Toolbar 错位、sheet/fullScreenCover 误用、`Color.red/.green/.orange/.blue/.gray` 裸写、`.cornerRadius(数字)`、`.font(.system(size:))` 等遗留兜底清完。**

- [ ] **Step 1：Toolbar 公约自查**

   ```bash
   grep -rn "ToolbarItem(placement:" BeadInventory/Views --include="*.swift"
   ```

   逐行人工检查（应该不多）：
   - leading 应仅放"取消 / 返回"
   - trailing 应放主操作；溢出走 Menu
   - 任何"主操作在 leading / 取消在 trailing"的位置就地修正

- [ ] **Step 2：导航策略巡检 — sheet-in-sheet 兜底**

   ```bash
   grep -rn "\\.sheet(" BeadInventory/Views --include="*.swift"
   ```
   人工核对：任何 Sheet 内部又调 `.sheet(` 或 `.fullScreenCover(`，**重写**为 push 或把 cover 提到根。

- [ ] **Step 3：颜色裸写清扫**

   ```bash
   grep -rn "Color\\.red\\|Color\\.green\\|Color\\.orange\\|Color\\.blue\\|Color\\.gray\\|Color\\.pink\\|Color\\.purple\\|Color\\.yellow\\|\\.foregroundStyle(\\.red\\|\\.tint(\\.green\\|\\.tint(\\.orange\\|\\.tint(\\.blue\\|\\.tint(\\.red" BeadInventory/Views --include="*.swift"
   ```

   逐处替换映射表：

   | 旧写法 | 新写法 |
   |---|---|
   | `Color.red`（错误/破坏） | `Theme.ColorToken.Status.error` |
   | `Color.orange`（低库存/警告） | `Theme.ColorToken.Status.warning` |
   | `Color.green`（成功/库存够） | `Theme.ColorToken.Status.success` |
   | `Color.blue`（信息/图表中性） | `Theme.ColorToken.Status.info` |
   | `Color.gray`（次要文本） | `Theme.ColorToken.Text.secondary` |
   | `Color.gray.opacity(0.3)`（边框/分隔） | `Theme.ColorToken.Border.default` |
   | `Color(.systemGray5/6)`（背景） | `Theme.ColorToken.Surface.subtle` |
   | `.tint(.red)` 按钮 | `BIDestructiveButton` 或 `Theme.ColorToken.Status.error` |

   **豁免名单**：`CustomColorEditView.swift` / `BIColorSwatch.swift` 中数据驱动渲染拼豆色板的 `Color(hex:)` 调用 **保留**（这是数据，不是 UI 装饰）。

- [ ] **Step 3b：StatisticsView 缺失的 destructive swipe 二次确认补齐**

   ```bash
   grep -n "swipeActions\|.destructive\|alert(" BeadInventory/Views/StatisticsView.swift
   ```

   对每个 `swipeActions { ... Button(role: .destructive) ... }`，确认是否后续 alert 弹出。若直接执行删除而无 alert，改为：
   ```swift
   .swipeActions(edge: .trailing) {
       Button(role: .destructive) {
           pendingDeletion = item  // @State var pendingDeletion: Item?
       } label: { Label("删除", systemImage: "trash") }
   }
   .alert("确认删除",
          isPresented: Binding(get: { pendingDeletion != nil },
                               set: { if !$0 { pendingDeletion = nil } })) {
       Button("取消", role: .cancel) {}
       Button("删除", role: .destructive) {
           if let item = pendingDeletion { performDelete(item) }
           pendingDeletion = nil
       }
   } message: {
       Text("确认删除\\(pendingDeletion?.displayName ?? "")吗？此操作无法撤销。")
   }
   ```

   覆盖 spec §4.6 的"StatisticsView 缺二次确认的 swipe 全部补齐"要求。`BUILD_CMD`。

- [ ] **Step 4：圆角与字号常量化**

   ```bash
   grep -rn "cornerRadius([0-9]" BeadInventory/Views --include="*.swift"
   grep -rn "\\.font(\\.system(size:" BeadInventory/Views --include="*.swift"
   ```

   替换：
   - `cornerRadius(8)` → `cornerRadius(Theme.Radius.sm)`
   - `cornerRadius(12)` → `cornerRadius(Theme.Radius.md)`
   - `cornerRadius(16)` / `cornerRadius(20)` → `cornerRadius(Theme.Radius.lg)`
   - `cornerRadius(其它离群值)` → 就近取 sm/md/lg
   - `.font(.system(size: 60))`（空状态用） → 改用 EmptyStateView，不直接指定字号
   - 其它 `.font(.system(size: N))` → 用 `Theme.Typography.pageTitle/cardTitle/body/metadata/number` 之一

- [ ] **Step 5：编译 + 测试 + 模拟器全应用巡检**

   `BUILD_CMD` 与 test，期望全 PASS。

   模拟器跑一遍 5 个 Tab + 全部主流 Sheet（截图 9 张），与 baseline 比对。允许变化点：所有红/绿/橘的色相微调；所有圆角整齐到 8/12/16；字号统一。**不允许**布局错位、按钮变小、文字截断。

- [ ] **Step 6：最终 grep 验收**

   ```bash
   grep -rn "Color\\.red\\|Color\\.green\\|Color\\.orange\\|Color\\.blue\\|Color\\.gray\\|Color\\.pink\\|Color\\.purple\\|Color\\.yellow" BeadInventory/Views --include="*.swift" | grep -v "BIColorSwatch.swift\\|CustomColorEditView.swift" | wc -l
   ```
   期望输出：`0` 或几行豁免说明（在 commit 信息里记录）。

- [ ] **Step 7：Commit**

   ```bash
   git add BeadInventory/Views/
   git commit -m "refactor(nav): toolbar 公约 + sheet/push/fullScreenCover 整改 + 颜色/圆角/字号全局清扫

   全应用清理 Toolbar 位置错位、Sheet-in-sheet 残留、Color.red/.green/.orange
   等裸写、cornerRadius 魔数、.font(.system(size:)) 硬编码字号。豁免：拼豆色
   板的数据驱动 Color(hex:) 渲染。

   Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
   ```

---

## Task 9：触觉反馈接入

**Files:**
- Create: `BeadInventory/Views/DesignSystem/BIHaptics.swift`
- Modify: 散点接入（库存扣减成功、保存项目、计划完成、错误 alert、扫描结束）

**目标：建立全应用统一的触觉反馈基线。**

- [ ] **Step 1：写 `BIHaptics.swift`**

   ```swift
   // BeadInventory/Views/DesignSystem/BIHaptics.swift
   import SwiftUI

   /// 统一封装 SwiftUI 17+ 的 `.sensoryFeedback` 触发器。
   /// 三档语义：选择切换 / 操作成功 / 操作失败。普通点击不加触觉。
   enum BIHaptics {
       enum Event {
           case selection   // 多选切换、Tab 切换无需触觉，不要乱接
           case success     // 扣减成功、保存项目、计划完成
           case error       // 库存不足、识别失败、网络错误
       }

       static func feedback(for event: Event) -> SensoryFeedback {
           switch event {
           case .selection: return .selection
           case .success:   return .success
           case .error:     return .error
           }
       }
   }

   /// 视图层语法糖：
   ///   `.haptic(.success, trigger: didSucceed)`
   extension View {
       func haptic<V: Equatable>(_ event: BIHaptics.Event, trigger: V) -> some View {
           self.sensoryFeedback(BIHaptics.feedback(for: event), trigger: trigger)
       }
   }
   ```

- [ ] **Step 2：库存扣减成功接 `.success`**

   在 InventoryView 或 ScanView 触发扣减完成的 state 上挂：
   ```swift
   .haptic(.success, trigger: deductCompletedAt)  // @State var deductCompletedAt = Date() (在成功时更新)
   ```

- [ ] **Step 3：保存项目 / 计划完成 / 历史回滚成功接 `.success`**

   分别在 PlannedProjectsView / ProjectDetailView / HistoryView 找到对应成功 closure，update 一个 `@State` Date trigger，挂 `.haptic(.success, trigger: trigger)`。

- [ ] **Step 4：错误 alert 接 `.error`**

   遇到"库存不足"、"识别失败"、"网络失败"等 alert，挂 `.haptic(.error, trigger: errorTrigger)`。

- [ ] **Step 5：多选切换 selection（Task 6 中已在 BISelectableCell 里挂了 `.sensoryFeedback(.selection, ...)`）—— 复查一次**

   ```bash
   grep -rn "sensoryFeedback\\|haptic(" BeadInventory/Views --include="*.swift"
   ```

   确认 BISelectableCell 中存在 selection 触觉；其它纯 tap 切换的地方**不要**滥加。

- [ ] **Step 6：真机测试（必须在物理设备上）**

   - 多选切换：轻微 tick
   - 扣减成功：双击式成功反馈
   - 库存不足：rejected 模式
   - 普通点击：无反馈（不应出现意外震动）

- [ ] **Step 7：Commit**

   ```bash
   git add BeadInventory/Views/DesignSystem/BIHaptics.swift \
           BeadInventory/Views/InventoryView.swift \
           BeadInventory/Views/ScanView.swift \
           BeadInventory/Views/PlannedProjectsView.swift \
           BeadInventory/Views/ProjectDetailView.swift \
           BeadInventory/Views/HistoryView.swift \
           BeadInventory.xcodeproj/project.pbxproj
   git commit -m "feat(haptics): BIHaptics 接入选择/保存/错误三态

   封装 SwiftUI 17+ sensoryFeedback 为三档语义事件（selection/success/
   error），在多选切换、扣减/保存/完成成功、库存不足/网络错误等关键节
   点接入。普通点击保持无触觉。

   Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
   ```

---

## 完工后清单

- [ ] 全部 9（或拆分后最多 11）个 commit 都已落地
- [ ] `git log --oneline main..HEAD` 显示有序、每条都自包含
- [ ] 模拟器跑完一遍 5 Tab + 主要 Sheet，截图与 Task 0 baseline 对比 —— 仅有"预期变化"
- [ ] `grep` 验收脚本：
    ```bash
    grep -rn "Color\\.red\\|Color\\.green\\|Color\\.orange\\|Color\\.blue\\|Color\\.gray\\|Color\\.pink\\|Color\\.purple\\|Color\\.yellow" BeadInventory/Views --include="*.swift" | grep -v "BIColorSwatch.swift\\|CustomColorEditView.swift"
    grep -rn "cornerRadius([0-9]\\|font(.system(size:" BeadInventory/Views --include="*.swift"
    ```
    两条都应为空（或仅含豁免文件）
- [ ] `xcodebuild ... test` 全 PASS
- [ ] 真机过一遍触觉反馈
- [ ] 如果有"调色不满意"的反馈，单独留 1 commit 调 Asset Catalog 数值（不进本 9 commit）

---

## 风险回顾

| 风险 | 应对 |
|---|---|
| Task 6 / 7 单 commit 过大 | 允许拆 6a/6b、7a/7b，总 ≤ 10 (+1 调色) |
| Asset Catalog 新色与原 AccentColor 视觉差异过大 | Task 2 完成后立即模拟器对比；不满意先调 colorset 数值再继续 |
| `xcodebuild` 新增 colorset 不被识别 | Xcode 直接打开工程拖入；不要手编 pbxproj |
| Sheet 改 push 引发返回行为异常 | Task 7 完成后单独走一遍扫描全流程 |
| 触觉真机与模拟器表现差异 | Task 9 真机验证为强制门槛 |
