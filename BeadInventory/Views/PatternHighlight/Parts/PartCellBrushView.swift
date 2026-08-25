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
//  而用户要改的正是那个形状。
//
//  图纸原图放在**旁边那一块**：按「对照图纸」，画布对半分，图纸在前、格子在后，
//  两块同一块地方、同一个放大倍数、同一批格线（靠零件区边上的零件只铺到工作图切剩的
//  那块，见 `imageRect`），拖哪一块两块一起动。切竖着还是横着由画布形状定，见 `panes`。
//
//  早先是按一下把格子那一层整个换成图纸、原地盖住 —— 换过去看不见自己改的格子、
//  换回来看不见图纸，用户得来回按十几次，靠脑子记住上一眼看到的是什么。
//  要比的两样东西必须同时在眼里（同 `PartOriginalSheet` 那一屏）。
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
    /// 多数时候约等于 `gridArea`；两种情况下会不一样，都必须按它自己的范围画，
    /// 不能把图拉满整个框（那样格线跟豆子会整体错开）：
    ///   · 靠零件区边上的零件会被工作图切掉一条；
    ///   · 裁图把像素矩形向外取整了，于是比要的那块大一点点（见 `cropExact`）。
    @State private var imageRect: CGRect = .zero
    /// 画布画的是整张图纸的哪一块（归一化）。**永远等于 `gridArea`** ——
    /// `transform` 要一个存下来的值，而 `gridArea` 是每次从 `parts` 现算的。
    @State private var region: CGRect = .zero
    /// 零件那一层。一格一个像素画成位图，再按最终尺寸贴上去 ——
    /// 单图纸模式一张图纸七万格，用 Canvas 一格一格描的话，
    /// 手指划一下整屏重画七万个矩形，直接卡死。
    @State private var overlay: UIImage?
    /// 正在对照图纸原图（画布对半分，图纸在前、格子在后，方向见 `panes`）。
    ///
    /// **默认是关的**：不对照的时候格子占满整个画布。开着的时候两块各占一半，
    /// 共用同一个 `transform` —— 两块宽高一样，同一格就落在两块里同一个位置上。
    @State private var comparing = false
    /// 现在这一块还剩多少颗豆子。放 @State 而不是每次 body 现算 ——
    /// 七万格的图纸上，拖一下就要重数七万遍。
    @State private var beadCount = 0
    /// 往零件里写过东西（决定关掉时要不要落盘）。
    /// 「取消」那一次还原也算 —— 还原本身也得落盘，把之前写进去的盖回去。
    @State private var changed = false
    /// 写不回零件（`partId` 在 `parts` 里找不到了）。这时候屏幕上画什么都没用，
    /// 得当场告诉用户，别让他白擦一屏。
    @State private var writeFailed = false
    /// 图纸这一块没取到（没有原图、裁失败、或者只裁到一半）。这一屏承诺的是
    /// 「照着图纸改」，取不到就得说出来 —— 「对照图纸」那个按钮这时候整个不出现，
    /// 光是按钮消失，用户看不出为什么。
    @State private var imageUnavailable = false
    /// 零件那一层这次没画出来，屏幕上是上一次的样子。颗数照样在变 ——
    /// 不说的话用户会以为「数字在动、画面不动」是数字在骗人，然后对着已经空了的格子再擦一遍。
    @State private var overlayStale = false
    /// 用户挑的那个色号在这张图纸的色号体系里没有对应的
    @State private var pickUnusable = false

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
                } else if writeFailed {
                    // 「还没判过色」在这儿是假话，它会把用户支去重判一遍色 ——
                    // 那一步会洗掉他手工核对过的所有颜色，而且救不了这个问题。
                    ContentUnavailableView(
                        "这一块对不上任何零件了",
                        systemImage: "exclamationmark.triangle",
                        description: Text("退出去回零件清单看看。在这儿改也存不下来。")
                    )
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

    /// 对照时把画布对半分，中间留一条缝。返回单块的尺寸，以及**格子那一块的左上角**。
    ///
    /// **两块必须一样大**：整屏只有一个 `transform`，它是按 `canvasSize` 算的 ——
    /// 两块宽高一致，同一格才会落在两块里同一个位置上，扫一眼就对得上。
    ///
    /// **沿画布的长边切，不写死方向。** 一格在屏幕上是正方的（`aspectFitRect` 等比，
    /// 边长是 `min(paneW/cols, paneH/rows)`）—— 砍短边等于直接砍格子，砍长边多半不影响。
    /// 竖屏画布是高的，切高度；横屏是宽的，切宽度。写死一个方向的话另一个方向就是
    /// 最坏情况：上一版写死上下分，而横屏画布本来只剩两百来点高，再对半分两块都塞不下。
    ///
    /// **`editorOrigin` 是轴的唯一出口。** 手势那一层（`drawing` / `paneLocal` /
    /// `brushLocal`）只按分量减这个原点，对方向一无所知 —— 「切哪个轴」和
    /// 「谁在前谁在后」这两件事都只活在这个函数里，下次要改不必翻到别处。
    private func panes(in total: CGSize) -> (size: CGSize, editorOrigin: CGPoint) {
        guard showsCompare else { return (total, .zero) }
        let gap = Theme.Spacing.xs
        if total.height >= total.width {
            let h = max(1, (total.height - gap) / 2)
            return (CGSize(width: total.width, height: h), CGPoint(x: 0, y: h + gap))
        }
        let w = max(1, (total.width - gap) / 2)
        return (CGSize(width: w, height: total.height), CGPoint(x: w + gap, y: 0))
    }

    /// 现在是不是真的分开。没有图纸就永远不分 —— 分出来那一块是空的，
    /// 白白把格子挤小一半。
    private var showsCompare: Bool { comparing && image != nil }

    private var canvas: some View {
        GeometryReader { geo in
            let (pane, editorOrigin) = panes(in: geo.size)
            // 图纸在前（上 / 左）、格子在后 —— 跟 `editorOrigin` 是同一件事，
            // 谁也别单独改：反了就成了「划这一格改那一格」。
            let layout = editorOrigin.x > 0
                ? AnyLayout(HStackLayout(spacing: Theme.Spacing.xs))
                : AnyLayout(VStackLayout(spacing: showsCompare ? Theme.Spacing.xs : 0))
            ZStack(alignment: .topLeading) {
                layout {
                    if showsCompare {
                        patternPane.frame(width: pane.width, height: pane.height)
                    }
                    editorPane.frame(width: pane.width, height: pane.height)
                }
                // **手势只有这一层，盖在两块上面**，见 `gestureCatcher`。
                gestureCatcher(editorOrigin: editorOrigin)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .onAppear { setCanvasSize(pane) }
            .onChange(of: pane) { _, new in setCanvasSize(new) }
        }
    }

    /// 画布尺寸变了（转屏、开关对照）就得把平移量重新夹一遍 ——
    /// `clampPan` 的边界跟着尺寸走，不夹的话分栏之后图会整块跑到框外面去。
    private func setCanvasSize(_ size: CGSize) {
        canvasSize = size
        pan = clampPan(pan)
        lastPan = pan
    }

    /// 格子那一块（或者不分栏时的整块）：能擦能补的那一层。
    private var editorPane: some View {
        ZStack(alignment: .topLeading) {
            Theme.ColorToken.Surface.subtle

            if canvasSize.width > 0, rows > 0, cols > 0 {
                let box = transform.screenRect(gridArea)

                boardBase(box)

                // 按最终尺寸摆图，**不用 scaleEffect** —— 那是图层变换，
                // 放大走双线性平滑，`.interpolation(.none)` 管不到它，
                // 而这一屏要看的正是一颗豆子的边界（同 PartsCellSizeStepView）。
                if let overlay {
                    Image(uiImage: overlay)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)
                }

                gridLines
            }

            if showsCompare { paneCaption("现在的格子") }
        }
        .clipped()
    }

    /// 图纸那一块：图纸上这一块的原样。**只看不改** —— 这一块里划手指是挪图，
    /// 不管上面选的是「擦掉」还是「补上」：用户盯着图纸比对时手指多半落在图纸那边，
    /// 那一下要是也在画，他改掉的是自己正照着看的东西。
    private var patternPane: some View {
        ZStack(alignment: .topLeading) {
            Theme.ColorToken.Surface.subtle

            if canvasSize.width > 0, rows > 0, cols > 0, let image {
                let box = transform.screenRect(gridArea)
                let shot = transform.screenRect(imageRect)

                boardBase(box)

                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: shot.width, height: shot.height)
                    .position(x: shot.midX, y: shot.midY)

                gridLines
            }

            paneCaption("图纸原图 · 只能看，拖它挪画面")
        }
        .clipped()
    }

    /// 板底。空格子就是它 —— 擦掉一格，露出来的是「这儿没有豆子」，
    /// 而不是图纸上那颗还在那儿的豆子。
    ///
    /// **不能用 `Surface.elevated`**：它浅色下近乎纯白 —— 白豆子铺上去就是一片白，
    /// 用户分不出哪几格是空的、哪几格是白豆子，而这一屏问的正是「这儿到底有没有豆子」；
    /// 深色下它又整个变暗，同一张图两种模式下擦出来能不一样多。板底是「桌上那块板」，
    /// 深浅色用同一个值。
    ///
    /// **要亮，但不能待在纯灰那条轴上。** 亮是用户要的（中灰压得整屏发闷，而豆子
    /// 本身的颜色才是这一屏要看的东西）；离开纯灰是因为豆子里灰的太多了。
    ///
    /// 拿屏幕真正渲染用的那份色表（`allcolors.json`，599 个不重复色值）按
    /// `0.95×豆子 + 0.05×板底`（见 `CellOverlayBitmap.beadAlpha`）合成后算 CIE76 ΔE，
    /// 「跟空格糊在一起」的色号数是这样的 —— ΔE 2.3 是人眼刚能察觉的门槛：
    ///
    ///     板底              相对亮度   ΔE<5   最近的那个
    ///     #8C8C8C 中灰       0.26      1     #89858C  ΔE 4.6
    ///     #D6D6D6 浅灰       0.67      5     #D9D9D9  ΔE 1.0   ← 看不见了
    ///     #D4E6D3 极浅绿     0.75      0     #E0E3DA  ΔE 7.2   ← 现在这个
    ///
    /// 也就是说纯灰**越浅越危险**：近白那一段正是色表最密的地方。极浅绿比浅灰还亮，
    /// 撞车的色号却从 5 个降到 0 个 —— 亮和「分得开」并不冲突，冲突的是亮和**灰**。
    ///
    /// **别再往纯灰上调。** 真要更保险，得给空格加非颜色的线索（斜纹 / 棋盘格）
    /// 并让豆子完全不透明，不是继续挪这个值。
    private func boardBase(_ box: CGRect) -> some View {
        Rectangle()
            .fill(Self.boardColor)
            .frame(width: box.width, height: box.height)
            .position(x: box.midX, y: box.midY)
    }

    /// 板底：比白略深一档的极浅绿。为什么不是白的、为什么不能是灰的，见 `boardBase`。
    ///
    /// 它跟 `CellOverlayBitmap.beadAlpha`、`gridLines` 那两道描边共担同一条不变量
    /// ——「空格和白豆子必须分得出来」。**三个值要一起调**，动一个就得重看另外两个。
    ///
    /// `fileprivate` 而不是 `private`：`CellOverlayBitmap` 的文档按符号引用它。
    fileprivate static let boardColor = Color(red: 212 / 255, green: 230 / 255, blue: 211 / 255)

    /// 哪一块是哪一块。两块都是浅底加格线，不写字的话看一眼分不出来。
    private func paneCaption(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(Theme.ColorToken.Text.secondary)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 2)
            .background(Capsule().fill(.regularMaterial))
            .padding(Theme.Spacing.sm)
            .allowsHitTesting(false)
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
            // 反而把底下的格子盖住。
            //
            // **阈值 6 不是 9。** 9 是「板底还是白的、只描一道线」那会儿定的。现在
            // 「这一格有没有豆子」全靠板底和豆子的颜色差（见 `boardBase`），格线只管
            // 「同色两格之间的缝」—— 也就是只在用户想精确点一格时才要紧，而那时候
            // 他本来就会放大。降到 6 是为了少一次「一按对照图纸格线就没了」的突变：
            // 分栏把短边砍一半，原来刚过 9 的零件会一下掉到线以下。
            if cw >= 6, ch >= 6 {
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
                // **描两遍：宽的浅线打底，窄的深线压在中间。**
                // 只有一种颜色时，它必然在色域的一端消失 —— 白线看不见白豆子挨白豆子的缝，
                // 黑线看不见黑豆子挨黑豆子的缝，而这两处恰恰都是最需要数格子的时候。
                // **别把它当成「白豆子和空格的区别」。** 这里是整片铺线的，
                // 空格四周同样有缝 —— 格线只解决「同色两格之间的缝」，
                // 「这一格有没有豆子」从头到尾只靠颜色差，那是 `boardColor` 的事。
                // 线宽跟着格子缩，别让它吃掉超过八分之一格 —— 6pt 的格子上
                // 1pt 的线就占了六分之一，一片格子看着像一张网。
                let hair = min(1.0, cw / 8)
                context.stroke(path, with: .color(.white.opacity(0.30)), lineWidth: hair)
                context.stroke(path, with: .color(.black.opacity(0.28)), lineWidth: hair / 2)
            }

            context.stroke(Path(box), with: .color(Theme.ColorToken.Morandi.honey), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }

    /// 这一下算不算画：工具不是「挪图」，而且**起点**落在格子那一块。
    ///
    /// 两个分量一起判，所以横竖两种切法用的是同一行代码 —— 没切到的那个轴
    /// 原点是 0，那一维恒成立（见 `panes`）。
    private func drawing(from start: CGPoint, editorOrigin o: CGPoint) -> Bool {
        tool != .move && start.x >= o.x && start.y >= o.y
    }

    /// 整块画布上的一点 → 它所在那一块自己的坐标。两块共用同一个 `transform`，
    /// 所以两块里同一个 (x, y) 指的就是同一块内容，减掉那一块的左上角就行
    /// （图纸那一块的左上角就是 0,0，所以原样返回）。
    ///
    /// **只给捏合用。** 画笔必须走 `brushLocal`，理由见那里。
    private func paneLocal(_ point: CGPoint, editorOrigin o: CGPoint) -> CGPoint {
        point.x >= o.x && point.y >= o.y
            ? CGPoint(x: point.x - o.x, y: point.y - o.y)
            : point
    }

    /// 画笔专用的换算：**无条件**减掉编辑区的左上角，越过中缝就让它变成负数。
    ///
    /// 不能用 `paneLocal`：那个函数对落在图纸那一块的点原样返回，而这里返回值会被
    /// 当成「编辑区自己的坐标」喂给 `cellIndex(at:)` —— 差一点点的越界坐标会被读成
    /// 块内快到头的位置，也就是零件的**最后一行 / 最后一列**。于是手指往外挪 5pt，
    /// 笔尖跳到零件另一头，`paint` 的补线看到 steps 很大，把中间整条改掉。
    /// 那个点在框**里面**（只是在错的地方），所以 `paint` 开头「划到框外就清锚点」
    /// 那道保护拦不住它。变成负数之后 `cellIndex` 会返回 nil，走清锚点那条路。
    private func brushLocal(_ point: CGPoint, editorOrigin o: CGPoint) -> CGPoint {
        CGPoint(x: point.x - o.x, y: point.y - o.y)
    }

    /// 整块画布的手势层。**只能有这一层**，哪怕分成了两块。
    ///
    /// 一块挂一层试过，翻车：两指一上一下各落一块时，两边的 `MagnifyGesture` 各自
    /// 只拿到一根手指、缩放根本不触发，而落在格子那一块的那根被 `minimumDistance: 0`
    /// 的拖动当成画笔收下了 —— 下面那句 `rollbackStroke()` 本来就是拦这件事的，
    /// 但它拦不到另一层里的笔。实测：开着对照、工具停在「擦掉」、两指跨着中间那条缝
    /// 往外一撑，倍数一点没变，一整行豆子没了。
    ///
    /// - Parameter editorOrigin: 格子那一块的左上角（见 `panes`）。手势点是整块画布的
    ///   坐标，靠它换算回单块坐标；**起点**落在它前面（图纸那块）就只挪图。
    private func gestureCatcher(editorOrigin: CGPoint) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                SimultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // 两指捏合时别顺手画一道 —— 拦的是 `MagnifyGesture` **起来之前**
                            // 漏进来的那一两拍（见下面 `rollbackStroke()` 那段）。
                            //
                            // 另一件事，别跟上面那句混：试过在这儿拿两指中点做
                            // 「两指拖动挪图」，**拿不到连续数据** —— 捏合一旦起来，
                            // 这个回调就不再送有效事件，中点算不出平移量。
                            // 放大之后要挪，走的是「拖图纸那一条」或者切回「挪图」，见 `hint`。
                            guard pinchContentAnchor == nil else { return }
                            if drawing(from: value.startLocation, editorOrigin: editorOrigin) {
                                paint(at: brushLocal(value.location, editorOrigin: editorOrigin))
                            } else {
                                pan = clampPan(CGSize(
                                    width: lastPan.width + value.translation.width,
                                    height: lastPan.height + value.translation.height
                                ))
                            }
                        }
                        .onEnded { value in
                            // 认**起点**不认落点：一笔从格子那一块划到图纸那一块，
                            // 抬手时还得走 `endStroke()` 把这一笔记进撤销栈。
                            if drawing(from: value.startLocation, editorOrigin: editorOrigin) {
                                // 最后一段常常只随抬手事件送达，onChanged 没见过它 ——
                                // 不补这一下，快速划一道的末尾几格不会变
                                //（同 PartsBoardStepView 里 gestureCatcher 的 onEnded：
                                // 抬手前再 updateMove 一次）。
                                if pinchContentAnchor == nil {
                                    paint(at: brushLocal(value.location, editorOrigin: editorOrigin))
                                }
                                endStroke()
                            } else {
                                lastPan = pan
                            }
                        },
                    MagnifyGesture()
                        .onChanged { value in
                            if pinchContentAnchor == nil {
                                pinchScreenPoint = paneLocal(value.startLocation, editorOrigin: editorOrigin)
                                pinchContentAnchor = unzoomed(pinchScreenPoint)
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
            } else if overlayStale {
                warning("这一层这次没画出来，屏幕上的格子不作数 —— 底下那个颗数才是准的。",
                        icon: "exclamationmark.triangle", isError: true)
            } else if pickUnusable {
                warning("挑的那个色号在这张图纸的色号体系里没有对应的，换一个。",
                        icon: "paintpalette", isError: true)
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
            .onChange(of: tool) { _, _ in
                endStroke()
                // 顺手把捏合锚点清了。它只在 `MagnifyGesture.onEnded` 里清，而手势被
                // 系统打断时（来电、下拉通知中心、sheet 被拖走）那一下不保证送达 ——
                // 停在非 nil 的话，`gestureCatcher` 第一行就 return，画布从此不画也不挪，
                // 而且没有任何别的路径能清它。切工具是用户「怎么点都没反应」时最先试的动作。
                pinchContentAnchor = nil
            }

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
                // 要判「图纸上这儿到底有没有豆子」，按一下把图纸拉到旁边那一块，
                // 两块同一块地方、同一个倍数，扫一眼就对得上。收起来则格子占满整屏。
                //
                // **没有图纸时不摆这个按钮**：拉出来的那一块是空的，
                // 用户按到的是一个只会把格子挤小一半的开关，而且看不出为什么。
                if image != nil {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { comparing.toggle() }
                    } label: {
                        // 图标得预告**这一次**会分成什么样：`panes` 沿画布长边切，
                        // 竖屏是上下分（横的分割线）、横屏是左右分（竖的）。
                        // 不分栏时 `canvasSize` 就是整块画布，拿它判方向正好。
                        Label(comparing ? "收起图纸" : "对照图纸",
                              systemImage: comparing
                                  ? "rectangle"
                                  : (canvasSize.height >= canvasSize.width
                                     ? "rectangle.split.1x2" : "rectangle.split.2x1"))
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
                    Button {
                        paintFill = option.fill
                        // 挑到一个能用的，「换一个」那句就不成立了。不清的话它会一直挂着，
                        // 而且它排在告警链最前面，会把「这次取不到图纸上的这一块」永远顶掉。
                        pickUnusable = false
                    } label: {
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
        // 画笔状态下拖动是画，不是挪 —— 放大之后想看旁边那块，得知道从哪儿挪。
        // 分栏时图纸那一块就是现成的把手（那儿只挪不画），收起来时只能切回「挪图」。
        // **别写「上面那条」**：`panes` 沿画布长边切，横屏时图纸在左边。
        case .erase:
            return showsCompare
                ? String(localized: "手指划过要去掉的格子。放大后想挪，拖图纸那一块。")
                : String(localized: "手指划过要去掉的格子。放大后想挪，先切回「挪图」。")
        case .paint:
            if paintFill == nil { return String(localized: "先在上面挑一个色号，再划过要补上的格子。") }
            return showsCompare
                ? String(localized: "手指划过要补上的格子。放大后想挪，拖图纸那一块。")
                : String(localized: "手指划过要补上的格子。放大后想挪，先切回「挪图」。")
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
        // 而那条带看起来就像他自己画的那一笔。框只占画布中间一块（长边方向两头是留白），
        // 划出去太容易了。
        guard let hit = cellIndex(at: point) else {
            stroke.last = nil
            return
        }
        let changesBefore = stroke.changes.count
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
        // **一次事件刷一遍，不是一格刷一遍；这一下没改到东西就一遍都不刷。**
        // `refresh` 要重数所有格子 + 重建整张位图；一次快速滑动光补线就能改十几格，
        // 放在 `setCell` 里就是同一个触摸事件里重建十几遍。而手指在同一格里挪动时
        // 每秒还有几十个事件，一格都没变，照样刷就是白烧电。
        // 单图纸模式一张七万格，位图方案本来就是为了避掉这种量。
        if stroke.changes.count != changesBefore { refresh() }
    }

    private func setCell(row: Int, col: Int, to fill: PartCellFill) {
        // 按**这一行自己的**长度判界。全仓库别处（`CellOverlayBitmap.make`、
        // `BeadPart.rotatedCells`、`PartsColorReviewStepView.apply`）都当 cells 可能不齐，
        // 早先只有这里拿第 0 行的宽度去索引别的行 —— 而这里是唯一会崩、不是跳过的地方。
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
        writeFailed = false
        changed = true
    }

    /// 格子变了之后，屏幕上跟着变的那几样
    private func refresh() {
        beadCount = cells.reduce(0) { $0 + $1.filter(\.needsBead).count }
        // 建不出来就**留住上一张**。无条件赋值的话，识别结果那一层会在用户下一笔之后
        // 整个消失 —— 他读到的是「我把东西全擦没了」，而真相是一张位图没建出来。
        if let built = CellOverlayBitmap.make(cells: cells, colors: overlayColors) {
            overlay = built
            overlayStale = false
        } else if !overlayStale {
            // 只报一次：`refresh` 是按触摸事件调的，真坏了会刷屏。
            overlayStale = true
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
    /// `buildPalette` 一律退回 `Theme.ColorToken.Surface.strong`，于是色号栏和零件那一层
    /// 一起变成同一片中性灰 —— 看上去像是所有色号合成了一种。
    /// 同 `PartsColorReviewStepView.bead(for:)`。
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
        guard let picked = pickedCodes.sorted().first else { return }
        guard let bead = inventoryManager.findColor(byMardCode: picked),
              bead.hasCode(for: colorSystem) else {
            // 用户明明挑了一个，回来却什么都没变 —— 下一笔又把选色盘弹出来，
            // 成了一个反复问同一个问题的死循环。说清楚这个色号在这张图纸的体系里没有。
            pickUnusable = true
            AppLogger.shared.warning("PartCellBrush", "picked_code_unusable", metadata: [
                "picked": picked, "system": "\(colorSystem)"
            ])
            return
        }
        pickUnusable = false
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
        // 「对照图纸」把它摆在旁边那一块，两块共用同一个 `transform` —— 多留一圈的话
        // 两块的同一格就错开了，而用户正是扫一眼比这两块。
        // 网格本身准不准是「量格子」那一屏的事，不在这儿看。
        let area = gridArea
        // 跟工作图自己那块相交一次：工作图是从**零件区**裁出来的，靠边的零件会伸到
        // 它外面去 —— 裁图那边会自动切掉，而这边还按没切之前的范围铺，图就被拉开一点。
        let cropRect = area.intersection(work?.region ?? CGRect(x: 0, y: 0, width: 1, height: 1))
        region = area
        // 切剩的那块小到没意义就不给了 —— 半条边的「对照」比没有还容易看错。
        guard let source = work, cropRect.width > area.width * 0.5,
              cropRect.height > area.height * 0.5 else {
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
        // 要**真正裁到的那一块**，不是我们要的那一块：裁图会把像素矩形向外取整，
        // 拿要的那块去铺，图整体会拉伸一点点，格线跟豆子对不上 ——
        // 而用户只会以为是网格没量准，跑回「量格子」白推半天。
        let cropped = await Task.detached(priority: .userInitiated) {
            PartsThumbnailMaker.cropExact(source, normalized: cropRect)
        }.value
        guard !Task.isCancelled else {
            // 取消 ≠ 成功。不说一句的话，「对照图纸」那个按钮凭空不见了，没人猜得到为什么。
            imageUnavailable = true
            return
        }
        image = cropped?.image
        imageRect = cropped?.rect ?? cropRect
        // 裁不出来就只剩格子那一块，「对照图纸」那个按钮跟着不出现。
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

// MARK: - 零件那一层

/// 把格子矩阵画成一张 **rows × cols 像素**的位图，一格一个像素。
///
/// 为什么不用 SwiftUI 的 Canvas 一格一格描：单图纸模式一张图纸七万格，
/// 手指划一下就要重画七万个矩形，一秒钟几十次 —— 卡到没法用。位图只有
/// 几万个像素，重建一次是零点几毫秒，贴上去的时候按最终尺寸 + 最近邻放大，
/// 边界照样是硬的。
///
/// 画的是**零件本身**：有豆子的格子是它自己的颜色，空格透明、露出底下那块板面
/// （`PartCellBrushView.boardColor`）。板面刻意不是纯白、也刻意不是灰的 ——
/// 白豆子铺在白板面上「空格」和「白豆子」长得一模一样，而灰板面会轮到灰豆子
/// 分不出来（那一段色号最密），理由和实测数字见 `boardBase`。
/// 所以擦掉一格就是「这儿空了」，跟拼豆板上看到的是同一件事 —— 早先这一层是
/// 半透明盖在图纸原图上的，空格还得铺一层灰才看得出擦掉没有，而底下那颗豆子
/// 一直还在图上，用户得盯着灰度差判断自己那一下生效没有。
enum CellOverlayBitmap {
    /// 有豆子的格子画多实。剩下那 5% 是板面透出来的一丝：在现在这块板面下，它让每颗
    /// 豆子往板面方向漂约 0.04 亮度 —— 肉眼看不出，但**算「豆子跟空格差多少」时得带上它**
    /// （`boardBase` 里那张表就是按 `0.95×豆子 + 0.05×板底` 合成后算的）。
    ///
    /// 留着只因为它无害。哪天要让豆子颜色跟图纸严格对得上（比色时），把它改成 1 就行，
    /// 但那时候 `boardBase` 那张表要重算。
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
        // 色号查不到时的兜底。**不能挑一个跟板面差不多的颜色** —— 那样这一格看起来
        // 就是「空的」，而查不到色号的格子恰恰是最需要用户看见、手工改掉的那一批。
        // 挑一个没有哪个色号长这样的品红（对现在这块板面 ΔE 92），
        // 它出现在屏幕上就等于「这格没认出来」。
        let fallback = premultiplied(Color(red: 0.85, green: 0.15, blue: 0.75), alpha: beadAlpha)
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
