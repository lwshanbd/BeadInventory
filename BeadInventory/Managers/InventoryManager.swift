//
//  InventoryManager.swift
//  BeadInventory
//
//  库存管理器 - 使用 SwiftData 进行数据持久化
//

import Foundation
import SwiftUI
import SwiftData

class InventoryManager: ObservableObject {
    @Published var beadColors: [BeadColor] = []
    @Published var projects: [ProjectRecord] = []

    // 品牌相关
    @Published var brands: [Brand] = []
    @Published var brandStocks: [BrandStock] = []
    @Published var currentBrandId: UUID?

    // SwiftData ModelContext
    private var modelContext: ModelContext?

    // 历史记录管理器
    private var historyManager: HistoryManager { HistoryManager.shared }

    // UserDefaults keys (用于迁移和当前品牌ID)
    private let beadColorsKey = "beadColors"
    private let projectsKey = "projects"
    private let brandsKey = "brands"
    private let brandStocksKey = "brandStocks"
    private let currentBrandIdKey = "currentBrandId"
    private let migrationCompletedKey = "swiftDataMigrationCompleted"

    // 计算属性：当前选中的品牌
    var currentBrand: Brand? {
        guard let id = currentBrandId else { return nil }
        return brands.first { $0.id == id }
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
    func addBrand(name: String, defaultStock: Int = 1000, selectedColors: Set<String>? = nil) -> Brand {
        let maxOrder = brands.map { $0.sortOrder }.max() ?? -1
        let brand = Brand(
            name: name,
            sortOrder: maxOrder + 1
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

    func selectBrand(_ brandId: UUID) {
        if brands.contains(where: { $0.id == brandId }) {
            currentBrandId = brandId
            saveCurrentBrandId()
        }
    }

    // MARK: - 品牌库存操作

    func initializeStockForBrand(_ brandId: UUID, defaultStock: Int = 1000, selectedColors: Set<String>? = nil) {
        for color in beadColors {
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

    func deductFromStock(brandId: UUID, colorCode: String, amount: Int) -> Bool {
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
            saveData()
            return true
        }
        return false
    }

    /// 撤回库存扣减（不记录历史）
    func revertFromStock(brandId: UUID, colorCode: String, amount: Int) -> Bool {
        guard let color = findColor(byCode: colorCode) else { return false }

        if let index = brandStocks.firstIndex(where: {
            $0.brandId == brandId && $0.mardCode == color.mardCode
        }) {
            brandStocks[index].used -= amount
            saveData()
            return true
        }
        return false
    }

    /// 撤回计划执行：恢复项目状态和库存
    func revertPlanExecute(projectId: UUID, brandId: UUID, beadUsages: [(colorCode: String, quantity: Int)]) -> Bool {
        guard let index = projects.firstIndex(where: { $0.id == projectId }) else {
            return false
        }

        // 恢复库存（把扣减的库存加回去）
        for usage in beadUsages {
            _ = revertFromStock(brandId: brandId, colorCode: usage.colorCode, amount: usage.quantity)
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
        brandStocks.filter { $0.brandId == brandId && !$0.isHidden && $0.available < 100 }
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

    // MARK: - 数据持久化 (SwiftData)

    func loadData() {
        guard let context = modelContext else {
            loadDataFromUserDefaults()
            return
        }

        // 检查是否需要迁移
        let needsMigration = !UserDefaults.standard.bool(forKey: migrationCompletedKey)
        if needsMigration {
            migrateFromUserDefaults()
        }

        // 从 SwiftData 加载品牌
        let brandDescriptor = FetchDescriptor<SDBrand>(sortBy: [SortDescriptor(\.sortOrder)])
        if let sdBrands = try? context.fetch(brandDescriptor) {
            brands = sdBrands.map { $0.toStruct() }
        }

        // 从 SwiftData 加载品牌库存
        let stockDescriptor = FetchDescriptor<SDBrandStock>()
        if let sdStocks = try? context.fetch(stockDescriptor) {
            brandStocks = sdStocks.map { $0.toStruct() }
        }

        // 从 SwiftData 加载项目记录
        let projectDescriptor = FetchDescriptor<SDProjectRecord>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        do {
            let sdProjects = try context.fetch(projectDescriptor)
            projects = sdProjects.map { $0.toStruct() }
            print("成功加载 \(projects.count) 个项目记录")
        } catch {
            print("加载项目记录失败: \(error)")
            // 不覆盖现有数据，保持 projects 为空数组（初始状态）
        }

        // 加载当前品牌 ID
        if let idString = UserDefaults.standard.string(forKey: currentBrandIdKey),
           let id = UUID(uuidString: idString) {
            currentBrandId = id
        }

        // 初始化颜色数据
        beadColors = DefaultBeadColors.colors
    }

    func saveData() {
        guard let context = modelContext else { return }

        do {
            // 删除旧的品牌数据
            try context.delete(model: SDBrand.self)
            // 保存新的品牌数据
            for brand in brands {
                let sdBrand = SDBrand(from: brand)
                context.insert(sdBrand)
            }

            // 删除旧的库存数据
            try context.delete(model: SDBrandStock.self)
            // 保存新的库存数据
            for stock in brandStocks {
                let sdStock = SDBrandStock(from: stock)
                context.insert(sdStock)
            }

            // 删除旧的项目数据
            try context.delete(model: SDProjectRecord.self)
            // 保存新的项目数据
            for project in projects {
                let sdProject = SDProjectRecord(from: project)
                context.insert(sdProject)
            }

            try context.save()
            saveCurrentBrandId()
        } catch {
            print("保存数据失败: \(error)")
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
    private func loadDataFromUserDefaults() {
        // 加载颜色数据
        beadColors = DefaultBeadColors.colors

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

        // 再匹配其他品牌色号
        return beadColors.first { color in
            color.cocoCode.uppercased() == code ||
            color.manmanCode.uppercased() == code ||
            color.panpanCode.uppercased() == code ||
            color.mixiaowoCode.uppercased() == code
        }
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
            color.mixiaowoCode.uppercased() == code
        }
    }

    func searchColors(_ query: String) -> [BeadColor] {
        guard !query.isEmpty else { return beadColors }
        let query = query.uppercased()
        return beadColors.filter { color in
            color.mardCode.uppercased().contains(query) ||
            color.cocoCode.uppercased().contains(query) ||
            color.manmanCode.uppercased().contains(query) ||
            color.panpanCode.uppercased().contains(query) ||
            color.mixiaowoCode.uppercased().contains(query) ||
            color.colorName.uppercased().contains(query)
        }
    }

    // MARK: - 项目管理

    func addProject(_ project: ProjectRecord) {
        projects.insert(project, at: 0)
        saveData()

        // 记录历史
        historyManager.recordProject(type: .projectAdd, project: project)
    }

    func deleteProject(at offsets: IndexSet) {
        // 删除项目时，回退库存
        for index in offsets {
            let project = projects[index]
            restoreStockFromProject(project)
        }
        projects.remove(atOffsets: offsets)
        saveData()
    }

    func deleteProject(id: UUID) {
        if let index = projects.firstIndex(where: { $0.id == id }) {
            let project = projects[index]

            // 记录历史（在删除前）
            historyManager.recordProject(type: .projectDelete, project: project)

            restoreStockFromProject(project)
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
            _ = deductFromStock(brandId: brandId, colorCode: usage.colorCode, amount: usage.quantity)
        }
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
            // 将独立项目设为该父项目的子项目
            for project in independentProjects {
                if let index = projects.firstIndex(where: { $0.id == project.id }) {
                    projects[index].parentId = existingParentId
                }
            }
            saveData()
            return existingParentId
        }

        // 情况2：多个父项目（可能还有独立项目）→ 创建新父项目，扁平化所有子项目
        if parentProjects.count > 1 {
            // 收集所有子项目
            var allChildren: [UUID] = []
            for parent in parentProjects {
                let children = childProjects(of: parent.id)
                allChildren.append(contentsOf: children.map { $0.id })
            }
            // 加上独立项目
            allChildren.append(contentsOf: independentProjects.map { $0.id })

            // 创建新的父项目
            let newParentProject = ProjectRecord(
                name: newName,
                date: Date(),
                beadUsage: [],
                brandId: nil,
                isArchived: false,
                parentId: nil,
                isPlanned: allPlanned
            )

            // 将所有子项目设为新父项目的子项目
            for childId in allChildren {
                if let index = projects.firstIndex(where: { $0.id == childId }) {
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
            return newParentProject.id
        }

        // 情况3：只有独立项目 → 创建新父项目
        let newParentProject = ProjectRecord(
            name: newName,
            date: Date(),
            beadUsage: [],
            brandId: nil,
            isArchived: false,
            parentId: nil,
            isPlanned: allPlanned
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
        return newParentProject.id
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
        projects.filter { $0.isPlanned && $0.parentId == nil && !$0.isArchived }
    }

    /// 获取计划项目数量（用于 Tab Badge）
    func plannedProjectCount() -> Int {
        // 只统计顶级计划项目（与 plannedProjects() 一致）
        projects.filter { $0.isPlanned && $0.parentId == nil && !$0.isArchived }.count
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

        // 如果是父项目，递归执行所有子项目
        if isParentProject(projectId) {
            return executePlannedParentProject(projectId, withBrand: brandId)
        }

        // 保存执行前的项目状态（用于撤回）
        let beforeProject = project

        // 执行库存扣减
        for usage in project.beadUsage {
            _ = deductFromStock(brandId: brandId, colorCode: usage.colorCode, amount: usage.quantity)
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

        // 执行所有子项目的库存扣减
        for child in children {
            if let childIndex = projects.firstIndex(where: { $0.id == child.id }) {
                for usage in child.beadUsage {
                    _ = deductFromStock(brandId: brandId, colorCode: usage.colorCode, amount: usage.quantity)
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
        // 记录历史（在删除前）
        if let project = projects.first(where: { $0.id == projectId }) {
            historyManager.recordProject(type: .planDelete, project: project)
        }

        // 如果是父项目，也删除子项目
        if isParentProject(projectId) {
            projects.removeAll { $0.parentId == projectId }
        }
        projects.removeAll { $0.id == projectId }
        saveData()
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
        // 初始化221个常用实色 (示例数据，实际使用时可以从文件导入)
        beadColors = DefaultBeadColors.colors
    }
}

// MARK: - 默认颜色数据 (来自 convert.csv)
struct DefaultBeadColors {
    static let colors: [BeadColor] = [
        // A系列
        BeadColor(colorHex: "FAF4C8", mardCode: "A1", cocoCode: "E02", manmanCode: "E2", panpanCode: "65", mixiaowoCode: "77"),
        BeadColor(colorHex: "FFFFD5", mardCode: "A2", cocoCode: "E01", manmanCode: "B1", panpanCode: "2", mixiaowoCode: "2"),
        BeadColor(colorHex: "FEFF8B", mardCode: "A3", cocoCode: "E05", manmanCode: "B2", panpanCode: "28", mixiaowoCode: "28"),
        BeadColor(colorHex: "FBED56", mardCode: "A4", cocoCode: "E07", manmanCode: "B3", panpanCode: "3", mixiaowoCode: "3"),
        BeadColor(colorHex: "F4D738", mardCode: "A5", cocoCode: "D03", manmanCode: "B4", panpanCode: "74", mixiaowoCode: "79"),
        BeadColor(colorHex: "FEAC4C", mardCode: "A6", cocoCode: "D05", manmanCode: "B5", panpanCode: "29", mixiaowoCode: "29"),
        BeadColor(colorHex: "FE8B4C", mardCode: "A7", cocoCode: "D08", manmanCode: "B6", panpanCode: "4", mixiaowoCode: "4"),
        BeadColor(colorHex: "FFDA45", mardCode: "A8", cocoCode: "E08", manmanCode: "B10", panpanCode: "88", mixiaowoCode: "98"),
        BeadColor(colorHex: "FF995B", mardCode: "A9", cocoCode: "D06", manmanCode: "B11", panpanCode: "90", mixiaowoCode: "97"),
        BeadColor(colorHex: "F77C31", mardCode: "A10", cocoCode: "D07", manmanCode: "B12", panpanCode: "89", mixiaowoCode: "96"),
        BeadColor(colorHex: "FFDD99", mardCode: "A11", cocoCode: "D01", manmanCode: "E11", panpanCode: "100", mixiaowoCode: "109"),
        BeadColor(colorHex: "FE9F72", mardCode: "A12", cocoCode: "K09", manmanCode: "A18", panpanCode: "99", mixiaowoCode: "110"),
        BeadColor(colorHex: "FFC365", mardCode: "A13", cocoCode: "D04", manmanCode: "B13", panpanCode: "131", mixiaowoCode: "116"),
        BeadColor(colorHex: "FD543D", mardCode: "A14", cocoCode: "C05", manmanCode: "B14", panpanCode: "138", mixiaowoCode: "135"),
        BeadColor(colorHex: "FFF365", mardCode: "A15", cocoCode: "E04", manmanCode: "B15", panpanCode: "150", mixiaowoCode: "150"),
        BeadColor(colorHex: "FFFF9F", mardCode: "A16", cocoCode: "E03", manmanCode: "IC04", panpanCode: "216", mixiaowoCode: "216"),
        BeadColor(colorHex: "FFE36E", mardCode: "A17", cocoCode: "E06", manmanCode: "IC9", panpanCode: "213", mixiaowoCode: "213"),
        BeadColor(colorHex: "FEBE7D", mardCode: "A18", cocoCode: "D02", manmanCode: "IC14", panpanCode: "223", mixiaowoCode: "208"),
        BeadColor(colorHex: "FD7C72", mardCode: "A19", cocoCode: "K10", manmanCode: "IC15", panpanCode: "218", mixiaowoCode: "218"),
        BeadColor(colorHex: "FFD568", mardCode: "A20", cocoCode: "E09", manmanCode: "Q6", panpanCode: "242", mixiaowoCode: "242"),
        BeadColor(colorHex: "FFE395", mardCode: "A21", cocoCode: "E10", manmanCode: "R07", panpanCode: "276", mixiaowoCode: "261"),
        BeadColor(colorHex: "F4F57D", mardCode: "A22", cocoCode: "E11", manmanCode: "R06", panpanCode: "270", mixiaowoCode: "255"),
        BeadColor(colorHex: "E6C9B7", mardCode: "A23", cocoCode: "E12", manmanCode: "R08", panpanCode: "274", mixiaowoCode: "259"),
        BeadColor(colorHex: "F7F8A2", mardCode: "A24", cocoCode: "E13", manmanCode: "G3", panpanCode: "288", mixiaowoCode: "273"),
        BeadColor(colorHex: "FFD67D", mardCode: "A25", cocoCode: "E14", manmanCode: "G4", panpanCode: "289", mixiaowoCode: "274"),
        BeadColor(colorHex: "FFC830", mardCode: "A26", cocoCode: "E15", manmanCode: "G5", panpanCode: "290", mixiaowoCode: "275"),
        // B系列
        BeadColor(colorHex: "E6EE31", mardCode: "B1", cocoCode: "F05", manmanCode: "C1", panpanCode: "48", mixiaowoCode: "48"),
        BeadColor(colorHex: "63F347", mardCode: "B2", cocoCode: "F08", manmanCode: "C2", panpanCode: "33", mixiaowoCode: "33"),
        BeadColor(colorHex: "9EF780", mardCode: "B3", cocoCode: "F04", manmanCode: "C7", panpanCode: "26", mixiaowoCode: "26"),
        BeadColor(colorHex: "5DE035", mardCode: "B4", cocoCode: "F09", manmanCode: "C3", panpanCode: "66", mixiaowoCode: "78"),
        BeadColor(colorHex: "35E352", mardCode: "B5", cocoCode: "F10", manmanCode: "C4", panpanCode: "39", mixiaowoCode: "39"),
        BeadColor(colorHex: "65E2A6", mardCode: "B6", cocoCode: "G04", manmanCode: "C9", panpanCode: "11", mixiaowoCode: "11"),
        BeadColor(colorHex: "3DAF80", mardCode: "B7", cocoCode: "G05", manmanCode: "C10", panpanCode: "44", mixiaowoCode: "44"),
        BeadColor(colorHex: "1C9C4F", mardCode: "B8", cocoCode: "F11", manmanCode: "C5", panpanCode: "10", mixiaowoCode: "10"),
        BeadColor(colorHex: "27523A", mardCode: "B9", cocoCode: "F16", manmanCode: "C6", panpanCode: "79", mixiaowoCode: "84"),
        BeadColor(colorHex: "95D3C2", mardCode: "B10", cocoCode: "G03", manmanCode: "C11", panpanCode: "96", mixiaowoCode: "100"),
        BeadColor(colorHex: "5D722A", mardCode: "B11", cocoCode: "F14", manmanCode: "C12", panpanCode: "97", mixiaowoCode: "99"),
        BeadColor(colorHex: "166F41", mardCode: "B12", cocoCode: "F12", manmanCode: "C13", panpanCode: "106", mixiaowoCode: "111"),
        BeadColor(colorHex: "CAEB7B", mardCode: "B13", cocoCode: "F02", manmanCode: "C14", panpanCode: "128", mixiaowoCode: "119"),
        BeadColor(colorHex: "ADE946", mardCode: "B14", cocoCode: "F06", manmanCode: "C15", panpanCode: "129", mixiaowoCode: "117"),
        BeadColor(colorHex: "2E5132", mardCode: "B15", cocoCode: "F15", manmanCode: "C16", panpanCode: "130", mixiaowoCode: "122"),
        BeadColor(colorHex: "C5ED9C", mardCode: "B16", cocoCode: "F03", manmanCode: "C17", panpanCode: "141", mixiaowoCode: "133"),
        BeadColor(colorHex: "9BB13A", mardCode: "B17", cocoCode: "F13", manmanCode: "C18", panpanCode: "142", mixiaowoCode: "141"),
        BeadColor(colorHex: "E6EE49", mardCode: "B18", cocoCode: "F07", manmanCode: "C19", panpanCode: "147", mixiaowoCode: "147"),
        BeadColor(colorHex: "24B88C", mardCode: "B19", cocoCode: "G06", manmanCode: "DH15", panpanCode: "191", mixiaowoCode: "174"),
        BeadColor(colorHex: "C2F0CC", mardCode: "B20", cocoCode: "G02", manmanCode: "DH10", panpanCode: "192", mixiaowoCode: "175"),
        BeadColor(colorHex: "156A6B", mardCode: "B21", cocoCode: "G07", manmanCode: "DH2", panpanCode: "207", mixiaowoCode: "194"),
        BeadColor(colorHex: "0B3C43", mardCode: "B22", cocoCode: "G08", manmanCode: "DH7", panpanCode: "206", mixiaowoCode: "193"),
        BeadColor(colorHex: "303A21", mardCode: "B23", cocoCode: "F17", manmanCode: "DH12", panpanCode: "205", mixiaowoCode: "192"),
        BeadColor(colorHex: "EEFCA5", mardCode: "B24", cocoCode: "F01", manmanCode: "IC5", panpanCode: "222", mixiaowoCode: "207"),
        BeadColor(colorHex: "4E846D", mardCode: "B25", cocoCode: "F18", manmanCode: "Q13", panpanCode: "240", mixiaowoCode: "240"),
        BeadColor(colorHex: "8D7A35", mardCode: "B26", cocoCode: "F19", manmanCode: "Q7", panpanCode: "248", mixiaowoCode: "248"),
        BeadColor(colorHex: "CCE1AF", mardCode: "B27", cocoCode: "F20", manmanCode: "R10", panpanCode: "262", mixiaowoCode: "262"),
        BeadColor(colorHex: "9EE5B9", mardCode: "B28", cocoCode: "F21", manmanCode: "R11", panpanCode: "269", mixiaowoCode: "254"),
        BeadColor(colorHex: "C5E254", mardCode: "B29", cocoCode: "F22", manmanCode: "R09", panpanCode: "268", mixiaowoCode: "253"),
        BeadColor(colorHex: "E2FCB1", mardCode: "B30", cocoCode: "F23", manmanCode: "G6", panpanCode: "285", mixiaowoCode: "270"),
        BeadColor(colorHex: "B0E792", mardCode: "B31", cocoCode: "F24", manmanCode: "G7", panpanCode: "286", mixiaowoCode: "271"),
        BeadColor(colorHex: "9CAB5A", mardCode: "B32", cocoCode: "F25", manmanCode: "G12", panpanCode: "287", mixiaowoCode: "272"),
        // C系列
        BeadColor(colorHex: "E8FFE7", mardCode: "C1", cocoCode: "G01", manmanCode: "C8", panpanCode: "64", mixiaowoCode: "76"),
        BeadColor(colorHex: "A9F9FC", mardCode: "C2", cocoCode: "H03", manmanCode: "D1", panpanCode: "30", mixiaowoCode: "30"),
        BeadColor(colorHex: "A0E2FB", mardCode: "C3", cocoCode: "H04", manmanCode: "D2", panpanCode: "63", mixiaowoCode: "75"),
        BeadColor(colorHex: "41CCFF", mardCode: "C4", cocoCode: "H05", manmanCode: "D3", panpanCode: "77", mixiaowoCode: "82"),
        BeadColor(colorHex: "01ACEB", mardCode: "C5", cocoCode: "H07", manmanCode: "D7", panpanCode: "34", mixiaowoCode: "34"),
        BeadColor(colorHex: "50AAF0", mardCode: "C6", cocoCode: "H08", manmanCode: "D4", panpanCode: "25", mixiaowoCode: "25"),
        BeadColor(colorHex: "3677D2", mardCode: "C7", cocoCode: "H13", manmanCode: "D8", panpanCode: "9", mixiaowoCode: "9"),
        BeadColor(colorHex: "0F54C0", mardCode: "C8", cocoCode: "H14", manmanCode: "D9", panpanCode: "52", mixiaowoCode: "71"),
        BeadColor(colorHex: "324BCA", mardCode: "C9", cocoCode: "H16", manmanCode: "N5", panpanCode: "42", mixiaowoCode: "42"),
        BeadColor(colorHex: "3EBCE2", mardCode: "C10", cocoCode: "H09", manmanCode: "D25", panpanCode: "121", mixiaowoCode: "130"),
        BeadColor(colorHex: "28DDDE", mardCode: "C11", cocoCode: "H10", manmanCode: "D28", panpanCode: "122", mixiaowoCode: "113"),
        BeadColor(colorHex: "1C334D", mardCode: "C12", cocoCode: "H23", manmanCode: "D26", panpanCode: "120", mixiaowoCode: "120"),
        BeadColor(colorHex: "CDE8FF", mardCode: "C13", cocoCode: "H01", manmanCode: "D30", panpanCode: "140", mixiaowoCode: "142"),
        BeadColor(colorHex: "D5FDFF", mardCode: "C14", cocoCode: "H02", manmanCode: "D29", panpanCode: "139", mixiaowoCode: "136"),
        BeadColor(colorHex: "22C4C6", mardCode: "C15", cocoCode: "H11", manmanCode: "D31", panpanCode: "143", mixiaowoCode: "132"),
        BeadColor(colorHex: "1557A8", mardCode: "C16", cocoCode: "H18", manmanCode: "D32", panpanCode: "149", mixiaowoCode: "149"),
        BeadColor(colorHex: "04D1F6", mardCode: "C17", cocoCode: "H19", manmanCode: "D36", panpanCode: "163", mixiaowoCode: "156"),
        BeadColor(colorHex: "1D3344", mardCode: "C18", cocoCode: "H24", manmanCode: "DH6", panpanCode: "196", mixiaowoCode: "196"),
        BeadColor(colorHex: "7F9698", mardCode: "C19", cocoCode: "H12", manmanCode: "DH9", panpanCode: "202", mixiaowoCode: "202"),
        BeadColor(colorHex: "176DAF", mardCode: "C20", cocoCode: "H17", manmanCode: "DH14", panpanCode: "197", mixiaowoCode: "197"),
        BeadColor(colorHex: "BEDDFF", mardCode: "C21", cocoCode: "H06", manmanCode: "IC3", panpanCode: "212", mixiaowoCode: "212"),
        BeadColor(colorHex: "67B4BE", mardCode: "C22", cocoCode: "H25", manmanCode: "Q11", panpanCode: "239", mixiaowoCode: "239"),
        BeadColor(colorHex: "C8E2FF", mardCode: "C23", cocoCode: "H26", manmanCode: "R13", panpanCode: "263", mixiaowoCode: "263"),
        BeadColor(colorHex: "7CC4FF", mardCode: "C24", cocoCode: "H27", manmanCode: "R14", panpanCode: "267", mixiaowoCode: "252"),
        BeadColor(colorHex: "A9E5E5", mardCode: "C25", cocoCode: "H28", manmanCode: "R12", panpanCode: "271", mixiaowoCode: "256"),
        BeadColor(colorHex: "3CAED8", mardCode: "C26", cocoCode: "H29", manmanCode: "R15", panpanCode: "265", mixiaowoCode: "250"),
        BeadColor(colorHex: "D3DFFA", mardCode: "C27", cocoCode: "H30", manmanCode: "G13", panpanCode: "279", mixiaowoCode: "264"),
        BeadColor(colorHex: "BBCFED", mardCode: "C28", cocoCode: "H31", manmanCode: "G14", panpanCode: "280", mixiaowoCode: "265"),
        BeadColor(colorHex: "34488E", mardCode: "C29", cocoCode: "H32", manmanCode: "G15", panpanCode: "281", mixiaowoCode: "266"),
        // D系列
        BeadColor(colorHex: "AEB4F2", mardCode: "D1", cocoCode: "J07", manmanCode: "D5", panpanCode: "46", mixiaowoCode: "46"),
        BeadColor(colorHex: "858EDD", mardCode: "D2", cocoCode: "J08", manmanCode: "D6", panpanCode: "36", mixiaowoCode: "36"),
        BeadColor(colorHex: "2F54AF", mardCode: "D3", cocoCode: "H15", manmanCode: "D10", panpanCode: "8", mixiaowoCode: "8"),
        BeadColor(colorHex: "182A84", mardCode: "D4", cocoCode: "H20", manmanCode: "D11", panpanCode: "75", mixiaowoCode: "80"),
        BeadColor(colorHex: "B843C5", mardCode: "D5", cocoCode: "J12", manmanCode: "D13", panpanCode: "32", mixiaowoCode: "32"),
        BeadColor(colorHex: "AC7BDE", mardCode: "D6", cocoCode: "J11", manmanCode: "D14", panpanCode: "27", mixiaowoCode: "27"),
        BeadColor(colorHex: "8854B3", mardCode: "D7", cocoCode: "J15", manmanCode: "D12", panpanCode: "7", mixiaowoCode: "7"),
        BeadColor(colorHex: "E2D3FF", mardCode: "D8", cocoCode: "J03", manmanCode: "D16", panpanCode: "94", mixiaowoCode: "89"),
        BeadColor(colorHex: "D5B9F8", mardCode: "D9", cocoCode: "J04", manmanCode: "D17", panpanCode: "93", mixiaowoCode: "90"),
        BeadColor(colorHex: "361B51", mardCode: "D10", cocoCode: "J19", manmanCode: "D15", panpanCode: "92", mixiaowoCode: "91"),
        BeadColor(colorHex: "B9BAE1", mardCode: "D11", cocoCode: "J06", manmanCode: "D19", panpanCode: "105", mixiaowoCode: "104"),
        BeadColor(colorHex: "DE9AD4", mardCode: "D12", cocoCode: "J10", manmanCode: "D20", panpanCode: "104", mixiaowoCode: "105"),
        BeadColor(colorHex: "B90095", mardCode: "D13", cocoCode: "J14", manmanCode: "D21", panpanCode: "103", mixiaowoCode: "106"),
        BeadColor(colorHex: "8B279B", mardCode: "D14", cocoCode: "J16", manmanCode: "D22", panpanCode: "102", mixiaowoCode: "107"),
        BeadColor(colorHex: "2F1F90", mardCode: "D15", cocoCode: "H22", manmanCode: "D18", panpanCode: "101", mixiaowoCode: "108"),
        BeadColor(colorHex: "E3E1EE", mardCode: "D16", cocoCode: "J01", manmanCode: "D23", panpanCode: "118", mixiaowoCode: "126"),
        BeadColor(colorHex: "C4D4F6", mardCode: "D17", cocoCode: "J05", manmanCode: "D24", panpanCode: "119", mixiaowoCode: "128"),
        BeadColor(colorHex: "A45EC7", mardCode: "D18", cocoCode: "J13", manmanCode: "D27", panpanCode: "124", mixiaowoCode: "125"),
        BeadColor(colorHex: "D8C3D7", mardCode: "D19", cocoCode: "J09", manmanCode: "D33", panpanCode: "153", mixiaowoCode: "153"),
        BeadColor(colorHex: "9C32B2", mardCode: "D20", cocoCode: "J17", manmanCode: "D34", panpanCode: "161", mixiaowoCode: "155"),
        BeadColor(colorHex: "9A009B", mardCode: "D21", cocoCode: "J18", manmanCode: "D35", panpanCode: "162", mixiaowoCode: "158"),
        BeadColor(colorHex: "333A95", mardCode: "D22", cocoCode: "H21", manmanCode: "DH1", panpanCode: "198", mixiaowoCode: "198"),
        BeadColor(colorHex: "EBDAFC", mardCode: "D23", cocoCode: "J02", manmanCode: "IC8", panpanCode: "217", mixiaowoCode: "217"),
        BeadColor(colorHex: "7786E5", mardCode: "D24", cocoCode: "J20", manmanCode: "Q14", panpanCode: "244", mixiaowoCode: "244"),
        BeadColor(colorHex: "494FC7", mardCode: "D25", cocoCode: "J21", manmanCode: "Q15", panpanCode: "249", mixiaowoCode: "234"),
        BeadColor(colorHex: "DFC2F8", mardCode: "D26", cocoCode: "J22", manmanCode: "R01", panpanCode: "273", mixiaowoCode: "258"),
        // E系列
        BeadColor(colorHex: "FDD3CC", mardCode: "E1", cocoCode: "K03", manmanCode: "E1", panpanCode: "18", mixiaowoCode: "18"),
        BeadColor(colorHex: "FEC0DF", mardCode: "E2", cocoCode: "K15", manmanCode: "A7", panpanCode: "38", mixiaowoCode: "38"),
        BeadColor(colorHex: "FFB7E7", mardCode: "E3", cocoCode: "K17", manmanCode: "A8", panpanCode: "62", mixiaowoCode: "74"),
        BeadColor(colorHex: "E8649E", mardCode: "E4", cocoCode: "K21", manmanCode: "A9", panpanCode: "6", mixiaowoCode: "6"),
        BeadColor(colorHex: "F551A2", mardCode: "E5", cocoCode: "K19", manmanCode: "A10", panpanCode: "40", mixiaowoCode: "40"),
        BeadColor(colorHex: "F13D74", mardCode: "E6", cocoCode: "K22", manmanCode: "A11", panpanCode: "20", mixiaowoCode: "20"),
        BeadColor(colorHex: "C63478", mardCode: "E7", cocoCode: "K25", manmanCode: "A12", panpanCode: "41", mixiaowoCode: "41"),
        BeadColor(colorHex: "FFDBE9", mardCode: "E8", cocoCode: "K12", manmanCode: "A13", panpanCode: "84", mixiaowoCode: "103"),
        BeadColor(colorHex: "E970CC", mardCode: "E9", cocoCode: "K18", manmanCode: "A14", panpanCode: "98", mixiaowoCode: "95"),
        BeadColor(colorHex: "D33793", mardCode: "E10", cocoCode: "K23", manmanCode: "A16", panpanCode: "83", mixiaowoCode: "94"),
        BeadColor(colorHex: "FCDDD2", mardCode: "E11", cocoCode: "K02", manmanCode: "A19", panpanCode: "125", mixiaowoCode: "131"),
        BeadColor(colorHex: "F78FC3", mardCode: "E12", cocoCode: "K16", manmanCode: "A20", panpanCode: "126", mixiaowoCode: "112"),
        BeadColor(colorHex: "B5006D", mardCode: "E13", cocoCode: "K24", manmanCode: "A21", panpanCode: "127", mixiaowoCode: "124"),
        BeadColor(colorHex: "FFD1BA", mardCode: "E14", cocoCode: "K05", manmanCode: "E21", panpanCode: "137", mixiaowoCode: "140"),
        BeadColor(colorHex: "F8C7C9", mardCode: "E15", cocoCode: "K04", manmanCode: "A23", panpanCode: "135", mixiaowoCode: "139"),
        BeadColor(colorHex: "FFF3EB", mardCode: "E16", cocoCode: "K01", manmanCode: "IC2", panpanCode: "221", mixiaowoCode: "206"),
        BeadColor(colorHex: "FFE2EA", mardCode: "E17", cocoCode: "K11", manmanCode: "IC7", panpanCode: "220", mixiaowoCode: "205"),
        BeadColor(colorHex: "FFC7DB", mardCode: "E18", cocoCode: "K13", manmanCode: "IC13", panpanCode: "210", mixiaowoCode: "210"),
        BeadColor(colorHex: "FEBAD5", mardCode: "E19", cocoCode: "K14", manmanCode: "IC12", panpanCode: "215", mixiaowoCode: "215"),
        BeadColor(colorHex: "D8C7D1", mardCode: "E20", cocoCode: "K26", manmanCode: "Q1", panpanCode: "241", mixiaowoCode: "241"),
        BeadColor(colorHex: "BD9DA1", mardCode: "E21", cocoCode: "K27", manmanCode: "Q2", panpanCode: "253", mixiaowoCode: "238"),
        BeadColor(colorHex: "B785A1", mardCode: "E22", cocoCode: "K28", manmanCode: "Q4", panpanCode: "252", mixiaowoCode: "237"),
        BeadColor(colorHex: "937A8D", mardCode: "E23", cocoCode: "K29", manmanCode: "Q3", panpanCode: "250", mixiaowoCode: "235"),
        BeadColor(colorHex: "E1BCE8", mardCode: "E24", cocoCode: "K30", manmanCode: "G8", panpanCode: "282", mixiaowoCode: "267"),
        // F系列
        BeadColor(colorHex: "FD957B", mardCode: "F1", cocoCode: "K08", manmanCode: "A1", panpanCode: "35", mixiaowoCode: "35"),
        BeadColor(colorHex: "FC3D46", mardCode: "F2", cocoCode: "C02", manmanCode: "A2", panpanCode: "31", mixiaowoCode: "31"),
        BeadColor(colorHex: "F74941", mardCode: "F3", cocoCode: "C03", manmanCode: "A3", panpanCode: "53", mixiaowoCode: "72"),
        BeadColor(colorHex: "FC283C", mardCode: "F4", cocoCode: "C06", manmanCode: "A4", panpanCode: "54", mixiaowoCode: "73"),
        BeadColor(colorHex: "E7002F", mardCode: "F5", cocoCode: "C07", manmanCode: "A5", panpanCode: "5", mixiaowoCode: "5"),
        BeadColor(colorHex: "943630", mardCode: "F6", cocoCode: "Z21", manmanCode: "E9", panpanCode: "16", mixiaowoCode: "16"),
        BeadColor(colorHex: "971937", mardCode: "F7", cocoCode: "C10", manmanCode: "A6", panpanCode: "47", mixiaowoCode: "47"),
        BeadColor(colorHex: "BC0028", mardCode: "F8", cocoCode: "C09", manmanCode: "A17", panpanCode: "81", mixiaowoCode: "92"),
        BeadColor(colorHex: "E2677A", mardCode: "F9", cocoCode: "K20", manmanCode: "A15", panpanCode: "82", mixiaowoCode: "93"),
        BeadColor(colorHex: "8A4526", mardCode: "F10", cocoCode: "Z20", manmanCode: "E15", panpanCode: "116", mixiaowoCode: "115"),
        BeadColor(colorHex: "5A2121", mardCode: "F11", cocoCode: "Z23", manmanCode: "E16", panpanCode: "117", mixiaowoCode: "129"),
        BeadColor(colorHex: "FD4E6A", mardCode: "F12", cocoCode: "C01", manmanCode: "A22", panpanCode: "136", mixiaowoCode: "134"),
        BeadColor(colorHex: "F35744", mardCode: "F13", cocoCode: "C04", manmanCode: "A24", panpanCode: "148", mixiaowoCode: "148"),
        BeadColor(colorHex: "FFA9AD", mardCode: "F14", cocoCode: "K07", manmanCode: "A25", panpanCode: "154", mixiaowoCode: "154"),
        BeadColor(colorHex: "D30022", mardCode: "F15", cocoCode: "C08", manmanCode: "DH8", panpanCode: "204", mixiaowoCode: "191"),
        BeadColor(colorHex: "FEC2A6", mardCode: "F16", cocoCode: "K06", manmanCode: "IC10", panpanCode: "211", mixiaowoCode: "211"),
        BeadColor(colorHex: "E69C79", mardCode: "F17", cocoCode: "K31", manmanCode: "Q9", panpanCode: "245", mixiaowoCode: "245"),
        BeadColor(colorHex: "D37C46", mardCode: "F18", cocoCode: "K32", manmanCode: "Q10", panpanCode: "246", mixiaowoCode: "246"),
        BeadColor(colorHex: "C1444A", mardCode: "F19", cocoCode: "K33", manmanCode: "Q05", panpanCode: "243", mixiaowoCode: "243"),
        BeadColor(colorHex: "CD9391", mardCode: "F20", cocoCode: "K34", manmanCode: "R04", panpanCode: "275", mixiaowoCode: "260"),
        BeadColor(colorHex: "F7B4C6", mardCode: "F21", cocoCode: "K35", manmanCode: "R03", panpanCode: "266", mixiaowoCode: "251"),
        BeadColor(colorHex: "FDC0D0", mardCode: "F22", cocoCode: "K36", manmanCode: "R02", panpanCode: "272", mixiaowoCode: "257"),
        BeadColor(colorHex: "F67E66", mardCode: "F23", cocoCode: "K37", manmanCode: "R05", panpanCode: "264", mixiaowoCode: "249"),
        BeadColor(colorHex: "E698AA", mardCode: "F24", cocoCode: "K38", manmanCode: "G9", panpanCode: "283", mixiaowoCode: "268"),
        BeadColor(colorHex: "E54B4F", mardCode: "F25", cocoCode: "K39", manmanCode: "G10", panpanCode: "284", mixiaowoCode: "269"),
        // G系列
        BeadColor(colorHex: "FFE2CE", mardCode: "G1", cocoCode: "Z02", manmanCode: "E3", panpanCode: "76", mixiaowoCode: "81"),
        BeadColor(colorHex: "FFC4AA", mardCode: "G2", cocoCode: "Z05", manmanCode: "E4", panpanCode: "49", mixiaowoCode: "49"),
        BeadColor(colorHex: "F4C3A5", mardCode: "G3", cocoCode: "Z06", manmanCode: "E5", panpanCode: "80", mixiaowoCode: "85"),
        BeadColor(colorHex: "E1B383", mardCode: "G4", cocoCode: "Z08", manmanCode: "E6", panpanCode: "19", mixiaowoCode: "19"),
        BeadColor(colorHex: "EDB045", mardCode: "G5", cocoCode: "Z10", manmanCode: "B7", panpanCode: "43", mixiaowoCode: "43"),
        BeadColor(colorHex: "E99C17", mardCode: "G6", cocoCode: "Z11", manmanCode: "B8", panpanCode: "50", mixiaowoCode: "50"),
        BeadColor(colorHex: "9D5B3E", mardCode: "G7", cocoCode: "Z18", manmanCode: "E7", panpanCode: "17", mixiaowoCode: "17"),
        BeadColor(colorHex: "753B32", mardCode: "G8", cocoCode: "Z22", manmanCode: "E8", panpanCode: "12", mixiaowoCode: "12"),
        BeadColor(colorHex: "E6B483", mardCode: "G9", cocoCode: "Z09", manmanCode: "E10", panpanCode: "91", mixiaowoCode: "102"),
        BeadColor(colorHex: "D98C39", mardCode: "G10", cocoCode: "Z15", manmanCode: "B9", panpanCode: "87", mixiaowoCode: "101"),
        BeadColor(colorHex: "E0C593", mardCode: "G11", cocoCode: "Z07", manmanCode: "E12", panpanCode: "112", mixiaowoCode: "118"),
        BeadColor(colorHex: "FFC890", mardCode: "G12", cocoCode: "Z13", manmanCode: "E13", panpanCode: "113", mixiaowoCode: "127"),
        BeadColor(colorHex: "B7714A", mardCode: "G13", cocoCode: "Z14", manmanCode: "E17", panpanCode: "115", mixiaowoCode: "114"),
        BeadColor(colorHex: "8D614C", mardCode: "G14", cocoCode: "Z17", manmanCode: "E14", panpanCode: "114", mixiaowoCode: "123"),
        BeadColor(colorHex: "FCF9E0", mardCode: "G15", cocoCode: "Z03", manmanCode: "E19", panpanCode: "133", mixiaowoCode: "143"),
        BeadColor(colorHex: "F2D9BA", mardCode: "G16", cocoCode: "Z04", manmanCode: "E20", panpanCode: "134", mixiaowoCode: "138"),
        BeadColor(colorHex: "7B524B", mardCode: "G17", cocoCode: "Z16", manmanCode: "E22", panpanCode: "144", mixiaowoCode: "137"),
        BeadColor(colorHex: "FFE4CC", mardCode: "G18", cocoCode: "Z01", manmanCode: "DH5", panpanCode: "203", mixiaowoCode: "203"),
        BeadColor(colorHex: "E07935", mardCode: "G19", cocoCode: "Z12", manmanCode: "DH3", panpanCode: "208", mixiaowoCode: "195"),
        BeadColor(colorHex: "A94023", mardCode: "G20", cocoCode: "Z19", manmanCode: "DH13", panpanCode: "199", mixiaowoCode: "199"),
        BeadColor(colorHex: "B88558", mardCode: "G21", cocoCode: "Z24", manmanCode: "Q8", panpanCode: "247", mixiaowoCode: "247"),
        // H系列
        BeadColor(colorHex: "FDFBFF", mardCode: "H1", cocoCode: "A02", manmanCode: "F1", panpanCode: "15", mixiaowoCode: "15"),
        BeadColor(colorHex: "FEFFFF", mardCode: "H2", cocoCode: "A01", manmanCode: "F2", panpanCode: "1", mixiaowoCode: "1"),
        BeadColor(colorHex: "B6B1BA", mardCode: "H3", cocoCode: "B03", manmanCode: "F3", panpanCode: "13", mixiaowoCode: "13"),
        BeadColor(colorHex: "89858C", mardCode: "H4", cocoCode: "B05", manmanCode: "F4", panpanCode: "78", mixiaowoCode: "83"),
        BeadColor(colorHex: "48464E", mardCode: "H5", cocoCode: "B06", manmanCode: "F5", panpanCode: "45", mixiaowoCode: "45"),
        BeadColor(colorHex: "2F2B2F", mardCode: "H6", cocoCode: "B07", manmanCode: "F6", panpanCode: "51", mixiaowoCode: "70"),
        BeadColor(colorHex: "000000", mardCode: "H7", cocoCode: "B09", manmanCode: "F7", panpanCode: "14", mixiaowoCode: "14"),
        BeadColor(colorHex: "E7D6DB", mardCode: "H8", cocoCode: "A09", manmanCode: "F8", panpanCode: "85", mixiaowoCode: "86"),
        BeadColor(colorHex: "EDEDED", mardCode: "H9", cocoCode: "A08", manmanCode: "F10", panpanCode: "95", mixiaowoCode: "87"),
        BeadColor(colorHex: "EEE9EA", mardCode: "H10", cocoCode: "A10", manmanCode: "F9", panpanCode: "86", mixiaowoCode: "88"),
        BeadColor(colorHex: "CECDD5", mardCode: "H11", cocoCode: "B01", manmanCode: "F11", panpanCode: "123", mixiaowoCode: "121"),
        BeadColor(colorHex: "FFF5ED", mardCode: "H12", cocoCode: "A04", manmanCode: "E18", panpanCode: "132", mixiaowoCode: "144"),
        BeadColor(colorHex: "F5ECD2", mardCode: "H13", cocoCode: "A06", manmanCode: "E23", panpanCode: "145", mixiaowoCode: "146"),
        BeadColor(colorHex: "CFD7D3", mardCode: "H14", cocoCode: "B02", manmanCode: "F12", panpanCode: "146", mixiaowoCode: "145"),
        BeadColor(colorHex: "98A6A8", mardCode: "H15", cocoCode: "B04", manmanCode: "DH4", panpanCode: "201", mixiaowoCode: "201"),
        BeadColor(colorHex: "1D1414", mardCode: "H16", cocoCode: "B08", manmanCode: "DH11", panpanCode: "200", mixiaowoCode: "200"),
        BeadColor(colorHex: "F1EDED", mardCode: "H17", cocoCode: "A07", manmanCode: "IC6", panpanCode: "214", mixiaowoCode: "214"),
        BeadColor(colorHex: "FFFDF0", mardCode: "H18", cocoCode: "A03", manmanCode: "IC1", panpanCode: "219", mixiaowoCode: "204"),
        BeadColor(colorHex: "F6EFE2", mardCode: "H19", cocoCode: "A05", manmanCode: "IC11", panpanCode: "209", mixiaowoCode: "209"),
        BeadColor(colorHex: "949FA3", mardCode: "H20", cocoCode: "B10", manmanCode: "Q12", panpanCode: "251", mixiaowoCode: "236"),
        BeadColor(colorHex: "FFFBE1", mardCode: "H21", cocoCode: "A11", manmanCode: "G1", panpanCode: "291", mixiaowoCode: "276"),
        BeadColor(colorHex: "CACAD4", mardCode: "H22", cocoCode: "A12", manmanCode: "G2", panpanCode: "277", mixiaowoCode: "277"),
        BeadColor(colorHex: "9A9D94", mardCode: "H23", cocoCode: "B11", manmanCode: "G11", panpanCode: "278", mixiaowoCode: "278"),
        // M系列
        BeadColor(colorHex: "BCC6B8", mardCode: "M1", cocoCode: "Y01", manmanCode: "YX11", panpanCode: "168", mixiaowoCode: "168"),
        BeadColor(colorHex: "8AA386", mardCode: "M2", cocoCode: "Y02", manmanCode: "YX12", panpanCode: "172", mixiaowoCode: "172"),
        BeadColor(colorHex: "697D80", mardCode: "M3", cocoCode: "Y03", manmanCode: "YX2", panpanCode: "166", mixiaowoCode: "166"),
        BeadColor(colorHex: "E3D2BC", mardCode: "M4", cocoCode: "Y04", manmanCode: "YX15", panpanCode: "167", mixiaowoCode: "167"),
        BeadColor(colorHex: "D0CCAA", mardCode: "M5", cocoCode: "Y05", manmanCode: "YX6", panpanCode: "174", mixiaowoCode: "159"),
        BeadColor(colorHex: "B0A782", mardCode: "M6", cocoCode: "Y06", manmanCode: "YX1", panpanCode: "169", mixiaowoCode: "169"),
        BeadColor(colorHex: "B4A497", mardCode: "M7", cocoCode: "Y07", manmanCode: "YX13", panpanCode: "171", mixiaowoCode: "171"),
        BeadColor(colorHex: "B38281", mardCode: "M8", cocoCode: "Y08", manmanCode: "YX14", panpanCode: "177", mixiaowoCode: "162"),
        BeadColor(colorHex: "A58767", mardCode: "M9", cocoCode: "Y09", manmanCode: "YX10", panpanCode: "170", mixiaowoCode: "170"),
        BeadColor(colorHex: "C5B2BC", mardCode: "M10", cocoCode: "Y10", manmanCode: "YX9", panpanCode: "164", mixiaowoCode: "164"),
        BeadColor(colorHex: "9F7594", mardCode: "M11", cocoCode: "Y11", manmanCode: "YX4", panpanCode: "176", mixiaowoCode: "161"),
        BeadColor(colorHex: "644749", mardCode: "M12", cocoCode: "Y12", manmanCode: "YX5", panpanCode: "173", mixiaowoCode: "173"),
        BeadColor(colorHex: "D19066", mardCode: "M13", cocoCode: "Y13", manmanCode: "YX8", panpanCode: "175", mixiaowoCode: "160"),
        BeadColor(colorHex: "C77362", mardCode: "M14", cocoCode: "Y14", manmanCode: "YX3", panpanCode: "165", mixiaowoCode: "165"),
        BeadColor(colorHex: "757D7B", mardCode: "M15", cocoCode: "Y15", manmanCode: "YX7", panpanCode: "178", mixiaowoCode: "163"),
        // P系列
        BeadColor(colorHex: "FCF7F8", mardCode: "P1", cocoCode: "M01", manmanCode: "P1", panpanCode: "71", mixiaowoCode: "62"),
        BeadColor(colorHex: "B0A9AC", mardCode: "P2", cocoCode: "M02", manmanCode: "P2", panpanCode: "55", mixiaowoCode: "69"),
        BeadColor(colorHex: "AFDCAB", mardCode: "P3", cocoCode: "M03", manmanCode: "P4", panpanCode: "73", mixiaowoCode: "66"),
        BeadColor(colorHex: "FEA49F", mardCode: "P4", cocoCode: "M04", manmanCode: "P5", panpanCode: "72", mixiaowoCode: "64"),
        BeadColor(colorHex: "EE8C3E", mardCode: "P5", cocoCode: "M05", manmanCode: "P3", panpanCode: "56", mixiaowoCode: "63"),
        BeadColor(colorHex: "5FD0A7", mardCode: "P6", cocoCode: "M06", manmanCode: "P8", panpanCode: "157", mixiaowoCode: "65"),
        BeadColor(colorHex: "EB9270", mardCode: "P7", cocoCode: "M07", manmanCode: "P6", panpanCode: "159", mixiaowoCode: "68"),
        BeadColor(colorHex: "F0D958", mardCode: "P8", cocoCode: "M08", manmanCode: "P7", panpanCode: "158", mixiaowoCode: "67"),
        BeadColor(colorHex: "D9D9D9", mardCode: "P9", cocoCode: "M09", manmanCode: "P13", panpanCode: "195", mixiaowoCode: "178"),
        BeadColor(colorHex: "D9C7EA", mardCode: "P10", cocoCode: "M10", manmanCode: "P18", panpanCode: "187", mixiaowoCode: "187"),
        BeadColor(colorHex: "F3ECC9", mardCode: "P11", cocoCode: "M11", manmanCode: "P9", panpanCode: "185", mixiaowoCode: "185"),
        BeadColor(colorHex: "E6EEF2", mardCode: "P12", cocoCode: "M12", manmanCode: "P12", panpanCode: "190", mixiaowoCode: "190"),
        BeadColor(colorHex: "AACBEF", mardCode: "P13", cocoCode: "M13", manmanCode: "P17", panpanCode: "193", mixiaowoCode: "176"),
        BeadColor(colorHex: "3376B0", mardCode: "P14", cocoCode: "M14", manmanCode: "P22", panpanCode: "183", mixiaowoCode: "183"),
        BeadColor(colorHex: "668575", mardCode: "P15", cocoCode: "M15", manmanCode: "P23", panpanCode: "184", mixiaowoCode: "184"),
        BeadColor(colorHex: "FEBF45", mardCode: "P16", cocoCode: "M16", manmanCode: "P14", panpanCode: "182", mixiaowoCode: "182"),
        BeadColor(colorHex: "FEA324", mardCode: "P17", cocoCode: "M17", manmanCode: "P19", panpanCode: "179", mixiaowoCode: "179"),
        BeadColor(colorHex: "FEB89F", mardCode: "P18", cocoCode: "M18", manmanCode: "P11", panpanCode: "194", mixiaowoCode: "177"),
        BeadColor(colorHex: "FFE0E9", mardCode: "P19", cocoCode: "M19", manmanCode: "P10", panpanCode: "186", mixiaowoCode: "186"),
        BeadColor(colorHex: "FEBECF", mardCode: "P20", cocoCode: "M21", manmanCode: "P15", panpanCode: "188", mixiaowoCode: "180"),
        BeadColor(colorHex: "ECBEBF", mardCode: "P21", cocoCode: "M20", manmanCode: "P20", panpanCode: "180", mixiaowoCode: "188"),
        BeadColor(colorHex: "E4A89F", mardCode: "P22", cocoCode: "M22", manmanCode: "P16", panpanCode: "189", mixiaowoCode: "189"),
        BeadColor(colorHex: "A56268", mardCode: "P23", cocoCode: "M23", manmanCode: "P21", panpanCode: "181", mixiaowoCode: "181"),
        // Q系列
        BeadColor(colorHex: "F2A5E8", mardCode: "Q1", cocoCode: "W3", manmanCode: "W3", panpanCode: "109", mixiaowoCode: "W3"),
        BeadColor(colorHex: "E9EC91", mardCode: "Q2", cocoCode: "W4", manmanCode: "W4", panpanCode: "111", mixiaowoCode: "W4"),
        BeadColor(colorHex: "FFFF00", mardCode: "Q3", cocoCode: "W1", manmanCode: "W1", panpanCode: "107", mixiaowoCode: "W1"),
        BeadColor(colorHex: "FFEBFA", mardCode: "Q4", cocoCode: "W2", manmanCode: "W2", panpanCode: "110", mixiaowoCode: "W2"),
        BeadColor(colorHex: "76CEDE", mardCode: "Q5", cocoCode: "W5", manmanCode: "W5", panpanCode: "108", mixiaowoCode: "W5"),
        // R系列
        BeadColor(colorHex: "D50D21", mardCode: "R1", cocoCode: "L01", manmanCode: "T1", panpanCode: "67", mixiaowoCode: "52"),
        BeadColor(colorHex: "F92F83", mardCode: "R2", cocoCode: "L02", manmanCode: "N1", panpanCode: "24", mixiaowoCode: "24"),
        BeadColor(colorHex: "FD8324", mardCode: "R3", cocoCode: "L03", manmanCode: "N2", panpanCode: "22", mixiaowoCode: "22"),
        BeadColor(colorHex: "F8EC31", mardCode: "R4", cocoCode: "L04", manmanCode: "N3", panpanCode: "21", mixiaowoCode: "21"),
        BeadColor(colorHex: "35C75B", mardCode: "R5", cocoCode: "L05", manmanCode: "N4", panpanCode: "23", mixiaowoCode: "23"),
        BeadColor(colorHex: "23B891", mardCode: "R6", cocoCode: "L06", manmanCode: "T4", panpanCode: "69", mixiaowoCode: "55"),
        BeadColor(colorHex: "19779D", mardCode: "R7", cocoCode: "L07", manmanCode: "T5", panpanCode: "37", mixiaowoCode: "37"),
        BeadColor(colorHex: "1A60C3", mardCode: "R8", cocoCode: "L08", manmanCode: "T3", panpanCode: "68", mixiaowoCode: "54"),
        BeadColor(colorHex: "9A56B4", mardCode: "R9", cocoCode: "L09", manmanCode: "T2", panpanCode: "70", mixiaowoCode: "56"),
        BeadColor(colorHex: "FFDB4C", mardCode: "R10", cocoCode: "L10", manmanCode: "L2", panpanCode: "156", mixiaowoCode: "53"),
        BeadColor(colorHex: "FFEBFA", mardCode: "R11", cocoCode: "L11", manmanCode: "T6", panpanCode: "151", mixiaowoCode: "151"),
        BeadColor(colorHex: "D8D5CE", mardCode: "R12", cocoCode: "L12", manmanCode: "T7", panpanCode: "160", mixiaowoCode: "157"),
        BeadColor(colorHex: "55514C", mardCode: "R13", cocoCode: "L13", manmanCode: "-", panpanCode: "152", mixiaowoCode: "152"),
        BeadColor(colorHex: "9FE4DF", mardCode: "R14", cocoCode: "S1", manmanCode: "S1", panpanCode: "231", mixiaowoCode: "231"),
        BeadColor(colorHex: "77CEE9", mardCode: "R15", cocoCode: "S2", manmanCode: "S2", panpanCode: "237", mixiaowoCode: "224"),
        BeadColor(colorHex: "3ECFCA", mardCode: "R16", cocoCode: "S3", manmanCode: "S3", panpanCode: "238", mixiaowoCode: "225"),
        BeadColor(colorHex: "4A867A", mardCode: "R17", cocoCode: "S4", manmanCode: "S5", panpanCode: "233", mixiaowoCode: "233"),
        BeadColor(colorHex: "7FCD9D", mardCode: "R18", cocoCode: "S5", manmanCode: "S4", panpanCode: "235", mixiaowoCode: "222"),
        BeadColor(colorHex: "CDE55D", mardCode: "R19", cocoCode: "S6", manmanCode: "S11", panpanCode: "227", mixiaowoCode: "227"),
        BeadColor(colorHex: "E8C7B4", mardCode: "R20", cocoCode: "S7", manmanCode: "S6", panpanCode: "230", mixiaowoCode: "230"),
        BeadColor(colorHex: "AD6F3C", mardCode: "R21", cocoCode: "S8", manmanCode: "S13", panpanCode: "234", mixiaowoCode: "221"),
        BeadColor(colorHex: "6C372F", mardCode: "R22", cocoCode: "S9", manmanCode: "S15", panpanCode: "226", mixiaowoCode: "226"),
        BeadColor(colorHex: "FEB872", mardCode: "R23", cocoCode: "S10", manmanCode: "S12", panpanCode: "224", mixiaowoCode: "219"),
        BeadColor(colorHex: "F3C1C0", mardCode: "R24", cocoCode: "S11", manmanCode: "S4", panpanCode: "228", mixiaowoCode: "228"),
        BeadColor(colorHex: "C9675E", mardCode: "R25", cocoCode: "S12", manmanCode: "S14", panpanCode: "225", mixiaowoCode: "220"),
        BeadColor(colorHex: "D293BE", mardCode: "R26", cocoCode: "S13", manmanCode: "S9", panpanCode: "229", mixiaowoCode: "229"),
        BeadColor(colorHex: "EA8CB1", mardCode: "R27", cocoCode: "S14", manmanCode: "S8", panpanCode: "232", mixiaowoCode: "232"),
        BeadColor(colorHex: "9C87D6", mardCode: "R28", cocoCode: "S15", manmanCode: "S10", panpanCode: "236", mixiaowoCode: "223"),
        // T系列
        BeadColor(colorHex: "FFFFFF", mardCode: "T1", cocoCode: "L14", manmanCode: "L6", panpanCode: "155", mixiaowoCode: "51"),
        // Y系列
        BeadColor(colorHex: "FD6FB4", mardCode: "Y1", cocoCode: "N01", manmanCode: "Y1", panpanCode: "59", mixiaowoCode: "59"),
        BeadColor(colorHex: "FEB481", mardCode: "Y2", cocoCode: "N02", manmanCode: "Y2", panpanCode: "60", mixiaowoCode: "60"),
        BeadColor(colorHex: "D7FAA0", mardCode: "Y3", cocoCode: "N03", manmanCode: "Y3", panpanCode: "57", mixiaowoCode: "57"),
        BeadColor(colorHex: "8BDBFA", mardCode: "Y4", cocoCode: "N04", manmanCode: "Y4", panpanCode: "58", mixiaowoCode: "58"),
        BeadColor(colorHex: "E987EA", mardCode: "Y5", cocoCode: "N05", manmanCode: "Y5", panpanCode: "61", mixiaowoCode: "61"),
        // ZG系列
        BeadColor(colorHex: "DAABB3", mardCode: "ZG1", cocoCode: "GB1", manmanCode: "ZG1", panpanCode: "254", mixiaowoCode: "ZG1"),
        BeadColor(colorHex: "D6AA87", mardCode: "ZG2", cocoCode: "GB2", manmanCode: "ZG2", panpanCode: "255", mixiaowoCode: "ZG2"),
        BeadColor(colorHex: "C1BD8D", mardCode: "ZG3", cocoCode: "GB3", manmanCode: "ZG3", panpanCode: "256", mixiaowoCode: "ZG3"),
        BeadColor(colorHex: "96B69F", mardCode: "ZG4", cocoCode: "GB4", manmanCode: "ZG4", panpanCode: "257", mixiaowoCode: "ZG4"),
        BeadColor(colorHex: "849DC6", mardCode: "ZG5", cocoCode: "GB5", manmanCode: "ZG5", panpanCode: "258", mixiaowoCode: "ZG5"),
        BeadColor(colorHex: "94BFE2", mardCode: "ZG6", cocoCode: "GB6", manmanCode: "ZG6", panpanCode: "259", mixiaowoCode: "ZG6"),
        BeadColor(colorHex: "E2A9D2", mardCode: "ZG7", cocoCode: "GB7", manmanCode: "ZG7", panpanCode: "260", mixiaowoCode: "ZG7"),
        BeadColor(colorHex: "AB91C0", mardCode: "ZG8", cocoCode: "GB8", manmanCode: "ZG8", panpanCode: "261", mixiaowoCode: "ZG8"),
    ]
}
