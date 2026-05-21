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
            .onTapGesture {
                if isActive { onTapInSelectMode() }
            }
            .onLongPressGesture(minimumDuration: 0.4) {
                if !isActive { onLongPress() }
            }
    }
}
