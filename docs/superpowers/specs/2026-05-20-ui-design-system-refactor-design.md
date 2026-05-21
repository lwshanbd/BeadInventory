# UI 设计系统重构 — 设计文档

- **日期**: 2026-05-20
- **作者**: lwshanbd + Claude
- **状态**: Draft（待用户 review）
- **代号**: BeadInventory Design System v1（下文简称 BIDS）

---

## 1. 背景与目标

BeadInventory 历经多个版本迭代，UI 层逐渐积累了三类技术债：

1. **颜色乱**：唯一定义的语义色只有 `AccentColor`，其余全是裸写 `Color.red/.green/.orange/.blue`。同一颜色承担多种语义（绿=成功/已下载/库存够/选中/已完成），同一语义又用不同颜色（错误既用 `.red` 也用 `Color.red.opacity(0.1)`）。
2. **交互乱**：多选模式三个页面三个范式；扫描流尾部"创建计划 / 扣减库存"两个等权重 CTA；Toolbar 主/次按钮摆位不固定；零触觉反馈；导航策略（sheet / fullScreenCover / push）无规则。
3. **组件乱**：15+ 行组件手写重复；3 处空状态绕过已有 `EmptyStateView`；26+ 处 `.system(size:)` 硬编码字体；圆角 / 间距全是魔数。

本次重构在**保留 App "给小姑娘用、色彩丰富"调性**的前提下，建立三层体系：

1. **Theme**：基础调色板 → 语义 Token → Tab 风味色，三层映射；间距 / 圆角 / 字体常量化。
2. **组件库**：抽取 8 个高复用度组件到 `Views/DesignSystem/`。
3. **交互公约**：多选 / 扫描流 / Toolbar / 导航 / 触觉 / 破坏性确认，形成可执行规则。

### 核心目标

- 视觉上 **整体协调**（同饱和度同明度的糖果色调色板）+ **每个 Tab 有专属辨识度**（Tab 风味色）+ **语义稳定**（绿=成功，无论在哪个 Tab）。
- 交互上消除三个最严重的不一致点：多选、扫描流、Toolbar 摆位。
- 引入触觉反馈基线（选择 / 成功 / 错误三态）。
- 组件层降低后续新功能的 UI 实现成本，禁止再裸写颜色与字体常量。

### 非目标（本次不做）

- 重做信息架构（Tab 数量、Tab 顺序不变）
- 重做品牌定位 / Logo / 启动页
- 完整无障碍审计（仅做对比度兜底）
- 完全的 Dynamic Type 自适应（仅保证语义字体）
- iPad 自适应布局
- 动画 / 转场系统

---

## 2. 决策汇总（已与用户对齐）

