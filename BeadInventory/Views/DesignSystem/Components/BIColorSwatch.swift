//
//  BIColorSwatch.swift
//  BeadInventory
//
//  拼豆色号方块。内置文字明度自适应。复用 BeadColor 中已有的非失败 Color.init(hex:)。
//

import SwiftUI

/// 拼豆色号方块。内置文字明度自适应。复用 BeadColor 中已有的非失败 Color.init(hex:)。
struct BIColorSwatch: View {
    let hex: String
    let code: String?
    let size: CGFloat

    init(hex: String, code: String? = nil, size: CGFloat = 40) {
        self.hex = hex
        self.code = code
        self.size = size
    }

    var body: some View {
        let fill = Color(hex: hex)
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(fill)
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .stroke(Theme.ColorToken.Border.default, lineWidth: 0.5)
                )
            if let code {
                Text(code)
                    .font(.system(size: size * 0.28, weight: .semibold, design: .monospaced))
                    .foregroundStyle(textColor(on: fill))
            }
        }
    }

    private func textColor(on background: Color) -> Color {
        let ui = UIColor(background)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return luminance > 0.6 ? .black : .white
    }
}

#Preview {
    HStack {
        BIColorSwatch(hex: "#FF6B9D", code: "H1")
        BIColorSwatch(hex: "#FFFFFF", code: "W1")
        BIColorSwatch(hex: "#000000", code: "K1")
        BIColorSwatch(hex: "#A0C8E8", code: "B5", size: 56)
    }
    .padding()
}
