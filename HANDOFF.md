# Handoff · 二级页重新设计落地

## 背景

设计稿（HTML / React）已经做完，存在两个文件：

- `index.html` —— 主 Tab（库存 / 工作台 / 统计 / 更多 / Dark）的重新设计
- `more-pages.html` —— 「更多」里 9 个子页的重新设计 + 一份「二级页骨架」+ 一份「能 / 不能」对照表

你的任务是把 `more-pages.html` 里的 9 个子页 + 骨架/守则，落地到 SwiftUI 代码里，替换现有那些还在用 `.listStyle(.insetGrouped)` + 系统色的旧实现。

> 设计稿不是像素级蓝图。你不需要复刻每个 div 的间距 —— 但 **必须** 把规则、组件抽象、色彩、信息结构搬过去。代码风格仍然按本仓库已有的 SwiftUI / Theme.swift 模式。

---

## 必读 · 三件事

### 1) 设计稿目录

- `more-pages.html` 的入口 React 文件 = `screens/more-pages-a.jsx` + `screens/more-pages-b.jsx` + `screens/more-pages-common.jsx`
- 主 Tab 设计稿 = `screens/*.jsx`（已经基本对齐过的版本）
- 视觉 tokens = `tokens.css`（与 SwiftUI 里的 `BeadInventory/Views/DesignSystem/Theme.swift` 一一对应）

打开 `more-pages.html` 看每块 artboard，每块对应一个要落地的 SwiftUI View。

### 2) 现有设计系统

`BeadInventory/Views/DesignSystem/Theme.swift` 已经有：
- `Theme.Spacing.{xs,sm,md,lg,xl,xxl}`
- `Theme.Radius.{sm,md,lg,pill}`
- `Theme.Typography.{pageTitle,sectionHeader,cardTitle,body,metadata,number,wordmark}`
- `Theme.ColorToken.Surface.{background,elevated,subtle,strong}`
- `Theme.ColorToken.Text.{primary,secondary,tertiary,onAccent}`
- `Theme.ColorToken.Morandi.{latte,rose,sage,mist,mauve,honey}`
- `Theme.ColorToken.Status.{success,warning,error,info}`
- `Theme.ColorToken.Border.{default,divider}`

`BeadInventory/Views/DesignSystem/Components/` 已经有 BIBadge / BIChip / BIRow / BIPrimaryButton / BISecondaryButton / BIDestructiveButton / BISegmented / BIStatCard / BIStepper / BeadView / Wordmark 等。**先看看能不能复用，再决定要不要新建。**

### 3) 已存在的偏离

参考 `more-pages.html` 中 00 号 artboard 的「能 / 不能」对照表逐条执行。**最重要的几条：**

| 不能 | 必须 |
|---|---|
| `Color(.systemGroupedBackground)` / `Color(.systemBackground)` | `Theme.ColorToken.Surface.background` |
| `.listStyle(.insetGrouped)` + `List` | `ScrollView { LazyVStack { ... } }` + `BIGroupCard` |
| `.pink` / `.blue` / `.cyan` / `.purple` / `.orange` / `.indigo` | `Theme.ColorToken.Morandi.*`（页面 flavor） |
| `.accentColor` 默认蓝 | 当前页面 flavor |
| 默认 Toggle 绿色 | `.tint(Theme.ColorToken.Morandi.sage)` |
| `.font(.largeTitle.bold())` 在二级页 | `SecondaryNav` 居中 16/600 标题 |
| Status.warning / Status.error 当主色 | Status 仅用于警示态；主色用 flavor |
| 默认 TextField / SecureField 灰白底 | 包在 `Theme.ColorToken.Surface.subtle` 圆角 10 的容器里 |
| 同屏 ≥ 3 个 Morandi 色 | ≤ 2 个 Morandi + 1 个 status 色 |

---

## 关键守则（请在所有页面贯彻）

### 🚫 不要给色号编中文名字
拼豆色号有两三百个，**不要为它们造名字**（雪糕白 / 蜜桃粉 / 玫瑰豆沙 这种全是设计稿早期的错误示范，现在已经清掉了）。展示色号时只用：
- **色号 code**（A01 / B12 / F05）
- **HEX**（如需要）
- **bead 圆点 + 实际颜色**

