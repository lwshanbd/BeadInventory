//
//  PartCellBrushView.swift
//  BeadInventory
//
//  多零件 / 单图纸模式 · 擦掉、补上格子
//
//  判色一定会错，而错法只有两种：**把空白判成了豆子**（零件外沿那圈毛边、图纸上的
//  文字和箭头、两个零件之间的连线），或者**把豆子判成了空白**（浅色豆子压在浅色底上）。
//
//  核对颜色那屏只解得了半个：它按色号把格子铺出来，改的是「这一格是什么颜色」。
//  一个本该有豆子的空格躺在几万个空格中间，在那儿根本找不到 —— 而这恰恰是用户
//  最想修的那一种错。
//
//  所以这一屏换个看法：把这一块**按它自己的行列数铺在屏幕上** —— 一格一个方块、
//  正方的、跟拼豆板上看到的是同一个形状 —— 手指划过去就是擦掉 / 补上。
//  用户回答的是「这儿到底有没有豆子」，不是「这一格叫什么名字」。
//
//  **不拿图纸原图当底。** 垫在底下的话，格子就得按图纸的几何铺：网格但凡量得不准，
//  零件在这一屏会被拉成一条扁带，跟零件清单、拼豆板上那个形状对不上 ——
//  而用户要改的正是那个形状。图纸原图挪到「对照图纸」那个按钮后面，
//  按一下整层换上来（同一个框、同一批格线），对完再按回来。
//
//  ## 三个工具，一次只干一件事
//
//    挪图  拖动看图、两指捏合放大。默认就是它 —— 进来第一件事是看，不是画，
//          落指就擦掉的话，用户想挪一下图就毁了一片格子。
//    擦掉  划过的格子变成「没有豆子」
//    补上  划过的格子变成选中的那个色号
//
//  ## 改完就是改完了
//
//  一笔画完立刻写回**内存里的**零件（`commit`），关掉这一屏时调用方落盘一次
//  （`onCommit`，见 `.onDisappear`）；中途被切到后台，两个流程容器的
//  `scenePhase != .active` 也会存一遍。用户擦掉的格子，下次进来、下次开 App
//  都还是擦掉的 —— 除非他自己再按「重新判色」，那一步本来就会从头重算每一格
//  （有确认弹窗）。
//

import SwiftUI

