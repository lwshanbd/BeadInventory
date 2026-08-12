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

    // 后台加载任务（测试可 await 它等加载完成）+ 代次令牌（忽略过期上下文迟到的完成）
    private(set) var loadTask: Task<Void, Never>?
    private var loadGeneration = 0
    // 是否有加载正在进行：供 reloadIfNeeded 区分「加载中」与「加载已失败」，避免在途时重复触发。
    private var isLoading = false

    // metadata-only 取数的列白名单：loadData 与 performSave 共用，避免两处各写一份漂移
    //（漏列某列会让该列在 fetch 阶段不被物化，"metadata-only" 语义就不成立）。
    private static let metadataProperties: [PartialKeyPath<SDHistoryRecord>] = [
        \.id, \.timestamp, \.operationType, \.targetName, \.isReverted
    ]

    // 防抖保存：避免频繁调用 saveData 导致 SwiftData 崩溃
    private var saveWorkItem: DispatchWorkItem?
    private var pendingSave = false

    // 保存基线：用于同步场景下避免“全量重写”造成互相覆盖
    private var baselineRecordsByID: [UUID: HistoryRecord] = [:]

    private init() {}

    // 设置 ModelContext
    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
        // 安装新上下文前清掉旧残留（生产仅启动调用一次、此时本为空；也避免单例在测试间串味），
        // 并取消可能挂着的防抖保存，防止旧上下文的待保存落到新库上。
        saveWorkItem?.cancel()
        saveWorkItem = nil
        pendingSave = false
        records = []
        baselineRecordsByID = [:]
        snapshotCache.removeAll()
        isDataLoaded = false
        loadData()
    }

    /// 补偿重试：仅当上次加载未成功（isDataLoaded 仍 false）、当前没有加载在途、且已有 context 时，
    /// 重新触发一次后台加载。供前台恢复（scenePhase.active）调用 —— 否则启动时加载失败会让
    /// isDataLoaded 永远停在 false：整 session 历史只在内存、saveDataImmediately 也被守卫跳过、
    /// 退出即丢。加载成功会顺带把这期间积压在内存、尚未落库的记录补存（见 loadData 的收尾补存）。
    func reloadIfNeeded() {
        guard !isDataLoaded, !isLoading, modelContext != nil else { return }
        AppLogger.shared.info("History", "reload_if_needed_retry")
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
    /// - Parameter capturesImages: 调用方是否为「图片改动」操作主动把 OLD thumbnail /
    ///   finishedImage 写进了 `project`。仅 updateProjectThumbnail / updateProjectFinishedImage
    ///   应该传 true；其它 metadata 改动一律 false（默认）。
    ///   undo 路径靠这个标志判断是否需要从 snapshot 还原图片，避免 metadata undo 把图清掉。
    /// - Parameter partsSheetData: 多零件图纸的原始字节。它不在 `ProjectRecord` 上（只有
    ///   SwiftData 列），所以跟 patternGrid 不同，得由调用方显式取来传进来。
    ///   语义同 patternGrid 的 opt-in：只有 destructive 路径（行会被删）需要传。
    func recordProject(
        type: HistoryOperationType,
        project: ProjectRecord,
        capturesImages: Bool = false,
        partsSheetData: Data? = nil
    ) {
        // 撤回操作时不记录新的历史
        guard !isReverting else { return }

        let usageSnapshots = project.beadUsage.map {
            BeadUsageSnapshot(colorCode: $0.colorCode, brandId: $0.brandId, quantity: $0.quantity, isDeducted: $0.isDeducted)
        }

        // patternGrid 编码：调用方（destructive 路径）会把 fetchProjectPatternGrid 取出来的
        // OLD grid 写到 `project.patternGrid` 上；image-update 和其它路径 project.patternGrid
        // 是 nil（来自 metadata-only cache），自然不会写进 snapshot —— 跟 capturesImages
        // 一样的 opt-in 语义。
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
            colorSystem: project.colorSystem,
            capturesImages: capturesImages,
            patternGridData: SDProjectRecord.encodePatternGrid(project.patternGrid, projectId: project.id),
            completedDate: project.completedDate,
            displayThumbnail: project.displayThumbnail,
            partsSheetData: partsSheetData
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
        case .projectArchive, .projectUnarchive, .planUpdate, .projectUpdate:
            // .projectUpdate 之前漏在 default 里 —— 已执行项目的 thumbnail / finishedImage /
            // completedDate 修改根本没写 beforeSnapshot，undo 完全是 no-op。
            // 已执行项目和计划项目走同一套 update / undo 语义。
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
            colorSystem: beforeProject.colorSystem,
            patternGridData: SDProjectRecord.encodePatternGrid(beforeProject.patternGrid, projectId: beforeProject.id),
            completedDate: beforeProject.completedDate,
            displayThumbnail: beforeProject.displayThumbnail
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
            colorSystem: afterProject.colorSystem,
            patternGridData: SDProjectRecord.encodePatternGrid(afterProject.patternGrid, projectId: afterProject.id),
            completedDate: afterProject.completedDate,
            displayThumbnail: afterProject.displayThumbnail
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
    /// - Parameter partsSheetDataByProjectId: 参与合并的项目里，行会被删掉那些的多零件图纸
    ///   原始字节（同 `recordProject` 的 partsSheetData —— 它不在 ProjectRecord 上）。
    func recordProjectMerge(
        originalProjects: [ProjectRecord],
        newParentId: UUID?,
        isSimpleMerge: Bool,
        existingParentId: UUID?,
        mergedName: String,
        partsSheetDataByProjectId: [UUID: Data] = [:]
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
                colorSystem: project.colorSystem,
                patternGridData: SDProjectRecord.encodePatternGrid(project.patternGrid, projectId: project.id),
                completedDate: project.completedDate,
                displayThumbnail: project.displayThumbnail,
                partsSheetData: partsSheetDataByProjectId[project.id]
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
    /// - Parameter partsSheetDataByProjectId: 父项目和每个子项目的多零件图纸原始字节
    ///   （同 `recordProject` 的 partsSheetData —— 它不在 ProjectRecord 上）。
    func recordPlanDelete(
        project: ProjectRecord,
        children: [ProjectRecord],
        partsSheetDataByProjectId: [UUID: Data] = [:]
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
            colorSystem: project.colorSystem,
            patternGridData: SDProjectRecord.encodePatternGrid(project.patternGrid, projectId: project.id),
            completedDate: project.completedDate,
            displayThumbnail: project.displayThumbnail,
            partsSheetData: partsSheetDataByProjectId[project.id]
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
                colorSystem: child.colorSystem,
                patternGridData: SDProjectRecord.encodePatternGrid(child.patternGrid, projectId: child.id),
                completedDate: child.completedDate,
                displayThumbnail: child.displayThumbnail,
                partsSheetData: partsSheetDataByProjectId[child.id]
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
        // records 常态 metadata-only，仅下面三个需要检查 snapshot 的分支按需取
        // （default 分支不读 snapshot，避免 HistoryView 整表 filter 时全量 hydrate）。
        var record = record
        if needsSnapshotForRevertCheck(record.operationType) {
            switch resolveSnapshots(for: record) {
            case .transientFailure:
                // 取快照失败是可重试的瞬时态，乐观放行；真正撤回时再校验，
                // 不在列表态把它误判成「永久不可撤回」。
                return true
            case .ready(let hydrated):
                record = hydrated
            }
        }
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

    /// canRevert / revertDisabledReason 中需要检查 snapshot 内容的操作类型。
    private func needsSnapshotForRevertCheck(_ type: HistoryOperationType) -> Bool {
        switch type {
        case .projectMerge, .planExecute, .planAdd:
            return true
        default:
            return false
        }
    }

    /// 获取不能撤回的原因
    @MainActor func revertDisabledReason(_ record: HistoryRecord) -> String? {
        var record = record
        if needsSnapshotForRevertCheck(record.operationType) {
            switch resolveSnapshots(for: record) {
            case .transientFailure:
                // 可重试失败：不展示「永久不可撤回」类原因（与 canRevert 乐观放行一致）。
                return nil
            case .ready(let hydrated):
                record = hydrated
            }
        }
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

    /// 撤回结果。`snapshotLoadFailed` 是可重试的瞬时态，调用方应提示「请重试」而非「数据已不可恢复」。
    enum RevertOutcome {
        case success
        /// 撤回逻辑失败（快照确实缺失 / 项目状态不允许 / 记录已撤回等）—— 通常不可重试。
        case failed
        /// 按需加载快照失败（fetch 抛错等）—— 可重试。
        case snapshotLoadFailed
        /// 主体撤回成功，但附带的某样东西没能一起还原（目前只有多零件进度）。
        ///
        /// 必须跟 `failed` 分开：项目行这时**已经建回去了**，再报失败的话历史记录会留着，
        /// 用户看到「撤回失败」再点一次 —— 而 `addProject` 不按 id 去重，
        /// 于是列表里出现两个同 UUID 的项目。这条既消费掉记录，又如实说清缺了什么。
        case partial(String)
    }

    /// `performRevert` 里攒下来的「主体成功了，但这样东西没跟上」。成功路径上被 `revert` 取走。
    @MainActor private var revertWarning: String?

    /// 给撤回过程中在别处（`InventoryManager` 的合并撤回）发现的「有东西没还原上」留话。
    /// 那些路径同样已经把项目建回去了，所以只能补一句说明，不能把整次撤回判成失败。
    @MainActor func noteRevertWarning(_ text: String) {
        guard isReverting else { return }
        revertWarning = text
    }

    /// 撤回一个操作
    @discardableResult
    @MainActor func revert(_ recordId: UUID) -> RevertOutcome {
        guard let index = records.firstIndex(where: { $0.id == recordId }) else {
            print("[History] 找不到记录: \(recordId)")
            return .failed
        }

        let baseRecord = records[index]

        if baseRecord.isReverted {
            print("[History] 记录已撤回: \(baseRecord.fullDescription)")
            return .failed
        }

        guard let manager = inventoryManager else {
            print("[History] InventoryManager 未设置")
            return .failed
        }

        // performRevert 各分支都要解码 snapshot，metadata-only 记录先按需补全。
        // 区分「确实没有/已就绪」与「取数失败」：后者返回 .snapshotLoadFailed，
        // 让 UI 提示可重试，而不是退化成 performRevert nil-快照 → 「数据已不可恢复」。
        let record: HistoryRecord
        switch resolveSnapshots(for: baseRecord) {
        case .ready(let hydrated):
            record = hydrated
        case .transientFailure:
            print("[History] 撤回前加载快照失败，可重试: \(baseRecord.fullDescription)")
            return .snapshotLoadFailed
        }

        // 设置撤回标志，防止撤回操作被记录为新的历史
        isReverting = true
        revertWarning = nil
        let success = performRevert(record: record, manager: manager)
        isReverting = false

        if success {
            // 撤回成功后直接删除该记录
            records.remove(at: index)
            snapshotCache.removeValue(forKey: record.id)
            saveData()
            print("[History] 撤回成功并删除记录: \(record.fullDescription)")
            if let warning = revertWarning {
                revertWarning = nil
                return .partial(warning)
            }
            return .success
        } else {
            print("[History] 撤回失败: \(record.fullDescription)")
            return .failed
        }
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
                // 项目行已经建回去了，所以这里一定算撤销成功 —— 返回 false 会把记录留着
                // 让用户再点一次，而 addProject 不去重，点第二次就是两个同 id 的项目。
                // 多零件进度没跟上就单独说一句，别让他以为东西都在。
                if !restorePartsSheet(from: snapshot, into: manager) {
                    revertWarning = String(localized: "项目回来了，但它的多零件进度没能一起还原。")
                    // 批量撤回时这句话会被合并进汇总，日志是唯一能逐条查到的地方
                    AppLogger.shared.error("History", "undo_parts_sheet_lost", metadata: [
                        "projectId": snapshot.id.uuidString, "kind": "projectDelete"
                    ])
                }
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
            // 撤回项目修改 = 恢复旧快照
            if let beforeData = record.beforeSnapshot,
               let snapshot = try? JSONDecoder().decode(ProjectSnapshot.self, from: beforeData) {
                // 自 v2.0.x 起 projects 缓存里 thumbnail / finishedImage 恒为 nil，
                // 只有 update*Image 系列方法在 record 之前会主动把 OLD 图取出来写进 snapshot
                // 并且把 `capturesImages` 标成 true。
                // 旧版本 snapshot 没有这个字段（capturesImages == nil），但旧逻辑总是把图编进
                // snapshot，所以兜底用 thumbnail/finishedImage 非空作存在性指标。
                let shouldRestoreImages = snapshot.capturesImages ?? (snapshot.thumbnail != nil || snapshot.finishedImage != nil)
                if shouldRestoreImages {
                    manager.updateProjectThumbnail(snapshot.id, thumbnail: snapshot.thumbnail)
                    manager.updateProjectFinishedImage(snapshot.id, finishedImage: snapshot.finishedImage)
                }
                // completedDate 撤销：新格式 snapshot 总是带 OLD 值（包括 OLD == nil），
                // 写回当前值或 nil 都是预期行为；旧格式 snapshot 没有 completedDate 字段
                // （`decodeIfPresent → nil`），不能盲写回 nil（会清掉用户当前的有效日期）。
                // 用 `capturesImages` 是否非 nil 区分新旧：新格式 record 总会传 false / true，
                // 旧格式 record decode 出来一律是 nil。
                // 覆盖的关键场景：
                //   - updateProjectFinishedImage 自动补的 completedDate 在 undo 时撤回
                //   - updateProjectCompletedDate 自身的 undo（包括 `nil → date` 和 `date → nil` 双向）
                if snapshot.capturesImages != nil {
                    manager.updateProjectCompletedDate(snapshot.id, completedDate: snapshot.completedDate)
                }
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
                var missing = restorePartsSheet(from: deleteSnapshot.deletedProject, into: manager) ? 0 : 1

                // 再恢复所有子项目
                for childSnapshot in deleteSnapshot.deletedChildren {
                    let childProject = restoreProject(from: childSnapshot)
                    manager.addPlannedProject(childProject)
                    if !restorePartsSheet(from: childSnapshot, into: manager) { missing += 1 }
                }

                print("[History] 恢复计划: \(parentProject.name) (包含 \(deleteSnapshot.deletedChildren.count) 个子项目)")
                // 计划和子项目都已经建回去了 —— 理由同 .projectDelete 分支
                if missing > 0 {
                    revertWarning = String(localized: "计划回来了，但其中 \(missing) 个项目的多零件进度没能一起还原。")
                    AppLogger.shared.error("History", "undo_parts_sheet_lost", metadata: [
                        "projectId": deleteSnapshot.deletedProject.id.uuidString,
                        "kind": "planDelete", "projects": missing
                    ])
                }
                return true
            }

            // 兼容旧格式（只有单个项目）
            if let snapshot = try? JSONDecoder().decode(ProjectSnapshot.self, from: beforeData) {
                let project = restoreProject(from: snapshot)
                manager.addPlannedProject(project)
                if !restorePartsSheet(from: snapshot, into: manager) {
                    revertWarning = String(localized: "项目回来了，但它的多零件进度没能一起还原。")
                    AppLogger.shared.error("History", "undo_parts_sheet_lost", metadata: [
                        "projectId": snapshot.id.uuidString, "kind": "planDeleteLegacy"
                    ])
                }
                return true
            }

            return false

        case .planUpdate:
            // 撤回修改 = 恢复旧名称 + 镜像 .projectUpdate 的图片撤销逻辑。
            // 之前只 updatePlannedProjectName 是个半成品 —— updateProjectThumbnail
            // 在 planned project 上记 .planUpdate 且带 capturesImages: true + OLD 图，
            // 但这里不读 capturesImages → 计划项目封面编辑 undo 静默失效。
            if let beforeData = record.beforeSnapshot,
               let snapshot = try? JSONDecoder().decode(ProjectSnapshot.self, from: beforeData) {
                let shouldRestoreImages = snapshot.capturesImages ?? (snapshot.thumbnail != nil || snapshot.finishedImage != nil)
                if shouldRestoreImages {
                    manager.updateProjectThumbnail(snapshot.id, thumbnail: snapshot.thumbnail)
                    // 计划项目没有 finishedImage 的语义（updateProjectFinishedImage 会被 !isPlanned
                    // guard 拦掉）—— 这里调一遍是 no-op，留着是为了和 .projectUpdate 路径同形，
                    // 万一未来 planned project 也支持成品图就自动跟上。
                    manager.updateProjectFinishedImage(snapshot.id, finishedImage: snapshot.finishedImage)
                }
                manager.updatePlannedProjectName(snapshot.id, newName: snapshot.name)
                return true
            }
            return false
        }
    }

    /// 项目行重建之后，把快照里的多零件图纸补写回去。
    /// 它不在 `ProjectRecord` 上（只有 SwiftData 列），`addProject` / `addPlannedProject`
    /// 带不过去，只能建完行再补一刀。
    ///
    /// 搬的是**原始字节**：快照可能是别的设备用新版本写的，解码再编码会把本版本
    /// 不认识的字段悄悄抹掉；解码失败更会让一份完好的数据整个被丢弃。
    /// 备份恢复和复制项目走的也是搬字节这条路。
    ///
    /// - Returns: 快照本来就没有多零件进度 → true（没东西要还原）；有但没写进去 → false。
    ///   **注意失败不代表撤销失败** —— 项目行这时已经建好了，见调用处。
    @MainActor private func restorePartsSheet(from snapshot: ProjectSnapshot, into manager: InventoryManager) -> Bool {
        guard let data = snapshot.partsSheetData else { return true }
        return manager.restoreProjectPartsSheetData(snapshot.id, data: data)
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
            // ProjectRecord 这一份用于回灌到 addProject / addPlannedProject ——
            // SDProjectRecord(from:) 会消费 completedDate / patternGrid / displayThumbnail 一并写入新行。
            completedDate: snapshot.completedDate,
            colorSystem: snapshot.colorSystem,
            patternGrid: SDProjectRecord.decodePatternGrid(snapshot.patternGridData, projectId: snapshot.id),
            displayThumbnail: snapshot.displayThumbnail
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
        guard records.count > maxRecords else { return }
        // 被裁掉的记录其 snapshot 缓存也一并清掉，避免 snapshotCache 无界增长，
        // 长期把已不在列表里的大 blob 一直驻留在内存。
        let droppedIDs = records[maxRecords...].map { $0.id }
        records = Array(records.prefix(maxRecords))
        for id in droppedIDs {
            snapshotCache.removeValue(forKey: id)
        }
    }

    /// 触发一次后台加载。返回的 Task 可被测试 `await` 以等待加载完成；生产侧 fire-and-forget。
    @discardableResult
    func loadData() -> Task<Void, Never>? {
        guard let context = modelContext else {
            print("[History] ModelContext 未设置，无法加载数据")
            return nil
        }

        // **启动白屏根因修复（二次）**：全 App 的第一次 SwiftData 取数会触发存储首次打开
        // —— SQLite + NSPersistentCloudKitContainer 初始化，冷启动实测同步阻塞约 1s。本函数
        // 由 BeadInventoryApp.init() 调用，发生在首帧渲染之前；若用 mainContext 同步取数，
        // 这 1s 直接压在首帧前 → ContentView 的加载态都来不及渲染 = 长时间白屏/黑屏。
        //
        // 改为在后台 ModelContext 上取数：开库开销落到后台线程，App.init 立即返回、加载态
        // 立刻渲染；只把转换好的 metadata 结构体回主线程赋值。顺带把存储预热好，紧随其后的
        // InventoryManager 主线程取数也走暖路径。
        //
        // 仍保留 propertiesToFetch（只取 metadata 列）：beforeSnapshot / afterSnapshot 是
        // inline BLOB（单条可达数 MB），全表物化会再压数百 MB 进内存；snapshot 在 revert 时
        // 走 resolveSnapshots(for:)（hydratedRecord(_:) 是其便捷封装）按 id 单行取。
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        let container = context.container
        let task = Task { @MainActor in
            let result = await Self.fetchHistoryMetadata(from: container)
            // 过期完成直接丢弃：await 期间又装了新上下文（如测试切库 / 重新加载），
            // 避免旧库的结果覆盖新状态。isLoading 归属最新一代，不在这里清。
            guard generation == self.loadGeneration else { return }
            self.isLoading = false
            switch result {
            case .success(let loaded):
                let loadedIDs = Set(loaded.map { $0.id })
                // 加载窗口内（isDataLoaded 仍为 false、performSave 被守卫跳过）新建、尚未持久化
                // 的本地记录：合并保留，避免被加载结果直接覆盖丢失。
                let pendingLocal = self.records.filter { !loadedIDs.contains($0.id) }
                self.records = (loaded + pendingLocal).sorted { $0.timestamp > $1.timestamp }
                self.snapshotCache.removeAll()
                self.isDataLoaded = true
                // baseline 只认已持久化集合：pendingLocal 不进 baseline → 下次 save 走 insert，
                // 不会被 performSave 当成「本地已删」而误删。
                self.baselineRecordsByID = self.makeMapByID(loaded)
                // 收尾补存：加载窗口内被守卫跳过的保存 / 合并进来的未持久化记录，此刻 isDataLoaded
                // 已 true，补触发一次 saveData 把它们落库；否则它们只在内存里、退出即丢。
                if self.pendingSave || !pendingLocal.isEmpty {
                    self.saveData()
                }
                AppLogger.shared.info("History", "loaded", metadata: [
                    "count": self.records.count,
                    "pendingMerged": pendingLocal.count
                ])
            case .failure(let error):
                // 失败不置 isDataLoaded（performSave 仍被守卫跳过、可重试），保留内存现状，
                // 并写入可导出诊断 —— 区别于「确实没有历史记录」。
                AppLogger.shared.error("History", "load_failed", metadata: [
                    "error": error.localizedDescription
                ])
            }
        }
        loadTask = task
        return task
    }

    /// 在后台 ModelContext 上做 metadata-only 取数并转换成 Sendable 结构体；失败以 `Result` 上抛，
    /// 由调用方区分「取数失败」与「确实没有记录」（前者不应置 isDataLoaded、可重试）。
    /// 全程在单个 detached task 内同步执行（取数与转换之间无 await，ModelContext 不跨线程），
    /// 只把 `[HistoryRecord]`（值类型）交回调用方。
    nonisolated private static func fetchHistoryMetadata(from container: ModelContainer) async -> Result<[HistoryRecord], Error> {
        let properties = metadataProperties
        return await Task.detached(priority: .userInitiated) {
            let bgContext = ModelContext(container)
            var descriptor = FetchDescriptor<SDHistoryRecord>(
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
            )
            descriptor.propertiesToFetch = properties
            do {
                return .success(try bgContext.fetch(descriptor).compactMap { $0.toMetadataStruct() })
            } catch {
                return .failure(error)
            }
        }.value
    }

    // MARK: - Snapshot 按需加载

    /// snapshot blob 的按需缓存：records 常态只携带 metadata（见 loadData），
    /// canRevert / revert 需要 snapshot 时按 id 单行 fetch 并缓存，避免重复查询。
    /// value 为 (before, after)，(nil, nil) 也是合法缓存值（该记录本来就没有 snapshot）。
    private var snapshotCache: [UUID: (before: Data?, after: Data?)] = [:]

    /// `resolveSnapshots(for:)` 的结果，关键在于把「确实没有 / 已加载」和「取数失败」分开。
    ///
    /// 旧实现里这三种情况都退化成「返回 metadata-only record（nil snapshot）」，
    /// 调用方无法区分，于是把**可重试的取数失败**误判成「旧版本记录、永久不可撤回」，
    /// 给用户展示了误导性的「数据已不可恢复」。
    enum SnapshotResolution {
        /// record 已带齐所需 snapshot（也可能确认为「本就没有」，此时仍是 ready）。
        case ready(HistoryRecord)
        /// 取数失败（modelContext 缺失 / fetch 抛错）—— 可重试，调用方不应判定为永久状态。
        case transientFailure
    }

    /// 按需补全 record 的 snapshot，区分「就绪」与「可重试的失败」。
    ///
    /// 三级来源：① record 自带（刚由 record() 创建、尚未经过 metadata-only reload 的
    /// 在内存记录）；② snapshotCache；③ 按 id 单行 fetch SwiftData（整行物化，含 blob）。
    /// 行不存在（如确无 snapshot 的记录）返回 `.ready(原 record)`；只有真正取数失败才回 `.transientFailure`。
    @MainActor
    func resolveSnapshots(for record: HistoryRecord) -> SnapshotResolution {
        if record.beforeSnapshot != nil || record.afterSnapshot != nil {
            return .ready(record)
        }

        let snapshots: (before: Data?, after: Data?)
        if let cached = snapshotCache[record.id] {
            snapshots = cached
        } else {
            guard let context = modelContext else { return .transientFailure }
            let recordId = record.id
            var descriptor = FetchDescriptor<SDHistoryRecord>(
                predicate: #Predicate { $0.id == recordId }
            )
            descriptor.fetchLimit = 1
            do {
                guard let sdRecord = try context.fetch(descriptor).first else {
                    // 行不在持久层：内存自带 snapshot 的路径上面已 return，
                    // 走到这里说明该记录确实没有 snapshot，按「就绪」处理。
                    return .ready(record)
                }
                snapshots = (sdRecord.beforeSnapshot, sdRecord.afterSnapshot)
                snapshotCache[record.id] = snapshots
            } catch {
                AppLogger.shared.error("History", "snapshot_hydrate_failed", metadata: [
                    "id": record.id.uuidString,
                    "error": "\(error)"
                ])
                return .transientFailure
            }
        }

        guard snapshots.before != nil || snapshots.after != nil else { return .ready(record) }
        return .ready(HistoryRecord(
            id: record.id,
            timestamp: record.timestamp,
            operationType: record.operationType,
            entityName: record.entityName,
            beforeSnapshot: snapshots.before,
            afterSnapshot: snapshots.after,
            isReverted: record.isReverted
        ))
    }

    /// 便捷封装：取数失败时退回原 record（用于不需要区分失败/缺失的场景）。
    @MainActor
    func hydratedRecord(_ record: HistoryRecord) -> HistoryRecord {
        switch resolveSnapshots(for: record) {
        case .ready(let hydrated):
            return hydrated
        case .transientFailure:
            return record
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
        guard let context = modelContext else {
            print("[History] ModelContext 未设置，无法保存数据")
            return
        }

        // 数据未加载完不保存空数据。**关键**：这里不清 pendingSave —— 加载窗口内被跳过的保存
        // 必须保留待存标志，否则加载完成后这条（仅在内存的）记录永远不会落库（pendingSave 被清、
        // saveDataImmediately 也不再 flush）。加载成功收尾时（见 loadData）会补触发一次保存。
        guard isDataLoaded else {
            print("[History] 警告：数据尚未加载完成，跳过保存（保留 pendingSave 待加载后补存）")
            return
        }

        pendingSave = false

        // 与 InventoryManager.saveData 同样的 fallback 守卫：用户主动放弃等待
        // iCloud 同步时（或 opt-out 重启前），baseline-diff 仍可能用过期内存覆盖
        // SwiftData/CloudKit 上更新的数据，因此整体跳过历史记录的持久化。
        if inventoryManager?.isUsingLocalFallbackMode == true {
            AppLogger.shared.warning("History", "save_skipped_local_fallback_mode")
            return
        }

        AppBackgroundTaskManager.shared.perform(named: "HistorySave") {
            do {
                // metadata-only：跟 loadData 同理，diff 只需要 id（更新走对象引用），
                // 不物化全表 snapshot blob —— 否则每次防抖保存都把数百 MB 拉进内存。
                var existingDescriptor = FetchDescriptor<SDHistoryRecord>()
                existingDescriptor.propertiesToFetch = Self.metadataProperties
                let existing = try context.fetch(existingDescriptor)
                let existingByID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let localByID = makeMapByID(records)

                // 本地确实删除（trim/clear）才执行删除；云端新增则保留并合并进本地
                var remoteRecordsToAppend: [HistoryRecord] = []
                for sdRecord in existing where localByID[sdRecord.id] == nil {
                    if baselineRecordsByID[sdRecord.id] != nil {
                        context.delete(sdRecord)
                    } else if let remoteRecord = sdRecord.toMetadataStruct() {
                        // metadata-only 合并进内存即可：blob 留在库里，撤回时按需 hydrate
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
                        // 仅在内存里真带 snapshot 时才写回：metadata-only 记录的 nil
                        // 是「没加载」而不是「没有」，无条件赋值会把库里的 blob 清掉。
                        // snapshot 创建后不可变，不存在合法的「写 nil 清空」场景。
                        if record.beforeSnapshot != nil {
                            existingRecord.beforeSnapshot = record.beforeSnapshot
                        }
                        if record.afterSnapshot != nil {
                            existingRecord.afterSnapshot = record.afterSnapshot
                        }
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
        snapshotCache.removeAll()
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
