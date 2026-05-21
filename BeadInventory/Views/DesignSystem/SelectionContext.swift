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
