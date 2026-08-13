//
//  SinglePatternGridStepView.swift
//  BeadInventory
//
//  单图纸模式 · 量格子（第二屏；整条流程的屏序见 SinglePatternFlowView 的头注释）
//
//  这一屏定下整张图纸的格子：**方框框住的那一块，横竖各切成多少格**。
//
//  ## 为什么是「框 + 格数」，不是「格距 + 相位」
//
//  上一版是照搬多零件那屏的做法：量出一个格距，让格线以这个格距无限铺开，用户推相位。
//  在零件上没问题（一个零件十来格），在整张图纸上是错的 ——
//
//    格距只要差 1%，铺到第 30 格就偏出去三分之一格，第 60 格偏出去大半格。
//    而用户能看见的只有屏幕上那七八列：**局部对得严丝合缝，整张已经歪了**。
//    他按下「对齐了」，到核对颜色那屏才发现每一格都取了相邻四格的一角。
//
//  现在反过来：网格的外框**就是用户拖的那个方框**，里面等分。于是
//
//    - 画在屏幕上的网格、判色时切的格子、核对页抠的每一格，**是同一个矩形等分出来的**，
//      三者在数学上不可能对不上（上一版它们各自从格距推，就有对不上的空间）；
//    - 误差不再累积。框的两个角对准了，中间每一条线自动就对；
//    - 用户能验：把框的角拖到网格最外圈那一格的外角上 —— 这是他一眼能判断的事，
//      而「格距是不是 32.02 像素」不是。
//
//  ## 用户要做的两件事
//
//    对角   把方框的左上 / 右下两个角拖到网格最外圈。「看左上角 / 看右下角」两个按钮
//           直接把画面跳过去放大 —— 不给这个，用户只能自己在放大的图上找角，
//           而歪掉的恰恰就是他没看到的那一头。
//    数对   横竖各多少格。数是自动量出来的，用户**不用去数** —— 只在最后一条线明显
//           偏了半格时点一下 ±1（差一格是最常见的偏差，也一眼看得出来）。
//

import SwiftUI

struct SinglePatternGridStepView: View {
    let work: PartsWorkImage
    /// 网格的外框 = 用户拖的方框。这一屏可以接着改它 —— 上一屏是粗框，这里对角。
    @Binding var roi: CGRect
    /// 整张图纸当成一块。量出来的行列 / 格子范围直接写回它。
    @Binding var sheet: BeadPart
    /// 存盘用的格子标定。这一屏**由框和格数推出来**，不再是它推网格。
    @Binding var calibration: PartsGridCalibration?
    let onContinue: () -> Void

    @State private var cols = 0
    @State private var rows = 0
    @State private var estimating = true

    @State private var image: UIImage?
    /// 画布上画的是整张图纸的哪一块（归一化）。就是工作图自己那块，
    /// 它比方框大一圈 —— 不然用户没法把框往外拖。
    @State private var region: CGRect = .zero
    @State private var canvasSize: CGSize = .zero

    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var lastPan: CGSize = .zero
    @State private var pinchScreenPoint: CGPoint = .zero
    @State private var pinchContentAnchor: CGPoint?

    /// 这一次单指拖动在干什么。落指的位置决定，中途不变。
    private enum DragMode { case pan, topLeft, bottomRight }
    @State private var dragMode: DragMode?
    @State private var dragStartROI: CGRect = .zero

    /// 框的最小边长（归一化）。再小就不是一张图纸了，也容易误拖成一个点。
    private static let minSide: CGFloat = 0.02
    /// 行列数的上下限。上限跟 `PartsGrid` 一致 —— 再多的格子逐格判色也扛不住。
    private static let countRange = 1...400

    private var displayRect: CGRect {
        PartsRegionStepView.aspectFitRect(
            imageSize: image?.size ?? CGSize(width: 1, height: 1), in: canvasSize
        )
    }

    private var transform: PartsCanvasTransform {
        PartsCanvasTransform(region: region, display: displayRect,
                             size: canvasSize, zoom: zoom, pan: pan)
    }

