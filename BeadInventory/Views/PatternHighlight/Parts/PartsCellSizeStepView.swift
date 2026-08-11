//
//  PartsCellSizeStepView.swift
//  BeadInventory
//
//  多零件模式 · 第 ③ 屏 - 量一格有多大
//
//  这一屏只回答一个问题：**一格有多大**。有了它，每个零件就能切成整数行列，
//  「这个色号有多少颗、分别是哪几格」才有意义。
//
//  验收标准是眼睛：网格线必须落在豆子和豆子的缝上。所以主体是一个零件的大图 +
//  铺在上面的网格线，对没对齐一眼就知道，不需要用户去理解任何数值。
//
//  ## 两个状态，一次只看一样东西
//
//    看网格   默认。整片网格铺在零件上，用来判断对没对齐；方向键推位置。
//    重选格子 点「重选格子大小」进入。**网格线全部隐藏**，只剩一个黄框 ——
//             要精调一格的大小时，满屏的网格线只会碍事。
//
//  重选态里框就是**一格**：像截图软件那样抓住右下角的把手拉伸，抓住框身平移。
//  可以先放大再调（捏合或点 + 按钮）；**放大是以黄框为中心的**，所以框不会跑出
//  视野，也就不需要拖动画布 —— 拖把手时整张图跟着动是最让人恼火的事。
//
//  两条踩过的坑，不要再回去：
//
//  - **徒手拖一个框**（拖到哪算哪）。一格在屏幕上撑死三十几点，手指落点差三五点
//    就是 10% 的格距误差，铺到第 40 格偏出去 4 格；而且拖完只能重拖，没法在原来的
//    基础上修一点点。把手可以反复微调，是完全不同的东西。
//  - **让用户填「横多少格、竖多少格」**。用户不可能去数四十几个格子。
//
//  位置的微调交给四个方向键，一次推一个源图像素 —— 这个同样不该靠手指去蹭。
//

import SwiftUI

struct PartsCellSizeStepView: View {
    let work: PartsWorkImage
    /// 可写：这屏点出来的网格要写回零件，判色时不再自动重贴
    @Binding var parts: [BeadPart]
    @Binding var calibration: PartsGridCalibration?
    let onContinue: () -> Void

    /// 当前正在看哪个零件（按面积从大到小）。大零件格线多，最容易看出没对齐。
    @State private var sampleIndex = 0
    @State private var sampleImage: UIImage?
    /// 画布画的是整张图纸的哪一块（归一化）
    @State private var sampleRegion: CGRect = .zero
    /// 「一格」那个框的左上角，归一化（相对整张图纸）。网格从这里往四周铺。
    @State private var anchor: CGPoint = .zero
    @State private var estimating = true
    /// 是不是正在重选一格的大小。true 时只显示黄框，不显示网格线。
    @State private var picking = false

    /// 只为看清细节的缩放，不参与任何计算。缩放以黄框为中心。
    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1

    private var samples: [BeadPart] {
        parts.sorted { $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height }
            .prefix(12).map { $0 }
    }

    private var sample: BeadPart? {
        guard !samples.isEmpty else { return nil }
        return samples[min(sampleIndex, samples.count - 1)]
    }

    private var sampleIndexInParts: Int? {
        guard let sample else { return nil }
        return parts.firstIndex { $0.id == sample.id }
    }

    /// 按当前格距 + 框的位置铺出来的、覆盖整个零件的网格
    private var grid: PartsGrid? {
        guard let sample, let calibration,
              calibration.cellWidth > 0, calibration.cellHeight > 0 else { return nil }
        return PartsGrid(covering: sample.bounds, anchor: anchor, calibration: calibration)
    }

