//
//  BeadInventoryApp.swift
//  BeadInventory
//
//  拼豆库存管理App
//

import SwiftUI
import SwiftData
import CloudKit
import CoreData
import Combine

@main
struct BeadInventoryApp: App {
    let modelContainer: ModelContainer

    @StateObject private var inventoryManager: InventoryManager
    @StateObject private var sharedImageManager = SharedImageManager.shared
    @StateObject private var cloudSyncStatusManager: CloudSyncStatusManager

    @State private var themeManager = ThemeManager.shared

    /// 深链接触发扫描的标志
    @State private var shouldOpenScan = false
    @State private var hasSeenInitialActivePhase = false
    @State private var showingThemeRecoveryAlert = false
    /// 数据库初始化是否完全失败（用于向用户展示错误状态）
    @State private var modelContainerFatalError: String?
    /// init 中暂存的错误信息（用于传递到 @State）
    private let initialFatalErrorMessage: String?

    /// 监听应用生命周期
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppLogger.shared.info("App", "bootstrap_started")

        // 设置 SwiftData ModelContainer（使用版本化 Schema 支持数据迁移）
        let schema = Schema(versionedSchema: CurrentSchema.self)
        // 主动触发 bootValue 求值，确保设置页能用它判断"是否需要重启"。
        let userOptedOutOfCloudKit = CloudSyncPreferences.bootValue
        if userOptedOutOfCloudKit {
            AppLogger.shared.info("App", "cloud_sync_user_opted_out")
        }
        let cloudConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: userOptedOutOfCloudKit ? .none : .automatic
        )

        let localFallbackConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )

        let container: ModelContainer
        let isCloudSyncEnabled: Bool
        var fatalErrorMessage: String?
        do {
            container = try ModelContainer(
                for: schema,
                migrationPlan: BeadInventoryMigrationPlan.self,
                configurations: [cloudConfiguration]
            )
            isCloudSyncEnabled = !userOptedOutOfCloudKit
            if userOptedOutOfCloudKit {
                print("[App] ✅ 用户已选择关闭 iCloud 同步，使用本地存储")
                AppLogger.shared.info(
                    "App",
                    "model_container_initialized",
                    metadata: [
                        "cloudKit": "user_opted_out",
                        "userOptedOut": true
                    ]
                )
            } else {
                print("[App] ✅ iCloud 同步容器初始化成功")
                AppLogger.shared.info(
                    "App",
                    "model_container_initialized",
                    metadata: [
                        "cloudKit": "automatic",
                        "userOptedOut": false
                    ]
                )
            }
        } catch {
            let nsError = error as NSError
            print("[App] ⚠️ iCloud 同步容器初始化失败，回退本地存储: \(error)")
            print("[App]   - domain: \(nsError.domain), code: \(nsError.code)")
            // userOptedOut=false 时这里才是"被动 fallback"；userOptedOut=true 路径
            // 上面已成功，不会进到这里。带上 metadata 让监控能区分两种本地模式来源。
            AppLogger.shared.warning(
                "App",
                "model_container_fallback_to_local",
                metadata: [
                    "domain": nsError.domain,
                    "code": nsError.code,
                    "userOptedOut": userOptedOutOfCloudKit
                ]
            )
            if !nsError.userInfo.isEmpty {
                print("[App]   - userInfo: \(nsError.userInfo)")
            }
            do {
                container = try ModelContainer(
                    for: schema,
                    migrationPlan: BeadInventoryMigrationPlan.self,
                    configurations: [localFallbackConfiguration]
                )
                isCloudSyncEnabled = false
                print("[App] ✅ 已回退为本地存储模式，确保旧数据可用")
                AppLogger.shared.info("App", "model_container_local_mode_enabled")
            } catch {
                // 最后兜底：尝试删除损坏的数据库文件并重新创建空容器
                let localFallbackError = error
                AppLogger.shared.error("App", "model_container_creation_failed_trying_reset", metadata: ["error": "\(localFallbackError)"])
                print("[App] ❌ 本地容器也失败，尝试重建数据库: \(localFallbackError)")
                do {
                    // 删除可能损坏的 SwiftData 存储文件
                    if let storeURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                        let defaultStoreURL = storeURL.appendingPathComponent("default.store")
                        for suffix in ["", "-wal", "-shm"] {
                            let fileURL = URL(fileURLWithPath: defaultStoreURL.path + suffix)
                            do {
                                try FileManager.default.removeItem(at: fileURL)
                            } catch let removeError as NSError where removeError.domain == NSCocoaErrorDomain && removeError.code == NSFileNoSuchFileError {
                                // 文件不存在，无需处理
                            } catch {
                                AppLogger.shared.warning("App", "db_file_removal_failed", metadata: [
                                    "file": fileURL.lastPathComponent,
                                    "error": "\(error)"
                                ])
                            }
                        }
                    }
                    container = try ModelContainer(
                        for: schema,
                        migrationPlan: BeadInventoryMigrationPlan.self,
                        configurations: [localFallbackConfiguration]
                    )
                    isCloudSyncEnabled = false
                    fatalErrorMessage = String(localized: "数据库已损坏并被重置，历史数据可能丢失。")
                    AppLogger.shared.warning("App", "model_container_reset_succeeded")
                } catch {
                    // 最终兜底：使用内存存储，确保 app 至少能打开
                    AppLogger.shared.error("App", "fatal_model_container_using_memory", metadata: ["error": "\(error)"])
                    print("[App] ❌ 重建数据库也失败，使用内存模式: \(error)")
                    do {
                        let memoryConfig = ModelConfiguration(
                            schema: schema,
                            isStoredInMemoryOnly: true,
                            cloudKitDatabase: .none
                        )
                        container = try ModelContainer(for: schema, configurations: [memoryConfig])
                    } catch {
                        AppLogger.shared.error("App", "fatal_memory_container_also_failed", metadata: ["error": "\(error)"])
                        fatalError("无法创建任何 ModelContainer（含内存模式）: \(error)")
                    }
                    isCloudSyncEnabled = false
                    fatalErrorMessage = String(localized: "数据库初始化失败，当前为临时模式，数据不会被保存。请尝试重启应用或重新安装。")
                }
            }
        }

        self.modelContainer = container
        #if DEBUG
        // 清理统一走 WhiteScreenReproSeeder 的分批版本：两者共用 "ChaosSeed-" 前缀，
        // 但原来那版是一次性 delete 全部再 save —— 拼图模式种子每条带 ~10MB 原图，
        // 200 条一个事务会把 2GB 挂在 context 里，清理本身就先 OOM 了。
        WhiteScreenReproSeeder.runIfRequested(container: container, cloudKitEnabled: isCloudSyncEnabled)
        BeadInventoryApp.seedChaosStressDataIfRequested(container: container)
        #endif
        // 创建 InventoryManager 并传入 ModelContext
        let manager = InventoryManager(modelContext: container.mainContext)
        self._inventoryManager = StateObject(wrappedValue: manager)
        self._cloudSyncStatusManager = StateObject(
            wrappedValue: CloudSyncStatusManager(
                mode: isCloudSyncEnabled ? .iCloudEnabled : .localFallback
            )
        )

        // 初始化 HistoryManager
        HistoryManager.shared.setModelContext(container.mainContext)
        HistoryManager.shared.inventoryManager = manager
        AppLogger.shared.info("App", "history_context_set")  // 启动耗时探针：HistoryManager 上下文就绪（取数已转后台，不再阻塞此处）

        self.initialFatalErrorMessage = fatalErrorMessage

        AppLogger.shared.info("App", "app_init_completed")  // 启动耗时探针：App.init 同步段结束（首帧前）
    }

    var body: some Scene {
        WindowGroup {
            ContentView(shouldOpenScan: $shouldOpenScan)
                .environmentObject(inventoryManager)
                .environmentObject(sharedImageManager)
                .environmentObject(cloudSyncStatusManager)
                .environment(themeManager)
                .task {
                    let ctx = ModelContext(modelContainer)
                    do {
                        try themeManager.bootstrapBuiltinPresets(modelContext: ctx)
                    } catch {
                        AppLogger.shared.error("Theme", "bootstrap_builtin_failed", metadata: ["error": "\(error)"])
                    }
                    themeManager.loadOverridesFromDefaults()
                    themeManager.loadPendingDraftFromDefaults()
                    if themeManager.isDirty {
                        showingThemeRecoveryAlert = true
                    }
                }
                .alert("color_mode.dialog.recover_title", isPresented: $showingThemeRecoveryAlert) {
                    Button("color_mode.dialog.recover_keep") { /* keep draft state in memory */ }
                    Button("color_mode.dialog.recover_discard", role: .destructive) {
                        themeManager.discardDraft()
                    }
                } message: {
                    Text("color_mode.dialog.recover_message")
                }
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
                .onAppear {
                    // 如果数据库初始化有异常，延迟弹出提示
                    if let msg = initialFatalErrorMessage {
                        modelContainerFatalError = msg
                    }

                    inventoryManager.performInitialLoadIfNeeded(reason: "rootView.onAppear")
                    AppLogger.shared.info("App", "root_view_appeared")
                    // App 启动时检查是否有待处理的共享图片
                    sharedImageManager.checkForPendingImage()

                    // 检查并执行每周自动备份
                    BackupManager.shared.checkAndPerformWeeklyBackupIfNeeded(inventoryManager: inventoryManager)
                    // 启动时检查 iCloud 状态
                    cloudSyncStatusManager.refreshAccountStatus()

                    // 静默检查远程公告
                    AnnouncementManager.shared.checkForAnnouncement()

                    // 一次性迁移：本地模型识别下线后的善后（告知 + 清理残留模型文件）
                    LocalModelRemovalMigrator.shared.runIfNeeded()
                }
                .alert(
                    String(localized: "数据库异常"),
                    isPresented: Binding(
                        get: { modelContainerFatalError != nil },
                        set: { if !$0 { modelContainerFatalError = nil } }
                    )
                ) {
                    Button(String(localized: "我知道了")) {
                        modelContainerFatalError = nil
                    }
                } message: {
                    Text(modelContainerFatalError ?? "")
                }
                .onReceive(
                    NotificationCenter.default
                        .publisher(for: .NSPersistentStoreRemoteChange)
                        .receive(on: RunLoop.main)
                ) { _ in
                    // 仅在前台时处理远程变更，后台/非活跃阶段统一在恢复活跃时刷新
                    guard scenePhase == .active else {
                        AppLogger.shared.debug(
                            "CloudSync",
                            "remote_change_ignored",
                            metadata: ["scenePhase": "\(scenePhase)"]
                        )
                        return
                    }
                    inventoryManager.recordCloudKitRemoteChange()
                }
                .onChange(of: inventoryManager.hasCompletedInitialLoad) { _, completed in
                    // 图片瘦身是空闲工作。首次项目快照已经提交、且用户当前仍在前台时
                    // 才启动，避免它与冷启动读库/CloudKit 导入争用同一个 SQLite store。
                    guard completed, scenePhase == .active, !inventoryManager.isUsingLocalFallbackMode else { return }
                    ThumbnailMigrationCoordinator.shared.start(inventoryManager: inventoryManager)
                }
        }
        .modelContainer(modelContainer)
        .onChange(of: scenePhase) { _, newPhase in
            AppLogger.shared.info("AppLifecycle", "scene_phase_changed", metadata: ["phase": "\(newPhase)"])
            switch newPhase {
            case .background:
                // 应用进入后台时立即保存数据，防止被系统杀死后数据丢失
                inventoryManager.cancelScheduledRefresh(reason: "scenePhase.background")
                print("[App] 应用进入后台，保存数据...")
                inventoryManager.saveData()
                HistoryManager.shared.saveDataImmediately()
                themeManager.flushPersistenceNow()
                // 停掉 displayThumbnail 后台迁移协调器 —— 释放 CPU + 让 saveData 在干净 store 上完成。
                // 协调器内部用 generation token 保证下次 .active start() 不会跟旧 task 抢资源。
                // 注：协调器的 SwiftData I/O 全部在后台 ModelContext（build 180 watchdog 修复），
                // 即使 stop() 时仍有一次 fetch/save 在飞行中，也不占主线程、不影响 5s suspend 应答。
                ThumbnailMigrationCoordinator.shared.stop()
            case .inactive:
                // .inactive 频繁出现（例如控制中心、系统弹窗），先取消待执行刷新；
                // 若首次加载已完成，则补一次保守保存，降低系统在 .inactive 直接终止时的数据丢失风险。
                print("[App] 应用进入非活跃状态")
                inventoryManager.cancelScheduledRefresh(reason: "scenePhase.inactive")
                if inventoryManager.hasCompletedInitialLoad {
                    inventoryManager.saveData()
                    HistoryManager.shared.saveDataImmediately()
                }
                themeManager.flushPersistenceNow()
                ThumbnailMigrationCoordinator.shared.stop()
            case .active:
                print("[App] 应用恢复活跃状态")
                if hasSeenInitialActivePhase {
                    // 前台恢复与远程通知共用同一防抖刷新队列，避免短时间重复全量加载
                    inventoryManager.scheduleRefreshFromPersistentStore(
                        reason: "scenePhase.active",
                        debounceSeconds: 0.25
                    )
                } else {
                    hasSeenInitialActivePhase = true
                    let hadCompletedInitialLoadBeforeActive = inventoryManager.hasCompletedInitialLoad
                    inventoryManager.performInitialLoadIfNeeded(reason: "scenePhase.active.initial")
                    if !hadCompletedInitialLoadBeforeActive && inventoryManager.hasCompletedInitialLoad {
                        inventoryManager.scheduleRefreshFromPersistentStore(
                            reason: "scenePhase.active.initialCatchUp",
                            debounceSeconds: 0.25
                        )
                    }
                }
                cloudSyncStatusManager.refreshAccountStatus()
                // 历史记录若在启动时加载失败（isDataLoaded 仍 false），前台恢复时补一次重试 ——
                // 否则失败后整 session 历史只在内存、saveDataImmediately 也被守卫跳过、退出即丢。
                HistoryManager.shared.reloadIfNeeded()
                // 已完成首次加载的前台恢复可继续后台缩略图迁移；首次启动则由上面的
                // `hasCompletedInitialLoad` 观察器在数据提交后再开始，避免争抢首轮读库。
                if inventoryManager.hasCompletedInitialLoad, !inventoryManager.isUsingLocalFallbackMode {
                    ThumbnailMigrationCoordinator.shared.start(inventoryManager: inventoryManager)
                }
            @unknown default:
                break
            }
        }
    }

    /// 处理传入的 URL Scheme
    private func handleIncomingURL(_ url: URL) {
        // 处理 beadinventory://scan
        if url.scheme == "beadinventory" && url.host == "scan" {
            AppLogger.shared.info("DeepLink", "open_scan", metadata: ["url": url.absoluteString])
            // 检查共享图片
            sharedImageManager.checkForPendingImage()
            // 触发跳转到扫描页
            shouldOpenScan = true
        }
    }
}

