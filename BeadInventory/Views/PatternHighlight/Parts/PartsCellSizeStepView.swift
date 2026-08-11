//
//  PartsCellSizeStepView.swift
//  BeadInventory
//
//  多零件模式 · 第 ③ 屏 - 量格子
//
//  这一屏只回答一个问题：**格子多大、格线在哪**。有了它，每个零件就能切成整数行列，
//  「这个色号有多少颗、分别是哪几格」才有意义。
//
//  验收标准是眼睛：网格线必须落在豆子和豆子的缝上。所以主体是一个零件的大图 +
//  铺在上面的网格线，对没对齐一眼就知道，不需要用户去理解任何数值。
//
//  ## 全图只有一张网格
//
//  几十个零件是从同一张像素画上切下来的，格子多大、格线在哪，全图是同一个答案。
//  所以这一屏调的**永远是那一张网格**（`PartsGridCalibration`，带全局格线位置），
//  在哪个零件上调都一样，调完所有零件一起对齐 —— 「换一个看看」是用来验收的，
//  不是让用户一个一个重调的。
//
//  早先格线位置是每个零件自己的 bbox 均分出来的，于是「这个对齐了、换一个又对不上」，
//  用户得挨个重来。那是错的：bbox 带一圈抗锯齿毛边，每个零件毛边多少不一样。
//
//  ## 两个状态，一次只看一样东西
//
//    看网格   默认。整片网格铺在零件上，用来判断对没对齐；方向键整体推格线。
//    重选格子 点「重选格子大小」进入。**网格线全部隐藏**，只剩一个黄框 ——
//             要精调一格的大小时，满屏的网格线只会碍事。
//
//  重选态里框就是**一格**，像截图软件那样：拖框身平移、拖右下角的把手改大小。
//  进这个状态会自动放大到一格有近百点，手指才够得着；空白处单指拖动是移动图片，
//  两指捏合放大 —— 跟「找零件」那屏一个规矩。
//
//  两条踩过的坑，不要再回去：
//
//  - **徒手拖一个框**（拖到哪算哪）。一格在屏幕上撑死三十几点，手指落点差三五点
//    就是 10% 的格距误差，铺到第 40 格偏出去 4 格；而且拖完只能重拖，没法在原来的
//    基础上修一点点。把手可以反复微调，是完全不同的东西。
//  - **让用户填「横多少格、竖多少格」**。用户不可能去数四十几个格子。
//

import SwiftUI

struct PartsCellSizeStepView: View {
    let work: PartsWorkImage
    /// 可写：这屏定下来的网格要写回每一个零件
    @Binding var parts: [BeadPart]
    @Binding var calibration: PartsGridCalibration?
    let onContinue: () -> Void

    /// 当前正在看哪个零件（按面积从大到小）。大零件格线多，最容易看出没对齐。
    @State private var sampleIndex = 0
    @State private var sampleImage: UIImage?
    /// 画布画的是整张图纸的哪一块（归一化）
    @State private var sampleRegion: CGRect = .zero
    /// 黄框（也就是「一格」）的左上角，归一化。它同时**就是**全局格线的位置：
    /// 拖它 = 整张网格跟着走。
    @State private var frameOrigin: CGPoint = .zero
    @State private var estimating = true
    /// 是不是正在重选一格的大小。true 时只显示黄框，不显示网格线。
    @State private var picking = false

    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var lastPan: CGSize = .zero
    @State private var pinchScreenPoint: CGPoint = .zero
    @State private var pinchContentAnchor: CGPoint?

    /// 这一次单指拖动在干什么。落指的位置决定，中途不变。
    private enum DragMode { case pan, move, resize }
    @State private var dragMode: DragMode?
    @State private var dragStartOrigin: CGPoint = .zero
    @State private var dragStartCell: CGSize = .zero

    @State private var canvasSize: CGSize = .zero

    private var samples: [BeadPart] {
        parts.sorted { $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height }
            .prefix(12).map { $0 }
    }

