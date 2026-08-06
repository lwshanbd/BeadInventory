//
//  InventoryManager.swift
//  BeadInventory
//
//  库存管理器 - 使用 SwiftData 进行数据持久化
//

import Foundation
import SwiftUI
import SwiftData
import CryptoKit
import SQLite3

@MainActor
class InventoryManager: ObservableObject {
    @Published var beadColors: [BeadColor] = [] {
        didSet { colorLookupIndexDirty = true }
    }
    @Published var projects: [ProjectRecord] = [] {
        didSet { parentIdsCacheDirty = true }
    }
    @Published var customColors: [CustomColor] = []  // 自定义色号
    @Published var purchaseRecords: [PurchaseRecord] = []  // 运输中的购买记录
    @Published private(set) var isInitialLoadInProgress = false
    @Published private(set) var initialLoadErrorMessage: String?

    // MARK: - 项目图片 Blob 元数据
    //
    // 自 v2.0.x 起：`projects` 不再持有 thumbnail / finishedImage / patternGridData /
    // displayThumbnail 四个大 Data blob（防止 458 项目级用户加载完 ~200MB 撞 jetsam）。
    // **视图层走 `imageLoader`（后台 actor）**，不是下面这些 @MainActor 同步方法 ——
    // 后者只剩备份导出 / history 快照捕获等主线程调用方。按需从
    // SwiftData 取单条 row。**列表 row 优先读 displayThumbnail（小图 ~50-100 KB）**，
    // 没有再走 ImageDownsampler 现场降级 raw thumbnail，**永远不**直接 UIImage(data: raw thumbnail)。
    //
    // 为了让 CalendarView 这类「我有没有成品图」的查询不需要加载实际 Data，
    // 单独缓存一份 ID 集合：只查 `finishedImage != nil` 谓词，SQL 层就能完成不读 blob。
    /// 持久层里有 finishedImage 的项目 ID 集合（不含 Data）。
    /// 在 loadData 完成后 / updateProjectFinishedImage 后刷新。
    @Published private(set) var projectIDsWithFinishedImage: Set<UUID> = []

    /// 是否已经**成功跑完过一次全量** blob 存在性扫描（raw SQLite 或 legacy 回退均算）。
    ///
    /// 它存在的唯一理由是给 `scheduleBlobMetadataRetry` 当停止条件。早先的停止条件是
    /// 「集合非空」—— 但集合也被 addProject / duplicate / restore **增量**插入：用户在
    /// 重试的 2 秒退避窗口里新建一个带封面的项目 → 集合非空 → 重试链无声死亡 →
    /// 此后整个 session 所有**老**项目都报告「没有图」（拼图模式按钮灰、日历空白）。
    /// 增量插入≠扫描过，两件事必须分开记（round-2 双审两侧命中）。
    private var hasCompletedBlobMetadataScan = false

    /// 持久层里有 thumbnail 的项目 ID 集合（不含 Data）。
    @Published private(set) var projectIDsWithThumbnail: Set<UUID> = []

    /// 持久层里有 patternGridData 的项目 ID 集合（不含 Data）。
    /// 用于 "拼图模式" 按钮判断是直接进 highlight 还是先 calibration。
    @Published private(set) var projectIDsWithPatternGrid: Set<UUID> = []

    /// 持久层里有 displayThumbnail 的项目 ID 集合（不含 Data）。
    /// 老数据可能 nil（迁移协调器后台 backfill），视图层在 displayThumbnail 缺位时
    /// 走 ImageDownsampler 现场降级 raw thumbnail。
    ///
    /// **故意不 @Published**：迁移协调器每写一个项目就 `.insert(id)` 一次；如果加
    /// @Published，每次 insert 都触发 `objectWillChange.send()`，所有 @EnvironmentObject
    /// 消费者（整个计划列表）都会重新 evaluate body —— 这正是 PR #48 闪烁回归的根因之一。
    /// 视图层（`ProjectThumbnailImage`）不直接读本集合，不需要 SwiftUI 的响应式驱动。
    private(set) var projectIDsWithDisplayThumbnail: Set<UUID> = []

    /// 项目 blob（thumbnail / finishedImage / patternGrid / displayThumbnail）的全局版本号。
    /// 每当任意项目的 blob 被改动就 ++。SwiftUI 中需要重新拉图的组件
    /// 可以把它带进 .task(id:) 的复合 key 里强制重新跑取图任务。
    @Published private(set) var projectBlobsRevision: Int = 0

    // 品牌相关
    @Published var brands: [Brand] = []
    @Published var brandStocks: [BrandStock] = [] {
        didSet { stockPositionIndexDirty = true }
    }
    @Published var currentBrandId: UUID?

    // (brandId, mardCode) → brandStocks 中的下标。
    // 让 getStock 保持 O(1)；调用方可以在 body / ForEach 中无忧反复查。
    //
    // 用「dirty flag + 读时摊销重建」而不是直接 didSet 重建，是因为元素级写入
    // （brandStocks[i].stock = x）也会触发 didSet：批量场景（resetAllStock 走
    // removeAll + N 次 append、mergeBrands、addToInventory 等）会变成 K × O(N)。
    // 标记 dirty 后多次写只摊销成下一次读时的一次 O(N) 重建。
    //
    // 与所有 mutator 的 firstIndex(where:) 语义一致：rebuild 时若同一 (brandId,
    // mardCode) 在数组里出现多次（历史/iCloud 同步意外产生），索引保留第一条。
    private var _stockPositionIndex: [UUID: [String: Int]] = [:]
    private var stockPositionIndexDirty = true
    private var stockPositionIndex: [UUID: [String: Int]] {
        if stockPositionIndexDirty {
            rebuildStockPositionIndex()
            stockPositionIndexDirty = false
        }
        return _stockPositionIndex
    }

    // 父项目 ID 缓存：让 isParentProject 从 O(N) projects.contains 变 O(1) Set.contains。
    // 458 项目的 plan 页 PlannedProjectsView.shortageCount 之前是 458 × O(458) = O(N²) ≈ 210K 次比较，
    // 这一改下来直接降到 O(N)。
    private var _parentIdsCache: Set<UUID> = []
    private var parentIdsCacheDirty = true
    private var parentIds: Set<UUID> {
        if parentIdsCacheDirty {
            _parentIdsCache = Set(projects.compactMap { $0.parentId })
            parentIdsCacheDirty = false
        }
        return _parentIdsCache
    }

    // findColor(byCode:) 字典缓存：把每种 BeadColor 的 mardCode / cocoCode / manmanCode /
    // panpanCode / mixiaowoCode / kakaCode 都做成大写 key 进字典，O(1) 查替代原本的
    // M 次线扫 + M × 5 次 .uppercased() 分配。MARD 优先，仅当主键未占用时插入其它品牌 code。
    private var _colorLookupIndex: [String: BeadColor] = [:]
    private var colorLookupIndexDirty = true
    private var colorLookupIndex: [String: BeadColor] {
        if colorLookupIndexDirty {
            rebuildColorLookupIndex()
            colorLookupIndexDirty = false
        }
        return _colorLookupIndex
    }

    private func rebuildColorLookupIndex() {
        var dict: [String: BeadColor] = [:]
        // 第一轮：MARD 主键优先
        for color in beadColors {
            let key = color.mardCode.uppercased()
            if !key.isEmpty {
                dict[key] = color
            }
        }
        // 第二轮：其它品牌 code 兜底（已被 MARD 主键占用的不覆盖）
        for color in beadColors {
            let extras = [color.cocoCode, color.manmanCode, color.panpanCode, color.mixiaowoCode, color.kakaCode]
            for code in extras where !code.isEmpty {
                let key = code.uppercased()
                if dict[key] == nil {
                    dict[key] = color
                }
            }
        }
        _colorLookupIndex = dict
    }

    // SwiftData ModelContext
    // internal (而非 private)：ThumbnailMigrationCoordinator 需要经 `modelContext?.container`
    // 拿 ModelContainer 派生后台 context 跑迁移（迁移的 SwiftData I/O 全部离主线程）
    var modelContext: ModelContext? {
        didSet { imageLoader = modelContext.map { ProjectImageLoader(container: $0.container) } }
    }

    /// 视图取图的**后台**入口。视图层（列表 / 日历 / 详情）一律走它，不要再调
    /// 本类的 `fetchProject*Data` —— 那些是 `@MainActor` 同步 fetch，正是用户
    /// `.ips` 里主线程栈 `sqlite3_step → _platform_memmove` 的来源。
    /// 详见 `ProjectImageLoader` 头注释。
    private(set) var imageLoader: ProjectImageLoader?

    // 数据加载完成标志，防止在数据未加载时意外保存空数据
    private var isDataLoaded = false

    // 各实体加载成功标志，防止加载失败后保存时误删数据
    private var brandsLoadedSuccessfully = false
    private var stocksLoadedSuccessfully = false
    private var projectsLoadedSuccessfully = false
    private var customColorsLoadedSuccessfully = false

    // 防止 saveData() 重入（如 .inactive → .background 快速连续触发）
    private var isSaving = false

    // 防止重复触发持久层全量读取
    private var isLoadingPersistentStore = false
    /// 首次持久层读取必须离开 MainActor，否则 SwiftData 首次开库、关系 fault 和大表扫描
    /// 会发生在首帧之前，用户只能看到系统白色启动画面。
    ///
    /// `private(set)`：测试需要 `await manager.initialLoadTask?.value` 做确定性等待，
    /// 跟 `HistoryManager.loadTask` 同一约定，避免测试退化成轮询 sleep。
    private(set) var initialLoadTask: Task<Void, Never>?
    /// 在途持久层读取（首次加载 **和** 后台 refresh 共用）的代次。每次「重新发起 /
    /// 超时作废 / 用户改走本地模式」都会 +1，后台任务回到 MainActor 时代次对不上就整份丢弃。
    ///
    /// 这是把读取改成异步之后必须补的一道闸：同步版本里「在途」窗口是 0，
    /// 现在这个窗口有几百毫秒到数秒，期间用户完全可能已经点了「以本地模式继续」
    /// 并开始改数据 —— 过期结果绝不允许覆盖内存。
    private var initialLoadGeneration: UInt64 = 0
    /// 首次读取的超时看门狗。SwiftData 首次开库 / CloudKit 首次握手卡死时，
    /// `await` 不会自己返回，UI 会永远停在转圈且没有任何出口按钮。
    private var initialLoadTimeoutTask: Task<Void, Never>?
    /// 超过这个时间仍未拿到结果，就把这次读取判为失败，放出「重试 / 本地模式 / 关闭 iCloud」出口。
    /// 取值偏保守：正常冷启动实测约 220ms，首次 CloudKit 同步慢也很少超过 10s。
    ///
    /// 非 `let` 仅仅是为了让测试能调到几十毫秒去覆盖超时分支 —— 生产代码不要改它。
    var initialLoadTimeout: TimeInterval = 20
    /// 老版本 UserDefaults → SwiftData 迁移每次启动最多尝试一次。
    /// 迁移是**无去重的裸 insert**，超时作废 + 自动重试叠加时若跑第二遍会直接把品牌/库存翻倍。
    private static var hasAttemptedLegacyMigrationThisLaunch = false
    /// 首次加载完成后、由变更通知/回前台触发的后台全量刷新的在途任务。
    /// 跟 `initialLoadTask` 分开管：refresh 没有 loading 遮罩，失败/过期一律静默丢弃，
    /// 不进入错误重试 UI。`private(set)` 供测试 `await refreshTask?.value` 确定性等待。
    private(set) var refreshTask: Task<Void, Never>?
    private var refreshTimeoutTask: Task<Void, Never>?
    /// refresh 超时上限。卡死的 refresh 不影响可见 UI，但会让 `isLoadingPersistentStore`
    /// 永远为 true —— 后续所有 refresh 都被 defer 吞掉，数据从此不再刷新。到点作废回收旗子。
    /// 非 `let` 仅为测试能调小覆盖超时分支 —— 生产代码不要改它。
    var refreshTimeout: TimeInterval = 30
    /// 主存储写入代次：saveData 每次成功落盘 +1。后台 refresh 在 fetch 启动时记下当前值，
    /// apply 时对不上说明 fetch 期间发生过写入 —— 那份结果已过期，必须丢弃重排。
    private var persistentWriteGeneration: UInt64 = 0
    private var hasCompletedInitialPersistentLoad = false
    private var initialLoadAttemptCount = 0
    private let maxAutomaticInitialLoadAttempts = 3
    private var pendingAutomaticRetryWorkItem: DispatchWorkItem?
    // 用户已主动选择以本地模式继续使用（绕过持久层加载，避免 UI 永久卡死）
    @Published private(set) var isUsingLocalFallbackMode: Bool = false

    private struct DeferredRefreshRequest {
        let reason: String
        let preserveInMemoryOnFailure: Bool
        let debounceSeconds: TimeInterval?
    }
    private var deferredRefreshRequest: DeferredRefreshRequest?

    // 远程变更刷新防抖
    private var remoteRefreshWorkItem: DispatchWorkItem?
    private var remoteRefreshScheduledAt: Date?
    private var lastPersistentRefreshAt: Date = .distantPast
    private let minimumRefreshInterval: TimeInterval = 1.5

    // 全量清空授权（防止异常空数据被误同步到 iCloud）
    private var fullPurgeAuthorizedUntil: Date?

    // 仅在显式删除品牌（删除/合并）时记录，避免把意外缺失误判为“本地删除”
    private var pendingDeletedBrandIDs: Set<UUID> = []

    // 保存基线：用于 iCloud 同步冲突管理（仅写入本地改动，避免覆盖远端新数据）
    private var baselineBrandsByID: [UUID: Brand] = [:]
    private var baselineStocksByID: [UUID: BrandStock] = [:]
    private var baselineProjectsByID: [UUID: ProjectRecord] = [:]
    private var baselineCustomColorsByID: [UUID: CustomColor] = [:]
    private var baselineCurrentBrandId: UUID?
    private var baselinePurchaseRecords: [PurchaseRecord] = []

    private struct InMemorySnapshot {
        let beadColors: [BeadColor]
        let projects: [ProjectRecord]
        let customColors: [CustomColor]
        let purchaseRecords: [PurchaseRecord]
        let brands: [Brand]
        let brandStocks: [BrandStock]
        let currentBrandId: UUID?
        let isDataLoaded: Bool
        let brandsLoadedSuccessfully: Bool
        let stocksLoadedSuccessfully: Bool
        let projectsLoadedSuccessfully: Bool
        let customColorsLoadedSuccessfully: Bool
    }

    /// 后台 ModelContext 只把纯值类型结果交回 MainActor；SwiftData @Model 实例绝不跨线程。
    /// 这里刻意用**编译器检查的** `Sendable`（而不是 `@unchecked`）—— 成员模型都已显式声明
    /// `Sendable`，将来谁往 `Brand` / `ProjectRecord` 里塞了引用类型（UIImage、闭包……），
    /// 编译器会直接在那个模型上报错，而不是让它悄悄跨 `Task.detached` 边界。
    private struct InitialPersistentLoadResult: Sendable {
        var brands: [Brand]? = nil
        var brandStocks: [BrandStock]? = nil
        var projects: [ProjectRecord]? = nil
        var customColors: [CustomColor]? = nil
        var projectIDsWithFinishedImage: Set<UUID>? = nil
        var projectIDsWithThumbnail: Set<UUID>? = nil
        var projectIDsWithPatternGrid: Set<UUID>? = nil
        var projectIDsWithDisplayThumbnail: Set<UUID>? = nil
        var errors: [String: String] = [:]
    }

    private struct LegacyMigrationKeys: Sendable {
        let brands: String
        let stocks: String
        let projects: String
        let completed: String
    }

    // 历史记录管理器
    private var historyManager: HistoryManager { HistoryManager.shared }

    // UserDefaults keys (用于迁移和当前品牌ID)
    private let beadColorsKey = "beadColors"
    private let projectsKey = "projects"
    private let brandsKey = "brands"
    private let brandStocksKey = "brandStocks"
    private let currentBrandIdKey = "currentBrandId"
    private let migrationCompletedKey = "swiftDataMigrationCompleted"
    private let customColorsKey = "customColors"
    private let purchaseRecordsKey = "purchaseRecords"
    private let hasExistingDataKey = "hasExistingData"

    // 计算属性：当前选中的品牌
    var currentBrand: Brand? {
        guard let id = currentBrandId else { return nil }
        return brands.first { $0.id == id }
    }

    // 计算属性：当前品牌的色号体系
    var currentColorSystem: ColorSystem {
        currentBrand?.colorSystem ?? .mard
    }

    // 计算属性：当前品牌的库存
    var currentBrandStocks: [BrandStock] {
        guard let brandId = currentBrandId else { return [] }
        return brandStocks.filter { $0.brandId == brandId }
    }

