# 跨品牌扣减 & 相似色代替 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让用户在扫描扣减和计划执行时，可以逐颜色选择扣减品牌，并获得相似色替代建议。

**Architecture:** 新增 ColorSimilarityService（相似色算法）和 DeductionResolver（品牌分配状态管理）两个逻辑层，提取 DeductionItemRow 和 SimilarColorSheet 两个共享 UI 组件，最后分别接入 ScanView 和 PlannedProjectsView。InventoryManager 的核心 deductFromStock 方法保持不变。

**Tech Stack:** Swift, SwiftUI, SwiftData

**Parallelization:** Tasks 1+2 可并行，Tasks 4+5 可并行（合并后），Tasks 6+7 可并行。

---

## File Map

| 文件 | 操作 | 职责 |
|------|------|------|
| `Managers/ColorSimilarityService.swift` | 新建 | Hex→RGB→CIELAB 转换，Delta E 计算，相似色查询 |
| `Models/DeductionItem.swift` | 新建 | 扣减项数据结构 |
| `Managers/DeductionResolver.swift` | 新建 | 品牌分配状态管理，连接 View 和 InventoryManager |
| `Views/Components/SimilarColorSheet.swift` | 新建 | 相似色选择弹窗 |
| `Views/Components/DeductionItemRow.swift` | 新建 | 共享颜色行组件（品牌切换+相似色+库存状态） |
| `Views/ScanView.swift` | 修改 | 确认阶段接入 DeductionResolver + DeductionItemRow |
| `Views/PlannedProjectsView.swift` | 修改 | ExecuteSheet 接入 DeductionResolver + DeductionItemRow |
| `Managers/InventoryManager.swift` | 修改 | 新增 executePlannedProjectWithResolver 方法 |

---

### Task 1: ColorSimilarityService — 相似色算法

**Files:**
- Create: `BeadInventory/Managers/ColorSimilarityService.swift`

**可与 Task 2 并行执行。**

- [ ] **Step 1: 创建 ColorSimilarityService.swift**

```swift
//
//  ColorSimilarityService.swift
//  BeadInventory
//
//  相似色查找服务：基于 CIE76 Delta E 算法
//

import Foundation

struct SimilarColor {
    let beadColor: BeadColor
    let deltaE: Double
    let availableStock: Int
}

class ColorSimilarityService {

    // MARK: - Color Space Types

    private struct RGB {
        let r: Double, g: Double, b: Double
    }

    private struct LAB {
        let l: Double, a: Double, b: Double
    }

    // MARK: - Color Space Conversion

    private static func hexToRGB(_ hex: String) -> RGB? {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        h = h.replacingOccurrences(of: "#", with: "")
        guard h.count == 6, let n = UInt64(h, radix: 16) else { return nil }
        return RGB(
            r: Double((n >> 16) & 0xFF) / 255.0,
            g: Double((n >> 8) & 0xFF) / 255.0,
            b: Double(n & 0xFF) / 255.0
        )
    }

    private static func rgbToLAB(_ rgb: RGB) -> LAB {
        func linearize(_ c: Double) -> Double {
            c > 0.04045 ? pow((c + 0.055) / 1.055, 2.4) : c / 12.92
        }
        let lr = linearize(rgb.r)
        let lg = linearize(rgb.g)
        let lb = linearize(rgb.b)

        // D65 illuminant
        let x = (lr * 0.4124564 + lg * 0.3575761 + lb * 0.1804375) / 0.95047
        let y = (lr * 0.2126729 + lg * 0.7151522 + lb * 0.0721750)
        let z = (lr * 0.0193339 + lg * 0.1191920 + lb * 0.9503041) / 1.08883

        func f(_ t: Double) -> Double {
            t > 0.008856 ? pow(t, 1.0 / 3.0) : (7.787 * t + 16.0 / 116.0)
        }
        return LAB(
            l: 116.0 * f(y) - 16.0,
            a: 500.0 * (f(x) - f(y)),
            b: 200.0 * (f(y) - f(z))
        )
    }

    private static func deltaE(_ a: LAB, _ b: LAB) -> Double {
        let dl = a.l - b.l
        let da = a.a - b.a
        let db = a.b - b.b
        return sqrt(dl * dl + da * da + db * db)
    }

    // MARK: - Public API

    /// 在同品牌库存中查找与指定颜色最相似的替代色
    /// - Parameters:
    ///   - mardCode: 目标颜色的 MARD 码
    ///   - brandId: 品牌 ID（仅在此品牌库存中查找）
    ///   - allColors: 所有颜色定义
    ///   - brandStocks: 所有品牌库存
    ///   - maxResults: 最多返回几个结果（默认 5）
    ///   - maxDeltaE: 最大色差阈值（默认 20）
    /// - Returns: 按色差升序排列的相似色数组
    func findSimilarColors(
        for mardCode: String,
        brandId: UUID,
        allColors: [BeadColor],
        brandStocks: [BrandStock],
        maxResults: Int = 5,
        maxDeltaE: Double = 20.0
    ) -> [SimilarColor] {
        guard let target = allColors.first(where: { $0.mardCode == mardCode }),
              let targetRGB = Self.hexToRGB(target.colorHex) else {
            return []
        }
        let targetLAB = Self.rgbToLAB(targetRGB)

        var results: [SimilarColor] = []
        for color in allColors {
            guard color.mardCode != mardCode else { continue }
            guard let rgb = Self.hexToRGB(color.colorHex) else { continue }

            let de = Self.deltaE(targetLAB, Self.rgbToLAB(rgb))
            guard de <= maxDeltaE else { continue }

            let stock = brandStocks.first(where: {
                $0.brandId == brandId && $0.mardCode == color.mardCode
            })
            let available = stock?.available ?? 0
            guard available > 0 else { continue }

            results.append(SimilarColor(beadColor: color, deltaE: de, availableStock: available))
        }

        results.sort { $0.deltaE < $1.deltaE }
        return Array(results.prefix(maxResults))
    }
}
```

