//
//  TabFlavor.swift
//  BeadInventory
//
//  每个 Tab 的"风味色"环境值 —— 5 个 Tab → 5 种 Morandi 风味色（latte/honey/mauve/sage/mist）。
//

import SwiftUI

/// 5 个 Tab 的"风味色"：库存 / 计划 / 工作台 / 记录 / 更多。rawValue 就是 TabView 的 tag。
/// 仅作用于：TabBar 选中色、FAB、空状态、页眉强调、Interactive.primary。
enum TabFlavor: Int, CaseIterable {
    case inventory = 0
    case plan      = 1
    case workshop  = 2
    case records   = 3
    case more      = 4

    var color: Color {
        switch self {
        case .inventory:  return Color("Palette/Peach")    // latte
        case .plan:       return Color("Palette/Lemon")    // honey
        case .workshop:   return Color("Palette/Lavender") // mauve（工作台主色）
        case .records:    return Color("Palette/Mint")     // sage
        case .more:       return Color("Palette/Sky")      // mist
        }
    }

    /// 填充版风味色：按钮 / FAB / 激活 chip 的底色用这个（深色自动加深，见 Theme.ColorToken.Fill）。
    /// `color` 保留给彩色文字、图标、描边等前景场景。
    var fill: Color {
        switch self {
        case .inventory:  return Theme.ColorToken.Fill.latte
        case .plan:       return Theme.ColorToken.Fill.honey
        case .workshop:   return Theme.ColorToken.Fill.mauve
        case .records:    return Theme.ColorToken.Fill.sage
        case .more:       return Theme.ColorToken.Fill.mist
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