    /// 屏幕上画的网格。**外框就是 roi，里面等分** —— 跟判色、核对页用的是同一套。
    private var grid: PartsGrid? {
        guard rows > 0, cols > 0, roi.width > 0, roi.height > 0 else { return nil }
        return PartsGrid(rect: roi, rows: rows, cols: cols)
    }

    var body: some View {
        VStack(spacing: 0) {
            canvas
            footer
        }
        .navigationTitle("量格子")
        .navigationBarTitleDisplayMode(.inline)
        // 工作图也算进 id：进来时先拿到的是低清兜底版，高清版在后台裁好之后才换上来。
        .task(id: "\(work.image.size)|\(work.region)") { await load() }
        .onChange(of: roi) { _, _ in writeBack() }
        .onChange(of: cols) { _, _ in writeBack() }
        .onChange(of: rows) { _, _ in writeBack() }
    }

    // MARK: - 画布

    private var canvas: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Theme.ColorToken.Surface.subtle

                if let image, canvasSize.width > 0, region.width > 0 {
                    // 按放大后的尺寸直接摆图，**不用 scaleEffect** —— 那是图层变换，
                    // 放大走双线性平滑，`.interpolation(.none)` 管不到它，而这一屏
                    // 要看的恰恰是豆子边界。
                    let box = transform.screenRect(region)
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)

