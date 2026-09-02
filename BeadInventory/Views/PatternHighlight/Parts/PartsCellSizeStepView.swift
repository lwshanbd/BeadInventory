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
//  ## 格距默认全图共用，格线位置一个零件一个；对好的零件连格距一起锁
//
//  同一张纸上豆子一样大，所以**还没对过的零件共用一个格距**，在其中任何一个上调都一样。
//  但用户点过「对齐了」的零件会连格距带格线一起锁住（`isLocked` / `ownCalibration`）：
//  它当时按多大的格子对好的就一直是多大，在它身上调加减号也只改它自己
//  （`setCellPitch`）。不这样的话，他挨个对了二十个零件，在第二十一个上动一下就把
//  前二十个全推走了。
//
//  **格线位置不是。** 图纸上的零件是各画各的 —— 零件 A 的格线和零件 B 的格线压根不属于
//  同一批。早先整张图共用一个相位，于是「这个对齐了、换一个又对不上」，怎么推都推不好，
//  因为它数学上就不成立。现在是：格距由用户定（加减号一次 0.1 像素），
//  然后拿这个格距**一个零件一个零件地找它自己的格线**（`PartsPitchEstimator.fitOrigin`）。
//
//  所以主按钮是「对齐了，看下一个」，**所有零件都要过一遍**（大的排前面，格线多最容易
//  看出偏没偏）：翻到哪个零件就先按当前格距给它对一次，用户看到的是已经对好的，
//  只需要点头或者微调。不想看完的随时「不看了，完成」—— 没翻到过的那些会在离开
//  这一屏之前一起对完，只是没人拿眼睛验过。
//
//  更早还试过「每个零件拿自己的 bbox 均分」。那个是错的：bbox 带一圈抗锯齿毛边，
//  每个零件毛边多少不一样，均分出来的格线跟豆子缝没有关系。要按图上的周期信号去找。
//
//  **正在看的那一块，格线位置只认 `frameOrigin` 一个来源。** 屏幕上画的那片格线是从它
//  铺出来的，写回去的也必须是同一张。`phase(of:)`（上一张网格的左上角）只能用在不在
//  屏幕上的那些零件身上 —— 它跟 `frameOrigin` 差着整数个「当时的」格子，格距一改，
//  这个前提当场作废，两张网格能差出小半格。同理，`refitAllParts` 也不重找当前这一块：
//  用户刚拿眼睛验过的东西，不该在他按下一个按钮时被估计器改掉。
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
    /// 对完一个零件点「对齐了，看下一个」时调一下 —— 把这一屏的进度立刻落盘。
    /// 不然对了半天中途退出去，对好的网格全丢。
    let onConfirmPart: () -> Void
    let onContinue: () -> Void

    // 单图纸模式（`SinglePatternFlowView`）对的是**整张图纸**，它把整张图纸当成一个
    // 「零件」交给这一屏 —— 量格子这件事两种模式一模一样，没有理由再写一份。
    // 下面三个开关只改称呼和两处控件，算法一个字都不分叉。
    /// 这一屏在对什么。nil = 「零件 N」+「第几 / 共几个」（多零件）。
    var subjectLabel: LocalizedStringKey?
    /// 能不能删掉当前这个。单图纸不能：删掉整张图纸没有任何意义。
    var allowsDelete = true
    /// 能不能把当前这个标成插件。单图纸不能：一共就一张图纸，没有「分开排板」这件事。
    var allowsConnectorMark = true
    /// 「清掉颜色重新对格子」到底会清掉多少。**默认按多零件说实话**：
    /// 那边「再判一次」走的是 `runClassification()`，它重判**整张图纸的每一个零件**
    /// 并整个替换 `parts` —— 只说「清掉这一个」是骗人，四十九个零件手工核对过的
    /// 颜色会一起没。单图纸只有一块，所以那边传自己的说法。
    var regridCost: LocalizedStringKey =
        "这个零件判好的颜色会清掉，回「核对颜色」时会自动把这一块重判一遍。别的零件不动，框和位置也不动。"
    /// 一进来就翻到这一块。核对页点「看零件 → 回去重对这一块」时给 ——
    /// 不给的话用户落在第一个零件上，还得自己在四十九块里翻到刚才那一块。
    var focusPartId: UUID?
    /// 「对好了，回核对颜色」。非 nil 时主按钮变成它。
    ///
    /// 用户是特地为某一块回来的，不该被逼着把剩下四十八块也一路翻到底 ——
    /// 而这一屏原本唯一的出口是走到最后一个零件再进判色。
    var onReturn: (() -> Void)?
    /// 格线一挪，就把这一块判好的颜色当场作废（见 `writeBackCurrentPart`）。
    ///
    /// **只有下游会自动补判时才能开。** 多零件模式回到核对页会由
    /// `PartsSheetFlowView.classifyMissingParts()` 把空着的那一块重判回来，用户看到的是
    /// 「这块重判了一遍」；单图纸那边没有补判，作废等于整张图纸的颜色凭空消失，
    /// 他还得自己回上一步重判一次 —— 那是另一件事，不该顺手在这里做掉。
    var clearsColorsWhenGridMoves = false

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
    /// 正要删掉的那个零件。删一个零件会连带丢掉它已经判好的颜色和摆好的位置，
    /// 而这一屏是一下就能点到的，所以问一句。
    @State private var deletingPart: BeadPart?
    /// 正要为了改格子清掉这一块判好的颜色。见 `pitchLocked` 旁边那个按钮。
    @State private var unlockingPitch = false

    /// 已经翻到哪一块了。**记 id，不能记一个 Bool**：这一屏的 `@State` 在导航栈里活着，
    /// 用户第一次正常走过「量格子」时 `focusPartId` 还是 nil，记 Bool 的话那一次就把
    /// 「翻过了」用掉了 —— 之后从核对页指名回来，跳转会被静默跳过，落在上次停的那一块上，
    /// 而 `focusGridOnArrival` 也永远是 nil（作废旧颜色那道防线跟着一起失效）。
    @State private var focusedPartId: UUID?

    /// 一块零件的网格形状。判「动过没有」只看格线位置（`gridRect`）和行列数。
    private struct GridShape {
        let rect: CGRect?
        let rows: Int
        let cols: Int

        init(_ part: BeadPart) {
            rect = part.gridRect
            rows = part.rows
            cols = part.cols
        }

        /// 真的挪过了吗。**刻意不给 `Equatable`**：光是进这一屏，`syncFrameToLattice`
        /// 改一下 `frameOrigin` 就会触发 `writeBackCurrentPart` 把 `gridRect` 按
        /// `rect.width / cols` 原样重算一遍写回去 —— 数学上幂等，浮点上差最后一两位。
        /// 拿 `==` 比，「什么都没碰」也会被判成改过，用户手工改好的色号白清一次。
        ///
        /// 容差 1e-9：方向键一次至少推一个源图像素（归一化下 ≥ 2.5e-4），隔着五个数量级。
        func moved(from old: GridShape) -> Bool {
            if rows != old.rows || cols != old.cols { return true }
            guard let a = rect, let b = old.rect else { return (rect == nil) != (old.rect == nil) }
            let tolerance = 1e-9
            return abs(a.minX - b.minX) > tolerance || abs(a.minY - b.minY) > tolerance
                || abs(a.width - b.width) > tolerance || abs(a.height - b.height) > tolerance
        }
    }

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

    /// 要过一遍的零件：**全部，就按零件清单的顺序**。
    ///
    /// 这里以前只取最大的十二个（理由是「全图共用一张网格，看完最大的就够下结论」），
    /// 后来改成全部但按面积排。两个都是错的：
    /// - 只看十二个 —— 格线改成一个零件一个之后，剩下那些各有各的格线，没人看过；
    /// - 按面积排 —— 用户看到的编号一路乱跳（第一个是「零件 43」），跟零件清单对不上号，
    ///   而「大零件先看」这点好处在每个零件都要过一遍之后根本不存在。
    private var samples: [BeadPart] { parts }

    private var sample: BeadPart? {
        guard !samples.isEmpty else { return nil }
        return samples[min(sampleIndex, samples.count - 1)]
    }

    /// 当前零件用的那张标定：格距 + 这个零件自己的相位（`frameOrigin`）。
    ///
    /// 图纸上的零件是各画各的，格线不共用（用户拿真实图纸确认过）。默认拿全局那个格距，
    /// **但用户已经点过「对齐了」的零件用它自己的** —— 它当时是按多大的格子对好的，
    /// 之后在别的零件上把格距推到哪里都跟它无关。
    ///
    /// 这一条不只是显示问题。屏幕上的格线、黄框、「一格多少像素」、以及用户在这个零件上
    /// 再动一下时写回去的值，全都从这里来。这里要是取了全局格距，用户翻回一个对好的零件，
    /// 看到的就是别处调出来的数字和按那个数字画的格线 —— 他只要再碰一下，
    /// 这个零件就真的被改成那个格距了。锁住数据而不锁住这里，等于没锁。
    private var sampleCalibration: PartsGridCalibration? {
        guard let sample else { return nil }
        var c: PartsGridCalibration
        if let own = ownCalibration(of: sample) {
            c = own
        } else {
            guard let calibration, calibration.isUsable else { return nil }
            c = calibration
        }
        c.originX = Double(frameOrigin.x)
        c.originY = Double(frameOrigin.y)
        return c
    }

    /// 这个零件自己那套格距，从它已经定好的网格反推（格距 = 网格宽 ÷ 列数）。
    ///
    /// **锁住的零件一律走这里，判过色的也算**（曾经把判过色的排除在外，那是个会毁数据的
    /// 洞）：`writeBackCurrentPart` 是本文件唯一不查锁的写入路径，而它拿的就是这个函数的
    /// 结论。判过色的零件要是在这儿退回全局格距，用户从核对页退回「量格子」——
    /// 光是进屏幕，`syncFrameToLattice` 改一下 `frameOrigin` 就会触发一次写回 ——
    /// 它的 rows/cols 当场按全局格距重算，而 `cells` 还是老形状，几天的核对成果整片错位。
    ///
    /// 反过来，从零件自己的网格反推格距之后，同样的写回算出来的还是同一张网格
    /// （`PartsGrid(covering:)` 保证 `rect.width == cols * cellWidth`），写回变成幂等的，
    /// 那个洞就不存在了。
    private func ownCalibration(of part: BeadPart) -> PartsGridCalibration? {
        guard isLocked(part),
              let rect = part.gridRect, part.rows > 0, part.cols > 0,
              rect.width > 0, rect.height > 0 else { return nil }
        return PartsGridCalibration(
            cellWidth: Double(rect.width) / Double(part.cols),
            cellHeight: Double(rect.height) / Double(part.rows),
            originX: Double(rect.minX),
            originY: Double(rect.minY)
        )
    }

    /// 改格距的唯一入口，替掉了「直接给 `calibration` 赋值」。
    ///
    /// - 当前零件是用户确认过、**还没判色**的：**只改它自己**，全局那个数一动不动。
    ///   所以在这个零件上调加减号是有反应的（不然锁住就成了按钮失灵），而后面还没对的
    ///   零件也不会被这一下带偏 —— 它们等的是全局那个数。
    /// - 否则：改全局，`onChange(of: calibration)` 里的 `writeBack` 会带动所有还没锁的零件。
    ///
    /// 这里的条件**不能**图省事写成 `ownCalibration(of:) != nil` —— 那个现在把判过色的
    /// 零件也算进来了（见它的注释），而改判过色零件的格距会连行列数一起改，`cells` 当场错位。
    /// 判过色的零件在这一屏根本不该改格距，界面上那几个按钮也是禁用的。
    private func setCellPitch(width: Double, height: Double) {
        if let sample, sample.isGridConfirmed, !sample.hasCells,
           let index = parts.firstIndex(where: { $0.id == sample.id }) {
            let own = PartsGridCalibration(cellWidth: width, cellHeight: height,
                                           originX: Double(frameOrigin.x),
                                           originY: Double(frameOrigin.y))
            applyGrid(to: index, phase: frameOrigin, calibration: own)
            return
        }
        calibration = PartsGridCalibration(
            cellWidth: width, cellHeight: height,
            originX: calibration?.originX ?? Double(frameOrigin.x),
            originY: calibration?.originY ?? Double(frameOrigin.y)
        )
    }

    /// 当前零件落在它自己那张网格上的那块（行列数就是从这儿来的）
    private var grid: PartsGrid? {
        guard let sample, let c = sampleCalibration else { return nil }
        return PartsGrid(covering: sample.bounds, calibration: c)
    }

    /// 黄框在整张图纸上的归一化矩形。同样用当前零件那套格距（见 `sampleCalibration`）。
    private var frameRect: CGRect? {
        guard let c = sampleCalibration, c.isUsable else { return nil }
        return CGRect(x: frameOrigin.x, y: frameOrigin.y,
                      width: CGFloat(c.cellWidth), height: CGFloat(c.cellHeight))
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
        .navigationTitle("测量网格")
        .navigationBarTitleDisplayMode(.inline)
        // 翻到指定那一块。**认 `focusPartId` 本身，不能只在 `onAppear` 里做一次**：
        // 这一屏被 push 回来时 `onAppear` 发不发是 SwiftUI 的事，赌不得。
        // `initial: true` 让它照样赶在底下那两个 `.task` 之前 —— 晚一步的话
        // `loadSample` 会先给第一个零件白裁一张图，正确那一块的图也跟着晚出来。
        .onChange(of: focusPartId, initial: true) { _, _ in focusRequestedPart() }
        // 工作图也算进 id：进来时先拿到的是低清兜底版，高清版在后台裁好之后才换上来。
        // 认零件的 **id** 而不是下标：删掉一个非末尾的零件时下标不变，后面那个顶上来 ——
        // 只认下标的话这一句不会重跑，画布上留着的还是已经删掉那个零件的图，
        // 而 `sample` 已经指向顶上来的那一个。接着按「对齐了」，确认标记就盖到了
        // 一个用户根本没看过的零件上，从此自动对齐再也不管它。
        .task(id: "\(sample?.id.uuidString ?? "")|\(work.image.size)") { await loadSample() }
        .task { await estimateIfNeeded() }
        // 推格线只动当前这个零件 —— 别的零件有它们自己的格线，凭什么跟着走
        .onChange(of: frameOrigin) { _, _ in writeBackCurrentPart() }
        // 全局格距改了，**还没锁住的**零件都要重算；但各自的相位保持不变。
        // 锁住的那些由 writeBack 自己绕开（对好的零件不该被后面的调整推走）。
        .onChange(of: calibration) { _, _ in writeBack() }
        .confirmationDialog(
            "删掉这个零件？",
            isPresented: Binding(get: { deletingPart != nil },
                                 set: { if !$0 { deletingPart = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { deleteCurrentPart() }
            Button("取消", role: .cancel) { deletingPart = nil }
        } message: {
            Text("已识别的颜色和拼豆板上的位置将一并被清除。")
        }
        .confirmationDialog(
            "重新对格子大小？",
            isPresented: $unlockingPitch,
            titleVisibility: .visible
        ) {
            Button("清掉颜色，重新对", role: .destructive) { clearCellsForRegrid() }
            Button("取消", role: .cancel) { unlockingPitch = false }
        } message: {
            Text(regridCost)
        }
    }

    /// 删掉当前这个零件。删完停在原地 —— 后面那个会顶上来，正好接着看。
    private func deleteCurrentPart() {
        guard let target = deletingPart,
              let index = parts.firstIndex(where: { $0.id == target.id }) else { return }
        parts.remove(at: index)
        deletingPart = nil
        sampleIndex = min(sampleIndex, max(0, samples.count - 1))
    }

    /// 「插件」开关。
    ///
    /// **不用 `Toggle` + `.toggleStyle(.button)`**：那套的选中态是交给按钮样式画的，
    /// 在这一屏这个字号上开和关几乎看不出差别，而这是一个按下去在本屏没有任何
    /// 其它反馈的开关 —— 分不出状态就等于按了不知道有没有按上。这里照拼豆板那排板子片
    /// 的写法来：选中 = 填色 + 描边，隔着一米也认得出。
    private func connectorChip(for part: BeadPart) -> some View {
        let on = part.isConnectorPart
        return Button {
            setConnector(!on, for: part)
        } label: {
            Label("插件", systemImage: "puzzlepiece.extension.fill")
                .font(.footnote.weight(.medium))
                .foregroundColor(on
                                 ? Theme.ColorToken.Morandi.mauve
                                 : Theme.ColorToken.Text.secondary)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.xs)
                .background(
                    Capsule().fill(on
                                   ? Theme.ColorToken.Morandi.mauve.opacity(0.22)
                                   : Theme.ColorToken.Surface.elevated)
                )
                .overlay(
                    Capsule().stroke(on ? Theme.ColorToken.Morandi.mauve : Color.clear,
                                     lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
    }

    /// 标 / 取消标插件。
    ///
    /// 取消时写回 nil 而不是 false：这个字段的缺省就是「不是插件」，
    /// 存个 false 进去只会让每张图纸的 JSON 白长一截。
    ///
    /// 这里**不碰网格、不碰颜色**，所以不必像改格线那样作废什么东西 ——
    /// 标不标插件只影响最后排板子时它落在哪一块板上。
    private func setConnector(_ on: Bool, for part: BeadPart) {
        guard let index = parts.firstIndex(where: { $0.id == part.id }) else { return }
        parts[index].isConnector = on ? true : nil
        // 标一个存一个，跟点「对齐了」一样：一张图纸四十九个零件是能横跨好几天的活，
        // 不该等到走完整条流程才落盘。
        onConfirmPart()
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
                    ProgressView("正在测量…")
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
        setCellPitch(width: Double(dragStartCell.width * scale),
                     height: Double(dragStartCell.height * scale))
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(spacing: Theme.Spacing.md) {
            if let sample {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(subjectLabel ?? LocalizedStringKey(sample.displayName(order: sampleIndex)))
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(Theme.ColorToken.Text.primary)
                    // 对过的打个勾。用户翻回来时要能一眼看出「这个我确认过了」——
                    // 也才解释得了为什么后面调格距它没跟着动。
                    if sample.isGridConfirmed {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundColor(Theme.ColorToken.Status.success)
                    }
                    if let grid {
                        Text("\(grid.cols) × \(grid.rows) 格")
                            .font(.footnote.monospacedDigit())
                            .foregroundColor(Theme.ColorToken.Text.tertiary)
                    }
                    Spacer()
                    if allowsDelete {
                        // 一个一个过的时候才发现「这块根本不是零件」（水印、一行字）是常事，
                        // 而这一屏原来只能退回零件清单去删，回来又得从头翻。
                        Button(role: .destructive) {
                            deletingPart = sample
                        } label: {
                            Image(systemName: "trash").font(.footnote)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(Theme.ColorToken.Status.error)
                    }
                    // 还剩几个要看。一个一个过的时候，「还有多少」是唯一会让人
                    // 愿意继续按下去的信息 —— 不写的话按第三下就开始怀疑没有尽头。
                    // 只有一个的时候不写：「1 / 1」只会让用户去找另外那些。
                    if samples.count > 1 {
                        Text("\(sampleIndex + 1) / \(samples.count)")
                            .font(.footnote.monospacedDigit())
                            .foregroundColor(Theme.ColorToken.Text.tertiary)
                    }
                }

                // 插件的标记摆在这一屏，是因为这里是唯一一个「一个零件一个零件过一遍」的
                // 地方：用户翻到哪一块，眼前就是那一块的大图，认得出它是不是插件。
                // 零件清单那屏是一片缩略图，看不清；到了拼豆板那屏，板已经排完了。
                if allowsConnectorMark {
                    HStack(spacing: Theme.Spacing.sm) {
                        connectorChip(for: sample)

                        // 这一句说的是按下去之后板子会变成什么样，不是「插件是什么」。
                        // 不写的话，这个开关按下去在本屏一点变化都没有 ——
                        // 效果要翻过三屏、到拼豆板那儿才看得见。
                        Text("排拼豆板时单独占一块板")
                            .font(.caption)
                            .foregroundColor(Theme.ColorToken.Text.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
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
                        if let sample { Task { await refit(part: sample) } }
                    } label: {
                        Label("使用此大小", systemImage: "checkmark")
                            .font(.footnote.weight(.medium))
                    }
                }

                Text("黄色方框代表一格：拖动框体可移动位置，拖动右下角圆点可调整大小；在空白处拖动可平移图片。")
                    .font(.footnote)
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                    nudgePad
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        // 判过色的零件改不了格距（改了行列数，已经核对好的颜色会整片错位），
                        // 所以下面那几个按钮是灰的。灰着不说话是最难受的一种 ——
                        // 用户会以为 App 坏了，而不是「这里本来就不让改」。
                        // 锁住时这句话只回答一件事：**现在能做什么**。
                        // 「这个已经判过色了，格子大小暂时改不了 —— 改了颜色会整片错位」
                        // 是在讲系统内部出了什么事，用户要的是「我能干嘛、代价是什么」。
                        // 「每个零件各有各的格线」在单图纸模式下也是废话：一共就一张图纸。
                        Text(pitchLocked
                             ? "颜色已识别：可调整格线位置，但调整网格大小需要重新识别一次。"
                             : (samples.count > 1
                                ? "网格线需对齐豆子之间的间隙。每个零件的网格线各自独立。"
                                : "网格线要落在豆子和豆子的缝上。"))
                            .font(.footnote)
                            .foregroundStyle(Theme.ColorToken.Text.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        // 灰按钮必须给一条出路。
                        //
                        // 用户回到这一屏，十有八九就是因为格子不对；而判过色之后
                        // 「一格多少像素」「自动对齐」「重选格子大小」全是灰的 ——
                        // 他手里于是一件能改格子的工具都没有，只剩「这几个按钮是摆设」这一个结论。
                        // 单图纸模式尤其致命：只有一块，没有别的零件可以退而求其次。
                        //
                        // 所以把代价明说出来，让他自己决定：清掉这一块的颜色，格子就能改了。
                        // 反正往下走本来就要重判一次色。
                        if pitchLocked {
                            Button(role: .destructive) {
                                unlockingPitch = true
                            } label: {
                                Label("重新对格子大小", systemImage: "arrow.counterclockwise")
                                    .font(.footnote)
                            }
                        }

                        // 一格多少像素，加减号一次动 0.1 个像素。
                        //
                        // **必须摆在这一屏**（整张网格铺在零件上的这一屏），不能塞进
                        // 「重选格子大小」里 —— 那屏只显示一格。一格看着严丝合缝，
                        // 铺到第四十格照样偏出去半格；格距准不准只有看着整片格线才判断得了，
                        // 那就得能一边看着整片一边调。
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
                        .disabled(estimating || calibration == nil || pitchLocked)

                        HStack(spacing: Theme.Spacing.md) {
                            Button {
                                Task { await autoAlign() }
                            } label: {
                                Label("自动对齐", systemImage: "wand.and.stars").font(.footnote)
                            }
                            .disabled(estimating || pitchLocked)
                            Button {
                                enterPicking()
                            } label: {
                                Label("重新选择网格大小", systemImage: "square.dashed.inset.filled")
                                    .font(.footnote)
                            }
                            .disabled(estimating || pitchLocked)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }

            HStack(spacing: Theme.Spacing.sm) {
                // 翻过头了要能回去看一眼。四十九个零件一路按下来，发现上一个其实没对好
                // 却只能一路走到底再重进，是这一屏最容易把人逼疯的地方。
                Button {
                    sampleIndex -= 1
                } label: {
                    // 只定宽不定高：高度让 `.controlSize(.large)` 跟右边主按钮一起给，
                    // 写死 44 高会比主按钮高出一截。
                    Image(systemName: "arrow.left")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 24)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(sampleIndex == 0 || estimating || picking)

                // 一个零件一个零件地过：主按钮是「这个对了，换下一个」，不是「离开这一屏」。
                // 自动量出来的网格在个别零件上偏一点是常事，而偏了的那几个只有挨个看过去
                // 才发现得了 —— 早先主按钮直接跳去判色，用户看完第一个就走了。
                Button {
                    Task {
                        if let onReturn {
                            // 专门为一块回来的：确认 + 作废旧颜色一次写完，见 `finishRegrid`。
                            finishRegrid()
                            await refitAllParts()
                            onReturn()
                            return
                        }
                        // 先记下「这个我亲手对过了」：从此再改格距、再自动对齐都不动它。
                        confirmCurrentPart()
                        if isLastSample {
                            // 走到判色之前，用户没翻到过的那些零件也得按这个格距对一遍
                            await refitAllParts()
                            onContinue()
                        } else {
                            // 对完一个存一个。四十九个零件是能横跨好几天的活，
                            // 不能等走到最后一个才落盘。
                            onConfirmPart()
                            sampleIndex += 1
                        }
                    }
                } label: {
                    Label(mainActionTitle, systemImage: mainActionIcon)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(calibration == nil || estimating || picking)
            }

            // 剩下的不想一个个看了，随时能走。最后一个零件上不显示 —— 那时它和上面
            // 那个按钮是同一件事，摆两个只会让人以为有区别。
            if onReturn == nil, !isLastSample {
                Button("跳过并完成") {
                    Task {
                        await refitAllParts()
                        onContinue()
                    }
                }
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

    /// 主按钮上写什么。三种情形三句话，说的都是**按下去会去哪儿**。
    private var mainActionTitle: LocalizedStringKey {
        if onReturn != nil { return "返回核对颜色" }
        return isLastSample ? "已对齐，查看每格颜色" : "已对齐，查看下一个"
    }

    private var mainActionIcon: String {
        if onReturn != nil { return "checkmark" }
        return isLastSample ? "eyedropper" : "arrow.right"
    }

    /// 翻到核对页指定的那一块，并记下它现在的网格长什么样。
    private func focusRequestedPart() {
        guard let focusPartId else {
            // 这一趟结束了（容器把 `regridTarget` 收掉了）。这里也收干净 ——
            // 不收的话，用户为**同一块**再回来一次时 id 没变，下面那道判断会以为已经翻过了。
            focusedPartId = nil
            return
        }
        guard focusedPartId != focusPartId,
              let index = samples.firstIndex(where: { $0.id == focusPartId }) else { return }
        focusedPartId = focusPartId
        sampleIndex = index
    }

    /// 「对好了，回核对颜色」按下去时对当前这一块做的两件事，**合成一次写回**。
    ///
    /// 拆成 `confirmCurrentPart()` 再改一次 `parts[index]` 是不行的：两次都是
    /// get→mutate→set，而第二次的 get 不保证拿得到第一次刚写进去的值
    ///（`PartsBoardStepView.DragSession` 栽过一次），确认标记会被第二次原样盖回去。
    ///
    /// 网格一格没动就不清颜色 —— 用户可能只是回来看一眼确认没问题，
    /// 白清一次等于把他之前一格一格改过的色号扔了。
    private func finishRegrid() {
        // **认 `focusPartId`，不认 `sample`。** 用户在这一趟里可以按 ← 翻到别的零件去，
        // 认 `sample` 的话，「亲手对过」这个确认标记就盖到了一个无关的零件身上，
        // 而它从此被自动对齐和 `refitAllParts` 整个绕开。
        //
        // 作废旧颜色不在这里做 —— 那件事钉在 `writeBackCurrentPart`（改格线的唯一入口），
        // 这样按返回键、按「不看了，完成」离开也一样算数。
        let targetId = focusPartId ?? sample?.id
        guard let targetId, let index = parts.firstIndex(where: { $0.id == targetId }) else { return }
        parts[index].gridConfirmed = true
    }

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
        // **这里不解锁。** 曾经在这解过，理由是「锁着的话『就用这个大小』会被 `refit` 挡掉，
        // 用户拉了半天的框一点没落地」—— 有了 `setCellPitch` 之后那个理由就不成立了：
        // 拖把手走的是 `resize → setCellPitch`，对确认过的零件直接写它自己的网格，
        // 尺寸照样落地；被 `refit` 挡掉的只是自动重找相位，推格线随时可以补。
        //
        // 而解锁的代价很实在：解开的一瞬间 `ownCalibration` 就返回 nil，黄框改按**全局**
        // 格距画 —— 正好是用户刚刚特地走开的那个数字。这一屏又没有「取消」出口，
        // 于是点进来只想看一眼的人，出去时确认和绿勾都没了。
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
        // 第一次量整张图纸时，`loadSample` 里那一次对焦跑在 calibration 还没算出来的时候，
        // 什么都没做。不在这儿补一次的话，用户第一眼看到的正是这个函数存在的理由：一片糊。
        focusIfTooDense()
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
    ///
    /// 走 `sampleCalibration` 而不是全局那份 —— 用户确认过的零件要显示**它自己**的格距。
    private var cellPixels: Double {
        guard let c = sampleCalibration ?? calibration else { return 0 }
        return c.cellWidth * sheetPixelWidth
    }

    /// 写到小数点后两位：步长是 0.1，只显示一位的话用户看不出自己停在 20.03 还是 20.0，
    /// 而他要找的那个值恰恰藏在这一位里。
    private var cellPixelsText: String {
        let px = cellPixels
        guard px > 0 else { return "—" }
        return String(format: String(localized: "%.2f 像素"), px)
    }

    /// 加减号一次动多少源图像素。
    ///
    /// **0.1 而不是 1。** 一个像素太粗了：自动量出来的是 20.03 这种数，整数步只能在
    /// 19.03 / 20.03 / 21.03 之间跳，而对的那个值就在它们中间。粗调有拖把手和自动对齐，
    /// 这两个按钮是用来收尾的。
    private static let cellPixelStep = 0.1

    /// 加减号：一格的边长加 / 减一步。豆子是方的，所以高跟着宽走。
    private func changeCellPixels(by delta: Double) {
        guard sheetPixelWidth > 0 else { return }
        let next = max(2, cellPixels + delta)
        let width = next / sheetPixelWidth
        setCellPitch(width: width, height: width * sheetAspect)
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
        // **先把 `frameOrigin` 挪到新零件上，别等裁完图。**
        //
        // `sample` 是算出来的，`sampleIndex` 一改它当场就是新零件了；而 `frameOrigin`
        // 原来要等下面那次裁图 await 完才跟上。这中间的几百毫秒里 `frameOrigin` 属于
        // **上一块**零件，用户这时候点一下加减号，`writeBack` 就拿上一块的格线起点
        // 写到新零件头上（上一块要是自己锁着格距的，那个起点跟全局压根不是一套）。
        // 写完 `syncFrameToLattice` 又照着这个脏值把屏幕画出来，屏幕和存档「一致」了，
        // 用户看不出任何异常。
        //
        // 这一步只用 `sample.bounds` 和格距，跟图裁没裁好没关系，所以放前面没有代价。
        syncFrameToLattice()
        let source = work
        // 四周留一点余量，让用户看得见零件外沿那一圈是不是也被网格线切到了
        let padded = sample.bounds
            .insetBy(dx: -sample.bounds.width * 0.06, dy: -sample.bounds.height * 0.06)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let cropped = await Task.detached(priority: .userInitiated) {
            PartsThumbnailMaker.cropExact(source, normalized: padded)
        }.value
        // 裁这一下的工夫用户可能已经点了「对齐了，看下一个」，或者零件区那一版刚换上来 ——
        // 那时上面的 `.task(id:)` 已经把这一轮取消了。不认取消的话，屏幕上显示的是
        // 上一个零件的图，格线却是按新零件算的，用户对着错的图在标定。
        guard !Task.isCancelled else { return }
        // `padded` 可能伸到高清工作图之外。裁图会把越界部分截掉，所以图片和网格都必须
        // 使用真正裁到的区域；继续用 `padded` 会把被截掉更多的方向按错误比例摊开。
        sampleImage = cropped?.image
        sampleRegion = cropped?.rect ?? .zero
        syncFrameToLattice()
        focusIfTooDense()
        // 翻到一个零件就先按当前格距给它对一次 —— 用户翻过来看到的应该是已经对好的，
        // 而不是「上一个零件的格线平移过来」。它有自己的格线，跟别的零件没关系。
        guard !Task.isCancelled else { return }
        await refit(part: sample)
    }

    /// 一格在屏幕上太小就先替用户放大到看得清。
    ///
    /// 零件一般十来格，铺满画布之后一格二三十点，本来就够看；单图纸模式把**整张图纸**
    /// 当成一个零件送进来，铺满之后一格只剩四五个点 —— 几百条格线糊成一片色，
    /// 而这一屏的验收标准恰恰是「线有没有落在豆子的缝上」。看不清就等于没法验收，
    /// 用户只能对着一片糊按「对齐了」。
    ///
    /// 门槛卡在 10 点：零件基本碰不到，碰到的都是真的看不清。
    private func focusIfTooDense() {
        guard zoom == 1, let calibration, calibration.isUsable,
              displayRect.width > 0, sampleRegion.width > 0, canvasSize.width > 0 else { return }
        let cellPoints = CGFloat(calibration.cellWidth) / sampleRegion.width * displayRect.width
        guard cellPoints > 0, cellPoints < 10 else { return }
        zoom = max(1, min(16, 18 / cellPoints))
        lastZoom = zoom
        // 对准零件正中：边角多半是留白，看不出对没对齐
        let flat = PartsCanvasTransform(region: sampleRegion, display: displayRect,
                                        size: canvasSize, zoom: zoom, pan: .zero)
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let target = flat.screen(CGPoint(x: sampleRegion.midX, y: sampleRegion.midY))
        pan = clampPan(CGSize(width: center.x - target.x, height: center.y - target.y))
        lastPan = pan
    }

    /// 把黄框摆到零件正中那一格。
    ///
    /// 这不改变网格本身 —— 格线是无限铺开的，挑哪一格显示都一样。挑中间那格是因为
    /// 左上角那一格多半压在零件外面的空白上，框里一片粉，看不出格子边界对没对齐。
    ///
    /// - Parameter keepingPartPhase: 沿不沿用这个零件已有的格线位置。默认沿用 ——
    ///   翻回一个对过的零件，看到的必须还是他对好的那张。
    ///   「自动对齐」传 false：那一下刚在整张图上重新量出一条格线，沿用旧的等于把
    ///   量出来的结果原样扔掉，而用户按那个按钮就是要这一块被重新弄好
    ///   （屏幕上纹丝不动，他只会以为按钮坏了）。
    private func syncFrameToLattice(keepingPartPhase: Bool = true) {
        guard let sample else { return }
        // 确认过的零件整套（格距 + 格线）都用它自己的；否则拿全局格距，
        // 格线位置能用它自己的就用它自己的，没有才从全局那份推一格出来当起点。
        //
        // 这里不能图省事用 `sampleCalibration` —— 那个要读 `frameOrigin`，
        // 而这个函数就是负责算 `frameOrigin` 的。
        var base: PartsGridCalibration
        if let own = ownCalibration(of: sample) {
            base = own
        } else {
            guard let calibration, calibration.isUsable else { return }
            base = calibration
            if keepingPartPhase, let rect = sample.gridRect {
                base.originX = Double(rect.minX)
                base.originY = Double(rect.minY)
            }
        }
        frameOrigin = CGPoint(x: base.snappedX(Double(sample.bounds.midX)),
                              y: base.snappedY(Double(sample.bounds.midY)))
    }

    /// 格子大小改过之后，拿这个新尺寸把**整张图纸**的格线重新找一遍。
    ///
    /// 用户在一个零件上把格子调准了，剩下几十个零件不会自己变准 —— 它们的格子位置是
    /// 从同一张全局网格推出来的（`PartsGrid` 把 bounds 吸到全局格线上），格距一变，
    /// 那批格线该落在哪儿就得重算。不重算的话用户看到的是「我明明调对了，下一个还是偏」。
    ///
    /// 只找相位，不动格距 —— 格距是用户定的。某个零件找不出来（太小、装不下四格，
    /// 或者图上没有周期信号）就保持它现在的格线不动，总好过跳到一个瞎猜的地方。
    ///
    /// **正在看的那一块不重找。** 用户刚在它身上把格线调到位、眼睛验过了，这一下要是
    /// 拿估计器再量一遍，他按「跳过并完成」看到的就是「我明明调对了，一按就跑了」——
    /// 跟这一屏原来那个「只调大小不算数」是同一种难受。屏幕上那块以他看到的为准，
    /// 跟 `writeBack` 一个规矩。
    private func refitAllParts() async {
        guard let calibration, calibration.isUsable else { return }
        let source = work
        let snapshot = parts
        estimating = true
        let fitted = await Task.detached(priority: .userInitiated) { () -> [UUID: CGPoint] in
            var found: [UUID: CGPoint] = [:]
            // 锁住的跳过，理由同 `refit(part:)`
            for part in snapshot where !(part.isGridConfirmed || part.hasCells) {
                if let origin = PartsPitchEstimator.fitOrigin(
                    work: source, bounds: part.bounds, calibration: calibration
                ) {
                    found[part.id] = origin
                }
            }
            return found
        }.value
        estimating = false
        // 这里以前对**所有**零件都 applyGrid（锁住的靠 `phase(of:)` 保住相位）。
        // 那是不够的：applyGrid 会拿当前格距重算 rows/cols，格距一改，
        // 用户对好的零件行列数当场变掉，判过色的连 cells 都跟着错位。相位没被推走，
        // 但网格已经不是他确认的那张了。锁住的就整个别碰。
        let currentId = sample?.id
        for index in parts.indices where !isLocked(parts[index]) {
            let id = parts[index].id
            guard id != currentId else { continue }
            applyGrid(to: index, phase: fitted[id] ?? phase(of: parts[index]), calibration: calibration)
        }
        syncFrameToLattice()
    }

    /// 单独给一个零件按当前格距定位。翻到它的时候跑这一下，用户看到的就是已经对好的。
    ///
    /// 已经锁住的零件不动：
    /// - 判过色的 —— 改 `gridRect` 会连带改行列数，而 `cells` 还是按旧行列数存的，
    ///   结果是用户核对过的颜色整片错位（同 `squaredIfNeeded`）；
    /// - 用户点过「对齐了」的 —— 他翻回来看一眼，看到的必须还是自己对好的那张网格，
    ///   而不是被当场重对了一遍。要重对，旁边的「自动对齐」随时可以按。
    private func refit(part: BeadPart) async {
        guard !isLocked(part) else { return }
        guard let calibration, calibration.isUsable,
              parts.contains(where: { $0.id == part.id }) else { return }
        let source = work
        let bounds = part.bounds
        let origin = await Task.detached(priority: .userInitiated) {
            PartsPitchEstimator.fitOrigin(work: source, bounds: bounds, calibration: calibration)
        }.value
        // 锁要在 await **之后**再查一次：找相位这一下是后台跑的，这期间用户可能已经
        // 点了「对齐了」翻到下一个零件。只按开头那次判断就把结果写回去，等于拿一份
        // 过期的计算覆盖掉用户刚刚亲手确认的网格。顺便按 id 重取下标 —— 这期间
        // 零件也可能被删掉，老下标会指到别人身上。
        guard !Task.isCancelled, let origin,
              let index = parts.firstIndex(where: { $0.id == part.id }),
              !isLocked(parts[index]) else { return }
        applyGrid(to: index, phase: origin, calibration: calibration)
        syncFrameToLattice()
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
        var fitted: CGPoint?
        if measured == nil {
            fitted = await Task.detached(priority: .userInitiated) {
                PartsPitchEstimator.fitOrigin(work: source, parts: snapshot, calibration: calibration)
            }.value
            // 什么都没量出来：**锁原样留着**。解锁必须等到确实有结果，
            // 否则一次失败的「自动对齐」会悄悄把用户对好的零件重新暴露给后面的全局改动 ——
            // 屏幕上什么都没发生，他不会知道这个零件已经不受保护了。
            guard fitted != nil else { return }
        }
        // 按了这个就是「你帮我重弄这一个」，那当前零件的确认作废 —— 不然它锁着，
        // 这一下对它完全没反应，而按钮看起来跟能用一模一样。重弄完他再点一次
        // 「对齐了」重新确认就是。必须赶在下面动 `calibration` 之前解，
        // 那一下会触发 `writeBack`，而 `writeBack` 绕开所有锁着的零件。
        releaseCurrentPartLock()
        if let measured {
            self.calibration = measured
        } else if let fitted {
            self.calibration?.originX = Double(fitted.x)
            self.calibration?.originY = Double(fitted.y)
        }
        // 刚量出来的那条格线要落到当前这一块上，别被它自己的旧格线顶掉 —— 见参数注释。
        syncFrameToLattice(keepingPartPhase: false)
        writeBack()
    }

    /// 格距变了：**还没对好的**零件按它自己那条格线重算一遍。判色那步直接用这里的结论。
    ///
    /// 已经点过「对齐了」的一律不动 —— 用户挨个对了二十个零件，在第二十一个上动一下
    /// 加减号就把前二十个全推走，是这一屏最伤人的事：越往后调越乱，
    /// 而他根本不知道自己刚毁了什么。
    private func writeBack() {
        guard let calibration, calibration.isUsable else { return }
        // 锁住的一个都不碰，**包括当前正在看的这个**。
        //
        // 这里曾经给「当前零件」开过一个例外，理由是「用户就是在它身上调的加减号，
        // 不动等于按了没反应」。那个理由现在由 `setCellPitch` 承担了 —— 在确认过的零件上
        // 调格距只改它自己、根本不碰全局这个数，所以这个例外既用不上，又会在别的路径
        // （比如自动对齐改了全局格距）把用户对好的零件顺手推走。
        //
        // 底下那个 `writeBackCurrentPart` 不是把这个例外放回来：它只在当前零件**没锁**时
        // 走得到，改的是「拿哪个点当格线起点」，不是「要不要碰锁住的零件」。
        //
        // 认循环开始时的那个 id，别在循环里反复读 `sample` —— 那是个每次都要走一遍
        // `parts` binding 的计算属性，而「当前是哪一个」这件事在这一轮里是定死的。
        let currentId = sample?.id
        for index in parts.indices where !isLocked(parts[index]) {
            let id = parts[index].id
            if id == currentId {
                // **正在看的这个走 `frameOrigin`，不走 `phase(of:)`。**
                //
                // `phase(of:)` 拿的是它上一张网格的左上角（还没有网格的话退回全局那份），
                // 那个点跟屏幕上这片格线的起点差着整数个**旧**格子。格距一改，
                // 「差整数格」当场就不成立了 —— 从旧左上角铺出来的网格，和用户正盯着的
                // 那张能差出小半格。
                //
                // 而光调格子大小是唯一不会把这个差补回来的操作：推方向键直接拿
                // `frameOrigin` 当起点重铺（`writeBackCurrentPart`）；翻到别的零件是
                // 反过来 —— `refit` 重新量一个相位铺好网格，再由 `syncFrameToLattice`
                // 把 `frameOrigin` 吸到这张新网格上（锁住的零件跳过 `refit`，靠
                // `ownCalibration` 自洽）。两条路走完屏幕和存档总是同一张网格，
                // 只有调大小这一下会岔开：「屏幕上明明对齐了，存下来的是偏的」。
                writeBackCurrentPart()
            } else if id != focusPartId {
                // 从核对页指名回来重对的那一块不碰。它跟别的零件不一样：离开这一屏时
                // `finishRegrid` 会把它锁上，`refitAllParts` 于是跳过它 —— 没有人再给它
                // 重新量相位。这里要是按旧左上角给它换个格距，它带着一张漂了小半格的网格
                // 直接进重判，而用户以为自己对齐的是另一张。保持原样，等他翻回去自己调。
                applyGrid(to: index, phase: phase(of: parts[index]), calibration: calibration)
            }
        }
    }

    /// 这个零件的网格锁住了没有：自动重算（翻到它时的自动对齐、改全局格距、离开前的兜底）
    /// 一律绕开。判过色的一并算锁住 —— 那时候改行列数比推走格线还严重。
    private func isLocked(_ part: BeadPart) -> Bool {
        part.isGridConfirmed || part.hasCells
    }

    /// 当前这个零件的**格距**能不能改。判过色的不能：改格距会连行列数一起改，
    /// 而 `cells` 还是按老行列数存的，用户核对好的颜色会整片错位。
    ///
    /// 这一条必须反映到界面上（那三个按钮是灰的 + 旁边一句说明）。光在代码里挡住是不够的 ——
    /// 改格距的两条路（`setCellPitch` 走全局分支、`writeBack` 又绕开锁住的零件）合起来的
    /// 效果是「数字在动、格线在动、一个字节没写」，用户完全看不出自己白按了。
    ///
    /// 注意只锁格距，推格线没锁 ——「这个零件的网格整体偏了半格」恰恰是判完色最想回来修的事。
    ///
    /// **但推格线不是没有代价的**（这里以前写着「那是平移，不改行列数，`cells` 不会错位」，
    /// 是错的：`applyGrid` 连行列数一起重算）。格线一挪，每格盖住的就是别的豆子了。
    /// 目前只有「从核对页指名回来重对的那一块」会在离开时作废旧颜色（见 `finishRegrid`），
    /// 在别的零件上推格线仍然是「屏幕上一切正常、照着拼是错的」。
    private var pitchLocked: Bool {
        sample?.hasCells == true
    }

    /// 清掉这一块判好的颜色，把格距的锁解开 —— 用户明说要改格子时才走这条。
    /// 立刻落盘：这一屏别的改动都是当场存的，唯独这一下不存的话，
    /// 用户改完格子退出去，回来看到的是「颜色还在、格子又变了」的一堆错位。
    private func clearCellsForRegrid() {
        guard let sample, let index = parts.firstIndex(where: { $0.id == sample.id }) else { return }
        // 改一次写回一次。连着两次 `parts[index].x = y` 是两轮 get→mutate→set，
        // 而单图纸模式那边的 binding getter 是从 @State 现拼出来的 ——
        // 第二次拿到的可能还是旧值，把第一次清掉的格子又装回去
        // （同 `PartsBoardStepView.DragSession` 栽过的那一次）。
        var updated = parts[index]
        updated.cells = []
        updated.gridConfirmed = nil
        parts[index] = updated
        unlockingPitch = false
        onConfirmPart()
    }

    /// 记下「这个零件我亲手对过了」。点主按钮往下走的时候调。
    private func confirmCurrentPart() {
        guard let sample, let index = parts.firstIndex(where: { $0.id == sample.id }) else { return }
        parts[index].gridConfirmed = true
    }

    /// 解掉当前零件的锁。只在用户明确要求重弄这一个的时候调（自动对齐、重选格子大小）。
    private func releaseCurrentPartLock() {
        guard let sample, sample.isGridConfirmed,
              let index = parts.firstIndex(where: { $0.id == sample.id }) else { return }
        parts[index].gridConfirmed = nil
    }

    /// 只重算当前这个零件 —— 推格线是针对眼前这一个的。
    ///
    /// **格线真挪过就把这一块判好的颜色当场作废**（`clearsColorsWhenGridMoves` 开着时）。
    ///
    /// 这一条钉在这里，不钉在某个按钮上：用户可以按左上角返回、按「不看了，完成」、
    /// 或者在回程模式里翻到别的零件再走 —— 挂在按钮上的检查这几个出口全绕得过去。
    /// 绕过去的结果是每一格盖住的已经是别的豆子、装的还是旧色号，
    /// 屏幕上一切正常，照着拼出来是错的。
    ///
    /// 比网格的最终形状而不是「有没有按过方向键」：推出去再推回来是常事，那不算改过。
    /// 而且**必须带容差**（见 `GridShape.moved(from:)`）—— 光是进这一屏，
    /// `syncFrameToLattice` 就会触发一次原地重算，浮点上差最后一两位。
    private func writeBackCurrentPart() {
        guard let sample, let c = sampleCalibration,
              let index = parts.firstIndex(where: { $0.id == sample.id }) else { return }
        let before = GridShape(parts[index])
        applyGrid(to: index, phase: CGPoint(x: c.originX, y: c.originY), calibration: c)
        guard clearsColorsWhenGridMoves, parts[index].hasCells,
              GridShape(parts[index]).moved(from: before) else { return }
        // 只清颜色，`gridConfirmed` 留着 —— 用户亲手对过的那些零件仍然该锁住自己的格距
        //（`ownCalibration` 靠它），不然下一次写回会拿全局格距把行列数重算掉。
        parts[index].cells = []
    }

    /// 这个零件现在的格线在哪。对过的就是它 `gridRect` 的左上角；没对过的退回全局那份。
    private func phase(of part: BeadPart) -> CGPoint {
        if let rect = part.gridRect { return CGPoint(x: rect.minX, y: rect.minY) }
        guard let calibration else { return .zero }
        return CGPoint(x: calibration.originX, y: calibration.originY)
    }

    private func applyGrid(to index: Int, phase: CGPoint, calibration: PartsGridCalibration) {
        var c = calibration
        c.originX = Double(phase.x)
        c.originY = Double(phase.y)
        let grid = PartsGrid(covering: parts[index].bounds, calibration: c)
        parts[index].gridRect = grid.rect
        parts[index].rows = grid.rows
        parts[index].cols = grid.cols
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

/// 网格线的画法。跟「一格」那个黄框（`CellFrameOverlay`）分开，两者不会同时出现。
struct CellGridOverlay: View {
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

/// 同 `CellGridOverlay`：两种模式共用。
struct CellFrameOverlay: View {
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