    var body: some View {
        VStack(spacing: 0) {
            canvas
            footer
        }
        .navigationTitle("量格子")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: sampleIndex) { await loadSample() }
        .task { await estimateIfNeeded() }
        .onChange(of: anchor) { _, _ in writeBack() }
        .onChange(of: calibration) { _, _ in writeBack() }
    }

    // MARK: - 画布

    private var canvas: some View {
        GeometryReader { geo in
            let display = PartsRegionStepView.aspectFitRect(
                imageSize: sampleImage?.size ?? CGSize(width: 1, height: 1),
                in: geo.size
            )
            ZStack(alignment: .topLeading) {
                Theme.ColorToken.Surface.subtle

                if let sampleImage {
                    Image(uiImage: sampleImage)
                        .resizable()
                        // 像素画放大要用最近邻：插值会把格子边缘糊成渐变，
                        // 用户就没法判断网格线到底压没压在缝上。
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                }

                // 重选大小时把网格线全部收起来 —— 要盯着一格的边看，满屏的线只会碍事
                if let grid, sampleRegion.width > 0, !picking {
                    CellGridOverlay(grid: grid, region: sampleRegion, displayRect: display)
                        .allowsHitTesting(false)
                }

                if picking, calibration != nil, sampleRegion.width > 0, !estimating {
                    CellFrameHandle(
                        anchor: $anchor,
                        calibration: Binding(
                            get: { calibration ?? PartsGridCalibration(cellWidth: 0.01, cellHeight: 0.01) },
                            set: { calibration = $0 }
                        ),
                        region: sampleRegion,
                        displayRect: display,
                        zoom: zoom
                    )
                }

                if estimating {
                    ProgressView("正在量…")
                        .padding()
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            }
            // 以黄框为中心放大：框永远在视野里，用户不需要再去拖画布，
            // 也就不会出现「想调一格，结果整张图跟着跑」。
            .scaleEffect(zoom, anchor: zoomAnchor(in: geo.size, displayRect: display))
            .gesture(
                MagnificationGesture()
                    .onChanged { zoom = max(1, min(10, lastZoom * $0)) }
                    .onEnded { _ in lastZoom = zoom }
            )
        }
        .clipped()
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(spacing: Theme.Spacing.md) {
            if let sample {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(sample.displayName(order: sampleIndex))
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(Theme.ColorToken.Text.primary)
                    if let grid {
                        Text("\(grid.cols) × \(grid.rows) 格")
                            .font(.footnote.monospacedDigit())
                            .foregroundColor(Theme.ColorToken.Text.tertiary)
                    }
                    Spacer()
                    Button {
                        sampleIndex = (sampleIndex + 1) % max(samples.count, 1)
                    } label: {
                        Label("换一个看看", systemImage: "arrow.triangle.2.circlepath")
                            .font(.footnote)
                    }
                    .disabled(samples.count < 2)
                }
            }

            if picking {
                HStack(spacing: Theme.Spacing.md) {
                    Text("放大")
                        .font(.footnote)
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                    nudgeButton("minus.magnifyingglass") { zoomBy(1 / 1.6) }
                    nudgeButton("plus.magnifyingglass") { zoomBy(1.6) }
                    Text(String(format: "%.0f×", zoom))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Theme.ColorToken.Text.tertiary)
                    Spacer()
                    Button {
                        picking = false
                        zoom = 1; lastZoom = 1
                    } label: {
                        Label("就用这个大小", systemImage: "checkmark")
                            .font(.footnote.weight(.medium))
                    }
                }

                Text("黄框就是一格。捏合或点放大先看清楚，再拉右下角的把手改大小、拖框身挪位置。")
                    .font(.footnote)
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: Theme.Spacing.md) {
                    Text("推网格")
                        .font(.footnote)
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                    nudgeButton("chevron.left") { nudge(dx: -1, dy: 0) }
                    nudgeButton("chevron.right") { nudge(dx: 1, dy: 0) }
                    nudgeButton("chevron.up") { nudge(dx: 0, dy: -1) }
                    nudgeButton("chevron.down") { nudge(dx: 0, dy: 1) }
                    Spacer()
                    Button {
                        Task { await autoAlign() }
                    } label: {
                        Label("自动对齐", systemImage: "wand.and.stars").font(.footnote)
                    }
                    .disabled(estimating)
                }

                HStack {
                    Text("网格线要落在豆子和豆子的缝上。")
                        .font(.footnote)
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                    Spacer()
                    Button {
                        picking = true
                    } label: {
                        Label("重选格子大小", systemImage: "square.dashed.inset.filled")
                            .font(.footnote.weight(.medium))
                    }
                    .disabled(estimating)
                }
            }

            Button(action: onContinue) {
                Label("对齐了，看每格什么颜色", systemImage: "eyedropper")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(calibration == nil || estimating || picking)
        }
        .padding()
        .background(.regularMaterial)
    }

    private func nudgeButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.footnote.weight(.bold))
                .frame(width: 36, height: 36)
                .background(Theme.ColorToken.Surface.elevated)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundColor(Theme.ColorToken.Text.primary)
    }

    // MARK: - 逻辑

    /// 放大的锚点 = 黄框中心。这样放得再大框也在视野里，不用再去拖画布。
    private func zoomAnchor(in size: CGSize, displayRect: CGRect) -> UnitPoint {
        guard picking, let calibration, sampleRegion.width > 0, size.width > 0, size.height > 0 else {
            return .center
        }
        let x = displayRect.minX + (anchor.x - sampleRegion.minX) / sampleRegion.width * displayRect.width
            + CGFloat(calibration.cellWidth) / sampleRegion.width * displayRect.width / 2
        let y = displayRect.minY + (anchor.y - sampleRegion.minY) / sampleRegion.height * displayRect.height
            + CGFloat(calibration.cellHeight) / sampleRegion.height * displayRect.height / 2
        return UnitPoint(x: min(max(x / size.width, 0), 1), y: min(max(y / size.height, 0), 1))
    }

    private func zoomBy(_ factor: CGFloat) {
        zoom = max(1, min(10, zoom * factor))
        lastZoom = zoom
    }

    /// 方向键：一次推一个**源图像素**，跟屏幕缩放无关。
    private func nudge(dx: Int, dy: Int) {
        guard let image = sampleImage, image.size.width > 0, image.size.height > 0,
              sampleRegion.width > 0 else { return }
        anchor.x += CGFloat(dx) / image.size.width * sampleRegion.width
        anchor.y += CGFloat(dy) / image.size.height * sampleRegion.height
    }

    private func estimateIfNeeded() async {
        if calibration != nil {
            estimating = false
            await autoAlign()
            return
        }
        let source = work
        let snapshot = parts
        let guessed = await Task.detached(priority: .userInitiated) {
            PartsPitchEstimator.estimate(work: source, parts: snapshot)
        }.value
        // 一个都没量出来时给个保底值：按最大零件横向 12 格算。
        // 宁可给个明显不对的初值让用户去拉，也不要空着让他面对一张没有网格线的图。
        calibration = guessed ?? fallbackCalibration()
        estimating = false
        await autoAlign()
    }

    private func fallbackCalibration() -> PartsGridCalibration? {
        guard let biggest = samples.first else { return nil }
        return PartsGridCalibration(
            cellWidth: Double(biggest.bounds.width) / 12,
            cellHeight: Double(biggest.bounds.height) / 12
        )
    }

    private func loadSample() async {
        guard let sample else { return }
        zoom = 1; lastZoom = 1
        let source = work
        // 四周留一点余量，让用户看得见零件外沿那一圈是不是也被网格线切到了
        let padded = sample.bounds
            .insetBy(dx: -sample.bounds.width * 0.06, dy: -sample.bounds.height * 0.06)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let cropped = await Task.detached(priority: .userInitiated) {
            PartsThumbnailMaker.crop(source, normalized: padded)
        }.value
        sampleImage = cropped
        sampleRegion = padded
        if !estimating { await autoAlign() }
    }

    /// 让算法把网格贴到这个零件上，结果只落到 `anchor` ——
    /// 格距是用户拉出来的，自动对齐不许动它。
    private func autoAlign() async {
        guard let sample, let calibration else { return }
        let source = work
        let fitted = await Task.detached(priority: .userInitiated) {
            PartsPitchEstimator.fitGrid(work: source, part: sample, calibration: calibration)
        }.value
        anchor = fitted?.rect.origin ?? sample.bounds.origin
        writeBack()
    }

    /// 这一屏的结论写回零件本身。判色那步看到零件已经有 gridRect 就直接用，
    /// 不再自动重贴 —— 手动调过的不该被覆盖。
    private func writeBack() {
        guard let grid, let index = sampleIndexInParts else { return }
        parts[index].gridRect = grid.rect
        parts[index].rows = grid.rows
        parts[index].cols = grid.cols
    }
}

