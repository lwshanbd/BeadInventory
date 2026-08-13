//
//  SinglePatternGridStepView.swift
//  BeadInventory
//
//  单图纸模式 · 量格子（第二屏；整条流程的屏序见 SinglePatternFlowView 的头注释）
//
//  这一屏只回答一个问题：**格子多大、格线在哪**。答对了，图纸就被切成整数行列，
//  「这个色号有多少颗、分别是哪几格」才有意义。
//
//  验收标准是眼睛：网格线要落在豆子和豆子的缝上。所以主体就是图纸放大之后的样子 +
//  铺在上面的网格线，对没对齐一眼就知道，不需要用户去理解任何数值。
//
//  ## 这里不再让用户填「多少行、多少列」
//
//  上一版这一屏（`PatternCalibrationView`，已删）的主输入是两个数字框：行、列。
//  用户得**数清楚**这张图纸横竖各有多少格 —— 一张 60×80 的图纸，数一遍要好几分钟，
//  数错一格整张图全错，而且错在哪儿他自己看不出来（网格会均匀地偏一点点）。
//
//  现在反过来：用户只调「一格多大」，行列数由格子大小和框住的范围**算出来**。
//  一格是屏幕上看得见的东西，对没对齐也是看得见的；行列数不用他关心。
//
//  ## 两个状态，一次只看一样东西
//
//    看网格   默认。整片网格铺在图纸上，用来判断对没对齐；方向键整体推格线。
//    重选格子 点「重选格子大小」进入。**网格线全部隐藏**，只剩一个黄框 ——
//             要精调一格的大小时，满屏的网格线只会碍事。
//
//  这两条，以及「加减号一次动 0.1 像素」「不用 scaleEffect 放大」的理由，
//  跟多零件模式那屏是同一套，见 `PartsCellSizeStepView` 的头注释。
//

import SwiftUI

struct SinglePatternGridStepView: View {
    let work: PartsWorkImage
    /// 用户裁出来的图纸范围（归一化，相对整张源图）
    let roi: CGRect
    /// 整张图纸当成一块。量出来的行列 / 格子范围直接写回它。
    @Binding var sheet: BeadPart
    @Binding var calibration: PartsGridCalibration?
    let onContinue: () -> Void

    @State private var image: UIImage?
    /// 画布上画的是整张图纸的哪一块（归一化）
    @State private var region: CGRect = .zero
    /// 黄框（也就是「一格」）的左上角，归一化。它同时**就是**格线的位置：拖它 = 整张网格跟着走。
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

    /// 当前这张网格：全局格距 + 用户推到的格线位置
    private var activeCalibration: PartsGridCalibration? {
        guard let calibration, calibration.isUsable else { return nil }
        var c = calibration
        c.originX = Double(frameOrigin.x)
        c.originY = Double(frameOrigin.y)
        return c
    }

    /// 图纸落在这张网格上的那块（行列数就是从这儿来的）
    private var grid: PartsGrid? {
        guard let c = activeCalibration else { return nil }
        return PartsGrid(covering: roi, calibration: c)
    }

    /// 黄框在整张图纸上的归一化矩形
    private var frameRect: CGRect? {
        guard let calibration, calibration.isUsable else { return nil }
        return CGRect(x: frameOrigin.x, y: frameOrigin.y,
                      width: CGFloat(calibration.cellWidth), height: CGFloat(calibration.cellHeight))
    }

    private var displayRect: CGRect {
        PartsRegionStepView.aspectFitRect(
            imageSize: image?.size ?? CGSize(width: 1, height: 1), in: canvasSize
        )
    }

