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
    /// 这个零件摆在哪儿。nil = 还没摆上板 —— 目前进不来（只有点板上的零件才开得了这一屏），
    /// 留着是为了以后从零件条也能点开。
    struct Placement {
        let boardNumber: Int
        /// 顺时针转了几个 90°。**必须说**：板上那块是转过的，跟原图对不上不是识别错了。
        let turns: Int
    }

    /// 图纸原图现在处于哪一步。**必须是三选一，不能用「一张 nil 的图 + 一个 Bool」凑**：
    /// 那样「抠失败」和「还在抠」长得一模一样，用户对着一个永远转下去的圈等 ——
    /// 而抠失败是确定性的（同一张图、同一块 bounds，每次都失败），他等到天亮也不会出来。
    enum Original {
        case loading
        case ready(UIImage)
        /// 这次没有图纸可抠，或者这块在图纸上抠不出来。对用户来说是同一件事：
        /// 别等了，只能看识别结果。
        case unavailable
    }

    let title: String
    /// 零件清单里的序号，也就是板上写的那个号
    let order: Int
    /// 要不要单列一行写编号。零件没改过名时标题本身就是「零件 10」，
    /// 底下再写一行「编号 10」是同一句话说两遍；改过名的（「左前腿」）才需要这一行。
    let showsOrder: Bool
    let original: Original
    let footprint: PartFootprint
    let colors: [String: Color]
    let placement: Placement?
    /// 「回去重对这一块的格子」。nil = 这一屏只能看。
    ///
    /// 拼豆板那屏就是 nil：那时候零件已经在板上了，格子不对该走它自己的「改格子」。
    /// 核对颜色那屏才给这条路 —— 用户在那儿点开一块，十有八九就是因为觉得它判得不对，
    /// 而「格线没对准」正是判错的头号原因，出路不摆在眼前他只能自己猜要退到第几屏。
    var onRegrid: (() -> Void)?
    /// 翻到零件清单里的上一个 / 下一个。nil = 到头了，按钮变灰。
    ///
    /// 两个都是 nil 时整条底栏不出现（统共就一个零件）。**翻的是零件清单的顺序**，
    /// 也就是板上写的那个号 —— 翻到的那块可能摆在别的板上，「摆在」那一行会说清楚。
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    private var canStep: Bool { onPrevious != nil || onNext != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    compare
                    facts
                    regridButton
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
                if canStep {
                    ToolbarItemGroup(placement: .bottomBar) {
                        stepButton("上一个", systemImage: "chevron.left",
                                   iconLeading: true, action: onPrevious)
                        Spacer()
                        stepButton("下一个", systemImage: "chevron.right",
                                   iconLeading: false, action: onNext)
                    }
                }
            }
        }
    }

    // MARK: - 翻到上一个 / 下一个

    /// 图标和文字得自己拼进 HStack：工具栏里直接给 `Label`，
    /// 系统只画图标，`labelStyle` 也压不住（这个坑踩过）。
    private func stepButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        iconLeading: Bool,
        action: (() -> Void)?
    ) -> some View {
        Button {
            action?()
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                if iconLeading { Image(systemName: systemImage) }
                Text(title)
                if !iconLeading { Image(systemName: systemImage) }
            }
            .font(.body)
        }
        .disabled(action == nil)
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
        switch original {
        case .ready(let image):
            GeometryReader { geo in
                // 放大到超过原图分辨率时用最近邻，豆子的边界是硬的；缩小时用默认插值，
                // 否则一像素宽的格线会抖成摩尔纹。
                //
                // 比的是**图真正画出来那块**的宽，不是容器的宽：`scaledToFit` 之后
                // 竖长的图只占容器中间窄窄一条，拿容器宽去比会在其实正在缩小的时候选中
                // 最近邻，摩尔纹照样出来。
                let drawn = min(geo.size.width, geo.size.height * aspect(of: image))
                Image(uiImage: image)
                    .resizable()
                    .interpolation(drawn >= image.size.width ? .none : .high)
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            .padding(Theme.Spacing.sm)
        case .loading:
            ProgressView()
        case .unavailable:
            VStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.title)
                    .foregroundStyle(Theme.ColorToken.Text.tertiary)
                // 「没读出图纸」和「这块抠不出来」对用户是同一件事：别等了。
                // 但必须说成「这次拿不到」而不是转圈 —— 转圈是在让他等一个不会来的东西。
                Text("无法获取该区域的图纸原图，仅显示识别结果")
                    .font(.caption)
                    .foregroundColor(Theme.ColorToken.Text.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(Theme.Spacing.sm)
        }
    }

    private func aspect(of image: UIImage) -> CGFloat {
        guard image.size.height > 0 else { return 1 }
        return image.size.width / image.size.height
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

    /// 回去重对格子。**摆在两张图下面、说明文字上面** —— 用户是先看出不对，
    /// 才需要这个按钮的，摆在他得出结论的那一眼之后。
    @ViewBuilder
    private var regridButton: some View {
        if let onRegrid {
            // **自己关掉自己**，不劳调用方去清那个 item：调用方清了的话，
            // 弹窗还在退场动画里、里面已经没有零件可画，会闪一下空白。
            Button {
                onRegrid()
                dismiss()
            } label: {
                Label("格子没对准，回去重对这一块", systemImage: "grid")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    /// 只有真的有两边可比时才说这句。左边是转圈或者「拿不到」的时候，
    /// 「两边形状对不上」是在让他比一个不存在的东西。
    @ViewBuilder
    private var hint: some View {
        if case .ready = original {
            // 出路在哪儿取决于这一屏是从哪开的：核对颜色那屏上面就摆着按钮，
            // 拼豆板那屏得先回核对颜色。说错一句，用户就在导航栈里白跑一趟。
            Text(onRegrid == nil
                 ? "两侧形状不一致，可能是该零件的格子或颜色识别有误，请返回「核对颜色」页面修改后再摆放"
                 : "两边形状对不上，多半是格线没落在豆子的缝上。按上面那个按钮回去重对，对完这一块的颜色会自动重判一遍。")
                .font(.caption)
                .foregroundColor(Theme.ColorToken.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
