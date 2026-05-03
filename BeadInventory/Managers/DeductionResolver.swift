//
//  DeductionResolver.swift
//  BeadInventory
//
//  扣减解析器：管理一组待扣减颜色的品牌分配状态
//

import Foundation
import SwiftUI

@MainActor
class DeductionResolver: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var items: [DeductionItem] = []
    @Published var primaryBrandId: UUID?

    private let inventoryManager: InventoryManager
    private var cachedFailedItems: [DeductionItem]?

    init(inventoryManager: InventoryManager) {
        self.inventoryManager = inventoryManager
    }

    /// 从扫描识别结果初始化
    func initializeFromRecognizedItems(
        _ recognizedItems: [(colorCode: String, quantity: Int)],
        primaryBrandId: UUID,
        colorSystem: ColorSystem
    ) {
        self.primaryBrandId = primaryBrandId
        self.items = recognizedItems.map { item in
            let color = inventoryManager.findColor(byCode: item.colorCode)
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
        self.primaryBrandId = primaryBrandId
        self.items = usages.map { usage in
            let color = inventoryManager.findColor(byCode: usage.colorCode)
            let mardCode = color?.mardCode ?? usage.colorCode
            let displayCode = color?.displayCode(for: colorSystem) ?? usage.colorCode
            return DeductionItem(
                mardCode: mardCode,
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
    func overrideBrand(for itemId: UUID, to brandId: UUID) {
        guard let i = items.firstIndex(where: { $0.id == itemId }) else { return }
        items[i].brandId = brandId
        items[i].isManualOverride = true
        refreshStockStatus()
    }

    /// 重置某颜色回主品牌
    func resetToPrimary(for itemId: UUID) {
        guard let primaryBrandId,
              let i = items.firstIndex(where: { $0.id == itemId }) else { return }
        items[i].brandId = primaryBrandId
        items[i].isManualOverride = false
        refreshStockStatus()
    }

    /// 替换颜色（相似色代替）
    func substituteColor(itemId: UUID, newMardCode: String, newColorCode: String) {
        guard let i = items.firstIndex(where: { $0.id == itemId }) else { return }
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
        for i in items.indices {
            let stock = inventoryManager.getStock(brandId: items[i].brandId, mardCode: items[i].mardCode)
            items[i].availableStock = stock?.available ?? 0
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

    /// 执行扣减：逐条调用 InventoryManager.deductFromStock，返回失败项
    /// 重复调用时返回首次执行的缓存结果
    func executeDeductions(shouldSave: Bool = true) -> [DeductionItem] {
        if let cached = cachedFailedItems { return cached }

        var failedItems: [DeductionItem] = []
        for item in items {
            let success = inventoryManager.deductFromStock(
                brandId: item.brandId,
                colorCode: item.mardCode,
                amount: item.quantity,
                shouldSave: false
            )
            if !success {
                failedItems.append(item)
            }
        }
        if shouldSave {
            inventoryManager.saveData()
        }
        cachedFailedItems = failedItems
        return failedItems
    }
}