/// 用户级 iCloud 同步偏好。
///
/// `userOptedOut == true` 时，`BeadInventoryApp.init()` 会用 `cloudKitDatabase: .none`
/// 创建 ModelContainer，App 仅使用本地 SQLite。CloudKit 上原有的数据**不会被删除**，
/// 用户后续在「更多 → 数据与同步」里关闭此开关并重启 App，会重新走 .automatic 路径，
/// SwiftData/CoreData 会按记录 ID 把云端数据拉下来与本地合并。
///
/// 注意：本地模式期间产生的本地写入与同期其它设备产生的云端写入若命中同一记录 ID，
/// 重新启用同步后由 CloudKit 按 last-writer-wins 解决，不存在自动三方合并。
///
/// 主要用于解决：iCloud 空间满 / 同步异常导致 App 长期卡在加载界面时，
/// 给用户一个明确的"只用本地"的逃生通道。
enum CloudSyncPreferences {
    private static let userOptedOutKey = "userOptedOutOfICloudSync"

    /// App 启动时读取的快照，用于设置页判断当前修改是否需要重启 App 才能生效。
    /// `BeadInventoryApp.init()` 会主动访问一次以确保它真的反映启动时刻的值。
    static let bootValue: Bool = UserDefaults.standard.bool(forKey: userOptedOutKey)