只有 `CustomColor`（用户自定义色号）才显示用户自己取的名字 —— 那是用户输入的字段，不是 App 编出来的。

### 🎨 二级页 flavor 跟随入口图标色
不是 TabBar 的 mist。例如：
- 关于 / 运输 → `Morandi.latte`
- 成品日历 → `Morandi.sage`
- 历史记录 → `Morandi.honey`
- 色号转换 / 自定义色号 / AI 识别 → `Morandi.mauve`
- 品牌设置 / 品牌管理 → `Morandi.rose`

CTA / 选中态 / 进度条 / FAB 都用本页 flavor。

### 🧱 二级页统一骨架
```
SecondaryNav（返回 + 居中标题 + 0–2 个 IconBtn）
└─ ScrollView
   ├─ Hero / 总览卡（可选）
   ├─ BIGroupCard（标题 + 卡片）
   ├─ BIGroupCard
   ├─ ...
   └─ 危险区 BIGroupCard（独立，里面放 BIDangerRow）
（可选）粘底 CTA
```

---

## 任务清单（按优先级排序）

### Phase 0 · 设计系统补充组件

先把这些组件加进 `BeadInventory/Views/DesignSystem/Components/`，让后续 9 个页面有现成砖头可用：

1. **`BISecondaryNav.swift`** —— 二级页顶 nav。`init(title: String, leading: () -> View = backButton, trailing: () -> View = EmptyView)`. 高度 44，标题居中 16/600，背景 transparent。
2. **`BIGroupCard.swift`** —— `init(title: String? = nil, footer: String? = nil) { content }`. 18 圆角 + 1px border + elevated 底 + horizontal padding 18。内部子项之间需要 1px divider，divider 左侧留 60px 缩进（让 icon 上下对齐）。
3. **`BIListRow.swift`** —— 通用列表行。`init(icon: String, iconColor: Color, title: String, subtitle: String? = nil, trailing: Trailing = .chevron)`. trailing 枚举支持 `.chevron / .badge(String) / .toggle(Binding<Bool>) / .meta(String) / .new / .none`. （`MoreView.swift` 里的 `MoreCardRow` 改名搬过来即可。）
4. **`BIDangerRow.swift`** —— 危险行。icon background = error * 0.1，文字 = error。
5. **`BIGroupHeader.swift`** —— 卡片间分组标题。`init(title: String, hint: String? = nil)`. 13/600，padding `0 22px 8px`。
6. **`BIEmptyHero.swift`** —— 暖色空状态。`init(icon: String, flavor: Color, title: String, subtitle: String, cta: () -> View)`. 80×80 圆角 24 的 flavor*0.15 底 + 右下角一颗 bead。
7. **`BISearchBar.swift`** —— 搜索框。带 ⌘K 提示徽章；可选 clear button。包在 elevated 容器里。

每个组件都加一个 `#Preview` 用 morandi 各色测一下。

### Phase 1 · 9 个二级页（按 artboard 顺序）

每个对应一块 artboard，artboard label 在下面括号里。

