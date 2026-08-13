//
//  PartsCellSizeStepView.swift
//  BeadInventory
//
//  多零件模式 · 量格子（第三屏；整条流程的屏序见 PartsSheetFlowView 的头注释）
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
//  在哪个零件上调都一样，调完所有零件一起对齐。
//
//  但「一起对齐」不等于「一眼就能确认」：自动量出来的格距差千分之几，铺到某个零件上
//  就偏了半格，而偏的是哪几个只有挨个看过去才知道。所以主按钮是「对齐了，看下一个」，
//  一个零件一个零件地过；不想看完的随时可以「不看了，完成」。
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
    /// 上一次「全图重新对齐」用的是多大的格子。用来判断格距有没有变过 ——
    /// 见 `realignAllIfCellSizeChanged`。
    @State private var alignedAtCellWidth: Double?

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

    /// 拿来验收的零件，按面积从大到小最多十二个。大零件格线多、偏了最容易看出来；
    /// 五十个零件全过一遍没人受得了，而全图共用一张网格，看完最大的这批就够下结论。
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
        // 工作图也算进 id：进来时先拿到的是低清兜底版，高清版在后台裁好之后才换上来。
        .task(id: "\(sampleIndex)|\(work.image.size)") { await loadSample() }
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
                    // 还剩几个要看。一个一个过的时候，「还有多少」是唯一会让人
                    // 愿意继续按下去的信息 —— 不写的话按第三下就开始怀疑没有尽头。
                    Text("\(sampleIndex + 1) / \(samples.count)")
                        .font(.footnote.monospacedDigit())
                        .foregroundColor(Theme.ColorToken.Text.tertiary)
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
                        Task { await realignAllIfCellSizeChanged() }
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
                HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                    nudgePad
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text("网格线要落在豆子和豆子的缝上。")
                            .font(.footnote)
                            .foregroundStyle(Theme.ColorToken.Text.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        // 一格多少像素，加减号一次动一个像素。
                        //
                        // **必须摆在这一屏**（整张网格铺在零件上的这一屏），不能塞进
                        // 「重选格子大小」里 —— 那屏只显示一格。一格看着严丝合缝，
                        // 铺到第四十格照样偏出去半格；格距准不准只有看着整片格线才判断得了，
                        // 那就得能一边看着整片一边调。
                        HStack(spacing: Theme.Spacing.sm) {
                            Text("一格")
                                .font(.footnote)
                                .foregroundStyle(Theme.ColorToken.Text.secondary)
                            nudgeButton("minus") { changeCellPixels(by: -1) }
                            Text(cellPixelsText)
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(Theme.ColorToken.Text.primary)
                                .frame(minWidth: 64)
                            nudgeButton("plus") { changeCellPixels(by: 1) }
                        }
                        .disabled(estimating || calibration == nil)

                        HStack(spacing: Theme.Spacing.md) {
                            Button {
                                Task { await autoAlign() }
                            } label: {
                                Label("自动对齐", systemImage: "wand.and.stars").font(.footnote)
                            }
                            .disabled(estimating)
                            Button {
                                enterPicking()
                            } label: {
                                Label("重选格子大小", systemImage: "square.dashed.inset.filled")
                                    .font(.footnote)
                            }
                            .disabled(estimating)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }

            // 一个零件一个零件地过：主按钮是「这个对了，换下一个」，不是「离开这一屏」。
            // 自动量出来的网格在个别零件上偏一点是常事，而偏了的那几个只有挨个看过去
            // 才发现得了 —— 早先主按钮直接跳去判色，用户看完第一个就走了。
            Button {
                // 翻页之前先把「这个大小」应用到整张图纸 —— 否则用户在这个零件上调准了，
                // 下一个零件还是按旧格线画的，他会以为白调了。
                Task {
                    await realignAllIfCellSizeChanged()
                    if isLastSample { onContinue() } else { sampleIndex += 1 }
                }
            } label: {
                Label(isLastSample ? "对齐了，看每格什么颜色" : "对齐了，看下一个",
                      systemImage: isLastSample ? "eyedropper" : "arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(calibration == nil || estimating || picking)

            // 剩下的不想一个个看了，随时能走。最后一个零件上不显示 —— 那时它和上面
            // 那个按钮是同一件事，摆两个只会让人以为有区别。
            if !isLastSample {
                Button("不看了，完成", action: onContinue)
                    .font(.footnote)
                    .foregroundColor(Theme.ColorToken.Text.secondary)
                    .disabled(calibration == nil || estimating || picking)
            }
        }
        .padding()
        .background(.regularMaterial)
    }

    /// 是不是最后一个要看的零件
    private var isLastSample: Bool { sampleIndex >= samples.count - 1 }

    /// 方向键摆成十字。原先四个键排成一行，上下左右全靠图标区分 ——
    /// 想往上推一格得先在四个一模一样的小圆里找哪个是「上」，找到了还按不准。
    /// 摆成十字之后位置就是含义，手指按哪边网格就往哪边走。
    private var nudgePad: some View {
        VStack(spacing: 4) {
            nudgeButton("chevron.up") { nudge(dx: 0, dy: -1) }
            HStack(spacing: 4) {
                nudgeButton("chevron.left") { nudge(dx: -1, dy: 0) }
                Text("推\n网格")
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.ColorToken.Text.tertiary)
                    .frame(width: 44, height: 44)
                nudgeButton("chevron.right") { nudge(dx: 1, dy: 0) }
            }
            nudgeButton("chevron.down") { nudge(dx: 0, dy: 1) }
        }
    }

    private func nudgeButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.subheadline.weight(.bold))
                // 44pt 是 HIG 的最小点击目标。原先 36pt 四个挤在一行，实测就是按不准。
                .frame(width: 44, height: 44)
                .background(Theme.ColorToken.Surface.elevated)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundColor(Theme.ColorToken.Text.primary)
    }

    // MARK: - 视图变换

    /// 屏幕点 → 缩放前的画布点。只给捏合用：要把手指底下那一点钉在原地，
    /// 得先知道它在「没缩放的画布」上是哪儿。
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
            // 早先横竖两个方向是分开量的，存下来的可能是个长方形。掰回正方形 ——
            // 不掰的话用户在这一屏没有任何办法改：把手只能等比缩放，长方形缩放还是长方形。
            //
            // **但已经判过色的不能动。** 掰正会改掉每个零件的 rows/cols（`writeBack`），
            // 而 `part.cells` 还是按旧行列数存的：下游是 clamp 不是报错，所以结果不是崩，
            // 是底下几行悄悄丢掉、每个格子的叠加层整体错位 —— 用户几天的核对成果。
            // 这种项目要掰正得由他自己按「自动对齐」，那一下是他主动要求重量的。
            if !parts.contains(where: \.hasCells), let fixed = squaredIfNeeded(calibration) {
                self.calibration = fixed
            }
            syncFrameToLattice()
            // 存下来的那份相位就是按这个格距定的（甚至可能是用户手推过的），
            // 不记一笔的话第一次按「看下一个」会被当成「格距变了」，把它自动推回去。
            alignedAtCellWidth = self.calibration?.cellWidth
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
        // 刚量出来的相位就是配这个格距的，不用再重对一遍
        alignedAtCellWidth = calibration?.cellWidth
        syncFrameToLattice()
        writeBack()
    }

    private func fallbackCalibration() -> PartsGridCalibration? {
        guard let biggest = samples.first else { return nil }
        let cell = Double(biggest.bounds.width) / 12
        return PartsGridCalibration(
            cellWidth: cell,
            cellHeight: cell * sheetAspect,
            originX: Double(biggest.bounds.minX),
            originY: Double(biggest.bounds.minY)
        )
    }

    /// 整张图纸有多少像素宽。加减号要按**源图像素**动，不能按屏幕点 ——
    /// 屏幕上一格多大取决于当前放大了几倍，那是个跟图纸无关的数。
    private var sheetPixelWidth: Double {
        guard work.region.width > 0 else { return 0 }
        return Double(work.image.size.width) / Double(work.region.width)
    }

    /// 一格现在是多少源图像素。故意保留小数：自动量出来的格距本来就是 12.4 这种，
    /// 四舍五入到整数会凭空引入 5% 的误差，而这一屏存在的意义就是消掉这点误差。
    private var cellPixels: Double {
        guard let calibration else { return 0 }
        return calibration.cellWidth * sheetPixelWidth
    }

    private var cellPixelsText: String {
        let px = cellPixels
        guard px > 0 else { return "—" }
        return String(format: px == px.rounded() ? "%.0f 像素" : "%.1f 像素", px)
    }

    /// 加减号：一格的边长加 / 减一个源图像素。豆子是方的，所以高跟着宽走。
    private func changeCellPixels(by delta: Double) {
        guard let calibration, sheetPixelWidth > 0 else { return }
        let next = max(2, cellPixels + delta)
        let width = next / sheetPixelWidth
        self.calibration = PartsGridCalibration(
            cellWidth: width,
            cellHeight: width * sheetAspect,
            originX: calibration.originX,
            originY: calibration.originY
        )
    }

    /// 图纸整张的**像素**宽高比。
    ///
    /// 归一化坐标把宽和高各自摊到 0~1，所以图纸不是正方形时，同一个正方形在两个方向上的
    /// 归一化长度并不相等：一格是正方形 ⟺ `cellHeight == cellWidth * sheetAspect`。
    private var sheetAspect: Double {
        guard work.region.width > 0, work.region.height > 0 else { return 1 }
        let w = Double(work.image.size.width) / Double(work.region.width)
        let h = Double(work.image.size.height) / Double(work.region.height)
        guard w > 0, h > 0 else { return 1 }
        return w / h
    }

    /// 已经是正方形就返回 nil（不白改一次、不白存一次），否则以宽为准掰成正方形。
    private func squaredIfNeeded(_ c: PartsGridCalibration) -> PartsGridCalibration? {
        let square = c.cellWidth * sheetAspect
        guard square > 0, abs(c.cellHeight - square) > square * 0.005 else { return nil }
        var fixed = c
        fixed.cellHeight = square
        return fixed
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
        // 裁这一下的工夫用户可能已经点了「对齐了，看下一个」，或者零件区那一版刚换上来 ——
        // 那时上面的 `.task(id:)` 已经把这一轮取消了。不认取消的话，屏幕上显示的是
        // 上一个零件的图，格线却是按新零件算的，用户对着错的图在标定。
        guard !Task.isCancelled else { return }
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

    /// 格子大小改过之后，拿这个新尺寸把**整张图纸**的格线重新找一遍。
    ///
    /// 用户在一个零件上把格子调准了，剩下几十个零件不会自己变准 —— 它们的格子位置是
    /// 从同一张全局网格推出来的（`PartsGrid` 把 bounds 吸到全局格线上），格距一变，
    /// 那批格线该落在哪儿就得重算。不重算的话用户看到的是「我明明调对了，下一个还是偏」。
    ///
    /// 只在**格子大小**变过时才跑：
    /// - 格距没变就没什么可重算的，每按一次「看下一个」都重跑一遍纯属让人等；
    /// - 而且这里只重找相位。用户拿方向键手推过格线的话，再跑一次自动定相位会把他
    ///   刚推的推回去 —— 大小没变时绝不能碰。
    private func realignAllIfCellSizeChanged() async {
        guard let calibration, calibration.isUsable else { return }
        guard alignedAtCellWidth != calibration.cellWidth else { return }
        let source = work
        let snapshot = parts
        estimating = true
        let fitted = await Task.detached(priority: .userInitiated) {
            PartsPitchEstimator.fitOrigin(work: source, parts: snapshot, calibration: calibration)
        }.value
        estimating = false
        alignedAtCellWidth = calibration.cellWidth
        // 找不到就保持原样：格距是用户定的，位置维持现状总好过跳到一个瞎猜的地方。
        guard let fitted else { return }
        self.calibration?.originX = Double(fitted.x)
        self.calibration?.originY = Double(fitted.y)
        syncFrameToLattice()
        writeBack()
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
        // 这一下本来就是「格距和相位一起重来」，重对过了
        alignedAtCellWidth = self.calibration?.cellWidth
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
/// **谁都不用 `scaleEffect`。** 图片和覆盖层各自按这里算出来的屏幕矩形直接摆
/// （`.frame` + `.position`），放大只是算出一个更大的 frame。
/// 用 scaleEffect 的话像素画会被图层变换双线性平滑掉，`.interpolation(.none)` 管不到它
/// —— 而这一屏要看的恰恰是豆子边界（见本文件里 canvas 那段注释）；
/// 手势拿到的也永远是真实屏幕点，两边这样才对得上。
///
/// `zoom` / `pan` 就是在这个换算里生效的：先按 `region → display` 摊平，
/// 再绕画布中心放大 `zoom` 倍、平移 `pan`。
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

    /// `screen(_:)` 的逆：屏幕点 → 归一化坐标（相对整张图纸）
    func normalized(_ screenPoint: CGPoint) -> CGPoint {
        guard display.width > 0, display.height > 0, zoom > 0 else { return .zero }
        let flat = CGPoint(x: center.x + (screenPoint.x - pan.width - center.x) / zoom,
                           y: center.y + (screenPoint.y - pan.height - center.y) / zoom)
        return CGPoint(x: region.minX + (flat.x - display.minX) / display.width * region.width,
                       y: region.minY + (flat.y - display.minY) / display.height * region.height)
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