    private var transform: PartsCanvasTransform {
        PartsCanvasTransform(region: region, display: displayRect,
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
        .task(id: "\(roi)|\(work.image.size)") { await load() }
        .onChange(of: frameOrigin) { _, _ in writeBack() }
        .onChange(of: calibration) { _, _ in writeBack() }
    }

    // MARK: - 画布

    private var canvas: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Theme.ColorToken.Surface.subtle

                if let image, canvasSize.width > 0, region.width > 0 {
                    // 按放大后的尺寸直接摆图，**不用 scaleEffect** —— 那是图层变换，
                    // 放大走双线性平滑，`.interpolation(.none)` 管不到它，而这一屏
                    // 要看的恰恰是豆子边界（同 PartsCellSizeStepView）。
                    let box = transform.screenRect(region)
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)
                }

                if region.width > 0, canvasSize.width > 0 {
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
            .onAppear {
                canvasSize = geo.size
                focusIfTooDense()
            }
            .onChange(of: geo.size) { _, new in canvasSize = new }
        }
        .clipped()
    }

    /// 落指的位置决定这一拖是「挪格子」「改大小」还是「移动图片」——
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
                        Task { await autoAlign(keepingCellSize: true) }
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
                        HStack(spacing: Theme.Spacing.sm) {
                            // 行列数是**算出来的**，摆在这儿只是让用户对一眼图纸上写的尺寸。
                            // 它不是输入框：没有人会去数四十几个格子（见头注释）。
                            if let grid {
                                Text("\(grid.cols) × \(grid.rows) 格")
                                    .font(.subheadline.monospacedDigit().weight(.medium))
                                    .foregroundColor(Theme.ColorToken.Text.primary)
                            }
                            Spacer()
                        }

                        Text("网格线要落在豆子和豆子的缝上。")
                            .font(.footnote)
                            .foregroundStyle(Theme.ColorToken.Text.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        // 一格多少像素，加减号一次动 0.1 个像素。**必须摆在这一屏**
                        // （整片网格铺着的这一屏）：一格看着严丝合缝，铺到第四十格照样偏出去半格。
                        HStack(spacing: Theme.Spacing.sm) {
                            Text("一格")
                                .font(.footnote)
                                .foregroundStyle(Theme.ColorToken.Text.secondary)
                            nudgeButton("minus") { changeCellPixels(by: -Self.cellPixelStep) }
                            Text(cellPixelsText)
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(Theme.ColorToken.Text.primary)
                                .frame(minWidth: 78)
                            nudgeButton("plus") { changeCellPixels(by: Self.cellPixelStep) }
                        }
                        .disabled(estimating || calibration == nil)

                        HStack(spacing: Theme.Spacing.md) {
                            Button {
                                Task { await autoAlign(keepingCellSize: false) }
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

            Button(action: onContinue) {
                Label("对齐了，看每格什么颜色", systemImage: "eyedropper")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(calibration == nil || estimating || picking)
        }
        .padding()
        .background(.regularMaterial)
    }

    /// 方向键摆成十字：位置就是含义，手指按哪边网格就往哪边走。
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
    /// 不这么做的话一格在屏幕上只有十来点 —— 把手的热区比整个框还大，
    /// 用户想拖框身永远拖成改大小，也就成了「这个框根本动不了」。
    private func enterPicking() {
        picking = true
        guard let frameRect, displayRect.width > 0, region.width > 0 else { return }
        let cellPoints = frameRect.width / region.width * displayRect.width
        guard cellPoints > 0 else { return }
        zoom = max(1, min(16, 90 / cellPoints))
        lastZoom = zoom
        let flat = PartsCanvasTransform(region: region, display: displayRect,
                                        size: canvasSize, zoom: zoom, pan: .zero)
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let box = flat.screenRect(frameRect)
        pan = clampPan(CGSize(width: center.x - box.midX, height: center.y - box.midY))
        lastPan = pan
    }

    // MARK: - 逻辑

    /// 方向键：整张网格一次推一个**源图像素**，跟屏幕缩放无关。
    private func nudge(dx: Int, dy: Int) {
        guard let image, image.size.width > 0, image.size.height > 0, region.width > 0 else { return }
        frameOrigin.x += CGFloat(dx) / image.size.width * region.width
        frameOrigin.y += CGFloat(dy) / image.size.height * region.height
    }

    private func load() async {
        resetView()
        let source = work
        // 四周留一点余量，让用户看得见图纸最外圈那一格是不是也被网格线切到了
        let padded = roi
            .insetBy(dx: -roi.width * 0.04, dy: -roi.height * 0.04)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let cropped = await Task.detached(priority: .userInitiated) {
            PartsThumbnailMaker.crop(source, normalized: padded)
        }.value
        guard !Task.isCancelled else { return }
        image = cropped
        region = padded
        await estimateIfNeeded()
        focusIfTooDense()
    }

    /// 一格在屏幕上太小就先替用户放大到看得清。
    ///
    /// 一张 60×80 的图纸铺满手机屏幕时，一格只有五六个点，几百条格线糊成一片色 ——
    /// 而这一屏的验收标准恰恰是「格线有没有落在豆子的缝上」。看不清就等于没法验收，
    /// 用户只能对着一片糊按「对齐了」。所以进来就放大到一格十几点、对准图纸正中；
    /// 想看整张随时捏回去。
    private func focusIfTooDense() {
        guard zoom == 1, let calibration, calibration.isUsable,
              displayRect.width > 0, region.width > 0, canvasSize.width > 0 else { return }
        let cellPoints = CGFloat(calibration.cellWidth) / region.width * displayRect.width
        guard cellPoints > 0, cellPoints < 10 else { return }
        zoom = min(16, 16 / cellPoints)
        lastZoom = zoom
        // 对准图纸正中：边角多半是留白，看不出对没对齐
        let flat = PartsCanvasTransform(region: region, display: displayRect,
                                        size: canvasSize, zoom: zoom, pan: .zero)
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let target = flat.screen(CGPoint(x: roi.midX, y: roi.midY))
        pan = clampPan(CGSize(width: center.x - target.x, height: center.y - target.y))
        lastPan = pan
    }

    private func estimateIfNeeded() async {
        if let calibration, calibration.isUsable {
            estimating = false
            // 早先横竖两个方向是分开量的，存下来的可能是个长方形。掰回正方形 ——
            // 不掰的话用户在这一屏没有任何办法改：把手只能等比缩放。
            //
            // **已经判过色的不能动**：掰正会改掉行列数，而 `cells` 还是按旧行列数存的，
            // 结果不是崩，是底下几行悄悄丢掉、整片错位 —— 用户核对过的成果。
            if !sheet.hasCells, let fixed = squaredIfNeeded(calibration) {
                self.calibration = fixed
            }
            syncFrameToLattice()
            return
        }
        let source = work
        let region = roi
        let measured = await Task.detached(priority: .userInitiated) {
            // 整张图纸当成一块来量：竖格线在每一列上都出现在同样的相位，叠起来信号最强。
            PartsPitchEstimator.estimateLattice(
                work: source, parts: [BeadPart(rowBand: 0, bounds: region)]
            )
        }.value
        guard !Task.isCancelled else { return }
        // 一个都没量出来时给个保底值：按横向 40 格算。宁可给个明显不对的初值让用户去拉，
        // 也不要空着让他面对一张没有网格线的图。
        calibration = measured ?? fallbackCalibration()
        estimating = false
        syncFrameToLattice()
        writeBack()
    }

    private func fallbackCalibration() -> PartsGridCalibration? {
        guard roi.width > 0 else { return nil }
        let cell = Double(roi.width) / 40
        return PartsGridCalibration(
            cellWidth: cell,
            cellHeight: cell * sheetAspect,
            originX: Double(roi.minX),
            originY: Double(roi.minY)
        )
    }

    /// 把黄框摆到图纸正中那一格。
    ///
    /// 这不改变网格本身 —— 格线是无限铺开的，挑哪一格显示都一样。挑中间那格是因为
    /// 边角那一格多半压在留白上，框里一片空，看不出格子边界对没对齐。
    private func syncFrameToLattice() {
        guard let calibration, calibration.isUsable else { return }
        frameOrigin = CGPoint(x: calibration.snappedX(Double(roi.midX)),
                              y: calibration.snappedY(Double(roi.midY)))
    }

    /// 整张图纸有多少像素宽。加减号按**源图像素**动，不能按屏幕点 ——
    /// 屏幕上一格多大取决于当前放大了几倍，那是个跟图纸无关的数。
    private var sheetPixelWidth: Double {
        guard work.region.width > 0 else { return 0 }
        return Double(work.image.size.width) / Double(work.region.width)
    }

    /// 一格现在是多少源图像素。故意保留小数：量出来的格距本来就是 12.4 这种，
    /// 四舍五入到整数会凭空引入 5% 的误差，而这一屏存在的意义就是消掉这点误差。
    private var cellPixels: Double {
        guard let calibration else { return 0 }
        return calibration.cellWidth * sheetPixelWidth
    }

    private var cellPixelsText: String {
        let px = cellPixels
        guard px > 0 else { return "—" }
        return String(format: "%.2f 像素", px)
    }

    /// 加减号一次动多少源图像素。0.1 而不是 1 —— 整数步只能在 19.03 / 20.03 / 21.03
    /// 之间跳，而对的那个值就在它们中间。粗调有把手和自动对齐，这两个按钮是收尾用的。
    private static let cellPixelStep = 0.1

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

    /// 图纸整张的**像素**宽高比。归一化坐标把宽和高各自摊到 0~1，所以图纸不是正方形时，
    /// 一格是正方形 ⟺ `cellHeight == cellWidth * sheetAspect`。
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

    /// 重新自动对一次。
    ///
    /// - Parameter keepingCellSize: 用户刚手拉完一格的大小 → 只重找格线位置，
    ///   他量的多大就是多大。「自动对齐」按钮走的是 false：**连格距一起重量** ——
    ///   手拉的格子哪怕只大 1%，铺到第四十格就偏出去小半格，这时候光挪位置救不回来。
    ///   既然他按了那个按钮，就是「你帮我弄好」，不能留一个连按几次都没反应的死角。
    private func autoAlign(keepingCellSize: Bool) async {
        guard let current = calibration, current.isUsable else { return }
        let source = work
        let area = roi
        let parts = [BeadPart(rowBand: 0, bounds: area)]
        estimating = true
        defer { estimating = false }

        if !keepingCellSize,
           let measured = await Task.detached(priority: .userInitiated, operation: {
               PartsPitchEstimator.estimateLattice(work: source, parts: parts)
           }).value {
            calibration = measured
            syncFrameToLattice()
            writeBack()
            return
        }
        // 量不出来（或者用户要求保留自己拉的大小）时只对位置，至少别把现有的弄坏
        let fitted = await Task.detached(priority: .userInitiated) {
            PartsPitchEstimator.fitOrigin(work: source, parts: parts, calibration: current)
        }.value
        guard let fitted else { return }
        calibration?.originX = Double(fitted.x)
        calibration?.originY = Double(fitted.y)
        syncFrameToLattice()
        writeBack()
    }

    /// 把这一屏的结论写回图纸：整数行列、以及网格实际盖住的那块范围。
    ///
    /// **行列数一变就把判过的颜色扔掉。** 那些格子是按旧的行列数存的，换一张网格之后
    /// 它们描述的已经不是眼前这张图了；留着的话下游是 clamp 不是报错 ——
    /// 结果不是崩，是底下几行悄悄丢掉、每一格的颜色整体错位，而用户什么提示都没有。
    /// 扔掉不会让他白干：从这一屏往下走本来就要重新判一次色。
    ///
    /// 重新进来（格距和格线都是存下来那份）算出来的行列数跟存的一模一样，
    /// 所以这条不会在「只是回来看一眼」的时候误伤。
    private func writeBack() {
        guard let grid else { return }
        sheet.bounds = roi
        sheet.gridRect = grid.rect
        if sheet.hasCells, sheet.rows != grid.rows || sheet.cols != grid.cols {
            sheet.cells = []
        }
        sheet.rows = grid.rows
        sheet.cols = grid.cols
    }
}