- [ ] **Step 2: 将文件添加到 Xcode 项目**

确保 `ColorSimilarityService.swift` 出现在 Xcode 项目的 Managers 组中。

- [ ] **Step 3: 构建验证**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add BeadInventory/Managers/ColorSimilarityService.swift
git commit -m "feat: 添加 ColorSimilarityService 相似色算法"
```

---

### Task 2: DeductionItem 模型

**Files:**
- Create: `BeadInventory/Models/DeductionItem.swift`

**可与 Task 1 并行执行。**

- [ ] **Step 1: 创建 DeductionItem.swift**

```swift
//
//  DeductionItem.swift
//  BeadInventory
//
//  扣减项数据结构：记录每个颜色的品牌分配状态
//

import Foundation

struct DeductionItem: Identifiable {
    let id: UUID
    var mardCode: String
    var colorCode: String           // 当前色系的显示色号
    var quantity: Int
    var brandId: UUID               // 当前分配的扣减品牌
    var isManualOverride: Bool      // 是否手动覆盖了品牌

    // 由 DeductionResolver 计算填充
    var availableStock: Int
    var isInsufficient: Bool

    // 相似色替换追踪
    var originalMardCode: String?
    var originalColorCode: String?

    init(mardCode: String, colorCode: String, quantity: Int, brandId: UUID) {
        self.id = UUID()
        self.mardCode = mardCode
        self.colorCode = colorCode
        self.quantity = quantity
        self.brandId = brandId
        self.isManualOverride = false
        self.availableStock = 0
        self.isInsufficient = false
    }
}
```

- [ ] **Step 2: 构建验证**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add BeadInventory/Models/DeductionItem.swift
git commit -m "feat: 添加 DeductionItem 扣减项数据模型"
```

---

### Task 3: DeductionResolver — 扣减解析器

**Files:**
- Create: `BeadInventory/Managers/DeductionResolver.swift`

**依赖 Task 2 (DeductionItem)。**

- [ ] **Step 1: 创建 DeductionResolver.swift**

