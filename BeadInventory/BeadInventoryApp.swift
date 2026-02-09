//
//  BeadInventoryApp.swift
//  BeadInventory
//
//  拼豆库存管理App
//

import SwiftUI
import SwiftData

@main
struct BeadInventoryApp: App {
    let modelContainer: ModelContainer

    @StateObject private var inventoryManager: InventoryManager
    @StateObject private var sharedImageManager = SharedImageManager.shared

    /// 深链接触发扫描的标志
    @State private var shouldOpenScan = false

    /// 监听应用生命周期
    @Environment(\.scenePhase) private var scenePhase

    init() {
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
        do {
            container = try ModelContainer(
                for: schema,
                migrationPlan: BeadInventoryMigrationPlan.self,
                configurations: [cloudConfiguration]
            )
            print("[App] ✅ iCloud 同步容器初始化成功")
        } catch {
            let nsError = error as NSError
            print("[App] ⚠️ iCloud 同步容器初始化失败，回退本地存储: \(error)")
            print("[App]   - domain: \(nsError.domain), code: \(nsError.code)")
            if !nsError.userInfo.isEmpty {
                print("[App]   - userInfo: \(nsError.userInfo)")
            }
            do {
                container = try ModelContainer(
                    for: schema,
                    migrationPlan: BeadInventoryMigrationPlan.self,
                    configurations: [localFallbackConfiguration]
                )
                print("[App] ✅ 已回退为本地存储模式，确保旧数据可用")
            } catch {
                fatalError("无法创建 ModelContainer: \(error)")
            }
        }

        self.modelContainer = container
        // 创建 InventoryManager 并传入 ModelContext
        let manager = InventoryManager(modelContext: container.mainContext)
        self._inventoryManager = StateObject(wrappedValue: manager)

        // 初始化 HistoryManager
        HistoryManager.shared.setModelContext(container.mainContext)
        HistoryManager.shared.inventoryManager = manager
    }

    var body: some Scene {
        WindowGroup {
            ContentView(shouldOpenScan: $shouldOpenScan)
                .environmentObject(inventoryManager)
                .environmentObject(sharedImageManager)
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
                .onAppear {
                    // App 启动时检查是否有待处理的共享图片
                    sharedImageManager.checkForPendingImage()

                    // 检查并执行每周自动备份
                    BackupManager.shared.checkAndPerformWeeklyBackupIfNeeded(inventoryManager: inventoryManager)

                    // 静默检查远程公告（配置好 URL 和密钥后取消注释即可启用）
                    // AnnouncementManager.shared.checkForAnnouncement()
                }
        }
        .modelContainer(modelContainer)
        .onChange(of: scenePhase) { _, newPhase in
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
                inventoryManager.refreshFromPersistentStore(reason: "scenePhase.active")
            @unknown default:
                break
            }
        }
    }

    /// 处理传入的 URL Scheme
    private func handleIncomingURL(_ url: URL) {
        // 处理 beadinventory://scan
        if url.scheme == "beadinventory" && url.host == "scan" {
            // 检查共享图片
            sharedImageManager.checkForPendingImage()
            // 触发跳转到扫描页
            shouldOpenScan = true
        }
    }
}
