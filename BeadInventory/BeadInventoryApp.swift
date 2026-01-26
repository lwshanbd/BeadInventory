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

    init() {
        // 设置 SwiftData ModelContainer（使用版本化 Schema 支持数据迁移）
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )

        do {
            let container = try ModelContainer(
                for: schema,
                migrationPlan: BeadInventoryMigrationPlan.self,
                configurations: [modelConfiguration]
            )
            self.modelContainer = container
            // 创建 InventoryManager 并传入 ModelContext
            let manager = InventoryManager(modelContext: container.mainContext)
            self._inventoryManager = StateObject(wrappedValue: manager)

            // 初始化 HistoryManager
            HistoryManager.shared.setModelContext(container.mainContext)
            HistoryManager.shared.inventoryManager = manager
        } catch {
            fatalError("无法创建 ModelContainer: \(error)")
        }
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
                }
        }
        .modelContainer(modelContainer)
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