```swift
//
//  DeductionResolver.swift
//  BeadInventory
//
//  扣减解析器：管理一组待扣减颜色的品牌分配状态
//

import Foundation
import SwiftUI

class DeductionResolver: ObservableObject {
    @Published var items: [DeductionItem] = []
    @Published var primaryBrandId: UUID?

    private weak var inventoryManager: InventoryManager?

    init(inventoryManager: InventoryManager) {
        self.inventoryManager = inventoryManager
    }

    /// 从扫描识别结果初始化
    func initializeFromRecognizedItems(
        _ recognizedItems: [(colorCode: String, quantity: Int)],
        primaryBrandId: UUID,
        colorSystem: ColorSystem
    ) {
        guard let manager = inventoryManager else { return }
        self.primaryBrandId = primaryBrandId
        self.items = recognizedItems.map { item in
            let color = manager.findColor(byCode: item.colorCode)
            let mardCode = color?.mardCode ?? item.colorCode
            let displayCode = color?.displayCode(for: colorSystem) ?? item.colorCode
            return DeductionItem(
                mardCode: mardCode,
                colorCode: displayCode,
                quantity: item.quantity,
                brandId: primaryBrandId
            )
        }
        refreshStockStatus()
    }

    /// 从计划项目的 BeadUsage 初始化
    func initializeFromBeadUsages(
        _ usages: [BeadUsage],
        primaryBrandId: UUID,
        colorSystem: ColorSystem
    ) {
        guard let manager = inventoryManager else { return }
        self.primaryBrandId = primaryBrandId
        self.items = usages.map { usage in
            let color = manager.findColor(byCode: usage.colorCode)
            let displayCode = color?.displayCode(for: colorSystem) ?? usage.colorCode
            return DeductionItem(
                mardCode: usage.colorCode,
                colorCode: displayCode,
                quantity: usage.quantity,
                brandId: primaryBrandId
            )
        }
        refreshStockStatus()
    }

    /// 设置主品牌，所有未手动覆盖的 item 跟随切换
    func setPrimaryBrand(_ brandId: UUID) {
        primaryBrandId = brandId
        for i in items.indices where !items[i].isManualOverride {
            items[i].brandId = brandId
        }
        refreshStockStatus()
    }

    /// 为单个颜色切换品牌（标记为手动覆盖）
    func overrideBrand(for mardCode: String, to brandId: UUID) {
        guard let i = items.firstIndex(where: { $0.mardCode == mardCode }) else { return }
        items[i].brandId = brandId
        items[i].isManualOverride = true
        refreshStockStatus()
    }

    /// 重置某颜色回主品牌
    func resetToPrimary(for mardCode: String) {
        guard let primaryBrandId,
              let i = items.firstIndex(where: { $0.mardCode == mardCode }) else { return }
        items[i].brandId = primaryBrandId
        items[i].isManualOverride = false
        refreshStockStatus()
    }

    /// 替换颜色（相似色代替）
    func substituteColor(originalMardCode: String, newMardCode: String, newColorCode: String) {
        guard let i = items.firstIndex(where: { $0.mardCode == originalMardCode }) else { return }
        if items[i].originalMardCode == nil {
            items[i].originalMardCode = items[i].mardCode
            items[i].originalColorCode = items[i].colorCode
        }
        items[i].mardCode = newMardCode
        items[i].colorCode = newColorCode
        refreshStockStatus()
    }

    /// 刷新所有 item 的库存状态
    func refreshStockStatus() {
        guard let manager = inventoryManager else { return }
        for i in items.indices {
            let stock = manager.getStock(brandId: items[i].brandId, mardCode: items[i].mardCode)
            items[i].availableStock = stock?.available ?? 0
            items[i].isInsufficient = items[i].availableStock < items[i].quantity
        }
    }

    /// 所有库存不足的 item
    var insufficientItems: [DeductionItem] {
        items.filter { $0.isInsufficient }
    }

    /// 是否有手动覆盖的 item
    var hasManualOverrides: Bool {
        items.contains { $0.isManualOverride }
    }

    /// 手动覆盖的 item 列表（用于确认弹窗展示）
    var manualOverrideItems: [DeductionItem] {
        items.filter { $0.isManualOverride }
    }

    /// 是否有被替换的颜色
    var hasSubstitutions: Bool {
        items.contains { $0.originalMardCode != nil }
    }

    /// 执行扣减：逐条调用 InventoryManager.deductFromStock
    func executeDeductions() -> Bool {
        guard let manager = inventoryManager else { return false }
        for item in items {
            _ = manager.deductFromStock(
                brandId: item.brandId,
                colorCode: item.mardCode,
                amount: item.quantity,
                shouldSave: false
            )
        }
        manager.saveData()
        return true
    }

    /// 生成 BeadUsage 数组（用于创建 ProjectRecord）
    func buildBeadUsages(isDeducted: Bool) -> [BeadUsage] {
        items.map { item in
            BeadUsage(
                colorCode: item.mardCode,
                brandId: item.brandId,
                quantity: item.quantity,
                isDeducted: isDeducted
            )
        }
    }
}
```

- [ ] **Step 2: 构建验证**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add BeadInventory/Managers/DeductionResolver.swift
git commit -m "feat: 添加 DeductionResolver 扣减解析器"
```

---

### Task 4: SimilarColorSheet — 相似色选择弹窗

**Files:**
- Create: `BeadInventory/Views/Components/SimilarColorSheet.swift`

**依赖 Task 1 (SimilarColor 类型)。可与 Task 5 并行（合并 Task 1-3 后）。**

- [ ] **Step 1: 创建 SimilarColorSheet.swift**

```swift
//
//  SimilarColorSheet.swift
//  BeadInventory
//
//  相似色选择弹窗
//

import SwiftUI

