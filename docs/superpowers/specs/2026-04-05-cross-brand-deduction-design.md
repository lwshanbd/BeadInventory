# 跨品牌扣减 & 相似色代替 — 设计文档

> 日期：2026-04-05
> 状态：已确认

## 背景

用户反馈单一品牌库存经常不够用，希望在扣减时能灵活切换品牌。同时，当某个颜色完全缺货时，希望系统能推荐视觉上相似的替代色。

## 需求总结

### 核心原则
- **用户自主选择权**：系统提供建议，但不替用户做决定
- **最小侵入**：保持现有交互习惯，仅在需要时提供额外能力

### 功能一：跨品牌扣减
- 默认统一品牌（主品牌），用户可对个别颜色单独切换扣减品牌
- 品牌切换限定在同一色系内（如都是 MARD 或都是 KAKA）
- 即使库存充足，用户也可以主动选择从其他品牌扣减

### 功能二：相似色代替
- 仅在同一品牌内查找相似色（跨品牌+跨颜色留作后续 TODO）
- 库存不足时自动弹出相似色建议
- 用户可随时手动触发查找相似色
- 展示方式：大色块 + 色号 + 库存，不暴露 Delta E 等技术参数
- 匹配策略：Delta E ≤ 20 的颜色中取最相似的 5 个

### 适用场景
- 扫描页（ScanView）直接扣减
- 计划执行页（PlannedProjectsView）执行计划
- 两个入口共享同一套组件

---

## 架构设计

### 方案：组件 + Service 双层抽取

```
┌─────────────────────────────────────────┐
│           ScanView / PlannedProjectsView │
│                    │                     │
│           ┌────────▼────────┐            │
│           │ DeductionItemRow │  ← 共享 UI │
│           └────────┬────────┘            │
│                    │                     │
│      ┌─────────────▼──────────────┐      │
│      │     DeductionResolver      │      │
│      │  (品牌分配 & 状态管理)       │      │
│      └──────┬──────────────┬──────┘      │
│             │              │             │
│  ┌──────────▼───┐  ┌──────▼──────────┐  │
│  │ ColorSimilar │  │ InventoryManager │  │
│  │ ityService   │  │ .deductFromStock │  │
│  │ (相似色算法)  │  │   (不变)         │  │
│  └──────────────┘  └─────────────────┘  │
└─────────────────────────────────────────┘
```

InventoryManager 的核心 `deductFromStock(brandId:colorCode:amount:)` 方法保持不变，DeductionResolver 逐条调用它。

---

## 模块一：ColorSimilarityService

### 职责
给定一个颜色，在同品牌的库存中查找视觉上最相似的替代色。

### 算法
1. 将 `colorHex` 转为 RGB，再转为 CIELAB 色彩空间
2. 用 CIE76 Delta E 公式计算色差：`sqrt((L1-L2)² + (a1-a2)² + (b1-b2)²)`
3. 过滤条件：`deltaE ≤ 20` 且该色在当前品牌有库存（`available > 0`）
4. 按 deltaE 升序排列，取 top 5
5. 排除原色本身

### 为什么选 CIE76
CIE76 实现简单（约 20 行代码），对拼豆这种饱和度较高的颜色场景足够区分，性能好。后续如果需要更精确可升级为 CIEDE2000，接口不变。

### 接口

```swift
struct SimilarColor {
    let beadColor: BeadColor
    let deltaE: Double          // 仅内部排序用，不暴露给用户
    let availableStock: Int     // 在指定品牌的可用库存
}

class ColorSimilarityService {
    func findSimilarColors(
        for mardCode: String,
        brandId: UUID,
        allColors: [BeadColor],
        brandStocks: [BrandStock],
        maxResults: Int = 5,
        maxDeltaE: Double = 20.0
    ) -> [SimilarColor]
}
```

---

## 模块二：DeductionResolver

### 职责
管理"一组待扣减颜色"的品牌分配状态，是 View 和 InventoryManager 之间的中间层。

### 核心数据结构

```swift
struct DeductionItem: Identifiable {
    let id: UUID
    let mardCode: String
    let colorCode: String       // 当前色系的显示色号
    var quantity: Int
    var brandId: UUID            // 当前分配的品牌（默认跟随主品牌）
    var isManualOverride: Bool   // 用户是否手动覆盖了品牌

    // 由 resolver 计算填充：
    var availableStock: Int      // 该品牌下此色的可用库存
    var isInsufficient: Bool     // availableStock < quantity
}
```

### 接口

```swift
class DeductionResolver: ObservableObject {
    @Published var items: [DeductionItem]
    @Published var primaryBrandId: UUID?

    /// 设置主品牌，所有未手动覆盖的 item 跟随切换
    func setPrimaryBrand(_ brandId: UUID)

    /// 为单个颜色切换品牌（标记为手动覆盖）
    func overrideBrand(for mardCode: String, to brandId: UUID)

    /// 重置某颜色回主品牌（取消手动覆盖）
    func resetToPrimary(for mardCode: String)

    /// 替换颜色（相似色代替）
    func substituteColor(original mardCode: String, with newMardCode: String)

    /// 刷新所有 item 的库存状态
    func refreshStockStatus(brandStocks: [BrandStock])

    /// 获取所有库存不足的 item
    var insufficientItems: [DeductionItem] { get }

    /// 执行扣减：逐条调用 InventoryManager.deductFromStock
    func executeDeductions(via manager: InventoryManager) -> Bool
}
```