// MARK: - 从「一格」推出整片网格

/// 按格距和「一格」的位置，铺出覆盖整个零件的网格。
///
/// 用户只负责说清楚一格多大、在哪；行列数是算出来的，不用他数。
struct PartsGrid: Equatable {
    var rect: CGRect
    var rows: Int
    var cols: Int

    init(covering bounds: CGRect, anchor: CGPoint, calibration: PartsGridCalibration) {
        let cw = CGFloat(calibration.cellWidth)
        let ch = CGFloat(calibration.cellHeight)
        /// 从 anchor 往回退整数格，退到刚好盖住 bounds 的那一侧
        func start(_ anchorValue: CGFloat, _ lower: CGFloat, _ pitch: CGFloat) -> CGFloat {
            guard pitch > 0 else { return lower }
            let stepsBack = max(0, ((anchorValue - lower) / pitch).rounded(.up))
            return anchorValue - stepsBack * pitch
        }
        let x = start(anchor.x, bounds.minX, cw)
        let y = start(anchor.y, bounds.minY, ch)
        cols = max(1, min(400, Int(((bounds.maxX - x) / max(cw, 0.0001)).rounded(.up))))
        rows = max(1, min(400, Int(((bounds.maxY - y) / max(ch, 0.0001)).rounded(.up))))
        rect = CGRect(x: x, y: y, width: CGFloat(cols) * cw, height: CGFloat(rows) * ch)
    }
}

// MARK: - 「一格」那个框

private struct CellFrameHandle: View {
    @Binding var anchor: CGPoint
    @Binding var calibration: PartsGridCalibration
    let region: CGRect
    let displayRect: CGRect
    /// 画布当前的放大倍数。手势的位移是屏幕坐标，必须除掉它才对得上图上的距离 ——
    /// 否则放大 4 倍时手指移 40pt，框会跑 4 倍远。
    let zoom: CGFloat

