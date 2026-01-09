//
//  Brand.swift
//  BeadInventory
//
//  品牌/供应商模型
//

import Foundation

struct Brand: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String           // 品牌/供应商名称（如 "AB", "C"）
    var sortOrder: Int         // 排序顺序
    var createdAt: Date        // 创建时间
    var lowStockThreshold: Int // 低库存阈值，默认为100

    init(
        id: UUID = UUID(),
        name: String,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        lowStockThreshold: Int = 100
    ) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.lowStockThreshold = lowStockThreshold
    }

    // 自定义解码，兼容旧数据（没有 lowStockThreshold 属性）
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        sortOrder = try container.decode(Int.self, forKey: .sortOrder)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        // 兼容旧数据：如果没有 lowStockThreshold，使用默认值 100
        lowStockThreshold = try container.decodeIfPresent(Int.self, forKey: .lowStockThreshold) ?? 100
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, sortOrder, createdAt, lowStockThreshold
    }
}