struct PartCellBrushView: View {
    /// 图纸本身。**可以是 nil** —— 拼豆板那屏的图有可能裁不出来，
    /// 而「这一格多认了一颗」照样改得了：识别结果那一层自己就是一张图。
    /// 只是那时候没有原图可比，用户只能照着手上的实物改。
    let work: PartsWorkImage?
    let partId: UUID
    @Binding var parts: [BeadPart]
    let colorSystem: ColorSystem
    /// 底下写的是在改哪一块（「零件 3」/「整张图纸」）
    var subject: String
    /// 有没有「任意色」这一档。单图纸模式没有（同 `PartsColorReviewStepView.allowsAnyColor`）。
    var allowsAnyColor: Bool = true
    /// 改完落盘：这一屏只改内存里的零件，不写进项目的话，
    /// 用户擦掉的格子下次进来又原样回来了。
    let onCommit: () -> Void

    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) private var dismiss

    enum Tool: Hashable { case move, erase, paint }

    @State private var tool: Tool = .move
    /// 手上这一份格子。**不直接改 `parts`**：一笔下去要改几十格，
    /// 每格都往 binding 里写一次的话，单图纸模式那个现拼的 binding
    /// （`SinglePatternFlowView.sheetParts`）会把前一次写的读丢
    ///（同 `PartsCellSizeStepView.clearCellsForRegrid` 踩过的那次）。
    @State private var cells: [[PartCellFill]] = []
    /// 进来时的样子，「取消」用它整块还原
    @State private var original: [[PartCellFill]] = []
    /// 一笔一条，撤销按笔走 —— 划过去一串二十格，一格一格地撤是没人受得了的
    @State private var strokes: [[Change]] = []
    @State private var loaded = false

    /// 「补上」用哪个色号。**可以是 nil** —— 图纸上一个色号都没认出来、而这张图纸
    /// 又没有「任意色」这一档时（单图纸模式），没有任何一个合法的默认值可给，
    /// 那就先让用户自己挑一个（见 `buildPalette` 末尾）。
    @State private var paintFill: PartCellFill?
    @State private var showingCodePicker = false
    @State private var pickedCodes: Set<String> = []

    /// 图纸上这一块的原样
    @State private var image: UIImage?
    /// `image` 盖住的是格子矩阵里的哪一块（归一化，相对整张图纸）。
    ///
    /// 多数时候就是 `gridArea` 本身；靠零件区边上的零件会被工作图切掉一条，
    /// 那时它比 `gridArea` 小 —— 按它自己的范围画，切掉的那条就是空的，
    /// 而不是把一张缺角的图拉满整个框（那样格线跟豆子会整体错开）。
    @State private var imageRect: CGRect = .zero
    /// 画布画的是整张图纸的哪一块（归一化）
    @State private var region: CGRect = .zero
    /// 识别结果那一层。一格一个像素画成位图，再按最终尺寸贴上去 ——
    /// 单图纸模式一张图纸七万格，用 Canvas 一格一格描的话，
    /// 手指划一下整屏重画七万个矩形，直接卡死。
    @State private var overlay: UIImage?
    /// 正在对照图纸原图（把零件那一层整个换成图纸）。
    ///
    /// **默认是关的**：这一屏画的是零件本身 —— 一格一格、正方的、跟拼豆板上一样的那个
    /// 形状。图纸原图只在用户主动要「对一眼」的时候顶上来，而不是一直垫在底下：
    /// 垫在底下就得按图纸的几何铺格子，网格量得不准时零件会被拉变形。
    @State private var showsPattern = false
    /// 现在这一块还剩多少颗豆子。放 @State 而不是每次 body 现算 ——
    /// 七万格的图纸上，拖一下就要重数七万遍。
    @State private var beadCount = 0
    /// 往零件里写过东西（决定关掉时要不要落盘）。
    /// 「取消」那一次还原也算 —— 还原本身也得落盘，把之前写进去的盖回去。
    @State private var changed = false
    /// 写不回零件（`partId` 在 `parts` 里找不到了）。这时候屏幕上画什么都没用，
    /// 得当场告诉用户，别让他白擦一屏。
    @State private var writeFailed = false
    /// 图纸这一块没取到（没有原图、或者裁失败）。这一屏承诺的是「照着图纸改」，
    /// 取不到就得说出来 —— 而且「只看图纸」那个开关这时候只会给出一片空白。
    @State private var imageUnavailable = false

    @State private var canvasSize: CGSize = .zero
    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var lastPan: CGSize = .zero
    @State private var pinchScreenPoint: CGPoint = .zero
    @State private var pinchContentAnchor: CGPoint?

    /// 正在画的这一笔。**引用类型**：一次拖动里 onChanged 会连着来几十次，
    /// 中间要读上一次划到哪一格；@State 写完同一轮读回来不保证是新值
    /// （`PartsBoardStepView.DragSession` 就是栽在这上面）。
    @State private var stroke = StrokeState()

    private struct Change {
        let row: Int
        let col: Int
        let old: PartCellFill
    }

    private final class StrokeState {
        var changes: [Change] = []
        /// 上一次划到哪一格。手指移得快时两次事件之间会跳过好几格，
        /// 拿它把中间那几格补上，否则划出来的是一串虚线。
        var last: (row: Int, col: Int)?

        func reset() {
            changes = []
            last = nil
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if rows > 0, cols > 0 {
                    VStack(spacing: 0) {
                        canvas
                        footer
                    }
                } else if loaded {
                    ContentUnavailableView(
                        "这一块还没判过色",
                        systemImage: "eyedropper",
                        description: Text("先走一遍「看每格什么颜色」，再回来擦或者补。")
                    )
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("擦掉 / 补上")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // 「取消」就是整块还原成进来时的样子 —— 一笔一笔都已经写回零件了，
                    // 不还原的话这个按钮等于「完成」，只是不说话。
                    Button("取消") {
                        revert()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .font(.body.weight(.semibold))
                }
            }
        }
        .task { await load() }
        .onDisappear {
            // 落盘放在这里，不放在「完成」上：下拉关掉弹窗也是关掉，
            // 那时候格子早就写回零件了，不存的话用户下次进来看到的是没改过的样子。
            //
            // **晚一拍再落**：存不上的时候流程容器会弹「这一步没存上」，而这里正是
            // sheet 拆解的那一拍 —— 在这拍里 present 一个 alert 有可能被吞掉，
            // 那句话就再也不会出现（`prompt` 停在同一个 id，之后每次失败都盖回同一个值）。
            guard changed else { return }
            Task { @MainActor in onCommit() }
        }
        .sheet(isPresented: $showingCodePicker, onDismiss: applyPickedCode) {
            ColorSelectionView(
                selectedColors: $pickedCodes,
                colorSystem: colorSystem,
                suggestedColors: sheetColors,
                focusColor: currentPaintColor
            )
            .environmentObject(inventoryManager)
        }
    }

    // MARK: - 上：图

    private var canvas: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Theme.ColorToken.Surface.subtle

                if canvasSize.width > 0, rows > 0, cols > 0 {
                    let box = transform.screenRect(gridArea)

                    // 板底。空格子就是它 —— 擦掉一格，露出来的是「这儿没有豆子」，
                    // 而不是图纸上那颗还在那儿的豆子。
                    Rectangle()
                        .fill(Theme.ColorToken.Surface.elevated)
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)

                    // 按最终尺寸摆图，**不用 scaleEffect** —— 那是图层变换，
                    // 放大走双线性平滑，`.interpolation(.none)` 管不到它，
                    // 而这一屏要看的正是一颗豆子的边界（同 PartsCellSizeStepView）。
                    if showsPattern, let image {
                        let shot = transform.screenRect(imageRect)
                        Image(uiImage: image)
                            .resizable()
                            .interpolation(.none)
                            .frame(width: shot.width, height: shot.height)
                            .position(x: shot.midX, y: shot.midY)
                    } else if let overlay {
                        Image(uiImage: overlay)
                            .resizable()
                            .interpolation(.none)
                            .frame(width: box.width, height: box.height)
                            .position(x: box.midX, y: box.midY)
                    }

                    gridLines
                }

                gestureCatcher
            }
            .onAppear { canvasSize = geo.size }
            .onChange(of: geo.size) { _, new in canvasSize = new }
        }
        .clipped()
    }

    /// 格线 + 这一块的边界。
    ///
    /// 边界那个框不是装饰：框外面的格子这一屏改不了（零件的格子矩阵就这么大），
    /// 不画出来的话用户会对着框外面划半天，一格都不会变。
    private var gridLines: some View {
        Canvas { context, _ in
            let box = transform.screenRect(gridArea)
            let cw = box.width / CGFloat(cols)
            let ch = box.height / CGFloat(rows)

            // 一格小到看不出是格子的时候就别画了 —— 几百条线糊成一片，
            // 反而把底下的图纸盖住。
            if cw >= 9, ch >= 9 {
                var path = Path()
                for c in 0...cols {
                    let x = box.minX + CGFloat(c) * cw
                    path.move(to: CGPoint(x: x, y: box.minY))
                    path.addLine(to: CGPoint(x: x, y: box.maxY))
                }
                for r in 0...rows {
                    let y = box.minY + CGFloat(r) * ch
                    path.move(to: CGPoint(x: box.minX, y: y))
                    path.addLine(to: CGPoint(x: box.maxX, y: y))
                }
                context.stroke(path, with: .color(.white.opacity(0.35)), lineWidth: 0.5)
            }

            context.stroke(Path(box), with: .color(Theme.ColorToken.Morandi.honey), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }

    private var gestureCatcher: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                SimultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // 两指捏合时别顺手画一道
                            guard pinchContentAnchor == nil else { return }
                            if tool == .move {
                                pan = clampPan(CGSize(
                                    width: lastPan.width + value.translation.width,
                                    height: lastPan.height + value.translation.height
                                ))
                            } else {
                                paint(at: value.location)
                            }
                        }
                        .onEnded { value in
                            if tool == .move {
                                lastPan = pan
                            } else {
                                // 最后一段常常只随抬手事件送达，onChanged 没见过它 ——
                                // 不补这一下，快速划一道的末尾几格不会变
                                //（同 PartsBoardStepView 里 gestureCatcher 的 onEnded：
                                // 抬手前再 updateMove 一次）。
                                if pinchContentAnchor == nil { paint(at: value.location) }
                                endStroke()
                            }
                        },
                    MagnifyGesture()
                        .onChanged { value in
                            if pinchContentAnchor == nil {
                                pinchScreenPoint = value.startLocation
                                pinchContentAnchor = unzoomed(value.startLocation)
                                // **把这一笔退掉，不是收下。** 两指捏合的第一根手指会先
                                // 触发一次 minimumDistance 0 的拖动，在 Magnify 反应过来之前
                                // 已经改掉一格了 —— 用户想放大，代价是图纸上多 / 少了一颗豆子，
                                // 而在几千格里他多半发现不了。想放大就是想放大，退干净。
                                rollbackStroke()
                            }
                            guard let anchor = pinchContentAnchor else { return }
                            zoom = max(1, min(20, lastZoom * value.magnification))
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

    // MARK: - 下：工具

    private var footer: some View {
        VStack(spacing: Theme.Spacing.md) {
            // 出了事就摆在最上面，别让用户对着一屏正常的界面白擦。
            if writeFailed {
                warning("这一块对不上任何零件了，改的东西存不下来。退出去回零件清单看看。",
                        icon: "exclamationmark.triangle.fill", isError: true)
            } else if imageUnavailable {
                warning("这次取不到图纸上的这一块，没法对照图纸 —— 照着手上的实物改。",
                        icon: "photo.badge.exclamationmark", isError: false)
            }

            Picker("", selection: $tool) {
                Text("挪图").tag(Tool.move)
                Text("擦掉").tag(Tool.erase)
                Text("补上").tag(Tool.paint)
            }
            .pickerStyle(.segmented)
            .onChange(of: tool) { _, _ in endStroke() }

            if tool == .paint {
                paintColorBar
            }

            HStack(spacing: Theme.Spacing.md) {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    undo()
                } label: {
                    Label("撤销", systemImage: "arrow.uturn.backward").font(.footnote)
                }
                .disabled(strokes.isEmpty)
            }

            HStack(spacing: Theme.Spacing.md) {
                Text("\(subject) · 现在 \(beadCount) 颗")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Theme.ColorToken.Text.primary)
                Spacer()
                // 屏幕上画的是零件本身。要判「图纸上这儿到底有没有豆子」，按一下把
                // 图纸原图顶上来对一眼 —— 同一块地方、同一批格线，只是换了一层。
                //
                // **没有图纸时不摆这个按钮**：顶上来底下什么都没有，
                // 用户按到的是一个把屏幕清空的开关，而且看不出为什么。
                if image != nil {
                    Button {
                        showsPattern.toggle()
                    } label: {
                        Label(showsPattern ? "看零件" : "对照图纸",
                              systemImage: showsPattern ? "square.grid.3x3.fill" : "photo")
                            .font(.footnote)
                    }
                }
                zoomButton("minus.magnifyingglass") { zoomBy(1 / 1.6) }
                zoomButton("plus.magnifyingglass") { zoomBy(1.6) }
            }
        }
        .padding()
        .background(.regularMaterial)
    }

    private func warning(_ text: LocalizedStringKey, icon: String, isError: Bool) -> some View {
        Label {
            Text(text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: icon)
        }
        .foregroundStyle(isError ? Theme.ColorToken.Status.error : Theme.ColorToken.Text.secondary)
    }

    /// 「补上」补的是哪个色号。列的是**识别结果里已经出现过的**颜色，按颗数从多到少 ——
    /// 大多数时候要补的就在这几个里，用户不用去四百多个色号里翻。
    ///
    /// 盖不住的是「这个色号一颗都没认出来」那一种（浅色压在浅色底上最容易整片漏）：
    /// 它在识别结果里是零，所以既不在这条栏里，也不在「其它色号」的推荐里。
    /// 那时候只能自己去色号表翻 —— 要更准得把图纸色号表（`legendCounts`）传进来，
    /// 核对页就是那么做的（见 `PartsColorReviewStepView.patternColors`）。
    private var paintColorBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(paletteOptions, id: \.key) { option in
                    Button { paintFill = option.fill } label: {
                        colorChip(option)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    pickedCodes = []
                    showingCodePicker = true
                } label: {
                    Label("其它色号", systemImage: "paintpalette")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.sm)
                        .background(Capsule().fill(Theme.ColorToken.Surface.elevated))
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.ColorToken.Text.primary)
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 44)
    }

    private func colorChip(_ option: PaletteOption) -> some View {
        let isOn = paintFill.map(groupKey) == option.key
        return HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(option.color)
                .frame(width: 18, height: 18)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
                )
            Text(option.label)
                .font(.footnote.weight(.medium))
                .foregroundColor(Theme.ColorToken.Text.primary)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(
            Capsule().fill(isOn
                           ? Theme.ColorToken.Morandi.mauve.opacity(0.22)
                           : Theme.ColorToken.Surface.elevated)
        )
        .overlay(
            Capsule().stroke(isOn ? Theme.ColorToken.Morandi.mauve : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Capsule())
    }

    private func zoomButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.subheadline.weight(.bold))
                .frame(width: 40, height: 34)
                .background(Theme.ColorToken.Surface.elevated)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundColor(Theme.ColorToken.Text.primary)
    }

    private var hint: String {
        switch tool {
        case .move: return String(localized: "拖动看图，两指捏合放大。要改格子，上面换「擦掉」或「补上」。")
        case .erase: return String(localized: "手指划过要去掉的格子。")
        case .paint: return String(localized: "手指划过要补上的格子。")
        }
    }

    // MARK: - 几何

    private var rows: Int { cells.count }
    private var cols: Int { cells.first?.count ?? 0 }

    private var part: BeadPart? {
        parts.first { $0.id == partId }
    }

    /// 格子矩阵在整张图纸上占的那块（归一化）。跟 `BeadPart.cellRect` 用的是同一块 ——
    /// 两边对不上的话，用户划的是这一格、改的是旁边那一格。
    private var gridArea: CGRect {
        guard let part else { return .zero }
        return part.gridRect ?? part.bounds
    }

    /// 画布上摆的那块内容有多大：**永远按零件自己的行列数**，一格一个单位。
    ///
    /// 早先这里用的是图纸那张裁图的像素尺寸，于是格子跟着**图纸**的几何走：
    /// 网格但凡量得不准（格距偏大、框歪了），零件在这一屏就被拉成一条扁带，
    /// 跟拼豆板上、零件清单里看到的那个形状对不上 —— 而用户要改的正是那个形状。
    /// 按行列数铺之后，一格在屏幕上永远是正方的，零件长什么样就是什么样。
    private var contentSize: CGSize {
        CGSize(width: max(cols, 1), height: max(rows, 1))
    }

    private var displayRect: CGRect {
        PartsRegionStepView.aspectFitRect(imageSize: contentSize, in: canvasSize)
    }

    private var transform: PartsCanvasTransform {
        PartsCanvasTransform(region: region, display: displayRect,
                             size: canvasSize, zoom: zoom, pan: pan)
    }

    /// 屏幕上这一点落在第几行第几列。框外面返回 nil —— 那儿没有格子可改。
    private func cellIndex(at point: CGPoint) -> (row: Int, col: Int)? {
        let area = gridArea
        guard area.width > 0, area.height > 0, rows > 0, cols > 0 else { return nil }
        let n = transform.normalized(point)
        let col = Int(floor((n.x - area.minX) / (area.width / CGFloat(cols))))
        let row = Int(floor((n.y - area.minY) / (area.height / CGFloat(rows))))
        guard row >= 0, row < rows, col >= 0, col < cols else { return nil }
        return (row, col)
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

    private func zoomBy(_ factor: CGFloat) {
        zoom = max(1, min(20, zoom * factor))
        lastZoom = zoom
        pan = clampPan(pan)
        lastPan = pan
    }

    // MARK: - 画

    private func paint(at point: CGPoint) {
        // **画什么由工具单独决定，别写成三目。** `tool == .erase ? .empty : paintFill`
        // 会把「挪图」也映射成画画 —— 现在安全只因为两个调用点都先判了 .move，
        // 那是调用方的纪律，不是这里的保证。
        let target: PartCellFill
        switch tool {
        case .move: return
        case .erase: target = .empty
        case .paint:
            // 还没挑色号（图纸上一个都没认出来）。**别让这一下变成没反应的空点** ——
            // 直接把选色盘推上来，那正是他现在唯一该做的事。
            guard let paintFill else {
                if !showingCodePicker {
                    pickedCodes = []
                    showingCodePicker = true
                }
                return
            }
            target = paintFill
        }

        // 划到框外面：**把锚点清掉**。留着的话，用户从框里划出去、绕一圈再划回来，
        // 下面那段补线会把两个落点之间连成一条斜带，把他一小时前核对好的格子整片改掉 ——
        // 而那条带看起来就像他自己画的那一笔。框只是画布里的一小块（四周还特意留了
        // 一圈图纸看格线对没对齐），划出去太容易了。
        guard let hit = cellIndex(at: point) else {
            stroke.last = nil
            return
        }
        // 正对照着图纸的时候动了笔，就切回零件那一层 —— 否则用户划半天，
        // 屏幕上唯一的变化是底下那个颗数。
        if showsPattern { showsPattern = false }

        // 手指移得快时两次事件之间会跳过好几格。只改落点的话，划出来的是一串虚线，
        // 用户得回头一格一格补 —— 那正是这一屏想省掉的事。
        if let last = stroke.last, last != hit {
            let steps = max(abs(hit.row - last.row), abs(hit.col - last.col))
            if steps > 1 {
                for step in 1..<steps {
                    let t = Double(step) / Double(steps)
                    let r = Int((Double(last.row) + Double(hit.row - last.row) * t).rounded())
                    let c = Int((Double(last.col) + Double(hit.col - last.col) * t).rounded())
                    setCell(row: r, col: c, to: target)
                }
            }
        }
        setCell(row: hit.row, col: hit.col, to: target)
        stroke.last = hit
        // **一次事件刷一遍，不是一格刷一遍。** `refresh` 要重数所有格子 + 重建整张位图；
        // 一次快速滑动光补线就能改十几格，放在 `setCell` 里就是同一个触摸事件里重建十几遍。
        // 单图纸模式一张七万格，位图方案本来就是为了避掉这种量。
        refresh()
    }

    private func setCell(row: Int, col: Int, to fill: PartCellFill) {
        // 按**这一行自己的**长度判界。全仓库别处（`CellOverlayBitmap.make`、
        // `BeadPart.rotatedCells`、`PartsColorReviewStepView.apply`）都当 cells 可能不齐，
        // 只有这里拿第 0 行的宽度去索引别的行 —— 而这里是唯一会崩、不是跳过的地方。
        guard row >= 0, row < rows, col >= 0, col < cells[row].count else { return }
        guard cells[row][col] != fill else { return }
        stroke.changes.append(Change(row: row, col: col, old: cells[row][col]))
        cells[row][col] = fill
    }

    /// 一笔画完：记进撤销栈，写回**内存里的**零件。
    ///
    /// 一笔一写而不是等「完成」，是为了「取消」有东西可还原、撤销栈不跟零件脱节。
    /// **落盘不在这儿** —— 在 `.onDisappear` 那一下（见 `onCommit`）。这一屏开着时
    /// 被电话打断，靠的是两个流程容器的 `scenePhase != .active` 也会 persist 一次。
    private func endStroke() {
        defer { stroke.reset() }
        guard !stroke.changes.isEmpty else { return }
        strokes.append(stroke.changes)
        commit()
    }

    /// 把正在画的这一笔原样退回去（捏合抢走了这次手势）。
    /// 跟 `endStroke` 的区别是它不进撤销栈 —— 用户压根没打算画这一下。
    private func rollbackStroke() {
        defer { stroke.reset() }
        guard !stroke.changes.isEmpty else { return }
        restore(stroke.changes)
        refresh()
        commit()
    }

    private func undo() {
        guard let last = strokes.popLast() else { return }
        restore(last)
        refresh()
        commit()
    }

    /// 把一串改动按相反顺序放回去。同一格在一笔里最多出现一次（`setCell` 值没变就早返回、
    /// 一笔之内 target 恒定），所以顺序其实不承重 —— 但反着来是白拿的保险。
    private func restore(_ changes: [Change]) {
        for change in changes.reversed()
        where change.row < rows && change.col < cells[change.row].count {
            cells[change.row][change.col] = change.old
        }
    }

    /// 整块还原成进来时的样子（「取消」）
    private func revert() {
        endStroke()
        guard changed else { return }
        cells = original
        strokes = []
        refresh()
        commit()
    }

    /// 写回零件。**一次只写一遍 `parts`** —— 连着两次 `parts[i].x = y` 是两轮
    /// get→mutate→set，而单图纸模式那个 binding 的 getter 是现拼出来的，
    /// 第二次读到的可能还是旧值（见 `cells` 的注释）。
    private func commit() {
        guard let index = parts.firstIndex(where: { $0.id == partId }) else {
            // 屏幕上每一笔都照画不误（`cells` 是这一屏自己的），但一个字节都写不出去，
            // 而 `changed` 停在 false 连落盘都不会试 —— 用户擦五十格、看着全生效、
            // 按完成、回来一格没变。这种必须当场说，不能等他自己发现。
            guard !writeFailed else { return }
            writeFailed = true
            AppLogger.shared.error("PartCellBrush", "commit_part_missing", metadata: [
                "partId": partId.uuidString,
                "parts": "\(parts.count)"
            ])
            return
        }
        var updated = parts[index]
        updated.cells = cells
        parts[index] = updated
        changed = true
    }

    /// 格子变了之后，屏幕上跟着变的那几样
    private func refresh() {
        beadCount = cells.reduce(0) { $0 + $1.filter(\.needsBead).count }
        // 建不出来就**留住上一张**。无条件赋值的话，识别结果那一层会在用户下一笔之后
        // 整个消失 —— 他读到的是「我把东西全擦没了」，而真相是一张位图没建出来。
        if let built = CellOverlayBitmap.make(cells: cells, colors: overlayColors) {
            overlay = built
        } else {
            AppLogger.shared.error("PartCellBrush", "overlay_bitmap_failed", metadata: [
                "rows": "\(rows)", "cols": "\(cols)"
            ])
        }
    }

    // MARK: - 颜色

    private struct PaletteOption {
        let key: String
        let fill: PartCellFill
        let label: String
        let color: Color
    }

    /// 色号栏上列哪些。按整张图纸用到的颗数从多到少 —— 漏判的那颗最可能是主色。
    @State private var paletteOptions: [PaletteOption] = []
    /// 位图那一层用的颜色（含「任意色」）
    @State private var overlayColors: [String: Color] = [:]
    /// 选色盘里排在最前面的候选
    @State private var sheetColors: [BeadColor] = []

    private var currentPaintColor: BeadColor? {
        guard case .code(let code) = paintFill else { return nil }
        return bead(for: code)
    }

    private func groupKey(_ fill: PartCellFill) -> String {
        fill.groupKey
    }

    /// 色号 → 色库里那颗豆子。
    ///
    /// **MARD 不能走 `findColor(byCode:preferSystem:)`** —— 那个重载在
    /// `preferSystem == .mard` 时直接返回 nil（MARD 自己那一路留给了
    /// `findColor(byMardCode:)`）。走它的话 MARD 图纸上每个色号都取不到颜色，
    /// 色号栏和识别结果那一层会一起退成同一片灰（两处的 fallback 分别是
    /// `Surface.strong` 和 `Color(white: 0.5)`）—— 看上去像是所有色号合成了一种。
    /// 核对页栽过同样的坑，见 `PartsColorReviewStepView.bead(for:)`。
    private func bead(for code: String) -> BeadColor? {
        colorSystem == .mard
            ? inventoryManager.findColor(byMardCode: code)
            : inventoryManager.findColor(byCode: code, preferSystem: colorSystem)
    }

    /// 选色盘交回来的**永远是 mardCode**，而格子里存的是当前体系的显示码 ——
    /// 直接写回去的话，COCO / 漫漫这些非 MARD 图纸上会留下一个本体系查不到的码：
    /// 色块变灰、自成一组、跟色号表也对不上（同 `PartsColorReviewStepView.applyPickedCode`）。
    private func applyPickedCode() {
        defer { pickedCodes = [] }
        guard let picked = pickedCodes.sorted().first,
              let bead = inventoryManager.findColor(byMardCode: picked),
              bead.hasCode(for: colorSystem) else { return }
        let code = bead.displayCode(for: colorSystem)
        paintFill = .code(code)
        tool = .paint
        // 图纸上没用过的色号也要能画出来，不然补上去的格子是一片灰
        if overlayColors[code] == nil {
            overlayColors[code] = bead.color
            refresh()
        }
        if !paletteOptions.contains(where: { $0.key == code }) {
            paletteOptions.insert(
                PaletteOption(key: code, fill: .code(code), label: code, color: bead.color),
                at: 0
            )
        }
    }

    // MARK: - 载入

    private func load() async {
        guard !loaded else { return }
        defer { loaded = true }
        guard let part else {
            // 「还没判过色」那句话在这儿是假的，它会把用户支去重判一遍色 —— 而问题是
            // 这个 id 根本不在 parts 里，判多少遍色都没用。
            writeFailed = true
            AppLogger.shared.error("PartCellBrush", "part_missing_on_open", metadata: [
                "partId": partId.uuidString
            ])
            return
        }
        // **行列数跟 cells 的实际形状必须一致。** 落点换算这一屏用的是 `cells` 的行列数，
        // 而 `BeadPart.cellRect`（板子、抠图、核对页都走它）用的是 `rows`/`cols`
        // 这两个存储属性 —— 两边差一格，用户划的是这一格、改的却是旁边那一格，
        // 而且一声不响。宁可退回「还没判过色」让他重判，也不能让他在错位的网格上改。
        guard part.hasCells,
              part.rows == part.cells.count,
              part.cols == part.cells.first?.count else {
            if part.hasCells {
                AppLogger.shared.error("PartCellBrush", "cells_shape_mismatch", metadata: [
                    "partId": partId.uuidString,
                    "rows": "\(part.rows)", "cols": "\(part.cols)",
                    "cellRows": "\(part.cells.count)", "cellCols": "\(part.cells.first?.count ?? 0)"
                ])
            }
            return
        }
        cells = part.cells
        original = part.cells

        buildPalette()
        refresh()

        // 图纸上这一块的原样，裁的就是**格子矩阵那一块**，不多留边。
        //
        // 「对照图纸」是把它整个铺进同一个框里，跟零件那一层严丝合缝地换 ——
        // 多留一圈的话两层就对不上了，用户按一下图会跳一下，还以为是网格错位。
        // 网格本身准不准是「量格子」那一屏的事，不在这儿看。
        let area = gridArea
        // 跟工作图自己那块相交一次：工作图是从**零件区**裁出来的，靠边的零件会伸到
        // 它外面去 —— 裁图那边会自动切掉，而这边还按没切之前的范围铺，图就被拉开一点。
        let cropRect = area.intersection(work?.region ?? CGRect(x: 0, y: 0, width: 1, height: 1))
        region = area
        // 切剩的那块小到没意义就不给了 —— 半条边的「对照」比没有还容易看错。
        guard let source = work, cropRect.width > area.width * 0.5,
              cropRect.height > area.height * 0.5 else {
            // 没有图纸不是错（拼豆板那屏的图本来就可能裁不出来），但**必须说出来**：
            // 这一屏承诺的是「照着图纸改」，不说的话用户会对着一片灰底找豆子。
            // 没有图纸、或者这一块基本不在工作图里。改格子本身不受影响，
            // 只是没有图可对 —— 这件事要说出来（见 footer 那条提示）。
            imageUnavailable = true
            if let work {
                AppLogger.shared.warning("PartCellBrush", "brush_region_unusable", metadata: [
                    "partId": partId.uuidString,
                    "area": "\(area)", "workRegion": "\(work.region)"
                ])
            }
            return
        }
        let cropped = await Task.detached(priority: .userInitiated) {
            PartsThumbnailMaker.crop(source, normalized: cropRect)
        }.value
        guard !Task.isCancelled else { return }
        image = cropped
        imageRect = cropRect
        // 裁不出来就只画零件那一层，「对照图纸」那个按钮跟着不出现。
        // 记一笔：裁失败是确定性的（同一张图、同一块 bounds，重开几次都一样），
        // 不记的话事后无从查起（同 `PartsBoardStepView.loadOriginal`）。
        if cropped == nil {
            imageUnavailable = true
            AppLogger.shared.warning("PartCellBrush", "brush_crop_failed", metadata: [
                "partId": partId.uuidString,
                "crop": "\(cropRect)",
                "region": "\(source.region)",
                "workSize": "\(source.image.size)"
            ])
        }
    }

    /// 这张图纸用到的颜色，按颗数从多到少。
    ///
    /// 数的是**整张图纸**而不是当前这一块：漏判最多的往往是浅色，而浅色在这一块上
    /// 可能一颗都没被认出来 —— 只数这一块的话，用户要补的那个色号恰好不在栏里。
    private func buildPalette() {
        var counts: [String: Int] = [:]
        var fills: [String: PartCellFill] = [:]
        for part in parts {
            for row in part.cells {
                for cell in row where cell.needsBead {
                    let key = cell.groupKey
                    counts[key, default: 0] += 1
                    fills[key] = cell
                }
            }
        }

        var colors: [String: Color] = ["#any": Theme.ColorToken.Morandi.mauve]
        var options: [PaletteOption] = []
        var candidates: [BeadColor] = []
        for key in counts.keys.sorted(by: { (counts[$0] ?? 0) > (counts[$1] ?? 0) }) {
            guard let fill = fills[key] else { continue }
            switch fill {
            case .code(let code):
                let bead = bead(for: code)
                let color = bead?.color ?? Theme.ColorToken.Surface.strong
                colors[code] = color
                options.append(PaletteOption(key: code, fill: fill, label: code, color: color))
                if let bead { candidates.append(bead) }
            case .anyColor:
                guard allowsAnyColor else { continue }
                options.append(PaletteOption(
                    key: "#any", fill: .anyColor,
                    label: String(localized: "任意色"),
                    color: Theme.ColorToken.Morandi.mauve
                ))
            case .empty:
                break
            }
        }

        paletteOptions = options
        overlayColors = colors
        sheetColors = candidates
        // 默认补最常用的那个色号。
        //
        // **一个都没有时不能瞎给一个。** 早先这里退回 `.anyColor`，而单图纸模式压根没有
        // 「任意色」这一档：`SinglePatternFlowView.codeMatrix` 存盘时只写 `.code`，
        // 任意色被存成 nil、读回来是空 —— 用户画上去、颗数涨了、下次进来全没了，
        // 正是这个文件头承诺不做的事。现在宁可让「补上」先去挑一个色号。
        if let first = options.first {
            paintFill = first.fill
        } else if allowsAnyColor {
            paintFill = .anyColor
        } else {
            paintFill = nil
        }
    }
}

