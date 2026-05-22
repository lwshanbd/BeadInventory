//
//  BIEmptyHero.swift
//  BeadInventory
//
//  暖色空状态 hero —— 80×80 圆角 24 的 flavor*0.15 底 + 右下角一颗 bead。
//  flavor 跟随调用方页面（latte/sage/honey/mauve/rose/mist），不是统一 mist。
//

import SwiftUI

struct BIEmptyHero<CTA: View>: View {
    let icon: String
    let flavor: Color
    let title: String
    let subtitle: String
    @ViewBuilder var cta: () -> CTA

    init(
        icon: String,
        flavor: Color,
        title: String,
        subtitle: String,
        @ViewBuilder cta: @escaping () -> CTA = { EmptyView() }
    ) {
        self.icon = icon
        self.flavor = flavor
        self.title = title
        self.subtitle = subtitle
        self.cta = cta
    }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(flavor.opacity(0.15))
                    .frame(width: 80, height: 80)
                Image(systemName: icon)
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(flavor)
                // 右下角的小 bead
                BeadView(color: flavor, size: 24)
                    .overlay(
                        Circle()
                            .strokeBorder(Theme.ColorToken.Surface.background, lineWidth: 3)
                    )
                    .offset(x: 32, y: 32)
            }
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.Text.primary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            cta()
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 60)
    }
}

#Preview {
    VStack(spacing: 18) {
        BIEmptyHero(
            icon: "shippingbox",
            flavor: Theme.ColorToken.Morandi.latte,
            title: "暂无运输记录",
            subtitle: "等待中的购买订单会出现在这里"
        ) {
            // no CTA
        }
        BIEmptyHero(
            icon: "calendar.badge.clock",
            flavor: Theme.ColorToken.Morandi.sage,
            title: "暂无作品",
            subtitle: "完成扣减后,作品会出现在成品日历里"
        ) {
            // no CTA
        }
    }
    .background(Theme.ColorToken.Surface.background)
}
