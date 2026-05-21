//
//  BIBadge.swift
//  BeadInventory
//
//  通用徽章组件 —— 状态色 / 强调色 / 中性，自动跟随 TabFlavor 色调。
//

import SwiftUI

enum BIBadgeStyle {
    case success, warning, error, info, accent, neutral
    case custom(background: Color, foreground: Color)
}

struct BIBadge: View {
    let text: String
    let style: BIBadgeStyle

    @Environment(\.tabFlavor) private var flavor

    init(_ text: String, style: BIBadgeStyle = .neutral) {
        self.text = text
        self.style = style
    }

    var body: some View {
        Text(text)
            .font(Theme.Typography.metadata)
            .foregroundStyle(foreground)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xs)
            .background(background, in: RoundedRectangle(cornerRadius: Theme.Radius.pill))
    }

    private var background: Color {
        switch style {
        case .success: return Theme.ColorToken.Status.success.opacity(0.18)
        case .warning: return Theme.ColorToken.Status.warning.opacity(0.18)
        case .error:   return Theme.ColorToken.Status.error.opacity(0.18)
        case .info:    return Theme.ColorToken.Status.info.opacity(0.18)
        case .accent:  return flavor.color.opacity(0.18)
        case .neutral: return Theme.ColorToken.Surface.subtle
        case .custom(let bg, _): return bg
        }
    }
    private var foreground: Color {
        switch style {
        case .success: return Theme.ColorToken.Status.success
        case .warning: return Theme.ColorToken.Status.warning
        case .error:   return Theme.ColorToken.Status.error
        case .info:    return Theme.ColorToken.Status.info
        case .accent:  return flavor.color
        case .neutral: return Theme.ColorToken.Text.secondary
        case .custom(_, let fg): return fg
        }
    }
}

#Preview {
    VStack(spacing: 8) {
        BIBadge("成功", style: .success)
        BIBadge("低库存", style: .warning)
        BIBadge("不足", style: .error)
        BIBadge("提示", style: .info)
        BIBadge("强调", style: .accent)
        BIBadge("中性", style: .neutral)
    }
    .padding()
}