// MARK: - 识别结果那一层

/// 把格子矩阵画成一张 **rows × cols 像素**的位图，一格一个像素。
///
/// 为什么不用 SwiftUI 的 Canvas 一格一格描：单图纸模式一张图纸七万格，
/// 手指划一下就要重画七万个矩形，一秒钟几十次 —— 卡到没法用。位图只有
/// 几万个像素，重建一次是零点几毫秒，贴上去的时候按最终尺寸 + 最近邻放大，
/// 边界照样是硬的。
///
/// 画的是**零件本身**：有豆子的格子是它自己的颜色，空格透明、露出底下的板面。
/// 所以擦掉一格就是「这儿空了」，跟拼豆板上看到的是同一件事 —— 早先这一层是
/// 半透明盖在图纸原图上的，空格还得铺一层灰才看得出擦掉没有，而底下那颗豆子
/// 一直还在图上，用户得盯着灰度差判断自己那一下生效没有。
enum CellOverlayBitmap {
    /// 有豆子的格子画多实。留一点点透明，是为了「对照图纸」切过去的时候
    /// 两层看起来是同一块地方，而不是两张不相干的图。
    private static let beadAlpha: Double = 0.95

    static func make(cells: [[PartCellFill]], colors: [String: Color]) -> UIImage? {
        let rows = cells.count
        let cols = cells.first?.count ?? 0
        guard rows > 0, cols > 0 else { return nil }

        // 色号 → 已经乘好 alpha 的 RGBA（位图是 premultipliedLast）
        var table: [String: (UInt8, UInt8, UInt8, UInt8)] = [:]
        for (key, color) in colors {
            table[key] = premultiplied(color, alpha: beadAlpha)
        }
        let fallback = premultiplied(Color(white: 0.5), alpha: beadAlpha)
        // 空格全透明 —— 底下就是板面
        let empty: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)

        var bytes = [UInt8](repeating: 0, count: rows * cols * 4)
        for r in 0..<rows {
            let row = cells[r]
            for c in 0..<cols {
                let pixel: (UInt8, UInt8, UInt8, UInt8)
                if c < row.count, row[c].needsBead {
                    pixel = table[row[c].groupKey] ?? fallback
                } else {
                    pixel = empty
                }
                let offset = (r * cols + c) * 4
                bytes[offset] = pixel.0
                bytes[offset + 1] = pixel.1
                bytes[offset + 2] = pixel.2
                bytes[offset + 3] = pixel.3
            }
        }

        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(
                width: cols, height: rows,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cols * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { return nil }
        return UIImage(cgImage: cg)
    }

    private static func premultiplied(_ color: Color, alpha: Double) -> (UInt8, UInt8, UInt8, UInt8) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        let scale = alpha * Double(a)
        return (
            UInt8(max(0, min(255, Double(r) * scale * 255))),
            UInt8(max(0, min(255, Double(g) * scale * 255))),
            UInt8(max(0, min(255, Double(b) * scale * 255))),
            UInt8(max(0, min(255, scale * 255)))
        )
    }
}