| 决策项 | 选择 | 理由 |
|---|---|---|
| 总体策略 | 体系化方案（Theme + 组件库 + 交互公约三层） | 一次性收口三类问题，颗粒度适合 5–10 commit 评审 |
| 颜色丰富度 | 保留鲜亮糖果调，不走极简单色 | App 用户是小姑娘，色彩本身就是产品价值 |
| 协调手段 | 统一调色板的饱和度 / 明度（HSB S≈70 B≈95） | 同 S/B 的色相天然和谐 |
| Tab 个性 | 每个 Tab 一个专属"风味色"，仅作用于 TabBar tint / FAB / 空状态 / 页眉 | 治"5 个 Tab 抢同一个 AccentColor 槽位"的根因 |
| 语义色独立 | 成功/警告/错误/信息四档语义色全局统一，**不**随 Tab 变化 | 红=危险这种心智不能被打破 |
| 组件库位置 | `BeadInventory/Views/DesignSystem/` | 与现有 `Views/Components/` 分开，前者是 token-driven 设计系统，后者是已有业务组件 |
| 多选触发 | 长按进入选择模式（主）/ toolbar trailing 「选择」按钮（备） | 长按是 iOS 原生姿势；按钮做兜底入口 |
| 多选操作位置 | 底部 SafeArea 浮动 ActionBar，**不**再用行内按钮 | 行内按钮挤占内容；浮动 Bar 是 iOS 系统多选标准 |
| 扫描主 CTA | 仅"扣减库存"作为底部 sticky 主 CTA；"创建计划"降为 toolbar Menu 次级 | 减少决策歧义；"扣减"是真正改库存的破坏性动作，需要更显眼 |
| 扫描嵌套 sheet | DeductionReviewSheet 改为同一 NavigationStack 内 push | 现状是 sheet 里再 sheet，返回行为反常 |
| Toolbar 公约 | Leading=取消/返回，Trailing=主操作，溢出动作走 Menu | 与 Apple HIG 一致 |
| 导航策略 | 详情→sheet+detent；下钻→push；相机/裁剪→fullScreenCover；向导→sheet+stepper | 现状是三种并用、无规则 |
| 触觉封装 | 新建 `BIHaptics` enum，三态：selection / success / error | 全应用零触觉太干，但也不能滥用 |
| 破坏性确认 | 一律 `.alert(role: .destructive)`，文案模板："确认删除 X 吗？此操作无法撤销。" | 当前部分 destructive swipe 没有二次确认 |
| 字体策略 | 封装 `Theme.Typography` 语义层，全应用禁用 `.system(size:)` | 当前 26+ 处硬编码字号 |
| 间距 / 圆角 | `Theme.Spacing` xs/sm/md/lg/xl/xxl = 4/8/12/16/20/24；`Theme.Radius` sm/md/lg/pill = 8/12/16/999 | 顺承现状最常用值 |
| 旧颜色裸写 | 渐进式淘汰，不一次性 ban；每个迁移 commit 把当前涉及的视图清零 | 9 commit 内逐步收口，可逐步 review |
| 中文裸字符串 | 在第 5 个 commit 一并清理 | 与空状态同属"杂项清理"批次 |

---

## 3. 颜色体系

### 3.1 Layer 1 — 基础调色板（Asset Catalog）

写进 `Assets.xcassets/Palette/`，每个色集都提供 Light / Dark 两套。统一基调：HSB ≈ S70 B95（暗色模式 S60 B70）。

| 命名 | 用途线索 | 大致色相 |
|---|---|---|
| `Palette/Peach` | 库存 Tab 风味色（沿用并校准现 AccentColor） | 桃粉 |
| `Palette/Coral` | 扫描 Tab 风味色 | 珊瑚橙 |
| `Palette/Lavender` | 计划 Tab 风味色 | 薰衣草紫 |
| `Palette/Mint` | 统计 Tab 风味色 | 薄荷绿 |
| `Palette/Sky` | 更多 Tab 风味色 | 天蓝 |
| `Palette/Lemon` | 储备色（用于第二级图表系列 / 装饰） | 柠檬黄 |
| `Palette/Rose` | 储备色 | 玫红 |
| `Palette/Neutral50` ~ `Neutral900` | 中性灰阶 5 档 | 灰 |

> **注**：现有的 `AccentColor.colorset`（RGB 0.557/0.463/0.984）实测偏紫蓝。本次会把它**重命名为 `Palette/Peach`** 并重新校色到真正的桃粉系，以匹配文案描述；旧 `AccentColor` 名保留为 alias 指向 `Palette/Peach`，避免一次性破坏太多调用点。

### 3.2 Layer 2 — 语义 Token（Theme.Color）

视图层只允许引用语义 token，不允许引用 Layer 1 调色板（调色板仅供 Theme 内部映射使用）。

```swift
enum Theme {
  enum Color {
    enum Interactive { static let primary, secondary, destructive: SwiftUI.Color }
    enum Status     { static let success, warning, error, info: SwiftUI.Color }
    enum Text       { static let primary, secondary, tertiary, onAccent: SwiftUI.Color }
    enum Surface    { static let background, elevated, subtle: SwiftUI.Color }
    enum Border     { static let `default`, emphasis, divider: SwiftUI.Color }
  }
}
```

