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
    let vividCode: String          // vivid色号
    let manmanCode: String         // 漫漫色号
    let kakaCode: String           // 卡卡色号
    let colorName: String          // 颜色名称
    var stock: Int                 // 库存数量
    var used: Int                  // 已使用数量

    init(
        id: UUID = UUID(),
        colorHex: String,
        mardCode: String,
        vividCode: String = "",
        manmanCode: String = "",
        kakaCode: String = "",
        colorName: String = "",
        stock: Int = 1000,
        used: Int = 0
    ) {
        self.id = id
        self.colorHex = colorHex
        self.mardCode = mardCode
        self.vividCode = vividCode
        self.manmanCode = manmanCode
        self.kakaCode = kakaCode
        self.colorName = colorName
        self.stock = stock
        self.used = used
    }

    var color: Color {
        Color(hex: colorHex)
    }

    var available: Int {
        stock - used
    }
}

// MARK: - 图纸记录模型
struct ProjectRecord: Identifiable, Codable {
    let id: UUID
    var name: String
    var date: Date
    var beadUsage: [BeadUsage]    // 各颜色用量
    var totalBeads: Int
    var brandId: UUID?            // 项目关联的品牌 ID
    var isArchived: Bool          // 是否已归档

    init(id: UUID = UUID(), name: String, date: Date = Date(), beadUsage: [BeadUsage] = [], brandId: UUID? = nil, isArchived: Bool = false) {
        self.id = id
        self.name = name
        self.date = date
        self.beadUsage = beadUsage
        self.totalBeads = beadUsage.reduce(0) { $0 + $1.quantity }
        self.brandId = brandId
        self.isArchived = isArchived
    }

    // 自定义解码器，兼容旧数据（没有 isArchived 字段）
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        date = try container.decode(Date.self, forKey: .date)
        beadUsage = try container.decode([BeadUsage].self, forKey: .beadUsage)
        totalBeads = try container.decode(Int.self, forKey: .totalBeads)
        brandId = try container.decodeIfPresent(UUID.self, forKey: .brandId)
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
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