struct SimilarColorSheet: View {
    let originalColor: BeadColor?
    let originalColorCode: String
    let similarColors: [SimilarColor]
    let colorSystem: ColorSystem
    var onSelect: (SimilarColor) -> Void

    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                // 原色参照
                if let color = originalColor {
                    Section("原色") {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(color.color)
                                .frame(width: 48, height: 48)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                )
                            VStack(alignment: .leading) {
                                Text(originalColorCode)
                                    .font(.system(.body, design: .monospaced))
                                    .fontWeight(.medium)
                                if !color.colorName.isEmpty {
                                    Text(color.colorName)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .listRowBackground(Color(.systemGray6))
                    }
                }

                // 相似色列表
                if similarColors.isEmpty {
                    Section {
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundColor(.secondary)
                            Text("未找到相似色")
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    Section("可用相似色") {
                        ForEach(similarColors, id: \.beadColor.id) { similar in
                            Button {
                                onSelect(similar)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(similar.beadColor.color)
                                        .frame(width: 48, height: 48)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                        )

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(similar.beadColor.displayCode(for: colorSystem))
                                            .font(.system(.body, design: .monospaced))
                                            .fontWeight(.medium)
                                            .foregroundColor(.primary)
                                        if !similar.beadColor.colorName.isEmpty {
                                            Text(similar.beadColor.colorName)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }

                                    Spacer()

                                    VStack(alignment: .trailing) {
                                        Text("库存 \(similar.availableStock)")
                                            .font(.caption)
                                            .foregroundColor(.green)
                                    }

                                    Image(systemName: "arrow.right.circle.fill")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("查找相似色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
```

- [ ] **Step 2: 构建验证**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add BeadInventory/Views/Components/SimilarColorSheet.swift
git commit -m "feat: 添加 SimilarColorSheet 相似色选择弹窗"
```

---

### Task 5: DeductionItemRow — 共享颜色行组件

**Files:**
- Create: `BeadInventory/Views/Components/DeductionItemRow.swift`

**依赖 Tasks 1-4。**

- [ ] **Step 1: 创建 DeductionItemRow.swift**

```swift
//
//  DeductionItemRow.swift
//  BeadInventory
//
//  共享扣减颜色行组件：品牌切换 + 相似色入口 + 库存状态
//

import SwiftUI

struct DeductionItemRow: View {
    let item: DeductionItem
    let beadColor: BeadColor?
    let matchingBrands: [Brand]
    let similarColors: [SimilarColor]
    let colorSystem: ColorSystem
    let lowStockThreshold: Int
    let brandName: String

    var onBrandChanged: (UUID) -> Void
    var onResetBrand: () -> Void
    var onSubstitute: (String, String) -> Void  // (newMardCode, newColorCode)

    @State private var showingSimilarColorSheet = false

    private var stockAfter: Int {
        item.availableStock - item.quantity
    }

    private var isLowStock: Bool {
        !item.isInsufficient && stockAfter < lowStockThreshold
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 主行
            HStack(spacing: 10) {
                // 颜色预览
                colorPreview

                // 色号 + 库存
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(item.colorCode)
                            .font(.system(.body, design: .monospaced))
                            .fontWeight(.medium)
                        if item.originalMardCode != nil {
                            Text("(原 \(item.originalColorCode ?? ""))")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    }

                    // 库存状态
                    HStack(spacing: 4) {
                        Text("库存 \(item.availableStock)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("→")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("\(stockAfter)")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(item.isInsufficient ? .red : (isLowStock ? .orange : .green))
                        if item.isInsufficient {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundColor(.red)
                        } else if isLowStock {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    }
                }

                Spacer()

                // 数量
                Text("×\(item.quantity)")
                    .font(.headline)
                    .foregroundColor(.accentColor)

                // 品牌切换 Menu
                brandMenu
            }

            // 手动覆盖提示
            if item.isManualOverride {
                HStack {
                    Spacer()
                    Text("已覆盖")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Button(action: onResetBrand) {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .font(.caption2)
                            .foregroundColor(.accentColor)
                    }
                }
            }

            // 库存不足时自动展示相似色建议
            if item.isInsufficient && !similarColors.isEmpty {
                inlineSimilarSuggestion
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(item.isInsufficient ? Color.red.opacity(0.1) : Color(.systemGray6))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(item.isInsufficient ? Color.red.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .contextMenu {
            Button {
                showingSimilarColorSheet = true
            } label: {
                Label("查找相似色", systemImage: "magnifyingglass")
            }
        }
        .sheet(isPresented: $showingSimilarColorSheet) {
            SimilarColorSheet(
                originalColor: beadColor,
                originalColorCode: item.colorCode,
                similarColors: similarColors,
                colorSystem: colorSystem,
                onSelect: { similar in
                    onSubstitute(
                        similar.beadColor.mardCode,
                        similar.beadColor.displayCode(for: colorSystem)
                    )
                }
            )
        }
    }

    // MARK: - Sub Views

    @ViewBuilder
    private var colorPreview: some View {
        if let beadColor {
            RoundedRectangle(cornerRadius: 6)
                .fill(beadColor.color)
                .frame(width: 36, height: 36)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.3))
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: "questionmark")
                        .foregroundColor(.gray)
                )
        }
    }

    private var brandMenu: some View {
        Menu {
            ForEach(matchingBrands) { brand in
                Button {
                    onBrandChanged(brand.id)
                } label: {
                    HStack {
                        Text(brand.name)
                        if brand.id == item.brandId {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(brandName)
                    .font(.caption)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(item.isManualOverride ? Color.orange.opacity(0.15) : Color.accentColor.opacity(0.1))
            .foregroundColor(item.isManualOverride ? .orange : .accentColor)
            .cornerRadius(12)
        }
    }

    private var inlineSimilarSuggestion: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "lightbulb.fill")
                    .font(.caption2)
                    .foregroundColor(.yellow)
                Text("相似色可用：")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            ForEach(similarColors.prefix(3), id: \.beadColor.id) { similar in
                Button {
                    onSubstitute(
                        similar.beadColor.mardCode,
                        similar.beadColor.displayCode(for: colorSystem)
                    )
                } label: {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(similar.beadColor.color)
                            .frame(width: 16, height: 16)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
                            )
                        Text(similar.beadColor.displayCode(for: colorSystem))
                            .font(.caption2)
                            .fontWeight(.medium)
                        Text("(库存\(similar.availableStock))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("使用")
                            .font(.caption2)
                            .foregroundColor(.accentColor)
                    }
                }
                .buttonStyle(.plain)
            }

            if similarColors.count > 3 {
                Button {
                    showingSimilarColorSheet = true
                } label: {
                    Text("查看更多...")
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                }
            }
        }
        .padding(8)
        .background(Color.yellow.opacity(0.08))
        .cornerRadius(8)
    }
}
```

- [ ] **Step 2: 构建验证**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add BeadInventory/Views/Components/DeductionItemRow.swift
git commit -m "feat: 添加 DeductionItemRow 共享扣减颜色行组件"
```

---

### Task 6: ScanView 接入

**Files:**
- Modify: `BeadInventory/Views/ScanView.swift`

**依赖 Tasks 1-5。可与 Task 7 并行执行。**

- [ ] **Step 1: 在 ScanView 中添加 resolver 相关状态**

在 `ScanView` 的 `@State` 属性区域（约 line 38 附近 `@State private var showingCreatePlan = false` 之后）添加：

```swift
    // 扣减解析器
    @State private var deductionResolver: DeductionResolver?
    @State private var showingDeductionReview = false
    private let similarityService = ColorSimilarityService()
```

- [ ] **Step 2: 添加 resolver 初始化和相似色查找方法**

在 `ScanView` 的 `applyToInventory()` 方法之前（约 line 513 附近）添加：

```swift
    /// 准备扣减：初始化 resolver 并进入扣减审核
    func prepareDeduction() {
        guard let brandId = inventoryManager.currentBrandId,
              brandMatchesScanSystem else { return }

        let resolver = DeductionResolver(inventoryManager: inventoryManager)
        resolver.initializeFromRecognizedItems(
            recognizedItems.map { (colorCode: $0.colorCode, quantity: $0.quantity) },
            primaryBrandId: brandId,
            colorSystem: scanColorSystem
        )
        self.deductionResolver = resolver
        showingDeductionReview = true
    }

    /// 为指定颜色查找相似色
    func findSimilarColors(for mardCode: String, brandId: UUID) -> [SimilarColor] {
        similarityService.findSimilarColors(
            for: mardCode,
            brandId: brandId,
            allColors: inventoryManager.allBeadColors,
            brandStocks: inventoryManager.brandStocks
        )
    }
```

- [ ] **Step 3: 修改"扣减库存"按钮动作**

将 ScanView 中"扣减库存"按钮的 action（约 line 329-331）从：

```swift
                                        Button {
                                            showingConfirmation = true
                                        } label: {
```

改为：

```swift
                                        Button {
                                            prepareDeduction()
                                        } label: {
```

- [ ] **Step 4: 添加扣减审核 Sheet**

在现有的 `.alert("确认扣减"...)` 之后（约 line 451 附近）添加扣减审核 Sheet：

```swift
            .sheet(isPresented: $showingDeductionReview) {
                if let resolver = deductionResolver {
                    DeductionReviewSheet(
                        resolver: resolver,
                        colorSystem: scanColorSystem,
                        matchingBrands: inventoryManager.brands
                            .filter { $0.colorSystem == scanColorSystem }
                            .sorted { $0.sortOrder < $1.sortOrder },
                        inventoryManager: inventoryManager,
                        similarityService: similarityService,
                        onConfirm: {
                            applyToInventoryWithResolver(resolver)
                            showingDeductionReview = false
                        },
                        onCancel: {
                            showingDeductionReview = false
                        }
                    )
                }
            }
```

- [ ] **Step 5: 修改 applyToInventory 方法，添加 resolver 版本**

保留原有的 `applyToInventory()` 方法不变（作为 fallback），在其后添加 resolver 版本：

```swift
    /// 通过 resolver 执行扣减（支持跨品牌）
    func applyToInventoryWithResolver(_ resolver: DeductionResolver) {
        let thumbnailData = generateThumbnailData()

        let beadUsages = resolver.buildBeadUsages(isDeducted: true)
        let project = ProjectRecord(
            name: projectName.isEmpty ? "图纸\(Date().formatted(date: .numeric, time: .omitted))" : projectName,
            beadUsage: beadUsages,
            brandId: resolver.primaryBrandId,
            thumbnail: thumbnailData,
            colorSystem: scanColorSystem
        )
        inventoryManager.addProject(project)

        _ = resolver.executeDeductions()

        clearState()
        deductionResolver = nil
    }
```

- [ ] **Step 6: 创建 DeductionReviewSheet（在 ScanView.swift 底部或单独文件）**

在 ScanView.swift 底部（`RecognizedItemRowNew` 之后）添加：

```swift
// MARK: - 扣减审核弹窗
struct DeductionReviewSheet: View {
    @ObservedObject var resolver: DeductionResolver
    let colorSystem: ColorSystem
    let matchingBrands: [Brand]
    let inventoryManager: InventoryManager
    let similarityService: ColorSimilarityService
    var onConfirm: () -> Void
    var onCancel: () -> Void

    @State private var showConfirmAlert = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 主品牌选择
                HStack {
                    Text("主品牌:")
                        .foregroundColor(.secondary)
                    if let brand = matchingBrands.first(where: { $0.id == resolver.primaryBrandId }) {
                        Text(brand.name)
                            .fontWeight(.medium)
                    }
                    Spacer()
                    Menu {
                        ForEach(matchingBrands) { brand in
                            Button {
                                resolver.setPrimaryBrand(brand.id)
                            } label: {
                                HStack {
                                    Text(brand.name)
                                    if brand.id == resolver.primaryBrandId {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("切换")
                                .font(.caption)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.1))
                        .foregroundColor(.accentColor)
                        .cornerRadius(12)
                    }
                }
                .padding()

                Divider()

                // 颜色列表
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(resolver.items) { item in
                            let beadColor = inventoryManager.findColor(byCode: item.mardCode)
                            let brandName = matchingBrands.first(where: { $0.id == item.brandId })?.name ?? "未知"
                            let threshold = matchingBrands.first(where: { $0.id == item.brandId })?.lowStockThreshold ?? 100
                            let similarColors = similarityService.findSimilarColors(
                                for: item.mardCode,
                                brandId: item.brandId,
                                allColors: inventoryManager.allBeadColors,
                                brandStocks: inventoryManager.brandStocks
                            )

                            DeductionItemRow(
                                item: item,
                                beadColor: beadColor,
                                matchingBrands: matchingBrands,
                                similarColors: similarColors,
                                colorSystem: colorSystem,
                                lowStockThreshold: threshold,
                                brandName: brandName,
                                onBrandChanged: { newBrandId in
                                    resolver.overrideBrand(for: item.mardCode, to: newBrandId)
                                },
                                onResetBrand: {
                                    resolver.resetToPrimary(for: item.mardCode)
                                },
                                onSubstitute: { newMardCode, newColorCode in
                                    resolver.substituteColor(
                                        originalMardCode: item.mardCode,
                                        newMardCode: newMardCode,
                                        newColorCode: newColorCode
                                    )
                                }
                            )
                        }
                    }
                    .padding()
                }

                Divider()

                // 底部操作栏
                VStack(spacing: 8) {
                    // 统计信息
                    HStack {
                        Text("\(resolver.items.count) 种颜色")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("·")
                            .foregroundColor(.secondary)
                        Text("\(resolver.items.reduce(0) { $0 + $1.quantity }) 颗")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if !resolver.insufficientItems.isEmpty {
                            Text("·")
                                .foregroundColor(.secondary)
                            Text("\(resolver.insufficientItems.count) 种不足")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        Spacer()
                    }

                    Button {
                        showConfirmAlert = true
                    } label: {
                        HStack {
                            Image(systemName: resolver.insufficientItems.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            Text("确认扣减")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(resolver.insufficientItems.isEmpty ? Color.green : Color.red)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                }
                .padding()
            }
            .navigationTitle("扣减审核")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消", action: onCancel)
                }
            }
            .alert("确认扣减", isPresented: $showConfirmAlert) {
                Button("取消", role: .cancel) { }
                Button("确认", role: resolver.insufficientItems.isEmpty ? .none : .destructive) {
                    onConfirm()
                }
            } message: {
                let total = resolver.items.reduce(0) { $0 + $1.quantity }
                let count = resolver.items.count
                if resolver.insufficientItems.isEmpty && !resolver.hasManualOverrides {
                    Text("将扣减 \(total) 颗豆子，共 \(count) 种颜色。")
                } else {
                    var msg = "将扣减 \(total) 颗豆子，共 \(count) 种颜色。"
                    if resolver.hasManualOverrides {
                        let overrides = resolver.manualOverrideItems.compactMap { item in
                            if let brand = matchingBrands.first(where: { $0.id == item.brandId }) {
                                return "\(item.colorCode) → \(brand.name)"
                            }
                            return nil
                        }
                        msg += "\n\n跨品牌扣减：\n" + overrides.joined(separator: "\n")
                    }
                    if !resolver.insufficientItems.isEmpty {
                        msg += "\n\n⚠️ \(resolver.insufficientItems.count) 种颜色库存不足"
                    }
                    Text(msg)
                }
            }
        }
        .presentationDetents([.large])
    }
}
```

- [ ] **Step 7: 构建验证**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 8: Commit**

```bash
git add BeadInventory/Views/ScanView.swift
git commit -m "feat: ScanView 接入跨品牌扣减和相似色代替"
```

---

### Task 7: PlannedProjectsView + InventoryManager 接入

**Files:**
- Modify: `BeadInventory/Views/PlannedProjectsView.swift` (ExecutePlannedProjectSheet)
- Modify: `BeadInventory/Managers/InventoryManager.swift` (新增 executePlannedProjectWithResolver)

**依赖 Tasks 1-5。可与 Task 6 并行执行。**

- [ ] **Step 1: 在 InventoryManager 中添加 resolver 版本的 executePlannedProject**

在 `InventoryManager.swift` 的 `executePlannedProject(_:withBrand:)` 方法之后（约 line 2508 附近）添加：

```swift
    /// 通过 DeductionResolver 执行计划项目（支持跨品牌扣减）
    @discardableResult
    func executePlannedProjectWithResolver(_ projectId: UUID, resolver: DeductionResolver) -> Bool {
        guard let index = projects.firstIndex(where: { $0.id == projectId }) else {
            return false
        }

        let project = projects[index]
        guard project.isPlanned else { return false }

        // 如果是父项目，暂不支持 resolver 模式，回退到单品牌
        if isParentProject(projectId), let brandId = resolver.primaryBrandId {
            return executePlannedProject(projectId, withBrand: brandId)
        }

        let beforeProject = project

        // 通过 resolver 执行扣减（逐条使用各自的 brandId）
        _ = resolver.executeDeductions()

        // 更新项目状态
        projects[index].isPlanned = false
        projects[index].brandId = resolver.primaryBrandId
        projects[index].executedDate = Date()
        projects[index].beadUsage = resolver.buildBeadUsages(isDeducted: true)

        // 检查父项目状态
        if let parentId = project.parentId {
            let remainingPlannedChildren = projects.filter {
                $0.parentId == parentId && $0.isPlanned && $0.id != projectId
            }
            if remainingPlannedChildren.isEmpty {
                if let parentIndex = projects.firstIndex(where: { $0.id == parentId }) {
                    projects[parentIndex].isPlanned = false
                    projects[parentIndex].executedDate = Date()
                    projects[parentIndex].brandId = resolver.primaryBrandId
                }
            }
        }

        saveData()
        historyManager.recordPlanExecute(beforeProject: beforeProject, afterProject: projects[index])
        return true
    }
```

- [ ] **Step 2: 重写 ExecutePlannedProjectSheet**

将 `PlannedProjectsView.swift` 中的 `ExecutePlannedProjectSheet`（约 lines 672-845）替换为新版本，加入 DeductionResolver 和逐色品牌选择：

```swift
// MARK: - 执行计划弹窗
struct ExecutePlannedProjectSheet: View {
    let project: ProjectRecord
    var onExecuted: (() -> Void)? = nil
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss
    @State private var selectedBrandId: UUID?
    @State private var showConfirmation = false
    @StateObject private var resolver: DeductionResolver = DeductionResolver(inventoryManager: InventoryManager())
    @State private var resolverInitialized = false
    private let similarityService = ColorSimilarityService()

    /// 匹配当前项目色号体系的品牌
    var matchingBrands: [Brand] {
        inventoryManager.brands
            .filter { $0.colorSystem == project.colorSystem }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var selectedBrand: Brand? {
        guard let id = selectedBrandId else { return nil }
        return inventoryManager.brands.first { $0.id == id }
    }

    var isParent: Bool {
        inventoryManager.isParentProject(project.id)
    }

    var totalBeads: Int {
        if isParent {
            return inventoryManager.plannedAggregatedTotalBeads(for: project.id)
        }
        return project.totalBeads
    }

    var colorCount: Int {
        if isParent {
            return inventoryManager.plannedAggregatedColorCount(for: project.id)
        }
        return project.beadUsage.count
    }

    var allBeadUsages: [BeadUsage] {
        if isParent {
            return inventoryManager.plannedAggregatedBeadUsage(for: project.id)
        }
        return project.beadUsage
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("项目信息") {
                    HStack {
                        Text("项目名称")
                        Spacer()
                        Text(project.name)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("颜色数量")
                        Spacer()
                        Text("\(colorCount) 种")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("豆子总数")
                        Spacer()
                        Text("\(totalBeads) 颗")
                            .foregroundColor(.secondary)
                    }

                    if isParent {
                        HStack {
                            Text("子项目")
                            Spacer()
                            Text("\(inventoryManager.plannedChildProjects(of: project.id).count) 个")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section("选择扣减品牌") {
                    if matchingBrands.isEmpty {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("暂无\(project.colorSystem.displayName)体系的品牌，请先创建")
                                .foregroundColor(.secondary)
                        }
                    } else {
                        ForEach(matchingBrands) { brand in
                            Button {
                                selectedBrandId = brand.id
                                resolver.setPrimaryBrand(brand.id)
                            } label: {
                                HStack {
                                    Text(brand.name)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    if selectedBrandId == brand.id {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                            }
                        }
                    }
                }

                // 逐色扣减详情（仅在选中品牌后显示）
                if selectedBrandId != nil && resolverInitialized {
                    Section("扣减详情") {
                        ForEach(resolver.items) { item in
                            let beadColor = inventoryManager.findColor(byCode: item.mardCode)
                            let brandName = matchingBrands.first(where: { $0.id == item.brandId })?.name ?? "未知"
                            let threshold = matchingBrands.first(where: { $0.id == item.brandId })?.lowStockThreshold ?? 100
                            let similarColors = similarityService.findSimilarColors(
                                for: item.mardCode,
                                brandId: item.brandId,
                                allColors: inventoryManager.allBeadColors,
                                brandStocks: inventoryManager.brandStocks
                            )

                            DeductionItemRow(
                                item: item,
                                beadColor: beadColor,
                                matchingBrands: matchingBrands,
                                similarColors: similarColors,
                                colorSystem: project.colorSystem,
                                lowStockThreshold: threshold,
                                brandName: brandName,
                                onBrandChanged: { newBrandId in
                                    resolver.overrideBrand(for: item.mardCode, to: newBrandId)
                                },
                                onResetBrand: {
                                    resolver.resetToPrimary(for: item.mardCode)
                                },
                                onSubstitute: { newMardCode, newColorCode in
                                    resolver.substituteColor(
                                        originalMardCode: item.mardCode,
                                        newMardCode: newMardCode,
                                        newColorCode: newColorCode
                                    )
                                }
                            )
                            .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                        }
                    }
                }

                Section {
                    Button {
                        showConfirmation = true
                    } label: {
                        HStack {
                            Spacer()
                            if !resolver.insufficientItems.isEmpty {
                                Image(systemName: "exclamationmark.triangle.fill")
                            }
                            Text("执行扣减")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(selectedBrandId == nil)
                }
            }
            .navigationTitle("执行计划")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .alert("确认执行", isPresented: $showConfirmation) {
                Button("取消", role: .cancel) { }
                Button("确认", role: resolver.insufficientItems.isEmpty ? .none : .destructive) {
                    if selectedBrandId != nil {
                        inventoryManager.executePlannedProjectWithResolver(project.id, resolver: resolver)
                        dismiss()
                        onExecuted?()
                    }
                }
            } message: {
                if let brand = selectedBrand {
                    var msg = "将从「\(brand.name)」品牌库存中扣减 \(totalBeads) 颗豆子（\(colorCount) 种颜色）。"
                    if resolver.hasManualOverrides {
                        let overrides = resolver.manualOverrideItems.compactMap { item in
                            if let b = matchingBrands.first(where: { $0.id == item.brandId }) {
                                return "\(item.colorCode) → \(b.name)"
                            }
                            return nil
                        }
                        msg += "\n\n跨品牌扣减：\n" + overrides.joined(separator: "\n")
                    }
                    if !resolver.insufficientItems.isEmpty {
                        msg += "\n\n⚠️ \(resolver.insufficientItems.count) 种颜色扣除后库存将为负数"
                    }
                    Text(msg)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            let newResolver = DeductionResolver(inventoryManager: inventoryManager)

            // 默认选择当前品牌或第一个匹配品牌
            if let currentId = inventoryManager.currentBrandId,
               matchingBrands.contains(where: { $0.id == currentId }) {
                selectedBrandId = currentId
            } else {
                selectedBrandId = matchingBrands.first?.id
            }

            if let brandId = selectedBrandId {
                newResolver.initializeFromBeadUsages(
                    allBeadUsages,
                    primaryBrandId: brandId,
                    colorSystem: project.colorSystem
                )
            }

            // 用新 resolver 的数据更新 @StateObject
            resolver.items = newResolver.items
            resolver.primaryBrandId = newResolver.primaryBrandId
            resolverInitialized = true
        }
    }
}
```

**注意**：由于 `@StateObject` 的 init 需要在编译时确定，而我们需要传入 `inventoryManager`，这里用了一个 workaround：先用空的 resolver 初始化，在 `onAppear` 中重新设置。如果编译遇到问题，备选方案是将 `resolver` 改为 `@State private var resolver: DeductionResolver?` 并在 `onAppear` 中初始化。

- [ ] **Step 3: 修复 DeductionResolver 的 @StateObject 兼容性**

由于 `DeductionResolver` 需要 `InventoryManager` 引用，而 `@StateObject` 不方便在 init 传参，将 `ExecutePlannedProjectSheet` 中的 resolver 改为 `@State`：

将：
```swift
    @StateObject private var resolver: DeductionResolver = DeductionResolver(inventoryManager: InventoryManager())
    @State private var resolverInitialized = false
```

改为：
```swift
    @State private var resolver = DeductionResolver(inventoryManager: InventoryManager())
    @State private var resolverInitialized = false
```

并在 `DeductionResolver` 的 `inventoryManager` 属性改为非 weak（因为 InventoryManager 是 app 级单例不会释放）：

在 `DeductionResolver.swift` 中，将：
```swift
    private weak var inventoryManager: InventoryManager?
```
改为：
```swift
    private var inventoryManager: InventoryManager?
```

同时更新所有 `guard let manager = inventoryManager else { return }` 保持不变（仍安全解包）。

- [ ] **Step 4: 构建验证**

```bash
xcodebuild -project BeadInventory.xcodeproj -scheme BeadInventory -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add BeadInventory/Views/PlannedProjectsView.swift BeadInventory/Managers/InventoryManager.swift BeadInventory/Managers/DeductionResolver.swift
git commit -m "feat: PlannedProjectsView 和 InventoryManager 接入跨品牌扣减"
```

---

## Parallelization Summary

```
Wave 1 (parallel):     Task 1 (ColorSimilarityService)
                        Task 2 (DeductionItem)

Wave 2 (sequential):   Task 3 (DeductionResolver) — needs Task 2

Wave 3 (parallel):     Task 4 (SimilarColorSheet) — needs Task 1
                        Task 5 (DeductionItemRow) — needs Tasks 1-4
                        (Task 4 先完成, Task 5 再开始)

Wave 4 (parallel):     Task 6 (ScanView) — needs Tasks 1-5
                        Task 7 (PlannedProjectsView + InventoryManager) — needs Tasks 1-5
```

推荐 Agent 分工：
- **Agent A**: Task 1 → Task 4
- **Agent B**: Task 2 → Task 3
- 合并后 → **Agent C**: Task 5
- 合并后 → **Agent D**: Task 6 | **Agent E**: Task 7