| Token | 映射 | 说明 |
|---|---|---|
| `Interactive.primary` | 当前 Tab 风味色 | 由 `TabFlavorEnvironment` 注入；非 Tab 上下文（深层页面）回退到 Peach |
| `Interactive.secondary` | Neutral200 / Neutral700 | 次按钮、tinted style |
| `Interactive.destructive` | 系统红校准版 | 删除、移除 |
| `Status.success` | 校准绿 | 完成、库存够、模型已下载 |
| `Status.warning` | 校准琥珀 | 低库存、需注意 |
| `Status.error` | 校准红（与 destructive 同源但允许同义存在） | 失败、库存不足 |
| `Status.info` | 校准蓝 | 信息提示、统计图表中性系列 |
| `Text.primary/secondary/tertiary` | Neutral900/600/400 | 三档文字层级 |
| `Text.onAccent` | 白 / 黑（依风味色对比度自动） | 用在风味色 fill 上的文字 |
| `Surface.background` | systemGroupedBackground | List 背景 |
| `Surface.elevated` | systemBackground | 卡片底色 |
| `Surface.subtle` | Neutral50 | 弱强调底色 |
| `Border.default` | Neutral200 | 默认描边 |
| `Border.emphasis` | 当前风味色 | 选中态描边 |
| `Border.divider` | Neutral100 | 分隔线 |

### 3.3 Layer 3 — Tab 风味色（关键创新）

通过 `EnvironmentKey` 把当前 Tab 的风味色注入子视图，`Theme.Color.Interactive.primary` 自动取它：

```swift
struct TabFlavorKey: EnvironmentKey { static let defaultValue: SwiftUI.Color = .peach }
extension EnvironmentValues { var tabFlavor: SwiftUI.Color { ... } }

// ContentView:
TabView(selection: $selected) {
  InventoryView().environment(\.tabFlavor, .peach).tag(0)
  ScanView()     .environment(\.tabFlavor, .coral).tag(1)
  // ...
}
```

**作用范围**（**只**用于这些位置，不蔓延）：
- TabBar 选中色（跟随当前选中 Tab）
- 该 Tab 的 FAB（库存的 "+"、扫描的"拍照"等）
- 该 Tab 一级页面的页眉强调元素
- 该 Tab 的空状态插画
- `Interactive.primary` 通过环境拿到风味色（主按钮自动随 Tab 换色）

| Tab | 风味色 | 含义 |
|---|---|---|
| 库存 | Peach | 温暖、丰富、收藏感 |
| 扫描 | Coral | 行动、AI 识别 |
| 计划 | Lavender | 期待、未来、待办 |
| 统计 | Mint | 数据、冷静 |
| 更多 | Sky | 中性、设置 |

### 3.4 迁移规则

每个迁移 commit 必须满足：
- 涉及的视图文件里，**裸写的** `Color.red/.green/.orange/.blue/.gray/.pink/.purple/.yellow` 数量降为 0
- `.font(.system(size:…))` 数量降为 0
- `.cornerRadius(数字)` 改为 `.cornerRadius(Theme.Radius.xx)`
- `.padding(数字)` 改为 `.padding(Theme.Spacing.xx)`（除非数字 = 系统默认 16，可保留无参 `.padding()`）

最终验收：全应用 `grep "Color\\.\\(red\\|green\\|orange\\|blue\\|gray\\|pink\\|purple\\|yellow\\)"` 在 `BeadInventory/Views/` 下命中数应 ≈ 0（少量数据驱动的色板渲染除外，需在 PR 说明里列出豁免名单）。

---

## 4. 交互公约

### 4.1 多选

**触发**
- 主入口：长按列表 / 网格中的任意项 → 进入多选模式，被长按项默认选中
- 备入口：页面 toolbar trailing 的「选择」按钮

**视觉**
- 选中：单元格四周 2pt `Theme.Color.Border.emphasis` 边框 + 右上角填充对勾（用 `SF Symbol checkmark.circle.fill` 染色为 `Interactive.primary`）
- 未选中：单元格保持原样，右上角空心圆圈作为可选指示
- 多选模式下，**所有项**的非选中元素轻度降饱和（opacity 0.85），形成"选择态"的视觉环境

