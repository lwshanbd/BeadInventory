//
//  InventoryManager.swift
//  BeadInventory
//
//  库存管理器 - 使用 SwiftData 进行数据持久化
//

import Foundation
import SwiftUI
import SwiftData

@MainActor
class InventoryManager: ObservableObject {
    @Published var beadColors: [BeadColor] = []
    @Published var projects: [ProjectRecord] = []
    @Published var customColors: [CustomColor] = []  // 自定义色号
    @Published var purchaseRecords: [PurchaseRecord] = []  // 运输中的购买记录

    // 品牌相关
    @Published var brands: [Brand] = []
    @Published var brandStocks: [BrandStock] = []
    @Published var currentBrandId: UUID?

    // SwiftData ModelContext
    private var modelContext: ModelContext?

    // 数据加载完成标志，防止在数据未加载时意外保存空数据
    private var isDataLoaded = false

    // 各实体加载成功标志，防止加载失败后保存时误删数据
    private var brandsLoadedSuccessfully = false
    private var stocksLoadedSuccessfully = false
    private var projectsLoadedSuccessfully = false
    private var customColorsLoadedSuccessfully = false

    // 防止 saveData() 重入（如 .inactive → .background 快速连续触发）
    private var isSaving = false

    // 保存基线：用于 iCloud 同步冲突管理（仅写入本地改动，避免覆盖远端新数据）
    private var baselineBrandsByID: [UUID: Brand] = [:]
    private var baselineStocksByID: [UUID: BrandStock] = [:]
    private var baselineProjectsByID: [UUID: ProjectRecord] = [:]
    private var baselineCustomColorsByID: [UUID: CustomColor] = [:]

    // 历史记录管理器
    private var historyManager: HistoryManager { HistoryManager.shared }

    // UserDefaults keys (用于迁移和当前品牌ID)
    private let beadColorsKey = "beadColors"
    private let projectsKey = "projects"
    private let brandsKey = "brands"
    private let brandStocksKey = "brandStocks"
    private let currentBrandIdKey = "currentBrandId"
    private let migrationCompletedKey = "swiftDataMigrationCompleted"
    private let customColorsKey = "customColors"
    private let purchaseRecordsKey = "purchaseRecords"
    private let hasExistingDataKey = "hasExistingData"

    // 计算属性：当前选中的品牌
    var currentBrand: Brand? {
        guard let id = currentBrandId else { return nil }
        return brands.first { $0.id == id }
    }

    // 计算属性：当前品牌的色号体系
    var currentColorSystem: ColorSystem {
        currentBrand?.colorSystem ?? .mard
    }

    // 计算属性：当前品牌的库存
    var currentBrandStocks: [BrandStock] {
        guard let brandId = currentBrandId else { return [] }
        return brandStocks.filter { $0.brandId == brandId }
    }

