//
//  InventoryManager.swift
//  BeadInventory
//
//  库存管理器 - 处理数据持久化和业务逻辑
//

import Foundation
import SwiftUI

class InventoryManager: ObservableObject {
    @Published var beadColors: [BeadColor] = []
    @Published var projects: [ProjectRecord] = []

    // 品牌相关
    @Published var brands: [Brand] = []
    @Published var brandStocks: [BrandStock] = []
    @Published var currentBrandId: UUID?

    private let beadColorsKey = "beadColors"
    private let projectsKey = "projects"
    private let brandsKey = "brands"
    private let brandStocksKey = "brandStocks"
    private let currentBrandIdKey = "currentBrandId"

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

    init() {
        loadData()
        if beadColors.isEmpty {
            initializeDefaultColors()
        }
        // 数据迁移
        DataMigration.migrateIfNeeded(manager: self)
    }

    // MARK: - 品牌管理

    @discardableResult
    func addBrand(name: String) -> Brand {
        let maxOrder = brands.map { $0.sortOrder }.max() ?? -1
        let brand = Brand(
            name: name,
            sortOrder: maxOrder + 1
        )
        brands.append(brand)

        // 为新品牌初始化库存
        initializeStockForBrand(brand.id)

        // 如果没有当前品牌，设为当前品牌
        if currentBrandId == nil {
            currentBrandId = brand.id
        }

        saveData()
        return brand
    }

    func updateBrand(_ brand: Brand) {
        if let index = brands.firstIndex(where: { $0.id == brand.id }) {
            brands[index] = brand
            saveData()
        }
    }