**操作位置**
- 底部 SafeArea 浮动 `MultiSelectActionBar`（不再用行内按钮也不挤占 toolbar）
- 左侧文案：`已选 N`
- 右侧按钮组：当前页相关的批量操作（合并 / 扣减 / 删除…）
- 退出：toolbar leading 显示「取消」按钮，点击退出多选

**触觉**
- 进入多选：`.sensoryFeedback(.selection, trigger:)`
- 切换单项：`.selection`
- 批量操作成功：`.success`

**应用范围**
- 库存（**新增**多选：批量隐藏、批量调整低库存阈值、批量扣减）
- 计划（**替换**现有 `isSelectMode` + 行内按钮）
- 扫描手动录入 `ManualEntrySheet`（统一为长按触发 + 底 Bar）
- 历史记录（**新增**多选批量回滚）

### 4.2 扫描流

**问题**：现状识别后 "创建计划" 和 "扣减库存" 两个 CTA 等权重；色号未匹配时 DeductionReviewSheet 在 sheet 里再开 sheet。

**新流程**：

```
ScanView (NavigationStack root)
  └─ Stepper: ① 识别 → ② 调整 → ③ 确认（顶部 3 段进度指示器）
  └─ 内容区（识别结果可编辑）
  └─ 底部 sticky:
       [扣减库存] (Filled, Interactive.primary, 全宽 56pt)
  └─ Toolbar trailing menu (…):
       - 仅创建计划，不扣减
       - 清空当前识别
       - 重新拍照

  点 [扣减库存]：
    若全部色号已匹配 → alert("确认扣减") → 完成（success haptic）
    若存在未匹配色号 → NavigationStack push 到 DeductionReviewView（不再用嵌套 sheet）
       └─ Review 完成后 alert("确认扣减") → 完成
```

**关键改动**
- "创建计划" **不消失**，只是从主 CTA 降级为 Menu 中的次级动作 —— 用户偶尔需要"只记录不扣减"
- Stepper 状态指示器让用户清楚当前阶段
- DeductionReview 从 sheet 改为 push，可以正常返回

### 4.3 Toolbar 公约

| 位置 | 内容 |
|---|---|
| Leading | 取消 / 返回（push 流自动；sheet 流手动放 "取消"） |
| Trailing 主 | 主操作（保存 / 完成 / 选择 / 扣减） |
| Trailing 末尾 | 溢出 Menu（"…" `ellipsis.circle`） |

- 禁止把主操作放 leading；禁止 leading + trailing 各放一个 destructive
- 多选模式下，leading=取消，trailing=「完成」（自动隐藏其它按钮）

### 4.4 导航策略

| 场景 | 选择 |
|---|---|
| 详情编辑（一项的所有字段） | `.sheet` + NavigationStack + `.presentationDetents([.large])` |
| 层级下钻（A 里看 B） | `NavigationLink` push |
| 相机 / 裁剪 / 全屏图像编辑 | `.fullScreenCover` |
| 多步向导 | `.sheet` + 内部 stepper |

- **禁止** sheet 里再开 sheet（如必要，应在同一 NavigationStack 内 push）
- **禁止**从 sheet 内打开 `fullScreenCover` —— 把 cover 提到根视图触发

### 4.5 触觉反馈（`BIHaptics`）

```swift
enum BIHaptics {
  static let selectionChange: SensoryFeedback = .selection
  static let saveSuccess:     SensoryFeedback = .success
  static let actionError:     SensoryFeedback = .error
}
```

**应用点**
- 切换 / 多选：`selectionChange`
- 保存 / 扣减成功 / 项目完成：`saveSuccess`
- 库存不足 / 网络失败 / 识别失败：`actionError`
- 普通点击不加触觉（避免噪音）

### 4.6 破坏性操作确认

- 一律 `.alert(role: .destructive)` 二次确认
- 文案模板：`"确认删除 {对象名} 吗？此操作无法撤销。"`
- StatisticsView 中目前缺二次确认的 swipe 全部补齐

---

## 5. 组件库（`Views/DesignSystem/`）

### 5.1 目录结构

