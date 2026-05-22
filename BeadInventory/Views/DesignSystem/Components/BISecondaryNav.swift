//
//  BISecondaryNav.swift
//  BeadInventory
//
//  二级页顶 nav：返回箭头（chevron-left）+ 居中 16/600 标题 + 右侧 0–2 个图标按钮。
//  高度 44。不带 large title —— 大标题留给主 Tab。
//  搭配 NavigationStack 使用：在父级把系统 nav bar 隐藏（toolbar hidden / navigationBarHidden）。
//

import SwiftUI

struct BISecondaryNav<Trailing: View>: View {
    let title: String
    private let trailing: () -> Trailing
    var dismissAction: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    init(
        title: String,
        dismissAction: (() -> Void)? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.dismissAction = dismissAction
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if let dismissAction { dismissAction() } else { dismiss() }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.Text.primary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.ColorToken.Text.primary)
                .frame(maxWidth: .infinity)
                .lineLimit(1)
                .truncationMode(.tail)

            HStack(spacing: 6) {
                trailing()
            }
            .frame(minWidth: 36, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .frame(minHeight: 44)
    }
}

/// 二级页 nav 右侧的标准图标按钮 —— 34pt 圆角 + elevated + 1pt border，可选小角标。
struct BINavIconButton: View {
    let systemImage: String
    var badge: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 11)
                            .fill(Theme.ColorToken.Surface.elevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 11)
                            .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
                    )

                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(Theme.ColorToken.Morandi.rose)
                        )
                        .offset(x: 3, y: -3)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    VStack(spacing: 0) {
        BISecondaryNav(title: "关于啃豆小仓") {
            BINavIconButton(systemImage: "ellipsis", action: {})
        }
        BISecondaryNav(title: "色号转换") {
            BINavIconButton(systemImage: "magnifyingglass", action: {})
            BINavIconButton(systemImage: "slider.horizontal.3", badge: "3", action: {})
        }
        BISecondaryNav(title: "成品日历")
        Spacer()
    }
    .background(Theme.ColorToken.Surface.background)
}
