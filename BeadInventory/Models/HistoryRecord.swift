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
        case .brandAdd: return "添加品牌"
        case .brandUpdate: return "修改品牌"
        case .brandDelete: return "删除品牌"
        case .stockAdd: return "增加库存"
        case .stockUpdate: return "修改库存"
        case .stockDeduct: return "扣减库存"
        case .stockReset: return "重置库存"
        case .projectAdd: return "添加项目"
        case .projectDelete: return "删除项目"
        case .projectArchive: return "归档项目"
        case .projectUnarchive: return "取消归档"
        case .projectMerge: return "合并项目"
        case .planAdd: return "添加计划"
        case .planExecute: return "执行计划"
        case .planDelete: return "删除计划"
        case .planUpdate: return "修改计划"
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
        case .brandUpdate, .stockUpdate, .planUpdate:
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

struct HistoryRecord: Identifiable, Codable {
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