### 关键行为
- `setPrimaryBrand` 时，只更新 `isManualOverride == false` 的 item
- `substituteColor` 替换 mardCode 和 colorCode，保留 quantity 和品牌分配
- `refreshStockStatus` 在任何品牌切换或颜色替换后自动调用
- `executeDeductions` 逐条用各自的 `brandId` 调用现有的 `deductFromStock`

---

## 模块三：DeductionItemRow — 共享 UI 组件

### 职责
单个颜色行的展示，包含品牌切换、相似色入口、库存状态。在 ScanView 和 PlannedProjectsView 中复用。

### 布局

**正常状态**：
```
┌─────────────────────────────────────────────────────┐
│ 🟡  A2        ×12       库存 15 → 3      [品牌A ▾] │
└─────────────────────────────────────────────────────┘
```

**库存不足 + 相似色自动弹出**：
```
┌─────────────────────────────────────────────────────┐
│ 🔴  B3        ×8        库存 3 → -5  ⚠️  [品牌A ▾] │
│  ┌───────────────────────────────────────────────┐  │
│  │ 相似色： 🟡B2 (库存20) [使用]                 │  │
│  │         🟡B4 (库存15) [使用]                 │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

**手动覆盖品牌**：
```
┌─────────────────────────────────────────────────────┐
│ 🟡  A2        ×12       库存 15 → 3      [品牌B ▾] │
│                                    已覆盖 ↩️        │
└─────────────────────────────────────────────────────┘
```

### 交互

1. **品牌切换**：右侧 Menu，列出同色系所有品牌，点击切换。切换后显示"已覆盖"标签和重置按钮。
2. **相似色入口**：
   - 自动触发：`isInsufficient == true` 且有相似色结果时，行下方自动展开建议区
   - 手动触发：长按颜色行或点击搜索图标，弹出相似色 Sheet
3. **相似色 Sheet**：顶部显示原色色块做对比，列表展示大色块 + 色号 + 库存 + "使用此色"按钮。不暴露 Delta E。
4. **库存状态**：沿用三色方案——红色（不足）、橙色（低库存）、绿色（充足）

### 组件接口

```swift
struct DeductionItemRow: View {
    let item: DeductionItem
    let beadColor: BeadColor?
    let matchingBrands: [Brand]
    let similarColors: [SimilarColor]

    var onBrandChanged: (UUID) -> Void
    var onResetBrand: () -> Void
    var onSubstitute: (String) -> Void
}
```

---

## 模块四：现有页面改造

### ScanView

1. 扫描结果确认后，用 `recognizedItems` 初始化 `DeductionResolver`
2. 确认阶段的颜色行替换为 `DeductionItemRow`（扫描识别阶段的编辑行不变）
3. 顶部品牌选择器保留，切换时调用 `resolver.setPrimaryBrand()`
4. 确认扣减改为 `resolver.executeDeductions(via: inventoryManager)`
5. 确认弹窗增强：如有手动覆盖品牌的颜色，列出"以下颜色将从其他品牌扣减"

### PlannedProjectsView

1. ExecutePlannedProjectSheet 中用项目的 `beadUsage` 初始化 `DeductionResolver`
2. 品牌选择列表保留，选择时调用 `resolver.setPrimaryBrand()`
3. 品牌选择下方加入颜色列表，用 `DeductionItemRow` 展示
4. 执行逻辑：通过 resolver 扣减，再更新项目状态，每条 `BeadUsage` 记录实际 brandId

### InventoryManager

- `deductFromStock` 方法不变
- `executePlannedProject` 小幅调整：支持每条 BeadUsage 有不同的 brandId

---

## 新增文件清单

| 文件 | 位置 | 说明 |
|------|------|------|
| `ColorSimilarityService.swift` | Managers/ | 相似色算法 |
| `DeductionResolver.swift` | Managers/ | 扣减解析器 |
| `DeductionItem.swift` | Models/ | 扣减项数据结构 |
| `DeductionItemRow.swift` | Views/Components/ | 共享颜色行组件 |
| `SimilarColorSheet.swift` | Views/Components/ | 相似色选择 Sheet |

## 改动文件清单

| 文件 | 改动幅度 | 说明 |
|------|---------|------|
| ScanView.swift | 中等（~80 行） | 确认阶段接入 resolver + 替换行组件 |
| PlannedProjectsView.swift | 中等（~100 行） | ExecuteSheet 接入 resolver + 加颜色列表 |
| InventoryManager.swift | 小（~20 行） | executePlannedProject 支持多品牌 |

---

## 后续 TODO

- 跨品牌 + 跨颜色的相似色建议（当前仅同品牌内）
- Delta E 阈值和数量可配置化（当前硬编码 20 / 5）
- CIEDE2000 算法升级（如 CIE76 不够精确）
