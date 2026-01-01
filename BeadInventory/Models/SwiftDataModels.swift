//
//  SwiftDataModels.swift
//  BeadInventory
//
//  SwiftData 数据模型
//

import Foundation
import SwiftData

// MARK: - 品牌模型
@Model
final class SDBrand {
    @Attribute(.unique) var id: UUID
    var name: String
    var sortOrder: Int
    var createdAt: Date

    init(id: UUID = UUID(), name: String, sortOrder: Int = 0, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    // 从 struct 转换
    convenience init(from brand: Brand) {
        self.init(id: brand.id, name: brand.name, sortOrder: brand.sortOrder, createdAt: brand.createdAt)
    }

    // 转换为 struct
    func toStruct() -> Brand {
        Brand(id: id, name: name, sortOrder: sortOrder, createdAt: createdAt)
    }
}

// MARK: - 品牌库存模型
@Model
final class SDBrandStock {
    @Attribute(.unique) var id: UUID
    var brandId: UUID
    var mardCode: String
    var stock: Int
    var used: Int

    var available: Int {
        stock - used
    }

    init(id: UUID = UUID(), brandId: UUID, mardCode: String, stock: Int = 1000, used: Int = 0) {
        self.id = id
        self.brandId = brandId
        self.mardCode = mardCode
        self.stock = stock
        self.used = used
    }

    convenience init(from brandStock: BrandStock) {
        self.init(id: brandStock.id, brandId: brandStock.brandId, mardCode: brandStock.mardCode, stock: brandStock.stock, used: brandStock.used)
    }

    func toStruct() -> BrandStock {
        BrandStock(id: id, brandId: brandId, mardCode: mardCode, stock: stock, used: used)
    }
}

// MARK: - 项目记录模型
@Model
final class SDProjectRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var date: Date
    var totalBeads: Int
    var brandId: UUID?
    var isArchived: Bool
    var parentId: UUID?           // 父项目ID，nil表示顶级项目
    var isPlanned: Bool?          // 是否为计划项目（可选，nil视为false）
    var executedDate: Date?       // 执行日期

    @Relationship(deleteRule: .cascade)
    var beadUsages: [SDBeadUsage]

    // 计算属性：安全获取 isPlanned 值
    var isPlannedValue: Bool {
        isPlanned ?? false
    }

    init(id: UUID = UUID(), name: String, date: Date = Date(), totalBeads: Int = 0, brandId: UUID? = nil, isArchived: Bool = false, parentId: UUID? = nil, isPlanned: Bool = false, executedDate: Date? = nil, beadUsages: [SDBeadUsage] = []) {
        self.id = id
        self.name = name
        self.date = date
        self.totalBeads = totalBeads
        self.brandId = brandId
        self.isArchived = isArchived
        self.parentId = parentId
        self.isPlanned = isPlanned
        self.executedDate = executedDate
        self.beadUsages = beadUsages
    }

    convenience init(from record: ProjectRecord) {
        let usages = record.beadUsage.map { SDBeadUsage(from: $0) }
        self.init(id: record.id, name: record.name, date: record.date, totalBeads: record.totalBeads, brandId: record.brandId, isArchived: record.isArchived, parentId: record.parentId, isPlanned: record.isPlanned, executedDate: record.executedDate, beadUsages: usages)
    }

    func toStruct() -> ProjectRecord {
        let usages = beadUsages.map { $0.toStruct() }
        return ProjectRecord(id: id, name: name, date: date, beadUsage: usages, brandId: brandId, isArchived: isArchived, parentId: parentId, isPlanned: isPlannedValue, executedDate: executedDate)
    }
}

// MARK: - 单色用量模型
@Model
final class SDBeadUsage {
    @Attribute(.unique) var id: UUID
    var colorCode: String
    var brandId: UUID?
    var quantity: Int
    var isDeducted: Bool

    init(id: UUID = UUID(), colorCode: String, brandId: UUID? = nil, quantity: Int, isDeducted: Bool = false) {
        self.id = id
        self.colorCode = colorCode
        self.brandId = brandId
        self.quantity = quantity
        self.isDeducted = isDeducted
    }

    convenience init(from usage: BeadUsage) {
        self.init(id: usage.id, colorCode: usage.colorCode, brandId: usage.brandId, quantity: usage.quantity, isDeducted: usage.isDeducted)
    }

    func toStruct() -> BeadUsage {
        BeadUsage(id: id, colorCode: colorCode, brandId: brandId, quantity: quantity, isDeducted: isDeducted)
    }
}
