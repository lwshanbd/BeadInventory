# 色彩模式（Color Mode）功能设计

- 日期：2026-05-22
- 状态：草稿 · 等待用户复审
- 关联代码：`BeadInventory/Views/DesignSystem/Theme.swift`、`BeadInventory/Assets.xcassets/Palette/Bg.colorset`、`BgElev.colorset`、`BeadInventory/Models/SwiftDataMigration.swift`、`BeadInventory/Managers/InventoryManager.swift`（同步链路参考）
- 与并行 agent 的接触面：`Localizable.xcstrings`（新增 `color_mode.*` 键，会有合并冲突）；`Theme.swift`、`MoreView.swift`、`SwiftDataMigration.swift`（取决于并行 agent 改动）

---

## 1. 背景与目标

App 的视觉主调由 `Palette/Bg`（米奶 `#FAF5EC` / 深底 `#1B1714`）与 `Palette/BgElev`（卡片底）两个 colorset 控制，浅色 / 深色由 Asset Catalog 的 appearance variant 自动切换。

本功能让用户能：

1. **自定义** 浅色和深色模式各自的 `Bg` 与 `BgElev` —— 共 4 个色值
2. 从一组**内建预设**里一键应用（含"只应用浅色"/"只应用深色"/"全应用"三种粒度）
3. 用**系统 ColorPicker** 自由选色，并把当前 4 色**保存为命名主题**进入"我的主题"库
4. 通过云同步把"我的主题"跨设备共享

非目标（明确不做）：

- 不允许用户改 `Text/*`、`Border/*`、`Decorative/*`、`Morandi/*`、`Status/*` 等其它 token
- 不做 WCAG 对比度校验，信任用户的审美
- 不做截图回归测试

---

## 2. 关键决策汇总（来自 brainstorming）

| # | 决策项 | 选定方案 |
|---|---|---|
| Q1 | 色调范围 | Bg + BgElev 两层 Surface |
| Q2 | 明暗耦合 | light/dark 完全独立编辑 |
| Q3 | 预设组织 | 配对预设 + 一键应用其中一层（"全应用 / 仅浅色 / 仅深色"） |
| Q4 | 自定义保存 | 可保存为命名方案（"我的主题"列表） |
| Q5 | 同步范围 | 主题库同步、"当前选中"本机 |
| Q6 | 调色板颗粒度 | 系统 ColorPicker，不加 WCAG 限制 |
| Q7 | 预览时机 | 实时全局生效 + 未提交退出时弹"保存/放弃" |
| Q8 | 调色页布局 | 同时展示 4 个 swatch（浅 Bg / 浅 Elev / 深 Bg / 深 Elev） |

实现方案在三种里选了 **A：`ThemeManager` + `Theme.ColorToken` 透传**，原因：
- 业务调用面 0 改动（与并行 agent 的合并冲突最小）
- 与现有 `InventoryManager` 同步链路同构
- `UIColor { trait in ... }` 让 iOS 系统外观决定取哪一面，符合"两面独立但跟随系统"的诉求

---

## 3. 架构

```
BeadInventoryApp
  @State themeManager = ThemeManager.shared
  .environment(themeManager)
        │
        ▼
ThemeManager (@Observable, singleton + env)
  ├ resolvedLight / resolvedDark : ColorPalette
  ├ activeSchemeID : UUID?
  ├ draft : Draft?
  ├ apply(scheme, target)
  ├ updateSwatch / beginDraft / commit / discard / reset
  ├ bootstrapBuiltinPresets / loadFromPersistence
        │ (读)                              │ (持久化)
        ▼                                   ▼
Theme.ColorToken.Surface           SwiftData (SDColorScheme)
  .background = Color(uiColor:)    UserDefaults (activeSchemeID, draftJSON)
  .elevated   = Color(uiColor:)
        │
        ▼
所有视图（无需修改，照常 Theme.ColorToken.Surface.*）
```

**核心约束**

