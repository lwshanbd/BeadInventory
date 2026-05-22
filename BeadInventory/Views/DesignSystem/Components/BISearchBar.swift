//
//  BISearchBar.swift
//  BeadInventory
//
//  通用搜索框 —— 包在 Surface.subtle 圆角 12 容器里。
//  magnifyingglass icon + TextField + 可选 ⌘K 徽章 + 自动 clear 按钮。
//

import SwiftUI

struct BISearchBar: View {
    @Binding var text: String
    var placeholder: String = "搜索"
    var showShortcutHint: Bool = false
    var horizontalPadding: CGFloat = 18

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ColorToken.Text.tertiary)

            TextField(placeholder, text: $text)
                .font(.system(size: 14))
                .foregroundStyle(Theme.ColorToken.Text.primary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isFocused)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.ColorToken.Text.tertiary)
                }
                .buttonStyle(.plain)
            } else if showShortcutHint {
                Text("⌘K")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.ColorToken.Text.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.ColorToken.Surface.subtle)
        )
        .padding(.horizontal, horizontalPadding)
    }
}

#Preview {
    VStack(spacing: 18) {
        BISearchBar(text: .constant(""), placeholder: "搜索色号或名称", showShortcutHint: true)
        BISearchBar(text: .constant("A01"), placeholder: "搜索色号或名称")
        BISearchBar(text: .constant(""), placeholder: "搜索计划名称")
    }
    .padding(.vertical, 18)
    .background(Theme.ColorToken.Surface.background)
}