    static var userOptedOut: Bool {
        get { UserDefaults.standard.bool(forKey: userOptedOutKey) }
        set { UserDefaults.standard.set(newValue, forKey: userOptedOutKey) }
    }
}

/// iCloud 同步状态管理（仅用于 UI 状态展示）
@MainActor
class CloudSyncStatusManager: ObservableObject {
    enum Mode {
        case iCloudEnabled
        case localFallback
    }

    private struct CloudRecordTypes {
        let brands: [String]
        let stocks: [String]
        let projects: [String]
        let customColors: [String]

        static let `default` = CloudRecordTypes(
            brands: ["CD_SDBrand", "SDBrand"],
            stocks: ["CD_SDBrandStock", "SDBrandStock"],
            projects: ["CD_SDProjectRecord", "SDProjectRecord"],
            customColors: ["CD_SDCustomColor", "SDCustomColor"]
        )
    }

    private struct CloudDataCounts {
        let brands: Int?
        let stocks: Int?
        let projects: Int?
        let plannedProjects: Int?
        let customColors: Int?
    }

    private enum CloudDataQueryError: Error {
        case invalidRecordType(String)
    }

    @Published private(set) var mode: Mode
    @Published private(set) var accountStatus: CKAccountStatus?
    @Published private(set) var isCheckingAccount = false
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var isCheckingCloudData = false
    @Published private(set) var cloudDataSummaryText: String?
    @Published private(set) var cloudDataCheckedAt: Date?
    @Published private(set) var cloudDataErrorMessage: String?

    // 注意：不要在这里用 `let container = CKContainer(...)` 直接持有容器。
    // 首次 `CKContainer(identifier:)` 会与 cloudd 守护进程做一次同步握手；
    // CloudSyncStatusManager 是在 BeadInventoryApp.init() 的主线程上创建的，
    // 冷启动（cloudd 连接尚未预热）时该握手会阻塞主线程数秒，导致首帧迟迟不出 → 长时间白屏
    // （实测一次冷启动卡了约 8.5s）。改为按需在后台队列创建，确保启动路径零阻塞。
    private let containerIdentifier = "iCloud.com.beadinventory.app"
    private let cloudKitQueue = DispatchQueue(label: "com.beadinventory.cloudsync", qos: .utility)
    private var lastRefreshRequestedAt: Date?
    private var lastCloudDataRequestedAt: Date?
    private let cloudDataRefreshInterval: TimeInterval = 60
    private let cloudRecordTypes = CloudRecordTypes.default
    private let plannedProjectFieldCandidates = ["CD_isPlanned", "isPlanned"]
    private let cloudQueryZoneIDs: [CKRecordZone.ID] = [
        CKRecordZone.ID(zoneName: "com.apple.coredata.cloudkit.zone", ownerName: CKCurrentUserDefaultName),
        CKRecordZone.default().zoneID
    ]

    init(mode: Mode) {
        self.mode = mode
        AppLogger.shared.info("CloudSync", "status_manager_initialized", metadata: ["mode": "\(mode)"])
    }

    var statusIconName: String {
        switch mode {
        case .localFallback:
            return "internaldrive.fill"
        case .iCloudEnabled:
            if isCheckingAccount {
                return "icloud"
            }
            switch accountStatus {
            case .available:
                return "checkmark.icloud.fill"
            case .noAccount, .restricted, .temporarilyUnavailable:
                return "exclamationmark.icloud.fill"
            case .couldNotDetermine, .none:
                return "icloud.slash.fill"
            @unknown default:
                return "icloud.slash.fill"
            }
        }
    }

    var statusColor: Color {
        switch mode {
        case .localFallback:
            return .orange
        case .iCloudEnabled:
            switch accountStatus {
            case .available:
                return .green
            case .noAccount, .restricted, .temporarilyUnavailable:
                return .orange
            case .couldNotDetermine, .none:
                return .secondary
            @unknown default:
                return .secondary
            }
        }
    }

