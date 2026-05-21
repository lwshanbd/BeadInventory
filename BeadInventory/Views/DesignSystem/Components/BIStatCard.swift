//
//  BIStatCard.swift
//  BeadInventory
//
//  统计卡片：图标 + 数值 + 标签，全宽、左对齐、圆角背景。
//  accent 为 nil 时自动用风味色。
//

import SwiftUI

struct BIStatCard: View {
    let icon: String      // SF Symbol name
    let title: String
    let value: String
    let accent: Color?

    @Environment(\.tabFlavor) private var flavor

    init(icon: String, title: String, value: String, accent: Color? = nil) {
        self.icon = icon
        self.title = title
        self.value = value
        self.accent = accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(accent ?? flavor.color)
                    .font(.title3)
                Spacer()
            }
            Text(value)
                .font(Theme.Typography.number)
                .foregroundStyle(Theme.ColorToken.Text.primary)
            Text(title)
                .font(Theme.Typography.metadata)
                .foregroundStyle(Theme.ColorToken.Text.secondary)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Theme.ColorToken.Surface.elevated,
            in: RoundedRectangle(cornerRadius: Theme.Radius.md)
        )
    }
}