```
BeadInventory/Views/DesignSystem/
  Theme.swift                  // Spacing / Radius / Typography / Color
  TabFlavor.swift              // EnvironmentKey + 风味色定义
  BIHaptics.swift              // 触觉 wrapper
  Components/
    BIRow.swift                // 通用列表行（leading icon + title + subtitle + trailing accessory）
    BIBadge.swift              // 语义彩色 pill (success/warning/error/info/accent 五档 + 自定义)
    BIColorSwatch.swift        // 拼豆色号方块 + 编号
    BIStatCard.swift           // 统计卡（icon + title + value，可选趋势）
    BISelectableCell.swift     // 多选包装层（边框 + 对勾 + haptic + 长按触发）
    BIPrimaryButton.swift      // 全宽 filled，自动取当前 Tab 风味色
    BISecondaryButton.swift    // tinted style
    BIDestructiveButton.swift  // 红色 destructive
    MultiSelectActionBar.swift // 多选底部浮动 ActionBar
```

`EmptyStateView` 已存在于 `Views/Components/`，本次**强制全员迁移**，不再新建。

### 5.2 Theme.swift 内容

```swift
enum Theme {
  enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
  }
  enum Radius {
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let pill: CGFloat = 999
  }
  enum Typography {
    // 语义字体，封装 SwiftUI 内置 + 必要的 weight/design
    static let pageTitle:      Font = .largeTitle.weight(.bold)
    static let sectionHeader:  Font = .headline
    static let cardTitle:      Font = .title3.weight(.semibold)
    static let body:           Font = .body
    static let metadata:       Font = .caption
    static let number:         Font = .title2.monospacedDigit().weight(.semibold)
  }
  // Color: 见 §3.2
}
```

### 5.3 组件设计要点

- `BIRow`：通过 `init(leading: Image?, title: String, subtitle: String?, trailing: AnyView?)` 配置，自动按 `Theme.Spacing.md` 内边距。
- `BIBadge`：`init(text: String, style: BadgeStyle)`，`BadgeStyle = .success/.warning/.error/.info/.accent/.custom(Color)`，使用 `Theme.Radius.pill`。
- `BIColorSwatch`：`init(hex: String, code: String, size: CGFloat = 40)`，含明度自适应文字色。
- `BIStatCard`：`init(icon: Image, title: String, value: String, trend: Trend?)`，使用 `Theme.Surface.elevated` 底色 + `Theme.Radius.md`。
- `BISelectableCell<Content>`：`init(isSelected: Binding<Bool>, onLongPressEnterSelectMode: () -> Void, @ViewBuilder content)`。
- `BIPrimaryButton`：从环境读 `tabFlavor`，自动作为 fill 色；高 56pt，全宽，`Theme.Radius.md`。
- `MultiSelectActionBar`：通过 `.safeAreaInset(edge: .bottom)` 挂载，左 count 右按钮组。

---

## 6. 提交计划（9 个 commit）

| # | 主题 | 改动范围 | 风险 | 验证 |
|---|---|---|---|---|
| 1 | `feat(theme): 引入 Theme.swift + Asset Catalog 调色板 + 语义色集` | 新增文件，零业务调用 | 低 | 编译通过 + 截图与 main 一致 |
| 2 | `feat(theme): TabFlavor 环境注入 + TabBar 跟随选中 tint` | ContentView + Theme | 低 | 切 5 个 Tab 看 tint 与 FAB 变色 |
| 3 | `refactor(ds): 抽 BIRow / BIBadge / BIColorSwatch，迁移核心调用点` | 库存 / 计划 / 统计 主列表行 | 中 | 三个 Tab 视觉回归 |
| 4 | `refactor(ds): BIStatCard + BIPrimary/Secondary/DestructiveButton` | StatCard / OverviewCard + 各页面主按钮 | 中 | 主按钮风格一致；统计卡视觉无差 |
| 5 | `refactor(empty): 收口三处手写空状态 + 中文裸字符串本地化` | StatisticsView / BrandManagerView / InventoryView | 低 | 触发空数据态 + zh/en 切换 |
| 6 | `feat(select): 统一多选公约 — 库存 / 计划 / 扫描手动录入 / 历史` | 4 处多选逻辑 + 新增 `BISelectableCell` / `MultiSelectActionBar` | **高** | 4 处多选完整回归（含触觉） |
| 7 | `feat(scan): 扫描流去歧义 — 单主 CTA + Stepper + 取消嵌套 sheet` | ScanView + DeductionReviewSheet → DeductionReviewView | **高** | 全扫描流回归（含未匹配色号分支） |
| 8 | `refactor(nav): toolbar 公约 + sheet/push/fullScreenCover 整改` | 全 Views 巡检 | 中 | 全 Tab 巡检 + 5 个 Sheet 入口回归 |
| 9 | `feat(haptics): BIHaptics 接入选择 / 保存 / 错误三态` | 散点接入 | 低 | 真机感受一遍 |

