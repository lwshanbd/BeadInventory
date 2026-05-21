//
//  SelectionContext.swift
//  BeadInventory
//
//  多选状态容器 —— 各页统一的"进入/退出多选 + 选中集合"管理。
//

import SwiftUI

/// 多选状态容器。被多选页面内嵌：
///   @StateObject var sel = SelectionContext<UUID>()
/// 视图层调用 sel.isActive / sel.toggle / sel.exit 即可。
@MainActor
final class SelectionContext<ID: Hashable>: ObservableObject {
    @Published private(set) var isActive: Bool = false
    @Published private(set) var selected: Set<ID> = []

    func enter(initial: ID? = nil) {
        isActive = true
        if let id = initial { selected.insert(id) }
    }

    func exit() {
        isActive = false
        selected.removeAll()
    }

    func toggle(_ id: ID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    func contains(_ id: ID) -> Bool { selected.contains(id) }

    func selectAll<S: Sequence>(_ ids: S) where S.Element == ID {
        selected = Set(ids)
    }

    func clear() {
        selected.removeAll()
    }

    var count: Int { selected.count }
}

// MARK: - 跨视图通信
//
// 子视图（如 InventoryView）的多选态需要告知父容器（ContentView），
// 让父容器决定是否隐藏浮动按钮等会撞车的 UI。用 PreferenceKey 而不是
// 新的 EnvironmentObject，避免在已经很拥挤的环境对象树上再插一层。

/// 子视图通过 `.preference(key: SelectModeActivePreferenceKey.self, value: sel.isActive)`
/// 向上广播自己的多选态；父容器用 `.onPreferenceChange(...)` 监听。
struct SelectModeActivePreferenceKey: PreferenceKey {
    static var defaultValue: Bool = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        // 任意子视图为 true 即视为活跃
        value = value || nextValue()
    }
}

