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
//  多零件模式目前只占位（点了不做任何事），等交互定下来再接。
//

import SwiftUI

struct PatternModeSelectionSheet: View {
    /// 选「单图纸模式」。这里只**记下**选择，真正的跳转要放在 parent 的
    /// `sheet(onDismiss:)` 里——本页收起的同时再 present 下一个 sheet，
    /// SwiftUI 会把后者吞掉。
    let onSelectSinglePattern: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// 两张卡片实际占的高度。放大字号时卡片会长高，写死 detent 会把第二张卡切掉
    /// （AX-XXXL 下实测「多零件模式」整张看不见），所以量出来再定 detent。
    @State private var contentHeight: CGFloat = 0

    /// 内容高度 + 导航条，夹在一个合理范围内；超过就交给 `.large`。
    private var preferredDetent: PresentationDetent {
        .height(min(max(contentHeight + 64, 240), 620))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.md) {
                    PatternModeOptionCard(
                        icon: "square.grid.3x3.square",
                        tint: Theme.ColorToken.Fill.mauve,
                        title: "单图纸模式",
                        subtitle: "一张平面图纸，逐格高亮对照着拼",
                        showsChevron: true
                    ) {
                        onSelectSinglePattern()
                        dismiss()
                    }

                    PatternModeOptionCard(
                        icon: "cube.transparent",
                        tint: Theme.ColorToken.Fill.info,
                        title: "多零件模式",
                        subtitle: "多零件模式常见于立体拼图图纸",
                        showsChevron: false
                    ) {
                        // 占位：交互还没定，点了不做任何事。
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
        // 超大字号下内容比 620pt 还高，`.large` 兜底让用户能撑开继续滚。
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
            PatternModeSelectionSheet(onSelectSinglePattern: {})
        }
}
