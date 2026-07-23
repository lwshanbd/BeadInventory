//
//  BIPrimaryButton.swift
//  BeadInventory
//
//  主操作按钮：全宽、56pt 高、用风味色填充背景。
//  禁用时自动降为三级文字色。
//

import SwiftUI

struct BIPrimaryButton: View {
    let title: String
    let systemImage: String?
    let action: () -> Void

    @Environment(\.tabFlavor) private var flavor
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).font(Theme.Typography.cardTitle)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .foregroundStyle(.white)
            .background(
                (isEnabled ? flavor.fill : Theme.ColorToken.Text.tertiary),
                in: RoundedRectangle(cornerRadius: Theme.Radius.md)
            )
        }
        .buttonStyle(.plain)
    }
}
