//
//  PatternModeSelectionSheet.swift
//  BeadInventory
//
//  拼图模式 - 入口分流页：单图纸 / 多零件
//
//  「拼图模式」原来是一个按钮直接进单张图纸的标定/高亮流程。立体拼图的图纸
//  通常是好几张零件图拼起来的，跟单图纸是两套用法，所以入口在这里分成两个
//  选项：用户点「拼图模式」→ 先说清楚自己要拼的是哪一种，再进对应流程。
//


import SwiftUI

struct PatternModeSelectionSheet: View {
    /// 选「单图纸模式」。这里只**记下**选择，真正的跳转要放在 parent 的
    /// `sheet(onDismiss:)` 里——本页收起的同时再 present 下一个 sheet，
    /// SwiftUI 会把后者吞掉。
    let onSelectSinglePattern: () -> Void

    /// 选「多零件模式」。跳转时机同上。
    let onSelectMultiPart: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// 内容块（两张卡片 + 四周 padding）实际占的高度。放大字号时卡片会长高，
    /// detent 写死会让第二张卡落到折叠线以下，所以量出来再定。
    /// 首帧是 0，detent 先取下限 240 再跳到实测值，开合时会有一次高度变化。
    @State private var contentHeight: CGFloat = 0

    /// 内容高度 + 64 的经验余量（导航条 + 底部安全区，不是算出来的；
    /// 改标题样式或改 padding 之后要重新量），夹在 [240, 620]。
    ///
    /// 注意上限的实际效果：内容再高也只是停在 620，**不会**自动切到 `.large`——
    /// AX-XXXL 下「多零件模式」仍然在折叠线以下，要用户自己上拉或滚动。
    private var preferredDetent: PresentationDetent {
        .height(min(max(contentHeight + 64, 240), 620))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.md) {
                    PatternModeOptionCard(
                        icon: "square.grid.3x3.square",
                        tint: Theme.ColorToken.Morandi.mauve,
                        title: "单图纸模式",
                        subtitle: "单张平面图纸，逐格高亮比对拼装",
                        showsChevron: true
                    ) {
                        onSelectSinglePattern()
                        dismiss()
                    }

                    PatternModeOptionCard(
                        icon: "cube.transparent",
                        tint: Theme.ColorToken.Morandi.mist,
                        title: "多零件模式",
                        subtitle: "一张图纸上排列着数十个小零件，常见于立体拼图",
                        showsChevron: true
                    ) {
                        onSelectMultiPart()
                        dismiss()
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.lg)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: PatternModeContentHeightKey.self, value: geo.size.height)
                    }
                )
            }
            .onPreferenceChange(PatternModeContentHeightKey.self) { contentHeight = $0 }
            .background(Theme.ColorToken.Surface.background)
            .navigationTitle("拼图模式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
        }
        // 超大字号下内容比 620pt 还高，`.large` 是兜底：用户上拉能撑开继续滚，
        // 但不会自动切过去（见 preferredDetent）。
        .presentationDetents([preferredDetent, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct PatternModeContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - 选项卡片

private struct PatternModeOptionCard: View {
    let icon: String
    /// 图标色。用 `Theme.ColorToken.Morandi.*`，**不要**用 `Fill.*` ——
    /// Fill 深色下会自动加深（为压白字设计），当图标前景色会糊在深色卡片上。
    let tint: Color
    let title: String
    let subtitle: String
    let showsChevron: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.lg) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(tint)
                    .frame(width: 48, height: 48)
                    .background(tint.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))

                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(Theme.ColorToken.Text.primary)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundColor(Theme.ColorToken.Text.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(Theme.ColorToken.Text.tertiary)
                }
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.ColorToken.Surface.elevated)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            PatternModeSelectionSheet(onSelectSinglePattern: {}, onSelectMultiPart: {})
        }
}
