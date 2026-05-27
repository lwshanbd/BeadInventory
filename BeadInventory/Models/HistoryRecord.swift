//
//  HistoryRecord.swift
//  BeadInventory
//
//  历史记录模型 - 用于追踪所有数据操作并支持撤回
//

import Foundation

// MARK: - 操作类型

enum HistoryOperationType: String, Codable, CaseIterable {
    // 品牌操作
    case brandAdd = "brand_add"
    case brandUpdate = "brand_update"
    case brandDelete = "brand_delete"

    // 库存操作
    case stockAdd = "stock_add"
    case stockUpdate = "stock_update"
    case stockDeduct = "stock_deduct"
    case stockReset = "stock_reset"

    // 项目操作
    case projectAdd = "project_add"
    case projectUpdate = "project_update"
    case projectDelete = "project_delete"
    case projectArchive = "project_archive"
    case projectUnarchive = "project_unarchive"
    case projectMerge = "project_merge"

    // 计划操作
    case planAdd = "plan_add"
    case planExecute = "plan_execute"
    case planDelete = "plan_delete"
    case planUpdate = "plan_update"

    // 显示名称
    var displayName: String {
        switch self {
        case .brandAdd: return String(localized: "添加品牌")
        case .brandUpdate: return String(localized: "修改品牌")
        case .brandDelete: return String(localized: "删除品牌")
        case .stockAdd: return String(localized: "增加库存")
        case .stockUpdate: return String(localized: "修改库存")
        case .stockDeduct: return String(localized: "扣减库存")
        case .stockReset: return String(localized: "重置库存")
        case .projectAdd: return String(localized: "添加项目")
        case .projectUpdate: return String(localized: "修改项目")
        case .projectDelete: return String(localized: "删除项目")
        case .projectArchive: return String(localized: "归档项目")
        case .projectUnarchive: return String(localized: "取消归档")
        case .projectMerge: return String(localized: "合并项目")
        case .planAdd: return String(localized: "添加计划")
        case .planExecute: return String(localized: "执行计划")
        case .planDelete: return String(localized: "删除计划")
        case .planUpdate: return String(localized: "修改计划")
        }
    }

    // 图标名称
    var iconName: String {
        switch self {
        case .brandAdd: return "plus.circle.fill"
        case .brandUpdate: return "pencil.circle.fill"
        case .brandDelete: return "minus.circle.fill"
        case .stockAdd: return "arrow.up.circle.fill"
        case .stockUpdate: return "arrow.left.arrow.right.circle.fill"
        case .stockDeduct: return "arrow.down.circle.fill"
        case .stockReset: return "arrow.counterclockwise.circle.fill"
        case .projectAdd: return "doc.badge.plus"
        case .projectUpdate: return "pencil.circle.fill"
        case .projectDelete: return "doc.badge.minus"
        case .projectArchive: return "archivebox.fill"
        case .projectUnarchive: return "archivebox"
        case .projectMerge: return "arrow.triangle.merge"
        case .planAdd: return "calendar.badge.plus"
        case .planExecute: return "checkmark.circle.fill"
        case .planDelete: return "calendar.badge.minus"
        case .planUpdate: return "calendar.badge.clock"
        }
    }

    // 图标颜色
    var iconColor: String {
        switch self {
        case .brandAdd, .stockAdd, .projectAdd, .planAdd:
            return "green"
        case .brandUpdate, .stockUpdate, .projectUpdate, .planUpdate:
            return "blue"
        case .brandDelete, .stockDeduct, .projectDelete, .planDelete:
            return "red"
        case .stockReset:
            return "orange"
        case .projectArchive:
            return "purple"
        case .projectUnarchive:
            return "indigo"
        case .projectMerge:
            return "teal"
        case .planExecute:
            return "green"
        }
    }
}

// MARK: - 历史记录模型

struct HistoryRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let operationType: HistoryOperationType
    let entityName: String           // 显示名称，如 "MARD" 或 "皮卡丘"
    let beforeSnapshot: Data?        // 操作前状态 (JSON)
    let afterSnapshot: Data?         // 操作后状态 (JSON)
    var isReverted: Bool             // 是否已撤回

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        operationType: HistoryOperationType,
        entityName: String,
        beforeSnapshot: Data? = nil,
        afterSnapshot: Data? = nil,
        isReverted: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.operationType = operationType
        self.entityName = entityName
        self.beforeSnapshot = beforeSnapshot
        self.afterSnapshot = afterSnapshot
        self.isReverted = isReverted
    }

    // 格式化时间戳
    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: timestamp)
    }

    // 格式化日期
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: timestamp)
    }

    // 完整描述
    var fullDescription: String {
        "\(operationType.displayName): \(entityName)"
    }
}

// MARK: - 库存变更快照

struct StockChangeSnapshot: Codable {
    let brandId: UUID
    let mardCode: String
    let oldValue: Int
    let newValue: Int
    let changeAmount: Int
}

// MARK: - 品牌快照

struct BrandSnapshot: Codable {
    let id: UUID
    let name: String
    let sortOrder: Int
}

// MARK: - 项目快照

