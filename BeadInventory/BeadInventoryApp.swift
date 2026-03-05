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

    /// 深链接触发扫描的标志
    @State private var shouldOpenScan = false

    /// 监听应用生命周期
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppLogger.shared.info("App", "bootstrap_started")

        // 设置 SwiftData ModelContainer（使用版本化 Schema 支持数据迁移）
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let cloudConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .automatic
        )

        let localFallbackConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )

        let container: ModelContainer
        let isCloudSyncEnabled: Bool
        do {
            container = try ModelContainer(
                for: schema,
                migrationPlan: BeadInventoryMigrationPlan.self,
                configurations: [cloudConfiguration]
            )
            isCloudSyncEnabled = true
            print("[App] ✅ iCloud 同步容器初始化成功")
            AppLogger.shared.info("App", "model_container_initialized", metadata: ["cloudKit": "automatic"])
        } catch {
            let nsError = error as NSError
            print("[App] ⚠️ iCloud 同步容器初始化失败，回退本地存储: \(error)")
            print("[App]   - domain: \(nsError.domain), code: \(nsError.code)")
            AppLogger.shared.warning(
                "App",
                "model_container_fallback_to_local",
                metadata: [
                    "domain": nsError.domain,
                    "code": nsError.code
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
                AppLogger.shared.error("App", "fatal_model_container_creation_failed", metadata: ["error": "\(error)"])
                fatalError("无法创建 ModelContainer: \(error)")
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
    }

    var body: some Scene {
        WindowGroup {
            ContentView(shouldOpenScan: $shouldOpenScan)
                .environmentObject(inventoryManager)
                .environmentObject(sharedImageManager)
                .environmentObject(cloudSyncStatusManager)
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
                .onAppear {
                    AppLogger.shared.info("App", "root_view_appeared")
                    // App 启动时检查是否有待处理的共享图片
                    sharedImageManager.checkForPendingImage()

                    // 检查并执行每周自动备份
                    BackupManager.shared.checkAndPerformWeeklyBackupIfNeeded(inventoryManager: inventoryManager)
                    // 启动时检查 iCloud 状态
                    cloudSyncStatusManager.refreshAccountStatus()

                    // 静默检查远程公告（配置好 URL 和密钥后取消注释即可启用）
                    // AnnouncementManager.shared.checkForAnnouncement()
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
                print("[App] 应用进入后台，保存数据...")
                inventoryManager.saveData()
                HistoryManager.shared.saveDataImmediately()
            case .inactive:
                // .inactive 可能是切后台前的过渡态，也可能是控制中心/通知中心弹出
                // 这里也保存，saveData() 内部有重入保护，不会重复执行
                print("[App] 应用进入非活跃状态，保存数据...")
                inventoryManager.saveData()
                HistoryManager.shared.saveDataImmediately()
            case .active:
                print("[App] 应用恢复活跃状态")
                // 前台恢复与远程通知共用同一防抖刷新队列，避免短时间重复全量加载
                inventoryManager.scheduleRefreshFromPersistentStore(
                    reason: "scenePhase.active",
                    debounceSeconds: 0.25
                )
                cloudSyncStatusManager.refreshAccountStatus()
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

/// iCloud 同步状态管理（仅用于 UI 状态展示）
@MainActor
class CloudSyncStatusManager: ObservableObject {
    enum Mode {
        case iCloudEnabled
        case localFallback
    }

    @Published private(set) var mode: Mode
    @Published private(set) var accountStatus: CKAccountStatus?
    @Published private(set) var isCheckingAccount = false
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var lastErrorMessage: String?

    private let container = CKContainer(identifier: "iCloud.com.beadinventory.app")
    private var lastRefreshRequestedAt: Date?

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
            return "当前为本地存储模式"
        case .iCloudEnabled:
            if isCheckingAccount && accountStatus == nil {
                return "正在检查 iCloud 状态..."
            }
            switch accountStatus {
            case .available:
                return "iCloud 同步已启用"
            case .noAccount:
                return "未登录 iCloud 账号"
            case .restricted:
                return "iCloud 权限受限"
            case .temporarilyUnavailable:
                return "iCloud 暂时不可用"
            case .couldNotDetermine, .none:
                return "iCloud 状态暂时未知"
            @unknown default:
                return "iCloud 状态暂时未知"
            }
        }
    }

    var secondaryStatusText: String {
        switch mode {
        case .localFallback:
            return "应用已自动回退到本地存储，现有数据可继续正常使用。"
        case .iCloudEnabled:
            if let lastErrorMessage {
                return "状态检查失败：\(lastErrorMessage)"
            }
            switch accountStatus {
            case .available:
                return "已连接 iCloud，可在多设备间同步数据。"
            case .noAccount:
                return "当前设备未登录 iCloud，无法进行云同步。"
            case .restricted:
                return "当前设备或账号限制了 iCloud 使用。"
            case .temporarilyUnavailable:
                return "iCloud 服务暂时不可用，请稍后再试。"
            case .couldNotDetermine, .none:
                return "暂时无法确认账号状态，请稍后点击刷新。"
            @unknown default:
                return "暂时无法确认账号状态，请稍后点击刷新。"
            }
        }
    }

    var shouldAllowManualRefresh: Bool {
        mode == .iCloudEnabled
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
            return
        }
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
                    return
                }

                self.accountStatus = status
                AppLogger.shared.info("CloudSync", "account_status_updated", metadata: ["status": "\(status.rawValue)"])
            }
        }
    }
}
