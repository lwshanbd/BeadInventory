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
    @Published var selectedBrand: BrandType = .mard

    private let beadColorsKey = "beadColors"
    private let projectsKey = "projects"

    enum BrandType: String, CaseIterable {
        case mard = "MARD"
        case vivid = "vivid"
        case manman = "漫漫"
        case kaka = "卡卡"
    }

    init() {
        loadData()
        if beadColors.isEmpty {
            initializeDefaultColors()
        }
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
    }

    func saveData() {
        if let data = try? JSONEncoder().encode(beadColors) {
            UserDefaults.standard.set(data, forKey: beadColorsKey)
        }
        if let data = try? JSONEncoder().encode(projects) {
            UserDefaults.standard.set(data, forKey: projectsKey)
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
            if beadColors[index].available >= amount {
                beadColors[index].used += amount
                saveData()
                return true
            }
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

    func getCode(for color: BeadColor, brand: BrandType) -> String {
        switch brand {
        case .mard: return color.mardCode
        case .vivid: return color.vividCode
        case .manman: return color.manmanCode
        case .kaka: return color.kakaCode
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
        for index in beadColors.indices {
            beadColors[index].stock = amount
            beadColors[index].used = 0
        }
        saveData()
    }

    func resetUsage() {
        for index in beadColors.indices {
            beadColors[index].used = 0
        }
        saveData()
    }

    // MARK: - 初始化默认颜色数据

    private func initializeDefaultColors() {
        // 初始化221个常用实色 (示例数据，实际使用时可以从文件导入)
        beadColors = DefaultBeadColors.colors
        saveData()
    }
}

// MARK: - 默认颜色数据
struct DefaultBeadColors {
    static let colors: [BeadColor] = [
        // 红色系
        BeadColor(colorHex: "8B0000", mardCode: "F8", vividCode: "81", manmanCode: "A17", kakaCode: "B56", colorName: "深红"),
        BeadColor(colorHex: "FFFFFF", mardCode: "H2", vividCode: "1", manmanCode: "F2", kakaCode: "B2", colorName: "白色"),
        BeadColor(colorHex: "FFD700", mardCode: "A17", vividCode: "213", manmanCode: "IC09", kakaCode: "B195", colorName: "金黄"),
        BeadColor(colorHex: "FFA500", mardCode: "A3", vividCode: "28", manmanCode: "B2", kakaCode: "B86", colorName: "橙色"),
        BeadColor(colorHex: "90EE90", mardCode: "B6", vividCode: "11", manmanCode: "C9", kakaCode: "B146", colorName: "浅绿"),
        BeadColor(colorHex: "FF6B6B", mardCode: "F14", vividCode: "154", manmanCode: "A25", kakaCode: "B188", colorName: "珊瑚红"),
        BeadColor(colorHex: "FFB6C1", mardCode: "F5", vividCode: "5", manmanCode: "A5", kakaCode: "B62", colorName: "浅粉"),
        BeadColor(colorHex: "DC143C", mardCode: "D22", vividCode: "198", manmanCode: "DH01", kakaCode: "B233", colorName: "深红"),
        BeadColor(colorHex: "E0E0E0", mardCode: "A1", vividCode: "65", manmanCode: "E2", kakaCode: "E251", colorName: "浅灰"),
        BeadColor(colorHex: "4169E1", mardCode: "G14", vividCode: "114", manmanCode: "E14", kakaCode: "B254", colorName: "皇家蓝"),
        BeadColor(colorHex: "FF4500", mardCode: "F4", vividCode: "54", manmanCode: "A4", kakaCode: "B62", colorName: "橙红"),
        BeadColor(colorHex: "8B4513", mardCode: "F10", vividCode: "116", manmanCode: "E15", kakaCode: "B73", colorName: "棕色"),
        BeadColor(colorHex: "2F4F4F", mardCode: "G15", vividCode: "133", manmanCode: "E19", kakaCode: "B257", colorName: "深灰"),

        // 更多颜色 - 黄色系
        BeadColor(colorHex: "FFFF00", mardCode: "A2", vividCode: "2", manmanCode: "B1", kakaCode: "B80", colorName: "黄色"),
        BeadColor(colorHex: "FFFACD", mardCode: "A4", vividCode: "4", manmanCode: "B3", kakaCode: "B81", colorName: "柠檬黄"),
        BeadColor(colorHex: "F0E68C", mardCode: "A5", vividCode: "5", manmanCode: "B4", kakaCode: "B82", colorName: "卡其黄"),

        // 绿色系
        BeadColor(colorHex: "008000", mardCode: "B1", vividCode: "10", manmanCode: "C1", kakaCode: "B140", colorName: "绿色"),
        BeadColor(colorHex: "00FF00", mardCode: "B2", vividCode: "11", manmanCode: "C2", kakaCode: "B141", colorName: "亮绿"),
        BeadColor(colorHex: "006400", mardCode: "B3", vividCode: "12", manmanCode: "C3", kakaCode: "B142", colorName: "深绿"),
        BeadColor(colorHex: "32CD32", mardCode: "B4", vividCode: "13", manmanCode: "C4", kakaCode: "B143", colorName: "酸橙绿"),
        BeadColor(colorHex: "228B22", mardCode: "B5", vividCode: "14", manmanCode: "C5", kakaCode: "B144", colorName: "森林绿"),

        // 蓝色系
        BeadColor(colorHex: "0000FF", mardCode: "G1", vividCode: "110", manmanCode: "E1", kakaCode: "B250", colorName: "蓝色"),
        BeadColor(colorHex: "00BFFF", mardCode: "G2", vividCode: "111", manmanCode: "E2", kakaCode: "B251", colorName: "天蓝"),
        BeadColor(colorHex: "1E90FF", mardCode: "G3", vividCode: "112", manmanCode: "E3", kakaCode: "B252", colorName: "道奇蓝"),
        BeadColor(colorHex: "000080", mardCode: "G4", vividCode: "113", manmanCode: "E4", kakaCode: "B253", colorName: "海军蓝"),
        BeadColor(colorHex: "87CEEB", mardCode: "G5", vividCode: "115", manmanCode: "E5", kakaCode: "B255", colorName: "天空蓝"),

        // 紫色系
        BeadColor(colorHex: "800080", mardCode: "D1", vividCode: "190", manmanCode: "DH1", kakaCode: "B230", colorName: "紫色"),
        BeadColor(colorHex: "9370DB", mardCode: "D2", vividCode: "191", manmanCode: "DH2", kakaCode: "B231", colorName: "中紫"),
        BeadColor(colorHex: "8A2BE2", mardCode: "D3", vividCode: "192", manmanCode: "DH3", kakaCode: "B232", colorName: "蓝紫"),
        BeadColor(colorHex: "DDA0DD", mardCode: "D4", vividCode: "193", manmanCode: "DH4", kakaCode: "B234", colorName: "梅红"),
        BeadColor(colorHex: "EE82EE", mardCode: "D5", vividCode: "194", manmanCode: "DH5", kakaCode: "B235", colorName: "紫罗兰"),

        // 粉色系
        BeadColor(colorHex: "FFC0CB", mardCode: "F1", vividCode: "50", manmanCode: "A1", kakaCode: "B60", colorName: "粉色"),
        BeadColor(colorHex: "FF69B4", mardCode: "F2", vividCode: "51", manmanCode: "A2", kakaCode: "B61", colorName: "热粉"),
        BeadColor(colorHex: "FF1493", mardCode: "F3", vividCode: "52", manmanCode: "A3", kakaCode: "B63", colorName: "深粉"),

        // 棕色系
        BeadColor(colorHex: "A52A2A", mardCode: "C1", vividCode: "70", manmanCode: "D1", kakaCode: "B170", colorName: "棕色"),
        BeadColor(colorHex: "D2691E", mardCode: "C2", vividCode: "71", manmanCode: "D2", kakaCode: "B171", colorName: "巧克力"),
        BeadColor(colorHex: "8B4513", mardCode: "C3", vividCode: "72", manmanCode: "D3", kakaCode: "B172", colorName: "马鞍棕"),
        BeadColor(colorHex: "CD853F", mardCode: "C4", vividCode: "73", manmanCode: "D4", kakaCode: "B173", colorName: "秘鲁"),
        BeadColor(colorHex: "DEB887", mardCode: "C5", vividCode: "74", manmanCode: "D5", kakaCode: "B174", colorName: "实木"),

        // 灰色系
        BeadColor(colorHex: "808080", mardCode: "H1", vividCode: "0", manmanCode: "F1", kakaCode: "B1", colorName: "灰色"),
        BeadColor(colorHex: "A9A9A9", mardCode: "H3", vividCode: "3", manmanCode: "F3", kakaCode: "B3", colorName: "深灰"),
        BeadColor(colorHex: "D3D3D3", mardCode: "H4", vividCode: "4", manmanCode: "F4", kakaCode: "B4", colorName: "浅灰"),
        BeadColor(colorHex: "000000", mardCode: "H5", vividCode: "99", manmanCode: "F5", kakaCode: "B5", colorName: "黑色"),

        // 特殊色
        BeadColor(colorHex: "C0C0C0", mardCode: "S1", vividCode: "200", manmanCode: "S1", kakaCode: "S1", colorName: "银色"),
        BeadColor(colorHex: "FFD700", mardCode: "S2", vividCode: "201", manmanCode: "S2", kakaCode: "S2", colorName: "金色"),
        BeadColor(colorHex: "F5F5DC", mardCode: "H6", vividCode: "6", manmanCode: "F6", kakaCode: "B6", colorName: "米色"),
        BeadColor(colorHex: "FFFFF0", mardCode: "H7", vividCode: "7", manmanCode: "F7", kakaCode: "B7", colorName: "象牙白"),
        BeadColor(colorHex: "FFF8DC", mardCode: "H8", vividCode: "8", manmanCode: "F8", kakaCode: "B8", colorName: "玉米丝"),
    ]
}
