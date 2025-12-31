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

    init() {
        // 设置 SwiftData ModelContainer
        let schema = Schema([
            SDBrand.self,
            SDBrandStock.self,
            SDProjectRecord.self,
            SDBeadUsage.self
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            self.modelContainer = container
            // 创建 InventoryManager 并传入 ModelContext
            let manager = InventoryManager(modelContext: container.mainContext)
            self._inventoryManager = StateObject(wrappedValue: manager)
        } catch {
            fatalError("无法创建 ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(inventoryManager)
        }
        .modelContainer(modelContainer)
    }
}
