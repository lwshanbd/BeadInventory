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
//  ## 投到电视 / 投影仪
//
//  接了外屏就把整张图纸送过去（`BoardCastSession`），手机上点亮哪几个色号，
//  电视上就只亮哪几个。送过去的形式是「一张图纸 = 一块板 + 一个占满全板的零件」——
//  跟拼豆板共用同一套画法（`BoardCanvas`），不另写一份。
//
//  **电视上画的是格子，不是这张图片。** 图片放大了是像素画，投到 65 寸上一格豆子
//  糊成一坨；而画格子是矢量的，多大都清楚，还能把没选中的色号整体压成灰。
//  用户抬头要看的是「下一颗红色在第几行第几个」，不是图纸的照片。
//

import SwiftUI

struct SinglePatternHighlightStepView: View {
    let project: ProjectRecord
    let work: PartsWorkImage
    /// 已经判好色的网格。四角 / 行列 / 每格色号都在里面。
    let grid: BeadPatternGrid
    /// 图纸内容改过几次。**送外屏那份的重算信号就是它** —— 见 `castSignature`。
    let revision: Int
    /// 「重新对一遍」——退回第一屏。
    let onRecalibrate: () -> Void
    /// 「完成」——存好，关掉整个流程。
    let onFinish: () -> Void

    @EnvironmentObject var inventoryManager: InventoryManager
    @ObservedObject private var cast = BoardCastSession.shared
    /// 开着「对准豆板」那一屏
    @State private var showingProjectorSheet = false

