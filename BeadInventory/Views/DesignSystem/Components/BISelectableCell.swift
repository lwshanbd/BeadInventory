//
//  BISelectableCell.swift
//  BeadInventory
//
//  多选单元统一外观：选中边框 + 右上角勾选 + 长按进入多选。
//

import SwiftUI

struct BISelectableCell<Content: View>: View {
    let isActive: Bool
    let isSelected: Bool
    let onLongPress: () -> Void
    let onTapInSelectMode: () -> Void
    /// 可选：非多选态下的轻点回调。如果由外层 NavigationLink / 内层 Button 提供点击行为，请保持 nil 让点击穿透。
    var onTapInactive: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    @Environment(\.tabFlavor) private var flavor

    var body: some View {
        content()
            .overlay(alignment: .topTrailing) {
                if isActive {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? flavor.color : Theme.ColorToken.Text.tertiary)
                        .padding(Theme.Spacing.xs)
                        .background(
                            Circle().fill(Theme.ColorToken.Surface.elevated.opacity(0.85))
                        )
                        .padding(Theme.Spacing.xs)
                        .sensoryFeedback(.selection, trigger: isSelected)
                }
            }
            .overlay {
                if isActive && isSelected {
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .strokeBorder(flavor.color, lineWidth: 2)
                }
            }
            .opacity(isActive && !isSelected ? 0.85 : 1.0)
            .contentShape(Rectangle())
            // 仅在多选态 或 显式提供 inactive 回调时才劫持点击；否则让内部内容（如 NavigationLink）正常响应。
            .modifier(_OptionalTapHandler(
                isActive: isActive,
                onTapInSelectMode: onTapInSelectMode,
                onTapInactive: onTapInactive
            ))
            .onLongPressGesture(minimumDuration: 0.4) {
                if !isActive { onLongPress() }
            }
    }
}

/// 内部 helper：只有在需要时才挂 .onTapGesture，避免覆盖内层 NavigationLink / Button 的点击。
private struct _OptionalTapHandler: ViewModifier {
    let isActive: Bool
    let onTapInSelectMode: () -> Void
    let onTapInactive: (() -> Void)?

    func body(content: Content) -> some View {
        if isActive {
            content.onTapGesture { onTapInSelectMode() }
        } else if let onTapInactive {
            content.onTapGesture { onTapInactive() }
        } else {
            content
        }
    }
}