    var primaryStatusText: String {
        switch mode {
        case .localFallback:
            return String(localized: "当前为本地存储模式")
        case .iCloudEnabled:
            if isCheckingAccount && accountStatus == nil {
                return String(localized: "正在检查 iCloud 状态...")
            }
            switch accountStatus {
            case .available:
                return String(localized: "iCloud 同步已启用")
            case .noAccount:
                return String(localized: "未登录 iCloud 账号")
            case .restricted:
                return String(localized: "iCloud 权限受限")
            case .temporarilyUnavailable:
                return String(localized: "iCloud 暂时不可用")
            case .couldNotDetermine, .none:
                return String(localized: "iCloud 状态暂时未知")
            @unknown default:
                return String(localized: "iCloud 状态暂时未知")
            }
        }
    }

    var secondaryStatusText: String {
        switch mode {
        case .localFallback:
            return String(localized: "应用已自动回退到本地存储，现有数据可继续正常使用。")
        case .iCloudEnabled:
            if let lastErrorMessage {
                return String(localized: "状态检查失败：\(lastErrorMessage)")
            }
            switch accountStatus {
            case .available:
                return String(localized: "已连接 iCloud，可在多设备间同步数据。")
            case .noAccount:
                return String(localized: "当前设备未登录 iCloud，无法进行云同步。")
            case .restricted:
                return String(localized: "当前设备或账号限制了 iCloud 使用。")
            case .temporarilyUnavailable:
                return String(localized: "iCloud 服务暂时不可用，请稍后再试。")
            case .couldNotDetermine, .none:
                return String(localized: "暂时无法确认账号状态，请稍后点击刷新。")
            @unknown default:
                return String(localized: "暂时无法确认账号状态，请稍后点击刷新。")
            }
        }
    }

    var shouldAllowManualRefresh: Bool {
        mode == .iCloudEnabled
    }

    /// 云端统计已下线，仅保留账号状态展示。
    private func clearCloudDataStatus() {
        isCheckingCloudData = false
        cloudDataSummaryText = nil
        cloudDataCheckedAt = nil
        cloudDataErrorMessage = nil
    }