    /// 送外屏用的那份「整张图纸当成一块板」。**算一次存着** ——
    /// 它要遍历几万格，每次点色号都重算一遍就是每次点击卡一下。
    @State private var castBoard: PartsBoard?
    @State private var castFootprints: [UUID: PartFootprint] = [:]
    @State private var castColors: [String: Color] = [:]

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
        let legend = Set(legendUsage.map(\.colorCode))
        return counts
            .map {
                ColorPaletteBar.Entry(code: $0.key, count: $0.value,
                                      isExtra: !legend.contains($0.key),
                                      color: color(for: $0.key))
            }
            .sorted { $0.count > $1.count }
    }

    /// 图纸色号表，**色号翻成当前体系的显示码之后**的样子。
    ///
    /// `beadUsage.colorCode` 存的是 canonical mardCode，而格子里存的是显示码。
    /// 不翻这一道的话，卡卡 / COCO 这类非 MARD 图纸上两边一个都对不上：
    /// 每个色号都被判成「表上没有」（底下全是虚线圈），顶上那条「跟图纸写的对不上」
    /// 会把所有色号一并算进去 —— 而其实一个都没错。
    private var legendUsage: [BeadUsage] {
        currentProject.beadUsage.map { usage in
            BeadUsage(id: usage.id,
                      colorCode: displayCode(for: usage.colorCode),
                      brandId: usage.brandId,
                      quantity: usage.quantity,
                      isDeducted: usage.isDeducted)
        }
    }

    private func displayCode(for canonical: String) -> String {
        inventoryManager.findColor(byMardCode: canonical)?
            .displayCode(for: currentProject.colorSystem) ?? canonical
    }

    /// 显示码 → 色号表里那个 canonical 码。写回项目时必须翻回去：
    /// `updatePlannedProjectUsage` 是按 colorCode 精确匹配的，对不上就**什么都不做也不报错** ——
    /// 用户点了「采纳网格数」之后毫无反应，而他没有任何办法知道为什么。
    private func canonicalCode(for display: String) -> String {
        currentProject.beadUsage.first { displayCode(for: $0.colorCode) == display }?.colorCode ?? display
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
            // 接了电视 / 投影仪之后第一件想确认的就是「到底投上了没有」——
            // 而人多半站在电视那头，手机上得有个准信。
            // 点它就是「对准豆板」——投影仪投出来的画面跟豆板对不上，是接上之后立刻
            // 会发现的事，而这个标记正是他这时候在看的东西（多零件那屏同样处理）。
            if cast.externalConnected {
                ProjectorStatusChip { showingProjectorSheet = true }
                    .padding(.horizontal, Theme.Spacing.md)
            }
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
        // 格子内容变了（用户回核对页改过色号）就重算一次送外屏的那份
        .task(id: castSignature) { await rebuildCast() }
        .onChange(of: highlightedCodes) { _, _ in publishToExternalDisplay() }
        // 离开这一屏就把电视上的东西撤掉：留着的话用户已经走了，电视上还停着一张
        // 他不再看的图纸 —— 而这一屏是被 push 上来的，退出去是很随手的动作。
        .onDisappear { BoardCastSession.shared.stop() }
        // 校准的收尾挂在这儿，理由同 PartsBoardStepView：那一屏自己分不清「被关掉了」
        // 和「被『自定义尺寸』盖住了」。
        .sheet(isPresented: $showingProjectorSheet, onDismiss: {
            if BoardProjector.shared.isCalibrating { BoardProjector.shared.cancelCalibrating() }
        }) {
            if let screen = cast.externalScreenSize {
                // 这里的「板」是整张图纸，跟桌上那块实物豆板多少格没有关系 —— 送 nil，
                // 让用户自己点一下，猜一个图纸尺寸当板子格数只会把中间的格子全对歪。
                BoardProjectorSheet(suggestedBoard: nil, screen: screen)
            }
        }
        .sheet(isPresented: $showingDiffSheet) {
            ValidationDiffSheet(
                diffs: GridValidator.mismatches(grid: grid, beadUsage: legendUsage),
                onAdoptGridForCode: { code, gridCount in
                    // 界面上是显示码，库里存的是 canonical 码，写回去要翻回来（见 canonicalCode）
                    inventoryManager.updatePlannedProjectUsage(currentProject.id,
                                                               colorCode: canonicalCode(for: code),
                                                               newQuantity: gridCount)
                }
            )
        }
    }

    // MARK: - 跟色号表对不上的提示

    @ViewBuilder
    private var mismatchBanner: some View {
        let mismatches = GridValidator.mismatches(grid: grid, beadUsage: legendUsage)
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
            PartsThumbnailMaker.cropExact(source, normalized: padded)
        }.value
        guard !Task.isCancelled else { return }
        image = cropped?.image
        region = cropped?.rect ?? .zero
    }

    // MARK: - 投到电视 / 投影仪

    /// 送外屏的那份东西什么时候要重算。**格子改过才算**，高亮不算 ——
    /// 高亮变了只要重发一次，不用把几万格重建一遍。
    ///
    /// 这里曾经拿 `grid.lastCalibratedAt` 当信号，而那是 `currentGrid` 每次求值现取的
    /// `Date()`：父视图任何一次 body 重算都会让它变，于是几万格被反复重建 ——
    /// 正好是「算一次存着」想避免的事，而且重建结果还会被 `Task.isCancelled` 静默丢掉，
    /// 手机上「投屏中」照常亮着，电视可能一直空白。
    private var castSignature: String {
        "\(revision)|\(grid.rows)x\(grid.cols)"
    }

    /// 整张图纸打包成「一块板 + 一个占满全板的零件」。
    /// 几万格的遍历放后台：主线程上做，用户点进这一屏时界面会僵一下。
    private func rebuildCast() async {
        guard grid.rows > 0, grid.cols > 0, grid.cellColorCodes.count == grid.rows else {
            castBoard = nil
            BoardCastSession.shared.stop()
            return
        }
        let codes = grid.cellColorCodes
        let built = await Task.detached(priority: .userInitiated) { () -> (PartsBoard, PartFootprint) in
            let cells: [[PartCellFill]] = codes.map { row in
                row.map { code in
                    guard let code, !code.isEmpty else { return PartCellFill.empty }
                    return .code(code)
                }
            }
            let placement = PartPlacement(partId: UUID(), col: 0, row: 0)
            let board = PartsBoard(
                size: BeadBoardSize(cols: codes.first?.count ?? 0, rows: codes.count),
                placements: [placement]
            )
            return (board, PartFootprint(cells: cells))
        }.value
        guard !Task.isCancelled, let placementId = built.0.placements.first?.id else { return }
        castBoard = built.0
        castFootprints = [placementId: built.1]
        castColors = Dictionary(uniqueKeysWithValues: entries.map { ($0.code, $0.color) })
        publishToExternalDisplay()
    }

    private func publishToExternalDisplay() {
        guard let castBoard else { return }
        BoardCastSession.shared.update(.init(
            board: castBoard,
            footprints: castFootprints,
            colorCache: castColors,
            highlightKeys: highlightedCodes,
            caption: String(localized: "整张图纸 · \(castBoard.cols) × \(castBoard.rows) 格")
        ))
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
