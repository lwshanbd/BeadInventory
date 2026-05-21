//
//  MultiSelectActionBar.swift
//  BeadInventory
//
//  底部浮动的多选动作条：左侧 "已选 N"，右侧自定义按钮组。
//

import SwiftUI

struct MultiSelectActionBar<Actions: View>: View {
    let count: Int
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text("已选 \(count)")
                .font(Theme.Typography.body.weight(.medium))
                .foregroundStyle(Theme.ColorToken.Text.primary)
            Spacer()
            actions()
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.ColorToken.Border.divider)
                .frame(height: 0.5)
        }
    }
}
