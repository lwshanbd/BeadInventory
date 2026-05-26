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
import TipKit

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

        self.initialFatalErrorMessage = fatalErrorMessage

        // 初始化 TipKit
        do {
            try Tips.configure([
                .displayFrequency(.daily),
                .datastoreLocation(.applicationDefault)
            ])
        } catch {
            AppLogger.shared.error("TipKit", "初始化失败: \(error.localizedDescription)")
        }
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
                    AppLogger.shared.info("CloudSync", "remote_change_received")
                    inventoryManager.scheduleRefreshFromPersistentStore(reason: "remoteChangeNotification")
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
                // 停掉 displayThumbnail 后台迁移协调器 —— 释放 CPU + 让 saveData 在干净 context 上完成。
                // 协调器内部用 generation token 保证下次 .active start() 不会跟旧 task 抢资源。
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
                // 启动 displayThumbnail 后台迁移协调器 —— 给老用户的大图后台 backfill 小图。
                // 协调器内部 5s 延迟 + 重入安全（已在跑就跳过）+ 失败自愈（下次启动从余量继续）。
                // **关键路径**：458 项目级用户在迁移完成前列表 fallback 现场降级，**已经**不会撞 jetsam，
                // 迁移只是把列表加载从 fallback CGImageSource 升级到直接读小图 JPEG。
                ThumbnailMigrationCoordinator.shared.start(inventoryManager: inventoryManager)
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

    private let container = CKContainer(identifier: "iCloud.com.beadinventory.app")
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

        container.accountStatus { [weak self] status, error in
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

        let database = container.privateCloudDatabase
        let recordTypes = cloudRecordTypes
        let plannedFields = plannedProjectFieldCandidates
        let preferredZoneIDs = cloudQueryZoneIDs

        AppLogger.shared.info("CloudSync", "cloud_data_refresh_started", metadata: ["force": force])

        Task.detached(priority: .utility) {
            do {
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
