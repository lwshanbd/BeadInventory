//
//  BIGroupCard.swift
//  BeadInventory
//
//  分组卡片 —— 取代 .listStyle(.insetGrouped) 的容器。
//  18 圆角 + 1px border + elevated 底 + horizontal padding 18。
//  内部子项需要分隔时，在子项里画 1px divider；divider 左侧留 60pt 缩进让 icon 上下对齐。
//

import SwiftUI

/// 分组卡片：可选标题 + content + 可选 footer。
/// 卡片本身 18 圆角 + 1px border + elevated 底；外面留 18pt 水平 padding。
struct BIGroupCard<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: () -> Content

    init(
        title: String? = nil,
        footer: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.Text.primary)
                    .padding(.leading, 4)
                    .padding(.bottom, 8)
            }
            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Theme.ColorToken.Surface.elevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18))
            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ColorToken.Text.tertiary)
                    .padding(.top, 8)
                    .padding(.horizontal, 6)
            }
        }
        .padding(.horizontal, 18)
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 18) {
            BIGroupCard(title: "分组标题") {
                Text("一行内容").padding(14)
                Rectangle().fill(Theme.ColorToken.Border.divider).frame(height: 1).padding(.leading, 60)
                Text("第二行").padding(14)
            }
            BIGroupCard(footer: "说明文字写在 footer 这里，给一段补充。") {
                Text("仅 footer 无标题").padding(14)
            }
        }
        .padding(.vertical, 18)
    }
    .background(Theme.ColorToken.Surface.background)
}
