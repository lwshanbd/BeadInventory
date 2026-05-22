//
//  Wordmark.swift
//  BeadInventory
//
//  品牌字标 "啃[豆]小仓"：以 BeadView 代替 "豆" 字。
//

import SwiftUI

struct Wordmark: View {
    var size: CGFloat = 32
    var beadColor: Color = Theme.ColorToken.Morandi.latte

    init(size: CGFloat = 32, beadColor: Color = Theme.ColorToken.Morandi.latte) {
        self.size = size
        self.beadColor = beadColor
    }

    var body: some View {
        // ZCOOL KuaiLe（站酷快乐体）— 设计稿 tokens.css 指定的 wordmark 字体，圆润可爱
        let font = Theme.Typography.wordmark(size: size)
        HStack(spacing: 2) {
            Text("啃")
                .font(font)
                .foregroundStyle(Theme.ColorToken.Text.primary)
            BeadView(color: beadColor, size: size * 1.02)
                .offset(y: size * 0.04)
            Text("小")
                .font(font)
                .foregroundStyle(Theme.ColorToken.Text.primary)
            Text("仓")
                .font(font)
                .foregroundStyle(Theme.ColorToken.Text.primary)
        }
    }
}