- 业务侧仅 `Surface.background` 与 `Surface.elevated` 这两个 token 被改造，其余 token 不动
- `UIColor { trait in ... }` 闭包持有 `ThemeManager.shared` 强引用（单例不泄漏），让系统外观切换自动取对应一面
- `ThemeManager` 用 iOS 17 `@Observable`；视图通过 `@Environment(ThemeManager.self)` 订阅；`.shared` 兜底给 enum 静态访问点（`Theme.ColorToken`、`ShapeStyle` 扩展等无法读环境的位置）

---

## 4. 数据模型

### 4.1 内存（struct）

```swift
typealias ColorHex = String   // "RRGGBB" 大写无前缀，沿用 BeadColor.colorHex 风格

struct ColorPalette: Codable, Equatable, Hashable {
    var bg:     ColorHex
    var bgElev: ColorHex
}

struct AppColorScheme: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String           // 内建：本地化 key；自定义：用户输入
    var light: ColorPalette
    var dark:  ColorPalette
    var isBuiltin: Bool
    let createdAt: Date
    var updatedAt: Date
}
```

类型名加 `App` 前缀避免与 `SwiftUI.ColorScheme` 撞名。

### 4.2 SwiftData

```swift
@Model
final class SDColorScheme {
    @Attribute(.unique) var id: UUID
    var name: String
    var lightBgHex:     String
    var lightBgElevHex: String
    var darkBgHex:      String
    var darkBgElevHex:  String
    var isBuiltin: Bool
    var createdAt: Date
    var updatedAt: Date
}
```

- 注册到 `SwiftDataMigration.swift` 的 `Schema([...])`
- 不关联其它 entity，独立表
- 同步走与 `SDCustomColor` 同套差量合并（参考 `InventoryManager.swift:1838-1865`）
- `isBuiltin = true` 行也入库 + 同步，但 UI 禁编辑/禁删除

### 4.3 本机偏好（UserDefaults）

| Key | 含义 |
|---|---|
| `theme.activeSchemeID` | 当前应用方案的 UUID 字符串；nil 表示"自定义未保存" |
| `theme.light.bgHex` / `theme.light.bgElevHex` | 当 activeSchemeID == nil 时使用 |
| `theme.dark.bgHex` / `theme.dark.bgElevHex` | 同上 |
| `theme.pendingDraftJSON` | 进入调色页后未提交的 draft 状态（含 dirty 标记） |
| `theme.builtinVersion` | 内建预设版本号，用于 bootstrap 比对 |

解析失败一律回到 asset catalog 默认值，不抛异常。

### 4.4 内建预设

放 `BeadInventory/Resources/built_in_color_schemes.json`：

```jsonc
{
  "version": 1,
  "schemes": [
    {
      "id": "00000000-0000-0000-0000-000000000001",
      "name_key": "color_mode.preset.cream_latte",
      "light": { "bg": "FAF5EC", "bg_elev": "FFFFFF" },
      "dark":  { "bg": "1B1714", "bg_elev": "27201B" }
    },
    // 薄荷晨光 / 雾蓝海岸 / 暮色玫瑰 / 黑金 ...
  ]
}
```

5 个内建：
1. **奶油拿铁**（当前默认）—— 米奶 / 白  ⇄  深咖 / 暖深
2. **薄荷晨光** —— 清新绿白调
3. **雾蓝海岸** —— 冷色系
4. **暮色玫瑰** —— 暖粉系
5. **黑金**（深色为主）—— 浅色：象牙白 / 香槟金兜底；深色：纯黑 / 金辉

具体 hex 值待落地时由设计稿/用户拍板，本 spec 不卡死。UUID 写死在 JSON 中以保证跨设备同步内建唯一。

---

## 5. ThemeManager API

