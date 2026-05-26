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
    // 关于这三个大 blob 字段为什么暂时**不**加 @Attribute(.externalStorage)：
    //
    // 注释里说是 JPEG，实际是 PNG（ScanView.generateThumbnailData /
    // ProjectDetailView 都存 PNG），单条可达 MB 级。理想形态是走 externalStorage
    // 让 blob 落成 .store_blob 旁路文件，但 SwiftData 的 lightweight migration
    // **不支持**「现存 inline BLOB → external file reference」自动迁移
    // （已验证：会抛 "Unable to use inferred mapping to move external reference into
    // store"，ModelContainer 初始化失败 → 全员升级即崩 → 退回本地模式丢 iCloud 同步）。
    // 真正引发 458 项目用户 jetsam 的根因是 InventoryManager.projects 缓存把全部
    // ProjectRecord 含 Data 物化进内存，本 PR 通过 toMetadataStruct + 按需取图已经
    // 解决；externalStorage 只是次级优化（SQLite 主 store 小一点 / CloudKit CKAsset），
    // 留作下一个 PR 配合 VersionedSchema + 显式 willMigrate/didMigrate 手工搬迁。
    var thumbnail: Data?          // 缩略图数据（PNG）
    var finishedImage: Data?      // 成品图数据（PNG，仅已执行项目使用）
    var completedDate: Date?      // 完成日期（用于日历展示）
    var colorSystemRaw: String?   // 色号体系，可选以兼容旧数据，默认为 MARD
    var patternGridData: Data?    // JSON 编码后的 BeadPatternGrid（拼图模式网格数据）

    @Relationship(deleteRule: .cascade, inverse: \SDBeadUsage.project)
    var beadUsages: [SDBeadUsage]? = []

    // 计算属性：安全获取 isPlanned 值
    var isPlannedValue: Bool {
        isPlanned ?? false
    }

    init(id: UUID = UUID(), name: String, date: Date = Date(), totalBeads: Int = 0, brandId: UUID? = nil, isArchived: Bool = false, parentId: UUID? = nil, isPlanned: Bool = false, executedDate: Date? = nil, thumbnail: Data? = nil, finishedImage: Data? = nil, completedDate: Date? = nil, colorSystemRaw: String? = nil, patternGridData: Data? = nil, beadUsages: [SDBeadUsage] = []) {
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
        self.patternGridData = patternGridData
        self.beadUsages = beadUsages
    }

    convenience init(from record: ProjectRecord) {
        let usages = record.beadUsage.map { SDBeadUsage(from: $0) }
        let gridData = SDProjectRecord.encodePatternGrid(record.patternGrid, projectId: record.id)
        self.init(id: record.id, name: record.name, date: record.date, totalBeads: record.totalBeads, brandId: record.brandId, isArchived: record.isArchived, parentId: record.parentId, isPlanned: record.isPlanned, executedDate: record.executedDate, thumbnail: record.thumbnail, finishedImage: record.finishedImage, completedDate: record.completedDate, colorSystemRaw: record.colorSystem.rawValue, patternGridData: gridData, beadUsages: usages)
    }

    /// 完整版转换：读取 thumbnail / finishedImage / patternGridData 三个大 blob 字段。
    /// 仅用于一次性需要全数据的路径（备份导出、详情页全屏图、history 快照前快照存档等）。
    /// **不要**在 InventoryManager.projects 这种全表缓存里调用 —— 用 toMetadataStruct()。
    func toStruct() -> ProjectRecord {
        let usages = (beadUsages ?? []).map { $0.toStruct() }
        let grid = SDProjectRecord.decodePatternGrid(patternGridData, projectId: id)
        return ProjectRecord(
            id: id,
            name: name,
            date: date,
            beadUsage: usages,
            totalBeads: totalBeads,
            brandId: brandId,
            isArchived: isArchived,
            parentId: parentId,
            isPlanned: isPlannedValue,
            executedDate: executedDate,
            thumbnail: thumbnail,
            finishedImage: finishedImage,
            completedDate: completedDate,
            colorSystem: ColorSystem(rawValue: colorSystemRaw ?? "") ?? .mard,
            patternGrid: grid
        )
    }

    /// 轻量版转换：metadata + beadUsages，但**不读** thumbnail / finishedImage / patternGridData。
    /// 用于 InventoryManager.projects 全表缓存 —— 458 项目时把内存峰值从 ~200MB 砍到 ~MB 级。
    /// 视图需要图片时走 InventoryManager.fetchProjectThumbnailData / fetchProjectFinishedImageData 按需取。
    /// 注意：调用方在 saveData 路径上必须用对应的轻量 diff，避免把 nil blob 写回覆盖云端真数据。
    func toMetadataStruct() -> ProjectRecord {
        let usages = (beadUsages ?? []).map { $0.toStruct() }
        return ProjectRecord(
            id: id,
            name: name,
            date: date,
            beadUsage: usages,
            totalBeads: totalBeads,
            brandId: brandId,
            isArchived: isArchived,
            parentId: parentId,
            isPlanned: isPlannedValue,
            executedDate: executedDate,
            thumbnail: nil,
            finishedImage: nil,
            completedDate: completedDate,
            colorSystem: ColorSystem(rawValue: colorSystemRaw ?? "") ?? .mard,
            patternGrid: nil
        )
    }

    /// 把 BeadPatternGrid 编码成持久化用的 JSON Data。失败时返回 nil 并记日志，
    /// 调用方应自行判断是否覆盖已有数据（iCloud 同步路径应保留 last-known-good）。
    static func encodePatternGrid(_ grid: BeadPatternGrid?, projectId: UUID) -> Data? {
        guard let grid else { return nil }
        do {
            return try JSONEncoder().encode(grid)
        } catch {
            AppLogger.shared.error(
                "SDProjectRecord",
                "patternGrid_encode_failed",
                metadata: [
                    "projectId": projectId.uuidString,
                    "error": "\(error)"
                ]
            )
            return nil
        }
    }

    /// 从持久化 JSON Data 解码 BeadPatternGrid。失败时返回 nil 并记日志，
    /// 调用方收到 nil 时不应改写 SwiftData 的 patternGridData（防止覆盖损坏后再丢数据）。
    static func decodePatternGrid(_ data: Data?, projectId: UUID) -> BeadPatternGrid? {
        guard let data else { return nil }
        do {
            return try JSONDecoder().decode(BeadPatternGrid.self, from: data)
        } catch {
            AppLogger.shared.error(
                "SDProjectRecord",
                "patternGrid_decode_failed",
                metadata: [
                    "projectId": projectId.uuidString,
                    "bytes": data.count,
                    "error": "\(error)"
                ]
            )
            return nil
        }
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
    // before / afterSnapshot 是 ProjectRecord (含图) 的 JSON 编码；可达数 MB。
    // 同样**不**加 @Attribute(.externalStorage) —— 升级路径上自动 lightweight migration
    // 不支持把 inline BLOB 搬迁到外部存储（详见 SDProjectRecord.thumbnail 注释）。
    // 真正的内存控制靠 capturesImages 标志 + image-update 路径才回填 OLD 图，
    // metadata-only 操作的 snapshot JSON 不再带图，已经把单条 snapshot 大小压回 KB 级。
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

// MARK: - 色彩主题模型
@Model
final class SDColorScheme {
    // CloudKit does not support .unique; uniqueness is guaranteed by UUID()
    // for user themes and by bootstrapBuiltinPresets' fetch-by-id upsert for builtins.
    var id: UUID = UUID()
    var name: String = ""
    var lightBgHex:     String = "FAF5EC"
    var lightBgElevHex: String = "FFFDF8"
    var darkBgHex:      String = "1B1714"
    var darkBgElevHex:  String = "25201B"
    var isBuiltin: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        name: String,
        lightBgHex: String,
        lightBgElevHex: String,
        darkBgHex: String,
        darkBgElevHex: String,
        isBuiltin: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.lightBgHex = lightBgHex
        self.lightBgElevHex = lightBgElevHex
        self.darkBgHex = darkBgHex
        self.darkBgElevHex = darkBgElevHex
        self.isBuiltin = isBuiltin
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    convenience init(from scheme: AppColorScheme) {
        self.init(
            id: scheme.id,
            name: scheme.name,
            lightBgHex: scheme.light.bg,
            lightBgElevHex: scheme.light.bgElev,
            darkBgHex: scheme.dark.bg,
            darkBgElevHex: scheme.dark.bgElev,
            isBuiltin: scheme.isBuiltin,
            createdAt: scheme.createdAt,
            updatedAt: scheme.updatedAt
        )
    }

    func toStruct() -> AppColorScheme {
        AppColorScheme(
            id: id,
            name: name,
            light: ColorPalette(bg: lightBgHex, bgElev: lightBgElevHex),
            dark:  ColorPalette(bg: darkBgHex,  bgElev: darkBgElevHex),
            isBuiltin: isBuiltin,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
