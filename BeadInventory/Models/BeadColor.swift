//
//  BeadColor.swift
//  BeadInventory
//
//  豆子颜色数据模型
//

import Foundation
import SwiftUI

// MARK: - 豆子颜色模型
struct BeadColor: Identifiable, Codable, Hashable {
    let id: UUID
    let colorHex: String           // 颜色十六进制值
    let mardCode: String           // MARD色号
    let cocoCode: String           // COCO色号
    let manmanCode: String         // 漫漫色号
    let panpanCode: String         // 盼盼色号
    let mixiaowoCode: String       // 咪小窝色号
    let kakaCode: String           // 卡卡色号
    let colorName: String          // 颜色名称
    var stock: Int                 // 库存数量
    var used: Int                  // 已使用数量

    init(
        id: UUID = UUID(),
        colorHex: String,
        mardCode: String,
        cocoCode: String = "",
        manmanCode: String = "",
        panpanCode: String = "",
        mixiaowoCode: String = "",
        kakaCode: String = "",
        colorName: String = "",
        stock: Int = 1000,
        used: Int = 0
    ) {
        self.id = id
        self.colorHex = colorHex
        self.mardCode = mardCode
        self.cocoCode = cocoCode
        self.manmanCode = manmanCode
        self.panpanCode = panpanCode
        self.mixiaowoCode = mixiaowoCode
        self.kakaCode = kakaCode
        self.colorName = colorName
        self.stock = stock
        self.used = used
    }

    // 自定义解码器，兼容旧数据（没有 kakaCode 字段）
    private enum BeadColorCodingKeys: String, CodingKey {
        case id, colorHex, mardCode, cocoCode, manmanCode, panpanCode, mixiaowoCode, kakaCode, colorName, stock, used
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: BeadColorCodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        colorHex = try container.decode(String.self, forKey: .colorHex)
        mardCode = try container.decode(String.self, forKey: .mardCode)
        cocoCode = try container.decodeIfPresent(String.self, forKey: .cocoCode) ?? ""
        manmanCode = try container.decodeIfPresent(String.self, forKey: .manmanCode) ?? ""
        panpanCode = try container.decodeIfPresent(String.self, forKey: .panpanCode) ?? ""
        mixiaowoCode = try container.decodeIfPresent(String.self, forKey: .mixiaowoCode) ?? ""
        kakaCode = try container.decodeIfPresent(String.self, forKey: .kakaCode) ?? ""
        colorName = try container.decodeIfPresent(String.self, forKey: .colorName) ?? ""
        stock = try container.decodeIfPresent(Int.self, forKey: .stock) ?? 1000
        used = try container.decodeIfPresent(Int.self, forKey: .used) ?? 0
    }

    var color: Color {
        Color(hex: colorHex)
    }

    var available: Int {
        stock - used
    }

    /// 获取指定色号体系的编码
    func displayCode(for system: ColorSystem) -> String {
        let code: String
        switch system {
        case .mard: code = mardCode
        case .coco: code = cocoCode
        case .manman: code = manmanCode
        case .panpan: code = panpanCode
        case .mixiaowo: code = mixiaowoCode
        case .kaka: code = kakaCode
        }
        return code.isEmpty ? mardCode : code
    }

    /// 判断该颜色在指定色号体系中是否有对应编码
    func hasCode(for system: ColorSystem) -> Bool {
        switch system {
        case .mard: return !mardCode.isEmpty && !mardCode.hasPrefix("KK-")
        case .coco: return !cocoCode.isEmpty
        case .manman: return !manmanCode.isEmpty
        case .panpan: return !panpanCode.isEmpty
        case .mixiaowo: return !mixiaowoCode.isEmpty
        case .kaka: return !kakaCode.isEmpty
        }
    }
}

