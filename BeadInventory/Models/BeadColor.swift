//
//  BeadColor.swift
//  BeadInventory
//
//  豆子颜色数据模型
//

import Foundation
import SwiftUI

// MARK: - 豆子颜色模型
struct BeadColor: Identifiable, Codable, Hashable, Sendable {
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
struct ProjectRecord: Identifiable, Codable, Equatable, Sendable {
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
    var thumbnail: Data?          // 「原图」—— 全分辨率（编码见 ProjectImageEncoder）。拼图模式 / 详情大图用。**列表 row 不要直接读**
                                  // （读了就 jetsam）—— 走 displayThumbnail，没有就 ImageDownsampler 现场降级。
    var finishedImage: Data?      // 成品图数据（编码见 ProjectImageEncoder，仅已执行项目使用）
    var completedDate: Date?      // 完成日期（用于日历展示，用户可自定义选择）
    var colorSystem: ColorSystem  // 色号体系（MARD/卡卡等）
    var patternGrid: BeadPatternGrid?  // 拼图模式网格数据（nil = 未标定）
    var displayThumbnail: Data?   // 列表用小图（512px JPEG 0.85 ~50-100 KB）。老数据 nil，由迁移协调器后台填。

    /// - Parameter totalBeads: 显式总数。为 `nil` 时从 `beadUsage` 求和（兼容旧调用方）。
    ///   注意：`SDProjectRecord.toStruct()` 应该传入 `totalBeads: sdProject.totalBeads`，
    ///   这样既复用持久层算好的总数，也不需要 fault 整个 `beadUsages` relationship 来求和。
    init(
        id: UUID = UUID(),
        name: String,
        date: Date = Date(),
        beadUsage: [BeadUsage] = [],
        totalBeads: Int? = nil,
        brandId: UUID? = nil,
        isArchived: Bool = false,
        parentId: UUID? = nil,
        isPlanned: Bool = false,
        executedDate: Date? = nil,
        thumbnail: Data? = nil,
        finishedImage: Data? = nil,
        completedDate: Date? = nil,
        colorSystem: ColorSystem = .mard,
        patternGrid: BeadPatternGrid? = nil,
        displayThumbnail: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.date = date
        self.beadUsage = beadUsage
        self.totalBeads = totalBeads ?? beadUsage.reduce(0) { $0 + $1.quantity }
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
        self.displayThumbnail = displayThumbnail
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
        // 向后兼容：旧数据没有 displayThumbnail 字段（迁移协调器会后台 backfill）
        displayThumbnail = try container.decodeIfPresent(Data.self, forKey: .displayThumbnail)
    }
}

// MARK: - 单色用量
struct BeadUsage: Identifiable, Codable, Hashable, Sendable {
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
struct PurchaseRecord: Identifiable, Codable, Equatable, Sendable {
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
    /// 已经报过的非法 hex。`Color(hex:)` 常写在 `body` 第一行（比如 `BIColorSwatch`），
    /// 列表里有一个坏色号 + 用户一滚，日志会按帧刷 —— `AppLogger` 是滚动的，
    /// 几秒就能把导出诊断时真正要看的记录挤掉。同一个值只报一次。
    @MainActor private static var reportedInvalidHex: Set<String> = []

    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        // **要扫到底、位数也要对。**
        //
        // `scanHexInt64` 碰到非十六进制字符就停下、把已经读到的那几位当结果 ——
        // 而 trim 只去两头的非字母数字，字母混在中间是留得住的。参考数据 `color.json`
        // 里出现过 `#FECODF`（第 4 位是字母 O 不是零）；那份没进 App 包，所以**没有真的
        // 渲染错过**，但同样的笔误落到运行时那份 `allcolors.json` 上就是：扫出 `0xFEC`、
        // 位数仍是 6、一路走到 case 6，浅粉变饱和蓝，不报错也不留日志。
        //
        // 位数得单独判：`"FFFF"` 全是合法十六进制字符、扫得到底，但 3/6/8 之外的位数
        // 一样是笔误，只判字符的话它会静默落到 default 变成一格黑。
        let scanner = Scanner(string: hex)
        let parsed = scanner.scanHexInt64(&int) && scanner.isAtEnd
            && (hex.count == 3 || hex.count == 6 || hex.count == 8)
        if !parsed {
            // **不断言。** 这里收得到持久化和导入的数据（`SDCustomColor.colorHex` 的默认值
            // 就是空串；备份恢复那条路见 `BackupManager`），拿用户的数据去炸开发机不对。
            // 挡在门口是导入那边的事，这里只负责别装成没事。
            MainActor.assumeIsolated {
                if Self.reportedInvalidHex.insert(hex).inserted {
                    AppLogger.shared.error("Color", "invalid_hex",
                                           metadata: ["hex": hex, "len": "\(hex.count)"])
                }
            }
        }
        let a, r, g, b: UInt64
        switch parsed ? hex.count : 0 {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            // **兜底别用黑。** 黑在这个 App 里是合法色号（`H7 #000000` 就在色表里），
            // 一格黑看起来像「这个色号变成黑的了」，而不是「这条数据坏了」。
            // 跟 `CellOverlayBitmap` 那个「没认出来」的兜底同一个思路：挑一个没有哪个
            // 色号长这样的品红，它出现在屏幕上就等于「这儿的颜色没解析出来」。
            (a, r, g, b) = (255, 217, 38, 191)
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
