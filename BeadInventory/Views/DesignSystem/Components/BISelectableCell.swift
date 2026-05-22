//
//  BISelectableCell.swift
//  BeadInventory
//
//  多选单元统一外观：选中边框 + 勾选圆 + 长按进入多选。
//  勾选圆位置可选 .leadingInline（默认，行式 cell）或 .topLeading（网格方块 cell，避免挤压内容）。
//

import SwiftUI

/// 多选勾选圆的位置策略。
/// - `.leadingInline`：放在 cell 左侧，挤掉一点内容宽度，适合行式 cell（如列表）。
/// - `.topLeading`：浮在 cell 左上角，不占内容宽度，适合方形网格 cell。
enum BISelectableCheckmarkPlacement {
    case leadingInline
    case topLeading
}

struct BISelectableCell<Content: View>: View {
    let isActive: Bool
    let isSelected: Bool
    let onLongPress: () -> Void
    let onTapInSelectMode: () -> Void
    /// 可选：非多选态下的轻点回调。如果由外层 NavigationLink / 内层 Button 提供点击行为，请保持 nil 让点击穿透。
    var onTapInactive: (() -> Void)? = nil
    /// 勾选圆位置策略，默认行式 cell 在左侧、网格 cell 应显式传 `.topLeading`。
    var checkmarkPlacement: BISelectableCheckmarkPlacement = .leadingInline
    @ViewBuilder let content: () -> Content

    @Environment(\.tabFlavor) private var flavor

    private var checkmarkIcon: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(isSelected ? flavor.color : Theme.ColorToken.Text.tertiary)
            .sensoryFeedback(.selection, trigger: isSelected)
    }

    var body: some View {
        Group {
            switch checkmarkPlacement {
            case .leadingInline:
                HStack(spacing: Theme.Spacing.sm) {
                    if isActive {
                        checkmarkIcon
                            .frame(width: 28)
                            .transition(.asymmetric(
                                insertion: .move(edge: .leading).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)
                            ))
                    }
                    content()
                }
            case .topLeading:
                content()
                    .overlay(alignment: .topLeading) {
                        if isActive {
                            checkmarkIcon
                                .padding(Theme.Spacing.xs)
                                .background(
                                    Circle().fill(Theme.ColorToken.Surface.elevated.opacity(0.85))
                                )
                                .padding(Theme.Spacing.xs)
                        }
                    }
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
