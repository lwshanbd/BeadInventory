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

    init(
        id: UUID = UUID(),
        name: String,
        sortOrder: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}
