//
//  HistoryManager.swift
//  BeadInventory
//
//  历史记录管理器 - 记录所有数据操作并支持撤回
//

import Foundation
import SwiftUI
import SwiftData

class HistoryManager: ObservableObject {
    static let shared = HistoryManager()

    @Published var records: [HistoryRecord] = []

    // SwiftData ModelContext
    private var modelContext: ModelContext?

    // 最大记录数
    private let maxRecords = 100

    // 对 InventoryManager 的引用（用于撤回操作）
    weak var inventoryManager: InventoryManager?

    private init() {}

    // 设置 ModelContext
    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
        loadData()
    }

    // MARK: - 记录操作

    /// 记录一个操作
    func record(
        type: HistoryOperationType,
        entityName: String,
        before: (any Encodable)? = nil,
        after: (any Encodable)? = nil
    ) {
        let beforeData = before.flatMap { try? JSONEncoder().encode(AnyEncodable($0)) }
        let afterData = after.flatMap { try? JSONEncoder().encode(AnyEncodable($0)) }

        let record = HistoryRecord(
            operationType: type,
            entityName: entityName,
            beforeSnapshot: beforeData,
            afterSnapshot: afterData
        )

        records.insert(record, at: 0)
        trimRecords()
        saveData()

        print("[History] 记录操作: \(type.displayName) - \(entityName)")
    }

    /// 记录库存变更
    func recordStockChange(
        type: HistoryOperationType,
        brandId: UUID,
        mardCode: String,
        oldValue: Int,
        newValue: Int,
        changeAmount: Int
    ) {
        let snapshot = StockChangeSnapshot(
            brandId: brandId,
            mardCode: mardCode,
            oldValue: oldValue,
            newValue: newValue,
            changeAmount: changeAmount
        )

        let beforeData = try? JSONEncoder().encode(snapshot)

        let record = HistoryRecord(
            operationType: type,
            entityName: mardCode,
            beforeSnapshot: beforeData,
            afterSnapshot: nil
        )

        records.insert(record, at: 0)
        trimRecords()
        saveData()

        print("[History] 记录库存变更: \(type.displayName) - \(mardCode) (\(oldValue) -> \(newValue))")
    }

    /// 记录品牌操作
    func recordBrand(
        type: HistoryOperationType,
        brand: Brand,
        oldName: String? = nil
    ) {
        let snapshot = BrandSnapshot(id: brand.id, name: brand.name, sortOrder: brand.sortOrder)
        let beforeData: Data?
        let afterData: Data?

        switch type {
        case .brandAdd:
            beforeData = nil
            afterData = try? JSONEncoder().encode(snapshot)
        case .brandUpdate:
            let oldSnapshot = BrandSnapshot(id: brand.id, name: oldName ?? brand.name, sortOrder: brand.sortOrder)
            beforeData = try? JSONEncoder().encode(oldSnapshot)
            afterData = try? JSONEncoder().encode(snapshot)
        case .brandDelete:
            beforeData = try? JSONEncoder().encode(snapshot)
            afterData = nil
        default:
            beforeData = nil
            afterData = nil
        }

        let record = HistoryRecord(
            operationType: type,
            entityName: brand.name,
            beforeSnapshot: beforeData,
            afterSnapshot: afterData
        )

        records.insert(record, at: 0)
        trimRecords()
        saveData()

        print("[History] 记录品牌操作: \(type.displayName) - \(brand.name)")
    }

    /// 记录项目操作
    func recordProject(
        type: HistoryOperationType,
        project: ProjectRecord
    ) {
        let usageSnapshots = project.beadUsage.map {
            BeadUsageSnapshot(colorCode: $0.colorCode, brandId: $0.brandId, quantity: $0.quantity, isDeducted: $0.isDeducted)
        }

        let snapshot = ProjectSnapshot(
            id: project.id,
            name: project.name,
            date: project.date,
            totalBeads: project.totalBeads,
            brandId: project.brandId,
            isArchived: project.isArchived,
            parentId: project.parentId,
            isPlanned: project.isPlanned,
            executedDate: project.executedDate,
            beadUsages: usageSnapshots
        )

        let snapshotData = try? JSONEncoder().encode(snapshot)

        let beforeData: Data?
        let afterData: Data?

        switch type {
        case .projectAdd, .planAdd:
            beforeData = nil
            afterData = snapshotData
        case .projectDelete, .planDelete:
            beforeData = snapshotData
            afterData = nil
        case .projectArchive, .projectUnarchive, .planExecute, .planUpdate:
            beforeData = snapshotData
            afterData = snapshotData
        default:
            beforeData = nil
            afterData = nil
        }

        let record = HistoryRecord(
            operationType: type,
            entityName: project.name,
            beforeSnapshot: beforeData,
            afterSnapshot: afterData
        )

        records.insert(record, at: 0)
        trimRecords()
        saveData()

        print("[History] 记录项目操作: \(type.displayName) - \(project.name)")
    }

    // MARK: - 撤回操作

    /// 撤回一个操作
    @discardableResult
    func revert(_ recordId: UUID) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == recordId }) else {
            print("[History] 找不到记录: \(recordId)")
            return false
        }

        let record = records[index]

        if record.isReverted {
            print("[History] 记录已撤回: \(record.fullDescription)")
            return false
        }

        guard let manager = inventoryManager else {
            print("[History] InventoryManager 未设置")
            return false
        }

        let success = performRevert(record: record, manager: manager)

        if success {
            records[index].isReverted = true
            saveData()
            print("[History] 撤回成功: \(record.fullDescription)")
        } else {
            print("[History] 撤回失败: \(record.fullDescription)")
        }

        return success
    }

    private func performRevert(record: HistoryRecord, manager: InventoryManager) -> Bool {
        switch record.operationType {
        // 品牌操作撤回
        case .brandAdd:
            // 撤回添加 = 删除
            if let afterData = record.afterSnapshot,
               let snapshot = try? JSONDecoder().decode(BrandSnapshot.self, from: afterData) {
                return manager.deleteBrand(snapshot.id)
            }
            return false

        case .brandUpdate:
            // 撤回修改 = 恢复旧名称
            if let beforeData = record.beforeSnapshot,
               let snapshot = try? JSONDecoder().decode(BrandSnapshot.self, from: beforeData) {
                manager.updateBrand(snapshot.id, name: snapshot.name)
                return true
            }
            return false

        case .brandDelete:
            // 撤回删除 = 重新创建
            if let beforeData = record.beforeSnapshot,
               let snapshot = try? JSONDecoder().decode(BrandSnapshot.self, from: beforeData) {
                manager.addBrand(name: snapshot.name)
                return true
            }
            return false

        // 库存操作撤回
        case .stockAdd:
            // 撤回增加 = 减少
            if let beforeData = record.beforeSnapshot,
               let snapshot = try? JSONDecoder().decode(StockChangeSnapshot.self, from: beforeData) {
                manager.addStock(brandId: snapshot.brandId, mardCode: snapshot.mardCode, amount: -snapshot.changeAmount)
                return true
            }
            return false

        case .stockUpdate:
            // 撤回修改 = 恢复旧值
            if let beforeData = record.beforeSnapshot,
               let snapshot = try? JSONDecoder().decode(StockChangeSnapshot.self, from: beforeData) {
                manager.updateStock(brandId: snapshot.brandId, mardCode: snapshot.mardCode, newStock: snapshot.oldValue)
                return true
            }
            return false

        case .stockDeduct:
            // 撤回扣减 = 加回
            if let beforeData = record.beforeSnapshot,
               let snapshot = try? JSONDecoder().decode(StockChangeSnapshot.self, from: beforeData) {
                manager.addStock(brandId: snapshot.brandId, mardCode: snapshot.mardCode, amount: snapshot.changeAmount)
                return true
            }
            return false

        case .stockReset:
            // 库存重置不支持撤回（影响太大）
            return false

        // 项目操作撤回
        case .projectAdd:
            // 撤回添加 = 删除
            if let afterData = record.afterSnapshot,
               let snapshot = try? JSONDecoder().decode(ProjectSnapshot.self, from: afterData) {
                manager.deleteProject(id: snapshot.id)
                return true
            }
            return false

        case .projectDelete:
            // 撤回删除 = 从快照恢复
            if let beforeData = record.beforeSnapshot,
               let snapshot = try? JSONDecoder().decode(ProjectSnapshot.self, from: beforeData) {
                let project = restoreProject(from: snapshot)
                manager.addProject(project)
                return true
            }
            return false

        case .projectArchive:
            // 撤回归档 = 取消归档
            if let beforeData = record.beforeSnapshot,
               let snapshot = try? JSONDecoder().decode(ProjectSnapshot.self, from: beforeData) {
                manager.unarchiveProject(id: snapshot.id)
                return true
            }
            return false

        case .projectUnarchive:
            // 撤回取消归档 = 重新归档
            if let beforeData = record.beforeSnapshot,
               let snapshot = try? JSONDecoder().decode(ProjectSnapshot.self, from: beforeData) {
                manager.archiveProject(id: snapshot.id)
                return true
            }
            return false

        case .projectMerge:
            // 合并不支持撤回（太复杂）
            return false

        // 计划操作撤回
        case .planAdd:
            // 撤回添加 = 删除
            if let afterData = record.afterSnapshot,
               let snapshot = try? JSONDecoder().decode(ProjectSnapshot.self, from: afterData) {
                manager.deletePlannedProject(snapshot.id)
                return true
            }
            return false

        case .planExecute:
            // 执行计划的撤回比较复杂，需要恢复库存和状态
            // 暂不支持
            return false

        case .planDelete:
            // 撤回删除 = 从快照恢复
            if let beforeData = record.beforeSnapshot,
               let snapshot = try? JSONDecoder().decode(ProjectSnapshot.self, from: beforeData) {
                let project = restoreProject(from: snapshot)
                manager.addPlannedProject(project)
                return true
            }
            return false

        case .planUpdate:
            // 撤回修改 = 恢复旧名称
            if let beforeData = record.beforeSnapshot,
               let snapshot = try? JSONDecoder().decode(ProjectSnapshot.self, from: beforeData) {
                manager.updatePlannedProjectName(snapshot.id, newName: snapshot.name)
                return true
            }
            return false
        }
    }

    private func restoreProject(from snapshot: ProjectSnapshot) -> ProjectRecord {
        let usages = snapshot.beadUsages.map {
            BeadUsage(colorCode: $0.colorCode, brandId: $0.brandId, quantity: $0.quantity, isDeducted: $0.isDeducted)
        }

        return ProjectRecord(
            id: snapshot.id,
            name: snapshot.name,
            date: snapshot.date,
            beadUsage: usages,
            brandId: snapshot.brandId,
            isArchived: snapshot.isArchived,
            parentId: snapshot.parentId,
            isPlanned: snapshot.isPlanned,
            executedDate: snapshot.executedDate
        )
    }

    // MARK: - 数据持久化

    private func trimRecords() {
        if records.count > maxRecords {
            records = Array(records.prefix(maxRecords))
        }
    }

    func loadData() {
        guard let context = modelContext else {
            print("[History] ModelContext 未设置，无法加载数据")
            return
        }

        do {
            let descriptor = FetchDescriptor<SDHistoryRecord>(
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
            )
            let sdRecords = try context.fetch(descriptor)
            records = sdRecords.compactMap { $0.toStruct() }
            print("[History] 加载了 \(records.count) 条历史记录")
        } catch {
            print("[History] 加载历史记录失败: \(error)")
        }
    }

    func saveData() {
        guard let context = modelContext else {
            print("[History] ModelContext 未设置，无法保存数据")
            return
        }

        do {
            // 删除所有旧记录
            let descriptor = FetchDescriptor<SDHistoryRecord>()
            let existing = try context.fetch(descriptor)
            for record in existing {
                context.delete(record)
            }

            // 插入新记录
            for record in records {
                let sdRecord = SDHistoryRecord(from: record)
                context.insert(sdRecord)
            }

            try context.save()
            print("[History] 保存了 \(records.count) 条历史记录")
        } catch {
            print("[History] 保存历史记录失败: \(error)")
        }
    }

    /// 清空所有历史记录
    func clearAll() {
        records.removeAll()
        saveData()
    }

    // MARK: - 分组辅助

    /// 按日期分组的记录
    var groupedRecords: [(String, [HistoryRecord])] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        var groups: [String: [HistoryRecord]] = [:]

        for record in records {
            let recordDate = calendar.startOfDay(for: record.timestamp)
            let key: String

            if recordDate == today {
                key = "今天"
            } else if recordDate == yesterday {
                key = "昨天"
            } else {
                let formatter = DateFormatter()
                formatter.dateFormat = "MM月dd日"
                key = formatter.string(from: record.timestamp)
            }

            if groups[key] == nil {
                groups[key] = []
            }
            groups[key]?.append(record)
        }

        // 排序：今天 > 昨天 > 其他日期（按时间倒序）
        let sortedKeys = groups.keys.sorted { key1, key2 in
            if key1 == "今天" { return true }
            if key2 == "今天" { return false }
            if key1 == "昨天" { return true }
            if key2 == "昨天" { return false }
            return key1 > key2
        }

        return sortedKeys.map { ($0, groups[$0] ?? []) }
    }
}

// MARK: - 辅助类型

private struct AnyEncodable: Encodable {
    private let encode: (Encoder) throws -> Void

    init<T: Encodable>(_ wrapped: T) {
        self.encode = wrapped.encode
    }

    func encode(to encoder: Encoder) throws {
        try encode(encoder)
    }
}
