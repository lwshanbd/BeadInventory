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
    // 自 v2.0.x 起：`projects` 不再持有 thumbnail / finishedImage / patternGridData
    // 三个大 Data blob（防止 458 项目级用户加载完 ~200MB 撞 jetsam）。视图需要图片
    // 时走 fetchProjectThumbnailData / fetchProjectFinishedImageData / fetchProjectPatternGrid
    // 按需从 SwiftData 取单条 row。
    //
    // 为了让 CalendarView 这类「我有没有成品图」的查询不需要加载实际 Data，
    // 单独缓存一份 ID 集合：只查 `finishedImage != nil` 谓词，SQL 层就能完成不读 blob。
    /// 持久层里有 finishedImage 的项目 ID 集合（不含 Data）。
    /// 在 loadData 完成后 / updateProjectFinishedImage 后刷新。
    @Published private(set) var projectIDsWithFinishedImage: Set<UUID> = []

    /// 持久层里有 thumbnail 的项目 ID 集合（不含 Data）。
    @Published private(set) var projectIDsWithThumbnail: Set<UUID> = []

    /// 持久层里有 patternGridData 的项目 ID 集合（不含 Data）。
    /// 用于 "拼图模式" 按钮判断是直接进 highlight 还是先 calibration。
    @Published private(set) var projectIDsWithPatternGrid: Set<UUID> = []

    /// 项目 blob（thumbnail / finishedImage / patternGrid）的全局版本号。
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
    // 458 项目的 plan 页 buildShortageMap 之前是 458 × O(458) = O(N²) ≈ 210K 次比较，
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
    private var modelContext: ModelContext?

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
        logInfo("init_with_model_context")
        initializeDefaultColors()
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
        performInitialLoadIfNeeded(reason: reason, force: true)
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
            performInitialLoadIfNeeded(reason: reason)
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
            performInitialLoadIfNeeded(reason: reason)
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

    func loadData(preserveInMemoryOnFailure: Bool = false) {
        guard !isLoadingPersistentStore else {
            logWarning("load_data_skipped_already_loading", metadata: [
                "preserveInMemoryOnFailure": preserveInMemoryOnFailure
            ])
            return
        }

        isLoadingPersistentStore = true
        defer {
            isLoadingPersistentStore = false
            replayDeferredRefreshIfNeeded()
        }

        AppBackgroundTaskManager.shared.perform(named: "InventoryLoad") {
            let fallbackSnapshot = preserveInMemoryOnFailure ? makeInMemorySnapshot() : nil
            logInfo("load_data_started", metadata: [
                "preserveInMemoryOnFailure": preserveInMemoryOnFailure
            ])

            guard let context = modelContext else {
                logWarning("load_data_use_user_defaults_mode")
                loadDataFromUserDefaults()
                return
            }

            // 重置加载状态标志（在开始时重置 isDataLoaded，让逻辑更封闭）
            isDataLoaded = false
            brandsLoadedSuccessfully = false
            stocksLoadedSuccessfully = false
            projectsLoadedSuccessfully = false
            customColorsLoadedSuccessfully = false

            // 检查是否需要迁移
            let needsMigration = !UserDefaults.standard.bool(forKey: migrationCompletedKey)
            if needsMigration {
                migrateFromUserDefaults()
            }

            // 先拉取到临时变量，避免半成功状态直接污染当前内存数据
            var loadedBrands = brands
            var loadedBrandStocks = brandStocks
            var loadedProjects = projects
            var loadedCustomColors = customColors
            var loadedCurrentBrandId = currentBrandId
            var loadedPurchaseRecords = purchaseRecords
            let loadedBeadColors = loadAllColorsFromJSON()

            // 从 SwiftData 加载品牌
            do {
                let brandDescriptor = FetchDescriptor<SDBrand>(sortBy: [SortDescriptor(\.sortOrder)])
                let sdBrands = try context.fetch(brandDescriptor)
                loadedBrands = sdBrands.map { $0.toStruct() }
                brandsLoadedSuccessfully = true
                print("[InventoryManager] 成功加载 \(loadedBrands.count) 个品牌")
                logInfo("load_brands_success", metadata: ["count": loadedBrands.count])
            } catch {
                print("[InventoryManager] ⚠️ 加载品牌失败: \(error)")
                logError("load_brands_failed", metadata: ["error": "\(error)"])
            }

            // 从 SwiftData 加载品牌库存
            do {
                let stockDescriptor = FetchDescriptor<SDBrandStock>()
                let sdStocks = try context.fetch(stockDescriptor)
                loadedBrandStocks = sdStocks.map { $0.toStruct() }
                stocksLoadedSuccessfully = true
                print("[InventoryManager] 成功加载 \(loadedBrandStocks.count) 条库存记录")
                logInfo("load_stocks_success", metadata: ["count": loadedBrandStocks.count])
            } catch {
                print("[InventoryManager] ⚠️ 加载库存失败: \(error)")
                logError("load_stocks_failed", metadata: ["error": "\(error)"])
            }

            // 从 SwiftData 加载项目记录
            //
            // 关键：用 toMetadataStruct() 而不是 toStruct() —— 不读 thumbnail / finishedImage /
            // patternGridData 三个大 Data blob。458 项目级用户曾因为这三个字段全部 inline
            // 物化进内存爆 ~200MB 被 jetsam。视图需要图片时按需走 fetchProjectThumbnailData /
            // fetchProjectFinishedImageData / fetchProjectPatternGrid 取单条 row。
            do {
                let projectDescriptor = FetchDescriptor<SDProjectRecord>(sortBy: [SortDescriptor(\.date, order: .reverse)])
                let sdProjects = try context.fetch(projectDescriptor)
                loadedProjects = sdProjects.map { $0.toMetadataStruct() }
                projectsLoadedSuccessfully = true
                print("[InventoryManager] 成功加载 \(loadedProjects.count) 个项目记录 (metadata-only)")
                logInfo("load_projects_success", metadata: ["count": loadedProjects.count])
            } catch {
                print("[InventoryManager] ⚠️ 加载项目失败: \(error)")
                logError("load_projects_failed", metadata: ["error": "\(error)"])
            }

            // 加载当前品牌 ID
            if let idString = UserDefaults.standard.string(forKey: currentBrandIdKey),
               let id = UUID(uuidString: idString) {
                loadedCurrentBrandId = id
            }

            // 从 SwiftData 加载自定义色号
            do {
                let customColorDescriptor = FetchDescriptor<SDCustomColor>(sortBy: [SortDescriptor(\.createdAt)])
                let sdCustomColors = try context.fetch(customColorDescriptor)
                loadedCustomColors = sdCustomColors.map { $0.toStruct() }
                customColorsLoadedSuccessfully = true
                print("[InventoryManager] 成功加载 \(loadedCustomColors.count) 个自定义色号")
                logInfo("load_custom_colors_success", metadata: ["count": loadedCustomColors.count])
            } catch {
                print("[InventoryManager] ⚠️ 加载自定义色号失败: \(error)")
                logError("load_custom_colors_failed", metadata: ["error": "\(error)"])
            }

            // 加载运输中的购买记录（存在 UserDefaults 中）
            if let data = UserDefaults.standard.data(forKey: purchaseRecordsKey),
               let decoded = try? JSONDecoder().decode([PurchaseRecord].self, from: data) {
                loadedPurchaseRecords = decoded
            }

            // 只有当所有关键数据都成功加载时，才标记为加载完成
            let allLoaded = brandsLoadedSuccessfully && stocksLoadedSuccessfully && projectsLoadedSuccessfully
            if allLoaded {
                // 防护：如果用户之前有数据，但本次 fetch 全部返回空，说明 SwiftData 加载异常
                // 拒绝标记为加载成功，阻止后续 saveData() 把空数据写入数据库覆盖原有记录
                let allEmpty = loadedBrands.isEmpty
                    && loadedBrandStocks.isEmpty
                    && loadedProjects.isEmpty
                    && loadedCustomColors.isEmpty
                let hadDataBefore = UserDefaults.standard.bool(forKey: hasExistingDataKey)

                // 防护：刷新期间若出现“品牌/库存骤减”，优先认为是同步中的中间态，不覆盖当前内存
                if let snapshot = fallbackSnapshot {
                    let suspiciousBrandDrop = snapshot.brands.count >= 3
                        && loadedBrands.count > 0
                        && loadedBrands.count * 2 < snapshot.brands.count
                    let suspiciousStockDrop = snapshot.brandStocks.count >= 200
                        && loadedBrandStocks.count > 0
                        && loadedBrandStocks.count * 2 < snapshot.brandStocks.count

                    if suspiciousBrandDrop || suspiciousStockDrop {
                        print("[InventoryManager] ⚠️ 检测到异常骤减（品牌/库存），判定为同步中间态，保留当前内存数据")
                        logWarning("load_data_suspicious_drop", metadata: [
                            "previousBrands": snapshot.brands.count,
                            "loadedBrands": loadedBrands.count,
                            "previousStocks": snapshot.brandStocks.count,
                            "loadedStocks": loadedBrandStocks.count
                        ])
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
                    print("[InventoryManager] ⚠️ 异常：数据库应有数据但加载全部为空，拒绝标记为加载成功以防覆盖")
                    logWarning("load_data_rejected_all_empty_after_existing_data")
                    // 不设置 isDataLoaded = true，saveData() 会被 guard 拦截
                    if let snapshot = fallbackSnapshot {
                        print("[InventoryManager] 已回滚到刷新前的内存数据，保持当前可用状态")
                        restoreInMemorySnapshot(snapshot)
                    }
                    finishInitialLoadFailure(
                        userMessage: String(localized: "暂时无法确认已有数据，请稍后重试。"),
                        metadata: ["failure": "unexpectedAllEmpty"]
                    )
                    return
                }

                // 当前品牌不存在时回退到首个品牌，避免引用悬空
                if let selectedBrandId = loadedCurrentBrandId,
                   !loadedBrands.contains(where: { $0.id == selectedBrandId }) {
                    loadedCurrentBrandId = loadedBrands.first?.id
                }

                // 用户主动选了 fallback 后又收到了一次成功的加载结果（例如 CloudKit
                // 远程通知触发了 refreshFromPersistentStore）。用真实数据接管 UI 是
                // 严格更优的状态，但用户并不知道——明确记一条日志，便于排查
                // "fallback 期间的写入丢失" 类问题。
                if isUsingLocalFallbackMode {
                    logInfo("local_fallback_exited_on_successful_load")
                    isUsingLocalFallbackMode = false
                }

                // 原子提交：避免中途状态导致 UI 看到“品牌突然消失”
                brands = loadedBrands
                brandStocks = loadedBrandStocks
                projects = loadedProjects
                customColors = loadedCustomColors
                currentBrandId = loadedCurrentBrandId
                purchaseRecords = loadedPurchaseRecords
                beadColors = loadedBeadColors

                isDataLoaded = true
                finishInitialLoadSuccess()
                hasCompletedInitialPersistentLoad = true
                print("[InventoryManager] ✅ 数据加载完成")
                logInfo("load_data_completed", metadata: [
                    "brands": brands.count,
                    "stocks": brandStocks.count,
                    "projects": projects.count,
                    "customColors": customColors.count
                ])

                // 标记用户已有数据（只要有任何一项非空就标记）
                if !allEmpty {
                    UserDefaults.standard.set(true, forKey: hasExistingDataKey)
                }

                // 刷新「持久层里有 finishedImage 的项目 ID 集合」—— CalendarView 类的
                // 存在性过滤要靠它（projects 本身已经不带 finishedImage Data）。
                refreshProjectBlobMetadata()

                // 刷新保存基线：后续 saveData() 只写入本地真实改动
                refreshBaselines()

                // 修复数据一致性问题（仅基于 executedDate 判断）
                fixProjectConsistency()
            } else {
                print("[InventoryManager] ❌ 部分数据加载失败，禁止后续保存操作以防数据丢失")
                print("[InventoryManager]   - 品牌: \(brandsLoadedSuccessfully ? "✅" : "❌")")
                print("[InventoryManager]   - 库存: \(stocksLoadedSuccessfully ? "✅" : "❌")")
                print("[InventoryManager]   - 项目: \(projectsLoadedSuccessfully ? "✅" : "❌")")
                print("[InventoryManager]   - 自定义色号: \(customColorsLoadedSuccessfully ? "✅" : "❌")")
                logError("load_data_partial_failure", metadata: [
                    "brandsLoaded": brandsLoadedSuccessfully,
                    "stocksLoaded": stocksLoadedSuccessfully,
                    "projectsLoaded": projectsLoadedSuccessfully,
                    "customColorsLoaded": customColorsLoadedSuccessfully
                ])
                if let snapshot = fallbackSnapshot {
                    print("[InventoryManager] 已回滚到刷新前的内存数据，避免进入不可保存状态")
                    restoreInMemorySnapshot(snapshot)
                } else {
                    // 保持颜色数据可用（用于界面展示），其余实体维持原内存状态
                    beadColors = loadedBeadColors
                }
                finishInitialLoadFailure(
                    userMessage: String(localized: "部分数据加载失败，请点击重试。"),
                    metadata: [
                        "failure": "partialLoad",
                        "brandsLoaded": brandsLoadedSuccessfully,
                        "stocksLoaded": stocksLoadedSuccessfully,
                        "projectsLoaded": projectsLoadedSuccessfully,
                        "customColorsLoaded": customColorsLoadedSuccessfully
                    ]
                )
            }
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
                let existingProjects = try context.fetch(FetchDescriptor<SDProjectRecord>())
                let existingProjectByID = Dictionary(existingProjects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let localProjectByID = makeMapByID(projects)

                if projectsLoadedSuccessfully {
                    var remoteProjectsToAppend: [ProjectRecord] = []
                    for sdProject in existingProjects where localProjectByID[sdProject.id] == nil {
                        if baselineProjectsByID[sdProject.id] != nil {
                            context.delete(sdProject)
                        } else {
                            remoteProjectsToAppend.append(sdProject.toStruct())
                        }
                    }
                    if !remoteProjectsToAppend.isEmpty {
                        projects.append(contentsOf: remoteProjectsToAppend)
                        projects.sort { $0.date > $1.date }
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
                        // existing.patternGridData ——
                        // 自 v2.0.x 起 `projects` 缓存里这三个字段恒为 nil（避免大 blob 物化进内存
                        // 撞 jetsam），如果还沿用旧 diff 写回，等于每次保存都把云端真数据用 nil
                        // 覆盖掉。这些字段改走 updateProjectThumbnail / updateProjectFinishedImage /
                        // updateProjectPatternGrid 直接对 SDProjectRecord 单 row 写入。

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

    private func migrateFromUserDefaults() {
        guard let context = modelContext else { return }
        // 与其它持久化路径同样的 fallback 守卫：fallback 期间不写库，
        // 等用户重启或 iCloud 恢复后再让迁移完成。
        if isUsingLocalFallbackMode {
            logWarning("migrate_from_user_defaults_skipped_local_fallback")
            return
        }

        print("开始从 UserDefaults 迁移数据到 SwiftData...")

        // 迁移品牌
        if let data = UserDefaults.standard.data(forKey: brandsKey),
           let decoded = try? JSONDecoder().decode([Brand].self, from: data) {
            for brand in decoded {
                let sdBrand = SDBrand(from: brand)
                context.insert(sdBrand)
            }
            print("迁移了 \(decoded.count) 个品牌")
        }

        // 迁移品牌库存
        if let data = UserDefaults.standard.data(forKey: brandStocksKey),
           let decoded = try? JSONDecoder().decode([BrandStock].self, from: data) {
            for stock in decoded {
                let sdStock = SDBrandStock(from: stock)
                context.insert(sdStock)
            }
            print("迁移了 \(decoded.count) 条库存记录")
        }

        // 迁移项目记录
        if let data = UserDefaults.standard.data(forKey: projectsKey),
           let decoded = try? JSONDecoder().decode([ProjectRecord].self, from: data) {
            for project in decoded {
                let sdProject = SDProjectRecord(from: project)
                context.insert(sdProject)
            }
            print("迁移了 \(decoded.count) 个项目记录")
        }

        do {
            try context.save()
            UserDefaults.standard.set(true, forKey: migrationCompletedKey)
            print("数据迁移完成！")
        } catch {
            print("数据迁移失败: \(error)")
        }
    }

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
        projects.insert(project, at: 0)
        saveData()

        // 记录历史
        historyManager.recordProject(type: .projectAdd, project: project)
    }

    func deleteProject(at offsets: IndexSet) {
        // 删除项目只从记录中移除，不回退库存
        projects.remove(atOffsets: offsets)
        saveData()
    }

    func deleteProject(id: UUID) {
        if let index = projects.firstIndex(where: { $0.id == id }) {
            let project = projects[index]

            // 记录历史（在删除前）
            historyManager.recordProject(type: .projectDelete, project: project)

            // 删除项目只从记录中移除，不回退库存
            projects.remove(at: index)
            saveData()
        }
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

            // 记录合并前的状态：所有子项目 + 所有父项目
            let originalProjects = allChildrenProjects + parentProjects

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
                    // 项目不存在（可能是被删除的旧父项目），需要重新创建
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
                        colorSystem: projectSnapshot.colorSystem
                    )
                    projects.append(restoredProject)
                }
            }

            saveData()
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
        projects.insert(plannedProject, at: 0)
        saveData()

        // 记录历史
        historyManager.recordProject(type: .planAdd, project: plannedProject)
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

        // 记录历史（在删除前），包含父项目和子项目
        historyManager.recordPlanDelete(project: project, children: children)

        // 如果是父项目，也删除子项目
        if !children.isEmpty {
            projects.removeAll { $0.parentId == projectId }
        }
        projects.removeAll { $0.id == projectId }
        saveData()
    }

    /// 复制计划项目（支持文件夹完整复制）
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

        // 创建副本项目
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
            thumbnail: project.thumbnail,
            colorSystem: project.colorSystem
        )

        // 插入到原项目后面
        projects.insert(duplicatedProject, at: index + 1)

        // 如果是父项目，复制所有子项目
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
                    thumbnail: child.thumbnail,
                    colorSystem: child.colorSystem
                )
                projects.append(duplicatedChild)
            }
        }

        saveData()

        // 记录历史
        historyManager.recordProject(type: .planAdd, project: duplicatedProject)

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
            thumbnail: project.thumbnail,
            colorSystem: project.colorSystem
        )

        // 插入到列表开头
        projects.insert(duplicatedProject, at: 0)

        // 如果是父项目，复制所有子项目
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
                    thumbnail: child.thumbnail,
                    colorSystem: child.colorSystem
                )
                projects.append(duplicatedChild)
            }
        }

        saveData()

        // 记录历史
        historyManager.recordProject(type: .planAdd, project: duplicatedProject)

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

    /// 同步取单个项目的 thumbnail Data。视图层应该在 `.task { }` 中调用，
    /// 让 SwiftData 解码 / 外部存储读取脱离主线程的「关键渲染窗口」。
    func fetchProjectThumbnailData(for projectId: UUID) -> Data? {
        guard let context = modelContext else { return nil }
        let descriptor = FetchDescriptor<SDProjectRecord>(
            predicate: #Predicate { $0.id == projectId }
        )
        return (try? context.fetch(descriptor).first)?.thumbnail
    }

    /// 同步取单个项目的 finishedImage Data。
    func fetchProjectFinishedImageData(for projectId: UUID) -> Data? {
        guard let context = modelContext else { return nil }
        let descriptor = FetchDescriptor<SDProjectRecord>(
            predicate: #Predicate { $0.id == projectId }
        )
        return (try? context.fetch(descriptor).first)?.finishedImage
    }

    /// 同步取单个项目的 BeadPatternGrid（拼图网格）。
    func fetchProjectPatternGrid(for projectId: UUID) -> BeadPatternGrid? {
        guard let context = modelContext else { return nil }
        let descriptor = FetchDescriptor<SDProjectRecord>(
            predicate: #Predicate { $0.id == projectId }
        )
        guard let sd = try? context.fetch(descriptor).first else { return nil }
        return SDProjectRecord.decodePatternGrid(sd.patternGridData, projectId: projectId)
    }

    /// 刷新「持久层里有 thumbnail / finishedImage / patternGridData 的项目 ID 集合」缓存。
    /// 谓词在 SQL 层完成 NULL 检查，不会把 blob 实际加载进内存
    /// （externalStorage 列只存引用；非 externalStorage 的 BLOB 列也只是查 IS NOT NULL）。
    /// 在每次 load_data_completed 之后调用一次；update* 路径自己增量更新对应集合。
    fileprivate func refreshProjectBlobMetadata() {
        guard let context = modelContext else {
            projectIDsWithFinishedImage = []
            projectIDsWithThumbnail = []
            projectIDsWithPatternGrid = []
            return
        }
        do {
            let finishedDesc = FetchDescriptor<SDProjectRecord>(predicate: #Predicate { $0.finishedImage != nil })
            let thumbDesc = FetchDescriptor<SDProjectRecord>(predicate: #Predicate { $0.thumbnail != nil })
            let gridDesc = FetchDescriptor<SDProjectRecord>(predicate: #Predicate { $0.patternGridData != nil })
            projectIDsWithFinishedImage = Set(try context.fetch(finishedDesc).map { $0.id })
            projectIDsWithThumbnail = Set(try context.fetch(thumbDesc).map { $0.id })
            projectIDsWithPatternGrid = Set(try context.fetch(gridDesc).map { $0.id })
        } catch {
            logError("project_blob_meta_refresh_failed", metadata: ["error": "\(error)"])
        }
    }

    /// 更新项目缩略图（支持计划项目和已执行项目）—— 直写 SwiftData，不走 saveData diff。
    func updateProjectThumbnail(_ projectId: UUID, thumbnail: Data?) {
        guard let context = modelContext else { return }
        guard let index = projects.firstIndex(where: { $0.id == projectId }) else { return }

        // 历史快照：把 OLD thumbnail 临时回填进 ProjectRecord 副本，让 undo 能还原。
        // 其它字段（finishedImage、patternGrid）此次操作没改，保持 nil 即可；
        // undo 路径只会还原本次 capturesImages 标记的字段。
        var snapshotProject = projects[index]
        snapshotProject.thumbnail = fetchProjectThumbnailData(for: projectId)
        historyManager.recordProject(
            type: projects[index].isPlanned ? .planUpdate : .projectUpdate,
            project: snapshotProject,
            capturesImages: true
        )

        do {
            let descriptor = FetchDescriptor<SDProjectRecord>(
                predicate: #Predicate { $0.id == projectId }
            )
            guard let sd = try context.fetch(descriptor).first else {
                logWarning("update_thumbnail_no_sd_record", metadata: ["projectId": projectId.uuidString])
                return
            }
            sd.thumbnail = thumbnail
            try context.save()
            // 同步缓存集合
            if thumbnail != nil {
                projectIDsWithThumbnail.insert(projectId)
            } else {
                projectIDsWithThumbnail.remove(projectId)
            }
            projectBlobsRevision &+= 1
            logInfo("project_thumbnail_updated", metadata: [
                "projectId": projectId.uuidString,
                "hasData": thumbnail != nil
            ])
        } catch {
            logError("project_thumbnail_update_failed", metadata: [
                "projectId": projectId.uuidString,
                "error": "\(error)"
            ])
        }
    }

    /// 更新项目的拼图模式网格数据（四角 / 行列 / 色号矩阵）—— 直写 SwiftData。
    func updateProjectPatternGrid(_ projectId: UUID, grid: BeadPatternGrid?) {
        guard let context = modelContext else { return }
        guard let index = projects.firstIndex(where: { $0.id == projectId }) else { return }

        historyManager.recordProject(
            type: projects[index].isPlanned ? .planUpdate : .projectUpdate,
            project: projects[index]
        )

        do {
            let descriptor = FetchDescriptor<SDProjectRecord>(
                predicate: #Predicate { $0.id == projectId }
            )
            guard let sd = try context.fetch(descriptor).first else {
                logWarning("update_pattern_grid_no_sd_record", metadata: ["projectId": projectId.uuidString])
                return
            }
            // 编码失败时**保留** existing.patternGridData 不覆盖（保持原 saveData 同义语：
            // 防止把云端最新值用 nil 覆盖造成全设备数据丢失）。
            if let grid = grid {
                if let data = SDProjectRecord.encodePatternGrid(grid, projectId: projectId) {
                    sd.patternGridData = data
                }
                // else: 编码失败，logger 已记录，sd.patternGridData 保持不变
            } else {
                // 用户明确清空，允许覆盖
                sd.patternGridData = nil
            }
            try context.save()
            // 同步缓存集合
            if sd.patternGridData != nil {
                projectIDsWithPatternGrid.insert(projectId)
            } else {
                projectIDsWithPatternGrid.remove(projectId)
            }
            projectBlobsRevision &+= 1
            logInfo("project_pattern_grid_updated", metadata: [
                "projectId": projectId.uuidString,
                "hasGrid": grid != nil
            ])
        } catch {
            logError("project_pattern_grid_update_failed", metadata: [
                "projectId": projectId.uuidString,
                "error": "\(error)"
            ])
        }
    }

    /// 更新项目成品图（仅已执行项目）—— 直写 SwiftData。
    /// 如果是新增成品图且之前没有完成日期，自动设置为当天。
    func updateProjectFinishedImage(_ projectId: UUID, finishedImage: Data?) {
        guard let context = modelContext else { return }
        guard let index = projects.firstIndex(where: { $0.id == projectId && !$0.isPlanned }) else { return }

        // 历史快照：把 OLD finishedImage 临时回填进 ProjectRecord 副本，让 undo 能还原。
        var snapshotProject = projects[index]
        snapshotProject.finishedImage = fetchProjectFinishedImageData(for: projectId)
        historyManager.recordProject(
            type: .projectUpdate,
            project: snapshotProject,
            capturesImages: true
        )

        do {
            let descriptor = FetchDescriptor<SDProjectRecord>(
                predicate: #Predicate { $0.id == projectId }
            )
            guard let sd = try context.fetch(descriptor).first else {
                logWarning("update_finished_image_no_sd_record", metadata: ["projectId": projectId.uuidString])
                return
            }
            sd.finishedImage = finishedImage

            // 上传成品图时，如果没有完成日期，自动设置为当天。
            // completedDate 也要同步到内存里 projects[index]，让日历视图立即反映。
            if finishedImage != nil && sd.completedDate == nil {
                let now = Date()
                sd.completedDate = now
                projects[index].completedDate = now
            }

            try context.save()

            // 同步更新 projectIDsWithFinishedImage 集合，让 CalendarView 立刻能看到 / 隐藏该项。
            if finishedImage != nil {
                projectIDsWithFinishedImage.insert(projectId)
            } else {
                projectIDsWithFinishedImage.remove(projectId)
            }
            projectBlobsRevision &+= 1
            logInfo("project_finished_image_updated", metadata: [
                "projectId": projectId.uuidString,
                "hasData": finishedImage != nil
            ])
        } catch {
            logError("project_finished_image_update_failed", metadata: [
                "projectId": projectId.uuidString,
                "error": "\(error)"
            ])
        }
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