    func refreshAccountStatus(force: Bool = false) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.refreshAccountStatus(force: force)
            }
            return
        }

        guard mode == .iCloudEnabled else {
            AppLogger.shared.debug("CloudSync", "refresh_skipped_local_mode")
            clearCloudDataStatus()
            return
        }
        clearCloudDataStatus()

        guard !isCheckingAccount else {
            AppLogger.shared.debug("CloudSync", "refresh_skipped_already_checking")
            return
        }

        if !force,
           let lastRefreshRequestedAt,
           Date().timeIntervalSince(lastRefreshRequestedAt) < 5 {
            AppLogger.shared.debug("CloudSync", "refresh_skipped_rate_limited")
            return
        }

        isCheckingAccount = true
        lastErrorMessage = nil
        lastRefreshRequestedAt = Date()
        AppLogger.shared.info("CloudSync", "account_status_check_started", metadata: ["force": force])

        // 在后台队列创建 CKContainer 并发起查询，避免首次 cloudd 握手阻塞主线程。
        let identifier = containerIdentifier
        cloudKitQueue.async { [weak self] in
            let container = CKContainer(identifier: identifier)
            container.accountStatus { status, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isCheckingAccount = false
                    self.lastCheckedAt = Date()

                    if let error {
                        self.accountStatus = .couldNotDetermine
                        self.lastErrorMessage = error.localizedDescription
                        AppLogger.shared.warning(
                            "CloudSync",
                            "account_status_check_failed",
                            metadata: ["error": error.localizedDescription]
                        )
                        self.clearCloudDataStatus()
                        return
                    }

                    self.accountStatus = status
                    AppLogger.shared.info("CloudSync", "account_status_updated", metadata: ["status": "\(status.rawValue)"])
                    self.clearCloudDataStatus()
                }
            }
        }
    }

    private func refreshCloudDataSummary(force: Bool) {
        guard mode == .iCloudEnabled else { return }
        guard accountStatus == .available else { return }
        guard !isCheckingCloudData else {
            AppLogger.shared.debug("CloudSync", "cloud_data_refresh_skipped_already_checking")
            return
        }

        if !force,
           let lastCloudDataRequestedAt,
           Date().timeIntervalSince(lastCloudDataRequestedAt) < cloudDataRefreshInterval {
            AppLogger.shared.debug("CloudSync", "cloud_data_refresh_skipped_rate_limited")
            return
        }

        isCheckingCloudData = true
        cloudDataErrorMessage = nil
        lastCloudDataRequestedAt = Date()

        let identifier = containerIdentifier
        let recordTypes = cloudRecordTypes
        let plannedFields = plannedProjectFieldCandidates
        let preferredZoneIDs = cloudQueryZoneIDs

        AppLogger.shared.info("CloudSync", "cloud_data_refresh_started", metadata: ["force": force])

        Task.detached(priority: .utility) {
            do {
                // CKContainer 在后台任务里按需创建，避免主线程 cloudd 握手开销。
                let database = CKContainer(identifier: identifier).privateCloudDatabase
                let resolvedZoneIDs = await Self.resolveCloudQueryZoneIDs(
                    database: database,
                    preferredZoneIDs: preferredZoneIDs
                )
                let counts = try await Self.fetchCloudDataCounts(
                    database: database,
                    zoneIDs: resolvedZoneIDs,
                    recordTypes: recordTypes,
                    plannedFieldCandidates: plannedFields
                )

                await MainActor.run {
                    self.isCheckingCloudData = false
                    self.cloudDataSummaryText = Self.makeCloudDataSummaryText(counts)
                    self.cloudDataCheckedAt = Date()
                    self.cloudDataErrorMessage = nil
                    AppLogger.shared.info(
                        "CloudSync",
                        "cloud_data_refresh_succeeded",
                        metadata: [
                            "brands": counts.brands ?? -1,
                            "stocks": counts.stocks ?? -1,
                            "projects": counts.projects ?? -1,
                            "plannedProjects": counts.plannedProjects ?? -1,
                            "customColors": counts.customColors ?? -1,
                            "zoneCount": resolvedZoneIDs.count
                        ]
                    )
                }
            } catch {
                await MainActor.run {
                    self.isCheckingCloudData = false
                    self.cloudDataErrorMessage = Self.makeCloudDataErrorMessage(error)
                    self.cloudDataCheckedAt = Date()
                    AppLogger.shared.warning(
                        "CloudSync",
                        "cloud_data_refresh_failed",
                        metadata: Self.cloudErrorMetadata(error)
                    )
                }
            }
        }
    }

    nonisolated private static func makeCloudDataSummaryText(_ counts: CloudDataCounts) -> String {
        let brandText = formatCloudCount(counts.brands)
        let stockText = formatCloudCount(counts.stocks)
        let projectText = formatCloudCount(counts.projects)
        let plannedText = formatCloudCount(counts.plannedProjects)
        let customColorText = formatCloudCount(counts.customColors)
        return String(localized: "云端：品牌 \(brandText) · 库存 \(stockText) · 项目 \(projectText) · 计划 \(plannedText) · 自定义 \(customColorText)")
    }

    nonisolated private static func formatCloudCount(_ value: Int?) -> String {
        guard let value else { return String(localized: "未知") }
        return "\(value)"
    }

    nonisolated private static func makeCloudDataErrorMessage(_ error: Error) -> String {
        if let queryError = error as? CloudDataQueryError {
            switch queryError {
            case .invalidRecordType:
                return String(localized: "云端统计配置错误")
            }
        }

        guard let ckError = error as? CKError else {
            return String(localized: "请稍后重试")
        }

        if isQueryCapabilityLimitationError(ckError) {
            return String(localized: "云端架构暂不支持该统计")
        }

        switch ckError.code {
        case .networkUnavailable, .networkFailure:
            return String(localized: "网络不可用")
        case .notAuthenticated:
            return String(localized: "未登录 iCloud")
        case .requestRateLimited, .serviceUnavailable:
            return String(localized: "请求过于频繁，请稍后重试")
        case .zoneNotFound:
            return String(localized: "云端分区未就绪")
        default:
            return String(localized: "请稍后重试")
        }
    }

    nonisolated private static func cloudErrorMetadata(_ error: Error) -> [String: Any] {
        if let queryError = error as? CloudDataQueryError {
            switch queryError {
            case .invalidRecordType(let recordType):
                return [
                    "error": "invalid_record_type",
                    "recordType": recordType
                ]
            }
        }

        guard let ckError = error as? CKError else {
            return ["error": error.localizedDescription]
        }
        return [
            "error": ckError.localizedDescription,
            "code": ckError.code.rawValue
        ]
    }

    nonisolated private static func fetchCloudDataCounts(
        database: CKDatabase,
        zoneIDs: [CKRecordZone.ID],
        recordTypes: CloudRecordTypes,
        plannedFieldCandidates: [String]
    ) async throws -> CloudDataCounts {
        let brandCount = try await countForRecordTypeCandidates(
            recordTypes.brands,
            database: database,
            zoneIDs: zoneIDs
        )
        let stockCount = try await countForRecordTypeCandidates(
            recordTypes.stocks,
            database: database,
            zoneIDs: zoneIDs
        )
        let customColorCount = try await countForRecordTypeCandidates(
            recordTypes.customColors,
            database: database,
            zoneIDs: zoneIDs
        )

        let projectRecordType = try await resolveRecordTypeIfPossible(
            recordTypes.projects,
            database: database,
            zoneIDs: zoneIDs
        )

        let projectCount: Int?
        let plannedProjectCount: Int?
        if let projectRecordType {
            do {
                projectCount = try await countRecordsAcrossKnownZones(
                    recordType: projectRecordType,
                    database: database,
                    zoneIDs: zoneIDs
                )
            } catch let ckError as CKError where isQueryCapabilityLimitationError(ckError) {
                projectCount = nil
            }

            do {
                plannedProjectCount = try await countPlannedProjectsAcrossKnownZones(
                    recordType: projectRecordType,
                    database: database,
                    zoneIDs: zoneIDs,
                    fieldCandidates: plannedFieldCandidates
                )
            } catch let ckError as CKError where isQueryCapabilityLimitationError(ckError) {
                plannedProjectCount = nil
            }
        } else {
            projectCount = nil
            plannedProjectCount = nil
        }

        return CloudDataCounts(
            brands: brandCount,
            stocks: stockCount,
            projects: projectCount,
            plannedProjects: plannedProjectCount,
            customColors: customColorCount
        )
    }

    nonisolated private static func countForRecordTypeCandidates(
        _ candidates: [String],
        database: CKDatabase,
        zoneIDs: [CKRecordZone.ID]
    ) async throws -> Int? {
        do {
            guard let recordType = try await resolveRecordTypeIfPossible(
                candidates,
                database: database,
                zoneIDs: zoneIDs
            ) else {
                return nil
            }

            return try await countRecordsAcrossKnownZones(
                recordType: recordType,
                database: database,
                zoneIDs: zoneIDs
            )
        } catch let ckError as CKError where isQueryCapabilityLimitationError(ckError) {
            return nil
        }
    }

    nonisolated private static func resolveRecordTypeIfPossible(
        _ candidates: [String],
        database: CKDatabase,
        zoneIDs: [CKRecordZone.ID]
    ) async throws -> String? {
        for candidate in candidates {
            guard isValidRecordTypeName(candidate) else {
                continue
            }
            do {
                _ = try await countRecordsAcrossKnownZones(
                    recordType: candidate,
                    database: database,
                    zoneIDs: zoneIDs,
                    predicate: NSPredicate(value: true),
                    resultsLimit: 1
                )
                return candidate
            } catch let ckError as CKError where isUnsupportedRecordTypeError(ckError) {
                continue
            } catch let ckError as CKError where isQueryCapabilityLimitationError(ckError) {
                continue
            }
        }
        return nil
    }

    nonisolated private static func countPlannedProjectsAcrossKnownZones(
        recordType: String,
        database: CKDatabase,
        zoneIDs: [CKRecordZone.ID],
        fieldCandidates: [String]
    ) async throws -> Int? {
        for field in fieldCandidates {
            do {
                return try await countRecordsAcrossKnownZones(
                    recordType: recordType,
                    database: database,
                    zoneIDs: zoneIDs,
                    predicate: NSPredicate(format: "%K == %@", field, NSNumber(value: true))
                )
            } catch let ckError as CKError where isInvalidFieldError(ckError, fieldName: field) {
                continue
            }
        }
        return nil
    }

    nonisolated private static func countRecordsAcrossKnownZones(
        recordType: String,
        database: CKDatabase,
        zoneIDs: [CKRecordZone.ID],
        predicate: NSPredicate = NSPredicate(value: true),
        resultsLimit: Int = 200
    ) async throws -> Int {
        var total = 0
        var hasSuccessfulZone = false

        for zoneID in zoneIDs {
            do {
                let zoneCount = try await countRecords(
                    recordType: recordType,
                    database: database,
                    zoneID: zoneID,
                    predicate: predicate,
                    resultsLimit: resultsLimit
                )
                hasSuccessfulZone = true
                total += zoneCount
            } catch let ckError as CKError {
                if shouldIgnoreZoneError(ckError) {
                    continue
                }
                throw ckError
            }
        }

        if hasSuccessfulZone {
            return total
        }

        // 兜底：不指定 zone 查询，兼容某些环境只支持默认行为
        return try await countRecords(
            recordType: recordType,
            database: database,
            zoneID: nil,
            predicate: predicate,
            resultsLimit: resultsLimit
        )
    }

    nonisolated private static func countRecords(
        recordType: String,
        database: CKDatabase,
        zoneID: CKRecordZone.ID?,
        predicate: NSPredicate,
        resultsLimit: Int
    ) async throws -> Int {
        guard isValidRecordTypeName(recordType) else {
            throw CloudDataQueryError.invalidRecordType(recordType)
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            var total = 0
            let lock = NSLock()

            func enqueueOperation(cursor: CKQueryOperation.Cursor?) {
                let operation: CKQueryOperation
                if let cursor {
                    operation = CKQueryOperation(cursor: cursor)
                } else {
                    let query = CKQuery(recordType: recordType, predicate: predicate)
                    operation = CKQueryOperation(query: query)
                    operation.zoneID = zoneID
                }

                operation.resultsLimit = resultsLimit
                operation.desiredKeys = []
                operation.recordMatchedBlock = { _, result in
                    if case .success = result {
                        lock.lock()
                        total += 1
                        lock.unlock()
                    }
                }

                operation.queryResultBlock = { result in
                    switch result {
                    case .success(let nextCursor):
                        if let nextCursor {
                            enqueueOperation(cursor: nextCursor)
                        } else {
                            lock.lock()
                            let finalCount = total
                            lock.unlock()
                            continuation.resume(returning: finalCount)
                        }
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }

                database.add(operation)
            }

            enqueueOperation(cursor: nil)
        }
    }

    nonisolated private static func isValidRecordTypeName(_ recordType: String) -> Bool {
        guard let first = recordType.unicodeScalars.first else {
            return false
        }

        let asciiLetters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_")

        guard asciiLetters.contains(first) else {
            return false
        }

        return recordType.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    nonisolated private static func isUnsupportedRecordTypeError(_ error: CKError) -> Bool {
        let partialErrors = partialCKErrors(from: error)
        if !partialErrors.isEmpty {
            return partialErrors.contains { isUnsupportedRecordTypeError($0) }
        }

        if error.code == .unknownItem {
            return true
        }

        if error.code == .invalidArguments {
            let description = error.localizedDescription.lowercased()
            if description.contains("record type"),
               (description.contains("unknown") || description.contains("invalid") || description.contains("not found")) {
                return true
            }
        }

        if error.code == .serverRejectedRequest {
            let description = error.localizedDescription.lowercased()
            if description.contains("record type"),
               (description.contains("unknown") || description.contains("invalid") || description.contains("not found")) {
                return true
            }
        }

        return false
    }

    nonisolated private static func isQueryCapabilityLimitationError(_ error: CKError) -> Bool {
        let partialErrors = partialCKErrors(from: error)
        if !partialErrors.isEmpty {
            return partialErrors.contains { isQueryCapabilityLimitationError($0) }
        }

        let description = error.localizedDescription.lowercased()
        if error.code == .invalidArguments || error.code == .serverRejectedRequest || error.code == .partialFailure {
            if description.contains("queryable")
                || description.contains("indexed")
                || description.contains("index")
                || description.contains("predicate")
                || description.contains("keypath")
                || description.contains("recordname")
                || description.contains("field") {
                return true
            }
        }
        return false
    }

    nonisolated private static func shouldIgnoreZoneError(_ error: CKError) -> Bool {
        let partialErrors = partialCKErrors(from: error)
        if !partialErrors.isEmpty {
            return partialErrors.allSatisfy { partialError in
                shouldIgnoreZoneError(partialError) || isQueryCapabilityLimitationError(partialError)
            }
        }

        switch error.code {
        case .zoneNotFound, .userDeletedZone, .unknownItem, .invalidArguments:
            return true
        default:
            return false
        }
    }

    nonisolated private static func isInvalidFieldError(_ error: CKError, fieldName: String) -> Bool {
        let partialErrors = partialCKErrors(from: error)
        if !partialErrors.isEmpty {
            return partialErrors.contains { isInvalidFieldError($0, fieldName: fieldName) }
        }

        if error.code == .invalidArguments || error.code == .serverRejectedRequest || error.code == .partialFailure {
            let description = error.localizedDescription.lowercased()
            if description.contains("field")
                || description.contains(fieldName.lowercased())
                || description.contains("keypath")
                || description.contains("recordname")
                || description.contains("predicate") {
                return true
            }
        }

        return false
    }

    nonisolated private static func partialCKErrors(from error: CKError) -> [CKError] {
        guard error.code == .partialFailure,
              let errorsByItem = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] else {
            return []
        }

        return errorsByItem.values.compactMap { $0 as? CKError }
    }

    nonisolated private static func resolveCloudQueryZoneIDs(
        database: CKDatabase,
        preferredZoneIDs: [CKRecordZone.ID]
    ) async -> [CKRecordZone.ID] {
        do {
            let fetchedZoneIDs = try await fetchAllZoneIDs(database: database)
            let merged = uniqueZoneIDs(fetchedZoneIDs + preferredZoneIDs)
            if merged.isEmpty {
                return preferredZoneIDs
            }
            return merged
        } catch {
            return preferredZoneIDs
        }
    }

    nonisolated private static func fetchAllZoneIDs(database: CKDatabase) async throws -> [CKRecordZone.ID] {
        try await withCheckedThrowingContinuation { continuation in
            var zoneIDs: [CKRecordZone.ID] = []
            let operation = CKFetchRecordZonesOperation.fetchAllRecordZonesOperation()
            operation.perRecordZoneResultBlock = { zoneID, result in
                if case .success = result {
                    zoneIDs.append(zoneID)
                }
            }
            operation.fetchRecordZonesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: zoneIDs)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    nonisolated private static func uniqueZoneIDs(_ zoneIDs: [CKRecordZone.ID]) -> [CKRecordZone.ID] {
        var seen: Set<String> = []
        var ordered: [CKRecordZone.ID] = []
        for zoneID in zoneIDs {
            let key = "\(zoneID.ownerName)|\(zoneID.zoneName)"
            guard seen.insert(key).inserted else { continue }
            ordered.append(zoneID)
        }
        return ordered
    }
}

#if DEBUG
// MARK: - Chaos 压测灌数据（DEBUG-only，仅在启动参数带 -StressSeedThumbnails 时触发）
//
// Release / TestFlight 构建整个 extension 不参与编译；不带该参数的日常调试启动
// 行为完全不变。用于真机模拟器对抗测试 ThumbnailMigrationCoordinator 的修复
//（build 180 watchdog 崩溃，详见 ThumbnailMigrationCoordinator.swift 顶部注释）——
// 灌大量待迁移的大 blob 项目，配合外部脚本高频切后台/杀进程，观察真实 App 进程
// 会不会崩，而不只是 XCTest 里量化主线程停摆。
//
// 用法：
//   xcrun simctl launch <udid> com.beadinventory.app \
//     -StressSeedThumbnails -StressSeedCount 300
//
// 清理（把上面灌的 ChaosSeed-* 项目连同 CloudKit 同步痕迹一起删掉）：
//   xcrun simctl launch <udid> com.beadinventory.app -StressSeedCleanup
// 走正常的 ModelContext.delete + save（不是绕过 Core Data 直接改 sqlite），
// 保证 CloudKit 镜像能正确把删除操作同步传播出去。
extension BeadInventoryApp {
    static func cleanupChaosStressDataIfRequested(container: ModelContainer) {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-StressSeedCleanup") else { return }

        let ctx = ModelContext(container)
        var descriptor = FetchDescriptor<SDProjectRecord>(
            predicate: #Predicate { $0.name.starts(with: "ChaosSeed-") }
        )
        // 只投影 id 列——delete 不需要物化 thumbnail/displayThumbnail 这些 blob，
        // 几百条 × ~1.6MB 裸 fetch 会在主线程一次性拉几百 MB 进内存，没必要。
        descriptor.propertiesToFetch = [\.id]
        do {
            let toDelete = try ctx.fetch(descriptor)
            AppLogger.shared.info("ChaosStress", "cleanup_started", metadata: ["count": toDelete.count])
            for record in toDelete {
                ctx.delete(record)
            }
            try ctx.save()
            AppLogger.shared.info("ChaosStress", "cleanup_completed", metadata: ["count": toDelete.count])
        } catch {
            AppLogger.shared.error("ChaosStress", "cleanup_failed", metadata: ["error": "\(error)"])
        }
    }

    static func seedChaosStressDataIfRequested(container: ModelContainer) {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-StressSeedThumbnails") else { return }

        let count = chaosStressCountArgument(args) ?? 300
        AppLogger.shared.info("ChaosStress", "seed_started", metadata: ["count": count])

        let ctx = ModelContext(container)
        // 每条项目独立生成噪声图（而不是共用同一份字节）——对抗测试要覆盖"内容各不相同、
        // 无法被磁盘/文件系统层面偷懒去重"的真实场景。
        for i in 0..<count {
            let png = makeChaosNoisyPNG(width: 900, height: 600)
            let record = SDProjectRecord(
                name: "ChaosSeed-\(i)",
                totalBeads: 0,
                thumbnail: png,
                finishedImage: nil,
                displayThumbnail: nil,
                beadUsages: []
            )
            ctx.insert(record)
        }
        do {
            try ctx.save()
            AppLogger.shared.info("ChaosStress", "seed_completed", metadata: ["count": count])
        } catch {
            AppLogger.shared.error("ChaosStress", "seed_failed", metadata: ["error": "\(error)"])
        }
    }

    private static func chaosStressCountArgument(_ args: [String]) -> Int? {
        guard let idx = args.firstIndex(of: "-StressSeedCount"), idx + 1 < args.count else {
            return nil
        }
        return Int(args[idx + 1])
    }

    /// 逐像素随机字节 —— PNG 基本不可压缩，文件大小逼近原始像素数据，
    /// 模拟老项目"全分辨率照片直接存 blob"的真实体量（~1.6MB/张）。
    private static func makeChaosNoisyPNG(width: Int, height: Int) -> Data {
        var buffer = Data(count: width * height * 4)
        buffer.withUnsafeMutableBytes { raw in
            arc4random_buf(raw.baseAddress, raw.count)
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
        guard let provider = CGDataProvider(data: buffer as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ),
              let png = UIImage(cgImage: cgImage).pngData() else {
            return Data(count: 1_600_000)  // 极端兜底，不让种子生成本身崩测试
        }
        return png
    }
}
#endif

//
//  WhiteScreenReproSeeder.swift
//  BeadInventory
//
//  DEBUG-only：为「打开 App 长时间白屏」造可复现的数据集。
//
//  ## 为什么需要它
//
//  白屏已经修过三轮（#51 CKContainer/TipKit —— TipKit 已于 #66 整体移除、#52 history 开库、
//  #57 InventoryManager 首次
//  fetch），每轮都是「读代码找到一个主线程阻塞点 → 移走 → 宣布修好」，但用户仍然报障。
//  根本问题是**从来没有人真正复现过它** —— 所有结论都建立在「这段代码看起来会阻塞」上，
//  而不是「这就是白屏的原因」。这个文件的唯一目的就是把猜测换成可复现的现场。
//
//  ## 造什么数据
//
//  重点是**拼图模式**的数据形态，因为它是唯一会用到「全分辨率原图」的场景：
//  `SDProjectRecord.thumbnail` 存的是原图 PNG（字段名是历史遗留），单条可达 5–25MB，
//  而且这 4 个 blob 字段**是 inline BLOB 不是 externalStorage**（见 SwiftDataModels.swift
//  的长注释：SwiftData 不支持 inline→external 的自动迁移），也就是说它们**就躺在 SQLite
//  的数据行里**。任何不带 propertiesToFetch 的整表扫描都会把它们物化进内存。
//
//  每条种子记录带：
//   - `thumbnail`：全分辨率噪声 PNG（默认长边 2400px，约 8–12MB，对标真实手机拍的图纸）
//   - `patternGridData`：真实形态的 BeadPatternGrid（默认 100×100 = 1 万格色号矩阵）
//   - `displayThumbnail`：**一半留 nil** —— 这是「老数据」形态，会触发
//     ThumbnailMigrationCoordinator 的 backfill，也会让列表走现场降级路径
//   - 计划 / 已执行 混合，覆盖工作台和项目两条列表
//
//  ## 用法
//
//      xcrun simctl launch <udid> com.beadinventory.app \
//        -StressSeedPatternMode -StressSeedCount 200 -StressSeedImageLongEdge 2400
//
//  清理（按 name 前缀，走正常 ModelContext.delete + save，CloudKit 能正确传播删除）：
//
//      xcrun simctl launch <udid> com.beadinventory.app -StressSeedCleanup
//
//  ## CloudKit 安全闸
//
//  没关 iCloud 同步时容器是 `cloudKitDatabase: .automatic`，灌 200 × 10MB 等于往用户
//  iCloud 里推 ~2GB，可能撑爆配额、拖垮真实数据的同步、并让其它设备下载同样体量。
//  所以默认**拒绝**在 CloudKit 开启时灌数据，必须显式加 `-StressSeedAllowCloudKit` 放行。
//  模拟器通常没登录 iCloud，不受影响。
//

#if DEBUG
enum WhiteScreenReproSeeder {

    /// 种子记录统一前缀，cleanup 靠它识别。改名会导致旧种子清理不掉。
    static let namePrefix = "ChaosSeed-"

    // MARK: - 入口

    static func runIfRequested(container: ModelContainer, cloudKitEnabled: Bool) {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-StressSeedCleanup") {
            cleanup(container: container)
        }
        if args.contains("-StressSeedPatternMode") {
            seed(container: container, args: args, cloudKitEnabled: cloudKitEnabled)
        }
    }

    // MARK: - 灌数据

    private static func seed(container: ModelContainer, args: [String], cloudKitEnabled: Bool) {
        let count = intArgument(args, key: "-StressSeedCount") ?? 200
        let longEdge = intArgument(args, key: "-StressSeedImageLongEdge") ?? 2400

        if cloudKitEnabled && !args.contains("-StressSeedAllowCloudKit") {
            AppLogger.shared.error("ReproSeeder", "seed_refused_cloudkit_on", metadata: [
                "reason": "CloudKit 同步开启时灌大 blob 会把数 GB 图片推上 iCloud。"
                    + "确认要这么做请加 -StressSeedAllowCloudKit；或先在「更多 → 数据与同步」关闭同步。",
                "count": count
            ])
            return
        }

        let startedAt = Date()
        AppLogger.shared.info("ReproSeeder", "seed_started", metadata: [
            "count": count,
            "longEdge": longEdge,
            "cloudKitEnabled": cloudKitEnabled
        ])

        // 全分辨率噪声 PNG 编码很慢（2400px 长边约 1–2s/张），逐条生成 200 张要几分钟。
        // 这里生成一小组不同的底图循环用：我们要复现的是**体量导致的物化开销**，
        // 不是「字节完全不重复」——SQLite 也不会对 BLOB 做去重。
        let basePool = (0..<min(count, 6)).map { _ in
            makeNoisePNG(longEdge: longEdge)
        }
        guard let firstSize = basePool.first?.count else { return }
        AppLogger.shared.info("ReproSeeder", "base_images_ready", metadata: [
            "poolSize": basePool.count,
            "bytesEach": firstSize,
            "elapsedMs": Int(Date().timeIntervalSince(startedAt) * 1000)
        ])

        let ctx = ModelContext(container)
        for i in 0..<count {
            let png = basePool[i % basePool.count]
            let grid = makePatternGrid(rows: 100, cols: 100)
            let gridData = try? JSONEncoder().encode(grid)

            let record = SDProjectRecord(
                name: "\(namePrefix)\(i)",
                date: Date().addingTimeInterval(-Double(i) * 3600),
                totalBeads: 10_000,
                isPlanned: i % 3 == 0,                       // 三分之一进「计划」列表
                executedDate: i % 3 == 0 ? nil : Date(),
                thumbnail: png,                              // 原图：拼图模式用
                finishedImage: i % 5 == 0 ? png : nil,
                patternGridData: gridData,
                // 一半留 nil = 老数据形态，触发迁移 backfill + 列表现场降级路径
                displayThumbnail: i % 2 == 0 ? nil : makeNoisePNG(longEdge: 512),
                beadUsages: []
            )
            ctx.insert(record)

            // 分批 save：一次性 insert 200 条 × 10MB 会让 context 把 2GB 全挂在内存里。
            if i % 20 == 19 {
                flush(ctx, at: i)
            }
        }
        flush(ctx, at: count - 1)

        AppLogger.shared.info("ReproSeeder", "seed_completed", metadata: [
            "count": count,
            "approxTotalMB": count * firstSize / 1_048_576,
            "elapsedMs": Int(Date().timeIntervalSince(startedAt) * 1000)
        ])
    }

    private static func flush(_ ctx: ModelContext, at index: Int) {
        do {
            try ctx.save()
        } catch {
            AppLogger.shared.error("ReproSeeder", "seed_batch_save_failed", metadata: [
                "index": index, "error": "\(error)"
            ])
        }
    }

    // MARK: - 清理

    private static func cleanup(container: ModelContainer) {
        let ctx = ModelContext(container)
        var descriptor = FetchDescriptor<SDProjectRecord>(
            predicate: #Predicate { $0.name.starts(with: "ChaosSeed-") }
        )
        // 只投影 id：delete 不需要物化 blob，几百条 × 10MB 裸 fetch 会一次拉几 GB 进内存。
        descriptor.propertiesToFetch = [\.id]
        do {
            let toDelete = try ctx.fetch(descriptor)
            AppLogger.shared.info("ReproSeeder", "cleanup_started", metadata: ["count": toDelete.count])
            // 分批删 + save，理由同灌数据：一次性 delete 几百条大行会把 undo/pending 全挂内存。
            for (i, record) in toDelete.enumerated() {
                ctx.delete(record)
                if i % 20 == 19 { flush(ctx, at: i) }
            }
            try ctx.save()
            AppLogger.shared.info("ReproSeeder", "cleanup_completed", metadata: ["count": toDelete.count])
        } catch {
            AppLogger.shared.error("ReproSeeder", "cleanup_failed", metadata: ["error": "\(error)"])
        }
    }

    // MARK: - 造数据

    /// 真实形态的拼图网格：100×100 = 1 万格色号矩阵，JSON 编码后约 100KB。
    private static func makePatternGrid(rows: Int, cols: Int) -> BeadPatternGrid {
        let palette = ["H01", "H02", "A4", "A5", "B7", "C12", "D3"]
        let cells: [[String?]] = (0..<rows).map { r in
            (0..<cols).map { c in
                // 留一部分空格，跟真实图纸一样不是满格
                (r + c) % 7 == 0 ? nil : palette[(r &* 31 &+ c) % palette.count]
            }
        }
        return BeadPatternGrid(
            corners: GridCorners(
                topLeft: CGPoint(x: 0.05, y: 0.05),
                topRight: CGPoint(x: 0.95, y: 0.05),
                bottomLeft: CGPoint(x: 0.05, y: 0.95),
                bottomRight: CGPoint(x: 0.95, y: 0.95)
            ),
            rows: rows,
            cols: cols,
            cellColorCodes: cells,
            lastCalibratedAt: Date(),
            sourceImageSize: CGSize(width: 2400, height: 1800),
            colorSystem: .mard
        )
    }

    /// 随机噪声 PNG：逐像素随机让 DEFLATE 基本失效，文件大小逼近原始像素数据，
    /// 逼近真实「手机直接拍的图纸原图」体量（纯色图会被压到几 KB，测不出东西）。
    private static func makeNoisePNG(longEdge: Int) -> Data {
        let width = longEdge
        let height = Int(Double(longEdge) * 0.75)   // 4:3
        var buffer = Data(count: width * height * 4)
        buffer.withUnsafeMutableBytes { raw in
            arc4random_buf(raw.baseAddress, raw.count)
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: buffer as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ),
              let png = UIImage(cgImage: cgImage).pngData() else {
            AppLogger.shared.error("ReproSeeder", "noise_png_failed", metadata: ["longEdge": longEdge])
            return Data()
        }
        return png
    }

    private static func intArgument(_ args: [String], key: String) -> Int? {
        guard let idx = args.firstIndex(of: key), idx + 1 < args.count else { return nil }
        return Int(args[idx + 1])
    }
}
#endif
