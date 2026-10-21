//
//  PatternToolbarLabel.swift
//  BeadInventory
//
//  拼图模式导航栏按钮的文字：横条里显示字，竖条里交给系统。
//

import SwiftUI

/// 拼图模式导航栏按钮（「退出」「拼完了」这类）的 label。
///
/// **横条里照旧显示文字。** 普通 iPhone 的导航栏里，`Label` 只画图标、不画字
/// （`labelStyle` 也压不住），而这几个按钮光一个图标用户得先猜它干什么。
///
/// **竖条里换成系统的 `Label`。** iPhone Duo 合上、或打开横放时，系统把导航栏按钮
/// 排成一列放在屏幕侧边，但只收「有图标的标准项」：纯文字项、自定义视图都留在
/// 顶上单独一条横栏里，白占一截高度（HIG「Designing for iPhone Duo」）。
///
/// 横条还是竖条由系统的 `toolbarVerticalEdge` 说了算，不按屏幕尺寸猜。
/// 转屏、开合时系统会更新它，按钮跟着变。
struct PatternToolbarLabel: View {
    let title: LocalizedStringKey
    let systemImage: String

    init(_ title: LocalizedStringKey, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        if #available(iOS 27.1, *) {
            AdaptiveLabel(title: title, systemImage: systemImage)
        } else {
            Text(title)
        }
    }
}

@available(iOS 27.1, *)
private struct AdaptiveLabel: View {
    let title: LocalizedStringKey
    let systemImage: String
    @Environment(\.toolbarVerticalEdge) private var verticalEdge

    var body: some View {
        if verticalEdge != nil {
            Label(title, systemImage: systemImage)
        } else {
            Text(title)
        }
    }
}
