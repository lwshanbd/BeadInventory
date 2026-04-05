//
//  DeductionResolver.swift
//  BeadInventory
//
//  扣减解析器：管理一组待扣减颜色的品牌分配状态
//

import Foundation
import SwiftUI

@MainActor
class DeductionResolver: ObservableObject {
    @Published var items: [DeductionItem] = []
    @Published var primaryBrandId: UUID?

    private var inventoryManager: InventoryManager?

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

    var insufficientItems: [DeductionItem] {
        items.filter { $0.isInsufficient }
    }

    var hasManualOverrides: Bool {
        items.contains { $0.isManualOverride }
    }

    var manualOverrideItems: [DeductionItem] {
        items.filter { $0.isManualOverride }
    }

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