| # | 文件 | 对应 artboard | 关键点 |
|---|---|---|---|
| 1 | `AboutView.swift` | `about` | hero（latte→honey 渐变 + bead）/ Made for YJ 用 Georgia italic 800 30px / 应用数据 3 列 flex stat / 致谢卡 / 「支持原创」honey 渐变卡 / 法律链接 list / 备案小字 |
| 2 | `CalendarView.swift` | `cal-main` + `cal-day` | 月份导航是独立卡片（sage chevron btn）/ 月度统计 hero / 周历用 GroupCard 包 / 有作品的日期叠 1–3 颗 bead 圆点 / 今天用实色 sage / day sheet 用半屏 sheet 风格 |
| 3 | `ShippingView.swift` | `ship-list` + `ship-empty` + `ship-detail` | 顶部 latte→honey 渐变 hero / 卡片化运输单（左边色 latte 立边代表 shipping）/ filter chips / 详情页有时间轴 / 粘底 CTA「标记为已到货」/ Empty 用 BIEmptyHero |
| 4 | `HistoryView.swift` | `hist-list` + `hist-select` | 按 "今天 / 昨天 / 更早" 分组 BIGroupCard / 每条 row 用 morandi 各色 icon 区分操作类型 / 选择态用 honey / 底部多选操作条独立浮起 |
| 5 | `ColorConverterView.swift` | `conv-empty` + `conv-results` | BISearchBar 带 ⌘K / 源色卡用 hex 渐变背景 / 跨品牌行带相似度% / Empty 给「试试这些」+ 最近查询 / **绝不要造中文色名** |
| 6 | `CustomColorsView.swift` | `custom-main` + `custom-edit` | 卡片左 honey 立边代表自定义 / 显示用户自取的名字（用户自定义所以可以）/ FAB mauve / 编辑半屏 sheet 含品牌启用 toggle 列表 |
| 7 | `SettingsView.swift` 中的 `RecognitionSettingsSections` | `ai-cloud` | 状态卡（success 立边）/ AI 提供商 radio list / API 配置卡 / 教程链接 |
| 8 | `BrandSettingsView.swift` | `bs-main` | 品牌 hero（rose→latte 渐变 + 品牌首字）/ 品牌信息 / 库存提醒 stepper / 库存操作 / **危险区独立 GroupCard** 放重置 / 清除 / 删除三个 BIDangerRow |
| 9 | `BrandManagerView.swift` | `bm-main` | 总览 hero + brand icon cluster / tip 提示 / 列表卡片（左 rose 立边 = current，drag handle，圆角 14）/ 合并品牌按钮在底 / FAB rose |

### Phase 2 · 顺手清理

打开 `more-pages.html` 的 artboard 旁边对照 —— 这 3 个虽然没单独画但归在「更多」下面，照同样原则改：

- `BrandManagerView` 里的 `EmptyStateView` —— 替换成 `BIEmptyHero`
- `DataToolsView` / `DiagnosticsToolsView`（在 `MoreView.swift` 同文件底）—— 全是 `.indigo` `.cyan` `.green` `.orange`，全部替换成 morandi.{mauve/mist/honey/sage}
- `HiddenColorsManageView` / `ImportFullDataView` / `BackupRestoreView` / `AddBrandView` / `CustomColorEditView` / `ColorDetailSheet` / `PurchaseRecordDetailView` —— 如果还在用 `.systemBackground` 或 `List + insetGrouped`，统统按 BIGroupCard 改造

---

## 提交策略

1. **Phase 0 一个 PR** —— 7 个新组件 + 各自 #Preview，不动业务代码
2. **Phase 1 拆 9 个小 PR** —— 一页一个 PR，每个 PR 必须附 before / after 截图，便于 review
3. **Phase 2 一个 PR** —— 收尾清理

每个 PR 之前自查 `more-pages.html` 里 00 号 artboard 那张「Code Review checklist」十条，全部打勾再提。

---

## 不要做的事

- 不要为了「视觉好看」加你自己想出来的功能（新分组 / 新统计项 / 新文案）。如果设计稿没有，就不要加 —— 有空可以问。
- 不要保留旧实现的 navigationTitle largeTitle 大标题，二级页一律改成 SecondaryNav。
- 不要重新发明组件 —— 先在 `DesignSystem/Components/` 里翻一遍。
- 不要给色号编名字。
- 不要 git push 没经过用户同意。

---

## 验收标准

落地完之后，跑一遍：

```bash
# 全编译
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory \
  -destination 'platform=iOS Simulator,name=iPhone 16' build

# 全文搜应该 0 个匹配（除了 SwiftUI 内部 SDK 使用）
grep -rn "Color(.systemGroupedBackground)" BeadInventory/Views
grep -rn "Color(.systemBackground)" BeadInventory/Views
grep -rn "Color.pink\|Color.blue\|Color.cyan\|Color.purple\|Color.orange\|Color.indigo" BeadInventory/Views
grep -rn "\.accentColor" BeadInventory/Views
grep -rn "listStyle(\.insetGrouped)" BeadInventory/Views
```

最后跑一遍 iOS 模拟器，点过 9 个页面截图，跟 `more-pages.html` 里对应 artboard 摆在一起人工对比一遍。
