//
//  SinglePatternHighlightStepView.swift
//  BeadInventory
//
//  单图纸模式 · 照着高亮拼（最后一屏；整条流程的屏序见 SinglePatternFlowView 的头注释）
//
//  前面几屏都是准备工作，这一屏才是用户真正花时间的地方：手里抓着一把 H7，
//  在图纸上找出它该去的那几百格。所以这一屏只做一件事 —— 点一个色号，
//  **图上除了它以外全部压暗**。
//
//  ## 放大不能用 scaleEffect
//
//  用户会把图纸放大到能数清一颗一颗豆子。`scaleEffect` 是图层变换，走双线性平滑，
//  `.interpolation(.none)` 管不到它 —— 放大之后像素画糊成一片渐变，正好毁掉他要看的东西。
//  所以图和高亮层各自按 `PartsCanvasTransform` 算出来的屏幕矩形直接摆
//  （同「量格子」「找零件」那几屏）。
//

import SwiftUI

struct SinglePatternHighlightStepView: View {
    let project: ProjectRecord
    let work: PartsWorkImage
    /// 已经判好色的网格。四角 / 行列 / 每格色号都在里面。
    let grid: BeadPatternGrid
    /// 「重新对一遍」——退回第一屏。
    let onRecalibrate: () -> Void
    /// 「完成」——存好，关掉整个流程。
    let onFinish: () -> Void

    @EnvironmentObject var inventoryManager: InventoryManager

    @State private var highlightedCodes: Set<String> = []
    @State private var guideMode: GuideMode = .off
    @State private var showingDiffSheet = false
    @State private var dismissedBanner = false

    @State private var image: UIImage?
    @State private var region: CGRect = .zero
    @State private var canvasSize: CGSize = .zero
    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var lastPan: CGSize = .zero
    @State private var pinchScreenPoint: CGPoint = .zero
    @State private var pinchContentAnchor: CGPoint?

