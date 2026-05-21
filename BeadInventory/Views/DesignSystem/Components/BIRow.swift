//
//  BIRow.swift
//  BeadInventory
//
//  通用列表行：leading + title/subtitle + trailing。
//  三个 slot 都可选；padding/spacing 走 Theme 常量。
//

import SwiftUI

/// 通用列表行：leading + title/subtitle + trailing。
/// 三个 slot 都可选；padding/spacing 走 Theme 常量。
struct BIRow<Leading: View, Trailing: View>: View {
    private let title: String
    private let subtitle: String?
    private let leading: () -> Leading
    private let trailing: () -> Trailing

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder leading: @escaping () -> Leading = { EmptyView() },
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            leading()
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.ColorToken.Text.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.vertical, Theme.Spacing.sm)
    }
}

#Preview {
    List {
        BIRow(title: "DA001", subtitle: "玫瑰红 · 库存 200") {
            BIColorSwatch(hex: "#FF6B9D", code: "DA1", size: 32)
        } trailing: {
            BIBadge("低", style: .warning)
        }
        BIRow(title: "项目示例", subtitle: "12 色 · 计划中") {
            Image(systemName: "calendar.badge.clock")
                .foregroundStyle(Theme.ColorToken.Status.info)
        } trailing: {
            BIBadge("进行中", style: .info)
        }
    }
}