    // 带 ModelContext 的初始化器
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        loadData()
        if beadColors.isEmpty {
            initializeDefaultColors()
        }
    }

    // 默认初始化器（用于 Preview）
    init() {
        loadDataFromUserDefaults()
        if beadColors.isEmpty {
            initializeDefaultColors()
        }
    }

    // MARK: - 品牌管理

    @discardableResult
    func addBrand(name: String, colorSystem: ColorSystem = .mard, defaultStock: Int = 1000, selectedColors: Set<String>? = nil) -> Brand {
        let maxOrder = brands.map { $0.sortOrder }.max() ?? -1
        let brand = Brand(
            name: name,
            sortOrder: maxOrder + 1,
            colorSystem: colorSystem
        )
        brands.append(brand)

        // 为新品牌初始化库存
        initializeStockForBrand(brand.id, defaultStock: defaultStock, selectedColors: selectedColors)

        // 如果没有当前品牌，设为当前品牌
        if currentBrandId == nil {
            currentBrandId = brand.id
        }

        saveData()

        // 记录历史
        historyManager.recordBrand(type: .brandAdd, brand: brand)

        return brand
    }

    func updateBrand(_ brand: Brand) {
        if let index = brands.firstIndex(where: { $0.id == brand.id }) {
            brands[index] = brand
            saveData()
        }
    }

    func updateBrand(_ brandId: UUID, name: String) {
        if let index = brands.firstIndex(where: { $0.id == brandId }) {
            let oldName = brands[index].name
            brands[index].name = name
            saveData()

            // 记录历史
            historyManager.recordBrand(type: .brandUpdate, brand: brands[index], oldName: oldName)
        }
    }

    func updateBrandLowStockThreshold(_ brandId: UUID, threshold: Int) {
        if let index = brands.firstIndex(where: { $0.id == brandId }) {
            brands[index].lowStockThreshold = threshold
            saveData()
        }
    }

    /// 获取品牌的低库存阈值，如果品牌不存在则返回默认值100
    func getLowStockThreshold(for brandId: UUID) -> Int {
        brands.first(where: { $0.id == brandId })?.lowStockThreshold ?? 100
    }

    func deleteBrand(_ brandId: UUID) -> Bool {
        // 记录历史（在删除前获取品牌信息）
        if let brand = brands.first(where: { $0.id == brandId }) {
            historyManager.recordBrand(type: .brandDelete, brand: brand)
        }

        // 删除品牌及其库存
        brands.removeAll { $0.id == brandId }
        brandStocks.removeAll { $0.brandId == brandId }

        // 如果删除的是当前选中的品牌，切换到第一个品牌
        if currentBrandId == brandId {
            currentBrandId = brands.first?.id
        }

        saveData()
        return true
    }

    /// 合并品牌：将源品牌的所有数据转移到目标品牌，然后删除源品牌
    @discardableResult
    func mergeBrands(sourceBrandId: UUID, targetBrandId: UUID) -> Bool {
        // 1. 校验：两个品牌都存在且不相同
        guard sourceBrandId != targetBrandId,
              let sourceBrand = brands.first(where: { $0.id == sourceBrandId }),
              brands.contains(where: { $0.id == targetBrandId }) else {
            return false
        }

        // 2. 合并 BrandStock
        let sourceStocks = brandStocks.filter { $0.brandId == sourceBrandId }
        for sourceStock in sourceStocks {
            if let targetIndex = brandStocks.firstIndex(where: {
                $0.brandId == targetBrandId && $0.mardCode == sourceStock.mardCode
            }) {
                // 目标品牌已有该色号 → 累加 stock 和 used
                brandStocks[targetIndex].stock += sourceStock.stock
                brandStocks[targetIndex].used += sourceStock.used
                // 如果源色号未隐藏，目标也取消隐藏
                if !sourceStock.isHidden {
                    brandStocks[targetIndex].isHidden = false
                }
            } else {
                // 目标品牌没有该色号 → 创建新 BrandStock
                let newStock = BrandStock(
                    brandId: targetBrandId,
                    mardCode: sourceStock.mardCode,
                    stock: sourceStock.stock,
                    used: sourceStock.used,
                    isHidden: sourceStock.isHidden
                )
                brandStocks.append(newStock)
            }
        }
        // 删除源品牌的所有 brandStocks
        brandStocks.removeAll { $0.brandId == sourceBrandId }

        // 3. 更新 Projects：将 brandId == sourceBrandId 的改为 targetBrandId
        for i in projects.indices {
            if projects[i].brandId == sourceBrandId {
                projects[i].brandId = targetBrandId
            }
            // 同时更新 beadUsage 中的 brandId
            for j in projects[i].beadUsage.indices {
                if projects[i].beadUsage[j].brandId == sourceBrandId {
                    projects[i].beadUsage[j] = BeadUsage(
                        id: projects[i].beadUsage[j].id,
                        colorCode: projects[i].beadUsage[j].colorCode,
                        brandId: targetBrandId,
                        quantity: projects[i].beadUsage[j].quantity,
                        isDeducted: projects[i].beadUsage[j].isDeducted
                    )
                }
            }
        }

        // 4. 更新 PurchaseRecords：将 brandId == sourceBrandId 的改为 targetBrandId
        for i in purchaseRecords.indices {
            if purchaseRecords[i].brandId == sourceBrandId {
                purchaseRecords[i] = PurchaseRecord(
                    id: purchaseRecords[i].id,
                    name: purchaseRecords[i].name,
                    date: purchaseRecords[i].date,
                    brandId: targetBrandId,
                    items: purchaseRecords[i].items,
                    note: purchaseRecords[i].note
                )
            }
        }

        // 5. 处理当前品牌：如果当前选中的是源品牌，切换到目标品牌
        if currentBrandId == sourceBrandId {
            currentBrandId = targetBrandId
        }

        // 6. 删除源品牌
        brands.removeAll { $0.id == sourceBrandId }

        // 7. 记录历史
        historyManager.recordBrand(type: .brandDelete, brand: sourceBrand)

        // 8. 保存数据
        saveData()

        return true
    }

    func selectBrand(_ brandId: UUID) {
        if brands.contains(where: { $0.id == brandId }) {
            currentBrandId = brandId
            saveCurrentBrandId()
        }
    }

    // MARK: - 品牌库存操作

    func initializeStockForBrand(_ brandId: UUID, defaultStock: Int = 1000, selectedColors: Set<String>? = nil) {
        // 获取该品牌的色号体系
        let colorSystem = brands.first(where: { $0.id == brandId })?.colorSystem ?? .mard

        // 为预设颜色初始化库存
        for color in beadColors {
            // 非 MARD 体系时，跳过没有对应编码的颜色
            if !color.hasCode(for: colorSystem) {
                continue
            }

            // 如果指定了 selectedColors，则只有选中的颜色才有库存，未选中的标记为隐藏
            let isSelected = selectedColors?.contains(color.mardCode) ?? true
            let stock = BrandStock(
                brandId: brandId,
                mardCode: color.mardCode,
                stock: isSelected ? defaultStock : 0,
                used: 0,
                isHidden: !isSelected
            )
            brandStocks.append(stock)
        }

        // 为自定义色号初始化库存
        for customColor in customColors {
            let stock = BrandStock(
                brandId: brandId,
                mardCode: customColor.mardCode,
                stock: 0,  // 自定义色号默认库存为0
                used: 0,
                isHidden: false
            )
            brandStocks.append(stock)
        }
    }

    func getStock(brandId: UUID, mardCode: String) -> BrandStock? {
        return brandStocks.first { $0.brandId == brandId && $0.mardCode == mardCode }
    }

    func updateStock(brandId: UUID, mardCode: String, newStock: Int) {
        if let index = brandStocks.firstIndex(where: {
            $0.brandId == brandId && $0.mardCode == mardCode
        }) {
            let oldStock = brandStocks[index].stock
            let newValue = max(0, newStock)
            brandStocks[index].stock = newValue
            // 如果是隐藏的色号，自动取消隐藏
            if brandStocks[index].isHidden {
                brandStocks[index].isHidden = false
            }
            saveData()

            // 记录历史
            historyManager.recordStockChange(
                type: .stockUpdate,
                brandId: brandId,
                mardCode: mardCode,
                oldValue: oldStock,
                newValue: newValue,
                changeAmount: newValue - oldStock
            )
        }
    }

    func addStock(brandId: UUID, mardCode: String, amount: Int) {
        if let index = brandStocks.firstIndex(where: {
            $0.brandId == brandId && $0.mardCode == mardCode
        }) {
            let oldStock = brandStocks[index].stock
            brandStocks[index].stock += amount
            // 如果是隐藏的色号，自动取消隐藏
            if brandStocks[index].isHidden {
                brandStocks[index].isHidden = false
            }
            saveData()

            // 记录历史（仅当不是撤回操作导致的负数调整时）
            if amount > 0 {
                historyManager.recordStockChange(
                    type: .stockAdd,
                    brandId: brandId,
                    mardCode: mardCode,
                    oldValue: oldStock,
                    newValue: brandStocks[index].stock,
                    changeAmount: amount
                )
            }
        }
    }

    /// 批量导入库存（累加模式）
    /// - Parameters:
    ///   - brandId: 目标品牌 ID
    ///   - items: 导入条目列表 [(色号, 数量)]
    ///   - unhideColors: 是否自动取消隐藏（默认 true）
    /// - Returns: 成功导入的条目数
    @discardableResult
    func importStock(brandId: UUID, items: [(colorCode: String, quantity: Int)], unhideColors: Bool = true) -> Int {
        var successCount = 0
        var totalAdded = 0

        for item in items {
            if let index = brandStocks.firstIndex(where: {
                $0.brandId == brandId && $0.mardCode == item.colorCode
            }) {
                let oldStock = brandStocks[index].stock
                brandStocks[index].stock += item.quantity
                totalAdded += item.quantity

                // 自动取消隐藏
                if unhideColors && brandStocks[index].isHidden {
                    brandStocks[index].isHidden = false
                }

                successCount += 1

                // 记录历史
                historyManager.recordStockChange(
                    type: .stockAdd,
                    brandId: brandId,
                    mardCode: item.colorCode,
                    oldValue: oldStock,
                    newValue: brandStocks[index].stock,
                    changeAmount: item.quantity
                )
            }
        }

        if successCount > 0 {
            saveData()
        }

        return successCount
    }

    func deductFromStock(brandId: UUID, colorCode: String, amount: Int, shouldSave: Bool = true) -> Bool {
        // 先找到对应的 mardCode
        guard let color = findColor(byCode: colorCode) else { return false }

        if let index = brandStocks.firstIndex(where: {
            $0.brandId == brandId && $0.mardCode == color.mardCode
        }) {
            brandStocks[index].used += amount
            // 如果是隐藏的色号，自动取消隐藏
            if brandStocks[index].isHidden {
                brandStocks[index].isHidden = false
            }
            if shouldSave {
                saveData()
            }
            return true
        }
        return false
    }

    /// 撤回库存扣减（不记录历史）
    func revertFromStock(brandId: UUID, colorCode: String, amount: Int, shouldSave: Bool = true) -> Bool {
        guard let color = findColor(byCode: colorCode) else { return false }

        if let index = brandStocks.firstIndex(where: {
            $0.brandId == brandId && $0.mardCode == color.mardCode
        }) {
            brandStocks[index].used -= amount
            if shouldSave {
                saveData()
            }
            return true
        }
        return false
    }

    /// 撤回计划执行：恢复项目状态和库存
    func revertPlanExecute(projectId: UUID, brandId: UUID, beadUsages: [(colorCode: String, quantity: Int)]) -> Bool {
        guard let index = projects.firstIndex(where: { $0.id == projectId }) else {
            return false
        }

        // 恢复库存（批量操作，不逐个保存）
        for usage in beadUsages {
            _ = revertFromStock(brandId: brandId, colorCode: usage.colorCode, amount: usage.quantity, shouldSave: false)
        }

        // 恢复项目状态
        projects[index].isPlanned = true
        projects[index].brandId = nil
        projects[index].executedDate = nil
        projects[index].beadUsage = projects[index].beadUsage.map { usage in
            BeadUsage(id: usage.id, colorCode: usage.colorCode, brandId: nil,
                      quantity: usage.quantity, isDeducted: false)
        }

        saveData()
        return true
    }

    // MARK: - 品牌统计

    func totalStock(for brandId: UUID) -> Int {
        brandStocks.filter { $0.brandId == brandId && !$0.isHidden }.reduce(0) { $0 + $1.stock }
    }

    func totalUsed(for brandId: UUID) -> Int {
        brandStocks.filter { $0.brandId == brandId && !$0.isHidden }.reduce(0) { $0 + $1.used }
    }

    func totalAvailable(for brandId: UUID) -> Int {
        brandStocks.filter { $0.brandId == brandId && !$0.isHidden }.reduce(0) { $0 + $1.available }
    }

    func lowStockColors(for brandId: UUID) -> [BrandStock] {
        let threshold = getLowStockThreshold(for: brandId)
        return brandStocks.filter { $0.brandId == brandId && !$0.isHidden && $0.available < threshold }
    }

    // MARK: - 隐藏色号管理

    /// 隐藏指定品牌的色号（清零库存）
    func hideColor(brandId: UUID, mardCode: String) {
        guard let index = brandStocks.firstIndex(where: {
            $0.brandId == brandId && $0.mardCode == mardCode
        }) else { return }

        // 清零库存并标记隐藏
        brandStocks[index].stock = 0
        brandStocks[index].used = 0
        brandStocks[index].isHidden = true

        saveData()
    }

    /// 取消隐藏指定品牌的色号（恢复默认库存）
    func unhideColor(brandId: UUID, mardCode: String, defaultStock: Int = 1000) {
        guard let index = brandStocks.firstIndex(where: {
            $0.brandId == brandId && $0.mardCode == mardCode
        }) else { return }

        // 取消隐藏并恢复默认库存
        brandStocks[index].isHidden = false
        brandStocks[index].stock = defaultStock
        brandStocks[index].used = 0

        saveData()
    }

    /// 批量取消隐藏色号
    func unhideColors(brandId: UUID, mardCodes: [String], defaultStock: Int = 1000) {
        for mardCode in mardCodes {
            if let index = brandStocks.firstIndex(where: {
                $0.brandId == brandId && $0.mardCode == mardCode
            }) {
                brandStocks[index].isHidden = false
                brandStocks[index].stock = defaultStock
                brandStocks[index].used = 0
            }
        }
        saveData()
    }

    /// 获取指定品牌的隐藏色号列表
    func hiddenColors(for brandId: UUID) -> [BrandStock] {
        brandStocks.filter { $0.brandId == brandId && $0.isHidden }
    }

    /// 获取指定品牌隐藏色号的数量
    func hiddenColorCount(for brandId: UUID) -> Int {
        brandStocks.filter { $0.brandId == brandId && $0.isHidden }.count
    }

    // MARK: - 自定义色号管理

    /// 添加自定义色号
    @discardableResult
    func addCustomColor(colorCode: String, colorHex: String, colorName: String = "") -> CustomColor? {
        // 检查色号是否已存在（包括预设颜色）
        let normalizedCode = colorCode.uppercased().trimmingCharacters(in: .whitespaces)
        let customMardCode = "#\(normalizedCode)"

        // 检查是否与预设颜色冲突
        if beadColors.contains(where: {
            $0.mardCode.uppercased() == normalizedCode ||
            $0.cocoCode.uppercased() == normalizedCode ||
            $0.manmanCode.uppercased() == normalizedCode ||
            $0.panpanCode.uppercased() == normalizedCode ||
            $0.mixiaowoCode.uppercased() == normalizedCode ||
            $0.kakaCode.uppercased() == normalizedCode
        }) {
            return nil
        }

        // 检查是否与已有自定义色号冲突
        if customColors.contains(where: {
            $0.colorCode.uppercased() == normalizedCode ||
            $0.mardCode.uppercased() == customMardCode
        }) {
            return nil
        }

        let customColor = CustomColor(
            colorCode: normalizedCode,
            colorHex: colorHex.replacingOccurrences(of: "#", with: ""),
            colorName: colorName
        )
        customColors.append(customColor)

        // 为所有品牌初始化该自定义色号的库存（默认隐藏，需要用户手动取消隐藏）
        for brand in brands {
            let stock = BrandStock(
                brandId: brand.id,
                mardCode: customColor.mardCode,
                stock: 0,
                used: 0,
                isHidden: true  // 自定义色号默认隐藏
            )
            brandStocks.append(stock)
        }

        saveData()
        return customColor
    }

    /// 更新自定义色号
    func updateCustomColor(id: UUID, colorCode: String? = nil, colorHex: String? = nil, colorName: String? = nil) -> Bool {
        guard let index = customColors.firstIndex(where: { $0.id == id }) else {
            return false
        }

        let oldMardCode = customColors[index].mardCode

        if let newCode = colorCode {
            let normalizedCode = newCode.uppercased().trimmingCharacters(in: .whitespaces)
            // 检查新色号是否冲突（排除自己）
            if customColors.contains(where: { $0.id != id && $0.colorCode.uppercased() == normalizedCode }) {
                return false
            }
            customColors[index].colorCode = normalizedCode

            // 更新所有品牌库存中的 mardCode
            let newMardCode = "#\(normalizedCode)"
            for i in brandStocks.indices where brandStocks[i].mardCode == oldMardCode {
                // 需要创建新的 BrandStock 因为 mardCode 是 let
                let oldStock = brandStocks[i]
                brandStocks[i] = BrandStock(
                    id: oldStock.id,
                    brandId: oldStock.brandId,
                    mardCode: newMardCode,
                    stock: oldStock.stock,
                    used: oldStock.used,
                    isHidden: oldStock.isHidden
                )
            }
        }

        if let newHex = colorHex {
            customColors[index].colorHex = newHex.replacingOccurrences(of: "#", with: "")
        }

        if let newName = colorName {
            customColors[index].colorName = newName
        }

        customColors[index].updatedAt = Date()
        saveData()
        return true
    }

    /// 删除自定义色号
    func deleteCustomColor(id: UUID) -> Bool {
        guard let index = customColors.firstIndex(where: { $0.id == id }) else {
            return false
        }

        let mardCode = customColors[index].mardCode

        // 删除所有品牌中该颜色的库存记录
        brandStocks.removeAll { $0.mardCode == mardCode }

        // 删除自定义色号
        customColors.remove(at: index)

        saveData()
        return true
    }

    /// 根据 ID 获取自定义色号
    func getCustomColor(id: UUID) -> CustomColor? {
        customColors.first { $0.id == id }
    }

    /// 根据色号获取自定义色号（兼容旧 C_ 前缀）
    func getCustomColor(byCode code: String) -> CustomColor? {
        let normalizedCode = code.uppercased().trimmingCharacters(in: .whitespaces)
        return customColors.first { custom in
            let customColorCode = custom.colorCode.uppercased()
            let oldMardCode = "C_\(customColorCode)"
            return customColorCode == normalizedCode ||
                   custom.mardCode.uppercased() == normalizedCode ||
                   oldMardCode == normalizedCode
        }
    }

    /// 检查色号是否为自定义色号（兼容旧 C_ 前缀）
    func isCustomColor(_ mardCode: String) -> Bool {
        mardCode.hasPrefix("#") || mardCode.hasPrefix("C_") || customColors.contains { $0.colorCode.uppercased() == mardCode.uppercased() }
    }

    // MARK: - 数据迁移

    /// 迁移旧 SDProjectRecord：补充 colorSystemRaw 字段（nil → "MARD"）
    func migrateProjectColorSystem() {
        guard let context = modelContext else { return }
        do {
            let descriptor = FetchDescriptor<SDProjectRecord>()
            let records = try context.fetch(descriptor)
            var updated = false
            for record in records {
                if record.colorSystemRaw == nil {
                    record.colorSystemRaw = ColorSystem.mard.rawValue
                    updated = true
                }
            }
            if updated {
                try context.save()
            }
        } catch {
            print("[DataMigration] migrateProjectColorSystem error: \(error)")
        }
    }

    /// 应用回到前台时刷新 SwiftData，拉取 iCloud 端已合并的数据
    func refreshFromPersistentStore(reason: String) {
        guard modelContext != nil else { return }
        guard !isSaving else { return }
        print("[InventoryManager] 前台刷新数据: \(reason)")
        loadData()
    }

    private func makeMapByID<T: Identifiable>(_ items: [T]) -> [UUID: T] where T.ID == UUID {
        Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    private func refreshBaselines() {
        baselineBrandsByID = makeMapByID(brands)
        baselineStocksByID = makeMapByID(brandStocks)
        baselineProjectsByID = makeMapByID(projects)
        baselineCustomColorsByID = makeMapByID(customColors)
    }

    // MARK: - 数据持久化 (SwiftData)

    func loadData() {
        guard let context = modelContext else {
            loadDataFromUserDefaults()
            return
        }

        // 重置加载状态标志（在开始时重置 isDataLoaded，让逻辑更封闭）
        isDataLoaded = false
        brandsLoadedSuccessfully = false
        stocksLoadedSuccessfully = false
        projectsLoadedSuccessfully = false
        customColorsLoadedSuccessfully = false

        // 检查是否需要迁移
        let needsMigration = !UserDefaults.standard.bool(forKey: migrationCompletedKey)
        if needsMigration {
            migrateFromUserDefaults()
        }

        // 从 SwiftData 加载品牌
        do {
            let brandDescriptor = FetchDescriptor<SDBrand>(sortBy: [SortDescriptor(\.sortOrder)])
            let sdBrands = try context.fetch(brandDescriptor)
            brands = sdBrands.map { $0.toStruct() }
            brandsLoadedSuccessfully = true
            print("[InventoryManager] 成功加载 \(brands.count) 个品牌")
        } catch {
            print("[InventoryManager] ⚠️ 加载品牌失败: \(error)")
            // 不修改 brands 数组，保持原状态
        }

        // 从 SwiftData 加载品牌库存
        do {
            let stockDescriptor = FetchDescriptor<SDBrandStock>()
            let sdStocks = try context.fetch(stockDescriptor)
            brandStocks = sdStocks.map { $0.toStruct() }
            stocksLoadedSuccessfully = true
            print("[InventoryManager] 成功加载 \(brandStocks.count) 条库存记录")
        } catch {
            print("[InventoryManager] ⚠️ 加载库存失败: \(error)")
            // 不修改 brandStocks 数组，保持原状态
        }

        // 从 SwiftData 加载项目记录
        do {
            let projectDescriptor = FetchDescriptor<SDProjectRecord>(sortBy: [SortDescriptor(\.date, order: .reverse)])
            let sdProjects = try context.fetch(projectDescriptor)
            projects = sdProjects.map { $0.toStruct() }
            projectsLoadedSuccessfully = true
            print("[InventoryManager] 成功加载 \(projects.count) 个项目记录")
        } catch {
            print("[InventoryManager] ⚠️ 加载项目失败: \(error)")
            // 不修改 projects 数组，保持原状态
        }

        // 加载当前品牌 ID
        if let idString = UserDefaults.standard.string(forKey: currentBrandIdKey),
           let id = UUID(uuidString: idString) {
            currentBrandId = id
        }

        // 初始化颜色数据
        beadColors = loadAllColorsFromJSON()

        // 从 SwiftData 加载自定义色号
        do {
            let customColorDescriptor = FetchDescriptor<SDCustomColor>(sortBy: [SortDescriptor(\.createdAt)])
            let sdCustomColors = try context.fetch(customColorDescriptor)
            customColors = sdCustomColors.map { $0.toStruct() }
            customColorsLoadedSuccessfully = true
            print("[InventoryManager] 成功加载 \(customColors.count) 个自定义色号")
        } catch {
            print("[InventoryManager] ⚠️ 加载自定义色号失败: \(error)")
            // 不修改 customColors 数组，保持原状态
        }

        // 加载运输中的购买记录（存在 UserDefaults 中）
        if let data = UserDefaults.standard.data(forKey: purchaseRecordsKey),
           let decoded = try? JSONDecoder().decode([PurchaseRecord].self, from: data) {
            purchaseRecords = decoded
        }

        // 只有当所有关键数据都成功加载时，才标记为加载完成
        let allLoaded = brandsLoadedSuccessfully && stocksLoadedSuccessfully && projectsLoadedSuccessfully
        if allLoaded {
            // 防护：如果用户之前有数据，但本次 fetch 全部返回空，说明 SwiftData 加载异常
            // 拒绝标记为加载成功，阻止后续 saveData() 把空数据写入数据库覆盖原有记录
            let allEmpty = brands.isEmpty && brandStocks.isEmpty && projects.isEmpty && customColors.isEmpty
            let hadDataBefore = UserDefaults.standard.bool(forKey: hasExistingDataKey)
            if allEmpty && hadDataBefore {
                print("[InventoryManager] ⚠️ 异常：数据库应有数据但加载全部为空，拒绝标记为加载成功以防覆盖")
                // 不设置 isDataLoaded = true，saveData() 会被 guard 拦截
                return
            }

            // 当前品牌不存在时回退到首个品牌，避免引用悬空
            if let selectedBrandId = currentBrandId,
               !brands.contains(where: { $0.id == selectedBrandId }) {
                currentBrandId = brands.first?.id
            }

            isDataLoaded = true
            print("[InventoryManager] ✅ 数据加载完成")

            // 标记用户已有数据（只要有任何一项非空就标记）
            if !allEmpty {
                UserDefaults.standard.set(true, forKey: hasExistingDataKey)
            }

            // 刷新保存基线：后续 saveData() 只写入本地真实改动
            refreshBaselines()

            // 修复数据一致性问题（仅基于 executedDate 判断）
            fixProjectConsistency()
        } else {
            print("[InventoryManager] ❌ 部分数据加载失败，禁止后续保存操作以防数据丢失")
            print("[InventoryManager]   - 品牌: \(brandsLoadedSuccessfully ? "✅" : "❌")")
            print("[InventoryManager]   - 库存: \(stocksLoadedSuccessfully ? "✅" : "❌")")
            print("[InventoryManager]   - 项目: \(projectsLoadedSuccessfully ? "✅" : "❌")")
            print("[InventoryManager]   - 自定义色号: \(customColorsLoadedSuccessfully ? "✅" : "❌")")
        }
    }

    /// 修复项目数据一致性问题
    /// 只修复明确不一致的情况：有 executedDate 但 isPlanned 为 true
    private func fixProjectConsistency() {
        var needsSave = false

        for index in projects.indices {
            let project = projects[index]

            // 唯一的修复条件：有执行日期但状态仍为计划中
            // 这是明确的不一致状态，说明之前的保存失败了
            if project.isPlanned && project.executedDate != nil {
                print("[InventoryManager] 修复项目一致性: \(project.name) (有执行日期但状态为计划中)")
                projects[index].isPlanned = false
                needsSave = true
            }
        }

        if needsSave {
            saveData()
            print("[InventoryManager] 已修复项目数据一致性")
        }
    }

    func saveData() {
        guard let context = modelContext else { return }

        // 防止在数据未加载完成时保存空数据，导致覆盖原有数据
        guard isDataLoaded else {
            print("[InventoryManager] 警告：数据尚未加载完成，跳过保存")
            return
        }

        // 防止重入：.inactive → .background 快速连续触发时，避免并发修改 SwiftData 关系
        guard !isSaving else {
            print("[InventoryManager] 警告：saveData() 正在执行中，跳过重复调用")
            return
        }
        isSaving = true
        defer { isSaving = false }

        do {
            // 仅写入本地改动，避免把另一台设备新同步的数据“当作缺失”删除

            // 1. 品牌
            let existingBrands = try context.fetch(FetchDescriptor<SDBrand>())
            let existingBrandByID = Dictionary(existingBrands.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let localBrandByID = makeMapByID(brands)

            if brandsLoadedSuccessfully {
                var remoteBrandsToAppend: [Brand] = []
                for sdBrand in existingBrands where localBrandByID[sdBrand.id] == nil {
                    if baselineBrandsByID[sdBrand.id] != nil {
                        // 基线里存在、当前本地不存在 -> 本地确实删除
                        context.delete(sdBrand)
                    } else {
                        // 远端新增，合并进本地内存避免“看不见但下次可能被覆盖”
                        remoteBrandsToAppend.append(sdBrand.toStruct())
                    }
                }
                if !remoteBrandsToAppend.isEmpty {
                    brands.append(contentsOf: remoteBrandsToAppend)
                    brands.sort { $0.sortOrder < $1.sortOrder }
                }
            }

            var staleLocalBrandIDs = Set<UUID>()
            for brand in brands {
                let baseline = baselineBrandsByID[brand.id]
                let changedLocally = baseline == nil || baseline != brand

                if let existing = existingBrandByID[brand.id] {
                    guard changedLocally else { continue }
                    existing.name = brand.name
                    existing.sortOrder = brand.sortOrder
                    existing.lowStockThreshold = brand.lowStockThreshold
                    existing.colorSystemRaw = brand.colorSystem.rawValue
                } else if changedLocally {
                    context.insert(SDBrand(from: brand))
                } else {
                    // 本地未改且云端已删除，丢弃本地过期副本
                    staleLocalBrandIDs.insert(brand.id)
                }
            }
            if !staleLocalBrandIDs.isEmpty {
                brands.removeAll { staleLocalBrandIDs.contains($0.id) }
            }
            if let selectedBrandId = currentBrandId,
               !brands.contains(where: { $0.id == selectedBrandId }) {
                currentBrandId = brands.first?.id
            }

            // 2. 库存
            let existingStocks = try context.fetch(FetchDescriptor<SDBrandStock>())
            let existingStockByID = Dictionary(existingStocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let localStockByID = makeMapByID(brandStocks)

            if stocksLoadedSuccessfully {
                var remoteStocksToAppend: [BrandStock] = []
                for sdStock in existingStocks where localStockByID[sdStock.id] == nil {
                    if baselineStocksByID[sdStock.id] != nil {
                        context.delete(sdStock)
                    } else {
                        remoteStocksToAppend.append(sdStock.toStruct())
                    }
                }
                if !remoteStocksToAppend.isEmpty {
                    brandStocks.append(contentsOf: remoteStocksToAppend)
                }
            }

            var staleLocalStockIDs = Set<UUID>()
            for stock in brandStocks {
                let baseline = baselineStocksByID[stock.id]
                let changedLocally = baseline == nil || baseline != stock

                if let existing = existingStockByID[stock.id] {
                    guard changedLocally else { continue }
                    existing.brandId = stock.brandId
                    existing.mardCode = stock.mardCode
                    existing.stock = stock.stock
                    existing.used = stock.used
                    existing.isHidden = stock.isHidden
                } else if changedLocally {
                    context.insert(SDBrandStock(from: stock))
                } else {
                    staleLocalStockIDs.insert(stock.id)
                }
            }
            if !staleLocalStockIDs.isEmpty {
                brandStocks.removeAll { staleLocalStockIDs.contains($0.id) }
            }

            // 3. 项目
            let existingProjects = try context.fetch(FetchDescriptor<SDProjectRecord>())
            let existingProjectByID = Dictionary(existingProjects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let localProjectByID = makeMapByID(projects)

            if projectsLoadedSuccessfully {
                var remoteProjectsToAppend: [ProjectRecord] = []
                for sdProject in existingProjects where localProjectByID[sdProject.id] == nil {
                    if baselineProjectsByID[sdProject.id] != nil {
                        context.delete(sdProject)
                    } else {
                        remoteProjectsToAppend.append(sdProject.toStruct())
                    }
                }
                if !remoteProjectsToAppend.isEmpty {
                    projects.append(contentsOf: remoteProjectsToAppend)
                    projects.sort { $0.date > $1.date }
                }
            }

            var staleLocalProjectIDs = Set<UUID>()
            for project in projects {
                let baseline = baselineProjectsByID[project.id]
                let changedLocally = baseline == nil || baseline != project

                if let existing = existingProjectByID[project.id] {
                    // 本地没改过，不写回，保留云端最新值
                    guard changedLocally else { continue }

                    // 更新项目基本属性
                    existing.name = project.name
                    existing.date = project.date
                    existing.totalBeads = project.totalBeads
                    existing.brandId = project.brandId
                    existing.isArchived = project.isArchived
                    existing.parentId = project.parentId
                    existing.isPlanned = project.isPlanned
                    existing.executedDate = project.executedDate
                    existing.thumbnail = project.thumbnail
                    existing.finishedImage = project.finishedImage
                    existing.completedDate = project.completedDate
                    existing.colorSystemRaw = project.colorSystem.rawValue

                    // 仅在本地项目有改动时同步 beadUsages，避免误删远端新变更
                    let newUsageIDs = Set(project.beadUsage.map { $0.id })
                    var existingUsages = existing.beadUsages ?? []

                    // 清理可能存在的重复 beadUsage（防止历史数据损坏导致后续崩溃）
                    // 区分"同一对象重复引用"与"不同对象但 id 相同"两种情况：
                    //   - 同一对象重复引用：仅移除多余引用，不 delete（保留该对象）
                    //   - 不同对象相同 id：保留首个，delete 其余实例
                    var keeperByID: [UUID: SDBeadUsage] = [:]
                    var indicesToRemove: [Int] = []
                    var objectsToDelete: [SDBeadUsage] = []
                    for (index, usage) in existingUsages.enumerated() {
                        if let keeper = keeperByID[usage.id] {
                            indicesToRemove.append(index)
                            if usage !== keeper {
                                objectsToDelete.append(usage)
                            }
                        } else {
                            keeperByID[usage.id] = usage
                        }
                    }
                    for index in indicesToRemove.reversed() {
                        existingUsages.remove(at: index)
                    }
                    for obj in objectsToDelete {
                        context.delete(obj)
                    }

                    let existingUsageByID = Dictionary(existingUsages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    let existingUsageIDs = Set(existingUsageByID.keys)

                    // 1. 删除不再存在的 beadUsage（先收集再删除，避免遍历时修改数组）
                    let usageIDsToDelete = existingUsageIDs.subtracting(newUsageIDs)
                    for usageID in usageIDsToDelete {
                        if let oldUsage = existingUsageByID[usageID] {
                            existingUsages.removeAll { $0.id == oldUsage.id }
                            context.delete(oldUsage)
                        }
                    }

                    // 2. 更新已存在的 beadUsage
                    for newUsage in project.beadUsage {
                        if let existingUsage = existingUsageByID[newUsage.id] {
                            existingUsage.colorCode = newUsage.colorCode
                            existingUsage.brandId = newUsage.brandId
                            existingUsage.quantity = newUsage.quantity
                            existingUsage.isDeducted = newUsage.isDeducted
                        }
                    }

                    // 3. 添加新的 beadUsage
                    let usageIDsToAdd = newUsageIDs.subtracting(existingUsageIDs)
                    for newUsage in project.beadUsage where usageIDsToAdd.contains(newUsage.id) {
                        existingUsages.append(SDBeadUsage(from: newUsage))
                    }
                    existing.beadUsages = existingUsages
                } else if changedLocally {
                    context.insert(SDProjectRecord(from: project))
                } else {
                    staleLocalProjectIDs.insert(project.id)
                }
            }
            if !staleLocalProjectIDs.isEmpty {
                projects.removeAll { staleLocalProjectIDs.contains($0.id) }
            }

            // 4. 自定义色号
            let existingCustomColors = try context.fetch(FetchDescriptor<SDCustomColor>())
            let existingCustomColorByID = Dictionary(existingCustomColors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let localCustomColorByID = makeMapByID(customColors)

            if customColorsLoadedSuccessfully {
                var remoteCustomColorsToAppend: [CustomColor] = []
                for sdColor in existingCustomColors where localCustomColorByID[sdColor.id] == nil {
                    if baselineCustomColorsByID[sdColor.id] != nil {
                        context.delete(sdColor)
                    } else {
                        remoteCustomColorsToAppend.append(sdColor.toStruct())
                    }
                }
                if !remoteCustomColorsToAppend.isEmpty {
                    customColors.append(contentsOf: remoteCustomColorsToAppend)
                    customColors.sort { $0.createdAt < $1.createdAt }
                }
            }

            var staleLocalCustomColorIDs = Set<UUID>()
            for customColor in customColors {
                let baseline = baselineCustomColorsByID[customColor.id]
                let changedLocally = baseline == nil || baseline != customColor

                if let existing = existingCustomColorByID[customColor.id] {
                    guard changedLocally else { continue }
                    existing.colorCode = customColor.colorCode
                    existing.colorHex = customColor.colorHex
                    existing.colorName = customColor.colorName
                    existing.updatedAt = customColor.updatedAt
                } else if changedLocally {
                    context.insert(SDCustomColor(from: customColor))
                } else {
                    staleLocalCustomColorIDs.insert(customColor.id)
                }
            }
            if !staleLocalCustomColorIDs.isEmpty {
                customColors.removeAll { staleLocalCustomColorIDs.contains($0.id) }
            }

            try context.save()
            refreshBaselines()
            saveCurrentBrandId()
            savePurchaseRecords()

            // 同步 hasExistingDataKey：用户合法删空数据后重置标志，
            // 防止下次启动时误判为"SwiftData加载异常"而锁死
            let currentlyHasData = !brands.isEmpty || !brandStocks.isEmpty || !projects.isEmpty || !customColors.isEmpty
            UserDefaults.standard.set(currentlyHasData, forKey: hasExistingDataKey)
        } catch {
            print("[InventoryManager] ⚠️ 保存数据失败: \(error)")
            // 回滚 context 中所有未提交的变更，防止残留的删除/插入操作被后续 save 意外提交
            context.rollback()
        }
    }

    private func savePurchaseRecords() {
        if let encoded = try? JSONEncoder().encode(purchaseRecords) {
            UserDefaults.standard.set(encoded, forKey: purchaseRecordsKey)
        }
    }

    private func saveCurrentBrandId() {
        if let id = currentBrandId {
            UserDefaults.standard.set(id.uuidString, forKey: currentBrandIdKey)
        }
    }

    // MARK: - 从 UserDefaults 迁移

    private func migrateFromUserDefaults() {
        guard let context = modelContext else { return }

        print("开始从 UserDefaults 迁移数据到 SwiftData...")

        // 迁移品牌
        if let data = UserDefaults.standard.data(forKey: brandsKey),
           let decoded = try? JSONDecoder().decode([Brand].self, from: data) {
            for brand in decoded {
                let sdBrand = SDBrand(from: brand)
                context.insert(sdBrand)
            }
            print("迁移了 \(decoded.count) 个品牌")
        }

        // 迁移品牌库存
        if let data = UserDefaults.standard.data(forKey: brandStocksKey),
           let decoded = try? JSONDecoder().decode([BrandStock].self, from: data) {
            for stock in decoded {
                let sdStock = SDBrandStock(from: stock)
                context.insert(sdStock)
            }
            print("迁移了 \(decoded.count) 条库存记录")
        }

        // 迁移项目记录
        if let data = UserDefaults.standard.data(forKey: projectsKey),
           let decoded = try? JSONDecoder().decode([ProjectRecord].self, from: data) {
            for project in decoded {
                let sdProject = SDProjectRecord(from: project)
                context.insert(sdProject)
            }
            print("迁移了 \(decoded.count) 个项目记录")
        }

        do {
            try context.save()
            UserDefaults.standard.set(true, forKey: migrationCompletedKey)
            print("数据迁移完成！")
        } catch {
            print("数据迁移失败: \(error)")
        }
    }

    // 从 UserDefaults 加载（用于 Preview 或无 ModelContext 时）
    // 注意：此模式不涉及 SwiftData，所以加载标志设为 true 是安全的
    private func loadDataFromUserDefaults() {
        // 加载颜色数据
        beadColors = loadAllColorsFromJSON()

        // 加载品牌
        if let data = UserDefaults.standard.data(forKey: brandsKey),
           let decoded = try? JSONDecoder().decode([Brand].self, from: data) {
            brands = decoded
        }

        // 加载品牌库存
        if let data = UserDefaults.standard.data(forKey: brandStocksKey),
           let decoded = try? JSONDecoder().decode([BrandStock].self, from: data) {
            brandStocks = decoded
        }

        // 加载项目记录
        if let data = UserDefaults.standard.data(forKey: projectsKey),
           let records = try? JSONDecoder().decode([ProjectRecord].self, from: data) {
            projects = records
        }

        // 加载当前品牌
        if let idString = UserDefaults.standard.string(forKey: currentBrandIdKey),
           let id = UUID(uuidString: idString) {
            currentBrandId = id
        }

        // 加载自定义色号
        if let data = UserDefaults.standard.data(forKey: customColorsKey),
           let decoded = try? JSONDecoder().decode([CustomColor].self, from: data) {
            customColors = decoded
        }

        // 加载运输中的购买记录
        if let data = UserDefaults.standard.data(forKey: purchaseRecordsKey),
           let decoded = try? JSONDecoder().decode([PurchaseRecord].self, from: data) {
            purchaseRecords = decoded
        }

        // UserDefaults 模式下，所有实体都视为"已加载"（不涉及 SwiftData 删除逻辑）
        brandsLoadedSuccessfully = true
        stocksLoadedSuccessfully = true
        projectsLoadedSuccessfully = true
        customColorsLoadedSuccessfully = true
        isDataLoaded = true
        refreshBaselines()
        print("[InventoryManager] 数据从 UserDefaults 加载完成")
    }

    // MARK: - 库存操作

    func updateStock(for colorId: UUID, newStock: Int) {
        if let index = beadColors.firstIndex(where: { $0.id == colorId }) {
            beadColors[index].stock = max(0, newStock)
            saveData()
        }
    }

    func addStock(for colorId: UUID, amount: Int) {
        if let index = beadColors.firstIndex(where: { $0.id == colorId }) {
            beadColors[index].stock += amount
            saveData()
        }
    }

    func useBeads(for colorId: UUID, amount: Int) {
        if let index = beadColors.firstIndex(where: { $0.id == colorId }) {
            beadColors[index].used += amount
            saveData()
        }
    }

    func deductFromStock(colorCode: String, amount: Int) -> Bool {
        // 尝试通过各种色号匹配
        if let index = findColorIndex(byCode: colorCode) {
            // 允许库存变为负数（消耗量大于库存）
            beadColors[index].used += amount
            saveData()
            return true
        }
        return false
    }

    // MARK: - 搜索和查找

    func findColor(byCode code: String) -> BeadColor? {
        let code = code.uppercased().trimmingCharacters(in: .whitespaces)

        // 优先精确匹配 MARD 色号（避免与其他品牌色号冲突）
        if let mardMatch = beadColors.first(where: { $0.mardCode.uppercased() == code }) {
            return mardMatch
        }

        // 匹配其他品牌色号
        if let brandMatch = beadColors.first(where: { color in
            color.cocoCode.uppercased() == code ||
            color.manmanCode.uppercased() == code ||
            color.panpanCode.uppercased() == code ||
            color.mixiaowoCode.uppercased() == code ||
            color.kakaCode.uppercased() == code
        }) {
            return brandMatch
        }

        // 匹配自定义色号（包括 # 前缀、旧 C_ 前缀和不带前缀的色号）
        if let customColor = customColors.first(where: { custom in
            let customMardCode = custom.mardCode.uppercased()
            let customColorCode = custom.colorCode.uppercased()
            // 兼容旧的 C_ 前缀
            let oldMardCode = "C_\(customColorCode)"
            return customMardCode == code ||
                   customColorCode == code ||
                   oldMardCode == code
        }) {
            return customColor.toBeadColor()
        }

        return nil
    }

    /// 根据色号查找颜色，优先匹配指定的色号体系（避免不同品牌间色号冲突，如 B3 在卡卡和 MARD 中是不同颜色）
    func findColor(byCode code: String, preferSystem: ColorSystem) -> BeadColor? {
        let code = code.uppercased().trimmingCharacters(in: .whitespaces)

        // 当有明确的品牌偏好且不是 MARD 时，优先匹配该品牌的色号
        if preferSystem != .mard {
            let match = beadColors.first { color in
                switch preferSystem {
                case .kaka: return color.kakaCode.uppercased() == code
                case .coco: return color.cocoCode.uppercased() == code
                case .manman: return color.manmanCode.uppercased() == code
                case .panpan: return color.panpanCode.uppercased() == code
                case .mixiaowo: return color.mixiaowoCode.uppercased() == code
                case .mard: return false
                }
            }
            if let match { return match }
        }

        // 非 MARD 体系下不回退到 MARD 匹配，避免跨体系误扣库存
        // 例如卡卡的 B3 和 MARD 的 B3 是完全不同的颜色
        return nil
    }

    func findColorIndex(byCode code: String) -> Int? {
        let code = code.uppercased().trimmingCharacters(in: .whitespaces)

        // 优先精确匹配 MARD 色号（避免与其他品牌色号冲突）
        if let mardIndex = beadColors.firstIndex(where: { $0.mardCode.uppercased() == code }) {
            return mardIndex
        }

        // 再匹配其他品牌色号
        return beadColors.firstIndex { color in
            color.cocoCode.uppercased() == code ||
            color.manmanCode.uppercased() == code ||
            color.panpanCode.uppercased() == code ||
            color.mixiaowoCode.uppercased() == code ||
            color.kakaCode.uppercased() == code
        }
    }

    func searchColors(_ query: String) -> [BeadColor] {
        guard !query.isEmpty else { return allBeadColors }
        let query = query.uppercased()
        let system = currentColorSystem
        return allBeadColors.filter { color in
            color.displayCode(for: system).uppercased().contains(query) ||
            color.mardCode.uppercased().contains(query) ||
            color.colorName.uppercased().contains(query)
        }
    }

    /// 所有颜色（包括预设颜色和自定义色号）
    var allBeadColors: [BeadColor] {
        beadColors + customColors.map { $0.toBeadColor() }
    }

    // MARK: - 项目管理

    func addProject(_ project: ProjectRecord) {
        projects.insert(project, at: 0)
        saveData()

        // 记录历史
        historyManager.recordProject(type: .projectAdd, project: project)
    }

    func deleteProject(at offsets: IndexSet) {
        // 删除项目只从记录中移除，不回退库存
        projects.remove(atOffsets: offsets)
        saveData()
    }

    func deleteProject(id: UUID) {
        if let index = projects.firstIndex(where: { $0.id == id }) {
            let project = projects[index]

            // 记录历史（在删除前）
            historyManager.recordProject(type: .projectDelete, project: project)

            // 删除项目只从记录中移除，不回退库存
            projects.remove(at: index)
            saveData()
        }
    }

    func archiveProject(id: UUID) {
        // 归档项目，不回退库存
        if let index = projects.firstIndex(where: { $0.id == id }) {
            // 记录历史（在归档前）
            historyManager.recordProject(type: .projectArchive, project: projects[index])

            projects[index].isArchived = true
            saveData()
        }
    }

    func unarchiveProject(id: UUID) {
        // 取消归档
        if let index = projects.firstIndex(where: { $0.id == id }) {
            // 记录历史（在取消归档前）
            historyManager.recordProject(type: .projectUnarchive, project: projects[index])

            projects[index].isArchived = false
            saveData()
        }
    }

    private func restoreStockFromProject(_ project: ProjectRecord) {
        // 回退项目中已扣除的库存
        guard let brandId = project.brandId else { return }
        for usage in project.beadUsage where usage.isDeducted {
            // 先将色号转换为 mardCode（与 deductFromStock 保持一致）
            guard let color = findColor(byCode: usage.colorCode) else { continue }

            if let stockIndex = brandStocks.firstIndex(where: {
                $0.brandId == brandId && $0.mardCode == color.mardCode
            }) {
                brandStocks[stockIndex].used = max(0, brandStocks[stockIndex].used - usage.quantity)
            }
        }
    }

    func applyProjectToInventory(_ project: ProjectRecord) {
        guard let brandId = project.brandId else { return }
        for usage in project.beadUsage where !usage.isDeducted {
            _ = deductFromStock(brandId: brandId, colorCode: usage.colorCode, amount: usage.quantity, shouldSave: false)
        }
        saveData()
    }

    // MARK: - 项目层级管理

    /// 获取所有顶级项目（parentId == nil）
    func topLevelProjects() -> [ProjectRecord] {
        projects.filter { $0.parentId == nil }
    }

    /// 获取指定项目的子项目
    func childProjects(of parentId: UUID) -> [ProjectRecord] {
        projects.filter { $0.parentId == parentId }
    }

    /// 获取父项目的计划中子项目（未执行的）
    func plannedChildProjects(of parentId: UUID) -> [ProjectRecord] {
        projects.filter { $0.parentId == parentId && $0.isPlanned }
    }

    /// 获取父项目的已执行子项目
    func executedChildProjects(of parentId: UUID) -> [ProjectRecord] {
        projects.filter { $0.parentId == parentId && !$0.isPlanned }
    }

    /// 判断父项目是否还有未执行的子项目
    func hasPlannedChildren(_ parentId: UUID) -> Bool {
        projects.contains { $0.parentId == parentId && $0.isPlanned }
    }

    /// 判断父项目是否有已执行的子项目
    func hasExecutedChildren(_ parentId: UUID) -> Bool {
        projects.contains { $0.parentId == parentId && !$0.isPlanned }
    }

    /// 判断项目是否为父项目（有子项目）
    func isParentProject(_ projectId: UUID) -> Bool {
        projects.contains { $0.parentId == projectId }
    }

    /// 获取父项目的汇总 beadUsage（合并所有子项目）
    func aggregatedBeadUsage(for parentId: UUID) -> [BeadUsage] {
        let children = childProjects(of: parentId)
        var usageDict: [String: Int] = [:]  // colorCode -> quantity

        for child in children {
            for usage in child.beadUsage {
                usageDict[usage.colorCode, default: 0] += usage.quantity
            }
        }

        return usageDict.map { colorCode, quantity in
            BeadUsage(colorCode: colorCode, quantity: quantity, isDeducted: true)
        }.sorted { $0.colorCode < $1.colorCode }
    }

    /// 获取父项目的汇总总颗数
    func aggregatedTotalBeads(for parentId: UUID) -> Int {
        childProjects(of: parentId).reduce(0) { $0 + $1.totalBeads }
    }

    /// 获取父项目的汇总颜色数
    func aggregatedColorCount(for parentId: UUID) -> Int {
        let children = childProjects(of: parentId)
        var colorCodes = Set<String>()
        for child in children {
            for usage in child.beadUsage {
                colorCodes.insert(usage.colorCode)
            }
        }
        return colorCodes.count
    }

    // MARK: - 计划子项目统计（只统计未执行的子项目）

    /// 获取父项目的计划中子项目汇总 beadUsage
    func plannedAggregatedBeadUsage(for parentId: UUID) -> [BeadUsage] {
        let children = plannedChildProjects(of: parentId)
        var usageDict: [String: Int] = [:]

        for child in children {
            for usage in child.beadUsage {
                usageDict[usage.colorCode, default: 0] += usage.quantity
            }
        }

        return usageDict.map { colorCode, quantity in
            BeadUsage(colorCode: colorCode, quantity: quantity, isDeducted: false)
        }.sorted { $0.colorCode < $1.colorCode }
    }

    /// 获取父项目的计划中子项目汇总总颗数
    func plannedAggregatedTotalBeads(for parentId: UUID) -> Int {
        plannedChildProjects(of: parentId).reduce(0) { $0 + $1.totalBeads }
    }

    /// 获取父项目的计划中子项目汇总颜色数
    func plannedAggregatedColorCount(for parentId: UUID) -> Int {
        let children = plannedChildProjects(of: parentId)
        var colorCodes = Set<String>()
        for child in children {
            for usage in child.beadUsage {
                colorCodes.insert(usage.colorCode)
            }
        }
        return colorCodes.count
    }

    // MARK: - 已执行子项目统计

    /// 获取父项目的已执行子项目汇总 beadUsage
    func executedAggregatedBeadUsage(for parentId: UUID) -> [BeadUsage] {
        let children = executedChildProjects(of: parentId)
        var usageDict: [String: Int] = [:]

        for child in children {
            for usage in child.beadUsage {
                usageDict[usage.colorCode, default: 0] += usage.quantity
            }
        }

        return usageDict.map { colorCode, quantity in
            BeadUsage(colorCode: colorCode, quantity: quantity, isDeducted: true)
        }.sorted { $0.colorCode < $1.colorCode }
    }

    /// 获取父项目的已执行子项目汇总总颗数
    func executedAggregatedTotalBeads(for parentId: UUID) -> Int {
        executedChildProjects(of: parentId).reduce(0) { $0 + $1.totalBeads }
    }

    /// 获取父项目的已执行子项目汇总颜色数
    func executedAggregatedColorCount(for parentId: UUID) -> Int {
        let children = executedChildProjects(of: parentId)
        var colorCodes = Set<String>()
        for child in children {
            for usage in child.beadUsage {
                colorCodes.insert(usage.colorCode)
            }
        }
        return colorCodes.count
    }

    /// 合并多个项目
    /// - 一个父项目 + 独立项目：独立项目成为父项目的子项目
    /// - 多个父项目：创建新父项目，包含所有子项目（扁平化）
    /// - 多个独立项目：创建新父项目，独立项目成为子项目
    /// - 不允许计划项目与已执行项目混合合并
    @discardableResult
    func mergeProjects(_ projectIds: [UUID], newName: String) -> UUID? {
        guard projectIds.count > 1 else {
            print("合并失败：项目数量不足")
            return nil
        }

        // 确保选中的项目都是顶级项目
        let validProjects = projectIds.compactMap { id in
            projects.first { $0.id == id && $0.parentId == nil }
        }
        guard validProjects.count == projectIds.count else {
            print("合并失败：找到 \(validProjects.count) 个有效项目，期望 \(projectIds.count) 个")
            return nil
        }

        // 检查是否都是计划项目或都是已执行项目
        let allPlanned = validProjects.allSatisfy { $0.isPlanned }
        let allExecuted = validProjects.allSatisfy { !$0.isPlanned }

        print("合并检查：\(validProjects.count) 个项目")
        for p in validProjects {
            print("  - \(p.name): isPlanned=\(p.isPlanned)")
        }
        print("  allPlanned=\(allPlanned), allExecuted=\(allExecuted)")

        guard allPlanned || allExecuted else {
            print("合并失败：项目类型不一致")
            return nil
        }

        // 区分父项目和独立项目
        let parentProjects = validProjects.filter { isParentProject($0.id) }
        let independentProjects = validProjects.filter { !isParentProject($0.id) }

        // 情况1：只有一个父项目 + 一个或多个独立项目
        if parentProjects.count == 1 && !independentProjects.isEmpty {
            let existingParentId = parentProjects[0].id

            // 记录合并前的状态（只记录独立项目，因为父项目不变）
            let originalProjects = independentProjects

            // 将独立项目设为该父项目的子项目
            for project in independentProjects {
                if let index = projects.firstIndex(where: { $0.id == project.id }) {
                    projects[index].parentId = existingParentId
                }
            }
            saveData()

            // 记录合并历史
            HistoryManager.shared.recordProjectMerge(
                originalProjects: originalProjects,
                newParentId: nil,
                isSimpleMerge: true,
                existingParentId: existingParentId,
                mergedName: parentProjects[0].name
            )

            return existingParentId
        }

        // 情况2：多个父项目（可能还有独立项目）→ 创建新父项目，扁平化所有子项目
        if parentProjects.count > 1 {
            // 收集所有子项目及其当前状态
            var allChildrenProjects: [ProjectRecord] = []
            for parent in parentProjects {
                let children = childProjects(of: parent.id)
                allChildrenProjects.append(contentsOf: children)
            }
            // 加上独立项目
            allChildrenProjects.append(contentsOf: independentProjects)

            // 记录合并前的状态：所有子项目 + 所有父项目
            let originalProjects = allChildrenProjects + parentProjects

            // 创建新的父项目（继承第一个子项目的色号体系）
            let mergedColorSystem = allChildrenProjects.first?.colorSystem ?? .mard
            let newParentProject = ProjectRecord(
                name: newName,
                date: Date(),
                beadUsage: [],
                brandId: nil,
                isArchived: false,
                parentId: nil,
                isPlanned: allPlanned,
                colorSystem: mergedColorSystem
            )

            // 将所有子项目设为新父项目的子项目
            for child in allChildrenProjects {
                if let index = projects.firstIndex(where: { $0.id == child.id }) {
                    projects[index].parentId = newParentProject.id
                }
            }

            // 删除旧的父项目
            for parent in parentProjects {
                projects.removeAll { $0.id == parent.id }
            }

            // 添加新父项目
            projects.insert(newParentProject, at: 0)
            saveData()

            // 记录合并历史
            HistoryManager.shared.recordProjectMerge(
                originalProjects: originalProjects,
                newParentId: newParentProject.id,
                isSimpleMerge: false,
                existingParentId: nil,
                mergedName: newName
            )

            return newParentProject.id
        }

        // 情况3：只有独立项目 → 创建新父项目
        // 记录合并前的状态
        let originalProjects = independentProjects

        // 继承第一个子项目的色号体系
        let mergedColorSystem = independentProjects.first?.colorSystem ?? .mard
        let newParentProject = ProjectRecord(
            name: newName,
            date: Date(),
            beadUsage: [],
            brandId: nil,
            isArchived: false,
            parentId: nil,
            isPlanned: allPlanned,
            colorSystem: mergedColorSystem
        )

        // 将独立项目设为新父项目的子项目
        for project in independentProjects {
            if let index = projects.firstIndex(where: { $0.id == project.id }) {
                projects[index].parentId = newParentProject.id
            }
        }

        // 添加新父项目
        projects.insert(newParentProject, at: 0)
        saveData()

        // 记录合并历史
        HistoryManager.shared.recordProjectMerge(
            originalProjects: originalProjects,
            newParentId: newParentProject.id,
            isSimpleMerge: false,
            existingParentId: nil,
            mergedName: newName
        )

        return newParentProject.id
    }

    /// 撤回项目合并操作
    func revertProjectMerge(mergeSnapshot: MergeSnapshot) -> Bool {
        if mergeSnapshot.isSimpleMerge {
            // 简单合并撤回：将子项目的 parentId 恢复为 nil（变回独立项目）
            for projectSnapshot in mergeSnapshot.originalProjects {
                if let index = projects.firstIndex(where: { $0.id == projectSnapshot.id }) {
                    projects[index].parentId = projectSnapshot.parentId  // 恢复原始 parentId（通常是 nil）
                }
            }
            saveData()
            print("[InventoryManager] 撤回简单合并：恢复了 \(mergeSnapshot.originalProjects.count) 个项目")
            return true
        } else {
            // 复杂合并撤回：
            // 1. 删除新创建的父项目
            // 2. 恢复所有原始项目的状态

            // 先删除新父项目
            if let newParentId = mergeSnapshot.newParentId {
                projects.removeAll { $0.id == newParentId }
            }

            // 恢复所有原始项目的状态
            for projectSnapshot in mergeSnapshot.originalProjects {
                if let index = projects.firstIndex(where: { $0.id == projectSnapshot.id }) {
                    // 恢复 parentId
                    projects[index].parentId = projectSnapshot.parentId
                } else {
                    // 项目不存在（可能是被删除的旧父项目），需要重新创建
                    let usages = projectSnapshot.beadUsages.map {
                        BeadUsage(colorCode: $0.colorCode, brandId: $0.brandId, quantity: $0.quantity, isDeducted: $0.isDeducted)
                    }
                    let restoredProject = ProjectRecord(
                        id: projectSnapshot.id,
                        name: projectSnapshot.name,
                        date: projectSnapshot.date,
                        beadUsage: usages,
                        brandId: projectSnapshot.brandId,
                        isArchived: projectSnapshot.isArchived,
                        parentId: projectSnapshot.parentId,
                        isPlanned: projectSnapshot.isPlanned,
                        executedDate: projectSnapshot.executedDate,
                        colorSystem: projectSnapshot.colorSystem
                    )
                    projects.append(restoredProject)
                }
            }

            saveData()
            print("[InventoryManager] 撤回复杂合并：恢复了 \(mergeSnapshot.originalProjects.count) 个项目")
            return true
        }
    }

    /// 将子项目独立为顶级项目
    func detachProject(_ projectId: UUID) {
        if let index = projects.firstIndex(where: { $0.id == projectId }) {
            projects[index].parentId = nil
            saveData()
        }
    }

    /// 删除父项目（级联删除所有子项目）
    func deleteParentProjectCascade(id: UUID) {
        // 先删除所有子项目
        let children = childProjects(of: id)
        for child in children {
            restoreStockFromProject(child)
        }
        projects.removeAll { $0.parentId == id }

        // 再删除父项目本身
        if let index = projects.firstIndex(where: { $0.id == id }) {
            restoreStockFromProject(projects[index])
            projects.remove(at: index)
        }
        saveData()
    }

    /// 删除父项目（子项目变为独立项目）
    func deleteParentProjectDetach(id: UUID) {
        // 将子项目独立
        for index in projects.indices {
            if projects[index].parentId == id {
                projects[index].parentId = nil
            }
        }

        // 删除父项目本身
        if let index = projects.firstIndex(where: { $0.id == id }) {
            restoreStockFromProject(projects[index])
            projects.remove(at: index)
        }
        saveData()
    }

    /// 归档父项目及其所有子项目
    func archiveProjectWithChildren(id: UUID) {
        // 归档父项目
        if let index = projects.firstIndex(where: { $0.id == id }) {
            projects[index].isArchived = true
        }
        // 归档所有子项目
        for index in projects.indices {
            if projects[index].parentId == id {
                projects[index].isArchived = true
            }
        }
        saveData()
    }

    /// 取消归档父项目及其所有子项目
    func unarchiveProjectWithChildren(id: UUID) {
        // 取消归档父项目
        if let index = projects.firstIndex(where: { $0.id == id }) {
            projects[index].isArchived = false
        }
        // 取消归档所有子项目
        for index in projects.indices {
            if projects[index].parentId == id {
                projects[index].isArchived = false
            }
        }
        saveData()
    }

    // MARK: - 计划项目管理

    /// 获取所有计划中的顶级项目
    func plannedProjects() -> [ProjectRecord] {
        // 获取所有顶级项目（没有父项目的）
        let topLevel = projects.filter { $0.parentId == nil && !$0.isArchived }

        return topLevel.filter { project in
            if isParentProject(project.id) {
                // 父项目：只有当它还有未执行的子项目时才显示
                return hasPlannedChildren(project.id)
            } else {
                // 独立项目：根据自身的 isPlanned 状态
                return project.isPlanned
            }
        }
    }

    /// 获取计划项目数量（用于 Tab Badge）
    func plannedProjectCount() -> Int {
        plannedProjects().count
    }

    /// 判断项目是否为计划项目
    func isPlannedProject(_ projectId: UUID) -> Bool {
        projects.first { $0.id == projectId }?.isPlanned ?? false
    }

    /// 创建计划项目（扫描后不选择品牌时调用）
    func addPlannedProject(_ project: ProjectRecord) {
        var plannedProject = project
        plannedProject.isPlanned = true
        plannedProject.brandId = nil
        // 确保 beadUsage 的 isDeducted 都为 false
        plannedProject.beadUsage = plannedProject.beadUsage.map { usage in
            BeadUsage(id: usage.id, colorCode: usage.colorCode, brandId: nil,
                      quantity: usage.quantity, isDeducted: false)
        }
        projects.insert(plannedProject, at: 0)
        saveData()

        // 记录历史
        historyManager.recordProject(type: .planAdd, project: plannedProject)
    }

    /// 执行计划项目：选择品牌后一次性扣减库存
    @discardableResult
    func executePlannedProject(_ projectId: UUID, withBrand brandId: UUID) -> Bool {
        guard let index = projects.firstIndex(where: { $0.id == projectId }) else {
            return false
        }

        let project = projects[index]
        guard project.isPlanned else { return false }

        // 防御性校验：品牌色号体系必须与项目色号体系一致
        guard let brand = brands.first(where: { $0.id == brandId }),
              brand.colorSystem == project.colorSystem else {
            return false
        }

        // 如果是父项目，递归执行所有子项目
        if isParentProject(projectId) {
            return executePlannedParentProject(projectId, withBrand: brandId)
        }

        // 保存执行前的项目状态（用于撤回）
        let beforeProject = project

        // 执行库存扣减（批量操作，不逐个保存）
        for usage in project.beadUsage {
            _ = deductFromStock(brandId: brandId, colorCode: usage.colorCode, amount: usage.quantity, shouldSave: false)
        }

        // 更新项目状态
        projects[index].isPlanned = false
        projects[index].brandId = brandId
        projects[index].executedDate = Date()
        // 更新 beadUsage 的 isDeducted 状态
        projects[index].beadUsage = project.beadUsage.map { usage in
            BeadUsage(id: usage.id, colorCode: usage.colorCode, brandId: brandId,
                      quantity: usage.quantity, isDeducted: true)
        }

        // 如果这是一个子项目，检查父项目是否还有其他未执行的子项目
        if let parentId = project.parentId {
            // 检查父项目是否还有其他未执行的子计划（排除当前刚执行的这个）
            let remainingPlannedChildren = projects.filter {
                $0.parentId == parentId && $0.isPlanned && $0.id != projectId
            }
            // 如果没有其他未执行的子计划，将父项目的 isPlanned 设为 false
            if remainingPlannedChildren.isEmpty {
                if let parentIndex = projects.firstIndex(where: { $0.id == parentId }) {
                    projects[parentIndex].isPlanned = false
                    projects[parentIndex].executedDate = Date()
                    projects[parentIndex].brandId = brandId
                }
            }
        }

        saveData()

        // 记录历史（保存执行前和执行后的状态）
        historyManager.recordPlanExecute(beforeProject: beforeProject, afterProject: projects[index])

        return true
    }

    /// 执行计划父项目及其所有子项目
    private func executePlannedParentProject(_ parentId: UUID, withBrand brandId: UUID) -> Bool {
        guard let parentIndex = projects.firstIndex(where: { $0.id == parentId }) else {
            return false
        }

        // 获取所有子项目
        let children = childProjects(of: parentId)

        // 执行所有子项目的库存扣减（批量操作，不逐个保存）
        for child in children {
            if let childIndex = projects.firstIndex(where: { $0.id == child.id }) {
                for usage in child.beadUsage {
                    _ = deductFromStock(brandId: brandId, colorCode: usage.colorCode, amount: usage.quantity, shouldSave: false)
                }

                // 更新子项目状态
                projects[childIndex].isPlanned = false
                projects[childIndex].brandId = brandId
                projects[childIndex].executedDate = Date()
                projects[childIndex].beadUsage = child.beadUsage.map { usage in
                    BeadUsage(id: usage.id, colorCode: usage.colorCode, brandId: brandId,
                              quantity: usage.quantity, isDeducted: true)
                }
            }
        }

        // 更新父项目状态
        projects[parentIndex].isPlanned = false
        projects[parentIndex].brandId = brandId
        projects[parentIndex].executedDate = Date()

        saveData()
        return true
    }

    /// 删除计划项目（不回退库存，因为还未扣减）
    func deletePlannedProject(_ projectId: UUID) {
        guard let project = projects.first(where: { $0.id == projectId }) else {
            return
        }

        // 查找子项目（如果有）
        let children = projects.filter { $0.parentId == projectId }

        // 记录历史（在删除前），包含父项目和子项目
        historyManager.recordPlanDelete(project: project, children: children)

        // 如果是父项目，也删除子项目
        if !children.isEmpty {
            projects.removeAll { $0.parentId == projectId }
        }
        projects.removeAll { $0.id == projectId }
        saveData()
    }

    /// 复制计划项目（支持文件夹完整复制）
    @discardableResult
    func duplicatePlannedProject(_ projectId: UUID) -> UUID? {
        guard let index = projects.firstIndex(where: { $0.id == projectId && $0.isPlanned }) else {
            return nil
        }

        let project = projects[index]
        let newId = UUID()

        // 复制 beadUsage，生成新的 UUID
        let newBeadUsage = project.beadUsage.map { usage in
            BeadUsage(
                id: UUID(),
                colorCode: usage.colorCode,
                brandId: nil,
                quantity: usage.quantity,
                isDeducted: false
            )
        }

        // 创建副本项目
        let duplicatedProject = ProjectRecord(
            id: newId,
            name: project.name + " (副本)",
            date: Date(),
            beadUsage: newBeadUsage,
            brandId: nil,
            isArchived: false,
            parentId: nil,  // 副本总是顶级项目
            isPlanned: true,
            executedDate: nil,
            thumbnail: project.thumbnail,
            colorSystem: project.colorSystem
        )

        // 插入到原项目后面
        projects.insert(duplicatedProject, at: index + 1)

        // 如果是父项目，复制所有子项目
        if isParentProject(projectId) {
            let children = childProjects(of: projectId)
            for child in children {
                let newChildId = UUID()
                let newChildBeadUsage = child.beadUsage.map { usage in
                    BeadUsage(
                        id: UUID(),
                        colorCode: usage.colorCode,
                        brandId: nil,
                        quantity: usage.quantity,
                        isDeducted: false
                    )
                }
                let duplicatedChild = ProjectRecord(
                    id: newChildId,
                    name: child.name,
                    date: Date(),
                    beadUsage: newChildBeadUsage,
                    brandId: nil,
                    isArchived: false,
                    parentId: newId,  // 关联到新的父项目
                    isPlanned: true,
                    executedDate: nil,
                    thumbnail: child.thumbnail,
                    colorSystem: child.colorSystem
                )
                projects.append(duplicatedChild)
            }
        }

        saveData()

        // 记录历史
        historyManager.recordProject(type: .planAdd, project: duplicatedProject)

        return newId
    }

    /// 复制任意项目到计划列表（支持文件夹完整复制）
    @discardableResult
    func duplicateProjectAsPlan(_ projectId: UUID) -> UUID? {
        guard let project = projects.first(where: { $0.id == projectId }) else {
            return nil
        }

        let newId = UUID()

        // 复制 beadUsage，生成新的 UUID
        let newBeadUsage = project.beadUsage.map { usage in
            BeadUsage(
                id: UUID(),
                colorCode: usage.colorCode,
                brandId: nil,
                quantity: usage.quantity,
                isDeducted: false
            )
        }

        // 创建副本项目
        let duplicatedProject = ProjectRecord(
            id: newId,
            name: project.name + " (副本)",
            date: Date(),
            beadUsage: newBeadUsage,
            brandId: nil,
            isArchived: false,
            parentId: nil,
            isPlanned: true,
            executedDate: nil,
            thumbnail: project.thumbnail,
            colorSystem: project.colorSystem
        )

        // 插入到列表开头
        projects.insert(duplicatedProject, at: 0)

        // 如果是父项目，复制所有子项目
        if isParentProject(projectId) {
            let children = childProjects(of: projectId)
            for child in children {
                let newChildId = UUID()
                let newChildBeadUsage = child.beadUsage.map { usage in
                    BeadUsage(
                        id: UUID(),
                        colorCode: usage.colorCode,
                        brandId: nil,
                        quantity: usage.quantity,
                        isDeducted: false
                    )
                }
                let duplicatedChild = ProjectRecord(
                    id: newChildId,
                    name: child.name,
                    date: Date(),
                    beadUsage: newChildBeadUsage,
                    brandId: nil,
                    isArchived: false,
                    parentId: newId,  // 关联到新的父项目
                    isPlanned: true,
                    executedDate: nil,
                    thumbnail: child.thumbnail,
                    colorSystem: child.colorSystem
                )
                projects.append(duplicatedChild)
            }
        }

        saveData()

        // 记录历史
        historyManager.recordProject(type: .planAdd, project: duplicatedProject)

        return newId
    }

    /// 更新计划项目名称
    func updatePlannedProjectName(_ projectId: UUID, newName: String) {
        if let index = projects.firstIndex(where: { $0.id == projectId && $0.isPlanned }) {
            // 记录历史（在修改前）
            historyManager.recordProject(type: .planUpdate, project: projects[index])

            projects[index].name = newName
            saveData()
        }
    }

    /// 更新计划项目内容（名称和用量）
    func updatePlannedProject(_ projectId: UUID, newName: String, newBeadUsage: [BeadUsage]) {
        if let index = projects.firstIndex(where: { $0.id == projectId && $0.isPlanned }) {
            // 记录历史（在修改前）
            historyManager.recordProject(type: .planUpdate, project: projects[index])

            projects[index].name = newName
            projects[index].beadUsage = newBeadUsage
            // 重新计算 totalBeads
            projects[index].totalBeads = newBeadUsage.reduce(0) { $0 + $1.quantity }
            saveData()
        }
    }

    /// 更新计划项目单个颜色的数量
    func updatePlannedProjectUsage(_ projectId: UUID, colorCode: String, newQuantity: Int) {
        if let index = projects.firstIndex(where: { $0.id == projectId && $0.isPlanned }) {
            // 记录历史（在修改前）
            historyManager.recordProject(type: .planUpdate, project: projects[index])

            if let usageIndex = projects[index].beadUsage.firstIndex(where: { $0.colorCode == colorCode }) {
                if newQuantity <= 0 {
                    // 数量为0或负数时删除该颜色
                    projects[index].beadUsage.remove(at: usageIndex)
                } else {
                    projects[index].beadUsage[usageIndex].quantity = newQuantity
                }
                // 重新计算 totalBeads
                projects[index].totalBeads = projects[index].beadUsage.reduce(0) { $0 + $1.quantity }
                saveData()
            }
        }
    }

    /// 删除计划项目中的单个颜色
    func deletePlannedProjectUsage(_ projectId: UUID, colorCode: String) {
        if let index = projects.firstIndex(where: { $0.id == projectId && $0.isPlanned }) {
            // 记录历史（在修改前）
            historyManager.recordProject(type: .planUpdate, project: projects[index])

            projects[index].beadUsage.removeAll { $0.colorCode == colorCode }
            // 重新计算 totalBeads
            projects[index].totalBeads = projects[index].beadUsage.reduce(0) { $0 + $1.quantity }
            saveData()
        }
    }

    /// 添加计划项目中的颜色
    func addPlannedProjectUsage(_ projectId: UUID, colorCode: String, quantity: Int) {
        if let index = projects.firstIndex(where: { $0.id == projectId && $0.isPlanned }) {
            // 检查是否已存在该颜色
            if let usageIndex = projects[index].beadUsage.firstIndex(where: { $0.colorCode == colorCode }) {
                // 已存在，增加数量
                projects[index].beadUsage[usageIndex].quantity += quantity
            } else {
                // 不存在，添加新颜色
                let newUsage = BeadUsage(colorCode: colorCode, brandId: nil, quantity: quantity, isDeducted: false)
                projects[index].beadUsage.append(newUsage)
            }
            // 重新计算 totalBeads
            projects[index].totalBeads = projects[index].beadUsage.reduce(0) { $0 + $1.quantity }
            saveData()
        }
    }

    // MARK: - 项目图片管理

    /// 更新项目缩略图（支持计划项目和已执行项目）
    func updateProjectThumbnail(_ projectId: UUID, thumbnail: Data?) {
        if let index = projects.firstIndex(where: { $0.id == projectId }) {
            // 记录历史
            historyManager.recordProject(type: projects[index].isPlanned ? .planUpdate : .projectUpdate, project: projects[index])

            projects[index].thumbnail = thumbnail
            saveData()
        }
    }

    /// 更新项目成品图（仅已执行项目）
    /// 如果是新增成品图且之前没有完成日期，自动设置为当天
    func updateProjectFinishedImage(_ projectId: UUID, finishedImage: Data?) {
        if let index = projects.firstIndex(where: { $0.id == projectId && !$0.isPlanned }) {
            // 记录历史
            historyManager.recordProject(type: .projectUpdate, project: projects[index])

            projects[index].finishedImage = finishedImage

            // 上传成品图时，如果没有完成日期，自动设置为当天
            if finishedImage != nil && projects[index].completedDate == nil {
                projects[index].completedDate = Date()
            }

            saveData()
        }
    }

    /// 更新项目完成日期（仅已执行项目）
    func updateProjectCompletedDate(_ projectId: UUID, completedDate: Date?) {
        if let index = projects.firstIndex(where: { $0.id == projectId && !$0.isPlanned }) {
            // 记录历史
            historyManager.recordProject(type: .projectUpdate, project: projects[index])

            projects[index].completedDate = completedDate
            saveData()
        }
    }

    // MARK: - 统计

    var totalStock: Int {
        beadColors.reduce(0) { $0 + $1.stock }
    }

    var totalUsed: Int {
        beadColors.reduce(0) { $0 + $1.used }
    }

    var totalAvailable: Int {
        beadColors.reduce(0) { $0 + $1.available }
    }

    var lowStockColors: [BeadColor] {
        beadColors.filter { $0.available < 100 }
    }

    // MARK: - 运输中（购买记录）

    /// 添加购买记录
    func addPurchaseRecord(name: String, brandId: UUID, items: [PurchaseItem], note: String? = nil) {
        let record = PurchaseRecord(name: name, brandId: brandId, items: items, note: note)
        purchaseRecords.append(record)
        savePurchaseRecords()
    }

    /// 删除购买记录
    func deletePurchaseRecord(id: UUID) {
        purchaseRecords.removeAll { $0.id == id }
        savePurchaseRecords()
    }

    /// 确认购买记录到货（添加到库存并删除记录）
    func confirmPurchaseRecord(id: UUID) {
        guard let record = purchaseRecords.first(where: { $0.id == id }) else { return }

        // 批量将购买的物品添加到库存（不记录单独的历史）
        for item in record.items {
            if let index = brandStocks.firstIndex(where: {
                $0.brandId == record.brandId && $0.mardCode == item.colorCode
            }) {
                brandStocks[index].stock += item.quantity
                // 如果是隐藏的色号，自动取消隐藏
                if brandStocks[index].isHidden {
                    brandStocks[index].isHidden = false
                }
            }
        }

        // 一次性保存所有库存变更
        saveData()

        // 记录历史（只记录一次汇总）
        let brandName = brands.first(where: { $0.id == record.brandId })?.name ?? "未知品牌"
        historyManager.record(type: .stockAdd, entityName: "\(brandName) 到货: \(record.name) (\(record.colorCount)色 +\(record.totalBeads)颗)")

        // 删除记录
        purchaseRecords.removeAll { $0.id == id }
        savePurchaseRecords()
    }

    /// 更新购买记录
    func updatePurchaseRecord(id: UUID, name: String? = nil, brandId: UUID? = nil, items: [PurchaseItem]? = nil, note: String? = nil) {
        guard let index = purchaseRecords.firstIndex(where: { $0.id == id }) else { return }
        if let name = name {
            purchaseRecords[index].name = name
        }
        if let brandId = brandId {
            purchaseRecords[index].brandId = brandId
        }
        if let items = items {
            purchaseRecords[index].items = items
        }
        if let note = note {
            purchaseRecords[index].note = note
        }
        savePurchaseRecords()
    }

    /// 获取指定品牌的购买记录
    func purchaseRecords(for brandId: UUID) -> [PurchaseRecord] {
        purchaseRecords.filter { $0.brandId == brandId }
    }

    // MARK: - 重置

    func resetAllStock(to amount: Int = 1000) {
        guard let brandId = currentBrandId else { return }

        // 获取当前品牌名称用于历史记录
        let brandName = brands.first(where: { $0.id == brandId })?.name ?? "未知品牌"

        // 清除当前品牌的所有库存记录
        brandStocks.removeAll { $0.brandId == brandId }
        // 为每个颜色创建新的库存记录
        for color in beadColors {
            let newStock = BrandStock(brandId: brandId, mardCode: color.mardCode, stock: amount, used: 0)
            brandStocks.append(newStock)
        }
        saveData()

        // 记录历史
        historyManager.record(type: .stockReset, entityName: "\(brandName) → \(amount)")
    }

    func resetUsage() {
        guard let brandId = currentBrandId else { return }
        // 重置当前品牌所有颜色的使用记录
        for index in brandStocks.indices {
            if brandStocks[index].brandId == brandId {
                brandStocks[index].used = 0
            }
        }
        saveData()
    }

    func clearAllData() {
        // 清除所有品牌库存数据
        brandStocks.removeAll()
        // 清除所有项目记录
        projects.removeAll()
        saveData()
    }

    // MARK: - 初始化默认颜色数据

    private func initializeDefaultColors() {
        beadColors = loadAllColorsFromJSON()
        print("[InventoryManager] 从 allcolors.json 加载 \(beadColors.count) 个颜色")
    }

    // MARK: - 从 allcolors.json 加载所有颜色数据
    /// 统一颜色数据源：包含所有 MARD 标准色 + 卡卡独有色（含真实 HEX）
    private func loadAllColorsFromJSON() -> [BeadColor] {
        guard let url = Bundle.main.url(forResource: "allcolors", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            print("[InventoryManager] ⚠️ 未找到 allcolors.json，使用空颜色列表")
            return []
        }

        do {
            let entries = try JSONDecoder().decode([[String: String]].self, from: data)
            return entries.map { entry in
                BeadColor(
                    colorHex: entry["colorHex"] ?? "CCCCCC",
                    mardCode: entry["mardCode"] ?? "",
                    cocoCode: entry["cocoCode"] ?? "",
                    manmanCode: entry["manmanCode"] ?? "",
                    panpanCode: entry["panpanCode"] ?? "",
                    mixiaowoCode: entry["mixiaowoCode"] ?? "",
                    kakaCode: entry["kakaCode"] ?? ""
                )
            }
        } catch {
            print("[InventoryManager] ⚠️ allcolors.json 解析失败: \(error)")
            return []
        }
    }

}
