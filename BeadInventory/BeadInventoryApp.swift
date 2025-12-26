//
//  BeadInventoryApp.swift
//  BeadInventory
//
//  拼豆库存管理App
//

import SwiftUI

@main
struct BeadInventoryApp: App {
    @StateObject private var inventoryManager = InventoryManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(inventoryManager)
        }
    }
}
