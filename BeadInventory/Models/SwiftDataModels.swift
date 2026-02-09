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
    var id: UUID = UUID()
    var name: String = ""
    var sortOrder: Int = 0
    var createdAt: Date = Date()
    var lowStockThreshold: Int?  // 低库存阈值，可选以兼容旧数据，默认为100
    var colorSystemRaw: String?  // 色号体系，可选以兼容旧数据，默认为 MARD

    init(id: UUID = UUID(), name: String, sortOrder: Int = 0, createdAt: Date = Date(), lowStockThreshold: Int = 100, colorSystemRaw: String? = nil) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.lowStockThreshold = lowStockThreshold
        self.colorSystemRaw = colorSystemRaw
    }

    // 从 struct 转换
    convenience init(from brand: Brand) {
        self.init(id: brand.id, name: brand.name, sortOrder: brand.sortOrder, createdAt: brand.createdAt, lowStockThreshold: brand.lowStockThreshold, colorSystemRaw: brand.colorSystem.rawValue)
    }

    // 转换为 struct
    func toStruct() -> Brand {
        Brand(id: id, name: name, sortOrder: sortOrder, createdAt: createdAt, lowStockThreshold: lowStockThreshold ?? 100, colorSystem: ColorSystem(rawValue: colorSystemRaw ?? "") ?? .mard)
    }
}

// MARK: - 品牌库存模型
@Model
final class SDBrandStock {
    var id: UUID = UUID()
    var brandId: UUID = UUID()
    var mardCode: String = ""
    var stock: Int = 1000
    var used: Int = 0
    var isHidden: Bool = false  // 是否隐藏（隐藏的色号不显示在库存列表中）

    var available: Int {
        stock - used
    }

    init(id: UUID = UUID(), brandId: UUID, mardCode: String, stock: Int = 1000, used: Int = 0, isHidden: Bool = false) {
        self.id = id
        self.brandId = brandId
        self.mardCode = mardCode
        self.stock = stock
        self.used = used
        self.isHidden = isHidden
    }

    convenience init(from brandStock: BrandStock) {
        self.init(id: brandStock.id, brandId: brandStock.brandId, mardCode: brandStock.mardCode, stock: brandStock.stock, used: brandStock.used, isHidden: brandStock.isHidden)
    }

    func toStruct() -> BrandStock {
        BrandStock(id: id, brandId: brandId, mardCode: mardCode, stock: stock, used: used, isHidden: isHidden)
    }
}

// MARK: - 项目记录模型
@Model
final class SDProjectRecord {
    var id: UUID = UUID()
    var name: String = ""
    var date: Date = Date()
    var totalBeads: Int = 0
    var brandId: UUID?
    var isArchived: Bool = false
    var parentId: UUID?           // 父项目ID，nil表示顶级项目
    var isPlanned: Bool?          // 是否为计划项目（可选，nil视为false）
    var executedDate: Date?       // 执行日期
    var thumbnail: Data?          // 缩略图数据（可选，压缩后的JPEG）
    var finishedImage: Data?      // 成品图数据（可选，压缩后的JPEG，仅已执行项目使用）
    var completedDate: Date?      // 完成日期（用于日历展示）
    var colorSystemRaw: String?   // 色号体系，可选以兼容旧数据，默认为 MARD

    @Relationship(deleteRule: .cascade, inverse: \SDBeadUsage.project)
    var beadUsages: [SDBeadUsage]?

    // 计算属性：安全获取 isPlanned 值
    var isPlannedValue: Bool {
        isPlanned ?? false
    }

    init(id: UUID = UUID(), name: String, date: Date = Date(), totalBeads: Int = 0, brandId: UUID? = nil, isArchived: Bool = false, parentId: UUID? = nil, isPlanned: Bool = false, executedDate: Date? = nil, thumbnail: Data? = nil, finishedImage: Data? = nil, completedDate: Date? = nil, colorSystemRaw: String? = nil, beadUsages: [SDBeadUsage] = []) {
        self.id = id
        self.name = name
        self.date = date
        self.totalBeads = totalBeads
        self.brandId = brandId
        self.isArchived = isArchived
        self.parentId = parentId
        self.isPlanned = isPlanned
        self.executedDate = executedDate
        self.thumbnail = thumbnail
        self.finishedImage = finishedImage
        self.completedDate = completedDate
        self.colorSystemRaw = colorSystemRaw
        self.beadUsages = beadUsages
    }

