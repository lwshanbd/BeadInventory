//
//  BIListRow.swift
//  BeadInventory
//
//  二级页通用列表行 —— icon tile + title + subtitle + trailing slot。
//  trailing 支持 chevron / badge / toggle / meta / new / none。
//  放在 BIGroupCard 里使用；通过 isLast 控制是否画底部分隔线（60pt 左缩进以对齐 icon）。
//

import SwiftUI

enum BIListRowTrailing {
    case chevron
    case badge(String)
    case toggle(Binding<Bool>)
    case meta(String)
    case new
    case none
}

struct BIListRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    var subtitle: String? = nil
    var subtitleColor: Color? = nil
    var trailing: BIListRowTrailing = .chevron
    var isLast: Bool = false
    var action: (() -> Void)? = nil

    var body: some View {
        Button {
            action?()
        } label: {
            content
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }

    private var content: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.ColorToken.Text.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(subtitleColor ?? Theme.ColorToken.Text.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            trailingView
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(Theme.ColorToken.Border.divider)
                    .frame(height: 1)
                    .padding(.leading, 60)
            }
        }
    }

    @ViewBuilder
    private var trailingView: some View {
        switch trailing {
        case .chevron:
            Image(systemName: "chevron.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ColorToken.Text.tertiary)
        case .badge(let text):
            Text(text)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(Theme.ColorToken.Status.warning)
                )
        case .toggle(let binding):
            Toggle("", isOn: binding)
                .labelsHidden()
                .tint(Theme.ColorToken.Morandi.sage)
        case .meta(let text):
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.ColorToken.Status.success)
        case .new:
            Text("NEW")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(Theme.ColorToken.Morandi.honey)
                )
        case .none:
            EmptyView()
        }
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 18) {
            BIGroupCard(title: "示例 · 各类 trailing") {
                BIListRow(icon: "paintpalette.fill", iconColor: Theme.ColorToken.Morandi.mauve, title: "色号转换", subtitle: "不同品牌间的色号对照")
                BIListRow(icon: "cloud", iconColor: Theme.ColorToken.Morandi.mist, title: "iCloud 同步", subtitle: "上次同步 · 5 分钟前", trailing: .toggle(.constant(true)))
                BIListRow(icon: "shippingbox.fill", iconColor: Theme.ColorToken.Morandi.latte, title: "运输中 · 待到货", subtitle: "2 张订单", trailing: .badge("2"))
                BIListRow(icon: "sparkles", iconColor: Theme.ColorToken.Morandi.honey, title: "色相分析", subtitle: "看看你最爱用哪类颜色", trailing: .new)
                BIListRow(icon: "sparkles", iconColor: Theme.ColorToken.Morandi.mauve, title: "AI 图像识别", subtitle: "当前 · Kimi", trailing: .meta("已配置"), isLast: true)
            }
        }
        .padding(.vertical, 18)
    }
    .background(Theme.ColorToken.Surface.background)
}