    private var sample: BeadPart? {
        guard !samples.isEmpty else { return nil }
        return samples[min(sampleIndex, samples.count - 1)]
    }

    /// 当前零件落在全局网格上的那块（行列数就是从这儿来的）
    private var grid: PartsGrid? {
        guard let sample, let calibration, calibration.isUsable else { return nil }
        return PartsGrid(covering: sample.bounds, calibration: calibration)
    }

    /// 黄框在整张图纸上的归一化矩形
    private var frameRect: CGRect? {
        guard let calibration, calibration.isUsable else { return nil }
        return CGRect(x: frameOrigin.x, y: frameOrigin.y,
                      width: CGFloat(calibration.cellWidth), height: CGFloat(calibration.cellHeight))
    }

    private var displayRect: CGRect {
        PartsRegionStepView.aspectFitRect(
            imageSize: sampleImage?.size ?? CGSize(width: 1, height: 1), in: canvasSize
        )
    }

    private var transform: PartsCanvasTransform {
        PartsCanvasTransform(region: sampleRegion, display: displayRect,
                             size: canvasSize, zoom: zoom, pan: pan)
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
        .onChange(of: frameOrigin) { _, new in
            calibration?.originX = Double(new.x)
            calibration?.originY = Double(new.y)
            writeBack()
        }
        .onChange(of: calibration) { _, _ in writeBack() }
    }

    // MARK: - 画布

    private var canvas: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Theme.ColorToken.Surface.subtle