struct ProjectSnapshot: Codable {
    let id: UUID
    let name: String
    let date: Date
    let totalBeads: Int
    let brandId: UUID?
    let isArchived: Bool
    let parentId: UUID?
    let isPlanned: Bool
    let executedDate: Date?
    let beadUsages: [BeadUsageSnapshot]
    let thumbnail: Data?
    let finishedImage: Data?
    let colorSystem: ColorSystem
    /// 该 snapshot 是否「为图片操作专门捕获了 thumbnail/finishedImage」。
    /// 自 v2.0.x 起 ProjectRecord 不再常驻这两个 Data 字段，普通的 metadata 改动（rename /
    /// completedDate 等）不会主动把 OLD 图取出来写进 snapshot，thumbnail/finishedImage
    /// 字段在新写入的 snapshot 里都是 nil。
    /// undo 路径必须靠这个标志判断：true 才允许从 snapshot 还原图片（image-update 的 undo），
    /// false / nil 一律跳过图片还原（避免把现存图清成 nil）。
    let capturesImages: Bool?
    /// `SDProjectRecord.patternGridData` 的原始字节。Destructive 路径（delete /
    /// planDelete / merge）捕获 OLD 网格，让 undo 重建 SwiftData 行后能用
    /// `_setProjectBlobsDirectly` 把网格写回。Image-update 路径不携带（grid 编辑
    /// 本身不进 history —— 见 `updateProjectPatternGrid` 注释）。
    /// 旧 record 没这个字段；按 `decodeIfPresent → nil` 兼容，相当于"不还原"。
    let patternGridData: Data?
    /// `ProjectRecord.completedDate` —— 已执行项目在日历上的"完成日期"。
    /// 之前漏在 snapshot 之外，导致 `updateProjectFinishedImage` 自动补的日期撤销
    /// 时还原不回去 + `updateProjectCompletedDate` 撤销整体 no-op。
    /// 旧 record 没这个字段；`decodeIfPresent → nil` 表示"撤销不动 completedDate"。
    let completedDate: Date?
    /// `ProjectRecord.displayThumbnail` —— 列表用的小 JPEG。Destructive 撤销时一并还原，
    /// 这样恢复的项目下次在列表里能立刻有小图（不用等迁移协调器重做）。旧 record 没这个字段；
    /// `decodeIfPresent → nil` 表示"还原后让迁移协调器现场 backfill"。
    let displayThumbnail: Data?

    // 自定义解码器，兼容旧数据
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        date = try container.decode(Date.self, forKey: .date)
        totalBeads = try container.decode(Int.self, forKey: .totalBeads)
        brandId = try container.decodeIfPresent(UUID.self, forKey: .brandId)
        isArchived = try container.decode(Bool.self, forKey: .isArchived)
        parentId = try container.decodeIfPresent(UUID.self, forKey: .parentId)
        isPlanned = try container.decode(Bool.self, forKey: .isPlanned)
        executedDate = try container.decodeIfPresent(Date.self, forKey: .executedDate)
        beadUsages = try container.decode([BeadUsageSnapshot].self, forKey: .beadUsages)
        // 向后兼容：旧数据没有这些字段
        thumbnail = try container.decodeIfPresent(Data.self, forKey: .thumbnail)
        finishedImage = try container.decodeIfPresent(Data.self, forKey: .finishedImage)
        colorSystem = try container.decodeIfPresent(ColorSystem.self, forKey: .colorSystem) ?? .mard
        // capturesImages 是 v2.0.x 新增字段；旧数据 = nil 视作 false。
        // 但旧 record 里的 thumbnail/finishedImage 可能是真实捕获的数据（旧版本逻辑总是带图），
        // 所以旧 record 的 undo 仍然保持「有数据就还原」语义，靠 thumbnail != nil 兜底。
        capturesImages = try container.decodeIfPresent(Bool.self, forKey: .capturesImages)
        // patternGridData / completedDate / displayThumbnail 都是新加字段。
        // 旧 record 没有 → 解为 nil → undo 时不写回这两个字段。
        patternGridData = try container.decodeIfPresent(Data.self, forKey: .patternGridData)
        completedDate = try container.decodeIfPresent(Date.self, forKey: .completedDate)
        displayThumbnail = try container.decodeIfPresent(Data.self, forKey: .displayThumbnail)
    }

    init(id: UUID, name: String, date: Date, totalBeads: Int, brandId: UUID?, isArchived: Bool, parentId: UUID?, isPlanned: Bool, executedDate: Date?, beadUsages: [BeadUsageSnapshot], thumbnail: Data? = nil, finishedImage: Data? = nil, colorSystem: ColorSystem = .mard, capturesImages: Bool? = nil, patternGridData: Data? = nil, completedDate: Date? = nil, displayThumbnail: Data? = nil) {
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
        self.thumbnail = thumbnail
        self.finishedImage = finishedImage
        self.colorSystem = colorSystem
        self.capturesImages = capturesImages
        self.patternGridData = patternGridData
        self.completedDate = completedDate
        self.displayThumbnail = displayThumbnail
    }
}

struct BeadUsageSnapshot: Codable {
    let colorCode: String
    let brandId: UUID?
    let quantity: Int
    let isDeducted: Bool
}

// MARK: - 合并快照（用于支持合并操作撤回）

struct MergeSnapshot: Codable {
    /// 合并前所有参与项目的状态
    let originalProjects: [ProjectSnapshot]
    /// 合并后新创建的父项目ID（如果有）
    let newParentId: UUID?
    /// 是否是简单合并（一个父项目 + 独立项目，不创建新父项目）
    let isSimpleMerge: Bool
    /// 原有父项目ID（仅用于简单合并情况）
    let existingParentId: UUID?
}

// MARK: - 计划删除快照（用于支持删除父项目时恢复子项目）

struct PlanDeleteSnapshot: Codable {
    /// 被删除的项目（父项目）
    let deletedProject: ProjectSnapshot
    /// 被级联删除的子项目
    let deletedChildren: [ProjectSnapshot]
}
