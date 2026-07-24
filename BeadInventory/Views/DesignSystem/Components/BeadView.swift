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

            // 左上高光（深色下减弱，避免深底上发白刺眼）
            Circle()
                .fill(
                    RadialGradient(
                        colors: [BeadView.highlight, .clear],
                        center: UnitPoint(x: 0.32, y: 0.26),
                        startRadius: 0,
                        endRadius: size * 0.5
                    )
                )

            // 内圈柔和深度（深色下黑圈不可见，换浅色圈托出轮廓）
            Circle()
                .strokeBorder(BeadView.innerRim, lineWidth: 1.5)
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
        .shadow(color: Theme.ColorToken.Shadow.medium, radius: 1.5, x: 0, y: 1)
    }

    /// 深浅感知的白高光（深色减弱），InventoryView 网格色块等同类高光复用
    static let highlight = Color(uiColor: UIColor { trait in
        UIColor.white.withAlphaComponent(trait.userInterfaceStyle == .dark ? 0.32 : 0.55)
    })

    private static let innerRim = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.10)
            : UIColor.black.withAlphaComponent(0.12)
    })
}