    // 带 ModelContext 的初始化器
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        // `didSet` 在 init 里的赋值上**不会**触发，必须手动建一次，
        // 否则视图层拿到的 imageLoader 恒为 nil，取图全部静默返回空。
        self.imageLoader = ProjectImageLoader(container: modelContext.container)
        logInfo("init_with_model_context")
        initializeDefaultColors()
        logInfo("default_colors_loaded", metadata: ["count": beadColors.count])  // 启动耗时探针：色卡 JSON 解析完成
    }

    // 默认初始化器（用于 Preview）
    init() {
        logInfo("init_preview_mode")
        loadDataFromUserDefaults()
        if beadColors.isEmpty {
            initializeDefaultColors()
        }
    }

    private func logInfo(_ event: String, metadata: [String: Any] = [:]) {
        AppLogger.shared.info("InventoryManager", event, metadata: metadata)
    }

    private func logWarning(_ event: String, metadata: [String: Any] = [:]) {
        AppLogger.shared.warning("InventoryManager", event, metadata: metadata)
    }

    private func logError(_ event: String, metadata: [String: Any] = [:]) {
        AppLogger.shared.error("InventoryManager", event, metadata: metadata)
    }

    var hasCompletedInitialLoad: Bool {
        hasCompletedInitialPersistentLoad
    }

    func retryInitialLoad(reason: String = "manualRetry") {
        pendingAutomaticRetryWorkItem?.cancel()
        pendingAutomaticRetryWorkItem = nil
        initialLoadAttemptCount = 0
        initialLoadErrorMessage = nil
        // 作废可能还在途的上一轮后台读取，并把旗子交还给新一轮，
        // 否则 `loadData` 会被 `isLoadingPersistentStore` 挡住，用户点「重试」毫无反应。
        discardInFlightInitialLoad(reason: reason)
        performInitialLoadIfNeeded(reason: reason, force: true)
    }

    /// 让在途的首次后台读取作废：代次 +1 之后，它回到 MainActor 时会自行丢弃结果。
    ///
    /// 无法真正取消 —— SwiftData 的 `context.fetch` 不响应 Task 取消，只能让结果失效。
    private func discardInFlightInitialLoad(reason: String) {
        initialLoadTimeoutTask?.cancel()
        initialLoadTimeoutTask = nil
        refreshTimeoutTask?.cancel()
        refreshTimeoutTask = nil
        guard isLoadingPersistentStore || initialLoadTask != nil || refreshTask != nil else { return }
        initialLoadGeneration &+= 1
        initialLoadTask = nil
        refreshTask = nil
        isLoadingPersistentStore = false
        logWarning("initial_load_in_flight_discarded", metadata: [
            "reason": reason,
            "generation": initialLoadGeneration
        ])
    }

    /// 用户主动放弃等待 iCloud 同步，进入"只读浏览"模式。
    ///
    /// 此模式下：
    /// - 解除加载屏蔽，允许用户浏览当前内存中的数据（可能为空，也可能是 partial-load 后保留的 snapshot）；
    /// - `saveData()` 会被 `isUsingLocalFallbackMode` 守卫整体跳过，
    ///   避免把内存中可能过期的版本覆盖 CloudKit 上更新的数据；
    /// - 下一次 refresh 成功（来自 CloudKit 通知或 scenePhase.active）会调用
    ///   `finishInitialLoadSuccess()`，自动清掉 fallback 标志并恢复正常写入。
    ///
    /// 调用方需要保证不在 `isLoadingPersistentStore` 期间触发，否则正在进行的
    /// `loadData` 仍会在收尾阶段把内存覆盖；下方实现里也加了二次保护。
    func continueInLocalFallbackMode(reason: String = "userOptedOutOfWaiting") {
        pendingAutomaticRetryWorkItem?.cancel()
        pendingAutomaticRetryWorkItem = nil
        // 关键：解除 UI 屏蔽之前先让在途读取作废。用户从这一刻起就能编辑内存里的数据，
        // 若干秒后后台读取才返回 —— 不作废的话它会直接把用户刚改的内容整份盖掉。
        // 同步版本里这个窗口是 0，所以原来不需要这道闸。
        discardInFlightInitialLoad(reason: reason)
        isInitialLoadInProgress = false
        initialLoadErrorMessage = nil
        isUsingLocalFallbackMode = true

        // 颜色数据来源于本地 JSON，不依赖持久层。空状态下补一份让基础界面可用。
        if beadColors.isEmpty {
            beadColors = loadAllColorsFromJSON()
        }

        // 仅解除 UI 屏蔽，不更新 isDataLoaded / loaded* 标志，
        // 由 saveData() 上方的 fallback 守卫直接拦截写入。
        hasCompletedInitialPersistentLoad = true
        logWarning("initial_load_user_opted_local_fallback", metadata: [
            "reason": reason,
            "isLoadingInFlight": isLoadingPersistentStore
        ])
    }

    // MARK: - 品牌管理

    @discardableResult
    func addBrand(name: String, colorSystem: ColorSystem = .mard, defaultStock: Int = 1000, selectedColors: Set<String>? = nil) -> Brand {
        let maxOrder = brands.map { $0.sortOrder }.max() ?? -1
        let brand = Brand(
            name: name,
            sortOrder: maxOrder + 1,
            colorSystem: colorSystem
        )
        brands.append(brand)

        // 为新品牌初始化库存
        initializeStockForBrand(brand.id, defaultStock: defaultStock, selectedColors: selectedColors)

        // 如果没有当前品牌，设为当前品牌
        if currentBrandId == nil {
            currentBrandId = brand.id
        }

        saveData()

        // 记录历史
        historyManager.recordBrand(type: .brandAdd, brand: brand)

        return brand
    }

    func updateBrand(_ brand: Brand) {
        if let index = brands.firstIndex(where: { $0.id == brand.id }) {
            brands[index] = brand
            saveData()
        }
    }

    func updateBrand(_ brandId: UUID, name: String) {
        if let index = brands.firstIndex(where: { $0.id == brandId }) {
            let oldName = brands[index].name
            brands[index].name = name
            saveData()

            // 记录历史
            historyManager.recordBrand(type: .brandUpdate, brand: brands[index], oldName: oldName)
        }
    }

    func updateBrandLowStockThreshold(_ brandId: UUID, threshold: Int) {
        if let index = brands.firstIndex(where: { $0.id == brandId }) {
            brands[index].lowStockThreshold = threshold
            saveData()
        }
    }

    /// 获取品牌的低库存阈值，如果品牌不存在则返回默认值100
    func getLowStockThreshold(for brandId: UUID) -> Int {
        brands.first(where: { $0.id == brandId })?.lowStockThreshold ?? 100
    }

    func deleteBrand(_ brandId: UUID) -> Bool {
        // 记录历史（在删除前获取品牌信息）
        if let brand = brands.first(where: { $0.id == brandId }) {
            historyManager.recordBrand(type: .brandDelete, brand: brand)
        }

        // 标记为显式删除，saveData() 才会真正删除持久层记录
        pendingDeletedBrandIDs.insert(brandId)

        // 删除品牌及其库存
        brands.removeAll { $0.id == brandId }
        brandStocks.removeAll { $0.brandId == brandId }

        // 如果删除的是当前选中的品牌，切换到第一个品牌
        if currentBrandId == brandId {
            currentBrandId = brands.first?.id
        }

        saveData()
        return true
    }

    /// 合并品牌：将源品牌的所有数据转移到目标品牌，然后删除源品牌
    @discardableResult
    func mergeBrands(sourceBrandId: UUID, targetBrandId: UUID) -> Bool {
        // 1. 校验：两个品牌都存在且不相同
        guard sourceBrandId != targetBrandId,
              let sourceBrand = brands.first(where: { $0.id == sourceBrandId }),
              brands.contains(where: { $0.id == targetBrandId }) else {
            return false
        }

        // 2. 合并 BrandStock
        let sourceStocks = brandStocks.filter { $0.brandId == sourceBrandId }
        for sourceStock in sourceStocks {
            if let targetIndex = brandStocks.firstIndex(where: {
                $0.brandId == targetBrandId && $0.mardCode == sourceStock.mardCode
            }) {
                // 目标品牌已有该色号 → 累加 stock 和 used
                brandStocks[targetIndex].stock += sourceStock.stock
                brandStocks[targetIndex].used += sourceStock.used
                // 如果源色号未隐藏，目标也取消隐藏
                if !sourceStock.isHidden {
                    brandStocks[targetIndex].isHidden = false
                }
            } else {
                // 目标品牌没有该色号 → 创建新 BrandStock
                let newStock = BrandStock(
                    brandId: targetBrandId,
                    mardCode: sourceStock.mardCode,
                    stock: sourceStock.stock,
                    used: sourceStock.used,
                    isHidden: sourceStock.isHidden
                )
                brandStocks.append(newStock)
            }
        }
        // 删除源品牌的所有 brandStocks
        brandStocks.removeAll { $0.brandId == sourceBrandId }

        // 3. 更新 Projects：将 brandId == sourceBrandId 的改为 targetBrandId
        for i in projects.indices {
            if projects[i].brandId == sourceBrandId {
                projects[i].brandId = targetBrandId
            }
            // 同时更新 beadUsage 中的 brandId
            for j in projects[i].beadUsage.indices {
                if projects[i].beadUsage[j].brandId == sourceBrandId {
                    projects[i].beadUsage[j] = BeadUsage(
                        id: projects[i].beadUsage[j].id,
                        colorCode: projects[i].beadUsage[j].colorCode,
                        brandId: targetBrandId,
                        quantity: projects[i].beadUsage[j].quantity,
                        isDeducted: projects[i].beadUsage[j].isDeducted
                    )
                }
            }
        }

        // 4. 更新 PurchaseRecords：将 brandId == sourceBrandId 的改为 targetBrandId
        for i in purchaseRecords.indices {
            if purchaseRecords[i].brandId == sourceBrandId {
                purchaseRecords[i] = PurchaseRecord(
                    id: purchaseRecords[i].id,
                    name: purchaseRecords[i].name,
                    date: purchaseRecords[i].date,
                    brandId: targetBrandId,
                    items: purchaseRecords[i].items,
                    note: purchaseRecords[i].note
                )
            }
        }

        // 5. 处理当前品牌：如果当前选中的是源品牌，切换到目标品牌
        if currentBrandId == sourceBrandId {
            currentBrandId = targetBrandId
        }

        // 6. 删除源品牌
        pendingDeletedBrandIDs.insert(sourceBrandId)
        brands.removeAll { $0.id == sourceBrandId }

        // 7. 记录历史
        historyManager.recordBrand(type: .brandDelete, brand: sourceBrand)

        // 8. 保存数据
        saveData()

        return true
    }

    func selectBrand(_ brandId: UUID) {
        if brands.contains(where: { $0.id == brandId }) {
            currentBrandId = brandId
            saveCurrentBrandId()
        }
    }

    // MARK: - 品牌库存操作

    func initializeStockForBrand(_ brandId: UUID, defaultStock: Int = 1000, selectedColors: Set<String>? = nil) {
        // 获取该品牌的色号体系
        let colorSystem = brands.first(where: { $0.id == brandId })?.colorSystem ?? .mard

        // 为预设颜色初始化库存
        for color in beadColors {
            // 非 MARD 体系时，跳过没有对应编码的颜色
            if !color.hasCode(for: colorSystem) {
                continue
            }

            // 如果指定了 selectedColors，则只有选中的颜色才有库存，未选中的标记为隐藏
            let isSelected = selectedColors?.contains(color.mardCode) ?? true
            let stock = BrandStock(
                brandId: brandId,
                mardCode: color.mardCode,
                stock: isSelected ? defaultStock : 0,
                used: 0,
                isHidden: !isSelected
            )
            brandStocks.append(stock)
        }

        // 为自定义色号初始化库存
        for customColor in customColors {
            let stock = BrandStock(
                brandId: brandId,
                mardCode: customColor.mardCode,
                stock: 0,  // 自定义色号默认库存为0
                used: 0,
                isHidden: false
            )
            brandStocks.append(stock)
        }
    }

    func getStock(brandId: UUID, mardCode: String) -> BrandStock? {
        // 快路径：索引命中且行内容匹配。
        if let i = stockPositionIndex[brandId]?[mardCode], i < brandStocks.count {
            let stock = brandStocks[i]
            if stock.brandId == brandId && stock.mardCode == mardCode {
                return stock
            }
            // 命中到这里说明索引指向了不匹配的行——属于"索引被绕过维护"的 bug。
            // DEBUG 立刻暴露；release 走 AppLogger 上报到日志流，再线性扫描兜底
            // 避免给用户错数据。两条信号至少一条会被开发者看到，不让 bug 静默。
            assertionFailure(
                "stockPositionIndex stale at [\(brandId)][\(mardCode)] → row \(i)"
            )
            logError("stock_index_stale", metadata: [
                "brandId": "\(brandId)",
                "mardCode": mardCode,
                "row": i
            ])
        }
        // 慢路径：索引缺 key。正常情况是「真的没这条记录」→ 线性扫描返回 nil。
        // 异常情况是「索引漏 key 但数组里有这一行」→ 这才是 bug，要单独上报。
        let hit = brandStocks.first { $0.brandId == brandId && $0.mardCode == mardCode }
        if hit != nil, stockPositionIndex[brandId]?[mardCode] == nil {
            assertionFailure(
                "stockPositionIndex missing key for existing row [\(brandId)][\(mardCode)]"
            )
            logError("stock_index_missing_key", metadata: [
                "brandId": "\(brandId)",
                "mardCode": mardCode
            ])
        }
        return hit
    }

    private func rebuildStockPositionIndex() {
        var index: [UUID: [String: Int]] = [:]
        for (i, s) in brandStocks.enumerated() {
            // 与所有 mutator 的 firstIndex(where:) 保持一致：重复行只记第一条，
            // 避免索引指向 last-write 而 mutator 改 first-write 导致读写错位。
            if index[s.brandId]?[s.mardCode] == nil {
                index[s.brandId, default: [:]][s.mardCode] = i
            }
        }
        _stockPositionIndex = index
    }

    func updateStock(brandId: UUID, mardCode: String, newStock: Int) {
        if let index = brandStocks.firstIndex(where: {
            $0.brandId == brandId && $0.mardCode == mardCode
        }) {
            let oldStock = brandStocks[index].stock
            let newValue = max(0, newStock)
            brandStocks[index].stock = newValue
            // 如果是隐藏的色号，自动取消隐藏
            if brandStocks[index].isHidden {
                brandStocks[index].isHidden = false
            }
            saveData()

            // 记录历史
            historyManager.recordStockChange(
                type: .stockUpdate,
                brandId: brandId,
                mardCode: mardCode,
                oldValue: oldStock,
                newValue: newValue,
                changeAmount: newValue - oldStock
            )
        }
    }

    func addStock(brandId: UUID, mardCode: String, amount: Int) {
        if let index = brandStocks.firstIndex(where: {
            $0.brandId == brandId && $0.mardCode == mardCode
        }) {
            let oldStock = brandStocks[index].stock
            brandStocks[index].stock += amount
            // 如果是隐藏的色号，自动取消隐藏
            if brandStocks[index].isHidden {
                brandStocks[index].isHidden = false
            }
            saveData()

            // 记录历史（仅当不是撤回操作导致的负数调整时）
            if amount > 0 {
                historyManager.recordStockChange(
                    type: .stockAdd,
                    brandId: brandId,
                    mardCode: mardCode,
                    oldValue: oldStock,
                    newValue: brandStocks[index].stock,
                    changeAmount: amount
                )
            }
        }
    }

    /// 增加 used（即"使用/扣减库存"），并记录 stockDeduct 历史。
    /// EditStockSheet 的负数调整路径应走这个方法，避免绕过 HistoryManager。
    @discardableResult
    func useStock(brandId: UUID, mardCode: String, amount: Int) -> Bool {
        guard amount > 0,
              let index = brandStocks.firstIndex(where: {
                  $0.brandId == brandId && $0.mardCode == mardCode
              })
        else { return false }
        let oldUsed = brandStocks[index].used
        brandStocks[index].used += amount
        saveData()
        historyManager.recordStockChange(
            type: .stockDeduct,
            brandId: brandId,
            mardCode: mardCode,
            oldValue: oldUsed,
            newValue: brandStocks[index].used,
            changeAmount: amount
        )
        return true
    }

    /// 直接把 used 设为目标值（EditStockSheet "直接设置" 模式用）。
    /// 内部按 delta 记录 stockDeduct 或 stockUpdate 历史，不绕过 HistoryManager。
    @discardableResult
    func updateUsed(brandId: UUID, mardCode: String, newUsed: Int) -> Bool {
        guard newUsed >= 0,
              let index = brandStocks.firstIndex(where: {
                  $0.brandId == brandId && $0.mardCode == mardCode
              })
        else { return false }
        let oldUsed = brandStocks[index].used
        guard newUsed != oldUsed else { return false }
        brandStocks[index].used = newUsed
        saveData()
        // 增加视为扣减,减少视为校正
        let delta = newUsed - oldUsed
        historyManager.recordStockChange(
            type: delta > 0 ? .stockDeduct : .stockUpdate,
            brandId: brandId,
            mardCode: mardCode,
            oldValue: oldUsed,
            newValue: newUsed,
            changeAmount: abs(delta)
        )
        return true
    }

    /// 批量导入库存（累加模式）
    /// - Parameters:
    ///   - brandId: 目标品牌 ID
    ///   - items: 导入条目列表 [(色号, 数量)]
    ///   - unhideColors: 是否自动取消隐藏（默认 true）
    /// - Returns: 成功导入的条目数
    @discardableResult
    func importStock(brandId: UUID, items: [(colorCode: String, quantity: Int)], unhideColors: Bool = true) -> Int {
        var successCount = 0
        var totalAdded = 0

        // 品牌使用的色号体系（决定如何把用户输入码翻译为 mardCode）
        let colorSystem = brands.first(where: { $0.id == brandId })?.colorSystem ?? .mard

        for item in items {
            // 把用户输入的色号（可能是 kakaCode/cocoCode 等）翻译为内部存储的 mardCode
            let mardCode: String
            if colorSystem == .mard {
                mardCode = item.colorCode
            } else if let match = findColor(byCode: item.colorCode, preferSystem: colorSystem) {
                mardCode = match.mardCode
            } else {
                continue
            }

            if let index = brandStocks.firstIndex(where: {
                $0.brandId == brandId && $0.mardCode == mardCode
            }) {
                let oldStock = brandStocks[index].stock
                brandStocks[index].stock += item.quantity
                totalAdded += item.quantity

                // 自动取消隐藏
                if unhideColors && brandStocks[index].isHidden {
                    brandStocks[index].isHidden = false
                }

                successCount += 1

                // 记录历史
                historyManager.recordStockChange(
                    type: .stockAdd,
                    brandId: brandId,
                    mardCode: mardCode,
                    oldValue: oldStock,
                    newValue: brandStocks[index].stock,
                    changeAmount: item.quantity
                )
            }
        }

        if successCount > 0 {
            saveData()
        }

        return successCount
    }

    func deductFromStock(brandId: UUID, colorCode: String, amount: Int, shouldSave: Bool = true) -> Bool {
        // 先找到对应的 mardCode
        guard let color = findColor(byCode: colorCode) else { return false }

        if let index = brandStocks.firstIndex(where: {
            $0.brandId == brandId && $0.mardCode == color.mardCode
        }) {
            brandStocks[index].used += amount
            // 如果是隐藏的色号，自动取消隐藏
            if brandStocks[index].isHidden {
                brandStocks[index].isHidden = false
            }
            if shouldSave {
                saveData()
            }
            return true
        }
        return false
    }

    /// 撤回库存扣减（不记录历史）
    func revertFromStock(brandId: UUID, colorCode: String, amount: Int, shouldSave: Bool = true) -> Bool {
        guard let color = findColor(byCode: colorCode) else { return false }

        if let index = brandStocks.firstIndex(where: {
            $0.brandId == brandId && $0.mardCode == color.mardCode
        }) {
            brandStocks[index].used -= amount
            if shouldSave {
                saveData()
            }
            return true
        }
        return false
    }

    /// 撤回计划执行：恢复项目状态和库存（按每条 usage 的 brandId 恢复，支持跨品牌扣减的撤回）
    func revertPlanExecute(projectId: UUID, brandId: UUID, beadUsages: [(colorCode: String, quantity: Int)]) -> Bool {
        guard let index = projects.firstIndex(where: { $0.id == projectId }) else {
            return false
        }

        // 优先按每条 beadUsage 自带的 brandId 恢复库存；若无则回退到传入的 brandId
        let projectUsages = projects[index].beadUsage
        for usage in beadUsages {
            let usageBrandId = projectUsages.first(where: { $0.colorCode == usage.colorCode })?.brandId ?? brandId
            _ = revertFromStock(brandId: usageBrandId, colorCode: usage.colorCode, amount: usage.quantity, shouldSave: false)
        }

        // 恢复项目状态
        projects[index].isPlanned = true
        projects[index].brandId = nil
        projects[index].executedDate = nil
        projects[index].beadUsage = projects[index].beadUsage.map { usage in
            BeadUsage(id: usage.id, colorCode: usage.colorCode, brandId: nil,
                      quantity: usage.quantity, isDeducted: false)
        }

        saveData()
        return true
    }

    // MARK: - 品牌统计

    func totalStock(for brandId: UUID) -> Int {
        brandStocks.filter { $0.brandId == brandId && !$0.isHidden }.reduce(0) { $0 + $1.stock }
    }

    func totalUsed(for brandId: UUID) -> Int {
        brandStocks.filter { $0.brandId == brandId && !$0.isHidden }.reduce(0) { $0 + $1.used }
    }

    func totalAvailable(for brandId: UUID) -> Int {
        brandStocks.filter { $0.brandId == brandId && !$0.isHidden }.reduce(0) { $0 + $1.available }
    }

    func lowStockColors(for brandId: UUID) -> [BrandStock] {
        let threshold = getLowStockThreshold(for: brandId)
        return brandStocks.filter { $0.brandId == brandId && !$0.isHidden && $0.available < threshold }
    }

    // MARK: - 隐藏色号管理

    /// 隐藏指定品牌的色号（清零库存）
    func hideColor(brandId: UUID, mardCode: String) {
        guard let index = brandStocks.firstIndex(where: {
            $0.brandId == brandId && $0.mardCode == mardCode
        }) else { return }

        // 清零库存并标记隐藏
        brandStocks[index].stock = 0
        brandStocks[index].used = 0
        brandStocks[index].isHidden = true

        saveData()
    }

    /// 取消隐藏指定品牌的色号（恢复默认库存）
    func unhideColor(brandId: UUID, mardCode: String, defaultStock: Int = 1000) {
        guard let index = brandStocks.firstIndex(where: {
            $0.brandId == brandId && $0.mardCode == mardCode
        }) else { return }

        // 取消隐藏并恢复默认库存
        brandStocks[index].isHidden = false
        brandStocks[index].stock = defaultStock
        brandStocks[index].used = 0

        saveData()
    }

    /// 批量取消隐藏色号
    func unhideColors(brandId: UUID, mardCodes: [String], defaultStock: Int = 1000) {
        for mardCode in mardCodes {
            if let index = brandStocks.firstIndex(where: {
                $0.brandId == brandId && $0.mardCode == mardCode
            }) {
                brandStocks[index].isHidden = false
                brandStocks[index].stock = defaultStock
                brandStocks[index].used = 0
            }
        }
        saveData()
    }

    /// 获取指定品牌的隐藏色号列表
    func hiddenColors(for brandId: UUID) -> [BrandStock] {
        brandStocks.filter { $0.brandId == brandId && $0.isHidden }
    }

    /// 获取指定品牌隐藏色号的数量
    func hiddenColorCount(for brandId: UUID) -> Int {
        brandStocks.filter { $0.brandId == brandId && $0.isHidden }.count
    }

    // MARK: - 自定义色号管理

    /// 添加自定义色号
    @discardableResult
    func addCustomColor(colorCode: String, colorHex: String, colorName: String = "") -> CustomColor? {
        // 检查色号是否已存在（包括预设颜色）
        let normalizedCode = colorCode.uppercased().trimmingCharacters(in: .whitespaces)
        let customMardCode = "#\(normalizedCode)"

        // 检查是否与预设颜色冲突
        if beadColors.contains(where: {
            $0.mardCode.uppercased() == normalizedCode ||
            $0.cocoCode.uppercased() == normalizedCode ||
            $0.manmanCode.uppercased() == normalizedCode ||
            $0.panpanCode.uppercased() == normalizedCode ||
            $0.mixiaowoCode.uppercased() == normalizedCode ||
            $0.kakaCode.uppercased() == normalizedCode
        }) {
            return nil
        }

        // 检查是否与已有自定义色号冲突
        if customColors.contains(where: {
            $0.colorCode.uppercased() == normalizedCode ||
            $0.mardCode.uppercased() == customMardCode
        }) {
            return nil
        }

        let customColor = CustomColor(
            colorCode: normalizedCode,
            colorHex: colorHex.replacingOccurrences(of: "#", with: ""),
            colorName: colorName
        )
        customColors.append(customColor)

        // 为所有品牌初始化该自定义色号的库存（默认隐藏，需要用户手动取消隐藏）
        for brand in brands {
            let stock = BrandStock(
                brandId: brand.id,
                mardCode: customColor.mardCode,
                stock: 0,
                used: 0,
                isHidden: true  // 自定义色号默认隐藏
            )
            brandStocks.append(stock)
        }

        saveData()
        return customColor
    }

    /// 更新自定义色号
    func updateCustomColor(id: UUID, colorCode: String? = nil, colorHex: String? = nil, colorName: String? = nil) -> Bool {
        guard let index = customColors.firstIndex(where: { $0.id == id }) else {
            return false
        }

        let oldMardCode = customColors[index].mardCode

        if let newCode = colorCode {
            let normalizedCode = newCode.uppercased().trimmingCharacters(in: .whitespaces)
            // 检查新色号是否冲突（排除自己）
            if customColors.contains(where: { $0.id != id && $0.colorCode.uppercased() == normalizedCode }) {
                return false
            }
            customColors[index].colorCode = normalizedCode

            // 更新所有品牌库存中的 mardCode
            let newMardCode = "#\(normalizedCode)"
            for i in brandStocks.indices where brandStocks[i].mardCode == oldMardCode {
                // 需要创建新的 BrandStock 因为 mardCode 是 let
                let oldStock = brandStocks[i]
                brandStocks[i] = BrandStock(
                    id: oldStock.id,
                    brandId: oldStock.brandId,
                    mardCode: newMardCode,
                    stock: oldStock.stock,
                    used: oldStock.used,
                    isHidden: oldStock.isHidden
                )
            }
        }

        if let newHex = colorHex {
            customColors[index].colorHex = newHex.replacingOccurrences(of: "#", with: "")
        }

        if let newName = colorName {
            customColors[index].colorName = newName
        }

        customColors[index].updatedAt = Date()
        saveData()
        return true
    }

    /// 删除自定义色号
    func deleteCustomColor(id: UUID) -> Bool {
        guard let index = customColors.firstIndex(where: { $0.id == id }) else {
            return false
        }

        let mardCode = customColors[index].mardCode

        // 删除所有品牌中该颜色的库存记录
        brandStocks.removeAll { $0.mardCode == mardCode }

        // 删除自定义色号
        customColors.remove(at: index)

        saveData()
        return true
    }

    /// 根据 ID 获取自定义色号
    func getCustomColor(id: UUID) -> CustomColor? {
        customColors.first { $0.id == id }
    }

    /// 根据色号获取自定义色号（兼容旧 C_ 前缀）
    func getCustomColor(byCode code: String) -> CustomColor? {
        let normalizedCode = code.uppercased().trimmingCharacters(in: .whitespaces)
        return customColors.first { custom in
            let customColorCode = custom.colorCode.uppercased()
            let oldMardCode = "C_\(customColorCode)"
            return customColorCode == normalizedCode ||
                   custom.mardCode.uppercased() == normalizedCode ||
                   oldMardCode == normalizedCode
        }
    }

    /// 检查色号是否为自定义色号（兼容旧 C_ 前缀）
    func isCustomColor(_ mardCode: String) -> Bool {
        mardCode.hasPrefix("#") || mardCode.hasPrefix("C_") || customColors.contains { $0.colorCode.uppercased() == mardCode.uppercased() }
    }

    // MARK: - 数据迁移

    /// 迁移旧 SDProjectRecord：补充 colorSystemRaw 字段（nil → "MARD"）
    func migrateProjectColorSystem() {
        guard let context = modelContext else { return }
        // fallback 模式下也要避免 context.save()：迁移会写持久层并触发 CloudKit 同步，
        // 同样有覆盖云端真实数据的风险。等用户重启切回普通模式或 opt-out 后再走这条路径。
        if isUsingLocalFallbackMode {
            logWarning("migrate_project_color_system_skipped_local_fallback")
            return
        }
        do {
            let descriptor = FetchDescriptor<SDProjectRecord>()
            let records = try context.fetch(descriptor)
            var updated = false
            for record in records {
                if record.colorSystemRaw == nil {
                    record.colorSystemRaw = ColorSystem.mard.rawValue
                    updated = true
                }
            }
            if updated {
                try context.save()
                logInfo("migrate_project_color_system_saved")
            }
        } catch {
            print("[DataMigration] migrateProjectColorSystem error: \(error)")
            logError("migrate_project_color_system_failed", metadata: ["error": "\(error)"])
        }
    }

    /// 应用回到前台时刷新 SwiftData，拉取 iCloud 端已合并的数据
    func refreshFromPersistentStore(reason: String, preserveInMemoryOnFailure: Bool = true) {
        guard modelContext != nil else {
            logWarning("refresh_skipped_no_model_context", metadata: ["reason": reason])
            return
        }
        guard hasCompletedInitialPersistentLoad else {
            if isLoadingPersistentStore {
                deferRefreshUntilLoadFinishes(
                    reason: reason,
                    preserveInMemoryOnFailure: preserveInMemoryOnFailure
                )
                logInfo("refresh_deferred_during_initial_load", metadata: ["reason": reason])
            } else {
                performInitialLoadIfNeeded(reason: reason)
            }
            return
        }
        guard !isSaving else {
            logWarning("refresh_skipped_while_saving", metadata: ["reason": reason])
            return
        }
        guard !isLoadingPersistentStore else {
            deferRefreshUntilLoadFinishes(
                reason: reason,
                preserveInMemoryOnFailure: preserveInMemoryOnFailure
            )
            logWarning("refresh_skipped_while_loading", metadata: ["reason": reason])
            return
        }
        lastPersistentRefreshAt = Date()
        print("[InventoryManager] 前台刷新数据: \(reason)")
        logInfo("refresh_from_persistent_store", metadata: [
            "reason": reason,
            "preserveInMemoryOnFailure": preserveInMemoryOnFailure
        ])
        loadData(preserveInMemoryOnFailure: preserveInMemoryOnFailure)
    }

    func performInitialLoadIfNeeded(reason: String, force: Bool = false) {
        guard modelContext != nil else {
            // 自动重试如果撞到这里会陷入死循环（attemptCount 不递增、不再调度），
            // UI 永远卡转圈。立即把错误透出给用户，让重试/本地模式按钮可见。
            logError("initial_load_skipped_no_model_context", metadata: ["reason": reason])
            pendingAutomaticRetryWorkItem?.cancel()
            pendingAutomaticRetryWorkItem = nil
            isInitialLoadInProgress = false
            initialLoadErrorMessage = String(localized: "数据库未就绪，请重启应用后再试。")
            return
        }
        guard !hasCompletedInitialPersistentLoad else { return }
        guard !isLoadingPersistentStore else {
            logWarning("initial_load_skipped_while_loading", metadata: ["reason": reason])
            return
        }
        if !force && initialLoadErrorMessage != nil {
            logWarning("initial_load_blocked_after_failure", metadata: ["reason": reason])
            return
        }

        initialLoadAttemptCount += 1
        isInitialLoadInProgress = true
        if force {
            initialLoadErrorMessage = nil
        }
        let preserveInMemoryOnFailure = force || initialLoadAttemptCount > 1
        lastPersistentRefreshAt = Date()
        logInfo("initial_load_triggered", metadata: [
            "reason": reason,
            "attempt": initialLoadAttemptCount,
            "force": force,
            "preserveInMemoryOnFailure": preserveInMemoryOnFailure
        ])
        loadData(preserveInMemoryOnFailure: preserveInMemoryOnFailure)
    }

    func cancelScheduledRefresh(reason: String) {
        guard remoteRefreshWorkItem != nil || remoteRefreshScheduledAt != nil else { return }
        remoteRefreshWorkItem?.cancel()
        remoteRefreshWorkItem = nil
        remoteRefreshScheduledAt = nil
        logInfo("schedule_refresh_cancelled", metadata: ["reason": reason])
    }

    /// 远程变更到达时的防抖刷新（避免 CloudKit 短时间多次通知导致频繁全量 reload）
    func scheduleRefreshFromPersistentStore(reason: String, debounceSeconds: TimeInterval = 1.2, retryCount: Int = 0) {
        guard modelContext != nil else {
            logWarning("schedule_refresh_skipped_no_model_context", metadata: ["reason": reason])
            return
        }
        guard hasCompletedInitialPersistentLoad else {
            if isLoadingPersistentStore {
                deferRefreshUntilLoadFinishes(
                    reason: reason,
                    preserveInMemoryOnFailure: true,
                    debounceSeconds: debounceSeconds
                )
                logInfo("schedule_refresh_deferred_during_initial_load", metadata: [
                    "reason": reason,
                    "retryCount": retryCount
                ])
            } else {
                performInitialLoadIfNeeded(reason: reason)
            }
            return
        }
        guard !isLoadingPersistentStore else {
            deferRefreshUntilLoadFinishes(
                reason: reason,
                preserveInMemoryOnFailure: true,
                debounceSeconds: debounceSeconds
            )
            logWarning("schedule_refresh_skipped_while_loading", metadata: [
                "reason": reason,
                "retryCount": retryCount
            ])
            return
        }

        let now = Date()
        let remainingInterval = max(0, minimumRefreshInterval - now.timeIntervalSince(lastPersistentRefreshAt))
        let effectiveDebounce = max(debounceSeconds, remainingInterval)
        let fireDate = now.addingTimeInterval(effectiveDebounce)

        if let existingWorkItem = remoteRefreshWorkItem,
           !existingWorkItem.isCancelled,
           let scheduledAt = remoteRefreshScheduledAt {
            // 已经有更早的刷新任务时，保留更早任务，避免持续重排导致“始终不触发”。
            if scheduledAt <= fireDate {
                return
            }
            existingWorkItem.cancel()
        } else {
            remoteRefreshWorkItem?.cancel()
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.remoteRefreshWorkItem = nil
            self.remoteRefreshScheduledAt = nil
            guard !self.isSaving else {
                // 保存进行中时稍后再试，避免与 saveData 并发
                let maxRetryCount = 5
                guard retryCount < maxRetryCount else {
                    print("[InventoryManager] 远程刷新重试次数已达上限，放弃本轮刷新: \(reason)")
                    self.logWarning("schedule_refresh_retry_exhausted", metadata: [
                        "reason": reason,
                        "retryCount": retryCount
                    ])
                    return
                }
                self.scheduleRefreshFromPersistentStore(
                    reason: reason,
                    debounceSeconds: 1.0,
                    retryCount: retryCount + 1
                )
                return
            }
            self.refreshFromPersistentStore(reason: reason)
        }

        remoteRefreshWorkItem = workItem
        remoteRefreshScheduledAt = fireDate
        logInfo("schedule_refresh", metadata: [
            "reason": reason,
            "debounceSeconds": effectiveDebounce,
            "retryCount": retryCount
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + effectiveDebounce, execute: workItem)
    }

    private func deferRefreshUntilLoadFinishes(
        reason: String,
        preserveInMemoryOnFailure: Bool,
        debounceSeconds: TimeInterval? = nil
    ) {
        if let existing = deferredRefreshRequest {
            let mergedDebounce: TimeInterval?
            switch (existing.debounceSeconds, debounceSeconds) {
            case (nil, _), (_, nil):
                mergedDebounce = nil
            case let (lhs?, rhs?):
                mergedDebounce = min(lhs, rhs)
            }

            deferredRefreshRequest = DeferredRefreshRequest(
                reason: reason,
                preserveInMemoryOnFailure: existing.preserveInMemoryOnFailure || preserveInMemoryOnFailure,
                debounceSeconds: mergedDebounce
            )
        } else {
            deferredRefreshRequest = DeferredRefreshRequest(
                reason: reason,
                preserveInMemoryOnFailure: preserveInMemoryOnFailure,
                debounceSeconds: debounceSeconds
            )
        }

        logInfo("refresh_deferred_until_load_finishes", metadata: [
            "reason": reason,
            "debounceSeconds": debounceSeconds as Any
        ])
    }

    private func replayDeferredRefreshIfNeeded() {
        guard let request = deferredRefreshRequest else { return }
        deferredRefreshRequest = nil

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let debounceSeconds = request.debounceSeconds {
                self.scheduleRefreshFromPersistentStore(
                    reason: request.reason,
                    debounceSeconds: debounceSeconds
                )
            } else {
                self.refreshFromPersistentStore(
                    reason: request.reason,
                    preserveInMemoryOnFailure: request.preserveInMemoryOnFailure
                )
            }
        }
    }

    private func finishInitialLoadSuccess() {
        pendingAutomaticRetryWorkItem?.cancel()
        pendingAutomaticRetryWorkItem = nil
        isInitialLoadInProgress = false
        initialLoadErrorMessage = nil
        initialLoadAttemptCount = 0
        isUsingLocalFallbackMode = false
    }

    private func finishInitialLoadFailure(userMessage: String, metadata: [String: Any] = [:]) {
        guard !hasCompletedInitialPersistentLoad else { return }
        isInitialLoadInProgress = false

        if initialLoadAttemptCount < maxAutomaticInitialLoadAttempts {
            // 自动重试，避免 UI 永久卡在转圈：在 maxAutomaticInitialLoadAttempts=3 时
            // 实际产生约 1.5s / 3.0s 两次延迟（attempt=1 → 1.5s，attempt=2 → 3.0s）。
            // 注意延迟随 attemptCount 指数增长，调高上限会让总等待显著变长，
            // 如需调整请改下方 1.5 系数或基数 2，而不是 maxAutomaticInitialLoadAttempts。
            let delay = pow(2.0, Double(initialLoadAttemptCount - 1)) * 1.5
            // 中间失败也按 error 级别上报，避免 Sentry 看不到卡住前两轮发生了什么
            logError("initial_load_attempt_failed_will_retry", metadata: metadata.merging([
                "attempt": initialLoadAttemptCount,
                "maxAttempts": maxAutomaticInitialLoadAttempts,
                "delaySeconds": delay,
                "willRetry": true
            ]) { _, new in new })

            pendingAutomaticRetryWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingAutomaticRetryWorkItem = nil
                guard !self.hasCompletedInitialPersistentLoad else { return }
                self.performInitialLoadIfNeeded(reason: "automaticRetry", force: true)
            }
            pendingAutomaticRetryWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            return
        }

        initialLoadErrorMessage = userMessage
        logError("initial_load_retry_limit_reached", metadata: metadata.merging([
            "attempts": initialLoadAttemptCount
        ]) { _, new in new })
    }

    private func makeInMemorySnapshot() -> InMemorySnapshot {
        InMemorySnapshot(
            beadColors: beadColors,
            projects: projects,
            customColors: customColors,
            purchaseRecords: purchaseRecords,
            brands: brands,
            brandStocks: brandStocks,
            currentBrandId: currentBrandId,
            isDataLoaded: isDataLoaded,
            brandsLoadedSuccessfully: brandsLoadedSuccessfully,
            stocksLoadedSuccessfully: stocksLoadedSuccessfully,
            projectsLoadedSuccessfully: projectsLoadedSuccessfully,
            customColorsLoadedSuccessfully: customColorsLoadedSuccessfully
        )
    }

    private func restoreInMemorySnapshot(_ snapshot: InMemorySnapshot) {
        beadColors = snapshot.beadColors
        projects = snapshot.projects
        customColors = snapshot.customColors
        purchaseRecords = snapshot.purchaseRecords
        brands = snapshot.brands
        brandStocks = snapshot.brandStocks
        currentBrandId = snapshot.currentBrandId
        isDataLoaded = snapshot.isDataLoaded
        brandsLoadedSuccessfully = snapshot.brandsLoadedSuccessfully
        stocksLoadedSuccessfully = snapshot.stocksLoadedSuccessfully
        projectsLoadedSuccessfully = snapshot.projectsLoadedSuccessfully
        customColorsLoadedSuccessfully = snapshot.customColorsLoadedSuccessfully
    }

    private func makeMapByID<T: Identifiable>(_ items: [T]) -> [UUID: T] where T.ID == UUID {
        Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    private func refreshBaselines() {
        baselineBrandsByID = makeMapByID(brands)
        baselineStocksByID = makeMapByID(brandStocks)
        baselineProjectsByID = makeMapByID(projects)
        baselineCustomColorsByID = makeMapByID(customColors)
        baselineCurrentBrandId = currentBrandId
        baselinePurchaseRecords = purchaseRecords
    }

    private func hasModelChangesComparedToBaseline() -> Bool {
        let localBrandsByID = makeMapByID(brands)
        if localBrandsByID != baselineBrandsByID {
            return true
        }

        let localStocksByID = makeMapByID(brandStocks)
        if localStocksByID != baselineStocksByID {
            return true
        }

        let localProjectsByID = makeMapByID(projects)
        if localProjectsByID != baselineProjectsByID {
            return true
        }

        let localCustomColorsByID = makeMapByID(customColors)
        if localCustomColorsByID != baselineCustomColorsByID {
            return true
        }

        return false
    }

    private func hasMetadataChangesComparedToBaseline() -> Bool {
        if currentBrandId != baselineCurrentBrandId {
            return true
        }
        if purchaseRecords != baselinePurchaseRecords {
            return true
        }
        return false
    }

    // MARK: - 数据持久化 (SwiftData)

    /// 首次启动专用：在独立 ModelContext 上读取持久层，只在完成后回 MainActor 原子提交。
    /// 后台任务返回的只有 struct / Set 等值类型，不会把 SwiftData @Model 实例跨线程传递。
    private func startInitialPersistentLoad(
        from container: ModelContainer,
        preserveInMemoryOnFailure: Bool
    ) {
        let fallbackSnapshot = preserveInMemoryOnFailure ? makeInMemorySnapshot() : nil
        let loadedBeadColors = loadAllColorsFromJSON()
        var loadedCurrentBrandId = currentBrandId
        if let idString = UserDefaults.standard.string(forKey: currentBrandIdKey),
           let id = UUID(uuidString: idString) {
            loadedCurrentBrandId = id
        }
        var loadedPurchaseRecords = purchaseRecords
        if let data = UserDefaults.standard.data(forKey: purchaseRecordsKey),
           let decoded = try? JSONDecoder().decode([PurchaseRecord].self, from: data) {
            loadedPurchaseRecords = decoded
        }

        isDataLoaded = false
        brandsLoadedSuccessfully = false
        stocksLoadedSuccessfully = false
        projectsLoadedSuccessfully = false
        customColorsLoadedSuccessfully = false

        // 迁移每次启动只允许尝试一次：超时作废后会自动重试，而 migrateLegacyUserDefaults
        // 是裸 insert 没有去重，跑第二遍等于把老用户的品牌/库存/项目全部翻倍。
        // 失败不置 completed 标志，下次启动仍会重试。
        let needsMigration = !UserDefaults.standard.bool(forKey: migrationCompletedKey)
            && !Self.hasAttemptedLegacyMigrationThisLaunch
        if needsMigration {
            Self.hasAttemptedLegacyMigrationThisLaunch = true
        }
        let migrationKeys = LegacyMigrationKeys(
            brands: brandsKey,
            stocks: brandStocksKey,
            projects: projectsKey,
            completed: migrationCompletedKey
        )

        initialLoadGeneration &+= 1
        let generation = initialLoadGeneration
        logInfo("load_data_started", metadata: [
            "preserveInMemoryOnFailure": preserveInMemoryOnFailure,
            "execution": "background",
            "generation": generation,
            "needsMigration": needsMigration
        ])

        startInitialLoadTimeoutWatchdog(
            generation: generation,
            fallbackSnapshot: fallbackSnapshot,
            loadedBeadColors: loadedBeadColors
        )

        initialLoadTask = Task { @MainActor [weak self] in
            // 迁移写入必须带后台任务断言：这条路径是老用户升级后第一次启动才会走的一次性
            // 写库，用户此时把 App 切后台，进程被挂起会让 save 半途而废。
            let result = await AppBackgroundTaskManager.shared.performAsync(named: "InventoryInitialLoad") {
                await Self.fetchInitialPersistentData(
                    from: container,
                    needsMigration: needsMigration,
                    migrationKeys: migrationKeys
                )
            }
            guard let self else { return }
            // 代次对不上 = 这次读取已经被超时作废 / 被用户的重试或本地模式取代。
            // 直接丢弃，且**不要**碰 isLoadingPersistentStore —— 那面旗子已经属于新一轮读取。
            guard generation == self.initialLoadGeneration else {
                self.logWarning("initial_load_result_discarded_stale", metadata: [
                    "resultGeneration": generation,
                    "currentGeneration": self.initialLoadGeneration
                ])
                return
            }
            defer {
                self.initialLoadTask = nil
                self.isLoadingPersistentStore = false
                self.replayDeferredRefreshIfNeeded()
            }
            self.initialLoadTimeoutTask?.cancel()
            self.initialLoadTimeoutTask = nil
            self.applyInitialPersistentLoad(
                result,
                fallbackSnapshot: fallbackSnapshot,
                loadedBeadColors: loadedBeadColors,
                loadedCurrentBrandId: loadedCurrentBrandId,
                loadedPurchaseRecords: loadedPurchaseRecords
            )
        }
    }

    /// 首次读取的超时看门狗。
    ///
    /// 改成异步之后新增的失败模式：SwiftData 首次开库或 CloudKit 首次握手如果卡死，
    /// `await` 永远不返回 —— 旧的同步实现至少还会被系统看门狗杀掉，异步版本则是
    /// 一个永远转圈、连「以本地模式继续」按钮都不出现的软死锁（出口按钮只在
    /// `initialLoadErrorMessage != nil` 时渲染）。这里到点就把在途读取判负，
    /// 交回既有失败机制去放出口。
    private func startInitialLoadTimeoutWatchdog(
        generation: UInt64,
        fallbackSnapshot: InMemorySnapshot?,
        loadedBeadColors: [BeadColor]
    ) {
        initialLoadTimeoutTask?.cancel()
        let timeout = initialLoadTimeout
        initialLoadTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard generation == self.initialLoadGeneration else { return }
            guard !self.hasCompletedInitialPersistentLoad else { return }

            // 让在途结果作废（它回来时代次已经变了，会自行丢弃），把旗子交还给失败机制。
            self.initialLoadGeneration &+= 1
            self.initialLoadTask = nil
            self.initialLoadTimeoutTask = nil
            self.isLoadingPersistentStore = false

            self.logError("initial_load_timed_out", metadata: [
                "timeoutSeconds": timeout,
                "generation": generation
            ])
            if let fallbackSnapshot {
                self.restoreInMemorySnapshot(fallbackSnapshot)
            } else if self.beadColors.isEmpty {
                self.beadColors = loadedBeadColors
            }
            // 超时不再走自动重试阶梯：卡住的库重试一轮还是会卡满 timeout，三轮下来用户要
            // 盯着转圈将近一分钟才等到出口。把尝试次数打满，让错误 UI（重试 / 以本地模式继续 /
            // 关闭 iCloud 同步）立刻出来，把选择权交回用户。
            self.initialLoadAttemptCount = self.maxAutomaticInitialLoadAttempts
            self.finishInitialLoadFailure(
                userMessage: String(localized: "云端数据仍在同步中，请稍后重试。"),
                metadata: [
                    "failure": "timeout",
                    "timeoutSeconds": timeout
                ]
            )
            self.replayDeferredRefreshIfNeeded()
        }
    }

    nonisolated private static func fetchInitialPersistentData(
        from container: ModelContainer,
        needsMigration: Bool,
        migrationKeys: LegacyMigrationKeys
    ) async -> InitialPersistentLoadResult {
        await Task.detached(priority: .userInitiated) {
            let startedAt = Date()
            let context = ModelContext(container)
            var result = InitialPersistentLoadResult()

            if needsMigration {
                migrateLegacyUserDefaults(into: context, keys: migrationKeys)
            }

            do {
                let descriptor = FetchDescriptor<SDBrand>(
                    sortBy: [SortDescriptor(\.sortOrder)]
                )
                let loaded = try context.fetch(descriptor).map { $0.toStruct() }
                result.brands = loaded
                AppLogger.shared.info("InventoryManager", "load_brands_success", metadata: [
                    "count": loaded.count,
                    "execution": "background"
                ])
            } catch {
                result.errors["brands"] = "\(error)"
                AppLogger.shared.error("InventoryManager", "load_brands_failed", metadata: [
                    "error": "\(error)",
                    "execution": "background"
                ])
            }

            do {
                let descriptor = FetchDescriptor<SDBrandStock>()
                let loaded = try context.fetch(descriptor).map { $0.toStruct() }
                result.brandStocks = loaded
                AppLogger.shared.info("InventoryManager", "load_stocks_success", metadata: [
                    "count": loaded.count,
                    "execution": "background"
                ])
            } catch {
                result.errors["stocks"] = "\(error)"
                AppLogger.shared.error("InventoryManager", "load_stocks_failed", metadata: [
                    "error": "\(error)",
                    "execution": "background"
                ])
            }

            do {
                // 只投影 metadata 列；beadUsages relationship 会在这个后台 context 上 fault。
                var descriptor = FetchDescriptor<SDProjectRecord>(
                    sortBy: [SortDescriptor(\.date, order: .reverse)]
                )
                descriptor.propertiesToFetch = [
                    \.id, \.name, \.date, \.totalBeads, \.brandId, \.isArchived,
                    \.parentId, \.isPlanned, \.executedDate, \.completedDate, \.colorSystemRaw
                ]
                let loaded = try context.fetch(descriptor).map { $0.toMetadataStruct() }
                result.projects = loaded
                AppLogger.shared.info("InventoryManager", "load_projects_success", metadata: [
                    "count": loaded.count,
                    "execution": "background"
                ])
            } catch {
                result.errors["projects"] = "\(error)"
                AppLogger.shared.error("InventoryManager", "load_projects_failed", metadata: [
                    "error": "\(error)",
                    "execution": "background"
                ])
            }

            do {
                let descriptor = FetchDescriptor<SDCustomColor>(
                    sortBy: [SortDescriptor(\.createdAt)]
                )
                let loaded = try context.fetch(descriptor).map { $0.toStruct() }
                result.customColors = loaded
                AppLogger.shared.info("InventoryManager", "load_custom_colors_success", metadata: [
                    "count": loaded.count,
                    "execution": "background"
                ])
            } catch {
                result.errors["customColors"] = "\(error)"
                AppLogger.shared.error("InventoryManager", "load_custom_colors_failed", metadata: [
                    "error": "\(error)",
                    "execution": "background"
                ])
            }

            // 四个 blob 存在性集合优先走 raw SQLite 头部扫描。
            //
            // 不能用 SwiftData 的 `#Predicate { $0.blob != nil }`：哪怕 propertiesToFetch
            // 只投影 id，SwiftData 也会把命中行的 blob 内容 SELECT 进内存（实测 120 条
            // × 10.5MB → +1.26GB，见 InitialLoadMemoryDiagnosticTests）。四个查询跑在每次
            // 加载/refresh 里，真实体量库上进程峰值实测 5.7GB —— 真机被 jetsam 杀死，
            // 就是用户报的「转圈转着转着闪退」。SQLite 判 IS NOT NULL 只读记录头，零物化。
            //
            // 回退策略按失败类型分叉，**不是**一律回退：
            //   .unsupportedStore（in-memory 测试库 / 未来 schema 变更）→ 永久状态，
            //     回退 SwiftData 查询是对的（这类库都很小，高内存路径无害）。
            //   .transient（SQLITE_BUSY / I-O）→ **不回退**。SwiftData 的 BLOB 谓词实测
            //     +1.26GB，而 store 忙的时候恰恰是最不该吃内存的时候 —— 瘦身 pass 正在跑的
            //     时候尤其容易撞上。留 nil 让调用方保留上一次的集合，等下次刷新重来。
            if result.brands != nil, result.brandStocks != nil, result.projects != nil {
                let scanResult = (container.configurations.first?.url).map {
                    ProjectBlobExistenceScanner.scan(storeURL: $0)
                } ?? .failure(.unsupportedStore)

                switch scanResult {
                case .success(let existence):
                    result.projectIDsWithFinishedImage = existence.finishedImage
                    result.projectIDsWithThumbnail = existence.thumbnail
                    result.projectIDsWithPatternGrid = existence.patternGrid
                    result.projectIDsWithDisplayThumbnail = existence.displayThumbnail
                case .failure(.transient):
                    AppLogger.shared.warning(
                        "InventoryManager",
                        "blob_existence_scan_transient_keeping_previous",
                        metadata: ["execution": "background"]
                    )
                case .failure(.unsupportedStore):
                    AppLogger.shared.error(
                        "InventoryManager",
                        "blob_existence_scan_fallback_swiftdata",
                        metadata: ["execution": "background"]
                    )
                    do {
                        let existence = try Self.legacyBlobExistenceFetch(context: context)
                        result.projectIDsWithFinishedImage = existence.finishedImage
                        result.projectIDsWithThumbnail = existence.thumbnail
                        result.projectIDsWithPatternGrid = existence.patternGrid
                        result.projectIDsWithDisplayThumbnail = existence.displayThumbnail
                    } catch {
                        result.errors["projectBlobMetadata"] = "\(error)"
                        AppLogger.shared.error(
                            "InventoryManager",
                            "project_blob_meta_refresh_failed",
                            metadata: ["error": "\(error)", "execution": "background"]
                        )
                    }
                }
            }

            AppLogger.shared.info("InventoryManager", "load_data_fetch_completed", metadata: [
                "durationMs": Int(Date().timeIntervalSince(startedAt) * 1_000),
                "execution": "background",
                "errorCount": result.errors.count
            ])
            return result
        }.value
    }

    /// 旧版 SwiftData 存在性查询 —— 仅作 ProjectBlobExistenceScanner 的回退
    ///（in-memory 测试库没有 SQLite 文件、未来 schema 变更时）。
    /// ⚠️ 大库上会把命中行的 blob 物化进内存（见调用方注释），不要变回主路径。
    nonisolated private static func legacyBlobExistenceFetch(
        context: ModelContext
    ) throws -> ProjectBlobExistence {
        var finished = FetchDescriptor<SDProjectRecord>(
            predicate: #Predicate { $0.finishedImage != nil }
        )
        finished.propertiesToFetch = [\.id]
        var thumbnail = FetchDescriptor<SDProjectRecord>(
            predicate: #Predicate { $0.thumbnail != nil }
        )
        thumbnail.propertiesToFetch = [\.id]
        var patternGrid = FetchDescriptor<SDProjectRecord>(
            predicate: #Predicate { $0.patternGridData != nil }
        )
        patternGrid.propertiesToFetch = [\.id]
        var displayThumbnail = FetchDescriptor<SDProjectRecord>(
            predicate: #Predicate { $0.displayThumbnail != nil }
        )
        displayThumbnail.propertiesToFetch = [\.id]

        var existence = ProjectBlobExistence()
        existence.finishedImage = Set(try context.fetch(finished).map { $0.id })
        existence.thumbnail = Set(try context.fetch(thumbnail).map { $0.id })
        existence.patternGrid = Set(try context.fetch(patternGrid).map { $0.id })
        existence.displayThumbnail = Set(try context.fetch(displayThumbnail).map { $0.id })
        return existence
    }

    nonisolated private static func migrateLegacyUserDefaults(
        into context: ModelContext,
        keys: LegacyMigrationKeys
    ) {
        let defaults = UserDefaults.standard
        var migratedBrands = 0
        var migratedStocks = 0
        var migratedProjects = 0

        if let data = defaults.data(forKey: keys.brands),
           let decoded = try? JSONDecoder().decode([Brand].self, from: data) {
            migratedBrands = decoded.count
            for brand in decoded {
                context.insert(SDBrand(from: brand))
            }
        }
        if let data = defaults.data(forKey: keys.stocks),
           let decoded = try? JSONDecoder().decode([BrandStock].self, from: data) {
            migratedStocks = decoded.count
            for stock in decoded {
                context.insert(SDBrandStock(from: stock))
            }
        }
        if let data = defaults.data(forKey: keys.projects),
           let decoded = try? JSONDecoder().decode([ProjectRecord].self, from: data) {
            migratedProjects = decoded.count
            for project in decoded {
                context.insert(SDProjectRecord(from: project))
            }
        }

        do {
            try context.save()
            defaults.set(true, forKey: keys.completed)
            AppLogger.shared.info("InventoryManager", "legacy_migration_completed", metadata: [
                "brands": migratedBrands,
                "stocks": migratedStocks,
                "projects": migratedProjects,
                "execution": "background"
            ])
        } catch {
            context.rollback()
            AppLogger.shared.error("InventoryManager", "legacy_migration_failed", metadata: [
                "error": "\(error)",
                "execution": "background"
            ])
        }
    }

    private func applyInitialPersistentLoad(
        _ result: InitialPersistentLoadResult,
        fallbackSnapshot: InMemorySnapshot?,
        loadedBeadColors: [BeadColor],
        loadedCurrentBrandId initialCurrentBrandId: UUID?,
        loadedPurchaseRecords: [PurchaseRecord]
    ) {
        brandsLoadedSuccessfully = result.brands != nil
        stocksLoadedSuccessfully = result.brandStocks != nil
        projectsLoadedSuccessfully = result.projects != nil
        customColorsLoadedSuccessfully = result.customColors != nil

        let loadedBrands = result.brands ?? brands
        let loadedBrandStocks = result.brandStocks ?? brandStocks
        let loadedProjects = result.projects ?? projects
        let loadedCustomColors = result.customColors ?? customColors
        var loadedCurrentBrandId = initialCurrentBrandId

        let allLoaded = brandsLoadedSuccessfully
            && stocksLoadedSuccessfully
            && projectsLoadedSuccessfully
        guard allLoaded else {
            logError("load_data_partial_failure", metadata: [
                "brandsLoaded": brandsLoadedSuccessfully,
                "stocksLoaded": stocksLoadedSuccessfully,
                "projectsLoaded": projectsLoadedSuccessfully,
                "customColorsLoaded": customColorsLoadedSuccessfully,
                "execution": "background"
            ])
            if let fallbackSnapshot {
                restoreInMemorySnapshot(fallbackSnapshot)
            } else {
                beadColors = loadedBeadColors
            }
            finishInitialLoadFailure(
                userMessage: String(localized: "部分数据加载失败，请点击重试。"),
                metadata: [
                    "failure": "partialLoad",
                    "brandsLoaded": brandsLoadedSuccessfully,
                    "stocksLoaded": stocksLoadedSuccessfully,
                    "projectsLoaded": projectsLoadedSuccessfully,
                    "customColorsLoaded": customColorsLoadedSuccessfully,
                    "errors": result.errors
                ]
            )
            return
        }

        let allEmpty = loadedBrands.isEmpty
            && loadedBrandStocks.isEmpty
            && loadedProjects.isEmpty
            && loadedCustomColors.isEmpty
        let hadDataBefore = UserDefaults.standard.bool(forKey: hasExistingDataKey)

        if let snapshot = fallbackSnapshot {
            let suspiciousBrandDrop = snapshot.brands.count >= 3
                && !loadedBrands.isEmpty
                && loadedBrands.count * 2 < snapshot.brands.count
            let suspiciousStockDrop = snapshot.brandStocks.count >= 200
                && !loadedBrandStocks.isEmpty
                && loadedBrandStocks.count * 2 < snapshot.brandStocks.count
            if suspiciousBrandDrop || suspiciousStockDrop {
                restoreInMemorySnapshot(snapshot)
                finishInitialLoadFailure(
                    userMessage: String(localized: "云端数据仍在同步中，请稍后重试。"),
                    metadata: [
                        "failure": "suspiciousDrop",
                        "previousBrands": snapshot.brands.count,
                        "loadedBrands": loadedBrands.count,
                        "previousStocks": snapshot.brandStocks.count,
                        "loadedStocks": loadedBrandStocks.count
                    ]
                )
                return
            }
        }

        if allEmpty && hadDataBefore {
            if let fallbackSnapshot {
                restoreInMemorySnapshot(fallbackSnapshot)
            }
            finishInitialLoadFailure(
                userMessage: String(localized: "暂时无法确认已有数据，请稍后重试。"),
                metadata: ["failure": "unexpectedAllEmpty"]
            )
            return
        }

        if let selectedBrandId = loadedCurrentBrandId,
           !loadedBrands.contains(where: { $0.id == selectedBrandId }) {
            loadedCurrentBrandId = loadedBrands.first?.id
        }

        // 跟同步路径保持一致：真实数据接管 UI 是严格更优的状态，但用户并不知道，
        // 明确记一条日志，便于排查 "fallback 期间的写入丢失" 类问题。
        // （正常情况下走不到这里 —— `continueInLocalFallbackMode` 已经把在途读取作废了；
        //   留着是为了兜住将来新增的、不经过那条路径的 fallback 入口。）
        if isUsingLocalFallbackMode {
            logInfo("local_fallback_exited_on_successful_load", metadata: ["execution": "background"])
            isUsingLocalFallbackMode = false
        }

        brands = loadedBrands
        brandStocks = loadedBrandStocks
        projects = loadedProjects
        customColors = loadedCustomColors
        currentBrandId = loadedCurrentBrandId
        purchaseRecords = loadedPurchaseRecords
        beadColors = loadedBeadColors

        if let ids = result.projectIDsWithFinishedImage {
            projectIDsWithFinishedImage = ids
        }
        if let ids = result.projectIDsWithThumbnail {
            projectIDsWithThumbnail = ids
        }
        if let ids = result.projectIDsWithPatternGrid {
            projectIDsWithPatternGrid = ids
        }
        if let ids = result.projectIDsWithDisplayThumbnail {
            projectIDsWithDisplayThumbnail = ids
        }
        // 四个集合由 fetchInitialPersistentData 整批产出（scanner 或 legacy 都是要么全有
        // 要么全无），任一非 nil 即代表全量扫描成功过。
        if result.projectIDsWithThumbnail != nil {
            hasCompletedBlobMetadataScan = true
        }
        projectBlobsRevision &+= 1

        // 四个集合全是 nil = 扫描报了 `.transient`（库正忙），我们按约定保留了「上一次的值」。
        //
        // 问题是**冷启动时「上一次」就是空集**，而空集在下游不是「未知」而是「确定没有图」：
        // 拼图模式按钮 `.disabled(!hasThumbnail)` 全灰、日历一张成品图都不显示、
        // 详情页成品图区块整块隐藏。而 `refreshProjectBlobMetadata()` 只在 CloudKit 远端
        // 合并和批量写图时才被调用，`scenePhase == .active` 上没有挂 —— 撞上忙库的用户
        // 会一直残废到某次远端变更，或者重启进同一个忙库。
        //
        // 所以这里补一次有界重试。瘦身是空闲任务可以等，但「用户这一整个 session 看不到图」
        // 不能等。
        if result.projectIDsWithThumbnail == nil,
           result.projectIDsWithFinishedImage == nil,
           result.projectIDsWithPatternGrid == nil,
           result.projectIDsWithDisplayThumbnail == nil {
            logWarning("blob_metadata_unavailable_scheduling_retry", metadata: [
                "reason": "scanner reported transient during initial load"
            ])
            scheduleBlobMetadataRetry(attempt: 1)
        }

        isDataLoaded = true
        finishInitialLoadSuccess()
        hasCompletedInitialPersistentLoad = true
        if !allEmpty {
            UserDefaults.standard.set(true, forKey: hasExistingDataKey)
        }
        refreshBaselines()
        fixProjectConsistency()
        logInfo("load_data_completed", metadata: [
            "brands": brands.count,
            "stocks": brandStocks.count,
            "projects": projects.count,
            "customColors": customColors.count,
            "execution": "background"
        ])
    }

    func loadData(preserveInMemoryOnFailure: Bool = false) {
        guard !isLoadingPersistentStore else {
            logWarning("load_data_skipped_already_loading", metadata: [
                "preserveInMemoryOnFailure": preserveInMemoryOnFailure
            ])
            return
        }

        guard let context = modelContext else {
            // Preview / 无持久层模式：数据在 UserDefaults，量小，同步读取无碍。
            logWarning("load_data_use_user_defaults_mode")
            loadDataFromUserDefaults()
            return
        }

        isLoadingPersistentStore = true

        // 首次读取发生在 rootView.onAppear。同步 fetch 会挡住 SwiftUI 提交首帧 —— 白屏（PR #57）。
        if !hasCompletedInitialPersistentLoad {
            startInitialPersistentLoad(
                from: context.container,
                preserveInMemoryOnFailure: preserveInMemoryOnFailure
            )
            return
        }

        // 后续 refresh 同样必须离开主线程 —— 2026-08-05 用 2.4GB 拼图模式种子库实测：
        // CloudKit / 跨 context 保存触发的变更通知走到这条路径的旧同步实现，每次堵主线程
        // 2.0-2.7s，冷启动后 30s 内连发 4 次（共 ~9.7s）。此时 loading 遮罩早已消失，
        // 用户看到的是整个 App 冻住 —— 这正是 #51/#52/#57 三轮修完仍在报的「白屏」真凶。
        //
        // 旧实现保持同步的理由是「防止后台结果覆盖用户正在编辑的数据」；这个职责改由
        // apply 前的写入代次 + 基线脏检查闸门承担（见 startBackgroundRefresh）。
        startBackgroundRefresh(
            from: context.container,
            preserveInMemoryOnFailure: preserveInMemoryOnFailure
        )
    }

    /// 首次加载完成后的后台全量刷新。与 startInitialPersistentLoad 的关键差别：
    /// - 没有 loading 遮罩保护，失败/过期一律**静默丢弃**，绝不弹错误 UI；
    /// - apply 前多两道闸：写入代次（fetch 期间 saveData 落过盘 → 结果过期）和基线脏检查
    ///   （内存里有未保存编辑 → 一应用就整份盖掉）。命中任何一道就丢弃本次结果并延后重排，
    ///   等 auto-save 落盘、基线干净之后再刷；
    /// - 超时只回收 `isLoadingPersistentStore` 旗子，不打扰用户。
    private func startBackgroundRefresh(
        from container: ModelContainer,
        preserveInMemoryOnFailure: Bool
    ) {
        let fallbackSnapshot = preserveInMemoryOnFailure ? makeInMemorySnapshot() : nil
        let loadedBeadColors = loadAllColorsFromJSON()
        var loadedCurrentBrandId = currentBrandId
        if let idString = UserDefaults.standard.string(forKey: currentBrandIdKey),
           let id = UUID(uuidString: idString) {
            loadedCurrentBrandId = id
        }
        var loadedPurchaseRecords = purchaseRecords
        if let data = UserDefaults.standard.data(forKey: purchaseRecordsKey),
           let decoded = try? JSONDecoder().decode([PurchaseRecord].self, from: data) {
            loadedPurchaseRecords = decoded
        }

        initialLoadGeneration &+= 1
        let generation = initialLoadGeneration
        let writeGenerationAtStart = persistentWriteGeneration
        // refresh 永不做 legacy 迁移（首次加载已处理），keys 仅为复用同一个 fetch 函数。
        let migrationKeys = LegacyMigrationKeys(
            brands: brandsKey,
            stocks: brandStocksKey,
            projects: projectsKey,
            completed: migrationCompletedKey
        )
        logInfo("load_data_started", metadata: [
            "preserveInMemoryOnFailure": preserveInMemoryOnFailure,
            "execution": "background",
            "kind": "refresh",
            "generation": generation
        ])

        startRefreshTimeoutWatchdog(generation: generation)

        refreshTask = Task { @MainActor [weak self] in
            let result = await AppBackgroundTaskManager.shared.performAsync(named: "InventoryRefresh") {
                await Self.fetchInitialPersistentData(
                    from: container,
                    needsMigration: false,
                    migrationKeys: migrationKeys
                )
            }
            guard let self else { return }
            // 代次对不上 = 已被超时作废 / 被重试或本地模式取代。旗子属于新一轮，不碰。
            guard generation == self.initialLoadGeneration else {
                self.logWarning("refresh_result_discarded_stale_generation", metadata: [
                    "resultGeneration": generation,
                    "currentGeneration": self.initialLoadGeneration
                ])
                return
            }
            self.refreshTimeoutTask?.cancel()
            self.refreshTimeoutTask = nil

            // fetch 在途期间落过盘、或内存里有未保存的编辑：这份结果要么已过期、要么一应用
            // 就会把用户编辑整份盖掉。丢弃，延后重排（等 auto-save 把基线洗干净）。
            //
            // blob 单行直写（updateProjectThumbnail 等）故意不 bump 写入代次：它们只动
            // refresh 不读取的 blob 列 + 自己在内存维护的 projectIDsWith* 集合，且它们的
            // save 会再触发一次变更通知 → 新一轮 refresh 自然把集合补齐。
            if self.isSaving
                || self.persistentWriteGeneration != writeGenerationAtStart
                || self.hasModelChangesComparedToBaseline() {
                self.logInfo("refresh_result_discarded_dirty", metadata: [
                    "isSaving": self.isSaving,
                    "writeGenerationChanged": self.persistentWriteGeneration != writeGenerationAtStart
                ])
                self.refreshTask = nil
                self.isLoadingPersistentStore = false
                self.replayDeferredRefreshIfNeeded()
                self.scheduleRefreshFromPersistentStore(
                    reason: "refreshRetryAfterDirtyDiscard",
                    debounceSeconds: 3.0
                )
                return
            }

            self.applyInitialPersistentLoad(
                result,
                fallbackSnapshot: fallbackSnapshot,
                loadedBeadColors: loadedBeadColors,
                loadedCurrentBrandId: loadedCurrentBrandId,
                loadedPurchaseRecords: loadedPurchaseRecords
            )
            self.refreshTask = nil
            self.isLoadingPersistentStore = false
            self.replayDeferredRefreshIfNeeded()
        }
    }

    /// refresh 的超时看门狗：只回收状态旗子，不打扰用户（refresh 没有可见的加载 UI）。
    /// 不回收的话，卡死的 refresh 会让后续所有 refresh 永远被 defer 吞掉 —— 数据从此不再刷新。
    private func startRefreshTimeoutWatchdog(generation: UInt64) {
        refreshTimeoutTask?.cancel()
        let timeout = refreshTimeout
        refreshTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard generation == self.initialLoadGeneration else { return }
            self.initialLoadGeneration &+= 1   // 让在途结果作废（它回来时会自行丢弃）
            self.refreshTask = nil
            self.refreshTimeoutTask = nil
            self.isLoadingPersistentStore = false
            self.logError("refresh_timed_out", metadata: [
                "timeoutSeconds": timeout,
                "generation": generation
            ])
            self.replayDeferredRefreshIfNeeded()
        }
    }

    /// 修复项目数据一致性问题
    /// 只修复明确不一致的情况：有 executedDate 但 isPlanned 为 true
    private func fixProjectConsistency() {
        var needsSave = false

        for index in projects.indices {
            let project = projects[index]

            // 唯一的修复条件：有执行日期但状态仍为计划中
            // 这是明确的不一致状态，说明之前的保存失败了
            if project.isPlanned && project.executedDate != nil {
                print("[InventoryManager] 修复项目一致性: \(project.name) (有执行日期但状态为计划中)")
                logWarning("fix_project_consistency_applied", metadata: ["projectName": project.name])
                projects[index].isPlanned = false
                needsSave = true
            }
        }

        if needsSave {
            saveData()
            print("[InventoryManager] 已修复项目数据一致性")
            logInfo("fix_project_consistency_saved")
        }
    }

    func saveData() {
        guard let context = modelContext else { return }

        // 防止在数据未加载完成时保存空数据，导致覆盖原有数据
        guard isDataLoaded else {
            print("[InventoryManager] 警告：数据尚未加载完成，跳过保存")
            return
        }

        // 本地浏览模式：用户主动放弃等待 iCloud 同步，此时云端可能存在
        // 我们尚未读到的真实数据。saveData() 的 baseline-diff 会以当前内存版本
        // 覆盖 SwiftData/CloudKit 中可能更新的数据，造成静默数据丢失。
        // 因此在 fallback 模式下完全跳过持久化，等到下一次 refresh 成功
        // （finishInitialLoadSuccess 会清掉 isUsingLocalFallbackMode）后再放行。
        guard !isUsingLocalFallbackMode else {
            // logWarning 让 Sentry/AppLogger 能监测到有多少用户卡在 fallback。
            logWarning("save_skipped_local_fallback_mode")
            return
        }

        // 防止重入：.inactive → .background 快速连续触发时，避免并发修改 SwiftData 关系
        guard !isSaving else {
            print("[InventoryManager] 警告：saveData() 正在执行中，跳过重复调用")
            return
        }
        isSaving = true
        defer { isSaving = false }

        let hasModelChanges = hasModelChangesComparedToBaseline()
        let hasMetadataChanges = hasMetadataChangesComparedToBaseline()

        if !hasModelChanges && !hasMetadataChanges {
            print("[InventoryManager] 无本地改动，跳过保存")
            return
        }

        if !hasModelChanges && hasMetadataChanges {
            saveCurrentBrandId()
            savePurchaseRecords()
            baselineCurrentBrandId = currentBrandId
            baselinePurchaseRecords = purchaseRecords
            print("[InventoryManager] 仅元数据变更，执行轻量保存")
            return
        }

        // 保险丝：
        // 当本地主数据被“整体清空”且基线曾有数据时，默认阻止写回，
        // 仅允许在明确授权窗口内执行全量清空同步。
        let baselineHadData = !baselineBrandsByID.isEmpty
            || !baselineStocksByID.isEmpty
            || !baselineProjectsByID.isEmpty
            || !baselineCustomColorsByID.isEmpty
        let currentAllEmpty = brands.isEmpty
            && brandStocks.isEmpty
            && projects.isEmpty
            && customColors.isEmpty
        let isFullPurgeAuthorized = fullPurgeAuthorizedUntil.map { Date() <= $0 } ?? false

        if currentAllEmpty && baselineHadData && !isFullPurgeAuthorized {
            print("[InventoryManager] ⚠️ 拦截到未授权的全量清空保存，已阻止写入以防误同步到 iCloud")
            refreshFromPersistentStore(
                reason: "blockedUnexpectedFullPurge",
                preserveInMemoryOnFailure: false
            )
            return
        }

        AppBackgroundTaskManager.shared.perform(named: "InventorySave") {
            do {
                // 仅写入本地改动，避免把另一台设备新同步的数据“当作缺失”删除

                // 1. 品牌
                let existingBrands = try context.fetch(FetchDescriptor<SDBrand>())
                let existingBrandByID = Dictionary(existingBrands.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let localBrandByID = makeMapByID(brands)

                if brandsLoadedSuccessfully {
                    var remoteBrandsToAppend: [Brand] = []
                    var appliedBrandDeletionIDs = Set<UUID>()
                    for sdBrand in existingBrands where localBrandByID[sdBrand.id] == nil {
                        if pendingDeletedBrandIDs.contains(sdBrand.id) {
                            // 仅允许“显式删除”的品牌执行持久层删除
                            context.delete(sdBrand)
                            appliedBrandDeletionIDs.insert(sdBrand.id)
                        } else {
                            // 远端新增，合并进本地内存避免“看不见但下次可能被覆盖”
                            remoteBrandsToAppend.append(sdBrand.toStruct())
                        }
                    }
                    if !remoteBrandsToAppend.isEmpty {
                        brands.append(contentsOf: remoteBrandsToAppend)
                        brands.sort { $0.sortOrder < $1.sortOrder }
                    }

                    // 清理已处理完的待删 ID：
                    // 1) 本轮已成功删除
                    // 2) 持久层中已不存在（说明此前已删除/或无效 ID）
                    let existingBrandIDs = Set(existingBrands.map { $0.id })
                    let resolvedDeletedIDs = appliedBrandDeletionIDs.union(
                        pendingDeletedBrandIDs.subtracting(existingBrandIDs)
                    )
                    if !resolvedDeletedIDs.isEmpty {
                        pendingDeletedBrandIDs.subtract(resolvedDeletedIDs)
                    }
                }

                for brand in brands {
                    let baseline = baselineBrandsByID[brand.id]
                    let changedLocally = baseline == nil || baseline != brand

                    if let existing = existingBrandByID[brand.id] {
                        guard changedLocally else { continue }
                        existing.name = brand.name
                        existing.sortOrder = brand.sortOrder
                        existing.lowStockThreshold = brand.lowStockThreshold
                        existing.colorSystemRaw = brand.colorSystem.rawValue
                    } else if changedLocally {
                        context.insert(SDBrand(from: brand))
                    } else {
                        // 本地未改且持久层暂未命中：保守保留内存副本，避免误删/误隐藏品牌
                        continue
                    }
                }
                if let selectedBrandId = currentBrandId,
                   !brands.contains(where: { $0.id == selectedBrandId }) {
                    currentBrandId = brands.first?.id
                }

                // 2. 库存
                let existingStocks = try context.fetch(FetchDescriptor<SDBrandStock>())
                let existingStockByID = Dictionary(existingStocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let localStockByID = makeMapByID(brandStocks)

                if stocksLoadedSuccessfully {
                    var remoteStocksToAppend: [BrandStock] = []
                    for sdStock in existingStocks where localStockByID[sdStock.id] == nil {
                        if baselineStocksByID[sdStock.id] != nil {
                            context.delete(sdStock)
                        } else {
                            remoteStocksToAppend.append(sdStock.toStruct())
                        }
                    }
                    if !remoteStocksToAppend.isEmpty {
                        brandStocks.append(contentsOf: remoteStocksToAppend)
                    }
                }

                var staleLocalStockIDs = Set<UUID>()
                for stock in brandStocks {
                    let baseline = baselineStocksByID[stock.id]
                    let changedLocally = baseline == nil || baseline != stock

                    if let existing = existingStockByID[stock.id] {
                        guard changedLocally else { continue }
                        existing.brandId = stock.brandId
                        existing.mardCode = stock.mardCode
                        existing.stock = stock.stock
                        existing.used = stock.used
                        existing.isHidden = stock.isHidden
                    } else if changedLocally {
                        context.insert(SDBrandStock(from: stock))
                    } else {
                        staleLocalStockIDs.insert(stock.id)
                    }
                }
                if !staleLocalStockIDs.isEmpty {
                    brandStocks.removeAll { staleLocalStockIDs.contains($0.id) }
                }

                // 3. 项目
                //
                // **跟 loadData / HistoryManager.performSave 同型**：saveData 自 v2.0.x 起不再读写
                // blob 字段（见下方项目写回循环里的 ⚠️ 注释），diff 只消费 metadata + beadUsages 关系。
                // 不加 propertiesToFetch 的话，每次保存（进后台 / .inactive / 防抖保存）都会把全表
                // 4 个 blob 列物化进内存 —— 458 项目级用户场景即数 GB 瞬时峰值，jetsam 同型事故。
                // 后续对这些对象的属性更新 / context.delete 不受单列投影影响（SwiftData 按需 fault，
                // HistoryManager.performSave 的 metadata-only fetch + 写回是同一模式的既有先例）。
                var existingProjectsDescriptor = FetchDescriptor<SDProjectRecord>()
                existingProjectsDescriptor.propertiesToFetch = [
                    \.id, \.name, \.date, \.totalBeads, \.brandId, \.isArchived,
                    \.parentId, \.isPlanned, \.executedDate, \.completedDate, \.colorSystemRaw
                ]
                let existingProjects = try context.fetch(existingProjectsDescriptor)
                let existingProjectByID = Dictionary(existingProjects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let localProjectByID = makeMapByID(projects)

                if projectsLoadedSuccessfully {
                    var remoteProjectsToAppend: [ProjectRecord] = []
                    var remoteAppendedIDs = Set<UUID>()
                    for sdProject in existingProjects where localProjectByID[sdProject.id] == nil {
                        if baselineProjectsByID[sdProject.id] != nil {
                            context.delete(sdProject)
                        } else {
                            // 用 toMetadataStruct 而不是 toStruct —— 远端合并不要把 blob
                            // 物化进 in-memory projects 缓存，否则 CloudKit 同步触发的合并
                            // 会偷偷把内存峰值顶到 458 项目级用户被 jetsam 的水平。
                            remoteProjectsToAppend.append(sdProject.toMetadataStruct())
                            remoteAppendedIDs.insert(sdProject.id)
                        }
                    }
                    if !remoteProjectsToAppend.isEmpty {
                        projects.append(contentsOf: remoteProjectsToAppend)
                        projects.sort { $0.date > $1.date }
                        // ID 集合也要刷 —— 远端拿过来的项目可能本身就带 blob，UI 立刻就要
                        // 知道有没有图。这里只 fetch 一次（在 saveData 末尾再统一刷一次更稳，
                        // 但本路径已经在做差分写回，独立刷一次代价可接受）。
                        DispatchQueue.main.async { [weak self] in
                            self?.refreshProjectBlobMetadata()
                        }
                    }
                }

                var staleLocalProjectIDs = Set<UUID>()
                for project in projects {
                    let baseline = baselineProjectsByID[project.id]
                    let changedLocally = baseline == nil || baseline != project

                    if let existing = existingProjectByID[project.id] {
                        // 本地没改过，不写回，保留云端最新值
                        guard changedLocally else { continue }

                        // 更新项目基本属性
                        existing.name = project.name
                        existing.date = project.date
                        existing.totalBeads = project.totalBeads
                        existing.brandId = project.brandId
                        existing.isArchived = project.isArchived
                        existing.parentId = project.parentId
                        existing.isPlanned = project.isPlanned
                        existing.executedDate = project.executedDate
                        existing.completedDate = project.completedDate
                        existing.colorSystemRaw = project.colorSystem.rawValue
                        // ⚠️ 不再在 saveData 路径写 existing.thumbnail / existing.finishedImage /
                        // existing.patternGridData / existing.displayThumbnail ——
                        // 自 v2.0.x 起 `projects` 缓存里这四个字段恒为 nil（避免大 blob 物化进内存
                        // 撞 jetsam），如果还沿用旧 diff 写回，等于每次保存都把云端真数据用 nil
                        // 覆盖掉。这些字段改走 updateProjectThumbnail / updateProjectFinishedImage /
                        // updateProjectPatternGrid 直接对 SDProjectRecord 单 row 写入（带 blob 字段
                        // 同步）；displayThumbnail 迁移写回由 ThumbnailMigrationCoordinator 在后台
                        // ModelContext 上完成。

                        // 仅在本地项目有改动时同步 beadUsages，避免误删远端新变更
                        let newUsageIDs = Set(project.beadUsage.map { $0.id })
                        var existingUsages = existing.beadUsages ?? []

                        // 清理可能存在的重复 beadUsage（防止历史数据损坏导致后续崩溃）
                        // 区分"同一对象重复引用"与"不同对象但 id 相同"两种情况：
                        //   - 同一对象重复引用：仅移除多余引用，不 delete（保留该对象）
                        //   - 不同对象相同 id：保留首个，delete 其余实例
                        var keeperByID: [UUID: SDBeadUsage] = [:]
                        var indicesToRemove: [Int] = []
                        var objectsToDelete: [SDBeadUsage] = []
                        for (index, usage) in existingUsages.enumerated() {
                            if let keeper = keeperByID[usage.id] {
                                indicesToRemove.append(index)
                                if usage !== keeper {
                                    objectsToDelete.append(usage)
                                }
                            } else {
                                keeperByID[usage.id] = usage
                            }
                        }
                        for index in indicesToRemove.reversed() {
                            existingUsages.remove(at: index)
                        }
                        for obj in objectsToDelete {
                            context.delete(obj)
                        }

                        let existingUsageByID = Dictionary(existingUsages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                        let existingUsageIDs = Set(existingUsageByID.keys)

                        // 1. 删除不再存在的 beadUsage（先收集再删除，避免遍历时修改数组）
                        let usageIDsToDelete = existingUsageIDs.subtracting(newUsageIDs)
                        for usageID in usageIDsToDelete {
                            if let oldUsage = existingUsageByID[usageID] {
                                existingUsages.removeAll { $0.id == oldUsage.id }
                                context.delete(oldUsage)
                            }
                        }

                        // 2. 更新已存在的 beadUsage
                        for newUsage in project.beadUsage {
                            if let existingUsage = existingUsageByID[newUsage.id] {
                                existingUsage.colorCode = newUsage.colorCode
                                existingUsage.brandId = newUsage.brandId
                                existingUsage.quantity = newUsage.quantity
                                existingUsage.isDeducted = newUsage.isDeducted
                            }
                        }

                        // 3. 添加新的 beadUsage
                        let usageIDsToAdd = newUsageIDs.subtracting(existingUsageIDs)
                        for newUsage in project.beadUsage where usageIDsToAdd.contains(newUsage.id) {
                            existingUsages.append(SDBeadUsage(from: newUsage))
                        }
                        existing.beadUsages = existingUsages
                    } else if changedLocally {
                        context.insert(SDProjectRecord(from: project))
                    } else {
                        staleLocalProjectIDs.insert(project.id)
                    }
                }
                if !staleLocalProjectIDs.isEmpty {
                    projects.removeAll { staleLocalProjectIDs.contains($0.id) }
                }

                // 4. 自定义色号
                let existingCustomColors = try context.fetch(FetchDescriptor<SDCustomColor>())
                let existingCustomColorByID = Dictionary(existingCustomColors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let localCustomColorByID = makeMapByID(customColors)

                if customColorsLoadedSuccessfully {
                    var remoteCustomColorsToAppend: [CustomColor] = []
                    for sdColor in existingCustomColors where localCustomColorByID[sdColor.id] == nil {
                        if baselineCustomColorsByID[sdColor.id] != nil {
                            context.delete(sdColor)
                        } else {
                            remoteCustomColorsToAppend.append(sdColor.toStruct())
                        }
                    }
                    if !remoteCustomColorsToAppend.isEmpty {
                        customColors.append(contentsOf: remoteCustomColorsToAppend)
                        customColors.sort { $0.createdAt < $1.createdAt }
                    }
                }

                var staleLocalCustomColorIDs = Set<UUID>()
                for customColor in customColors {
                    let baseline = baselineCustomColorsByID[customColor.id]
                    let changedLocally = baseline == nil || baseline != customColor

                    if let existing = existingCustomColorByID[customColor.id] {
                        guard changedLocally else { continue }
                        existing.colorCode = customColor.colorCode
                        existing.colorHex = customColor.colorHex
                        existing.colorName = customColor.colorName
                        existing.updatedAt = customColor.updatedAt
                    } else if changedLocally {
                        context.insert(SDCustomColor(from: customColor))
                    } else {
                        staleLocalCustomColorIDs.insert(customColor.id)
                    }
                }
                if !staleLocalCustomColorIDs.isEmpty {
                    customColors.removeAll { staleLocalCustomColorIDs.contains($0.id) }
                }

                try context.save()
                // 写入代次 +1：作废所有 fetch 早于本次落盘的在途后台 refresh 结果
                //（它们读到的是保存前的旧数据，一应用会把刚保存的编辑从内存里抹掉）。
                persistentWriteGeneration &+= 1
                refreshBaselines()
                saveCurrentBrandId()
                savePurchaseRecords()

                // 同步 hasExistingDataKey：用户合法删空数据后重置标志，
                // 防止下次启动时误判为"SwiftData加载异常"而锁死
                let currentlyHasData = !brands.isEmpty || !brandStocks.isEmpty || !projects.isEmpty || !customColors.isEmpty
                UserDefaults.standard.set(currentlyHasData, forKey: hasExistingDataKey)

                // 消费一次全量清空授权
                if isFullPurgeAuthorized {
                    fullPurgeAuthorizedUntil = nil
                }
            } catch {
                print("[InventoryManager] ⚠️ 保存数据失败: \(error)")
                // 回滚 context 中所有未提交的变更，防止残留的删除/插入操作被后续 save 意外提交
                context.rollback()
            }
        }
    }

    private func savePurchaseRecords() {
        if let encoded = try? JSONEncoder().encode(purchaseRecords) {
            UserDefaults.standard.set(encoded, forKey: purchaseRecordsKey)
        }
    }

    private func saveCurrentBrandId() {
        if let id = currentBrandId {
            UserDefaults.standard.set(id.uuidString, forKey: currentBrandIdKey)
        }
    }

    // MARK: - 从 UserDefaults 迁移
    //
    // 同步版 migrateFromUserDefaults 已删除：refresh 路径全面异步化后它成了死代码。
    // 现役实现是 nonisolated static migrateLegacyUserDefaults —— 在首次加载的后台
    // ModelContext 上执行（见 fetchInitialPersistentData），每次启动最多尝试一次。

    // 从 UserDefaults 加载（用于 Preview 或无 ModelContext 时）
    // 注意：此模式不涉及 SwiftData，所以加载标志设为 true 是安全的
    private func loadDataFromUserDefaults() {
        // 加载颜色数据
        beadColors = loadAllColorsFromJSON()

        // 加载品牌
        if let data = UserDefaults.standard.data(forKey: brandsKey),
           let decoded = try? JSONDecoder().decode([Brand].self, from: data) {
            brands = decoded
        }

        // 加载品牌库存
        if let data = UserDefaults.standard.data(forKey: brandStocksKey),
           let decoded = try? JSONDecoder().decode([BrandStock].self, from: data) {
            brandStocks = decoded
        }

        // 加载项目记录
        if let data = UserDefaults.standard.data(forKey: projectsKey),
           let records = try? JSONDecoder().decode([ProjectRecord].self, from: data) {
            projects = records
        }

        // 加载当前品牌
        if let idString = UserDefaults.standard.string(forKey: currentBrandIdKey),
           let id = UUID(uuidString: idString) {
            currentBrandId = id
        }

        // 加载自定义色号
        if let data = UserDefaults.standard.data(forKey: customColorsKey),
           let decoded = try? JSONDecoder().decode([CustomColor].self, from: data) {
            customColors = decoded
        }

        // 加载运输中的购买记录
        if let data = UserDefaults.standard.data(forKey: purchaseRecordsKey),
           let decoded = try? JSONDecoder().decode([PurchaseRecord].self, from: data) {
            purchaseRecords = decoded
        }

        // UserDefaults 模式下，所有实体都视为"已加载"（不涉及 SwiftData 删除逻辑）
        brandsLoadedSuccessfully = true
        stocksLoadedSuccessfully = true
        projectsLoadedSuccessfully = true
        customColorsLoadedSuccessfully = true
        isDataLoaded = true
        hasCompletedInitialPersistentLoad = true
        finishInitialLoadSuccess()
        refreshBaselines()
        print("[InventoryManager] 数据从 UserDefaults 加载完成")
    }

    // MARK: - 库存操作

    func updateStock(for colorId: UUID, newStock: Int) {
        if let index = beadColors.firstIndex(where: { $0.id == colorId }) {
            beadColors[index].stock = max(0, newStock)
            saveData()
        }
    }

    func addStock(for colorId: UUID, amount: Int) {
        if let index = beadColors.firstIndex(where: { $0.id == colorId }) {
            beadColors[index].stock += amount
            saveData()
        }
    }

    func useBeads(for colorId: UUID, amount: Int) {
        if let index = beadColors.firstIndex(where: { $0.id == colorId }) {
            beadColors[index].used += amount
            saveData()
        }
    }

    func deductFromStock(colorCode: String, amount: Int) -> Bool {
        // 尝试通过各种色号匹配
        if let index = findColorIndex(byCode: colorCode) {
            // 允许库存变为负数（消耗量大于库存）
            beadColors[index].used += amount
            saveData()
            return true
        }
        return false
    }

    // MARK: - 搜索和查找

    /// 按色号字符串查 BeadColor。
    ///
    /// 老版本是 M × 5 次线扫 + 每次循环每个 color 都 `.uppercased()` 分配新 String；
    /// 458 项目 × 平均 30 usages × M ≈ 600 colors = ~14M 次比较 + 14M 次分配。
    /// 现在走预建字典：MARD 主键优先、其它品牌 code 兜底、自定义色号兜底。O(1) lookup。
    func findColor(byCode code: String) -> BeadColor? {
        let key = code.uppercased().trimmingCharacters(in: .whitespaces)

        if let match = colorLookupIndex[key] {
            return match
        }

        // 自定义色号（包括 # 前缀、旧 C_ 前缀和不带前缀的色号）—— 数量小，保持线扫。
        if let customColor = customColors.first(where: { custom in
            let customMardCode = custom.mardCode.uppercased()
            let customColorCode = custom.colorCode.uppercased()
            let oldMardCode = "C_\(customColorCode)"
            return customMardCode == key ||
                   customColorCode == key ||
                   oldMardCode == key
        }) {
            return customColor.toBeadColor()
        }

        return nil
    }

    /// 根据色号查找颜色，优先匹配指定的色号体系（避免不同品牌间色号冲突，如 B3 在卡卡和 MARD 中是不同颜色）
    func findColor(byCode code: String, preferSystem: ColorSystem) -> BeadColor? {
        let code = code.uppercased().trimmingCharacters(in: .whitespaces)

        // 当有明确的品牌偏好且不是 MARD 时，优先匹配该品牌的色号
        if preferSystem != .mard {
            let match = beadColors.first { color in
                switch preferSystem {
                case .kaka: return color.kakaCode.uppercased() == code
                case .coco: return color.cocoCode.uppercased() == code
                case .manman: return color.manmanCode.uppercased() == code
                case .panpan: return color.panpanCode.uppercased() == code
                case .mixiaowo: return color.mixiaowoCode.uppercased() == code
                case .mard: return false
                }
            }
            if let match { return match }
        }

        // 非 MARD 体系下不回退到 MARD 匹配，避免跨体系误扣库存
        // 例如卡卡的 B3 和 MARD 的 B3 是完全不同的颜色
        return nil
    }

    /// 严格按 mardCode 匹配，不回退到其他品牌字段。
    /// 用于已经被 recognizeImage 等流程归一化为 mardCode 的存储值，避免无品牌偏好查询
    /// 时跨品牌乱碰（如 Kaka 模式下原始字符串 "B02" 撞到 COCO 的 cocoCode "B02"）。
    func findColor(byMardCode code: String) -> BeadColor? {
        let code = code.uppercased().trimmingCharacters(in: .whitespaces)

        if let match = beadColors.first(where: { $0.mardCode.uppercased() == code }) {
            return match
        }

        // 自定义色号沿用 findColor(byCode:) 的兼容键（# 前缀 / 裸色号 / 旧 C_ 前缀）
        if let custom = customColors.first(where: { custom in
            let customMardCode = custom.mardCode.uppercased()
            let customColorCode = custom.colorCode.uppercased()
            let oldMardCode = "C_\(customColorCode)"
            return customMardCode == code ||
                   customColorCode == code ||
                   oldMardCode == code
        }) {
            return custom.toBeadColor()
        }

        return nil
    }

    func findColorIndex(byCode code: String) -> Int? {
        let code = code.uppercased().trimmingCharacters(in: .whitespaces)

        // 优先精确匹配 MARD 色号（避免与其他品牌色号冲突）
        if let mardIndex = beadColors.firstIndex(where: { $0.mardCode.uppercased() == code }) {
            return mardIndex
        }

        // 再匹配其他品牌色号
        return beadColors.firstIndex { color in
            color.cocoCode.uppercased() == code ||
            color.manmanCode.uppercased() == code ||
            color.panpanCode.uppercased() == code ||
            color.mixiaowoCode.uppercased() == code ||
            color.kakaCode.uppercased() == code
        }
    }

    func searchColors(_ query: String) -> [BeadColor] {
        guard !query.isEmpty else { return allBeadColors }
        let query = query.uppercased()
        let system = currentColorSystem
        return allBeadColors.filter { color in
            color.displayCode(for: system).uppercased().contains(query) ||
            color.mardCode.uppercased().contains(query) ||
            color.colorName.uppercased().contains(query)
        }
    }

    /// 所有颜色（包括预设颜色和自定义色号）
    var allBeadColors: [BeadColor] {
        beadColors + customColors.map { $0.toBeadColor() }
    }

    // MARK: - 项目管理

    func addProject(_ project: ProjectRecord) {
        // 自动生成 displayThumbnail —— 调用方喂的 ProjectRecord 通常只设了 thumbnail（原图），
        // displayThumbnail 留 nil。这里 downsample 一次落地，列表 row 第一次显示就走小图快路径
        // （不用走实时 fallback downsample）。
        // downsample 失败时**保持 displayThumbnail = nil** —— 不能用原 thumbnail 字节做 fallback：
        // 原图常常是 5-10 MB PNG，UIImage(data:) 解码到 30+ MB；列表 row 视口同时显示 10 个就
        // 直奔 jetsam（这正是本 PR 试图修的 458-项目崩溃根因）。让 ProjectThumbnailImage 的
        // 第二优先级路径（CGImageSourceCreateThumbnailAtIndex 实时 downsample）兜底。
        var enriched = project
        if enriched.displayThumbnail == nil, let thumb = enriched.thumbnail {
            if let downsampled = ImageDownsampler.downsample(thumb) {
                enriched.displayThumbnail = downsampled
            } else {
                logError("display_thumbnail_downsample_failed_at_add", metadata: [
                    "projectId": enriched.id.uuidString,
                    "sourceBytes": thumb.count
                ])
            }
        }
        projects.insert(enriched, at: 0)
        // saveData 通过 SDProjectRecord(from: project) 把 thumbnail / finishedImage /
        // patternGridData / displayThumbnail 一并落地到 SwiftData。
        saveData()

        // 同步 ID 集合 —— 不能等下次 refreshProjectBlobMetadata 才更新，否则
        // 「拼图模式」按钮、Calendar 等存在性判断在本次会话期间都看不到该项目。
        if enriched.thumbnail != nil { projectIDsWithThumbnail.insert(enriched.id) }
        if enriched.finishedImage != nil { projectIDsWithFinishedImage.insert(enriched.id) }
        if enriched.patternGrid != nil { projectIDsWithPatternGrid.insert(enriched.id) }
        if enriched.displayThumbnail != nil { projectIDsWithDisplayThumbnail.insert(enriched.id) }
        projectBlobsRevision &+= 1

        // 卸掉 in-memory blob 副本：blob 已经在 SwiftData 里了，缓存继续持有等于在内存里
        // 多放一份。连续扫描多次时会重新堆出内存压力 —— 这就是引发 jetsam 的同型问题。
        stripBlobFromInMemoryProject(enriched.id)

        // 记录历史 —— 用刚 strip 过的 metadata-only 记录（add 撤回不需要图：
        // undo 走 `deleteProject(id:)` 不读 snapshot 里的图）。
        if let stripped = projects.first(where: { $0.id == enriched.id }) {
            historyManager.recordProject(type: .projectAdd, project: stripped)
        }
    }

    func deleteProject(at offsets: IndexSet) {
        // 删除项目只从记录中移除，不回退库存
        projects.remove(atOffsets: offsets)
        saveData()
    }

    func deleteProject(id: UUID) {
        if let index = projects.firstIndex(where: { $0.id == id }) {
            let project = projects[index]

            // 记录历史（在删除前）—— destructive 操作必须把 OLD 图也写进 snapshot，
            // 否则原 SwiftData row 被删除后 undo 无法把图找回来。
            // capturesImages: true 让 restoreProject 路径在重新创建项目后回写图。
            var snapshotProject = project
            snapshotProject.thumbnail = fetchProjectThumbnailData(for: id)
            snapshotProject.finishedImage = fetchProjectFinishedImageData(for: id)
            snapshotProject.patternGrid = fetchProjectPatternGrid(for: id)
            snapshotProject.displayThumbnail = fetchProjectDisplayThumbnail(for: id)
            logSnapshotCaptureGapsIfAny(
                projectId: id,
                operation: "deleteProject",
                snapshot: snapshotProject
            )
            historyManager.recordProject(type: .projectDelete, project: snapshotProject, capturesImages: true)

            // 删除项目只从记录中移除，不回退库存
            projects.remove(at: index)
            // 同步 ID 集合
            projectIDsWithThumbnail.remove(id)
            projectIDsWithFinishedImage.remove(id)
            projectIDsWithPatternGrid.remove(id)
            projectIDsWithDisplayThumbnail.remove(id)
            projectBlobsRevision &+= 1
            saveData()
        }
    }

    /// 校验 destructive snapshot 是否完整：如果三个存在性 Set 里说"该项目应该有 blob"
    /// 但 fetch 拿出来的对应字段是 nil，说明 fetch 出错被吞了（do/catch + logError + 返回 nil 的
    /// cascade），undo 会写 nil 把现存数据清掉。这里**不阻断删除**（避免 transient SwiftData
    /// 错误锁死用户），但写 logError 让 Sentry 能看到，未来这类"撤销不回原图"的用户反馈能溯源。
    fileprivate func logSnapshotCaptureGapsIfAny(
        projectId: UUID,
        operation: String,
        snapshot: ProjectRecord
    ) {
        var gaps: [String] = []
        if projectIDsWithThumbnail.contains(projectId) && snapshot.thumbnail == nil {
            gaps.append("thumbnail")
        }
        if projectIDsWithFinishedImage.contains(projectId) && snapshot.finishedImage == nil {
            gaps.append("finishedImage")
        }
        if projectIDsWithPatternGrid.contains(projectId) && snapshot.patternGrid == nil {
            gaps.append("patternGrid")
        }
        guard !gaps.isEmpty else { return }
        logError("snapshot_capture_gap", metadata: [
            "projectId": projectId.uuidString,
            "operation": operation,
            "missingFields": gaps.joined(separator: ","),
            "note": "ID 集合记录该项目有 blob，但 fetch 返回 nil；undo 将无法还原这些字段"
        ])
    }

    func archiveProject(id: UUID) {
        // 归档项目，不回退库存
        if let index = projects.firstIndex(where: { $0.id == id }) {
            // 记录历史（在归档前）
            historyManager.recordProject(type: .projectArchive, project: projects[index])

            projects[index].isArchived = true
            saveData()
        }
    }

    func unarchiveProject(id: UUID) {
        // 取消归档
        if let index = projects.firstIndex(where: { $0.id == id }) {
            // 记录历史（在取消归档前）
            historyManager.recordProject(type: .projectUnarchive, project: projects[index])

            projects[index].isArchived = false
            saveData()
        }
    }

    private func restoreStockFromProject(_ project: ProjectRecord) {
        // 回退项目中已扣除的库存
        guard let brandId = project.brandId else { return }
        for usage in project.beadUsage where usage.isDeducted {
            // 先将色号转换为 mardCode（与 deductFromStock 保持一致）
            guard let color = findColor(byCode: usage.colorCode) else { continue }

            if let stockIndex = brandStocks.firstIndex(where: {
                $0.brandId == brandId && $0.mardCode == color.mardCode
            }) {
                brandStocks[stockIndex].used = max(0, brandStocks[stockIndex].used - usage.quantity)
            }
        }
    }

    func applyProjectToInventory(_ project: ProjectRecord) {
        guard let brandId = project.brandId else { return }
        for usage in project.beadUsage where !usage.isDeducted {
            _ = deductFromStock(brandId: brandId, colorCode: usage.colorCode, amount: usage.quantity, shouldSave: false)
        }
        saveData()
    }

    // MARK: - 项目层级管理

    /// 获取所有顶级项目（parentId == nil）
    func topLevelProjects() -> [ProjectRecord] {
        projects.filter { $0.parentId == nil }
    }

    /// 获取指定项目的子项目
    func childProjects(of parentId: UUID) -> [ProjectRecord] {
        projects.filter { $0.parentId == parentId }
    }

    /// 获取父项目的计划中子项目（未执行的）
    func plannedChildProjects(of parentId: UUID) -> [ProjectRecord] {
        projects.filter { $0.parentId == parentId && $0.isPlanned }
    }

    /// 获取父项目的已执行子项目
    func executedChildProjects(of parentId: UUID) -> [ProjectRecord] {
        projects.filter { $0.parentId == parentId && !$0.isPlanned }
    }

    /// 判断父项目是否还有未执行的子项目
    func hasPlannedChildren(_ parentId: UUID) -> Bool {
        projects.contains { $0.parentId == parentId && $0.isPlanned }
    }

    /// 判断父项目是否有已执行的子项目
    func hasExecutedChildren(_ parentId: UUID) -> Bool {
        projects.contains { $0.parentId == parentId && !$0.isPlanned }
    }

    /// 判断项目是否为父项目（有子项目）—— O(1) Set 查表。
    func isParentProject(_ projectId: UUID) -> Bool {
        parentIds.contains(projectId)
    }

    /// 获取父项目的汇总 beadUsage（合并所有子项目）
    func aggregatedBeadUsage(for parentId: UUID) -> [BeadUsage] {
        let children = childProjects(of: parentId)
        var usageDict: [String: Int] = [:]  // colorCode -> quantity

        for child in children {
            for usage in child.beadUsage {
                usageDict[usage.colorCode, default: 0] += usage.quantity
            }
        }

        return usageDict.map { colorCode, quantity in
            BeadUsage(colorCode: colorCode, quantity: quantity, isDeducted: true)
        }.sorted { $0.colorCode < $1.colorCode }
    }

    /// 获取父项目的汇总总颗数
    func aggregatedTotalBeads(for parentId: UUID) -> Int {
        childProjects(of: parentId).reduce(0) { $0 + $1.totalBeads }
    }

    /// 获取父项目的汇总颜色数
    func aggregatedColorCount(for parentId: UUID) -> Int {
        let children = childProjects(of: parentId)
        var colorCodes = Set<String>()
        for child in children {
            for usage in child.beadUsage {
                colorCodes.insert(usage.colorCode)
            }
        }
        return colorCodes.count
    }

    // MARK: - 计划子项目统计（只统计未执行的子项目）

    /// 获取父项目的计划中子项目汇总 beadUsage
    func plannedAggregatedBeadUsage(for parentId: UUID) -> [BeadUsage] {
        let children = plannedChildProjects(of: parentId)
        var usageDict: [String: Int] = [:]

        for child in children {
            for usage in child.beadUsage {
                usageDict[usage.colorCode, default: 0] += usage.quantity
            }
        }

        return usageDict.map { colorCode, quantity in
            BeadUsage(colorCode: colorCode, quantity: quantity, isDeducted: false)
        }.sorted { $0.colorCode < $1.colorCode }
    }

    /// 获取父项目的计划中子项目汇总总颗数
    func plannedAggregatedTotalBeads(for parentId: UUID) -> Int {
        plannedChildProjects(of: parentId).reduce(0) { $0 + $1.totalBeads }
    }

    /// 获取父项目的计划中子项目汇总颜色数
    func plannedAggregatedColorCount(for parentId: UUID) -> Int {
        let children = plannedChildProjects(of: parentId)
        var colorCodes = Set<String>()
        for child in children {
            for usage in child.beadUsage {
                colorCodes.insert(usage.colorCode)
            }
        }
        return colorCodes.count
    }

    // MARK: - 已执行子项目统计

    /// 获取父项目的已执行子项目汇总 beadUsage
    func executedAggregatedBeadUsage(for parentId: UUID) -> [BeadUsage] {
        let children = executedChildProjects(of: parentId)
        var usageDict: [String: Int] = [:]

        for child in children {
            for usage in child.beadUsage {
                usageDict[usage.colorCode, default: 0] += usage.quantity
            }
        }

        return usageDict.map { colorCode, quantity in
            BeadUsage(colorCode: colorCode, quantity: quantity, isDeducted: true)
        }.sorted { $0.colorCode < $1.colorCode }
    }

    /// 获取父项目的已执行子项目汇总总颗数
    func executedAggregatedTotalBeads(for parentId: UUID) -> Int {
        executedChildProjects(of: parentId).reduce(0) { $0 + $1.totalBeads }
    }

    /// 获取父项目的已执行子项目汇总颜色数
    func executedAggregatedColorCount(for parentId: UUID) -> Int {
        let children = executedChildProjects(of: parentId)
        var colorCodes = Set<String>()
        for child in children {
            for usage in child.beadUsage {
                colorCodes.insert(usage.colorCode)
            }
        }
        return colorCodes.count
    }

    /// 合并多个项目
    /// - 一个父项目 + 独立项目：独立项目成为父项目的子项目
    /// - 多个父项目：创建新父项目，包含所有子项目（扁平化）
    /// - 多个独立项目：创建新父项目，独立项目成为子项目
    /// - 不允许计划项目与已执行项目混合合并
    @discardableResult
    func mergeProjects(_ projectIds: [UUID], newName: String) -> UUID? {
        guard projectIds.count > 1 else {
            print("合并失败：项目数量不足")
            return nil
        }

        // 确保选中的项目都是顶级项目
        let validProjects = projectIds.compactMap { id in
            projects.first { $0.id == id && $0.parentId == nil }
        }
        guard validProjects.count == projectIds.count else {
            print("合并失败：找到 \(validProjects.count) 个有效项目，期望 \(projectIds.count) 个")
            return nil
        }

        // 检查是否都是计划项目或都是已执行项目
        let allPlanned = validProjects.allSatisfy { $0.isPlanned }
        let allExecuted = validProjects.allSatisfy { !$0.isPlanned }

        print("合并检查：\(validProjects.count) 个项目")
        for p in validProjects {
            print("  - \(p.name): isPlanned=\(p.isPlanned)")
        }
        print("  allPlanned=\(allPlanned), allExecuted=\(allExecuted)")

        guard allPlanned || allExecuted else {
            print("合并失败：项目类型不一致")
            return nil
        }

        // 区分父项目和独立项目
        let parentProjects = validProjects.filter { isParentProject($0.id) }
        let independentProjects = validProjects.filter { !isParentProject($0.id) }

        // 情况1：只有一个父项目 + 一个或多个独立项目
        if parentProjects.count == 1 && !independentProjects.isEmpty {
            let existingParentId = parentProjects[0].id

            // 记录合并前的状态（只记录独立项目，因为父项目不变）
            let originalProjects = independentProjects

            // 将独立项目设为该父项目的子项目
            for project in independentProjects {
                if let index = projects.firstIndex(where: { $0.id == project.id }) {
                    projects[index].parentId = existingParentId
                }
            }
            saveData()

            // 记录合并历史
            HistoryManager.shared.recordProjectMerge(
                originalProjects: originalProjects,
                newParentId: nil,
                isSimpleMerge: true,
                existingParentId: existingParentId,
                mergedName: parentProjects[0].name
            )

            return existingParentId
        }

        // 情况2：多个父项目（可能还有独立项目）→ 创建新父项目，扁平化所有子项目
        if parentProjects.count > 1 {
            // 收集所有子项目及其当前状态
            var allChildrenProjects: [ProjectRecord] = []
            for parent in parentProjects {
                let children = childProjects(of: parent.id)
                allChildrenProjects.append(contentsOf: children)
            }
            // 加上独立项目
            allChildrenProjects.append(contentsOf: independentProjects)

            // 记录合并前的状态：所有子项目 + 所有父项目。
            //
            // 父项目的 SwiftData 行接下来会被 `projects.removeAll { $0.id == parent.id }` 删掉，
            // undo 时 revertProjectMerge 走 recreate 分支重新创建 SDProjectRecord —— 必须在删
            // 之前把每个父项目的 thumbnail / finishedImage / patternGrid 都 fetch 出来塞进
            // snapshot 副本，否则 undo 重建的行 blob 字段恒为 nil（→ 永久丢图丢校准）。
            // 子项目和独立项目的 SwiftData 行 *不* 被删（只改 parentId），blob 在原行里继续在，
            // 所以这里不需要为它们 fetch blob。
            let parentSnapshots = parentProjects.map { parent -> ProjectRecord in
                var snap = parent
                snap.thumbnail = fetchProjectThumbnailData(for: parent.id)
                snap.finishedImage = fetchProjectFinishedImageData(for: parent.id)
                snap.patternGrid = fetchProjectPatternGrid(for: parent.id)
                snap.displayThumbnail = fetchProjectDisplayThumbnail(for: parent.id)
                logSnapshotCaptureGapsIfAny(
                    projectId: parent.id,
                    operation: "mergeProjects.parent",
                    snapshot: snap
                )
                return snap
            }
            let originalProjects = allChildrenProjects + parentSnapshots

            // 创建新的父项目（继承第一个子项目的色号体系）
            let mergedColorSystem = allChildrenProjects.first?.colorSystem ?? .mard
            let newParentProject = ProjectRecord(
                name: newName,
                date: Date(),
                beadUsage: [],
                brandId: nil,
                isArchived: false,
                parentId: nil,
                isPlanned: allPlanned,
                colorSystem: mergedColorSystem
            )

            // 将所有子项目设为新父项目的子项目
            for child in allChildrenProjects {
                if let index = projects.firstIndex(where: { $0.id == child.id }) {
                    projects[index].parentId = newParentProject.id
                }
            }

            // 删除旧的父项目
            for parent in parentProjects {
                projects.removeAll { $0.id == parent.id }
            }

            // 添加新父项目
            projects.insert(newParentProject, at: 0)
            saveData()

            // 记录合并历史
            HistoryManager.shared.recordProjectMerge(
                originalProjects: originalProjects,
                newParentId: newParentProject.id,
                isSimpleMerge: false,
                existingParentId: nil,
                mergedName: newName
            )

            return newParentProject.id
        }

        // 情况3：只有独立项目 → 创建新父项目
        // 记录合并前的状态
        let originalProjects = independentProjects

        // 继承第一个子项目的色号体系
        let mergedColorSystem = independentProjects.first?.colorSystem ?? .mard
        let newParentProject = ProjectRecord(
            name: newName,
            date: Date(),
            beadUsage: [],
            brandId: nil,
            isArchived: false,
            parentId: nil,
            isPlanned: allPlanned,
            colorSystem: mergedColorSystem
        )

        // 将独立项目设为新父项目的子项目
        for project in independentProjects {
            if let index = projects.firstIndex(where: { $0.id == project.id }) {
                projects[index].parentId = newParentProject.id
            }
        }

        // 添加新父项目
        projects.insert(newParentProject, at: 0)
        saveData()

        // 记录合并历史
        HistoryManager.shared.recordProjectMerge(
            originalProjects: originalProjects,
            newParentId: newParentProject.id,
            isSimpleMerge: false,
            existingParentId: nil,
            mergedName: newName
        )

        return newParentProject.id
    }

    /// 撤回项目合并操作
    func revertProjectMerge(mergeSnapshot: MergeSnapshot) -> Bool {
        if mergeSnapshot.isSimpleMerge {
            // 简单合并撤回：将子项目的 parentId 恢复为 nil（变回独立项目）
            for projectSnapshot in mergeSnapshot.originalProjects {
                if let index = projects.firstIndex(where: { $0.id == projectSnapshot.id }) {
                    projects[index].parentId = projectSnapshot.parentId  // 恢复原始 parentId（通常是 nil）
                }
            }
            saveData()
            print("[InventoryManager] 撤回简单合并：恢复了 \(mergeSnapshot.originalProjects.count) 个项目")
            return true
        } else {
            // 复杂合并撤回：
            // 1. 删除新创建的父项目
            // 2. 恢复所有原始项目的状态

            // 先删除新父项目
            if let newParentId = mergeSnapshot.newParentId {
                projects.removeAll { $0.id == newParentId }
            }

            // 恢复所有原始项目的状态
            for projectSnapshot in mergeSnapshot.originalProjects {
                if let index = projects.firstIndex(where: { $0.id == projectSnapshot.id }) {
                    // 恢复 parentId
                    projects[index].parentId = projectSnapshot.parentId
                } else {
                    // 项目不存在（可能是被删除的旧父项目），需要重新创建。
                    // 把 snapshot 里捕获的 thumbnail / finishedImage / patternGridData / completedDate
                    // 一并塞进 ProjectRecord —— 后面 saveData 会走 insert 分支 `SDProjectRecord(from:)`，
                    // 把这些字段一次性写到新 SwiftData 行里。
                    let usages = projectSnapshot.beadUsages.map {
                        BeadUsage(colorCode: $0.colorCode, brandId: $0.brandId, quantity: $0.quantity, isDeducted: $0.isDeducted)
                    }
                    let restoredProject = ProjectRecord(
                        id: projectSnapshot.id,
                        name: projectSnapshot.name,
                        date: projectSnapshot.date,
                        beadUsage: usages,
                        brandId: projectSnapshot.brandId,
                        isArchived: projectSnapshot.isArchived,
                        parentId: projectSnapshot.parentId,
                        isPlanned: projectSnapshot.isPlanned,
                        executedDate: projectSnapshot.executedDate,
                        thumbnail: projectSnapshot.thumbnail,
                        finishedImage: projectSnapshot.finishedImage,
                        completedDate: projectSnapshot.completedDate,
                        colorSystem: projectSnapshot.colorSystem,
                        patternGrid: SDProjectRecord.decodePatternGrid(projectSnapshot.patternGridData, projectId: projectSnapshot.id),
                        displayThumbnail: projectSnapshot.displayThumbnail
                    )
                    projects.append(restoredProject)
                    // 同步 blob ID 集合（saveData 不更新这四个 Set）
                    if restoredProject.thumbnail != nil { projectIDsWithThumbnail.insert(restoredProject.id) }
                    if restoredProject.finishedImage != nil { projectIDsWithFinishedImage.insert(restoredProject.id) }
                    if restoredProject.patternGrid != nil { projectIDsWithPatternGrid.insert(restoredProject.id) }
                    if restoredProject.displayThumbnail != nil { projectIDsWithDisplayThumbnail.insert(restoredProject.id) }
                    projectBlobsRevision &+= 1
                }
            }

            saveData()
            // 重建项目带 blob 副本残留在 manager.projects 里；持久化后 strip 回 metadata-only，
            // 同 addProject / duplicate 的语义，避免内存峰值堆积。
            for snap in mergeSnapshot.originalProjects {
                stripBlobFromInMemoryProject(snap.id)
            }
            print("[InventoryManager] 撤回复杂合并：恢复了 \(mergeSnapshot.originalProjects.count) 个项目")
            return true
        }
    }

    /// 将子项目独立为顶级项目
    func detachProject(_ projectId: UUID) {
        if let index = projects.firstIndex(where: { $0.id == projectId }) {
            projects[index].parentId = nil
            saveData()
        }
    }

    /// 删除父项目（级联删除所有子项目）
    func deleteParentProjectCascade(id: UUID) {
        // 先删除所有子项目
        let children = childProjects(of: id)
        for child in children {
            restoreStockFromProject(child)
        }
        projects.removeAll { $0.parentId == id }

        // 再删除父项目本身
        if let index = projects.firstIndex(where: { $0.id == id }) {
            restoreStockFromProject(projects[index])
            projects.remove(at: index)
        }
        saveData()
    }

    /// 删除父项目（子项目变为独立项目）
    func deleteParentProjectDetach(id: UUID) {
        // 将子项目独立
        for index in projects.indices {
            if projects[index].parentId == id {
                projects[index].parentId = nil
            }
        }

        // 删除父项目本身
        if let index = projects.firstIndex(where: { $0.id == id }) {
            restoreStockFromProject(projects[index])
            projects.remove(at: index)
        }
        saveData()
    }

    /// 归档父项目及其所有子项目
    func archiveProjectWithChildren(id: UUID) {
        // 归档父项目
        if let index = projects.firstIndex(where: { $0.id == id }) {
            projects[index].isArchived = true
        }
        // 归档所有子项目
        for index in projects.indices {
            if projects[index].parentId == id {
                projects[index].isArchived = true
            }
        }
        saveData()
    }

    /// 取消归档父项目及其所有子项目
    func unarchiveProjectWithChildren(id: UUID) {
        // 取消归档父项目
        if let index = projects.firstIndex(where: { $0.id == id }) {
            projects[index].isArchived = false
        }
        // 取消归档所有子项目
        for index in projects.indices {
            if projects[index].parentId == id {
                projects[index].isArchived = false
            }
        }
        saveData()
    }

    // MARK: - 计划项目管理

    /// 获取所有计划中的顶级项目
    func plannedProjects() -> [ProjectRecord] {
        // 获取所有顶级项目（没有父项目的）
        let topLevel = projects.filter { $0.parentId == nil && !$0.isArchived }

        return topLevel.filter { project in
            if isParentProject(project.id) {
                // 父项目：只有当它还有未执行的子项目时才显示
                return hasPlannedChildren(project.id)
            } else {
                // 独立项目：根据自身的 isPlanned 状态
                return project.isPlanned
            }
        }
    }

    /// 获取计划项目数量（用于 Tab Badge）
    func plannedProjectCount() -> Int {
        plannedProjects().count
    }

    /// 判断项目是否为计划项目
    func isPlannedProject(_ projectId: UUID) -> Bool {
        projects.first { $0.id == projectId }?.isPlanned ?? false
    }

    /// 创建计划项目（扫描后不选择品牌时调用）
    func addPlannedProject(_ project: ProjectRecord) {
        var plannedProject = project
        plannedProject.isPlanned = true
        plannedProject.brandId = nil
        // 确保 beadUsage 的 isDeducted 都为 false
        plannedProject.beadUsage = plannedProject.beadUsage.map { usage in
            BeadUsage(id: usage.id, colorCode: usage.colorCode, brandId: nil,
                      quantity: usage.quantity, isDeducted: false)
        }
        // 自动生成 displayThumbnail —— 同 addProject，见那边注释
        if plannedProject.displayThumbnail == nil, let thumb = plannedProject.thumbnail {
            if let downsampled = ImageDownsampler.downsample(thumb) {
                plannedProject.displayThumbnail = downsampled
            } else {
                logError("display_thumbnail_downsample_failed_at_addPlanned", metadata: [
                    "projectId": plannedProject.id.uuidString,
                    "sourceBytes": thumb.count
                ])
            }
        }
        projects.insert(plannedProject, at: 0)
        saveData()

        // 同步 ID 集合（同 addProject —— 见那边注释）
        if plannedProject.thumbnail != nil { projectIDsWithThumbnail.insert(plannedProject.id) }
        if plannedProject.finishedImage != nil { projectIDsWithFinishedImage.insert(plannedProject.id) }
        if plannedProject.patternGrid != nil { projectIDsWithPatternGrid.insert(plannedProject.id) }
        if plannedProject.displayThumbnail != nil { projectIDsWithDisplayThumbnail.insert(plannedProject.id) }
        projectBlobsRevision &+= 1

        stripBlobFromInMemoryProject(plannedProject.id)

        // 记录历史 —— metadata-only（撤销 add 不需要图）
        if let stripped = projects.first(where: { $0.id == plannedProject.id }) {
            historyManager.recordProject(type: .planAdd, project: stripped)
        }
    }

    /// 执行计划项目：选择品牌后一次性扣减库存
    @discardableResult
    func executePlannedProject(_ projectId: UUID, withBrand brandId: UUID) -> Bool {
        guard let index = projects.firstIndex(where: { $0.id == projectId }) else {
            return false
        }

        let project = projects[index]
        guard project.isPlanned else { return false }

        // 防御性校验：品牌色号体系必须与项目色号体系一致
        guard let brand = brands.first(where: { $0.id == brandId }),
              brand.colorSystem == project.colorSystem else {
            return false
        }

        // 如果是父项目，递归执行所有子项目
        if isParentProject(projectId) {
            return executePlannedParentProject(projectId, withBrand: brandId)
        }

        // 保存执行前的项目状态（用于撤回）
        let beforeProject = project

        // 执行库存扣减（批量操作，不逐个保存）
        for usage in project.beadUsage {
            _ = deductFromStock(brandId: brandId, colorCode: usage.colorCode, amount: usage.quantity, shouldSave: false)
        }

        // 更新项目状态
        projects[index].isPlanned = false
        projects[index].brandId = brandId
        projects[index].executedDate = Date()
        // 更新 beadUsage 的 isDeducted 状态
        projects[index].beadUsage = project.beadUsage.map { usage in
            BeadUsage(id: usage.id, colorCode: usage.colorCode, brandId: brandId,
                      quantity: usage.quantity, isDeducted: true)
        }

        // 如果这是一个子项目，检查父项目是否还有其他未执行的子项目
        if let parentId = project.parentId {
            // 检查父项目是否还有其他未执行的子计划（排除当前刚执行的这个）
            let remainingPlannedChildren = projects.filter {
                $0.parentId == parentId && $0.isPlanned && $0.id != projectId
            }
            // 如果没有其他未执行的子计划，将父项目的 isPlanned 设为 false
            if remainingPlannedChildren.isEmpty {
                if let parentIndex = projects.firstIndex(where: { $0.id == parentId }) {
                    projects[parentIndex].isPlanned = false
                    projects[parentIndex].executedDate = Date()
                    projects[parentIndex].brandId = brandId
                }
            }
        }

        saveData()

        // 记录历史（保存执行前和执行后的状态）
        historyManager.recordPlanExecute(beforeProject: beforeProject, afterProject: projects[index])

        return true
    }

    /// 执行计划父项目及其所有子项目
    private func executePlannedParentProject(_ parentId: UUID, withBrand brandId: UUID) -> Bool {
        guard let parentIndex = projects.firstIndex(where: { $0.id == parentId }) else {
            return false
        }

        // 获取所有子项目
        let children = childProjects(of: parentId)

        // 执行所有子项目的库存扣减（批量操作，不逐个保存）
        for child in children {
            if let childIndex = projects.firstIndex(where: { $0.id == child.id }) {
                for usage in child.beadUsage {
                    _ = deductFromStock(brandId: brandId, colorCode: usage.colorCode, amount: usage.quantity, shouldSave: false)
                }

                // 更新子项目状态
                projects[childIndex].isPlanned = false
                projects[childIndex].brandId = brandId
                projects[childIndex].executedDate = Date()
                projects[childIndex].beadUsage = child.beadUsage.map { usage in
                    BeadUsage(id: usage.id, colorCode: usage.colorCode, brandId: brandId,
                              quantity: usage.quantity, isDeducted: true)
                }
            }
        }

        // 更新父项目状态
        projects[parentIndex].isPlanned = false
        projects[parentIndex].brandId = brandId
        projects[parentIndex].executedDate = Date()

        saveData()
        return true
    }

    /// 通过 DeductionResolver 执行计划项目（支持跨品牌扣减）
    @discardableResult
    func executePlannedProjectWithResolver(_ projectId: UUID, resolver: DeductionResolver) -> Bool {
        guard let index = projects.firstIndex(where: { $0.id == projectId }) else {
            return false
        }

        let project = projects[index]
        guard project.isPlanned else { return false }

        // 校验 primaryBrand 的色系与项目一致
        if let brandId = resolver.primaryBrandId,
           let brand = brands.first(where: { $0.id == brandId }),
           brand.colorSystem != project.colorSystem {
            return false
        }

        // 父项目暂不支持 resolver 模式，回退到单品牌
        if isParentProject(projectId), let brandId = resolver.primaryBrandId {
            return executePlannedProject(projectId, withBrand: brandId)
        }

        let beforeProject = project

        // 执行扣减，不在 resolver 内保存（统一在下面保存）
        let failedItems = resolver.executeDeductions(shouldSave: false)

        // 更新项目状态，标记失败项为未扣减
        projects[index].isPlanned = false
        projects[index].brandId = resolver.primaryBrandId
        projects[index].executedDate = Date()
        projects[index].beadUsage = resolver.items.map { item in
            BeadUsage(
                colorCode: item.mardCode,
                brandId: item.brandId,
                quantity: item.quantity,
                isDeducted: !failedItems.contains(where: { $0.id == item.id })
            )
        }

        if let parentId = project.parentId {
            let remainingPlannedChildren = projects.filter {
                $0.parentId == parentId && $0.isPlanned && $0.id != projectId
            }
            if remainingPlannedChildren.isEmpty {
                if let parentIndex = projects.firstIndex(where: { $0.id == parentId }) {
                    projects[parentIndex].isPlanned = false
                    projects[parentIndex].executedDate = Date()
                    projects[parentIndex].brandId = resolver.primaryBrandId
                }
            }
        }

        saveData()
        historyManager.recordPlanExecute(beforeProject: beforeProject, afterProject: projects[index])
        return true
    }

    /// 删除计划项目（不回退库存，因为还未扣减）
    func deletePlannedProject(_ projectId: UUID) {
        guard let project = projects.first(where: { $0.id == projectId }) else {
            return
        }

        // 查找子项目（如果有）
        let children = projects.filter { $0.parentId == projectId }

        // destructive 路径：把父项目和子项目的 OLD 图都从 SwiftData 取出来回填，
        // 否则原 SwiftData 行被删除后 undo 无法找回图。
        var snapshotParent = project
        snapshotParent.thumbnail = fetchProjectThumbnailData(for: projectId)
        snapshotParent.finishedImage = fetchProjectFinishedImageData(for: projectId)
        snapshotParent.patternGrid = fetchProjectPatternGrid(for: projectId)
        snapshotParent.displayThumbnail = fetchProjectDisplayThumbnail(for: projectId)
        let snapshotChildren = children.map { child -> ProjectRecord in
            var snap = child
            snap.thumbnail = fetchProjectThumbnailData(for: child.id)
            snap.finishedImage = fetchProjectFinishedImageData(for: child.id)
            snap.patternGrid = fetchProjectPatternGrid(for: child.id)
            snap.displayThumbnail = fetchProjectDisplayThumbnail(for: child.id)
            logSnapshotCaptureGapsIfAny(
                projectId: child.id,
                operation: "deletePlannedProject.child",
                snapshot: snap
            )
            return snap
        }
        logSnapshotCaptureGapsIfAny(
            projectId: projectId,
            operation: "deletePlannedProject.parent",
            snapshot: snapshotParent
        )
        // 记录历史（在删除前），包含父项目和子项目
        historyManager.recordPlanDelete(project: snapshotParent, children: snapshotChildren)

        // 如果是父项目，也删除子项目
        if !children.isEmpty {
            projects.removeAll { $0.parentId == projectId }
        }
        projects.removeAll { $0.id == projectId }
        // 同步 ID 集合（父 + 所有子）
        projectIDsWithThumbnail.remove(projectId)
        projectIDsWithFinishedImage.remove(projectId)
        projectIDsWithPatternGrid.remove(projectId)
        projectIDsWithDisplayThumbnail.remove(projectId)
        for child in children {
            projectIDsWithThumbnail.remove(child.id)
            projectIDsWithFinishedImage.remove(child.id)
            projectIDsWithPatternGrid.remove(child.id)
            projectIDsWithDisplayThumbnail.remove(child.id)
        }
        projectBlobsRevision &+= 1
        saveData()
    }

    /// 复制计划项目（支持文件夹完整复制）。
    ///
    /// blob 处理：源项目的 thumbnail / patternGrid 都在 SwiftData 里（in-memory 缓存只有
    /// metadata），所以复制时要从 SwiftData 按需取出再喂给新项目；落地后通过
    /// `_setProjectBlobsDirectly` 把 blob 写到新 row，同步 ID 集合。
    /// finishedImage 不复制 —— 副本是新创建的计划项目，没有"成品"语义。
    @discardableResult
    func duplicatePlannedProject(_ projectId: UUID) -> UUID? {
        guard let index = projects.firstIndex(where: { $0.id == projectId && $0.isPlanned }) else {
            return nil
        }

        let project = projects[index]
        let newId = UUID()

        // 复制 beadUsage，生成新的 UUID
        let newBeadUsage = project.beadUsage.map { usage in
            BeadUsage(
                id: UUID(),
                colorCode: usage.colorCode,
                brandId: nil,
                quantity: usage.quantity,
                isDeducted: false
            )
        }

        // 按需取源 blob —— 缓存只剩 metadata，必须直接读 SwiftData
        let sourceThumbnail = fetchProjectThumbnailData(for: projectId)
        let sourceGrid = fetchProjectPatternGrid(for: projectId)
        let sourceGridData = sourceGrid.flatMap { SDProjectRecord.encodePatternGrid($0, projectId: newId) }
        // 顺带复制源项目的 displayThumbnail；如果源没有就现场 downsample 源 thumbnail
        let sourceDisplay = fetchProjectDisplayThumbnail(for: projectId)
            ?? sourceThumbnail.flatMap { ImageDownsampler.downsample($0) }

        // 创建副本项目（这一份会经由 saveData → SDProjectRecord(from:) 落地，所以这里
        // 顺手把 blob 也喂进去 —— 一次 saveData 就把 blob 一并写入新 row）。
        let duplicatedProject = ProjectRecord(
            id: newId,
            name: project.name + " (副本)", // 持久化数据，不本地化以保证 iCloud 同步一致性
            date: Date(),
            beadUsage: newBeadUsage,
            brandId: nil,
            isArchived: false,
            parentId: nil,  // 副本总是顶级项目
            isPlanned: true,
            executedDate: nil,
            thumbnail: sourceThumbnail,
            colorSystem: project.colorSystem,
            patternGrid: sourceGrid,
            displayThumbnail: sourceDisplay
        )

        // 插入到原项目后面
        projects.insert(duplicatedProject, at: index + 1)

        // 如果是父项目，复制所有子项目（每个子项目也单独取自己的 blob）
        var childCopies: [(record: ProjectRecord, thumbnail: Data?, gridData: Data?, displayThumbnail: Data?)] = []
        if isParentProject(projectId) {
            let children = childProjects(of: projectId)
            for child in children {
                let newChildId = UUID()
                let newChildBeadUsage = child.beadUsage.map { usage in
                    BeadUsage(
                        id: UUID(),
                        colorCode: usage.colorCode,
                        brandId: nil,
                        quantity: usage.quantity,
                        isDeducted: false
                    )
                }
                let childThumb = fetchProjectThumbnailData(for: child.id)
                let childGrid = fetchProjectPatternGrid(for: child.id)
                let childGridData = childGrid.flatMap { SDProjectRecord.encodePatternGrid($0, projectId: newChildId) }
                let childDisplay = fetchProjectDisplayThumbnail(for: child.id)
                    ?? childThumb.flatMap { ImageDownsampler.downsample($0) }
                let duplicatedChild = ProjectRecord(
                    id: newChildId,
                    name: child.name,
                    date: Date(),
                    beadUsage: newChildBeadUsage,
                    brandId: nil,
                    isArchived: false,
                    parentId: newId,  // 关联到新的父项目
                    isPlanned: true,
                    executedDate: nil,
                    thumbnail: childThumb,
                    colorSystem: child.colorSystem,
                    patternGrid: childGrid,
                    displayThumbnail: childDisplay
                )
                projects.append(duplicatedChild)
                childCopies.append((record: duplicatedChild, thumbnail: childThumb, gridData: childGridData, displayThumbnail: childDisplay))
            }
        }

        saveData()

        // saveData 已经把 blob 持久化（SDProjectRecord(from:) 路径），但 ID 集合还没刷。
        // 同时把内存里副本的 blob 卸掉，回到 metadata-only 常态。
        if sourceThumbnail != nil { projectIDsWithThumbnail.insert(newId) }
        if sourceGridData != nil { projectIDsWithPatternGrid.insert(newId) }
        if sourceDisplay != nil { projectIDsWithDisplayThumbnail.insert(newId) }
        stripBlobFromInMemoryProject(newId)
        for child in childCopies {
            if child.thumbnail != nil { projectIDsWithThumbnail.insert(child.record.id) }
            if child.gridData != nil { projectIDsWithPatternGrid.insert(child.record.id) }
            if child.displayThumbnail != nil { projectIDsWithDisplayThumbnail.insert(child.record.id) }
            stripBlobFromInMemoryProject(child.record.id)
        }
        projectBlobsRevision &+= 1

        // 记录历史 —— add 撤回不需要图（撤回 = 删行，源 SwiftData 行还在）
        if let stripped = projects.first(where: { $0.id == newId }) {
            historyManager.recordProject(type: .planAdd, project: stripped)
        }

        return newId
    }

    /// 复制任意项目到计划列表（支持文件夹完整复制）
    @discardableResult
    func duplicateProjectAsPlan(_ projectId: UUID) -> UUID? {
        guard let project = projects.first(where: { $0.id == projectId }) else {
            return nil
        }

        let newId = UUID()

        // 复制 beadUsage，生成新的 UUID
        let newBeadUsage = project.beadUsage.map { usage in
            BeadUsage(
                id: UUID(),
                colorCode: usage.colorCode,
                brandId: nil,
                quantity: usage.quantity,
                isDeducted: false
            )
        }

        // 按需取源 blob —— 缓存只剩 metadata，必须直接读 SwiftData
        let sourceThumbnail = fetchProjectThumbnailData(for: projectId)
        let sourceGrid = fetchProjectPatternGrid(for: projectId)
        let sourceGridData = sourceGrid.flatMap { SDProjectRecord.encodePatternGrid($0, projectId: newId) }
        let sourceDisplay = fetchProjectDisplayThumbnail(for: projectId)
            ?? sourceThumbnail.flatMap { ImageDownsampler.downsample($0) }

        // 创建副本项目
        let duplicatedProject = ProjectRecord(
            id: newId,
            name: project.name + " (副本)", // 持久化数据，不本地化以保证 iCloud 同步一致性
            date: Date(),
            beadUsage: newBeadUsage,
            brandId: nil,
            isArchived: false,
            parentId: nil,
            isPlanned: true,
            executedDate: nil,
            thumbnail: sourceThumbnail,
            colorSystem: project.colorSystem,
            patternGrid: sourceGrid,
            displayThumbnail: sourceDisplay
        )

        // 插入到列表开头
        projects.insert(duplicatedProject, at: 0)

        // 如果是父项目，复制所有子项目
        var childCopies: [(record: ProjectRecord, thumbnail: Data?, gridData: Data?, displayThumbnail: Data?)] = []
        if isParentProject(projectId) {
            let children = childProjects(of: projectId)
            for child in children {
                let newChildId = UUID()
                let newChildBeadUsage = child.beadUsage.map { usage in
                    BeadUsage(
                        id: UUID(),
                        colorCode: usage.colorCode,
                        brandId: nil,
                        quantity: usage.quantity,
                        isDeducted: false
                    )
                }
                let childThumb = fetchProjectThumbnailData(for: child.id)
                let childGrid = fetchProjectPatternGrid(for: child.id)
                let childGridData = childGrid.flatMap { SDProjectRecord.encodePatternGrid($0, projectId: newChildId) }
                let childDisplay = fetchProjectDisplayThumbnail(for: child.id)
                    ?? childThumb.flatMap { ImageDownsampler.downsample($0) }
                let duplicatedChild = ProjectRecord(
                    id: newChildId,
                    name: child.name,
                    date: Date(),
                    beadUsage: newChildBeadUsage,
                    brandId: nil,
                    isArchived: false,
                    parentId: newId,  // 关联到新的父项目
                    isPlanned: true,
                    executedDate: nil,
                    thumbnail: childThumb,
                    colorSystem: child.colorSystem,
                    patternGrid: childGrid,
                    displayThumbnail: childDisplay
                )
                projects.append(duplicatedChild)
                childCopies.append((record: duplicatedChild, thumbnail: childThumb, gridData: childGridData, displayThumbnail: childDisplay))
            }
        }

        saveData()

        // 同步 ID 集合 + 卸 in-memory blob 副本（同 duplicatePlannedProject —— 见那边注释）
        if sourceThumbnail != nil { projectIDsWithThumbnail.insert(newId) }
        if sourceGridData != nil { projectIDsWithPatternGrid.insert(newId) }
        if sourceDisplay != nil { projectIDsWithDisplayThumbnail.insert(newId) }
        stripBlobFromInMemoryProject(newId)
        for child in childCopies {
            if child.thumbnail != nil { projectIDsWithThumbnail.insert(child.record.id) }
            if child.gridData != nil { projectIDsWithPatternGrid.insert(child.record.id) }
            if child.displayThumbnail != nil { projectIDsWithDisplayThumbnail.insert(child.record.id) }
            stripBlobFromInMemoryProject(child.record.id)
        }
        projectBlobsRevision &+= 1

        // 记录历史
        if let stripped = projects.first(where: { $0.id == newId }) {
            historyManager.recordProject(type: .planAdd, project: stripped)
        }

        return newId
    }

    /// 更新计划项目名称
    func updatePlannedProjectName(_ projectId: UUID, newName: String) {
        if let index = projects.firstIndex(where: { $0.id == projectId && $0.isPlanned }) {
            // 记录历史（在修改前）
            historyManager.recordProject(type: .planUpdate, project: projects[index])

            projects[index].name = newName
            saveData()
        }
    }

    /// 更新计划项目内容（名称和用量）
    func updatePlannedProject(_ projectId: UUID, newName: String, newBeadUsage: [BeadUsage]) {
        if let index = projects.firstIndex(where: { $0.id == projectId && $0.isPlanned }) {
            // 记录历史（在修改前）
            historyManager.recordProject(type: .planUpdate, project: projects[index])

            projects[index].name = newName
            projects[index].beadUsage = newBeadUsage
            // 重新计算 totalBeads
            projects[index].totalBeads = newBeadUsage.reduce(0) { $0 + $1.quantity }
            saveData()
        }
    }

    /// 更新计划项目单个颜色的数量
    func updatePlannedProjectUsage(_ projectId: UUID, colorCode: String, newQuantity: Int) {
        if let index = projects.firstIndex(where: { $0.id == projectId && $0.isPlanned }) {
            // 记录历史（在修改前）
            historyManager.recordProject(type: .planUpdate, project: projects[index])

            if let usageIndex = projects[index].beadUsage.firstIndex(where: { $0.colorCode == colorCode }) {
                if newQuantity <= 0 {
                    // 数量为0或负数时删除该颜色
                    projects[index].beadUsage.remove(at: usageIndex)
                } else {
                    projects[index].beadUsage[usageIndex].quantity = newQuantity
                }
                // 重新计算 totalBeads
                projects[index].totalBeads = projects[index].beadUsage.reduce(0) { $0 + $1.quantity }
                saveData()
            }
        }
    }

    /// 删除计划项目中的单个颜色
    func deletePlannedProjectUsage(_ projectId: UUID, colorCode: String) {
        if let index = projects.firstIndex(where: { $0.id == projectId && $0.isPlanned }) {
            // 记录历史（在修改前）
            historyManager.recordProject(type: .planUpdate, project: projects[index])

            projects[index].beadUsage.removeAll { $0.colorCode == colorCode }
            // 重新计算 totalBeads
            projects[index].totalBeads = projects[index].beadUsage.reduce(0) { $0 + $1.quantity }
            saveData()
        }
    }

    /// 添加计划项目中的颜色
    func addPlannedProjectUsage(_ projectId: UUID, colorCode: String, quantity: Int) {
        if let index = projects.firstIndex(where: { $0.id == projectId && $0.isPlanned }) {
            // 检查是否已存在该颜色
            if let usageIndex = projects[index].beadUsage.firstIndex(where: { $0.colorCode == colorCode }) {
                // 已存在，增加数量
                projects[index].beadUsage[usageIndex].quantity += quantity
            } else {
                // 不存在，添加新颜色
                let newUsage = BeadUsage(colorCode: colorCode, brandId: nil, quantity: quantity, isDeducted: false)
                projects[index].beadUsage.append(newUsage)
            }
            // 重新计算 totalBeads
            projects[index].totalBeads = projects[index].beadUsage.reduce(0) { $0 + $1.quantity }
            saveData()
        }
    }

    // MARK: - 项目图片管理（按需取图 / 直写持久层）
    //
    // 设计取舍：图片字段不再走 saveData 的 baseline-diff 路径。
    // 原因：自 v2.0.x 起 `projects` 缓存里这些字段恒为 nil（避免 jetsam），
    // 如果还沿用旧 diff 写回，会把云端真实数据用 nil 覆盖掉。
    // 新规则：图片读 / 写都对单个 SDProjectRecord 直操作；metadata（名称 / 计划状态 /
    // 总颗数 / beadUsage 等）仍走 saveData 的差分写回。

    /// 同步取单个项目的 thumbnail Data。
    ///
    /// 注意：InventoryManager 是 @MainActor，本方法在主线程跑 SwiftData fetch。
    /// `UIImage(data:)` 的真正解码 / 上屏由 UIKit 推迟到 draw time。
    /// **视图侧调用方**走 `.task { }` 的好处是：(1) `await` 让出本帧调度窗口，让首屏 commit
    /// 不在同一 runloop tick 里把 fetch 也吃掉；(2) Task 可取消，切走时不残留。
    /// 周备份路径则是主线程同步循环调用（BackupManager.createBackupData），不在上述框架内。
    /// 真正想"完全脱离主 actor"需要后台 ModelActor —— 留 follow-up。
    ///
    /// 错误处理：把 SwiftData 抛错和「真的没图」区分开。前者写日志返回 nil（避免静默吞错让
    /// store 损坏 / external storage sidecar 丢失看起来像无图）；后者直接返回 nil。
    func fetchProjectThumbnailData(for projectId: UUID) -> Data? {
        guard let context = modelContext else {
            logError("fetch_thumbnail_no_context", metadata: ["projectId": projectId.uuidString])
            return nil
        }
        var descriptor = FetchDescriptor<SDProjectRecord>(
            predicate: #Predicate { $0.id == projectId }
        )
        descriptor.fetchLimit = 1
        // 跟 fetchProjectFinishedImageData / fetchProjectDisplayThumbnail 同型（round-10 review I1）：
        // 不限定单列的话，同行 finishedImage / patternGridData / displayThumbnail 也会一起物化。
        // 周备份路径逐项目调本方法，全行 fetch 会把峰值内存翻 3-4 倍。
        descriptor.propertiesToFetch = [\.thumbnail]
        do {
            return try context.fetch(descriptor).first?.thumbnail
        } catch {
            logError("fetch_thumbnail_failed", metadata: [
                "projectId": projectId.uuidString,
                "error": "\(error)"
            ])
            return nil
        }
    }

    /// 同步取单个项目的 finishedImage Data。错误处理同 `fetchProjectThumbnailData`。
    /// **round-10 review I1**：`propertiesToFetch = [\.finishedImage]` 限定单列 fetch —— 否则
    /// SwiftData 会把同行的 raw `thumbnail`（可能 5-10 MB inline PNG）也一起物化。
    func fetchProjectFinishedImageData(for projectId: UUID) -> Data? {
        guard let context = modelContext else {
            logError("fetch_finished_image_no_context", metadata: ["projectId": projectId.uuidString])
            return nil
        }
        var descriptor = FetchDescriptor<SDProjectRecord>(
            predicate: #Predicate { $0.id == projectId }
        )
        descriptor.fetchLimit = 1
        descriptor.propertiesToFetch = [\.finishedImage]
        do {
            return try context.fetch(descriptor).first?.finishedImage
        } catch {
            logError("fetch_finished_image_failed", metadata: [
                "projectId": projectId.uuidString,
                "error": "\(error)"
            ])
            return nil
        }
    }

    /// 同步取单个项目的 BeadPatternGrid（拼图网格）。错误处理同上。
    /// **round-10 review I1**：`propertiesToFetch = [\.patternGridData]` 限定单列。
    func fetchProjectPatternGrid(for projectId: UUID) -> BeadPatternGrid? {
        guard let context = modelContext else {
            logError("fetch_pattern_grid_no_context", metadata: ["projectId": projectId.uuidString])
            return nil
        }
        var descriptor = FetchDescriptor<SDProjectRecord>(
            predicate: #Predicate { $0.id == projectId }
        )
        descriptor.fetchLimit = 1
        descriptor.propertiesToFetch = [\.patternGridData]
        do {
            guard let sd = try context.fetch(descriptor).first else { return nil }
            return SDProjectRecord.decodePatternGrid(sd.patternGridData, projectId: projectId)
        } catch {
            logError("fetch_pattern_grid_failed", metadata: [
                "projectId": projectId.uuidString,
                "error": "\(error)"
            ])
            return nil
        }
    }

    /// 同步取单个项目的 displayThumbnail（列表用小图）。错误处理同上。
    /// **注意：视图层已不再走这里**，改走 `ProjectImageLoader.displayThumbnail(for:)`（后台 actor）。
    /// 本方法只剩备份导出 / history 快照捕获等主线程调用方。
    /// **round-10 review I1**：`propertiesToFetch = [\.displayThumbnail]` 限定单列 —— 否则
    /// 列表每滚一个 row 都会 fault 同行的 raw thumbnail（5-10 MB inline PNG）到内存。
    func fetchProjectDisplayThumbnail(for projectId: UUID) -> Data? {
        guard let context = modelContext else {
            logError("fetch_display_thumbnail_no_context", metadata: ["projectId": projectId.uuidString])
            return nil
        }
        var descriptor = FetchDescriptor<SDProjectRecord>(
            predicate: #Predicate { $0.id == projectId }
        )
        descriptor.fetchLimit = 1
        descriptor.propertiesToFetch = [\.displayThumbnail]
        do {
            return try context.fetch(descriptor).first?.displayThumbnail
        } catch {
            logError("fetch_display_thumbnail_failed", metadata: [
                "projectId": projectId.uuidString,
                "error": "\(error)"
            ])
            return nil
        }
    }

    /// ThumbnailMigrationCoordinator 后台迁移成功一个项目后的**纯内存 bookkeeping**。
    /// 只更新 `projectIDsWithDisplayThumbnail`（列表 row 用它决定走 displayThumbnail 还是
    /// fallback 降级路径），**不做任何 SwiftData I/O** —— SwiftData 写回已由协调器在
    /// 后台 ModelContext 上完成。主线程保持零 I/O 是 build 180 watchdog 崩溃修复的核心
    /// 不变量，别在这里加 fetch/save。
    ///
    /// **不 bump `projectBlobsRevision`** —— 跟 update*Image 公开 API 关键差别：
    /// 迁移协调器 458 项目用户场景下每秒 ~10 次调用。如果每次 bump revision，
    /// 屏幕上所有列表 row 的 `.task(id:)` 都会 cancel + relaunch + fetch + decode
    /// → 每秒 100 次无谓 churn → 滑动卡顿 + placeholder 闪烁（PR #48 上线后用户报告）。
    /// 不 bump 之后：现有视图保持显示已加载的图（fallback CGImageSource 现场降级版本），
    /// 等下次自然 re-render（row 滚出再滚入 / app 重启 / 用户编辑触发其它 bump）时拿到新
    /// displayThumbnail —— 用户体验上是平滑过渡，下次启动列表更快。
    func noteProjectDisplayThumbnailMigrated(projectId: UUID) {
        projectIDsWithDisplayThumbnail.insert(projectId)
        // 故意**不** bump projectBlobsRevision —— 见函数级注释
    }

    /// 单条 fetch 取裸 SDProjectRecord —— 仅供同文件内的 `_setProject*Direct` 直写路径用。
    /// 不暴露 SwiftData 类型到外部接口。
    /// 注意：返回 nil 有**两种**根因（context 缺失 / fetch 抛错 / 真没记录），都单独记
    /// 不同 log 事件，避免 Sentry 把根因归错。
    private func fetchSDProject(by projectId: UUID) -> SDProjectRecord? {
        guard let context = modelContext else {
            logError("fetch_sd_project_no_context", metadata: ["projectId": projectId.uuidString])
            return nil
        }
        let descriptor = FetchDescriptor<SDProjectRecord>(
            predicate: #Predicate { $0.id == projectId }
        )
        do {
            return try context.fetch(descriptor).first
        } catch {
            logError("fetch_sd_project_failed", metadata: [
                "projectId": projectId.uuidString,
                "error": "\(error)"
            ])
            return nil
        }
    }

    /// 刷新「持久层里有 thumbnail / finishedImage / patternGridData 的项目 ID 集合」缓存。
    /// 谓词在 SQL 层完成 NULL 检查，不会把 blob 实际加载进内存
    /// （externalStorage 列只存引用；非 externalStorage 的 BLOB 列也只是查 IS NOT NULL）。
    ///
    /// 在以下时机调用：load_data_completed、CloudKit 远程合并完成、backup restore 收尾。
    /// 调用结束会 bump `projectBlobsRevision`，让视图 `.task(id:)` 复合 key 触发重取。
    /// `internal` 访问层级是为了让 BeadInventoryTests 能在测试里调到（通过同 module
    /// 的 @testable import 即可，不再需要 forTests 桥）。
    /// 扫描报 `.transient` 时的有界重试。退避 2s / 5s / 10s，三次后放弃并记 error
    /// （能被监控看到「有用户整个 session 没有图」，而不是只剩一条 warning）。
    ///
    /// 停止条件是 `hasCompletedBlobMetadataScan` —— 对真的一张图都没有的新用户，
    /// 首次扫描一样会成功（返回空集）并置位，不会白跑三次。
    private func scheduleBlobMetadataRetry(attempt: Int) {
        let delays: [TimeInterval] = [2, 5, 10]
        guard attempt <= delays.count else {
            logError("blob_metadata_retry_exhausted", metadata: [
                "attempts": delays.count,
                "impact": "拼图模式按钮/日历成品图本次启动不可用"
            ])
            return
        }
        let delay = delays[attempt - 1]
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            // 停止条件是「全量扫描成功过」这个**事实**，不是「集合非空」这个代理 ——
            // 集合会被 addProject 等增量插入，非空不代表老项目的数据已经扫出来了。
            guard !self.hasCompletedBlobMetadataScan else { return }
            self.logInfo("blob_metadata_retry", metadata: ["attempt": attempt])
            self.refreshProjectBlobMetadata(retryAttempt: attempt)
        }
    }

    func refreshProjectBlobMetadata(retryAttempt: Int = 0) {
        guard let context = modelContext else {
            projectIDsWithFinishedImage = []
            projectIDsWithThumbnail = []
            projectIDsWithPatternGrid = []
            projectIDsWithDisplayThumbnail = []
            // Preview / 无 store 模式：没有东西可扫，空集就是终态 —— 置位，别让重试空转。
            hasCompletedBlobMetadataScan = true
            projectBlobsRevision &+= 1
            return
        }
        let container = context.container
        // 全部挪到后台：旧实现的 4 个 `#Predicate { $0.blob != nil }` 查询在**主线程**上
        // 会把命中行的 blob 内容物化进内存（实测 +1.26GB/120 条，见
        // InitialLoadMemoryDiagnosticTests）—— 既是主线程停摆也是真机 jetsam 源。
        // 现在优先 raw SQLite 头部扫描（零物化），失败才回退 SwiftData 查询（后台 context）。
        // 调用方都不依赖集合同步更新（本就有 DispatchQueue.main.async 的先例），
        // 迟到的应用是 last-wins，与并发 refresh 的整份覆盖语义一致。
        Task { @MainActor [weak self] in
            let existence: ProjectBlobExistence? = await Task.detached(priority: .utility) {
                let scanResult = (container.configurations.first?.url).map {
                    ProjectBlobExistenceScanner.scan(storeURL: $0)
                } ?? .failure(.unsupportedStore)

                switch scanResult {
                case .success(let scanned):
                    return scanned
                case .failure(.transient):
                    // **不回退 SwiftData BLOB 谓词**（实测 +1.26GB）。store 忙的时候
                    // 恰恰是最不该吃内存的时候。返回 nil → 下面保留上一次的集合。
                    AppLogger.shared.warning(
                        "InventoryManager",
                        "blob_existence_scan_transient_keeping_previous",
                        metadata: ["caller": "refreshProjectBlobMetadata", "retryAttempt": retryAttempt]
                    )
                    return nil
                case .failure(.unsupportedStore):
                    AppLogger.shared.error(
                        "InventoryManager",
                        "blob_existence_scan_fallback_swiftdata",
                        metadata: ["caller": "refreshProjectBlobMetadata"]
                    )
                    let bg = ModelContext(container)
                    return try? Self.legacyBlobExistenceFetch(context: bg)
                }
            }.value
            guard let self else { return }
            if let existence {
                self.projectIDsWithFinishedImage = existence.finishedImage
                self.projectIDsWithThumbnail = existence.thumbnail
                self.projectIDsWithPatternGrid = existence.patternGrid
                self.projectIDsWithDisplayThumbnail = existence.displayThumbnail
                self.hasCompletedBlobMetadataScan = true
            } else {
                self.logError("project_blob_meta_refresh_failed", metadata: ["retryAttempt": retryAttempt])
                // 忙库 → 退避重试。不重试的话，冷启动撞上忙库的用户整个 session
                // 都看不到拼图模式按钮和日历成品图（空集在下游等于「确定没有图」）。
                if !self.hasCompletedBlobMetadataScan {
                    self.scheduleBlobMetadataRetry(attempt: retryAttempt + 1)
                }
            }
            // 即使扫描失败也要 bump：调用方（loadData / restore / 远端合并）已经动过持久层，
            // 视图缓存认定的 revision 必须前进一步，让 .task(id:) 重新跑取图，避免视图卡在
            // 旧 revision 显示过期图。
            self.projectBlobsRevision &+= 1
        }
    }

    /// 内部直写：把单个项目的 4 个 blob 字段（thumbnail / finishedImage / patternGridData /
    /// displayThumbnail）按需写到 SwiftData。**不**走 history 记录、**不**做 isPlanned 守卫。
    /// 供以下路径用：
    /// - public `updateProject*` 在调用方记完 history 后转发到这里
    /// - duplicate 路径在 addProject 后回填源项目的真实 blob
    /// - HistoryManager.restoreProject undo 删除时回填快照里的真实 blob
    /// - BackupManager.restoreBackup 把备份里的 blob（含 nil 清空语义）写回新 store
    ///
    /// 参数语义：`nil` = 跳过该字段（不动），`.some(nil)` = 清空，`.some(data)` = 写入新值。
    /// 用 `Data??` 而不是单层 optional + 单独 flag，是为了 call site 紧凑且类型即文档。
    @discardableResult
    fileprivate func _setProjectBlobsDirectly(
        projectId: UUID,
        thumbnail: Data?? = nil,
        finishedImage: Data?? = nil,
        patternGridData: Data?? = nil,
        displayThumbnail: Data?? = nil
    ) -> Bool {
        guard let context = modelContext else {
            logError("set_blobs_no_context", metadata: ["projectId": projectId.uuidString])
            return false
        }
        guard let sd = fetchSDProject(by: projectId) else {
            logWarning("set_blobs_no_sd_record", metadata: ["projectId": projectId.uuidString])
            return false
        }
        if case .some(let newThumb) = thumbnail {
            sd.thumbnail = newThumb
        }
        if case .some(let newFinished) = finishedImage {
            sd.finishedImage = newFinished
        }
        if case .some(let newGrid) = patternGridData {
            sd.patternGridData = newGrid
        }
        if case .some(let newDisplay) = displayThumbnail {
            sd.displayThumbnail = newDisplay
        }
        do {
            try context.save()
        } catch {
            logError("set_blobs_save_failed", metadata: [
                "projectId": projectId.uuidString,
                "error": "\(error)"
            ])
            return false
        }
        // 同步 ID 集合 —— 只对调用方明确写了的字段更新对应 Set。
        if case .some(let newThumb) = thumbnail {
            if newThumb != nil { projectIDsWithThumbnail.insert(projectId) } else { projectIDsWithThumbnail.remove(projectId) }
        }
        if case .some(let newFinished) = finishedImage {
            if newFinished != nil { projectIDsWithFinishedImage.insert(projectId) } else { projectIDsWithFinishedImage.remove(projectId) }
        }
        if case .some(let newGrid) = patternGridData {
            if newGrid != nil { projectIDsWithPatternGrid.insert(projectId) } else { projectIDsWithPatternGrid.remove(projectId) }
        }
        if case .some(let newDisplay) = displayThumbnail {
            if newDisplay != nil { projectIDsWithDisplayThumbnail.insert(projectId) } else { projectIDsWithDisplayThumbnail.remove(projectId) }
        }
        projectBlobsRevision &+= 1
        return true
    }

    /// 内部直写 + 给 finishedImage 上传自动补完成日期的便捷方法。
    /// 仅 `updateProjectFinishedImage` 公开 API 走这里（注意：BackupManager.restoreBackup
    /// **不**走这里，它走 `_setProjectBlobsDirectly` 不自动补 completedDate —— 因为备份
    /// 还原本来就是回放原始状态，不应该再造新的"今天"完成日期）。
    fileprivate func _setProjectFinishedImageDirectly(
        projectId: UUID,
        finishedImage: Data?,
        autoFillCompletedDate: Bool
    ) {
        // 显式 guard context —— 之前用 `try modelContext?.save()`，nil context 时整个表达式
        // 是 nil 不抛、不 log，但底下 ID 集合 + revision 还是 bump → 用户看到状态变了但
        // SwiftData 里啥都没写。改成同 `_setProjectBlobsDirectly` 的结构：先 guard，
        // 失败提前 return 不动 ID 集合。
        guard let context = modelContext else {
            logError("set_finished_image_no_context", metadata: ["projectId": projectId.uuidString])
            return
        }
        guard let sd = fetchSDProject(by: projectId) else {
            logWarning("set_finished_image_no_sd_record", metadata: ["projectId": projectId.uuidString])
            return
        }
        sd.finishedImage = finishedImage
        // 上传成品图时，如果没有完成日期，自动设置为当天。
        if autoFillCompletedDate, finishedImage != nil, sd.completedDate == nil {
            let now = Date()
            sd.completedDate = now
            // in-memory projects 也要同步
            if let idx = projects.firstIndex(where: { $0.id == projectId }) {
                projects[idx].completedDate = now
            }
        }
        do {
            try context.save()
        } catch {
            logError("set_finished_image_save_failed", metadata: [
                "projectId": projectId.uuidString,
                "error": "\(error)"
            ])
            return
        }
        if finishedImage != nil { projectIDsWithFinishedImage.insert(projectId) } else { projectIDsWithFinishedImage.remove(projectId) }
        projectBlobsRevision &+= 1
    }

    /// 给某个 in-memory `ProjectRecord` 卸掉 thumbnail / finishedImage / patternGrid / displayThumbnail。
    /// 用在 addProject / duplicate 这种「先把含 blob 的 record 暂存进 projects 数组以触发
    /// SDProjectRecord(from:) 持久化」的路径上：持久化完成后立刻把内存里的 blob 删掉，
    /// 否则连续 N 次扫描添加项目时 blob 会在内存里重新堆起来，重蹈 458 项目 jetsam 路。
    fileprivate func stripBlobFromInMemoryProject(_ projectId: UUID) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[idx].thumbnail = nil
        projects[idx].finishedImage = nil
        projects[idx].patternGrid = nil
        projects[idx].displayThumbnail = nil
    }

    /// 备份还原专用的批量 blob 写入。
    ///
    /// 语义：每个项目的 thumbnail / finishedImage **总是**按备份里的值写回，包括用 nil 清空
    /// （备份明确说该项目无图，store 上还残留旧图就该清）。patternGrid **只在备份提供时**写
    /// （`patternGridProvided == true` 才覆盖；当前备份 JSON 还没 round-trip 这个字段，
    /// 调用方一律传 false，避免清掉用户当前的网格标定）。
    ///
    /// 历史处理：本路径**完全不**记录 history（恢复备份不是用户的"操作"，不应该出现在
    /// 撤销栈里，否则 458 项目级用户一次 restore 会灌进几百条 history entries）。
    /// isPlanned 守卫：本路径**绕过** updateProjectFinishedImage 里的 `!isPlanned` 守卫
    /// （restore 不区分计划/已执行；计划项目也可以从备份还原其 finishedImage 字段
    /// —— 即使语义少见，也比静默丢数据强）。
    ///
    /// 调用方应在循环结束后由本方法内部统一调一次 `refreshProjectBlobMetadata()` 重建
    /// 三个 ID 集合，避免逐条增量更新引入抖动。
    ///
    /// - Returns: `RestoreBlobsResult` — `succeeded` 是成功写入的条目数，`failedIDs`
    ///   是 _setProjectBlobsDirectly 返回 false 的项目 ID 列表（context 缺失 / SD record
    ///   不存在 / save 抛错）。调用方应检查返回值；至少打印失败计数让备份 UI
    ///   能区分"完整恢复"和"部分恢复"。
    @MainActor
    @discardableResult
    func restoreProjectBlobsFromBackup(
        _ entries: [(id: UUID, thumbnail: Data?, finishedImage: Data?, patternGridData: Data?, patternGridProvided: Bool, displayThumbnail: Data?, displayThumbnailProvided: Bool)]
    ) -> RestoreBlobsResult {
        var failedIDs: [UUID] = []
        for entry in entries {
            // patternGrid 仅在备份显式带值时写入；否则保留 store 上的旧网格。
            let gridArg: Data?? = entry.patternGridProvided ? .some(entry.patternGridData) : .none
            // displayThumbnail：备份带就写（即使是 nil，也是显式声明"这条没有列表小图，
            // 让迁移协调器后续 backfill"）；备份没这个字段（老备份）→ 不动 store 旧值。
            let displayArg: Data?? = entry.displayThumbnailProvided ? .some(entry.displayThumbnail) : .none
            let ok = _setProjectBlobsDirectly(
                projectId: entry.id,
                thumbnail: .some(entry.thumbnail),
                finishedImage: .some(entry.finishedImage),
                patternGridData: gridArg,
                displayThumbnail: displayArg
            )
            if !ok { failedIDs.append(entry.id) }
        }
        // 内部 _setProjectBlobsDirectly 已经在增量更新四个 Set，但整批操作后
        // 跑一次 refreshProjectBlobMetadata 更稳：能纠正任何中途 catch 漏更的状态，
        // 同时再 bump 一次 revision 让所有视图 .task(id:) 重取。
        refreshProjectBlobMetadata()
        if !failedIDs.isEmpty {
            logError("restore_blobs_partial_failure", metadata: [
                "totalCount": entries.count,
                "failedCount": failedIDs.count,
                "sampleFailedIds": failedIDs.prefix(10).map { $0.uuidString }.joined(separator: ",")
            ])
        }
        return RestoreBlobsResult(succeeded: entries.count - failedIDs.count, failedIDs: failedIDs)
    }

    /// `restoreProjectBlobsFromBackup` 的返回值；让 BackupManager 能区分"完整恢复"和
    /// "部分恢复 N 项失败"。`failedIDs` 是 `_setProjectBlobsDirectly` 返回 false 的项目 ID。
    struct RestoreBlobsResult {
        let succeeded: Int
        let failedIDs: [UUID]
        var hasFailures: Bool { !failedIDs.isEmpty }
    }

    /// 更新项目缩略图（支持计划项目和已执行项目）—— 直写 SwiftData，不走 saveData diff。
    ///
    /// History 处理：本路径**同时**把 OLD thumbnail 和 OLD finishedImage 都回填到 snapshot，
    /// 设 `capturesImages: true`。原因：`capturesImages` 在 ProjectSnapshot 里是单 Bool，
    /// undo 路径会同时 `updateProjectThumbnail` 和 `updateProjectFinishedImage` 还原。
    /// 如果只回填本次改动的那一字段，另一字段（finishedImage）就会被 undo 写 nil 清空。
    /// 所以"任何 image 改动 → snapshot 同时带两张图"。
    func updateProjectThumbnail(_ projectId: UUID, thumbnail: Data?) {
        guard let index = projects.firstIndex(where: { $0.id == projectId }) else { return }

        var snapshotProject = projects[index]
        snapshotProject.thumbnail = fetchProjectThumbnailData(for: projectId)
        snapshotProject.finishedImage = fetchProjectFinishedImageData(for: projectId)
        snapshotProject.displayThumbnail = fetchProjectDisplayThumbnail(for: projectId)
        historyManager.recordProject(
            type: projects[index].isPlanned ? .planUpdate : .projectUpdate,
            project: snapshotProject,
            capturesImages: true
        )

        // 同步生成 NEW displayThumbnail —— thumbnail == nil 时清空 displayThumbnail；
        // 否则 downsample 一个新的。downsample 失败时清 displayThumbnail（保持跟 raw thumbnail
        // 同步，列表 row 会走 fallback 实时降级路径）。
        var newDisplayThumbnail: Data? = nil
        if let data = thumbnail {
            if let d = ImageDownsampler.downsample(data) {
                newDisplayThumbnail = d
            } else {
                logError("display_thumbnail_downsample_failed_at_update", metadata: [
                    "projectId": projectId.uuidString,
                    "sourceBytes": data.count
                ])
            }
        }
        _setProjectBlobsDirectly(
            projectId: projectId,
            thumbnail: .some(thumbnail),
            displayThumbnail: .some(newDisplayThumbnail)
        )
        logInfo("project_thumbnail_updated", metadata: [
            "projectId": projectId.uuidString,
            "hasData": thumbnail != nil
        ])
    }

    /// 更新项目的拼图模式网格数据（四角 / 行列 / 色号矩阵）—— 直写 SwiftData。
    ///
    /// History 处理：**不**记录历史。`.projectUpdate` 的 undo 路径目前不会还原 patternGrid，
    /// 加 history 会产生「dead undo」（用户以为可以撤回但其实无效）。
    /// 网格是校准元数据而不是用户内容，未来如果要做 grid undo，需要扩展 ProjectSnapshot
    /// 携带 patternGrid 字段并在 undo 分支里同时还原。
    func updateProjectPatternGrid(_ projectId: UUID, grid: BeadPatternGrid?) {
        guard projects.contains(where: { $0.id == projectId }) else { return }

        // 编码失败时**保留**原 patternGridData 不覆盖（保持原 saveData 同义语：
        // 防止把云端最新值用 nil 覆盖造成全设备数据丢失）。这里通过把 .none 传给
        // `_setProjectBlobsDirectly` 实现"不动该字段"。
        let newData: Data??
        if let grid = grid {
            if let encoded = SDProjectRecord.encodePatternGrid(grid, projectId: projectId) {
                newData = .some(.some(encoded))
            } else {
                newData = .none // 编码失败，logger 已记录，保留旧值
            }
        } else {
            newData = .some(nil) // 用户明确清空
        }
        if case .some = newData {
            _setProjectBlobsDirectly(projectId: projectId, patternGridData: newData)
        }
        logInfo("project_pattern_grid_updated", metadata: [
            "projectId": projectId.uuidString,
            "hasGrid": grid != nil
        ])
    }

    /// 更新项目成品图（仅已执行项目）—— 直写 SwiftData。
    /// 如果是新增成品图且之前没有完成日期，自动设置为当天。
    /// History 处理：同 `updateProjectThumbnail` —— 同时回填 OLD thumbnail + finishedImage。
    func updateProjectFinishedImage(_ projectId: UUID, finishedImage: Data?) {
        guard let index = projects.firstIndex(where: { $0.id == projectId && !$0.isPlanned }) else {
            logWarning("update_finished_image_skipped_planned_or_missing", metadata: [
                "projectId": projectId.uuidString
            ])
            return
        }

        var snapshotProject = projects[index]
        snapshotProject.thumbnail = fetchProjectThumbnailData(for: projectId)
        snapshotProject.finishedImage = fetchProjectFinishedImageData(for: projectId)
        snapshotProject.displayThumbnail = fetchProjectDisplayThumbnail(for: projectId)
        historyManager.recordProject(
            type: .projectUpdate,
            project: snapshotProject,
            capturesImages: true
        )

        _setProjectFinishedImageDirectly(
            projectId: projectId,
            finishedImage: finishedImage,
            autoFillCompletedDate: true
        )
        logInfo("project_finished_image_updated", metadata: [
            "projectId": projectId.uuidString,
            "hasData": finishedImage != nil
        ])
    }

    /// 更新项目完成日期（仅已执行项目）
    func updateProjectCompletedDate(_ projectId: UUID, completedDate: Date?) {
        if let index = projects.firstIndex(where: { $0.id == projectId && !$0.isPlanned }) {
            // 记录历史
            historyManager.recordProject(type: .projectUpdate, project: projects[index])

            projects[index].completedDate = completedDate
            saveData()
        }
    }

    // MARK: - 统计

    var totalStock: Int {
        beadColors.reduce(0) { $0 + $1.stock }
    }

    var totalUsed: Int {
        beadColors.reduce(0) { $0 + $1.used }
    }

    var totalAvailable: Int {
        beadColors.reduce(0) { $0 + $1.available }
    }

    var lowStockColors: [BeadColor] {
        beadColors.filter { $0.available < 100 }
    }

    // MARK: - 运输中（购买记录）

    /// 添加购买记录
    func addPurchaseRecord(name: String, brandId: UUID, items: [PurchaseItem], note: String? = nil) {
        let record = PurchaseRecord(name: name, brandId: brandId, items: items, note: note)
        purchaseRecords.append(record)
        savePurchaseRecords()
    }

    /// 删除购买记录
    func deletePurchaseRecord(id: UUID) {
        purchaseRecords.removeAll { $0.id == id }
        savePurchaseRecords()
    }

    /// 确认购买记录到货（添加到库存并删除记录）
    func confirmPurchaseRecord(id: UUID) {
        guard let record = purchaseRecords.first(where: { $0.id == id }) else { return }

        // 批量将购买的物品添加到库存（不记录单独的历史）
        for item in record.items {
            if let index = brandStocks.firstIndex(where: {
                $0.brandId == record.brandId && $0.mardCode == item.colorCode
            }) {
                brandStocks[index].stock += item.quantity
                // 如果是隐藏的色号，自动取消隐藏
                if brandStocks[index].isHidden {
                    brandStocks[index].isHidden = false
                }
            }
        }

        // 一次性保存所有库存变更
        saveData()

        // 记录历史（只记录一次汇总）
        // 注意：entityName 是持久化数据（HistoryRecord），不可本地化，以保证 iCloud 同步一致性
        let brandName = brands.first(where: { $0.id == record.brandId })?.name ?? "未知品牌"
        historyManager.record(type: .stockAdd, entityName: "\(brandName) 到货: \(record.name) (\(record.colorCount)色 +\(record.totalBeads)颗)")

        // 删除记录
        purchaseRecords.removeAll { $0.id == id }
        savePurchaseRecords()
    }

    /// 更新购买记录
    func updatePurchaseRecord(id: UUID, name: String? = nil, brandId: UUID? = nil, items: [PurchaseItem]? = nil, note: String? = nil) {
        guard let index = purchaseRecords.firstIndex(where: { $0.id == id }) else { return }
        if let name = name {
            purchaseRecords[index].name = name
        }
        if let brandId = brandId {
            purchaseRecords[index].brandId = brandId
        }
        if let items = items {
            purchaseRecords[index].items = items
        }
        if let note = note {
            purchaseRecords[index].note = note
        }
        savePurchaseRecords()
    }

    /// 获取指定品牌的购买记录
    func purchaseRecords(for brandId: UUID) -> [PurchaseRecord] {
        purchaseRecords.filter { $0.brandId == brandId }
    }

    // MARK: - 重置

    func resetAllStock(to amount: Int = 1000) {
        guard let brandId = currentBrandId else { return }

        // 获取当前品牌名称用于历史记录
        // 注意：brandName 用于 entityName（持久化数据），不可本地化，以保证 iCloud 同步一致性
        let brandName = brands.first(where: { $0.id == brandId })?.name ?? "未知品牌"

        // 清除当前品牌的所有库存记录
        brandStocks.removeAll { $0.brandId == brandId }
        // 为每个颜色创建新的库存记录
        for color in beadColors {
            let newStock = BrandStock(brandId: brandId, mardCode: color.mardCode, stock: amount, used: 0)
            brandStocks.append(newStock)
        }
        saveData()

        // 记录历史
        historyManager.record(type: .stockReset, entityName: "\(brandName) → \(amount)")
    }

    func resetUsage() {
        guard let brandId = currentBrandId else { return }
        // 重置当前品牌所有颜色的使用记录
        for index in brandStocks.indices {
            if brandStocks[index].brandId == brandId {
                brandStocks[index].used = 0
            }
        }
        saveData()
    }

    func clearAllData() {
        // 仅 clearAllData 触发显式全量清空授权，避免异常空数据误写入
        authorizeFullPurge()

        // 清除所有品牌库存数据
        brandStocks.removeAll()
        // 清除所有项目记录
        projects.removeAll()
        saveData()
    }

    /// 授权一次全量清空（默认 15 秒有效）
    private func authorizeFullPurge(validFor seconds: TimeInterval = 15) {
        fullPurgeAuthorizedUntil = Date().addingTimeInterval(seconds)
    }

    // MARK: - 初始化默认颜色数据

    private func initializeDefaultColors() {
        beadColors = loadAllColorsFromJSON()
        print("[InventoryManager] 从 allcolors.json 加载 \(beadColors.count) 个颜色")
    }

    // MARK: - 从 allcolors.json 加载所有颜色数据
    /// 统一颜色数据源：包含所有 MARD 标准色 + 卡卡独有色（含真实 HEX）
    private func loadAllColorsFromJSON() -> [BeadColor] {
        guard let url = Bundle.main.url(forResource: "allcolors", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            print("[InventoryManager] ⚠️ 未找到 allcolors.json，使用空颜色列表")
            return []
        }

        do {
            let entries = try JSONDecoder().decode([[String: String]].self, from: data)
            return entries.enumerated().map { index, entry in
                BeadColor(
                    id: stableColorID(for: entry, index: index),
                    colorHex: entry["colorHex"] ?? "CCCCCC",
                    mardCode: entry["mardCode"] ?? "",
                    cocoCode: entry["cocoCode"] ?? "",
                    manmanCode: entry["manmanCode"] ?? "",
                    panpanCode: entry["panpanCode"] ?? "",
                    mixiaowoCode: entry["mixiaowoCode"] ?? "",
                    kakaCode: entry["kakaCode"] ?? ""
                )
            }
        } catch {
            print("[InventoryManager] ⚠️ allcolors.json 解析失败: \(error)")
            return []
        }
    }

    /// 为 JSON 颜色生成稳定 ID，避免重载后 UUID 漂移导致 UI 选中状态错乱
    private func stableColorID(for entry: [String: String], index: Int) -> UUID {
        let mardCode = (entry["mardCode"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let key: String
        if !mardCode.isEmpty {
            key = "mard:\(mardCode)"
        } else {
            // 理论上不会触发（allcolors.json 的 mardCode 不为空），仅做兜底保证唯一性
            let fallbackParts = [
                entry["cocoCode"] ?? "",
                entry["manmanCode"] ?? "",
                entry["panpanCode"] ?? "",
                entry["mixiaowoCode"] ?? "",
                entry["kakaCode"] ?? "",
                "\(index)"
            ]
            key = "fallback:\(fallbackParts.joined(separator: "|"))"
        }
        return stableUUID(for: key)
    }

    private func stableUUID(for key: String) -> UUID {
        let digest = SHA256.hash(data: Data(key.utf8))
        let bytes = Array(digest.prefix(16))
        let tuple = uuid_t(
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }

}


// MARK: - 项目 blob 存在性扫描（raw SQLite）

/// 「哪些项目带某个 blob」的 4 个存在性集合，值类型跨线程安全。
struct ProjectBlobExistence: Sendable {
    var finishedImage: Set<UUID> = []
    var thumbnail: Set<UUID> = []
    var patternGrid: Set<UUID> = []
    var displayThumbnail: Set<UUID> = []
}

/// 用只读 SQLite 连接对 store 文件做 `WHERE 列 IS NOT NULL` 的存在性扫描。
///
/// ## 为什么绕开 SwiftData
///
/// `#Predicate { $0.thumbnail != nil }` + `propertiesToFetch = [\.id]` 看起来只取 id，
/// 实测（InitialLoadMemoryDiagnosticTests，120 条 × 10.5MB 库）会把**每条命中行的 blob
/// 内容整个 SELECT 进进程内存：+1.26GB**。四个存在性查询跑在每次首次加载和每次 refresh
/// 里，真实体量库上进程峰值实测冲到 5.7GB —— 真机前台 jetsam 上限只有 ~1.2-2.5GB，
/// 表现就是用户报的「转圈转着转着突然闪退」。
///
/// SQLite 判 `IS NOT NULL` 只读记录头的 serial type，不物化 blob 内容；本扫描器全程
/// 只在 C 层持有单行 ZID（16 字节），内存增量 ≈ 0。
///
/// ## 安全边界
///
/// - 只读打开（`SQLITE_OPEN_READONLY`），不可能写坏 store；WAL 模式下读到的是一致性快照。
/// - 启动即用 `PRAGMA table_info` 核对表/列存在；任何一步对不上（未来 schema 变更、
///   in-memory 测试库没有文件）→ 返回 nil，调用方回退 SwiftData 查询（行为同旧版）。
/// - CoreData 的 UUID 属性存储为 16 字节 BLOB（旧数据可能是 TEXT），两种都解析；
///   出现解析不了的行说明假设失效，整次扫描作废回退，绝不静默丢行。
enum ProjectBlobExistenceScanner {
    private static let table = "ZSDPROJECTRECORD"
    private static let idColumn = "ZID"
    private static let blobColumns: [(column: String, keyPath: WritableKeyPath<ProjectBlobExistence, Set<UUID>>)] = [
        ("ZFINISHEDIMAGE", \.finishedImage),
        ("ZTHUMBNAIL", \.thumbnail),
        ("ZPATTERNGRIDDATA", \.patternGrid),
        ("ZDISPLAYTHUMBNAIL", \.displayThumbnail)
    ]

    /// - Returns: 失败时区分 `.unsupportedStore`（永久，可回退 SwiftData 查询）
    ///   和 `.transient`（SQLITE_BUSY / I-O，**不可**回退 —— 见 `StoreScanFailure` 注释）。
    static func scan(storeURL: URL) -> Result<ProjectBlobExistence, StoreScanFailure> {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return .failure(.unsupportedStore)
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            let failure = StoreScanFailure.classify(db)
            if db != nil { sqlite3_close(db) }
            return .failure(failure)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2_000)

        // 核对 schema：表和所有依赖列必须存在，否则回退（未来改模型时的保险丝）
        var existingColumns = Set<String>()
        do {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else {
                return .failure(StoreScanFailure.classify(db))
            }
            defer { sqlite3_finalize(stmt) }
            var rc = sqlite3_step(stmt)
            while rc == SQLITE_ROW {
                if let name = sqlite3_column_text(stmt, 1) {
                    existingColumns.insert(String(cString: name).uppercased())
                }
                rc = sqlite3_step(stmt)
            }
            // 终止码必须检查 —— 中途 SQLITE_BUSY 会安静退出循环留下残缺列名集合，
            // 下面 allSatisfy 失败即误判成永久不支持。详见 StoreScanFailure.classify。
            guard rc == SQLITE_DONE else {
                return .failure(StoreScanFailure.classify(db))
            }
        }
        let required = [idColumn] + blobColumns.map(\.column)
        guard required.allSatisfy({ existingColumns.contains($0) }) else {
            return .failure(.unsupportedStore)
        }

        var result = ProjectBlobExistence()
        for (column, keyPath) in blobColumns {
            var stmt: OpaquePointer?
            let sql = "SELECT \(idColumn) FROM \(table) WHERE \(column) IS NOT NULL"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return .failure(StoreScanFailure.classify(db))
            }
            defer { sqlite3_finalize(stmt) }

            var ids = Set<UUID>()
            var rc = sqlite3_step(stmt)
            while rc == SQLITE_ROW {
                switch sqlite3_column_type(stmt, 0) {
                case SQLITE_BLOB where sqlite3_column_bytes(stmt, 0) == 16:
                    guard let raw = sqlite3_column_blob(stmt, 0) else { return .failure(.unsupportedStore) }
                    ids.insert(UUID(uuid: raw.load(as: uuid_t.self)))
                case SQLITE_TEXT:
                    guard let c = sqlite3_column_text(stmt, 0),
                          let uuid = UUID(uuidString: String(cString: c)) else {
                        return .failure(.unsupportedStore)
                    }
                    ids.insert(uuid)
                default:
                    // ZID 形态不符合任何已知存储方式：假设失效，整次作废回退
                    return .failure(.unsupportedStore)
                }
                rc = sqlite3_step(stmt)
            }
            guard rc == SQLITE_DONE else { return .failure(StoreScanFailure.classify(db)) }
            result[keyPath: keyPath] = ids
        }
        return .success(result)
    }
}