**风险点说明**
- Commit 6 / 7 是高风险，若实施时发现单 commit 太大，**允许**拆分为 6a/6b、7a/7b，但保持总数 ≤ 10。
- Commit 6 先于 7 落地的原因：多选公约需要 `BISelectableCell`，而扫描流的 ManualEntrySheet 也是多选场景之一，二者顺序耦合。
- 每个 commit 自包含：**单独 build 通过 + 可单独截图回归**，不允许"留个尾巴下一个 commit 修"。

**迁移期共存策略**
- Commit 1–2 之后，新旧颜色 / 字体短期并存；commit 3–4 完成核心组件后，"主流页面"先清零；commit 8 兜底全应用扫尾。
- 旧 `AccentColor` 名保留为 `Palette/Peach` 的 alias 至少持续到 commit 8，避免一次性破坏所有调用点。

---

## 7. 测试与回归策略

- **截图回归**：Commit 1 之前先在 main 跑一遍模拟器截图（5 个 Tab + 主要 sheet），存为基线；每个迁移 commit 完成后重新截图对比，目标"语义一致、风味色合理变更、布局零回归"。
- **多选回归清单**：库存批量隐藏 / 计划批量合并 / 扫描手动录入批量加 / 历史批量回滚 —— 每条都要走完触发 → 选 N 项 → 执行 → 退出。
- **扫描流回归清单**：拍照→识别→全匹配→扣减；拍照→识别→存在未匹配→Review→扣减；识别后改走"仅创建计划"分支。
- **触觉真机测试**：模拟器无法测，commit 9 须真机过一遍。
- **本地化抽检**：每个迁移 commit 切换一次系统语言到英文，看是否还有裸中文。

---

## 8. 风险与缓解

| 风险 | 缓解 |
|---|---|
| Tab 风味色环境注入在深层视图丢失 | 在每个 Tab 的根 View 上明确 `.environment(\\.tabFlavor, .peach)` 等；深 push 的 NavigationLink 自动继承；Sheet 内手动透传一次 |
| `AccentColor` 重命名破坏 SwiftUI 隐式 `.tint()` | 保留 alias；commit 1 完成后 grep 全应用 `AccentColor` 出现点逐一确认 |
| 多选触觉在某些机型表现不一致 | 仅用 SwiftUI 17+ `.sensoryFeedback`，不引第三方 |
| Commit 6 / 7 单 commit 过大 | 允许拆 6a/6b、7a/7b，总 commit 数控制在 10 以内 |
| 用户对某个 Tab 风味色不满意 | Tab 风味色在 Theme 单点定义，调色成本低；先按本设计落地，落地后留 1 个调色 commit 的预算 |
| 现存的 `Color(hex:)` 数据驱动渲染（拼豆色板）被误改 | 迁移规则明确豁免数据驱动色板；每个 commit PR 说明里列出豁免点 |

---

## 9. 后续（不在本次范围）

- 无障碍审计（VoiceOver / Dynamic Type 完整支持）
- 动画 / 转场系统（统一的 `BITransition` 库）
- iPad 自适应（SplitView / 多列）
- 设计系统 Storybook（用 Xcode Preview Macros 集中展示所有组件状态）
- 主题切换（白天 / 夜间外的第三套主题，比如"高对比度"或"复古"）