```swift
@Observable
final class ThemeManager {
    static let shared = ThemeManager()

    private(set) var activeSchemeID: UUID?
    private(set) var resolvedLight: ColorPalette
    private(set) var resolvedDark:  ColorPalette
    private(set) var draft: Draft?
    var isDirty: Bool { draft?.isDirty ?? false }

    func apply(scheme: AppColorScheme, target: ApplyTarget)
    func updateSwatch(_ slot: Slot, hex: String)
    func beginDraft()
    func commitAsNewScheme(name: String) throws -> AppColorScheme
    func discardDraft()
    func resetToBuiltinDefault()
    func bootstrapBuiltinPresets(modelContext: ModelContext)
    func loadFromPersistence(modelContext: ModelContext)
}

enum ApplyTarget { case both, lightOnly, darkOnly }
enum Slot { case lightBg, lightElev, darkBg, darkElev }

struct Draft {
    let snapshotActiveSchemeID: UUID?
    let snapshotLight: ColorPalette
    let snapshotDark:  ColorPalette
    var isDirty: Bool
}
```

---

## 6. 颜色解析链

```
View body
  └─ Theme.ColorToken.Surface.background          // 改为 computed
       └─ Color(uiColor: themeManager.dynamicBg)
            └─ UIColor { trait in
                 trait.userInterfaceStyle == .dark
                   ? UIColor(hex: themeManager.resolvedDark.bg)
                   : UIColor(hex: themeManager.resolvedLight.bg)
               }
```

**为什么必须用 `@Observable`**：`UIColor { trait in }` 闭包只在系统外观切换时被 iOS 调用，不会因为 `resolvedLight` 改变而重新评估。要让所有视图在改色后重绘，必须让 `Theme.ColorToken.Surface.background` 这个 computed property 在视图 body 评估时被识别为 ThemeManager 的依赖 —— `@Observable` 的线程局部 tracking 在 body 评估期间访问 `themeManager.resolvedLight` 即自动建立订阅，下次值变更触发整树 re-evaluate。

---

## 7. UI

入口：`MoreView` → 新增"色彩模式"行。

### 7.1 主页面 `ColorModeView`

```
┌─────────────────────────────────────────────┐
│  ←  色彩模式                          重置  │
├─────────────────────────────────────────────┤
│  当前方案：奶油拿铁（或"自定义（未保存）"）│
│  ┌────┬────┬────┬────┐                       │
│  │浅Bg│浅Elev│深Bg│深Elev│  ← 点击弹 ColorPicker
│  └────┴────┴────┴────┘                       │
│                              🌞⇄🌜 预览 toggle│
│                                              │
│ ── 预设方案 ──────────────                   │
│  ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐    │
│  │拿铁✓│ │晨光 │ │海岸 │ │玫瑰 │ │黑金 │    │
│  └─────┘ └─────┘ └─────┘ └─────┘ └─────┘    │
│                                              │
│ ── 我的主题 ──────────────                   │
│  [+ 保存为新主题…]   (dirty 时常显，否则灰)  │
│  ┌─────┐ ┌─────┐                             │
│  │咖啡⋯│ │暮色⋯│   ← ⋯ → 应用/重命名/删除   │
│  └─────┘ └─────┘                             │
└─────────────────────────────────────────────┘
```

### 7.2 交互细节

- **swatch 点击** → 弹系统 `ColorPicker`，`onChange` 实时写 ThemeManager；落盘 `pendingDraftJSON` 走 250ms debounce 或仅在 sheet `onDismiss` 写
- **任一 swatch 改色** → `activeSchemeID` 置 nil，标题切到"自定义（未保存）"
- **🌞⇄🌜 预览 toggle** → 调色页 `preferredColorScheme(.light/.dark)`，让浅色系统用户也能预览深色一面；退出页面恢复跟随系统
- **预设卡片单击** → confirmationDialog：`[全应用] / [仅浅色] / [仅深色] / 取消`
  - "全应用" → `activeSchemeID = scheme.id`，`isDirty = false`
  - "仅浅色"或"仅深色" → `activeSchemeID = nil`（因为已经不再是完整预设），`isDirty` 视改动而定
- **我的主题卡片** → `⋯` 按钮弹菜单（应用 / 重命名 / 删除）；同时支持 `contextMenu`。**不**用 `SwipeActionRow`（commit `09da85b` 修过的 contextMenu 被 SwipeActionRow 吃掉的坑），且整体改用网格 + ⋯ 按钮组合避开
- **保存为新主题** → TextField 弹窗输入名字 → 写入 SDColorScheme，`activeSchemeID` 指向新 id
- **重置** → 把 4 色恢复到 asset catalog 默认（= "奶油拿铁"），`activeSchemeID` 切到拿铁 id

