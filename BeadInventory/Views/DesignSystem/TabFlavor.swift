//
//  TabFlavor.swift
//  BeadInventory
//
//  每个 Tab 的"风味色"环境值 —— TabBar 选中色、FAB、空状态、页眉强调。
//

import SwiftUI

/// 5 个 Tab 的"风味色"，仅作用于：TabBar 选中色、FAB、空状态、页眉强调、Interactive.primary。
enum TabFlavor: Int, CaseIterable {
    case inventory = 0
    case scan      = 1
    case plan      = 2
    case statistics = 3
    case more      = 4

    var color: Color {
        switch self {
        case .inventory:  return Color("Palette/Peach")
        case .scan:       return Color("Palette/Coral")
        case .plan:       return Color("Palette/Lavender")
        case .statistics: return Color("Palette/Mint")
        case .more:       return Color("Palette/Sky")
        }
    }
}

private struct TabFlavorKey: EnvironmentKey {
    static let defaultValue: TabFlavor = .inventory
}

extension EnvironmentValues {
    var tabFlavor: TabFlavor {
        get { self[TabFlavorKey.self] }
        set { self[TabFlavorKey.self] = newValue }
    }
}
