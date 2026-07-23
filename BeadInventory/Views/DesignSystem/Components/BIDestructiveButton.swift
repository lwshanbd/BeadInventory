//
//  BIDestructiveButton.swift
//  BeadInventory
//
//  破坏性操作按钮：全宽、44pt 高、错误红色背景。
//  默认图标为 trash；传 nil 可隐藏图标。
//

import SwiftUI

struct BIDestructiveButton: View {
    let title: String
    let systemImage: String?
    let action: () -> Void

    init(_ title: String, systemImage: String? = "trash", action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(role: .destructive, action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).font(Theme.Typography.body.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .foregroundStyle(.white)
            .background(
                Theme.ColorToken.Fill.error,
                in: RoundedRectangle(cornerRadius: Theme.Radius.md)
            )
        }
        .buttonStyle(.plain)
    }
}