                if let sampleImage, canvasSize.width > 0, sampleRegion.width > 0 {
                    // 直接按放大后的尺寸摆图，**不用 scaleEffect** ——
                    // scaleEffect 是图层变换，放大时走的是双线性平滑，`.interpolation(.none)`
                    // 管不到它：9 倍下豆子边缘糊成一片渐变，恰恰是这一屏最需要看清的东西。
                    // 自己算尺寸的话，图是按最终大小渲染的，最近邻生效，格子边界是硬的。
                    let box = transform.screenRect(sampleRegion)
                    Image(uiImage: sampleImage)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)
                }

                // 覆盖层不跟着 scaleEffect 走，自己按 transform 算屏幕坐标 ——
                // 这样手势拿到的点和画出来的框在同一套坐标里，放大之后也对得上。
                // （早先整层一起 scaleEffect，手势位移是屏幕点、绘制是缩放前的点，
                // 两边差一个 zoom 倍，放大后拖框就会飞。）
                if sampleRegion.width > 0, canvasSize.width > 0 {
                    if let grid, !picking {
                        CellGridOverlay(grid: grid, transform: transform)
                            .allowsHitTesting(false)
                    }
                    if picking, let frameRect, !estimating {
                        CellFrameOverlay(rect: transform.screenRect(frameRect))
                            .allowsHitTesting(false)
                    }
                }

                gestureCatcher

                if estimating {
                    ProgressView("正在量…")
                        .padding()
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            }
            .onAppear { canvasSize = geo.size }
            .onChange(of: geo.size) { _, new in canvasSize = new }
        }
        .clipped()
    }

    /// 手势层。落指的位置决定这一拖是「挪格子」「改大小」还是「移动图片」——
    /// 用户不用先切模式，也不会出现「想移动图片结果把格子拽跑了」。
    private var gestureCatcher: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                SimultaneousGesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if dragMode == nil { beginDrag(at: value.startLocation) }
                            switch dragMode {
                            case .move:
                                let d = transform.normalizedDelta(value.translation)
                                frameOrigin = CGPoint(x: dragStartOrigin.x + d.width,
                                                      y: dragStartOrigin.y + d.height)
                            case .resize:
                                resize(by: value.translation)
                            default:
                                pan = clampPan(CGSize(width: lastPan.width + value.translation.width,
                                                      height: lastPan.height + value.translation.height))
                            }
                        }
                        .onEnded { _ in
                            if dragMode == .pan { lastPan = pan }
                            dragMode = nil
                        },
                    MagnifyGesture()
                        .onChanged { value in
                            if pinchContentAnchor == nil {
                                pinchScreenPoint = value.startLocation
                                pinchContentAnchor = unzoomed(value.startLocation)
                            }
                            guard let anchor = pinchContentAnchor else { return }
                            zoom = max(1, min(16, lastZoom * value.magnification))
                            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                            pan = clampPan(CGSize(
                                width: pinchScreenPoint.x - center.x - (anchor.x - center.x) * zoom,
                                height: pinchScreenPoint.y - center.y - (anchor.y - center.y) * zoom
                            ))
                        }
                        .onEnded { _ in
                            lastZoom = zoom
                            lastPan = pan
                            pinchContentAnchor = nil
                        }
                )
            )
    }

    private func beginDrag(at point: CGPoint) {
        guard picking, let frameRect else {
            dragMode = .pan
            return
        }
        let screen = transform.screenRect(frameRect)
        let corner = CGPoint(x: screen.maxX, y: screen.maxY)
        if hypot(point.x - corner.x, point.y - corner.y) <= 34 {
            dragMode = .resize
            dragStartCell = CGSize(width: frameRect.width, height: frameRect.height)
        } else if screen.insetBy(dx: -8, dy: -8).contains(point) {
            dragMode = .move
            dragStartOrigin = frameOrigin
        } else {
            dragMode = .pan
        }
    }

    /// 右下角把手：左上角钉住不动，只改大小。豆子是方的，横竖按同一个比例走。
    private func resize(by translation: CGSize) {
        guard dragStartCell.width > 0, dragStartCell.height > 0 else { return }
        let d = transform.normalizedDelta(translation)
        let scaleX = (dragStartCell.width + d.width) / dragStartCell.width
        let scaleY = (dragStartCell.height + d.height) / dragStartCell.height
        let scale = max(0.2, min(5, (scaleX + scaleY) / 2))
        calibration = PartsGridCalibration(
            cellWidth: Double(dragStartCell.width * scale),
            cellHeight: Double(dragStartCell.height * scale),
            originX: Double(frameOrigin.x),
            originY: Double(frameOrigin.y)
        )
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
                        Label("看看别的零件", systemImage: "arrow.triangle.2.circlepath")
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
                        resetView()
                    } label: {
                        Label("就用这个大小", systemImage: "checkmark")
                            .font(.footnote.weight(.medium))
                    }
                }

                Text("黄框就是一格：拖框身挪位置，拖右下角的圆点改大小。空白处拖动是移动图片。")
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

                HStack(alignment: .firstTextBaseline) {
                    Text("网格线要落在豆子和豆子的缝上。全图共用这一张网格，在哪个零件上调都一样。")
                        .font(.footnote)
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Theme.Spacing.sm)
                    Button {
                        enterPicking()
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

    // MARK: - 视图变换

    /// 屏幕点 → 缩放前的画布点（`content(_:)` 的那一半逆变换）
    private func unzoomed(_ point: CGPoint) -> CGPoint {
        guard zoom > 0 else { return point }
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        return CGPoint(x: center.x + (point.x - pan.width - center.x) / zoom,
                       y: center.y + (point.y - pan.height - center.y) / zoom)
    }

    private func clampPan(_ offset: CGSize) -> CGSize {
        let limitX = max(0, (zoom - 1) * canvasSize.width / 2)
        let limitY = max(0, (zoom - 1) * canvasSize.height / 2)
        return CGSize(width: min(max(offset.width, -limitX), limitX),
                      height: min(max(offset.height, -limitY), limitY))
    }

    private func zoomBy(_ factor: CGFloat) {
        zoom = max(1, min(16, zoom * factor))
        lastZoom = zoom
        pan = clampPan(pan)
        lastPan = pan
    }

    private func resetView() {
        zoom = 1; lastZoom = 1
        pan = .zero; lastPan = .zero
    }

    /// 进「重选格子大小」：自动放大到一格有近百点，手指才够得着，再把框挪到屏幕正中。
    /// 不这么做的话，一格在屏幕上只有十来点 —— 把手的热区比整个框还大，
    /// 用户想拖框身永远拖成改大小，也就成了「这个框根本动不了」。
    private func enterPicking() {
        picking = true
        guard let frameRect, displayRect.width > 0, sampleRegion.width > 0 else { return }
        let cellPoints = frameRect.width / sampleRegion.width * displayRect.width
        guard cellPoints > 0 else { return }
        zoom = max(1, min(16, 90 / cellPoints))
        lastZoom = zoom
        let flat = PartsCanvasTransform(region: sampleRegion, display: displayRect,
                                        size: canvasSize, zoom: zoom, pan: .zero)
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let box = flat.screenRect(frameRect)
        pan = clampPan(CGSize(width: center.x - box.midX, height: center.y - box.midY))
        lastPan = pan
    }

    // MARK: - 逻辑

    /// 方向键：整张网格一次推一个**源图像素**，跟屏幕缩放无关。
    private func nudge(dx: Int, dy: Int) {
        guard let image = sampleImage, image.size.width > 0, image.size.height > 0,
              sampleRegion.width > 0 else { return }
        frameOrigin.x += CGFloat(dx) / image.size.width * sampleRegion.width
        frameOrigin.y += CGFloat(dy) / image.size.height * sampleRegion.height
    }

    private func estimateIfNeeded() async {
        if let calibration, calibration.isUsable, calibration.originX > 0 || calibration.originY > 0 {
            estimating = false
            syncFrameToLattice()
            return
        }
        let source = work
        let snapshot = parts
        let measured = await Task.detached(priority: .userInitiated) {
            PartsPitchEstimator.estimateLattice(work: source, parts: snapshot)
        }.value
        // 一个都没量出来时给个保底值：按最大零件横向 12 格算。
        // 宁可给个明显不对的初值让用户去拉，也不要空着让他面对一张没有网格线的图。
        calibration = measured ?? fallbackCalibration()
        estimating = false
        syncFrameToLattice()
        writeBack()
    }

    private func fallbackCalibration() -> PartsGridCalibration? {
        guard let biggest = samples.first else { return nil }
        return PartsGridCalibration(
            cellWidth: Double(biggest.bounds.width) / 12,
            cellHeight: Double(biggest.bounds.height) / 12,
            originX: Double(biggest.bounds.minX),
            originY: Double(biggest.bounds.minY)
        )
    }

    private func loadSample() async {
        guard let sample else { return }
        resetView()
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
        syncFrameToLattice()
    }

    /// 把黄框摆到零件正中那一格。
    ///
    /// 这不改变网格本身 —— 格线是无限铺开的，挑哪一格显示都一样。挑中间那格是因为
    /// 左上角那一格多半压在零件外面的空白上，框里一片粉，看不出格子边界对没对齐。
    private func syncFrameToLattice() {
        guard let sample, let calibration, calibration.isUsable else { return }
        frameOrigin = CGPoint(x: calibration.snappedX(Double(sample.bounds.midX)),
                              y: calibration.snappedY(Double(sample.bounds.midY)))
    }

    /// 重新自动量一次整张图纸的网格 —— 格子多大、格线在哪一起重来。
    ///
    /// 刻意**连格距一起重量**：用户手拉的格子哪怕只大了 1%，铺到第四十格就偏出去
    /// 小半格，这时候光挪位置是救不回来的。既然他按了这个按钮，就是「你帮我弄好」，
    /// 那就不能留一个连按几次都没反应的死角。手量的结果还想要？「重选格子大小」就在旁边。
    /// 量不出来时退回只对位置，至少别把现有的弄坏。
    private func autoAlign() async {
        guard let calibration, calibration.isUsable else { return }
        let source = work
        let snapshot = parts
        let measured = await Task.detached(priority: .userInitiated) {
            PartsPitchEstimator.estimateLattice(work: source, parts: snapshot)
        }.value
        if let measured {
            self.calibration = measured
        } else {
            let fitted = await Task.detached(priority: .userInitiated) {
                PartsPitchEstimator.fitOrigin(work: source, parts: snapshot, calibration: calibration)
            }.value
            guard let fitted else { return }
            self.calibration?.originX = Double(fitted.x)
            self.calibration?.originY = Double(fitted.y)
        }
        syncFrameToLattice()
        writeBack()
    }

    /// 把这张网格套到**每一个**零件上。判色那步直接用这里的结论，不再自己去贴格线。
    private func writeBack() {
        guard let calibration, calibration.isUsable else { return }
        for index in parts.indices {
            let grid = PartsGrid(covering: parts[index].bounds, calibration: calibration)
            parts[index].gridRect = grid.rect
            parts[index].rows = grid.rows
            parts[index].cols = grid.cols
        }
    }
}

