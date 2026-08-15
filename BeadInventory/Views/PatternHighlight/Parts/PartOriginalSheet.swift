//
//  PartOriginalSheet.swift
//  BeadInventory
//
//  多零件模式 · 「这块到底是图纸上的哪一个」
//
//  零件一摆到拼豆板上，它跟图纸就断了：板上是一片纯色方块（判色的产物），图纸上那块
//  是带描边、带阴影的画，同一个零件在两边长得并不像。而拼的人手里抓着豆子，
//  最想确认的偏偏是「我现在填的这块，原图上是这个东西吗」。
//
//  所以板上每个零件都写着**它在零件清单里的号**，点开就是这一屏：左边图纸原图，
//  右边识别出来的样子，并排放着自己比。比出来不对，出路也写在下面 ——
//  回「核对颜色」那屏改，别在这儿改（这一屏只负责让人看清楚）。
//

import SwiftUI

struct PartOriginalSheet: View {
    /// 这个零件摆在哪儿。没摆上板时是 nil（零件条里的那些）。
    struct Placement {
        let boardNumber: Int
        /// 顺时针转了几个 90°。**必须说**：板上那块是转过的，跟原图对不上不是识别错了。
        let turns: Int
    }

    let title: String
    /// 零件清单里的序号，也就是板上写的那个号
    let order: Int
    /// 要不要单列一行写编号。零件没改过名时标题本身就是「零件 10」，
    /// 底下再写一行「编号 10」是同一句话说两遍；改过名的（「左前腿」）才需要这一行。
    let showsOrder: Bool
    /// 从图纸上抠下来的原样。nil = 还在抠，或者这次根本没有图（见 `hasSource`）。
    let original: UIImage?
    /// 这次有没有图纸可抠。没有图和「正在抠」要说不一样的话：
    /// 一个是等一下就好，一个是等到天亮也不会出来。
    let hasSource: Bool
    let footprint: PartFootprint
    let colors: [String: Color]
    let placement: Placement?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    compare
                    facts
                    hint
                }
                .padding()
            }
            .background(Theme.ColorToken.Surface.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            // 半屏就够：这一屏统共两张图加三行字，铺满整个屏幕只是多出一大片空白，
            // 而底下那块板还是他正在拼的东西，不该被整个盖掉。想看大的往上一拉。
            .presentationDetents([.medium, .large])
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    // MARK: - 并排比

    /// 两块一样大、并排放。上下叠放的话得滚一下才看得全，一滚就比不了了 ——
    /// 这一屏唯一的动作就是「两张图同时在眼里」。
    private var compare: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            panel(caption: String(localized: "图纸上原来这块")) { sourceImage }
            panel(caption: String(localized: "识别出来的样子")) {
                PartShapeThumbnail(footprint: footprint, colors: colors)
                    .padding(Theme.Spacing.sm)
            }
        }
    }

    private func panel<Content: View>(
        caption: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: Theme.Spacing.xs) {
            content()
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .fill(Theme.ColorToken.Surface.elevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
                )
            Text(caption)
                .font(.caption)
                .foregroundColor(Theme.ColorToken.Text.secondary)
        }
    }

    @ViewBuilder
    private var sourceImage: some View {
        if let original {
            GeometryReader { geo in
                // 放大到超过原图分辨率时用最近邻，豆子的边界是硬的（同零件清单那屏）；
                // 缩小时用默认插值，否则一像素宽的格线会抖成摩尔纹。
                Image(uiImage: original)
                    .resizable()
                    .interpolation(geo.size.width >= original.size.width ? .none : .high)
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            .padding(Theme.Spacing.sm)
        } else if hasSource {
            ProgressView()
        } else {
            VStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.title)
                    .foregroundStyle(Theme.ColorToken.Text.tertiary)
                Text("这次读不出图纸原图，只能看右边这张")
                    .font(.caption)
                    .foregroundColor(Theme.ColorToken.Text.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(Theme.Spacing.sm)
        }
    }

    // MARK: - 几句事实

    private var facts: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if showsOrder {
                row(label: String(localized: "编号"), value: "\(order)")
            }
            row(label: String(localized: "占地方"),
                value: String(localized: "\(footprint.width) × \(footprint.height) 格 · \(footprint.beads.count) 颗豆子"))
            if let placement {
                row(label: String(localized: "摆在"), value: boardText(placement))
            } else {
                row(label: String(localized: "摆在"), value: String(localized: "还没摆上板"))
            }
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Theme.ColorToken.Surface.elevated)
        )
    }

    /// 转过的零件必须写出来。不写的话用户拿板上那块跟左边原图一比，
    /// 发现「躺倒了」，第一反应是识别错了 —— 其实是排版时为了放得下特地转的。
    private func boardText(_ placement: Placement) -> String {
        placement.turns == 0
            ? String(localized: "第 \(placement.boardNumber) 块板")
            : String(localized: "第 \(placement.boardNumber) 块板 · 转了 \(placement.turns * 90)°")
    }

    private func row(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.footnote)
                .foregroundColor(Theme.ColorToken.Text.secondary)
            Spacer(minLength: Theme.Spacing.md)
            Text(value)
                .font(.footnote.weight(.medium))
                .foregroundColor(Theme.ColorToken.Text.primary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var hint: some View {
        Text("两边形状对不上，多半是这个零件的格子或者颜色判错了 —— 回「核对颜色」那屏改，改完再回来摆。")
            .font(.caption)
            .foregroundColor(Theme.ColorToken.Text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