### 7.3 离开页面流程

```
进入 ColorModeView
  → themeManager.beginDraft()    备份 (activeSchemeID, resolved)

[拖 swatch / 改色 → 实时全局生效, isDirty = true]

返回 / Tab 切换:
  !isDirty → 直接走
  isDirty  → confirmationDialog
    [保存为新主题…] → 弹 TextField → commitAsNewScheme(name:)
    [放弃改动]    → discardDraft() 还原快照
    [继续编辑]    → 取消手势
```

### 7.4 进程被杀的恢复

`loadFromPersistence` 优先级：
1. `pendingDraftJSON` 非空 → 恢复 `resolved` 与 `draft`，进 App 后弹 alert "恢复上次未保存的色彩改动？"（[保留] / [放弃]）
2. `activeSchemeID` 有值 → 查 SDColorScheme 套用
3. 否则套用奶油拿铁

### 7.5 国际化

所有字符串走 `Localizable.xcstrings`，主键 `color_mode.*`：

- `color_mode.title`、`color_mode.section.presets`、`color_mode.section.my_themes`、`color_mode.button.save_as_new`、`color_mode.button.reset`、`color_mode.label.current_scheme`、`color_mode.label.custom_unsaved`、`color_mode.dialog.discard_title` …
- 预设 5 个：`color_mode.preset.cream_latte` / `mint_dawn` / `mist_coast` / `dusk_rose` / `black_gold`
- zh-Hans + en 同步加键

---

## 8. 同步、迁移、兼容

### 8.1 SwiftData schema 迁移

在 `SwiftDataMigration.swift` 的 `Schema([...])` 追加 `SDColorScheme.self`。新增独立 entity，走 SwiftData 自动轻量迁移，无 migration plan 需要。

### 8.2 云同步（沿用 SDCustomColor 套路）

参考 `InventoryManager.swift:1838-1865` 的差量合并：

- 远端有、本地无、baseline 无 → 拉到本地
- 远端有、本地无、baseline 有 → 视为本地已删除，跳过
- 双方都有、`updatedAt` 不同 → 取较新者（last-write-wins）
- 本地有、远端无、baseline 有 → 视为远端删除，本地同删
- `isBuiltin = true` 行也走同步，但 UI 禁止编辑/删除（防止两端版本号不一致时各自生成重名内建）

### 8.3 内建预设版本管理

`bootstrapBuiltinPresets()` 在 App 启动时执行：

- `UserDefaults["theme.builtinVersion"] < json.version` → 5 个内建按 JSON 中固定 UUID upsert（强制覆盖名字 + 色值）
- 否则 skip
- 完成后写回 `theme.builtinVersion = json.version`

JSON 中 UUID 跨设备一致，避免同步出现 5 套同名内建。

### 8.4 与现有功能的兼容性

- **截图 / 分享 / PDF 导出**：颜色变化通过 `Theme.ColorToken.Surface` 透传，所有截图代码自动跟随，不需单独适配
- **`@Environment(\.tabFlavor)`**（`Theme.swift:91/95`）：与本功能正交，互不影响
- **`SwipeActionRow` / `contextMenu` 坑**（commit `09da85b`）：从设计上规避 —— "我的主题"用网格不用 List，且 ⋯ 按钮 + contextMenu 双入口

---

## 9. 性能考量

1. **`@Observable` 全树重渲染**：改一个 swatch 几乎所有 View body 被重新 evaluate。SwiftUI 的 diff 会拦截，实际 UIView 属性 mutation 极少。60fps 无压力。
2. **ColorPicker 拖动期间高频写 UserDefaults**：用 `Combine.debounce(250ms)` 或仅在 sheet `onDismiss` 时落盘 `pendingDraftJSON`，避免 60Hz 写盘。
3. **`UIColor { trait in ... }` 闭包持有 `ThemeManager.shared`**：单例不泄漏，trait change 回调极轻量。

---

## 10. 测试策略

### 10.1 单元测试