// MARK: - 画布坐标换算

/// 归一化坐标（相对整张图纸）↔ 屏幕点。
///
/// 图片是 `.scaleEffect(zoom, anchor: .center).offset(pan)` 画出来的，
/// 覆盖层不跟着缩放、自己算坐标 —— 手势拿到的永远是真实屏幕点，两边才对得上。
struct PartsCanvasTransform {
    /// 画布上画的是整张图纸的哪一块
    let region: CGRect
    /// 缩放前图片占的矩形
    let display: CGRect
    let size: CGSize
    let zoom: CGFloat
    let pan: CGSize

    private var center: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }

    func screen(_ normalized: CGPoint) -> CGPoint {
        guard region.width > 0, region.height > 0 else { return .zero }
        let flat = CGPoint(
            x: display.minX + (normalized.x - region.minX) / region.width * display.width,
            y: display.minY + (normalized.y - region.minY) / region.height * display.height
        )
        return CGPoint(x: center.x + (flat.x - center.x) * zoom + pan.width,
                       y: center.y + (flat.y - center.y) * zoom + pan.height)
    }

    func screenRect(_ normalized: CGRect) -> CGRect {
        let a = screen(normalized.origin)
        let b = screen(CGPoint(x: normalized.maxX, y: normalized.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    /// 手指在屏幕上移了多少 → 图纸上移了多少（归一化）
    func normalizedDelta(_ translation: CGSize) -> CGSize {
        guard display.width > 0, display.height > 0, zoom > 0 else { return .zero }
        return CGSize(width: translation.width / zoom / display.width * region.width,
                      height: translation.height / zoom / display.height * region.height)
    }
}

// MARK: - 网格线

private struct CellGridOverlay: View {
    let grid: PartsGrid
    let transform: PartsCanvasTransform

    var body: some View {
        Canvas { context, _ in
            guard grid.rows > 0, grid.cols > 0 else { return }
            let box = transform.screenRect(grid.rect)
            let cw = box.width / CGFloat(grid.cols)
            let ch = box.height / CGFloat(grid.rows)

            for c in 0...grid.cols {
                var path = Path()
                let x = box.minX + CGFloat(c) * cw
                path.move(to: CGPoint(x: x, y: box.minY))
                path.addLine(to: CGPoint(x: x, y: box.maxY))
                context.stroke(path, with: .color(.cyan.opacity(0.85)), lineWidth: 1)
            }
            for r in 0...grid.rows {
                var path = Path()
                let y = box.minY + CGFloat(r) * ch
                path.move(to: CGPoint(x: box.minX, y: y))
                path.addLine(to: CGPoint(x: box.maxX, y: y))
                context.stroke(path, with: .color(.cyan.opacity(0.85)), lineWidth: 1)
            }
        }
    }
}

// MARK: - 「一格」那个框

private struct CellFrameOverlay: View {
    /// 已经换算好的屏幕矩形
    let rect: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(Theme.ColorToken.Morandi.honey, lineWidth: 2)
                .background(Rectangle().fill(Theme.ColorToken.Morandi.honey.opacity(0.18)))
                .frame(width: max(rect.width, 8), height: max(rect.height, 8))
                .position(x: rect.midX, y: rect.midY)

            Circle()
                .fill(Theme.ColorToken.Morandi.honey)
                .frame(width: 22, height: 22)
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                .position(x: rect.maxX, y: rect.maxY)
        }
    }
}