    func deleteBrand(_ brandId: UUID) -> Bool {
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
            saveData()
        }
    }

    // MARK: - 品牌库存操作

    func initializeStockForBrand(_ brandId: UUID, defaultStock: Int = 1000) {
        for color in beadColors {
            let stock = BrandStock(
                brandId: brandId,
                mardCode: color.mardCode,
                stock: defaultStock,
                used: 0
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
            brandStocks[index].stock = max(0, newStock)
            saveData()
        }
    }

    func addStock(brandId: UUID, mardCode: String, amount: Int) {
        if let index = brandStocks.firstIndex(where: {
            $0.brandId == brandId && $0.mardCode == mardCode
        }) {
            brandStocks[index].stock += amount
            saveData()
        }
    }

    func deductFromStock(brandId: UUID, colorCode: String, amount: Int) -> Bool {
        // 先找到对应的 mardCode
        guard let color = findColor(byCode: colorCode) else { return false }

        if let index = brandStocks.firstIndex(where: {
            $0.brandId == brandId && $0.mardCode == color.mardCode
        }) {
            brandStocks[index].used += amount
            saveData()
            return true
        }
        return false
    }

    // MARK: - 品牌统计

    func totalStock(for brandId: UUID) -> Int {
        brandStocks.filter { $0.brandId == brandId }.reduce(0) { $0 + $1.stock }
    }

    func totalUsed(for brandId: UUID) -> Int {
        brandStocks.filter { $0.brandId == brandId }.reduce(0) { $0 + $1.used }
    }

    func totalAvailable(for brandId: UUID) -> Int {
        brandStocks.filter { $0.brandId == brandId }.reduce(0) { $0 + $1.available }
    }

    func lowStockColors(for brandId: UUID) -> [BrandStock] {
        brandStocks.filter { $0.brandId == brandId && $0.available < 100 }
    }

    // MARK: - 数据持久化

    func loadData() {
        // 加载颜色数据
        if let data = UserDefaults.standard.data(forKey: beadColorsKey),
           let colors = try? JSONDecoder().decode([BeadColor].self, from: data) {
            beadColors = colors
        }

        // 加载项目记录
        if let data = UserDefaults.standard.data(forKey: projectsKey),
           let records = try? JSONDecoder().decode([ProjectRecord].self, from: data) {
            projects = records
        }

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

        // 加载当前品牌
        if let idString = UserDefaults.standard.string(forKey: currentBrandIdKey),
           let id = UUID(uuidString: idString) {
            currentBrandId = id
        }
    }

    func saveData() {
        if let data = try? JSONEncoder().encode(beadColors) {
            UserDefaults.standard.set(data, forKey: beadColorsKey)
        }
        if let data = try? JSONEncoder().encode(projects) {
            UserDefaults.standard.set(data, forKey: projectsKey)
        }
        // 保存品牌
        if let data = try? JSONEncoder().encode(brands) {
            UserDefaults.standard.set(data, forKey: brandsKey)
        }
        // 保存品牌库存
        if let data = try? JSONEncoder().encode(brandStocks) {
            UserDefaults.standard.set(data, forKey: brandStocksKey)
        }
        // 保存当前品牌 ID
        if let id = currentBrandId {
            UserDefaults.standard.set(id.uuidString, forKey: currentBrandIdKey)
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
        return beadColors.first { color in
            color.mardCode.uppercased() == code ||
            color.vividCode.uppercased() == code ||
            color.manmanCode.uppercased() == code ||
            color.kakaCode.uppercased() == code
        }
    }

    func findColorIndex(byCode code: String) -> Int? {
        let code = code.uppercased().trimmingCharacters(in: .whitespaces)
        return beadColors.firstIndex { color in
            color.mardCode.uppercased() == code ||
            color.vividCode.uppercased() == code ||
            color.manmanCode.uppercased() == code ||
            color.kakaCode.uppercased() == code
        }
    }

    func searchColors(_ query: String) -> [BeadColor] {
        guard !query.isEmpty else { return beadColors }
        let query = query.uppercased()
        return beadColors.filter { color in
            color.mardCode.uppercased().contains(query) ||
            color.vividCode.uppercased().contains(query) ||
            color.manmanCode.uppercased().contains(query) ||
            color.kakaCode.uppercased().contains(query) ||
            color.colorName.uppercased().contains(query)
        }
    }

    // MARK: - 项目管理

    func addProject(_ project: ProjectRecord) {
        projects.insert(project, at: 0)
        saveData()
    }

    func deleteProject(at offsets: IndexSet) {
        projects.remove(atOffsets: offsets)
        saveData()
    }

    func applyProjectToInventory(_ project: ProjectRecord) {
        for usage in project.beadUsage where !usage.isDeducted {
            _ = deductFromStock(colorCode: usage.colorCode, amount: usage.quantity)
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
        // 清除当前品牌的所有库存记录
        brandStocks.removeAll { $0.brandId == brandId }
        // 为每个颜色创建新的库存记录
        for color in beadColors {
            let newStock = BrandStock(brandId: brandId, mardCode: color.mardCode, stock: amount, used: 0)
            brandStocks.append(newStock)
        }
        saveData()
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
        saveData()
    }
}

// MARK: - 默认颜色数据 (来自 color.json)
struct DefaultBeadColors {
    static let colors: [BeadColor] = [
        // A系列 - 黄橙色系
        BeadColor(colorHex: "FAF4C8", mardCode: "A1"),
        BeadColor(colorHex: "FFFFD5", mardCode: "A2"),
        BeadColor(colorHex: "FEFF8B", mardCode: "A3"),
        BeadColor(colorHex: "FBED56", mardCode: "A4"),
        BeadColor(colorHex: "F4D738", mardCode: "A5"),
        BeadColor(colorHex: "FEAC4C", mardCode: "A6"),
        BeadColor(colorHex: "FE8B4C", mardCode: "A7"),
        BeadColor(colorHex: "FFDA45", mardCode: "A8"),
        BeadColor(colorHex: "FF995B", mardCode: "A9"),
        BeadColor(colorHex: "F77C31", mardCode: "A10"),
        BeadColor(colorHex: "FFDD99", mardCode: "A11"),
        BeadColor(colorHex: "FE9F72", mardCode: "A12"),
        BeadColor(colorHex: "FFC365", mardCode: "A13"),
        BeadColor(colorHex: "FD543D", mardCode: "A14"),
        BeadColor(colorHex: "FFF365", mardCode: "A15"),
        BeadColor(colorHex: "FFFF9F", mardCode: "A16"),
        BeadColor(colorHex: "FFE36E", mardCode: "A17"),
        BeadColor(colorHex: "FEBE7D", mardCode: "A18"),
        BeadColor(colorHex: "FD7C72", mardCode: "A19"),
        BeadColor(colorHex: "FFD568", mardCode: "A20"),
        BeadColor(colorHex: "FFE395", mardCode: "A21"),
        BeadColor(colorHex: "F4F57D", mardCode: "A22"),
        BeadColor(colorHex: "E6C9B7", mardCode: "A23"),
        BeadColor(colorHex: "F7F8A2", mardCode: "A24"),
        BeadColor(colorHex: "FFD67D", mardCode: "A25"),
        BeadColor(colorHex: "FFC830", mardCode: "A26"),

        // B系列 - 绿色系
        BeadColor(colorHex: "E6EE31", mardCode: "B1"),
        BeadColor(colorHex: "63F347", mardCode: "B2"),
        BeadColor(colorHex: "9EF780", mardCode: "B3"),
        BeadColor(colorHex: "5DE035", mardCode: "B4"),
        BeadColor(colorHex: "35E352", mardCode: "B5"),
        BeadColor(colorHex: "65E2A6", mardCode: "B6"),
        BeadColor(colorHex: "3DAF80", mardCode: "B7"),
        BeadColor(colorHex: "1C9C4F", mardCode: "B8"),
        BeadColor(colorHex: "27523A", mardCode: "B9"),
        BeadColor(colorHex: "95D3C2", mardCode: "B10"),
        BeadColor(colorHex: "5D722A", mardCode: "B11"),
        BeadColor(colorHex: "166F41", mardCode: "B12"),
        BeadColor(colorHex: "CAEB7B", mardCode: "B13"),
        BeadColor(colorHex: "ADE946", mardCode: "B14"),
        BeadColor(colorHex: "2E5132", mardCode: "B15"),
        BeadColor(colorHex: "C5ED9C", mardCode: "B16"),
        BeadColor(colorHex: "9BB13A", mardCode: "B17"),
        BeadColor(colorHex: "E6EE49", mardCode: "B18"),
        BeadColor(colorHex: "24B88C", mardCode: "B19"),
        BeadColor(colorHex: "C2F0CC", mardCode: "B20"),
        BeadColor(colorHex: "156A6B", mardCode: "B21"),
        BeadColor(colorHex: "0B3C43", mardCode: "B22"),
        BeadColor(colorHex: "303A21", mardCode: "B23"),
        BeadColor(colorHex: "EEFCA5", mardCode: "B24"),
        BeadColor(colorHex: "4E846D", mardCode: "B25"),
        BeadColor(colorHex: "8D7A35", mardCode: "B26"),
        BeadColor(colorHex: "CCE1AF", mardCode: "B27"),
        BeadColor(colorHex: "9EE5B9", mardCode: "B28"),
        BeadColor(colorHex: "C5E254", mardCode: "B29"),
        BeadColor(colorHex: "E2FCB1", mardCode: "B30"),
        BeadColor(colorHex: "B0E792", mardCode: "B31"),
        BeadColor(colorHex: "9CAB5A", mardCode: "B32"),

        // C系列 - 蓝青色系
        BeadColor(colorHex: "E8FFE7", mardCode: "C1"),
        BeadColor(colorHex: "A9F9FC", mardCode: "C2"),
        BeadColor(colorHex: "A0E2FB", mardCode: "C3"),
        BeadColor(colorHex: "41CCFF", mardCode: "C4"),
        BeadColor(colorHex: "01ACEB", mardCode: "C5"),
        BeadColor(colorHex: "50AAF0", mardCode: "C6"),
        BeadColor(colorHex: "3677D2", mardCode: "C7"),
        BeadColor(colorHex: "0F54C0", mardCode: "C8"),
        BeadColor(colorHex: "324BCA", mardCode: "C9"),
        BeadColor(colorHex: "3EBCE2", mardCode: "C10"),
        BeadColor(colorHex: "28DDDE", mardCode: "C11"),
        BeadColor(colorHex: "1C334D", mardCode: "C12"),
        BeadColor(colorHex: "CDE8FF", mardCode: "C13"),
        BeadColor(colorHex: "D5FDFF", mardCode: "C14"),
        BeadColor(colorHex: "22C4C6", mardCode: "C15"),
        BeadColor(colorHex: "1557A8", mardCode: "C16"),
        BeadColor(colorHex: "04D1F6", mardCode: "C17"),
        BeadColor(colorHex: "1D3344", mardCode: "C18"),
        BeadColor(colorHex: "1887A2", mardCode: "C19"),
        BeadColor(colorHex: "176DAF", mardCode: "C20"),
        BeadColor(colorHex: "BEDDFF", mardCode: "C21"),
        BeadColor(colorHex: "67B4BE", mardCode: "C22"),
        BeadColor(colorHex: "C8E2FF", mardCode: "C23"),
        BeadColor(colorHex: "7CC4FF", mardCode: "C24"),
        BeadColor(colorHex: "A9E5E5", mardCode: "C25"),
        BeadColor(colorHex: "3CAED8", mardCode: "C26"),
        BeadColor(colorHex: "D3DFFA", mardCode: "C27"),
        BeadColor(colorHex: "BBCFED", mardCode: "C28"),
        BeadColor(colorHex: "34488E", mardCode: "C29"),

        // D系列 - 紫色系
        BeadColor(colorHex: "AEB4F2", mardCode: "D1"),
        BeadColor(colorHex: "858EDD", mardCode: "D2"),
        BeadColor(colorHex: "2F54AF", mardCode: "D3"),
        BeadColor(colorHex: "182A84", mardCode: "D4"),
        BeadColor(colorHex: "B843C5", mardCode: "D5"),
        BeadColor(colorHex: "AC7BDE", mardCode: "D6"),
        BeadColor(colorHex: "8854B3", mardCode: "D7"),
        BeadColor(colorHex: "E2D3FF", mardCode: "D8"),
        BeadColor(colorHex: "D5B9F8", mardCode: "D9"),
        BeadColor(colorHex: "361B51", mardCode: "D10"),
        BeadColor(colorHex: "B9BAE1", mardCode: "D11"),
        BeadColor(colorHex: "DE9AD4", mardCode: "D12"),
        BeadColor(colorHex: "B90095", mardCode: "D13"),
        BeadColor(colorHex: "8B279B", mardCode: "D14"),
        BeadColor(colorHex: "2F1F90", mardCode: "D15"),
        BeadColor(colorHex: "E3E1EE", mardCode: "D16"),
        BeadColor(colorHex: "C4D4F6", mardCode: "D17"),
        BeadColor(colorHex: "A45EC7", mardCode: "D18"),
        BeadColor(colorHex: "D8C3D7", mardCode: "D19"),
        BeadColor(colorHex: "9C32B2", mardCode: "D20"),
        BeadColor(colorHex: "9A009B", mardCode: "D21"),
        BeadColor(colorHex: "333A95", mardCode: "D22"),
        BeadColor(colorHex: "EBDAFC", mardCode: "D23"),
        BeadColor(colorHex: "7786E5", mardCode: "D24"),
        BeadColor(colorHex: "494FC7", mardCode: "D25"),
        BeadColor(colorHex: "DFC2F8", mardCode: "D26"),

        // E系列 - 粉色系
        BeadColor(colorHex: "FDD3CC", mardCode: "E1"),
        BeadColor(colorHex: "FEC0DF", mardCode: "E2"),
        BeadColor(colorHex: "FFB7E7", mardCode: "E3"),
        BeadColor(colorHex: "E8649E", mardCode: "E4"),
        BeadColor(colorHex: "F551A2", mardCode: "E5"),
        BeadColor(colorHex: "F13D74", mardCode: "E6"),
        BeadColor(colorHex: "C63478", mardCode: "E7"),
        BeadColor(colorHex: "FFDBE9", mardCode: "E8"),
        BeadColor(colorHex: "E970CC", mardCode: "E9"),
        BeadColor(colorHex: "D33793", mardCode: "E10"),
        BeadColor(colorHex: "FCDDD2", mardCode: "E11"),
        BeadColor(colorHex: "F78FC3", mardCode: "E12"),
        BeadColor(colorHex: "B5006D", mardCode: "E13"),
        BeadColor(colorHex: "FFD1BA", mardCode: "E14"),
        BeadColor(colorHex: "F8C7C9", mardCode: "E15"),
        BeadColor(colorHex: "FFF3EB", mardCode: "E16"),
        BeadColor(colorHex: "FFE2EA", mardCode: "E17"),
        BeadColor(colorHex: "FFC7DB", mardCode: "E18"),
        BeadColor(colorHex: "FEBAD5", mardCode: "E19"),
        BeadColor(colorHex: "D8C7D1", mardCode: "E20"),
        BeadColor(colorHex: "BD9DA1", mardCode: "E21"),
        BeadColor(colorHex: "B785A1", mardCode: "E22"),
        BeadColor(colorHex: "937A8D", mardCode: "E23"),
        BeadColor(colorHex: "FFFF00", mardCode: "E24"),

        // F系列 - 红色系
        BeadColor(colorHex: "FD957B", mardCode: "F1"),
        BeadColor(colorHex: "FC3D46", mardCode: "F2"),
        BeadColor(colorHex: "F74941", mardCode: "F3"),
        BeadColor(colorHex: "FC283C", mardCode: "F4"),
        BeadColor(colorHex: "E7002F", mardCode: "F5"),
        BeadColor(colorHex: "943630", mardCode: "F6"),
        BeadColor(colorHex: "971937", mardCode: "F7"),
        BeadColor(colorHex: "BC0028", mardCode: "F8"),
        BeadColor(colorHex: "E2677A", mardCode: "F9"),
        BeadColor(colorHex: "8A4526", mardCode: "F10"),
        BeadColor(colorHex: "5A2121", mardCode: "F11"),
        BeadColor(colorHex: "FD4E6A", mardCode: "F12"),
        BeadColor(colorHex: "F35744", mardCode: "F13"),
        BeadColor(colorHex: "FFA9AD", mardCode: "F14"),
        BeadColor(colorHex: "D30022", mardCode: "F15"),
        BeadColor(colorHex: "FEC2A6", mardCode: "F16"),
        BeadColor(colorHex: "E69C79", mardCode: "F17"),
        BeadColor(colorHex: "D37C46", mardCode: "F18"),
        BeadColor(colorHex: "C1444A", mardCode: "F19"),
        BeadColor(colorHex: "CD9391", mardCode: "F20"),
        BeadColor(colorHex: "F7B4C6", mardCode: "F21"),
        BeadColor(colorHex: "FDC0D0", mardCode: "F22"),
        BeadColor(colorHex: "F67E66", mardCode: "F23"),
        BeadColor(colorHex: "E698AA", mardCode: "F24"),
        BeadColor(colorHex: "E54B4F", mardCode: "F25"),

        // G系列 - 棕/肤色系
        BeadColor(colorHex: "FFE2CE", mardCode: "G1"),
        BeadColor(colorHex: "FFC4AA", mardCode: "G2"),
        BeadColor(colorHex: "F4C3A5", mardCode: "G3"),
        BeadColor(colorHex: "E1B383", mardCode: "G4"),
        BeadColor(colorHex: "EDB045", mardCode: "G5"),
        BeadColor(colorHex: "E99C17", mardCode: "G6"),
        BeadColor(colorHex: "9D5B3E", mardCode: "G7"),
        BeadColor(colorHex: "753B32", mardCode: "G8"),
        BeadColor(colorHex: "E6B483", mardCode: "G9"),
        BeadColor(colorHex: "D98C39", mardCode: "G10"),
        BeadColor(colorHex: "E0C593", mardCode: "G11"),
        BeadColor(colorHex: "FFC890", mardCode: "G12"),
        BeadColor(colorHex: "B7714A", mardCode: "G13"),
        BeadColor(colorHex: "8D614C", mardCode: "G14"),
        BeadColor(colorHex: "FCF9E0", mardCode: "G15"),
        BeadColor(colorHex: "F2D9BA", mardCode: "G16"),
        BeadColor(colorHex: "7B524B", mardCode: "G17"),
        BeadColor(colorHex: "FFE4CC", mardCode: "G18"),
        BeadColor(colorHex: "E07935", mardCode: "G19"),
        BeadColor(colorHex: "A94023", mardCode: "G20"),
        BeadColor(colorHex: "B88558", mardCode: "G21"),

        // H系列 - 灰/黑/白色系
        BeadColor(colorHex: "FDFBFF", mardCode: "H1"),
        BeadColor(colorHex: "FEFFFF", mardCode: "H2"),
        BeadColor(colorHex: "B6B1BA", mardCode: "H3"),
        BeadColor(colorHex: "89858C", mardCode: "H4"),
        BeadColor(colorHex: "48464E", mardCode: "H5"),
        BeadColor(colorHex: "2F2B2F", mardCode: "H6"),
        BeadColor(colorHex: "000000", mardCode: "H7"),
        BeadColor(colorHex: "E7D6DB", mardCode: "H8"),
        BeadColor(colorHex: "EDEDED", mardCode: "H9"),
        BeadColor(colorHex: "EEE9EA", mardCode: "H10"),
        BeadColor(colorHex: "CECDD5", mardCode: "H11"),
        BeadColor(colorHex: "FFF5ED", mardCode: "H12"),
        BeadColor(colorHex: "F5ECD2", mardCode: "H13"),
        BeadColor(colorHex: "CFD7D3", mardCode: "H14"),
        BeadColor(colorHex: "98A6A8", mardCode: "H15"),
        BeadColor(colorHex: "1D1414", mardCode: "H16"),
        BeadColor(colorHex: "F1EDED", mardCode: "H17"),
        BeadColor(colorHex: "FFFDF0", mardCode: "H18"),
        BeadColor(colorHex: "F6EFE2", mardCode: "H19"),
        BeadColor(colorHex: "949FA3", mardCode: "H20"),
        BeadColor(colorHex: "FFFBE1", mardCode: "H21"),
        BeadColor(colorHex: "CACAD4", mardCode: "H22"),
        BeadColor(colorHex: "9A9D94", mardCode: "H23"),

        // M系列 - 莫兰迪色系
        BeadColor(colorHex: "BCC6B8", mardCode: "M1"),
        BeadColor(colorHex: "8AA386", mardCode: "M2"),
        BeadColor(colorHex: "697D80", mardCode: "M3"),
        BeadColor(colorHex: "E3D2BC", mardCode: "M4"),
        BeadColor(colorHex: "D0CCAA", mardCode: "M5"),
        BeadColor(colorHex: "B0A782", mardCode: "M6"),
        BeadColor(colorHex: "B4A497", mardCode: "M7"),
        BeadColor(colorHex: "B38281", mardCode: "M8"),
        BeadColor(colorHex: "A58767", mardCode: "M9"),
        BeadColor(colorHex: "C5B2BC", mardCode: "M10"),
        BeadColor(colorHex: "9F7594", mardCode: "M11"),
        BeadColor(colorHex: "644749", mardCode: "M12"),
        BeadColor(colorHex: "D19066", mardCode: "M13"),
        BeadColor(colorHex: "C77362", mardCode: "M14"),
        BeadColor(colorHex: "757D7B", mardCode: "M15"),

        // P系列 - 珠光/特殊色系
        BeadColor(colorHex: "FCF7F8", mardCode: "P1"),
        BeadColor(colorHex: "B0A9AC", mardCode: "P2"),
        BeadColor(colorHex: "AFDCAB", mardCode: "P3"),
        BeadColor(colorHex: "FEA49F", mardCode: "P4"),
        BeadColor(colorHex: "EE8C3E", mardCode: "P5"),
        BeadColor(colorHex: "5FD0A7", mardCode: "P6"),
        BeadColor(colorHex: "EB9270", mardCode: "P7"),
        BeadColor(colorHex: "F0D958", mardCode: "P8"),
        BeadColor(colorHex: "D9D9D9", mardCode: "P9"),
        BeadColor(colorHex: "D9C7EA", mardCode: "P10"),
        BeadColor(colorHex: "F3ECC9", mardCode: "P11"),
        BeadColor(colorHex: "E6EEF2", mardCode: "P12"),
        BeadColor(colorHex: "AACBEF", mardCode: "P13"),
        BeadColor(colorHex: "3376B0", mardCode: "P14"),
        BeadColor(colorHex: "668575", mardCode: "P15"),
        BeadColor(colorHex: "FEBF45", mardCode: "P16"),
        BeadColor(colorHex: "FEA324", mardCode: "P17"),
        BeadColor(colorHex: "FEB89F", mardCode: "P18"),
        BeadColor(colorHex: "FFE0E9", mardCode: "P19"),
        BeadColor(colorHex: "FEBECF", mardCode: "P20"),
        BeadColor(colorHex: "ECBEBF", mardCode: "P21"),
        BeadColor(colorHex: "E4A89F", mardCode: "P22"),
        BeadColor(colorHex: "A56268", mardCode: "P23"),

        // Q系列 - 荧光色系
        BeadColor(colorHex: "F2A5E8", mardCode: "Q1"),
        BeadColor(colorHex: "E9EC91", mardCode: "Q2"),
        BeadColor(colorHex: "FFFF00", mardCode: "Q3"),
        BeadColor(colorHex: "FFEBFA", mardCode: "Q4"),
        BeadColor(colorHex: "76CEDE", mardCode: "Q5"),

        // R系列 - 特殊/混合色系
        BeadColor(colorHex: "D50D21", mardCode: "R1"),
        BeadColor(colorHex: "F92F83", mardCode: "R2"),
        BeadColor(colorHex: "FD8324", mardCode: "R3"),
        BeadColor(colorHex: "F8EC31", mardCode: "R4"),
        BeadColor(colorHex: "35C75B", mardCode: "R5"),
        BeadColor(colorHex: "23B891", mardCode: "R6"),
        BeadColor(colorHex: "19779D", mardCode: "R7"),
        BeadColor(colorHex: "1A60C3", mardCode: "R8"),
        BeadColor(colorHex: "9A56B4", mardCode: "R9"),
        BeadColor(colorHex: "FFDB4C", mardCode: "R10"),
        BeadColor(colorHex: "FFEBFA", mardCode: "R11"),
        BeadColor(colorHex: "D8D5CE", mardCode: "R12"),
        BeadColor(colorHex: "55514C", mardCode: "R13"),
        BeadColor(colorHex: "9FE4DF", mardCode: "R14"),
        BeadColor(colorHex: "77CEE9", mardCode: "R15"),
        BeadColor(colorHex: "3ECFCA", mardCode: "R16"),
        BeadColor(colorHex: "4A867A", mardCode: "R17"),
        BeadColor(colorHex: "7FCD9D", mardCode: "R18"),
        BeadColor(colorHex: "CDE55D", mardCode: "R19"),
        BeadColor(colorHex: "E8C7B4", mardCode: "R20"),
        BeadColor(colorHex: "AD6F3C", mardCode: "R21"),
        BeadColor(colorHex: "6C372F", mardCode: "R22"),
        BeadColor(colorHex: "FEB872", mardCode: "R23"),
        BeadColor(colorHex: "F3C1C0", mardCode: "R24"),
        BeadColor(colorHex: "C9675E", mardCode: "R25"),
        BeadColor(colorHex: "D293BE", mardCode: "R26"),
        BeadColor(colorHex: "EA8CB1", mardCode: "R27"),
        BeadColor(colorHex: "9C87D6", mardCode: "R28"),

        // T系列 - 透明色
        BeadColor(colorHex: "FFFFFF", mardCode: "T1"),

        // Y系列 - 夜光色系
        BeadColor(colorHex: "FD6FB4", mardCode: "Y1"),
        BeadColor(colorHex: "FEB481", mardCode: "Y2"),
        BeadColor(colorHex: "D7FAA0", mardCode: "Y3"),
        BeadColor(colorHex: "8BDBFA", mardCode: "Y4"),
        BeadColor(colorHex: "E987EA", mardCode: "Y5"),

        // ZG系列 - 珠光渐变色系
        BeadColor(colorHex: "DAABB3", mardCode: "ZG1"),
        BeadColor(colorHex: "D6AA87", mardCode: "ZG2"),
        BeadColor(colorHex: "C1BD8D", mardCode: "ZG3"),
        BeadColor(colorHex: "96B69F", mardCode: "ZG4"),
        BeadColor(colorHex: "849DC6", mardCode: "ZG5"),
        BeadColor(colorHex: "94BFE2", mardCode: "ZG6"),
        BeadColor(colorHex: "E2A9D2", mardCode: "ZG7"),
        BeadColor(colorHex: "AB91C0", mardCode: "ZG8"),

        // 特殊色号
        BeadColor(colorHex: "CCCCCC", mardCode: "Any", colorName: "任意色"),
    ]
}