// MARK: - 图纸记录模型
struct ProjectRecord: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var date: Date
    var beadUsage: [BeadUsage]    // 各颜色用量
    var totalBeads: Int
    var brandId: UUID?            // 项目关联的品牌 ID
    var isArchived: Bool          // 是否已归档
    var parentId: UUID?           // 父项目ID，nil表示顶级项目
    var isPlanned: Bool           // 是否为计划项目（true=计划中，false=已执行）
    var executedDate: Date?       // 执行日期（计划项目执行后记录）
    var thumbnail: Data?          // 缩略图数据（可选，压缩后的JPEG）
    var finishedImage: Data?      // 成品图数据（可选，压缩后的JPEG，仅已执行项目使用）
    var completedDate: Date?      // 完成日期（用于日历展示，用户可自定义选择）
    var colorSystem: ColorSystem  // 色号体系（MARD/卡卡等）
    var patternGrid: BeadPatternGrid?  // 拼图模式网格数据（nil = 未标定）

    // MARK: - 大图懒加载标志
    //
    // finishedImage / patternGrid 是内联存储的大 blob。为避免每次全量 loadData
    // 把所有项目的成品图/网格都读进内存（图越多越慢、越占内存），列表/统计阶段
    // **不再加载** 这两个字段，仅在真正需要展示时按 id 按需加载。
    //
    // 这两个标志反映「持久层里到底有没有这张图」，独立于 finishedImage/patternGrid
    // 当前是否已加载进内存：
    //   - finishedImage == nil 且 hasFinishedImage == true  → 懒加载未读，**不是**没有图
    //   - finishedImage == nil 且 hasFinishedImage == false → 确实没有图（或被用户清空）
    // saveData() 依赖这个区分，避免把"未加载"误当成"被删除"而擦掉云端/本地的图。
    var hasFinishedImage: Bool
    var hasPatternGrid: Bool
    /// 同理，thumbnail 实际存的是完整拼图原图（单张可达数 MB），列表/详情按需加载。
    /// 区分「未加载」与「无图」，供 saveData() 防擦图。
    var hasThumbnail: Bool

    init(id: UUID = UUID(), name: String, date: Date = Date(), beadUsage: [BeadUsage] = [], brandId: UUID? = nil, isArchived: Bool = false, parentId: UUID? = nil, isPlanned: Bool = false, executedDate: Date? = nil, thumbnail: Data? = nil, finishedImage: Data? = nil, completedDate: Date? = nil, colorSystem: ColorSystem = .mard, patternGrid: BeadPatternGrid? = nil, hasFinishedImage: Bool? = nil, hasPatternGrid: Bool? = nil, hasThumbnail: Bool? = nil) {
        self.id = id
        self.name = name
        self.date = date
        self.beadUsage = beadUsage
        self.totalBeads = beadUsage.reduce(0) { $0 + $1.quantity }
        self.brandId = brandId
        self.isArchived = isArchived
        self.parentId = parentId
        self.isPlanned = isPlanned
        self.executedDate = executedDate
        self.thumbnail = thumbnail
        self.finishedImage = finishedImage
        self.completedDate = completedDate
        self.colorSystem = colorSystem
        self.patternGrid = patternGrid
        // 默认从内存值推断：常规构造（带真实图）的调用方无需关心标志位。
        // 懒加载路径会显式传 true + 图为 nil。
        self.hasFinishedImage = hasFinishedImage ?? (finishedImage != nil)
        self.hasPatternGrid = hasPatternGrid ?? (patternGrid != nil)
        self.hasThumbnail = hasThumbnail ?? (thumbnail != nil)
    }

    // 自定义解码器，兼容旧数据
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        date = try container.decode(Date.self, forKey: .date)
        beadUsage = try container.decode([BeadUsage].self, forKey: .beadUsage)
        totalBeads = try container.decode(Int.self, forKey: .totalBeads)
        brandId = try container.decodeIfPresent(UUID.self, forKey: .brandId)
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        parentId = try container.decodeIfPresent(UUID.self, forKey: .parentId)
        // 向后兼容：旧数据没有 isPlanned 字段，默认为 false（已执行状态）
        isPlanned = try container.decodeIfPresent(Bool.self, forKey: .isPlanned) ?? false
        executedDate = try container.decodeIfPresent(Date.self, forKey: .executedDate)
        // 向后兼容：旧数据没有 thumbnail 字段
        thumbnail = try container.decodeIfPresent(Data.self, forKey: .thumbnail)
        // 向后兼容：旧数据没有 finishedImage 字段
        finishedImage = try container.decodeIfPresent(Data.self, forKey: .finishedImage)
        // 向后兼容：旧数据没有 completedDate 字段
        completedDate = try container.decodeIfPresent(Date.self, forKey: .completedDate)
        // 向后兼容：旧数据没有 colorSystem 字段，默认为 MARD
        colorSystem = try container.decodeIfPresent(ColorSystem.self, forKey: .colorSystem) ?? .mard
        // 向后兼容：旧数据没有 patternGrid 字段
        patternGrid = try container.decodeIfPresent(BeadPatternGrid.self, forKey: .patternGrid)
        // 向后兼容：旧快照/备份没有这两个标志 → 按当前是否带图推断
        hasFinishedImage = try container.decodeIfPresent(Bool.self, forKey: .hasFinishedImage) ?? (finishedImage != nil)
        hasPatternGrid = try container.decodeIfPresent(Bool.self, forKey: .hasPatternGrid) ?? (patternGrid != nil)
        hasThumbnail = try container.decodeIfPresent(Bool.self, forKey: .hasThumbnail) ?? (thumbnail != nil)
    }
}

// MARK: - 单色用量
struct BeadUsage: Identifiable, Codable, Hashable {
    let id: UUID
    let colorCode: String          // 色号（MARD为主）
    let brandId: UUID?             // 关联的品牌 ID
    var quantity: Int              // 用量
    var isDeducted: Bool           // 是否已从库存扣除

    init(id: UUID = UUID(), colorCode: String, brandId: UUID? = nil, quantity: Int, isDeducted: Bool = false) {
        self.id = id
        self.colorCode = colorCode
        self.brandId = brandId
        self.quantity = quantity
        self.isDeducted = isDeducted
    }

    // 自定义解码器，兼容旧数据（没有 brandId 和 isDeducted 字段）
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        colorCode = try container.decode(String.self, forKey: .colorCode)
        brandId = try container.decodeIfPresent(UUID.self, forKey: .brandId)
        quantity = try container.decode(Int.self, forKey: .quantity)
        isDeducted = try container.decodeIfPresent(Bool.self, forKey: .isDeducted) ?? false
    }
}

// MARK: - 购买记录（运输中）
struct PurchaseRecord: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String                    // 购买记录名称（如"淘宝订单xxx"）
    let date: Date                      // 创建日期
    var brandId: UUID                   // 目标品牌
    var items: [PurchaseItem]           // 购买的颜色列表
    var note: String?                   // 备注

    init(id: UUID = UUID(), name: String, date: Date = Date(), brandId: UUID, items: [PurchaseItem], note: String? = nil) {
        self.id = id
        self.name = name
        self.date = date
        self.brandId = brandId
        self.items = items
        self.note = note
    }

    var totalBeads: Int {
        items.reduce(0) { $0 + $1.quantity }
    }

    var colorCount: Int {
        items.count
    }
}

// MARK: - 购买项
struct PurchaseItem: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let colorCode: String   // 色号（MARD）
    var quantity: Int       // 数量

    init(id: UUID = UUID(), colorCode: String, quantity: Int) {
        self.id = id
        self.colorCode = colorCode
        self.quantity = quantity
    }
}

// MARK: - Color Extension
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
