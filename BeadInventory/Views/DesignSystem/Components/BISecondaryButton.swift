//
//  BISecondaryButton.swift
//  BeadInventory
//
//  次级操作按钮：全宽、44pt 高、风味色轮廓风格。
//

import SwiftUI

struct BISecondaryButton: View {
    let title: String
    let systemImage: String?
    let action: () -> Void

    @Environment(\.tabFlavor) private var flavor

    init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).font(Theme.Typography.body.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .foregroundStyle(flavor.color)
            .background(
                flavor.color.opacity(0.12),
                in: RoundedRectangle(cornerRadius: Theme.Radius.md)
            )
        }
        .buttonStyle(.plain)
    }
}
