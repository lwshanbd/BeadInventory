//
//  BIGroupHeader.swift
//  BeadInventory
//
//  卡片之间的分组标题：13/600 主文 + 可选 11/tertiary hint。
//  padding 与设计稿一致：左右 22pt，上下 marginTop 18 + bottom 8。
//

import SwiftUI

struct BIGroupHeader: View {
    let title: String
    var hint: String? = nil

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ColorToken.Text.primary)
            Spacer()
            if let hint, !hint.isEmpty {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ColorToken.Text.tertiary)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }
}

#Preview {
    VStack(spacing: 0) {
        BIGroupHeader(title: "色号工具")
        BIGroupHeader(title: "数据 & 同步", hint: "本机 · 已同步")
        BIGroupHeader(title: "危险区")
    }
    .background(Theme.ColorToken.Surface.background)
}