**`ThemeManagerTests`**
- `apply(scheme, target: .both)` 后 `resolvedLight/Dark` 与 scheme 一致，`activeSchemeID == scheme.id`
- `apply(scheme, target: .lightOnly)` 后只动 light，dark 保持，`activeSchemeID == nil`
- `updateSwatch(.lightBg, ...)` 后 `activeSchemeID == nil`
- `beginDraft → updateSwatch → discardDraft` 后完全还原快照
- `commitAsNewScheme` 写入 SDColorScheme 字段一一对应
- 非法 hex → fallback 默认，不抛异常

**`ColorSchemeSyncTests`**
- 远端新增 → 本地拉
- 双方修改 + updatedAt 更新者胜
- 本地删除 + baseline 有 → 远端同删
- 内建预设按固定 UUID upsert，不重复

**`BuiltinPresetBootstrapTests`**
- 版本号 0 → 5：写入 5 条
- 版本号 5 → 5：不动
- 版本号 5 → 6 且用户改过内建名：强制覆盖

### 10.2 手测清单

- 4 swatch 拖动 60fps（Instruments → Animation Hitches）
- 改色 → 切 Tab → confirmationDialog 弹出
- ColorPicker 拖动期间无 jetsam / battery 异常
- 浅色系统下 🌞⇄🌜 toggle 切到深色预览 → ColorPicker 弹窗自身颜色也跟着变
- 系统外观切换实时跟随
- iCloud 多设备：A 保存"咖啡" → B 拉到 → B 改色值 → A 看到更新
- 进程杀：拖一半 → 杀 → 重启 → 恢复提示出现 → 选放弃 → 状态还原

---

## 11. 实现里程碑

```
M1. 基础设施
  ├─ SDColorScheme 模型 + Schema 注册
  ├─ ColorPalette / AppColorScheme struct + Codable
  ├─ Theme.swift: Surface.background/.elevated 改 computed
  └─ ThemeManager 空壳 (硬编码默认)

M2. ThemeManager 完整 API + 持久化
  ├─ apply / updateSwatch / beginDraft / discardDraft / commit
  ├─ UserDefaults 偏好读写 (含 debounce)
  ├─ 进程恢复流程
  └─ 单元测试

M3. 内建预设
  ├─ Resources/built_in_color_schemes.json (5 个 + 固定 UUID)
  └─ bootstrapBuiltinPresets()

M4. UI - ColorModeView
  ├─ MoreView 入口
  ├─ 4 swatch + ColorPicker
  ├─ 预设区 + ActionSheet
  ├─ 我的主题区 + ⋯ 菜单
  ├─ 🌞⇄🌜 预览 toggle
  └─ 保存为新主题 / 重置

M5. 离开流程 + 进程恢复 UI
  ├─ confirmationDialog
  └─ 启动恢复 alert

M6. 同步
  └─ SDColorScheme 差量合并接入现有同步

M7. i18n
  └─ Localizable.xcstrings 加 color_mode.* (zh-Hans + en)
```

M1–M3 后端基础，可一气呵成；M4 大块 UI；M5/M6/M7 可并行收尾。

---

## 12. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 并行 agent 同时改 `Localizable.xcstrings` | rebase 时手动合并 `color_mode.*` 键 |
| `@Observable` + computed Surface 导致全树重绘 | SwiftUI diff 拦截，实测 60fps |
| ColorPicker 拖动高频 UserDefaults 写盘 | debounce 250ms 或仅 onDismiss 落盘 |
| 用户调出难看 / 不可读的配色 | 信任用户 + 提供"重置"按钮快速回到拿铁 |
| 同步出现重名内建 | JSON 固定 UUID + 内建 UI 禁编辑 |

---

## 13. 开放问题（待落地时决定）

1. 5 个内建预设的精确 hex 值（除了奶油拿铁 = 当前默认）
2. ColorPicker 落盘 debounce 是 250ms 还是仅 onDismiss —— 取实测体验决定
3. "重置"按钮是否需要二次确认（如果当前是 dirty，建议要；如果当前 = 拿铁 id，按钮可灰显）