    private var currentProject: ProjectRecord {
        inventoryManager.projects.first { $0.id == project.id } ?? project
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

    /// 图上每个色号有多少格，多的排前面。
    private var entries: [ColorPaletteBar.Entry] {
        var counts: [String: Int] = [:]
        for row in grid.cellColorCodes {
            for case let code? in row {
                counts[code, default: 0] += 1
            }
        }
        let legend = Set(currentProject.beadUsage.map(\.colorCode))
        return counts
            .map {
                ColorPaletteBar.Entry(code: $0.key, count: $0.value,
                                      isExtra: !legend.contains($0.key),
                                      color: color(for: $0.key))
            }
            .sorted { $0.count > $1.count }
    }

    /// 色号 → 色库里那颗豆子的颜色。
    ///
    /// **MARD 不能走 `findColor(byCode:preferSystem:)`** —— 那个重载在 `preferSystem == .mard`
    /// 时直接返回 nil（MARD 那一路留给了 `findColor(byMardCode:)`），走错的话 MARD 图纸上
    /// 每个色号的小圆点都是灰的。核对页 (`PartsColorReviewStepView.bead(for:)`) 就是这么分流的，
    /// 两屏必须用同一套规则，否则同一个色号在两屏上是两种颜色。
    private func color(for code: String) -> Color {
        let system = currentProject.colorSystem
        let bead = system == .mard
            ? inventoryManager.findColor(byMardCode: code)
            : inventoryManager.findColor(byCode: code, preferSystem: system)
        return bead?.color ?? Theme.ColorToken.Surface.subtle
    }

    var body: some View {
        VStack(spacing: 0) {
            mismatchBanner
            canvas
            ColorPaletteBar(entries: entries, highlightedCodes: $highlightedCodes)
        }
        .navigationTitle(currentProject.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section("辅助线") {
                        ForEach(GuideMode.allCases, id: \.self) { mode in
                            Button {
                                guideMode = mode
                            } label: {
                                if guideMode == mode {
                                    Label(mode.label, systemImage: "checkmark")
                                } else {
                                    Text(mode.label)
                                }
                            }
                        }
                    }
                    Divider()
                    Button {
                        highlightedCodes.removeAll()
                    } label: {
                        Label("清除高亮", systemImage: "eye.slash")
                    }
                    Button(action: onRecalibrate) {
                        Label("重新对一遍", systemImage: "square.grid.3x3.square")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成", action: onFinish)
            }
        }
        .task(id: "\(work.image.size)|\(grid.rows)x\(grid.cols)") { await load() }
        .sheet(isPresented: $showingDiffSheet) {
            ValidationDiffSheet(
                diffs: GridValidator.mismatches(grid: grid, beadUsage: currentProject.beadUsage),
                onAdoptGridForCode: { code, gridCount in
                    inventoryManager.updatePlannedProjectUsage(currentProject.id,
                                                               colorCode: code,
                                                               newQuantity: gridCount)
                }
            )
        }
    }

    // MARK: - 跟色号表对不上的提示

    @ViewBuilder
    private var mismatchBanner: some View {
        let mismatches = GridValidator.mismatches(grid: grid, beadUsage: currentProject.beadUsage)
        if !mismatches.isEmpty && !dismissedBanner {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.ColorToken.Status.warning)
                Text("图上认出来的颗数，有 \(mismatches.count) 个色号跟图纸写的对不上")
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("看看") { showingDiffSheet = true }
                    .font(.footnote)
                Button { dismissedBanner = true } label: {
                    Image(systemName: "xmark").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.ColorToken.Text.secondary)
            }
            .padding(8)
            .background(Theme.ColorToken.Status.warning.opacity(0.15))
        }
    }

    // MARK: - 画布

    private var canvas: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black

                if let image, canvasSize.width > 0, region.width > 0 {
                    let box = transform.screenRect(region)
                    Image(uiImage: image)
                        .resizable()
                        // 放大到一颗豆子时要看得见硬边界，插值会把它糊掉
                        .interpolation(box.width >= image.size.width ? .none : .high)
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)

                    PatternHighlightOverlay(
                        grid: grid,
                        highlightedCodes: highlightedCodes,
                        guideMode: guideMode,
                        // 高亮层按「整张源图占的那块屏幕」算坐标 —— 网格的四角就是
                        // 相对整张源图的归一化点，两边用同一个坐标系才对得上。
                        displayRect: transform.screenRect(CGRect(x: 0, y: 0, width: 1, height: 1))
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                    .allowsHitTesting(false)
                }

                gestureCatcher
            }
            .onAppear { canvasSize = geo.size }
            .onChange(of: geo.size) { _, new in canvasSize = new }
        }
        .clipped()
    }

    private var gestureCatcher: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                SimultaneousGesture(
                    SimultaneousGesture(
                        // 双击在 1× 和 4× 之间切。**必须跟拖动并进同一个 SimultaneousGesture**：
                        // 单独挂 onTapGesture 会被 DragGesture 整个吞掉，表现为「双击没反应」。
                        SpatialTapGesture(count: 2).onEnded { value in
                            toggleZoom(at: value.location)
                        },
                        DragGesture(minimumDistance: 4)
                            .onChanged { value in
                                pan = clampPan(CGSize(width: lastPan.width + value.translation.width,
                                                      height: lastPan.height + value.translation.height))
                            }
                            .onEnded { _ in lastPan = pan }
                    ),
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

    // MARK: - 逻辑

    private func load() async {
        let source = work
        // 画的是网格盖住的那一块（外加一点余量），不是整张图 ——
        // 图纸上下那一圈色号表、留白，在这一屏只会占地方。
        let box = boundingBox(of: grid.corners)
        let padded = box
            .insetBy(dx: -box.width * 0.03, dy: -box.height * 0.03)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let cropped = await Task.detached(priority: .userInitiated) {
            PartsThumbnailMaker.crop(source, normalized: padded)
        }.value
        guard !Task.isCancelled else { return }
        image = cropped
        region = padded.width > 0 ? padded : CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    private func boundingBox(of corners: GridCorners) -> CGRect {
        let xs = [corners.topLeft.x, corners.topRight.x, corners.bottomLeft.x, corners.bottomRight.x]
        let ys = [corners.topLeft.y, corners.topRight.y, corners.bottomLeft.y, corners.bottomRight.y]
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max(), maxX > minX, maxY > minY else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func toggleZoom(at point: CGPoint) {
        withAnimation(.easeInOut(duration: 0.25)) {
            if zoom > 1.05 {
                zoom = 1; lastZoom = 1
                pan = .zero; lastPan = .zero
            } else {
                let anchor = unzoomed(point)
                zoom = 4; lastZoom = 4
                let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                pan = clampPan(CGSize(width: point.x - center.x - (anchor.x - center.x) * zoom,
                                      height: point.y - center.y - (anchor.y - center.y) * zoom))
                lastPan = pan
            }
        }
    }

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
}