                    if let grid, !estimating {
                        CellGridOverlay(grid: grid, transform: transform)
                            .allowsHitTesting(false)
                    }
                    GridFrameOverlay(rect: transform.screenRect(roi))
                        .allowsHitTesting(false)
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
            .onAppear {
                canvasSize = geo.size
                focusIfTooDense()
            }
            .onChange(of: geo.size) { _, new in canvasSize = new }
        }
        .clipped()
    }

    /// 落指的位置决定这一拖是「拖角」还是「移动图片」——
    /// 用户不用先切模式，也不会出现「想移动图片结果把框拽跑了」。
    private var gestureCatcher: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                SimultaneousGesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if dragMode == nil { beginDrag(at: value.startLocation) }
                            switch dragMode {
                            case .topLeft, .bottomRight:
                                dragCorner(to: value.location)
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
                            zoom = max(1, min(24, lastZoom * value.magnification))
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
        let box = transform.screenRect(roi)
        // 44pt 是 HIG 的最小点击目标；角点本身画成 26pt，热区给足
        let hit: CGFloat = 44
        if hypot(point.x - box.minX, point.y - box.minY) <= hit {
            dragMode = .topLeft
        } else if hypot(point.x - box.maxX, point.y - box.maxY) <= hit {
            dragMode = .bottomRight
        } else {
            dragMode = .pan
            return
        }
        dragStartROI = roi
    }

    private func dragCorner(to point: CGPoint) {
        let n = transform.normalized(point)
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        switch dragMode {
        case .topLeft:
            let x = min(max(n.x, 0), dragStartROI.maxX - Self.minSide)
            let y = min(max(n.y, 0), dragStartROI.maxY - Self.minSide)
            roi = CGRect(x: x, y: y,
                         width: dragStartROI.maxX - x, height: dragStartROI.maxY - y).intersection(unit)
        case .bottomRight:
            let x = max(min(n.x, 1), dragStartROI.minX + Self.minSide)
            let y = max(min(n.y, 1), dragStartROI.minY + Self.minSide)
            roi = CGRect(x: dragStartROI.minX, y: dragStartROI.minY,
                         width: x - dragStartROI.minX, height: y - dragStartROI.minY).intersection(unit)
        default:
            break
        }
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.lg) {
                countStepper(title: "横", value: $cols)
                countStepper(title: "竖", value: $rows)
            }

            Text("把方框的两个角拖到网格最外圈那一格的外角上，中间的线会自动等分。最后一条线偏了半格，就把格数 ±1。")
                .font(.footnote)
                .foregroundStyle(Theme.ColorToken.Text.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Theme.Spacing.md) {
                // 歪掉的永远是没看到的那一头，所以这两个按钮不是方便，是必需
                Button { focus(on: CGPoint(x: roi.minX, y: roi.minY)) } label: {
                    Label("看左上角", systemImage: "arrow.up.left").font(.footnote)
                }
                Button { focus(on: CGPoint(x: roi.maxX, y: roi.maxY)) } label: {
                    Label("看右下角", systemImage: "arrow.down.right").font(.footnote)
                }
                Button {
                    Task { await estimate() }
                } label: {
                    Label("重新量", systemImage: "wand.and.stars").font(.footnote)
                }
                .disabled(estimating)
            }

            Button(action: onContinue) {
                Label("对齐了，看每格什么颜色", systemImage: "eyedropper")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(estimating || grid == nil)
        }
        .padding()
        .background(.regularMaterial)
    }

    private func countStepper(title: LocalizedStringKey, value: Binding<Int>) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(Theme.ColorToken.Text.secondary)
            stepButton("minus") {
                value.wrappedValue = max(Self.countRange.lowerBound, value.wrappedValue - 1)
            }
            Text("\(value.wrappedValue)")
                .font(.title3.monospacedDigit().weight(.medium))
                .foregroundStyle(Theme.ColorToken.Text.primary)
                .frame(minWidth: 44)
            stepButton("plus") {
                value.wrappedValue = min(Self.countRange.upperBound, value.wrappedValue + 1)
            }
            Text("格")
                .font(.footnote)
                .foregroundStyle(Theme.ColorToken.Text.secondary)
        }
        .disabled(estimating)
    }

    private func stepButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.subheadline.weight(.bold))
                // 44pt 是 HIG 的最小点击目标
                .frame(width: 44, height: 44)
                .background(Theme.ColorToken.Surface.elevated)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundColor(Theme.ColorToken.Text.primary)
    }

    // MARK: - 视图变换

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

    /// 一格在屏幕上太小就先替用户放大到看得清。整张图纸铺满手机屏时一格只有五六个点，
    /// 而这一屏要判断的是「线有没有落在缝上」，看不清就等于没法验收。
    private func focusIfTooDense() {
        guard zoom == 1, let grid, displayRect.width > 0, region.width > 0, canvasSize.width > 0 else { return }
        let cellPoints = roi.width / CGFloat(grid.cols) / region.width * displayRect.width
        guard cellPoints > 0, cellPoints < 12 else { return }
        setZoom(min(24, 20 / cellPoints), centeredOn: CGPoint(x: roi.minX, y: roi.minY))
    }

    /// 把图纸上某个点挪到屏幕正中，并放大到一格看得清。
    private func focus(on point: CGPoint) {
        guard let grid, displayRect.width > 0, region.width > 0, canvasSize.width > 0 else { return }
        let cellPoints = roi.width / CGFloat(grid.cols) / region.width * displayRect.width
        let target = cellPoints > 0 ? max(zoom, min(24, 34 / cellPoints)) : zoom
        withAnimation(.easeInOut(duration: 0.25)) {
            setZoom(target, centeredOn: point)
        }
    }

    private func setZoom(_ newZoom: CGFloat, centeredOn point: CGPoint) {
        zoom = max(1, newZoom)
        lastZoom = zoom
        let flat = PartsCanvasTransform(region: region, display: displayRect,
                                        size: canvasSize, zoom: zoom, pan: .zero)
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let screen = flat.screen(point)
        pan = clampPan(CGSize(width: center.x - screen.x, height: center.y - screen.y))
        lastPan = pan
    }

    // MARK: - 逻辑

    private func load() async {
        let source = work
        let visible = source.region
        let cropped = await Task.detached(priority: .userInitiated) {
            PartsThumbnailMaker.crop(source, normalized: visible)
        }.value
        guard !Task.isCancelled else { return }
        image = cropped
        region = visible

        // 已经有格数了（上次做过 / 这次量过）就照用，**不重新量** ——
        // 重量一次就等于把用户上次对好的角和格数推翻一遍。
        if sheet.rows > 0, sheet.cols > 0, calibration?.isUsable == true {
            rows = sheet.rows
            cols = sheet.cols
            estimating = false
            focusIfTooDense()
            return
        }
        await estimate()
        focusIfTooDense()
    }

    /// 量一次「一格多大」，换算成框里横竖各多少格。
    ///
    /// 只用来**给个初值**：格数是整数，量出来的格距差个百分之一也还是同一个整数，
    /// 所以这一步不准也不要紧 —— 真正定生死的是框的两个角（见文件头）。
    private func estimate() async {
        let source = work
        let box = roi
        estimating = true
        let measured = await Task.detached(priority: .userInitiated) {
            PartsPitchEstimator.estimateLattice(
                work: source, parts: [BeadPart(rowBand: 0, bounds: box)]
            )
        }.value
        guard !Task.isCancelled else { return }
        estimating = false
        // 量不出来（图上没有规则格线）时按横 30 格给个明显能看出对不对的初值，
        // 总好过空着让用户面对一张没有网格线的图。
        let fallback = Double(box.width) / 30
        let cw = measured.map(\.cellWidth) ?? fallback
        let ch = measured.map(\.cellHeight) ?? fallback * aspectOfCellHeight
        cols = clampCount(Double(box.width) / max(cw, 1e-6))
        rows = clampCount(Double(box.height) / max(ch, 1e-6))
        writeBack()
    }

    /// 图纸整张的像素宽高比。归一化坐标把宽和高各自摊到 0~1，所以
    /// 一格是正方形 ⟺ `cellHeight == cellWidth * 这个比值`。
    private var aspectOfCellHeight: Double {
        guard work.region.width > 0, work.region.height > 0 else { return 1 }
        let w = Double(work.image.size.width) / Double(work.region.width)
        let h = Double(work.image.size.height) / Double(work.region.height)
        guard w > 0, h > 0 else { return 1 }
        return w / h
    }

    private func clampCount(_ value: Double) -> Int {
        let rounded = Int(value.rounded())
        return min(max(rounded, Self.countRange.lowerBound), Self.countRange.upperBound)
    }

    /// 把这一屏的结论写回图纸：格子范围**就是方框**，行列就是这两个数。
    ///
    /// `calibration` 在这里是**推出来的**（框宽 ÷ 格数），存下来只是为了让下次进来知道
    /// 一格多大；它不再反过来决定网格 —— 上一版就是让它决定网格，才有了
    /// 「画的和切的对不上」（见文件头）。
    ///
    /// 行列数一变就把判过的颜色扔掉：那些格子是按旧行列数存的，留着的话下游是 clamp
    /// 不是报错，结果不是崩，是每一格的颜色整体错位，而用户什么提示都没有。
    private func writeBack() {
        guard rows > 0, cols > 0, roi.width > 0, roi.height > 0 else { return }
        if sheet.hasCells, sheet.rows != rows || sheet.cols != cols {
            sheet.cells = []
        }
        sheet.bounds = roi
        sheet.gridRect = roi
        sheet.rows = rows
        sheet.cols = cols
        calibration = PartsGridCalibration(
            cellWidth: Double(roi.width) / Double(cols),
            cellHeight: Double(roi.height) / Double(rows),
            originX: Double(roi.minX),
            originY: Double(roi.minY)
        )
    }
}

// MARK: - 外框

/// 网格的外框 + 两个可以拖的角。框身不给拖 —— 这一屏要的是把角对准，
/// 整体挪框是上一屏的事，两个动作放一起只会互相误触。
private struct GridFrameOverlay: View {
    let rect: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(Theme.ColorToken.Morandi.honey, lineWidth: 2)
                .frame(width: max(rect.width, 4), height: max(rect.height, 4))
                .position(x: rect.midX, y: rect.midY)

            corner.position(x: rect.minX, y: rect.minY)
            corner.position(x: rect.maxX, y: rect.maxY)
        }
    }

    private var corner: some View {
        Circle()
            .fill(Theme.ColorToken.Status.error.opacity(0.9))
            .frame(width: 26, height: 26)
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
    }
}
