//
//  BIDangerRow.swift
//  BeadInventory
//
//  危险行 —— icon tile 用 error * 0.1 底色，文字与 chevron 用 error 色。
//  独立成组放在自己的 BIGroupCard 里，永远不和普通行混在同一张卡里。
//

import SwiftUI

struct BIDangerRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var isLast: Bool = false
    var action: (() -> Void)? = nil

    var body: some View {
        Button {
            action?()
        } label: {
            content
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }

    private var content: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Theme.ColorToken.Status.error.opacity(0.10))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.ColorToken.Status.error)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.ColorToken.Status.error)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ColorToken.Status.error)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(Theme.ColorToken.Border.divider)
                    .frame(height: 1)
                    .padding(.leading, 60)
            }
        }
    }
}

#Preview {
    VStack(spacing: 18) {
        BIGroupCard {
            BIDangerRow(icon: "arrow.counterclockwise", title: "重置库存", subtitle: "把当前品牌所有色号置零")
            BIDangerRow(icon: "trash", title: "清空所有数据", subtitle: "操作不可撤销")
            BIDangerRow(icon: "minus.circle", title: "删除此品牌", subtitle: "及其所有库存记录", isLast: true)
        }
    }
    .padding(.vertical, 18)
    .background(Theme.ColorToken.Surface.background)
}
