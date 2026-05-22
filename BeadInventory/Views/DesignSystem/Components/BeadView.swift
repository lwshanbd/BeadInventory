//
//  BeadView.swift
//  BeadInventory
//
//  拼豆字形：带中心孔的小圆珠。
//  通过高光 + 阴影叠加营造立体感，可选描边环。
//

import SwiftUI

struct BeadView: View {
    var color: Color
    var size: CGFloat = 32
    var ring: Color? = nil

    init(color: Color, size: CGFloat = 32, ring: Color? = nil) {
        self.color = color
        self.size = size
        self.ring = ring
    }

    var body: some View {
        ZStack {
            // 底色
            Circle().fill(color)

            // 左上高光
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.55), .clear],
                        center: UnitPoint(x: 0.32, y: 0.26),
                        startRadius: 0,
                        endRadius: size * 0.5
                    )
                )

            // 内圈柔和深度
            Circle()
                .strokeBorder(Color.black.opacity(0.12), lineWidth: 1.5)
                .blur(radius: 1)

            // 中心孔
            ZStack {
                Circle()
                    .fill(Theme.ColorToken.Surface.background)
                Circle()
                    .strokeBorder(Color.black.opacity(0.35), lineWidth: 1)
                    .blur(radius: 0.5)
                    .mask(Circle())
            }
            .frame(width: size * 0.32, height: size * 0.32)

            // 可选描边环
            if let ring {
                Circle().strokeBorder(ring, lineWidth: 2)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: Color.black.opacity(0.12), radius: 1.5, x: 0, y: 1)
    }
}
