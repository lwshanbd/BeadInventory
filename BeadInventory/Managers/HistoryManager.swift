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

    // 是否正在执行撤回操作（撤回时不记录新的历史）
    private var isReverting = false

    // 数据加载完成标志
    private var isDataLoaded = false

    // 防抖保存：避免频繁调用 saveData 导致 SwiftData 崩溃
    private var saveWorkItem: DispatchWorkItem?
    private var pendingSave = false

    // 保存基线：用于同步场景下避免“全量重写”造成互相覆盖
    private var baselineRecordsByID: [UUID: HistoryRecord] = [:]

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
        // 撤回操作时不记录新的历史
        guard !isReverting else { return }

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
        // 撤回操作时不记录新的历史
        guard !isReverting else { return }

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
        // 撤回操作时不记录新的历史
        guard !isReverting else { return }

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
        // 撤回操作时不记录新的历史
        guard !isReverting else { return }

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
            beadUsages: usageSnapshots,
            thumbnail: project.thumbnail,
            finishedImage: project.finishedImage,
            colorSystem: project.colorSystem
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
        case .projectArchive, .projectUnarchive, .planUpdate:
            beforeData = snapshotData
            afterData = snapshotData
        case .planExecute:
            // planExecute 应该使用 recordPlanExecute 方法
            // 这里保持向后兼容，但快照不完整
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

    /// 记录计划执行操作（需要同时保存执行前和执行后的状态）
    func recordPlanExecute(
        beforeProject: ProjectRecord,
        afterProject: ProjectRecord
    ) {
        // 撤回操作时不记录新的历史
        guard !isReverting else { return }

        // 执行前快照
        let beforeUsages = beforeProject.beadUsage.map {
            BeadUsageSnapshot(colorCode: $0.colorCode, brandId: $0.brandId, quantity: $0.quantity, isDeducted: $0.isDeducted)
        }
        let beforeSnapshot = ProjectSnapshot(
            id: beforeProject.id,
            name: beforeProject.name,
            date: beforeProject.date,
            totalBeads: beforeProject.totalBeads,
            brandId: beforeProject.brandId,
            isArchived: beforeProject.isArchived,
            parentId: beforeProject.parentId,
            isPlanned: beforeProject.isPlanned,
            executedDate: beforeProject.executedDate,
            beadUsages: beforeUsages,
            thumbnail: beforeProject.thumbnail,
            finishedImage: beforeProject.finishedImage,
            colorSystem: beforeProject.colorSystem
        )

        // 执行后快照
        let afterUsages = afterProject.beadUsage.map {
            BeadUsageSnapshot(colorCode: $0.colorCode, brandId: $0.brandId, quantity: $0.quantity, isDeducted: $0.isDeducted)
        }
        let afterSnapshot = ProjectSnapshot(
            id: afterProject.id,
            name: afterProject.name,
            date: afterProject.date,
            totalBeads: afterProject.totalBeads,
            brandId: afterProject.brandId,
            isArchived: afterProject.isArchived,
            parentId: afterProject.parentId,
            isPlanned: afterProject.isPlanned,
            executedDate: afterProject.executedDate,
            beadUsages: afterUsages,
            thumbnail: afterProject.thumbnail,
            finishedImage: afterProject.finishedImage,
            colorSystem: afterProject.colorSystem
        )

        let beforeData = try? JSONEncoder().encode(beforeSnapshot)
        let afterData = try? JSONEncoder().encode(afterSnapshot)

        let record = HistoryRecord(
            operationType: .planExecute,
            entityName: afterProject.name,
            beforeSnapshot: beforeData,
            afterSnapshot: afterData
        )

        records.insert(record, at: 0)
        trimRecords()
        saveData()

        print("[History] 记录计划执行: \(afterProject.name)")
    }

    /// 记录项目合并操作
    func recordProjectMerge(
        originalProjects: [ProjectRecord],
        newParentId: UUID?,
        isSimpleMerge: Bool,
        existingParentId: UUID?,
        mergedName: String
    ) {
        // 撤回操作时不记录新的历史
        guard !isReverting else { return }

        // 为所有原始项目创建快照
        let projectSnapshots = originalProjects.map { project -> ProjectSnapshot in
            let usageSnapshots = project.beadUsage.map {
                BeadUsageSnapshot(colorCode: $0.colorCode, brandId: $0.brandId, quantity: $0.quantity, isDeducted: $0.isDeducted)
            }
            return ProjectSnapshot(
                id: project.id,
                name: project.name,
                date: project.date,
                totalBeads: project.totalBeads,
                brandId: project.brandId,
                isArchived: project.isArchived,
                parentId: project.parentId,
                isPlanned: project.isPlanned,
                executedDate: project.executedDate,
                beadUsages: usageSnapshots,
                thumbnail: project.thumbnail,
                finishedImage: project.finishedImage,
                colorSystem: project.colorSystem
            )
        }

        let mergeSnapshot = MergeSnapshot(
            originalProjects: projectSnapshots,
            newParentId: newParentId,
            isSimpleMerge: isSimpleMerge,
            existingParentId: existingParentId
        )

        let snapshotData = try? JSONEncoder().encode(mergeSnapshot)

        let record = HistoryRecord(
            operationType: .projectMerge,
            entityName: mergedName,
            beforeSnapshot: snapshotData,
            afterSnapshot: nil
        )

        records.insert(record, at: 0)
        trimRecords()
        saveData()

        print("[History] 记录项目合并: \(mergedName) (包含 \(originalProjects.count) 个项目)")
    }

    /// 记录计划删除操作（包含父项目及其子项目）
    func recordPlanDelete(
        project: ProjectRecord,
        children: [ProjectRecord]
    ) {
        // 撤回操作时不记录新的历史
        guard !isReverting else { return }

        // 创建父项目快照
        let projectUsages = project.beadUsage.map {
            BeadUsageSnapshot(colorCode: $0.colorCode, brandId: $0.brandId, quantity: $0.quantity, isDeducted: $0.isDeducted)
        }
        let projectSnapshot = ProjectSnapshot(
            id: project.id,
            name: project.name,
            date: project.date,
            totalBeads: project.totalBeads,
            brandId: project.brandId,
            isArchived: project.isArchived,
            parentId: project.parentId,
            isPlanned: project.isPlanned,
            executedDate: project.executedDate,
            beadUsages: projectUsages,
            thumbnail: project.thumbnail,
            finishedImage: project.finishedImage,
            colorSystem: project.colorSystem
        )

        // 创建子项目快照
        let childSnapshots = children.map { child -> ProjectSnapshot in
            let childUsages = child.beadUsage.map {
                BeadUsageSnapshot(colorCode: $0.colorCode, brandId: $0.brandId, quantity: $0.quantity, isDeducted: $0.isDeducted)
            }
            return ProjectSnapshot(
                id: child.id,
                name: child.name,
                date: child.date,
                totalBeads: child.totalBeads,
                brandId: child.brandId,
                isArchived: child.isArchived,
                parentId: child.parentId,
                isPlanned: child.isPlanned,
                executedDate: child.executedDate,
                beadUsages: childUsages,
                thumbnail: child.thumbnail,
                finishedImage: child.finishedImage,
                colorSystem: child.colorSystem
            )
        }

        let deleteSnapshot = PlanDeleteSnapshot(
            deletedProject: projectSnapshot,
            deletedChildren: childSnapshots
        )

        let snapshotData = try? JSONEncoder().encode(deleteSnapshot)

        let record = HistoryRecord(
            operationType: .planDelete,
            entityName: project.name,
            beforeSnapshot: snapshotData,
            afterSnapshot: nil
        )

        records.insert(record, at: 0)
        trimRecords()
        saveData()

        if children.isEmpty {
            print("[History] 记录计划删除: \(project.name)")
        } else {
            print("[History] 记录计划删除: \(project.name) (包含 \(children.count) 个子项目)")
        }
    }

    // MARK: - 撤回操作

    /// 检查某个记录是否可以撤回
    @MainActor func canRevert(_ record: HistoryRecord) -> Bool {
        switch record.operationType {
        case .stockReset:
            // 库存重置不支持撤回
            return false

        case .projectMerge:
            // 检查是否有合并快照
            guard let beforeData = record.beforeSnapshot,
                  let _ = try? JSONDecoder().decode(MergeSnapshot.self, from: beforeData) else {
                return false
            }
            return true

        case .planExecute:
            // 现在支持撤回执行操作
            // 检查是否有足够的快照信息
            guard let afterData = record.afterSnapshot,
                  let afterSnapshot = try? JSONDecoder().decode(ProjectSnapshot.self, from: afterData),
                  afterSnapshot.brandId != nil else {
                return false
            }
            // 检查项目是否还存在
            guard let manager = inventoryManager,
                  manager.projects.contains(where: { $0.id == afterSnapshot.id }) else {
                return false
            }
            return true

        case .planAdd:
            // 如果计划已执行，不能直接撤回添加计划
            guard let afterData = record.afterSnapshot,
                  let snapshot = try? JSONDecoder().decode(ProjectSnapshot.self, from: afterData) else {
                return false
            }
            // 检查项目当前状态
            if let manager = inventoryManager,
               let currentProject = manager.projects.first(where: { $0.id == snapshot.id }) {
                if !currentProject.isPlanned {
                    // 项目已执行，不能撤回添加计划
                    return false
                }
            }
            return true

        default:
            return true
        }
    }

    /// 获取不能撤回的原因
    @MainActor func revertDisabledReason(_ record: HistoryRecord) -> String? {
        switch record.operationType {
        case .stockReset:
            return String(localized: "库存重置影响范围太大，不支持撤回")
        case .projectMerge:
            // 检查是否有合并快照
            if record.beforeSnapshot == nil {
                return String(localized: "缺少合并快照，无法撤回（旧版本记录）")
            }
            if let beforeData = record.beforeSnapshot,
               (try? JSONDecoder().decode(MergeSnapshot.self, from: beforeData)) == nil {
                return String(localized: "合并快照格式无效，无法撤回")
            }
            return nil
        case .planAdd:
            if let afterData = record.afterSnapshot,
               let snapshot = try? JSONDecoder().decode(ProjectSnapshot.self, from: afterData),
               let manager = inventoryManager,
               let currentProject = manager.projects.first(where: { $0.id == snapshot.id }),
               !currentProject.isPlanned {
                return String(localized: "计划已执行，请先撤回「执行计划」操作")
            }
            return nil
        case .planExecute:
            if let afterData = record.afterSnapshot,
               let afterSnapshot = try? JSONDecoder().decode(ProjectSnapshot.self, from: afterData) {
                if afterSnapshot.brandId == nil {
                    return String(localized: "缺少品牌信息，无法撤回")
                }
                if let manager = inventoryManager,
                   !manager.projects.contains(where: { $0.id == afterSnapshot.id }) {
                    return String(localized: "项目已被删除，无法撤回")
                }
            }
            return nil
        default:
            return nil
        }
    }

    /// 撤回一个操作
    @discardableResult
    @MainActor func revert(_ recordId: UUID) -> Bool {
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

        // 设置撤回标志，防止撤回操作被记录为新的历史
        isReverting = true
        let success = performRevert(record: record, manager: manager)
        isReverting = false

        if success {
            // 撤回成功后直接删除该记录
            records.remove(at: index)
            saveData()
            print("[History] 撤回成功并删除记录: \(record.fullDescription)")
        } else {
            print("[History] 撤回失败: \(record.fullDescription)")
        }

        return success
    }

    @MainActor private func performRevert(record: HistoryRecord, manager: InventoryManager) -> Bool {
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

        case .projectUpdate:
            // 撤回项目修改 = 恢复旧快照（目前主要是缩略图/成品图修改）
            if let beforeData = record.beforeSnapshot,
               let snapshot = try? JSONDecoder().decode(ProjectSnapshot.self, from: beforeData) {
                // 恢复缩略图
                manager.updateProjectThumbnail(snapshot.id, thumbnail: snapshot.thumbnail)
                // 恢复成品图
                manager.updateProjectFinishedImage(snapshot.id, finishedImage: snapshot.finishedImage)
                return true
            }
            return false

        case .projectMerge:
            // 撤回合并 = 恢复所有原始项目的状态
            guard let beforeData = record.beforeSnapshot,
                  let mergeSnapshot = try? JSONDecoder().decode(MergeSnapshot.self, from: beforeData) else {
                print("[History] 无法撤回合并：缺少合并快照")
                return false
            }
            return manager.revertProjectMerge(mergeSnapshot: mergeSnapshot)

        // 计划操作撤回
        case .planAdd:
            // 撤回添加 = 删除（但需要检查是否已执行）
            if let afterData = record.afterSnapshot,
               let snapshot = try? JSONDecoder().decode(ProjectSnapshot.self, from: afterData) {
                // 检查项目当前是否已执行
                if let currentProject = manager.projects.first(where: { $0.id == snapshot.id }) {
                    if !currentProject.isPlanned {
                        // 项目已执行，不能直接撤回添加计划，需要先撤回执行
                        print("[History] 计划已执行，请先撤回执行操作")
                        return false
                    }
                }
                manager.deletePlannedProject(snapshot.id)
                return true
            }
            return false

        case .planExecute:
            // 撤回执行 = 恢复库存 + 恢复项目状态
            if let afterData = record.afterSnapshot,
               let afterSnapshot = try? JSONDecoder().decode(ProjectSnapshot.self, from: afterData) {
                // 使用执行后快照中的 brandId 和 beadUsages
                guard let brandId = afterSnapshot.brandId else {
                    print("[History] 无法撤回执行：缺少品牌信息")
                    return false
                }

                // 提取需要恢复的库存信息
                let beadUsages = afterSnapshot.beadUsages.map { (colorCode: $0.colorCode, quantity: $0.quantity) }

                // 调用 InventoryManager 的撤回方法
                return manager.revertPlanExecute(
                    projectId: afterSnapshot.id,
                    brandId: brandId,
                    beadUsages: beadUsages
                )
            }
            return false

        case .planDelete:
            // 撤回删除 = 从快照恢复
            guard let beforeData = record.beforeSnapshot else { return false }

            // 尝试新格式（包含子项目）
            if let deleteSnapshot = try? JSONDecoder().decode(PlanDeleteSnapshot.self, from: beforeData) {
                // 先恢复父项目
                let parentProject = restoreProject(from: deleteSnapshot.deletedProject)
                manager.addPlannedProject(parentProject)

                // 再恢复所有子项目
                for childSnapshot in deleteSnapshot.deletedChildren {
                    let childProject = restoreProject(from: childSnapshot)
                    manager.addPlannedProject(childProject)
                }

                print("[History] 恢复计划: \(parentProject.name) (包含 \(deleteSnapshot.deletedChildren.count) 个子项目)")
                return true
            }

            // 兼容旧格式（只有单个项目）
            if let snapshot = try? JSONDecoder().decode(ProjectSnapshot.self, from: beforeData) {
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
            executedDate: snapshot.executedDate,
            thumbnail: snapshot.thumbnail,
            finishedImage: snapshot.finishedImage,
            colorSystem: snapshot.colorSystem
        )
    }

    // MARK: - 数据持久化

    private func makeMapByID(_ items: [HistoryRecord]) -> [UUID: HistoryRecord] {
        Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    private func refreshBaseline() {
        baselineRecordsByID = makeMapByID(records)
    }

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

        AppBackgroundTaskManager.shared.perform(named: "HistoryLoad") {
            do {
                let descriptor = FetchDescriptor<SDHistoryRecord>(
                    sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
                )
                let sdRecords = try context.fetch(descriptor)
                records = sdRecords.compactMap { $0.toStruct() }
                isDataLoaded = true
                refreshBaseline()
                print("[History] 加载了 \(records.count) 条历史记录")
            } catch {
                print("[History] 加载历史记录失败: \(error)")
            }
        }
    }

    func saveData() {
        // 使用防抖机制，避免频繁保存导致 SwiftData 崩溃
        pendingSave = true

        // 取消之前的保存任务
        saveWorkItem?.cancel()

        // 创建新的延迟保存任务
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.performSave()
            }
        }
        saveWorkItem = workItem

        // 延迟 0.1 秒执行保存，合并多次保存请求
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    /// 立即保存数据（用于应用进入后台等紧急情况）
    @MainActor
    func saveDataImmediately() {
        // 取消待处理的延迟保存
        saveWorkItem?.cancel()
        saveWorkItem = nil

        // 只有在有待保存数据时才执行
        if pendingSave {
            performSave()
        }
    }

    @MainActor
    private func performSave() {
        pendingSave = false

        guard let context = modelContext else {
            print("[History] ModelContext 未设置，无法保存数据")
            return
        }

        // 防止在数据未加载完成时保存空数据
        guard isDataLoaded else {
            print("[History] 警告：数据尚未加载完成，跳过保存")
            return
        }

        // 与 InventoryManager.saveData 同样的 fallback 守卫：用户主动放弃等待
        // iCloud 同步时（或 opt-out 重启前），baseline-diff 仍可能用过期内存覆盖
        // SwiftData/CloudKit 上更新的数据，因此整体跳过历史记录的持久化。
        if inventoryManager?.isUsingLocalFallbackMode == true {
            AppLogger.shared.warning("History", "save_skipped_local_fallback_mode")
            return
        }

        AppBackgroundTaskManager.shared.perform(named: "HistorySave") {
            do {
                let existing = try context.fetch(FetchDescriptor<SDHistoryRecord>())
                let existingByID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let localByID = makeMapByID(records)

                // 本地确实删除（trim/clear）才执行删除；云端新增则保留并合并进本地
                var remoteRecordsToAppend: [HistoryRecord] = []
                for sdRecord in existing where localByID[sdRecord.id] == nil {
                    if baselineRecordsByID[sdRecord.id] != nil {
                        context.delete(sdRecord)
                    } else if let remoteRecord = sdRecord.toStruct() {
                        remoteRecordsToAppend.append(remoteRecord)
                    }
                }
                if !remoteRecordsToAppend.isEmpty {
                    records.append(contentsOf: remoteRecordsToAppend)
                    records.sort { $0.timestamp > $1.timestamp }
                    trimRecords()
                }

                var staleLocalIDs = Set<UUID>()
                for record in records {
                    let baseline = baselineRecordsByID[record.id]
                    let changedLocally = baseline == nil || baseline != record

                    if let existingRecord = existingByID[record.id] {
                        guard changedLocally else { continue }
                        existingRecord.timestamp = record.timestamp
                        existingRecord.operationType = record.operationType.rawValue
                        existingRecord.targetName = record.entityName
                        existingRecord.beforeSnapshot = record.beforeSnapshot
                        existingRecord.afterSnapshot = record.afterSnapshot
                        existingRecord.isReverted = record.isReverted
                    } else if changedLocally {
                        context.insert(SDHistoryRecord(from: record))
                    } else {
                        staleLocalIDs.insert(record.id)
                    }
                }
                if !staleLocalIDs.isEmpty {
                    records.removeAll { staleLocalIDs.contains($0.id) }
                }

                try context.save()
                refreshBaseline()
                print("[History] 保存了 \(records.count) 条历史记录")
            } catch {
                print("[History] 保存历史记录失败: \(error)")
            }
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
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today

        var groups: [String: [HistoryRecord]] = [:]

        for record in records {
            let recordDate = calendar.startOfDay(for: record.timestamp)
            let key: String

            if recordDate == today {
                key = String(localized: "今天")
            } else if recordDate == yesterday {
                key = String(localized: "昨天")
            } else {
                let formatter = DateFormatter()
                formatter.setLocalizedDateFormatFromTemplate("MMMMd")
                key = formatter.string(from: record.timestamp)
            }

            if groups[key] == nil {
                groups[key] = []
            }
            groups[key]?.append(record)
        }

        // 排序：今天 > 昨天 > 其他日期（按时间倒序）
        // 使用 group 中第一条记录的实际时间戳排序，避免本地化日期字符串字典序不等于时间序
        let todayLabel = String(localized: "今天")
        let yesterdayLabel = String(localized: "昨天")
        let sortedKeys = groups.keys.sorted { key1, key2 in
            if key1 == todayLabel { return true }
            if key2 == todayLabel { return false }
            if key1 == yesterdayLabel { return true }
            if key2 == yesterdayLabel { return false }
            let date1 = groups[key1]?.first?.timestamp ?? .distantPast
            let date2 = groups[key2]?.first?.timestamp ?? .distantPast
            return date1 > date2
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