    @State private var dragStartAnchor: CGPoint?
    @State private var dragStartSize: CGSize?

    private var frame: CGRect {
        CGRect(
            x: displayRect.minX + (anchor.x - region.minX) / region.width * displayRect.width,
            y: displayRect.minY + (anchor.y - region.minY) / region.height * displayRect.height,
            width: CGFloat(calibration.cellWidth) / region.width * displayRect.width,
            height: CGFloat(calibration.cellHeight) / region.height * displayRect.height
        )
    }

    var body: some View {
        let f = frame
        ZStack(alignment: .topLeading) {
            // 框身：拖它 = 挪位置
            Rectangle()
                .strokeBorder(Theme.ColorToken.Morandi.honey, lineWidth: 2)
                .background(Rectangle().fill(Theme.ColorToken.Morandi.honey.opacity(0.2)))
                .frame(width: max(f.width, 10), height: max(f.height, 10))
                .position(x: f.midX, y: f.midY)
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if dragStartAnchor == nil { dragStartAnchor = anchor }
                            guard let start = dragStartAnchor else { return }
                            let scale = max(zoom, 0.0001)
                            anchor = CGPoint(
                                x: start.x + value.translation.width / scale / displayRect.width * region.width,
                                y: start.y + value.translation.height / scale / displayRect.height * region.height
                            )
                        }
                        .onEnded { _ in dragStartAnchor = nil }
                )

            // 右下角把手：拖它 = 改大小。豆子是方的，一个把手同时定两边。
            ZStack {
                Circle().fill(Color.white.opacity(0.001)).frame(width: 56, height: 56)
                Circle()
                    .fill(Theme.ColorToken.Morandi.honey)
                    .frame(width: 22, height: 22)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
            }
            .contentShape(Circle().scale(2))
            .position(x: f.maxX, y: f.maxY)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStartSize == nil {
                            dragStartSize = CGSize(width: calibration.cellWidth, height: calibration.cellHeight)
                        }
                        guard let start = dragStartSize, displayRect.width > 0, displayRect.height > 0 else { return }
                        // 横竖各拉了多少，换算成比例后取平均 —— 保证格子始终是方的
                        let viewScale = max(zoom, 0.0001)
                        let dx = value.translation.width / viewScale / displayRect.width * region.width
                        let dy = value.translation.height / viewScale / displayRect.height * region.height
                        let scaleX = (CGFloat(start.width) + dx) / max(CGFloat(start.width), 0.0001)
                        let scaleY = (CGFloat(start.height) + dy) / max(CGFloat(start.height), 0.0001)
                        let scale = max(0.2, min(5, (scaleX + scaleY) / 2))
                        calibration = PartsGridCalibration(
                            cellWidth: start.width * Double(scale),
                            cellHeight: start.height * Double(scale)
                        )
                    }
                    .onEnded { _ in dragStartSize = nil }
            )
        }
    }
}

// MARK: - 网格线

private struct CellGridOverlay: View {
    let grid: PartsGrid
    /// 画布上画的是整张图纸的哪一块（归一化）
    let region: CGRect
    let displayRect: CGRect

    var body: some View {
        Canvas { context, _ in
            guard grid.rows > 0, grid.cols > 0,
                  region.width > 0, region.height > 0,
                  displayRect.width > 0 else { return }

            func screenX(_ normalized: CGFloat) -> CGFloat {
                displayRect.minX + (normalized - region.minX) / region.width * displayRect.width
            }
            func screenY(_ normalized: CGFloat) -> CGFloat {
                displayRect.minY + (normalized - region.minY) / region.height * displayRect.height
            }

            let cw = grid.rect.width / CGFloat(grid.cols)
            let ch = grid.rect.height / CGFloat(grid.rows)
            let top = screenY(grid.rect.minY), bottom = screenY(grid.rect.maxY)
            let left = screenX(grid.rect.minX), right = screenX(grid.rect.maxX)

            for c in 0...grid.cols {
                var path = Path()
                let x = screenX(grid.rect.minX + CGFloat(c) * cw)
                path.move(to: CGPoint(x: x, y: top))
                path.addLine(to: CGPoint(x: x, y: bottom))
                context.stroke(path, with: .color(.cyan.opacity(0.85)), lineWidth: 1)
            }
            for r in 0...grid.rows {
                var path = Path()
                let y = screenY(grid.rect.minY + CGFloat(r) * ch)
                path.move(to: CGPoint(x: left, y: y))
                path.addLine(to: CGPoint(x: right, y: y))
                context.stroke(path, with: .color(.cyan.opacity(0.85)), lineWidth: 1)
            }
        }
    }
}