    convenience init(from record: ProjectRecord) {
        let usages = record.beadUsage.map { SDBeadUsage(from: $0) }
        self.init(id: record.id, name: record.name, date: record.date, totalBeads: record.totalBeads, brandId: record.brandId, isArchived: record.isArchived, parentId: record.parentId, isPlanned: record.isPlanned, executedDate: record.executedDate, thumbnail: record.thumbnail, finishedImage: record.finishedImage, completedDate: record.completedDate, colorSystemRaw: record.colorSystem.rawValue, beadUsages: usages)
    }

    func toStruct() -> ProjectRecord {
        let usages = (beadUsages ?? []).map { $0.toStruct() }
        return ProjectRecord(id: id, name: name, date: date, beadUsage: usages, brandId: brandId, isArchived: isArchived, parentId: parentId, isPlanned: isPlannedValue, executedDate: executedDate, thumbnail: thumbnail, finishedImage: finishedImage, completedDate: completedDate, colorSystem: ColorSystem(rawValue: colorSystemRaw ?? "") ?? .mard)
    }
}

// MARK: - 单色用量模型
@Model
final class SDBeadUsage {
    var id: UUID = UUID()
    var colorCode: String = ""
    var brandId: UUID?
    var quantity: Int = 0
    var isDeducted: Bool = false
    var project: SDProjectRecord?

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

// MARK: - 自定义色号模型
@Model
final class SDCustomColor {
    var id: UUID = UUID()
    var colorCode: String = ""  // 用户定义的色号
    var colorHex: String = ""   // 颜色十六进制值
    var colorName: String = ""  // 颜色名称
    var createdAt: Date = Date()// 创建时间
    var updatedAt: Date = Date()// 更新时间

    init(
        id: UUID = UUID(),
        colorCode: String,
        colorHex: String,
        colorName: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.colorCode = colorCode
        self.colorHex = colorHex
        self.colorName = colorName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    convenience init(from customColor: CustomColor) {
        self.init(
            id: customColor.id,
            colorCode: customColor.colorCode,
            colorHex: customColor.colorHex,
            colorName: customColor.colorName,
            createdAt: customColor.createdAt,
            updatedAt: customColor.updatedAt
        )
    }

    func toStruct() -> CustomColor {
        CustomColor(
            id: id,
            colorCode: colorCode,
            colorHex: colorHex,
            colorName: colorName,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

// MARK: - 历史记录模型
@Model
final class SDHistoryRecord {
    var id: UUID = UUID()
    var timestamp: Date = Date()
    var operationType: String = ""   // 存储 HistoryOperationType.rawValue
    @Attribute(originalName: "entityName")
    var targetName: String = ""      // 注意：避免使用 entityName（与 SwiftData 系统属性冲突），使用 originalName 保持数据兼容
    var beforeSnapshot: Data?
    var afterSnapshot: Data?
    var isReverted: Bool = false

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        operationType: String,
        targetName: String,
        beforeSnapshot: Data? = nil,
        afterSnapshot: Data? = nil,
        isReverted: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.operationType = operationType
        self.targetName = targetName
        self.beforeSnapshot = beforeSnapshot
        self.afterSnapshot = afterSnapshot
        self.isReverted = isReverted
    }

    convenience init(from record: HistoryRecord) {
        self.init(
            id: record.id,
            timestamp: record.timestamp,
            operationType: record.operationType.rawValue,
            targetName: record.entityName,
            beforeSnapshot: record.beforeSnapshot,
            afterSnapshot: record.afterSnapshot,
            isReverted: record.isReverted
        )
    }

    func toStruct() -> HistoryRecord? {
        guard let opType = HistoryOperationType(rawValue: operationType) else {
            return nil
        }
        return HistoryRecord(
            id: id,
            timestamp: timestamp,
            operationType: opType,
            entityName: targetName,
            beforeSnapshot: beforeSnapshot,
            afterSnapshot: afterSnapshot,
            isReverted: isReverted
        )
    }
}
