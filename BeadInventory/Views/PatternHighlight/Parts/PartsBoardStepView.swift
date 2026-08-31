//
//  PartsBoardStepView.swift
//  BeadInventory
//
//  多零件模式 · 摆到拼豆板（第六屏；整条流程的屏序见 PartsSheetFlowView 的头注释）
//
//  到这一步，五十几个零件每一格是什么色号都已经定了。剩下的是**真的动手拼**的时候
//  要回答的两个问题：
//
//    1. 这一板先拼哪几个零件、分别摆在哪儿？（一块板放不下整套）
//    2. 我手上抓着一把 H7，这块板上哪些格子该放它？
//
//  ## 为什么进来先自动排一遍
//
//  五十几个零件一个一个拖到板上，光是「拖」这个动作就要几十次，而且用户其实
//  并不在乎谁摆在哪 —— 他在乎的是「能不能一板多拼几个」。所以进来直接排好，
//  他要是不满意再拖。拖是微调手段，不是必经之路。
//
//  ## 摆放的硬规矩：零件之间要空开
//
//  烫的时候挨着的豆子会连成一片，所以两个零件的豆子之间至少隔一格
//  （见 BeadPartsBoard.swift）。留多宽有三档可选（`BoardSpacing`）——
//  一格是底线，往上是给剪刀和手指留的余地。
//
//  拖到不该去的地方，那个零件会变红、松手弹回原位 —— 不是弹一下就完，
//  底下会写清楚为什么，而且分得清「顶到边了」和「挨着别的零件了」。
//
//  **松紧是跟着图纸存的，不是一个全局设置**：拖动校验必须跟当初排版用的是同一档，
//  否则用户会撞见一块自己排出来、自己却拖不回去的板。见 `spacing`。
//
//  ## 高亮
//
//  拼的时候是一个颜色一个颜色抓豆子放的，不是一格一格看图纸的。所以下面那排颜色
//  点一下，板上就只剩这个色号是亮的，其余全部压成灰 —— 眼睛直接扫得出来该往哪儿放。
//

import SwiftUI

struct PartsBoardStepView: View {
    /// 可写：板上的零件也能一格一格地擦 / 补（见 `brushTarget`）。
    /// 真拼起来才发现「这块边上多认了一颗」是常事，那时候用户手上正抓着豆子，
    /// 让他退回核对页去找那一格是不现实的。
    @Binding var parts: [BeadPart]
    /// 图纸本身。**可以是 nil** —— 这一屏只靠格子数据就能画板子，图裁失败不该把用户
    /// 挡在最后一步外面（见 PartsSheetFlowView 的 navigationDestination）。
    /// 有图的时候多一件事能做：点板上的零件，把图纸上原来那块抠出来对一眼。
    var work: PartsWorkImage?
    @Binding var boards: [PartsBoard]
    /// 这套板子是按哪一档松紧排的。nil = 还没排过（或者是没这个字段的老图纸）。
    @Binding var boardSpacing: BoardSpacing?
    let colorSystem: ColorSystem
    /// 擦 / 补完格子立刻落盘 —— 那是对图纸本身的修改，不能等到「完成」那一下。
    let onPersist: () -> Void
    let onFinish: () -> Void

    @EnvironmentObject var inventoryManager: InventoryManager

    /// 上次用的板子尺寸。同一个人手上的板子基本不会换，记着就不用每次重选。
    @AppStorage("partsBoardCols") private var savedCols = 50
    @AppStorage("partsBoardRows") private var savedRows = 50
    /// 上次**亲手选**的松紧。同理 —— 剪刀和习惯不会天天变。只在还没排过的板子上作数。
    ///
    /// 只有用户在松紧菜单里点了某一档才写这里。换板子尺寸不写：那不是在选松紧，
    /// 而老图纸的 `spacing` 解析出来是 `.tight`，跟着写的话用户换块大板子就把自己
    /// 在别的图纸上选的档洗成紧凑了，而且屏幕上一个字都不会提。
    @AppStorage("partsBoardSpacing") private var preferredSpacing: BoardSpacing = .standard
    /// 自己填过的板子格数（最近三块，一行 `"60x40,29x29"`）。手上有哪几块板是跟着人走的，
    /// 不属于任何一张图纸 —— 所以在偏好里，投影仪校准页读的也是这一份。
    @AppStorage(BeadBoardSize.recentsKey) private var customSizes = ""

    @State private var boardIndex = 0
    /// 当前选中的那个「摆放」（不是零件本身 —— 同一个零件只会被摆一次，但选中态属于板上那一份）
    @State private var selection: UUID?
    /// 正在高亮的色号（`PartCellFill.groupKey`）。nil = 正常显示
    @State private var highlightKey: String?
    @State private var tab: Tab = .parts

    // 画布
    @State private var canvasSize: CGSize = .zero
    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var lastPan: CGSize = .zero
    @State private var pinchScreenPoint: CGPoint = .zero
    @State private var pinchContentAnchor: CGPoint?

    /// 这一次拖动是在挪零件还是在平移画布。
    ///
    /// **必须是引用类型**（外面这层 @State 只是拿来持有它，值本身不参与刷新）：
    /// 落指那一下要先判断「摸到零件没有」，紧接着在同一个回调里就得按这个判断分流。
    /// 要是把这些状态直接当成 @State 的值来存，写完立刻读回来不保证拿到新值，
    /// 而模拟器上整段拖动有时只来一个 onChanged —— 第一个事件被当成平移，
    /// 那一整次拖动就白拖了（零件纹丝不动，也没有任何提示）。
    @State private var session = DragSession()
    /// 画布要用的拖动状态（挪了几格、放不放得下）。这个必须是 @State，改了要重画。
    @State private var drag: Drag?

    /// 板上每个摆放对应的形状。位置不在里面 —— 拖动时只有位置在变，
    /// 形状不该跟着重算。
    @State private var footprints: [UUID: PartFootprint] = [:]
    @State private var colorCache: [String: Color] = [:]
    /// 零件 id → 它在清单里排第几（1-based）。板上写的号、零件条上写的号都是它，
    /// 跟「零件清单」那屏图上的号是同一个 —— 三处不一致的话，这个号就没法用来对图纸了。
    @State private var partOrder: [UUID: Int] = [:]
    /// 从图纸上抠下来的零件原样，连同它现在处于哪一步。
    ///
    /// 选中谁就裁谁（不是点开弹窗才裁），裁过的留着不清 —— 一次会话最多五十几张，
    /// 而且每张都只是原图上的一块（`CGImage.cropping` 跟底图共用像素），不额外占内存。
    ///
    /// **状态必须存进来，不能只存图**：只存 `UIImage?` 的话，「还在裁」和「裁不出来」
    /// 都是 nil，屏幕上只能都画成转圈 —— 而后者是等到天亮也不会出来的。见 `PartOriginalSheet.Original`。
    @State private var originals: [UUID: PartOriginalSheet.Original] = [:]
    /// 正在对照原图的那个零件
    @State private var inspecting: BeadPart?
    /// 正在图纸上擦 / 补格子的那个零件
    @State private var brushTarget: BrushTarget?
    /// 格子被改过几回。形状缓存、送外屏、「还有谁站不住」都靠它失效 ——
    /// `shapeSignature` / `castSignature` / `layoutSignature` 记的都是零件 id、转向和位置，
    /// **格子里的内容变了它们看不见**；颜色表在 `afterCellsChanged` 里直接重算。
    @State private var cellsRevision = 0
    /// 现在还站不住的那些**摆放**（跟旁边挨着 / 出界，而且挪不开）。
    ///
    /// **必须一直看得见**，不能只闪一句就算：挨着的两个零件烫完连成一片，那一刀下去
    /// 边缘就毁了 —— 提示消失之后，板上就是一份看起来完全正常、拼出来会报废的布局。
    /// 所以它们在板上描红边，「完成」也会先拦一下。
    ///
    /// **跟着板子重算，不是修完存一次。** 早先它是 `repair` 的返回值缓存下来的，
    /// 于是用户照着提示把零件拖开、或者重排一遍之后，红边还红着、「完成」还拦着 ——
    /// 而板子明明已经好了。一个跟着现实走的警告才有人看，一个赖着不走的警告只会被
    /// 学会无视，而旁边就摆着「仍然完成」。
    @State private var invalidPlacements: Set<UUID> = []
    /// 板上还有挨着的零件时按了「完成」
    @State private var confirmFinishInvalid = false
    /// 按了几次「标记已完成」。只拿来给触觉当触发器。
    @State private var doneToggles = 0

    private struct BrushTarget: Identifiable {
        let id: UUID
    }

    /// 填好了、等这一屏关掉再用的那块板
    private struct PendingCustomSize {
        let target: CustomSizeTarget
        let size: BeadBoardSize
    }

    /// 自己填完格数之后要干的事。**两条路必须分开**：「加一块」是往后添一块空板，
    /// 「全部重排成」会把手动挪过的位置全推翻 —— 后者得先弹一次确认。
    private enum CustomSizeTarget: Identifiable {
        case addBoard
        case repack

        var id: String {
            switch self {
            case .addBoard: return "add"
            case .repack: return "repack"
            }
        }
    }

    @State private var note: String?
    @State private var noteToken = UUID()
    /// 待确认的「全部重排」。板子尺寸和松紧是同一件事的两半 —— 改哪一个都得整块重摆，
    /// 所以走同一个确认弹窗，别让用户学两套。
    @State private var repackTarget: RepackTarget?
    @State private var didAutoPack = false
    /// 外屏投影状态。这一屏只用得着「连上没有」（画什么是 publishToExternalDisplay 送出去的），
    /// 但 `@ObservedObject` 订阅的是整个对象，所以每次送板子也会让这一屏重画一遍。
    /// 送板子只发生在离散的编辑动作上（拖动过程中不送），所以不在手势的热路径上。
    @ObservedObject private var cast = BoardCastSession.shared
    /// 开着「对准豆板」那一屏
    @State private var showingProjectorSheet = false
    @State private var showingConnectSheet = false
    /// 正在自己填格数，填完了拿这块板做什么
    @State private var customSizeTarget: CustomSizeTarget?
    /// 刚填好、等这一屏关掉再用的那块板（连同它是给哪一条用的）。见 `applyCustomSize`。
    @State private var pendingCustomSize: PendingCustomSize?

    private enum Tab: Hashable { case parts, colors }

    private struct RepackTarget: Equatable {
        var size: BeadBoardSize
        var spacing: BoardSpacing
        /// 用户在这次操作里**亲手选了松紧**。只改板子尺寸时是 false ——
        /// 那种情况下 `spacing` 是这张图纸原本就带的，把它写回全局偏好等于
        /// 拿一张老图纸的 `.tight` 覆盖掉用户在别处选的档（见 `preferredSpacing`）。
        var pickedSpacing: Bool
    }

    /// 这一屏所有「放得下吗」的判断都得用这一档 —— 自动排、点零件条落位、拖动校验。
    ///
    /// 排过的板子认板子自己带的那一档，**不认用户当前偏好**：偏好可能是他在别的图纸上
    /// 改的，拿它去校验会让用户拖不回自己刚刚排出来的位置。
    ///
    /// `boardSpacing == nil` 只有一个意思：**还没排过**，那就听偏好的。老图纸的
    /// `.tight` 在 `PartsSheetFlowView.load` 里就落定了，不在这儿推 —— 早先这里写成
    /// `boards.isEmpty ? preferredSpacing : .tight`，于是「有没有板子」和「哪一档」
    /// 缠在一起：`pack()` 排出零块板时（零件全比板子大）状态变成「没板子却有档位」，
    /// 松紧菜单从此点了没反应。
    private var spacing: BoardSpacing {
        boardSpacing ?? preferredSpacing
    }

    /// 一次拖动的现场。见 `session` 的注释。
    ///
    /// 挪了几格、放不放得下也记在这里，不去读 `drag`：手指抬起来那一下要用这两个值
    /// 决定是落位还是弹回，而整段拖动有时和抬手在同一轮里送达，@State 还没生效 ——
    /// 表现出来就是「零件弹回去了，也没告诉我为什么」。
    private final class DragSession {
        var active = false
        /// 正在挪的那个摆放；nil = 这一拖是在平移画布
        var placement: UUID?
        var originCol = 0
        var originRow = 0
        var deltaCol = 0
        var deltaRow = 0
        var valid = true
        /// 按下之前这个零件是不是已经选中了。用来实现「再点一下取消选中」。
        var wasSelected = false
        /// 落指时算好的占位表（已经把被拖的那个零件排除掉）。
        /// 拖动过程中板上别的东西不会变，没必要每帧重算。
        var occupancy: BoardOccupancy?

        func reset() {
            active = false
            placement = nil
            deltaCol = 0
            deltaRow = 0
            valid = true
            wasSelected = false
            occupancy = nil
        }
    }

    private struct Drag: Equatable {
        let placement: UUID
        let originCol: Int
        let originRow: Int
        var deltaCol = 0
        var deltaRow = 0
        var valid = true
    }

    // MARK: - 主体

    var body: some View {
        VStack(spacing: 0) {
            boardBar
            Divider()
            canvas
            bottomPanel
        }
        .navigationTitle("排布到拼豆板")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { boardMenu }
        }
        .task {
            colorCache = makeColorCache()
            partOrder = Dictionary(uniqueKeysWithValues: parts.enumerated().map { ($1.id, $0 + 1) })
            autoPackIfNeeded()
            // 排完（或者本来就有板子）之后先体检一遍：别处改过的格子可能已经把
            // 这块板改成非法的了，而用户看到板子就是在这儿。见 `revalidateBoards`。
            revalidateBoards()
        }
        // 板子一动就重算「还有谁站不住」。拖动、转向、拿下来、加一块、重排、切板子 ——
        // 每一处都得算，而它们分散在八九个函数里，所以认签名不认调用点。
        .onChange(of: layoutSignature) { _, _ in refreshInvalid() }
        // 选中谁就把谁的原图抠出来。抠在后台：高清工作图上一块零件几十万像素，
        // 主线程上裁，用户点一下零件界面就顿一下。
        //
        // **对照弹窗开着时听它的，不听板上的选中。** 弹窗里「上一个 / 下一个」翻到的
        // 那块并没有在板上被选中 —— 只认 `selectedPartId` 的话，翻过去那一边永远是
        // 一个转不完的圈（`originalState` 拿不到条目就当成还在抠）。
        // 关掉弹窗后键值退回选中的那块，而它早就是 `.ready` 了，不会重裁一遍。
        .task(id: inspecting?.id ?? selectedPartId) {
            await loadOriginal(for: inspecting?.id ?? selectedPartId)
        }
        // 送外屏必须跟在 footprints 算完之后 —— 外屏只有形状可画，没形状的摆放会被整个跳过
        // （见 BoardCanvas 里那句 `guard let footprint`）。这两件事分开写过一次，
        // 结果是新摆的零件在电视上根本不出现、重排一遍电视上整块空白。
        .task(id: shapeSignature) {
            let shapes = makeFootprints()
            footprints = shapes
            // 形状刚算完，这时候才知道每块板上现在到底有哪些色号。
            // 传值不读 `footprints`：写完同一轮读回来不保证拿到新值。
            pruneDoneColors(using: shapes)
            publishToExternalDisplay()
        }
        // 形状没变、只是挪了位置或者换了高亮，也要重送。
        // 拖动过程中的临时状态不送 —— 外屏是给人抬头看「板子现在长什么样」的，
        // 跟着手指抖没有意义；但手一松、位置定下来就必须送过去。
        .onChange(of: castSignature) { _, _ in publishToExternalDisplay() }
        .onDisappear { BoardCastSession.shared.stop() }
        // 板子和外屏尺寸都得有才对得起来。按钮本来就只在接了外屏、且这一屏有板子时
        // 才画得出来，所以这里取不到值的情况只剩「刚好在这一瞬间拔了线」。
        // 校准的收尾挂在呈现方：那一屏自己 `onDisappear` 判不准「是真被关掉了，还是
        // 只是被『自定义尺寸』盖住了」，判错的代价是外屏上的角标再也不消失（而角标跟
        // 真正要按豆子的格子长得一模一样），下次进去也不会重新拍快照。
        .sheet(isPresented: $showingConnectSheet) { ProjectorConnectSheet() }
        // 遥控器长按确定键要求校准。人就站在投影仪跟前，这一下之后手机上必须真的
        // 有一页开着 —— 校准态的开和关都挂在这一页上（见 `remoteCalibrationRequest`）。
        //
        // **先把这一屏上别的 sheet 收掉。** 同一时刻只能呈现一个：别的开着时直接置真，
        // 页面弹不出来，而这个标志位不会被系统复位、就一直停在 true —— 之后用户回到
        // 手机上点那个投影 chip（做的事同样是置真）也没反应了，只能退出这一屏再进来。
        // 而「在连接页里配好、把手机搁桌上走到投影仪那头」正是第一次架机器的主路径。
        .onReceive(BoardProjector.shared.remoteCalibrationRequest) { _ in
            showingConnectSheet = false
            customSizeTarget = nil
            brushTarget = nil
            inspecting = nil
            showingProjectorSheet = true
        }
        .sheet(isPresented: $showingProjectorSheet, onDismiss: {
            if BoardProjector.shared.isCalibrating { BoardProjector.shared.cancelCalibrating() }
        }) {
            if let board = currentBoard, let screen = cast.externalScreenSize {
                // 多零件模式下这块板就是桌上那块实物豆板，格数直接填好，用户少答一个问题
                BoardProjectorSheet(suggestedBoard: board.size, screen: screen)
            }
        }
        // **填完的板等这一屏关掉再用**：「全部重排成」那条路要弹确认弹窗，而在 sheet
        // 还没收干净时挂上去的弹窗会被吞掉 —— 用户点了「确定」，屏幕上什么都没发生。
        .sheet(item: $customSizeTarget, onDismiss: applyCustomSize) { target in
            BoardSizeCustomSheet(
                initial: currentBoard?.size ?? BeadBoardSize(cols: savedCols, rows: savedRows)
            ) { size in
                pendingCustomSize = PendingCustomSize(target: target, size: size)
            }
        }
        .task(id: noteToken) {
            guard note != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { note = nil }
        }
        .sheet(item: $brushTarget) { target in
            PartCellBrushView(
                work: work,
                partId: target.id,
                parts: $parts,
                colorSystem: colorSystem,
                subject: { name(of: $0) },
                // 翻页按零件清单的顺序走，跟弹窗里那条「上一个 / 下一个」同一把尺
                siblings: parts.map(\.id),
                // 这一屏只有多零件模式走得到，「任意色」那一档是有的。显式写出来 ——
                // 靠默认值恰好对，是下一个人删掉这一屏的前提时才会发现的那种对。
                allowsAnyColor: true,
                onCommit: {
                    // **先修板子再落盘。** 反过来的话，「挪到旁边空地了」那一下只活在
                    // 内存里等下一次 persist —— 而屏幕上刚跟用户说完这句话，
                    // 他有理由认为已经定了。
                    afterCellsChanged()
                    onPersist()
                }
            )
            .environmentObject(inventoryManager)
        }
        // **按 `isPresented` 开，不按 `item` 开。** 弹窗里「上一个 / 下一个」换的是
        // `inspecting` 本身 —— `sheet(item:)` 换 item 走的是「关掉再开一个」，
        // 翻一次弹窗就闪一下、还得等它重新升起来。这样写弹窗一直在，只是里面的内容跟着变。
        .sheet(isPresented: Binding(
            get: { inspecting != nil },
            set: { if !$0 { inspecting = nil } }
        )) {
            if let part = inspecting {
                PartOriginalSheet(
                    title: name(of: part.id),
                    order: partOrder[part.id] ?? 0,
                    // 判「改过名没有」跟 displayName 用同一把尺（都要去掉空白），
                    // 否则名字里只打了个空格时，标题退回「零件 10」而这一行以为它有名字。
                    showsOrder: part.customName?.trimmingCharacters(in: .whitespaces).isEmpty == false,
                    original: originalState(of: part.id),
                    footprint: part.footprint(turns: 0),
                    colors: colorCache,
                    placement: placementInfo(of: part.id),
                    onPrevious: stepAction(from: part.id, by: -1),
                    onNext: stepAction(from: part.id, by: 1)
                )
            }
        }
        .alert("板上有零件间距过近", isPresented: $confirmFinishInvalid) {
            Button("返回调整位置", role: .cancel) { confirmFinishInvalid = false }
            Button("继续完成") { onFinish() }
        } message: {
            Text("有 \(invalidPlacements.count) 个零件（红边标出）与相邻零件间距不足，熨烫后会粘连，需用剪刀分开，可能损坏边缘")
        }
        .alert("重新排列？", isPresented: Binding(
            get: { repackTarget != nil },
            set: { if !$0 { repackTarget = nil } }
        )) {
            Button("取消", role: .cancel) { repackTarget = nil }
            Button("重新排", role: .destructive) { repackAll() }
        } message: {
            // 重排造的是全新的板子，勾一律清空 —— 零件会被重新分到别的板上，而标记是
            // 按板记的，迁过去没有意义。所以这里要说清楚，不是想办法保留：用户按「确定」
            // 之前得知道自己同意的是「几个晚上的进度记录一起没」，不只是摆位。
            Text("会按 \(repackTarget?.size.label ?? "") 的板子、\(repackTarget?.spacing.label ?? "")间距重新摆一遍，你手动挪过的位置和各块板上的已完成标记都会清空。")
        }
    }

    // MARK: - 上：第几块板

    private var boardBar: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.sm) {
                    ForEach(Array(boards.enumerated()), id: \.element.id) { index, item in
                        Button { switchTo(index) } label: {
                            boardChip(index: index, board: item)
                        }
                        .buttonStyle(.plain)
                    }

                    Menu {
                        BoardSizePicker(
                            recents: BeadBoardSize.decodeList(customSizes),
                            onPick: { addBoard(size: $0) },
                            // 清掉上一次的残留：那一份只在 onDismiss 里消费，万一哪次
                            // 没消费成（sheet 开着时整条流程被拆掉），下次划走取消
                            // 会替它执行上一次的动作 —— 凭空多一块板，或者弹一个没人要的重排确认。
                            onCustom: { pendingCustomSize = nil; customSizeTarget = .addBoard }
                        )
                    } label: {
                        Label("新增一块", systemImage: "plus")
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.sm)
                            .background(Capsule().fill(Theme.ColorToken.Surface.elevated))
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
            }

            // 挨着的零件必须一直挂在眼前 —— 一句会消失的提示挡不住一块拼出来会粘连的板。
            if !invalidPlacements.isEmpty {
                Label("红边标出的 \(invalidPlacements.count) 个零件与相邻零件间距不足，熨烫后会粘连。请拖开间距，或点击上方「新增一块」新增板",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(Theme.ColorToken.Status.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Spacing.lg)
            }

            if let board = currentBoard {
                // 投屏那一行单独占一行：它那句话本身就够长，跟板子摘要挤在同一行的话
                // 两边都会被截断，而这两句都是用来「扫一眼确认」的。
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(board.size.label) · 摆了 \(board.placements.count) 个零件 · \(beadCount(of: board)) 颗豆子")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(Theme.ColorToken.Text.secondary)
                    // 状态标记 + 投影仪模式的入口，写法见 `ProjectorStatusChip`
                    if cast.externalConnected {
                        ProjectorStatusChip { showingProjectorSheet = true }
                    } else {
                        ProjectorConnectChip { showingConnectSheet = true }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Spacing.lg)
            }
        }
        .padding(.vertical, Theme.Spacing.sm)
        .background(Theme.ColorToken.Surface.background)
    }

    private func boardChip(index: Int, board: PartsBoard) -> some View {
        let isSelected = index == boardIndex
        return Text("板 \(index + 1)")
            .font(.footnote.weight(.medium))
            .foregroundColor(Theme.ColorToken.Text.primary)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(
                Capsule().fill(isSelected
                               ? Theme.ColorToken.Morandi.mauve.opacity(0.22)
                               : Theme.ColorToken.Surface.elevated)
            )
            .overlay(
                Capsule().stroke(isSelected ? Theme.ColorToken.Morandi.mauve : Color.clear, lineWidth: 1.5)
            )
    }

    private var boardMenu: some View {
        Menu {
            Section("零件间距") {
                ForEach(BoardSpacing.allCases) { option in
                    Button {
                        guard option != spacing else { return }
                        // 已经摆好的板子不会自己变松变紧 —— 那等于把用户挪过的位置
                        // 悄悄推翻。所以换档就是一次「全部重排」，走同一个确认弹窗。
                        let size = currentBoard?.size ?? BeadBoardSize(cols: savedCols, rows: savedRows)
                        if boards.contains(where: { !$0.placements.isEmpty }) {
                            repackTarget = RepackTarget(size: size, spacing: option, pickedSpacing: true)
                            return
                        }
                        // 板上什么都没摆，没什么可重排的，直接改。
                        preferredSpacing = option
                        // 空板也要跟着改：不然屏幕上打着勾的是一档，
                        // 手动往这块空板上放零件时守的还是另一档。
                        if !boards.isEmpty { boardSpacing = option }
                        // 这一支不重排，屏幕上那块空板前后一模一样。不说一句的话，
                        // 用户唯一能看到的证据是下次打开菜单时那个勾 ——
                        // 一次点击要么有效果，要么有说法。
                        flash(String(localized: "接下来摆的零件按\(option.label)间距放"))
                    } label: {
                        if option == spacing {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                        Text(option.detail)
                    }
                }
            }
            Section("全部重新排列为") {
                BoardSizePicker(
                    current: currentBoard?.size,
                    recents: BeadBoardSize.decodeList(customSizes),
                    onPick: { size in
                        repackTarget = RepackTarget(size: size, spacing: spacing, pickedSpacing: false)
                    },
                    onCustom: { pendingCustomSize = nil; customSizeTarget = .repack }
                )
            }
            if let board = currentBoard, !board.placements.isEmpty {
                Button("清空这块板", role: .destructive) { clearCurrentBoard() }
            }
            if boards.count > 1, currentBoard?.placements.isEmpty == true {
                Button("删除这块空板", role: .destructive) { removeCurrentBoard() }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    // MARK: - 中：板子

    private var canvas: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Theme.ColorToken.Surface.subtle

                if let board = currentBoard {
                    Canvas { context, size in
                        renderer(for: board).draw(in: context, canvas: size,
                                                  layout: layout(for: board))
                    }
                } else {
                    ContentUnavailableView(
                        "还没有板子",
                        systemImage: "square.grid.3x3",
                        description: Text("请在上方「新增一块」中选择一个尺寸。")
                    )
                }

                gestureCatcher

                if let note {
                    Text(note)
                        .font(.footnote)
                        .foregroundColor(Theme.ColorToken.Text.primary)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.sm)
                        .background(Capsule().fill(.regularMaterial))
                        .padding(Theme.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .onAppear { canvasSize = geo.size }
            .onChange(of: geo.size) { _, new in canvasSize = new }
        }
        .clipped()
        .animation(.easeInOut(duration: 0.2), value: note)
    }

    private var gestureCatcher: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                SimultaneousGesture(
                    // 点按不再单独用 SpatialTapGesture：拖完手指抬起来时它也会跟着触发一次，
                    // 把刚拖过的零件又取消选中了。改成「几乎没动 = 点按」，一个手势说了算。
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // 双指捏合的时候别顺手把零件也拖走
                            guard pinchContentAnchor == nil else { return }
                            if !session.active {
                                session.active = true
                                beginDrag(at: value.startLocation)
                            }
                            if session.placement != nil {
                                updateMove(value.translation)
                            } else {
                                pan = clampPan(CGSize(
                                    width: lastPan.width + value.translation.width,
                                    height: lastPan.height + value.translation.height
                                ))
                            }
                        }
                        .onEnded { value in
                            let moved = hypot(value.translation.width, value.translation.height)
                            if moved < 10 {
                                endAsTap()
                            } else if session.placement != nil {
                                // 抬手这一下要按**最终**位置重算一次。手指移动的最后一段
                                // 常常只随抬手事件送达，onChanged 根本没见过它 ——
                                // 只信 onChanged 的话，快速一拖就是「零件没动，也没说为什么」。
                                updateMove(value.translation)
                                commitMove()
                            }
                            lastPan = pan
                            drag = nil
                            session.reset()
                        },
                    MagnifyGesture()
                        .onChanged { value in
                            if pinchContentAnchor == nil {
                                pinchScreenPoint = value.startLocation
                                pinchContentAnchor = unzoomed(value.startLocation)
                            }
                            guard let anchor = pinchContentAnchor else { return }
                            zoom = max(1, min(14, lastZoom * value.magnification))
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

    // MARK: - 下：零件 / 颜色

    /// 下半屏。**选中一个零件时，这里整个变成那个零件在图纸上的大图。**
    ///
    /// 早先是在原来那排按钮左边塞了个 42pt 的小图 —— 一个 20×18 格的零件缩到 42 点，
    /// 一格两个点，什么都看不清，等于没给。而选中一个零件时用户就一件事要做：
    /// 确认「板上这块 = 图纸上那块」。零件条和色号条那会儿一个都用不上，让位给图。
    private var bottomPanel: some View {
        VStack(spacing: Theme.Spacing.md) {
            if let id = selection, let placement = currentBoard?.placements.first(where: { $0.id == id }) {
                selectedPanel(placement)
            } else {
                Picker("", selection: $tab) {
                    Text("零件").tag(Tab.parts)
                    Text("颜色").tag(Tab.colors)
                }
                .pickerStyle(.segmented)

                switch tab {
                case .parts: partsTray
                case .colors: colorTray
                }
            }

            // 板上还有挨着的零件时先拦一下。**不是禁用按钮** —— 灰着不说话，用户
            // 只会以为 App 坏了；而且「就这么拼」也可能真是他的决定（他也许打算
            // 拼完自己剪开）。所以说清楚代价，让他自己点。
            Button {
                if invalidPlacements.isEmpty { onFinish() } else { confirmFinishInvalid = true }
            } label: {
                Label("完成", systemImage: "checkmark").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.regularMaterial)
    }

    /// 选中之后的下半屏：这是几号 · 图纸上长什么样 · 能对它做什么。
    ///
    /// 板上的零件是一片纯色方块（判色的产物），跟图纸上那块带描边、带渐变的画差得很远 ——
    /// 拿错了零件、摆错了位置，只看板子是看不出来的，得跟原图对一眼。
    private func selectedPanel(_ placement: PartPlacement) -> some View {
        VStack(spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                orderBadge(placement.partId, size: 11)
                Text(name(of: placement.partId))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.ColorToken.Text.primary)
                    .lineLimit(1)
                Spacer(minLength: Theme.Spacing.sm)
                // 明写一个出口。选中之后零件条和色号条都让位了，只靠「点板上空白处取消」
                // 的话，用户想切回颜色高亮会以为那两条没了。
                Button("收起") { selection = nil }
                    .font(.footnote)
            }

            partPreview(placement)

            HStack(spacing: Theme.Spacing.sm) {
                Button { rotateSelected() } label: {
                    Label("转 90°", systemImage: "rotate.right").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                // 真拼起来才发现「这块边上多认了一颗」「这儿明明该有一颗」是常事。
                // 那一刻用户手上抓着豆子对着板子，退回核对页去几万格里找那一格是不现实的。
                Button { brushTarget = BrushTarget(id: placement.partId) } label: {
                    Label("编辑网格", systemImage: "eraser").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) { takeOffSelected() } label: {
                    Label("移除", systemImage: "arrow.down.left").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .font(.footnote)
            .lineLimit(1)
        }
    }

    /// 图纸上原来那块，尽量画大。
    ///
    /// **原图没到位时画的是识别结果，那就必须说出来。** 退回去画的
    /// `PartShapeThumbnail` 跟对照弹窗里标着「识别出来的样子」的是同一个 view，也跟
    /// 板子本身来自同一份 `cells` —— 不说明的话，用户为了核对「板上这块 = 图纸上那块」
    /// 点开它，看到的是同一份数据画的第二张图，两边**永远**一致。判错的零件会被读成
    /// 「核对通过」，然后照着它穿真豆子。这个功能存在的理由正是暴露识别错误，
    /// 让它自我确认比不做还糟。
    ///
    /// 所以角上那句话跟着状态走：有原图才说「点开对照」，没有就说清楚现在画的是什么、
    /// 还要不要等。
    private func partPreview(_ placement: PartPlacement) -> some View {
        let state = originalState(of: placement.partId)
        return Button { inspect(placement.partId) } label: {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(Theme.ColorToken.Surface.subtle)

                if case .ready(let image) = state {
                    GeometryReader { geo in
                        // 放大到超过原图分辨率时用最近邻，豆子边界是硬的；缩小时用默认插值，
                        // 否则一像素宽的格线会抖成摩尔纹。比的是图**真正画出来那块**的宽
                        // （`scaledToFit` 之后竖长的图只占中间一条），不是容器的宽。
                        let drawn = min(geo.size.width, geo.size.height * aspect(of: image))
                        Image(uiImage: image)
                            .resizable()
                            .interpolation(drawn >= image.size.width ? .none : .high)
                            .scaledToFit()
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                    .padding(Theme.Spacing.xs)
                } else if let part = parts.first(where: { $0.id == placement.partId }) {
                    PartShapeThumbnail(footprint: part.footprint(turns: 0), colors: colorCache)
                        .padding(Theme.Spacing.sm)
                }

                Label(previewCaption(state).text, systemImage: previewCaption(state).icon)
                    .font(.caption2.weight(.medium))
                    .foregroundColor(Theme.ColorToken.Text.secondary)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.regularMaterial))
                    .padding(Theme.Spacing.sm)
            }
            // 一屏之内板子和零件图各占一半上下：板子还得看得见（用户要照着它摆），
            // 零件图要大到一格豆子看得出颜色。200 点是两边都还成立的那个数。
            .frame(maxWidth: .infinity)
            .frame(height: 200)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topLeading) {
            // 板上那块是转过的，跟这张图对不上不是判错了 —— 不说的话用户会以为识别坏了。
            if placement.turns != 0 {
                Text("板上转了 \(placement.turns * 90)° 放")
                    .font(.caption2)
                    .foregroundColor(Theme.ColorToken.Text.secondary)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.regularMaterial))
                    .padding(Theme.Spacing.sm)
            }
        }
    }

    /// 还没摆上板的零件。点一下就落到当前这块板上 ——
    /// 从这么小一个缩略图一路拖到放大了的板上，手指中途一抖就得重来。
    /// 落位之后再拖着挪，起手点是板上那个实实在在的零件。
    private var partsTray: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text(unplaced.isEmpty
                     ? "零件已全部放置"
                     : "还有 \(unplaced.count) 个未摆放")
                    .font(.footnote)
                    .foregroundColor(Theme.ColorToken.Text.secondary)
                Spacer()
                if !unplaced.isEmpty {
                    Button { fillRemaining() } label: {
                        Label("自动排列", systemImage: "square.grid.3x3.fill")
                            .font(.footnote.weight(.medium))
                    }
                }
            }

            if unplaced.isEmpty {
                Text("拼完这块板后，可在上方切换到下一块。")
                    .font(.caption)
                    .foregroundColor(Theme.ColorToken.Text.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 76)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.sm) {
                        ForEach(unplaced) { part in
                            Button { place(part) } label: { trayCell(part) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(height: 76)
            }
        }
    }

    private func trayCell(_ part: BeadPart) -> some View {
        let footprint = part.footprint(turns: 0)
        return VStack(spacing: 2) {
            ZStack(alignment: .topLeading) {
                PartShapeThumbnail(footprint: footprint, colors: colorCache)
                    .frame(width: 48, height: 48)
                // 零件条上也写号：条里挑一个放上去、板上出现一个号，两边是同一个数字，
                // 用户才知道刚放上去的是哪一个。
                orderBadge(part.id, size: 9)
                    .padding(3)
            }
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .fill(Theme.ColorToken.Surface.subtle)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
            )
            Text("\(footprint.width)×\(footprint.height)")
                .font(.caption2.monospacedDigit())
                .foregroundColor(Theme.ColorToken.Text.secondary)
        }
        .contentShape(Rectangle())
    }

    /// 编号胶囊。跟「零件清单」那屏缩略图上那个长一样 —— 同一个号在两屏之间
    /// 换个样子出现，用户就得先确认「这两个号是不是一回事」。
    private func orderBadge(_ partId: UUID, size: CGFloat) -> some View {
        Text("\(partOrder[partId] ?? 0)")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(Theme.ColorToken.Text.onAccent)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Theme.ColorToken.Morandi.mauve))
    }

    /// 这块板上用到的颜色。点一下只剩它是亮的 —— 抓一把 H7 的时候，
    /// 眼睛要的是「哪几个坑」，不是「这一格是什么色号」。
    ///
    /// 拼完一个色就在这儿按一下「标记已完成」，色号上挂个勾，然后自动跳到下一个没拼的。
    /// 一块板十几个色号，拼上好几个晚上、中途还会被打断 —— 靠脑子记「刚才拼到哪个色」
    /// 是记不住的，而漏掉一个色往往要等整板烫完才发现。
    private var colorTray: some View {
        // **只算一次**：`boardColors` 要把板上每一颗豆子数一遍（一块 50×50 的板两千多格），
        // 而这一段要用到它四回。写成 `boardColors.xxx` 四次就是数四遍。
        let colors = boardColors
        let board = currentBoard
        let done = colors.filter { board?.isColorDone($0.key, count: $0.count) ?? false }.count
        return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                Text(highlightKey.map { "仅高亮「\(label(for: $0))」，再次点击可取消" }
                     ?? "选择一个颜色，仅高亮该颜色对应的格子")
                    .font(.footnote)
                    .foregroundColor(Theme.ColorToken.Text.secondary)

                Spacer(minLength: Theme.Spacing.sm)

                doneControl(colors: colors, doneCount: done)
            }

            if colors.isEmpty {
                Text("这块板尚未放置任何零件。")
                    .font(.caption)
                    .foregroundColor(Theme.ColorToken.Text.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 76)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.sm) {
                        ForEach(colors, id: \.key) { entry in
                            Button {
                                highlightKey = highlightKey == entry.key ? nil : entry.key
                            } label: {
                                colorChip(key: entry.key, count: entry.count,
                                          isDone: board?.isColorDone(entry.key, count: entry.count) ?? false)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(height: 76)
            }
        }
        .haptic(.success, trigger: doneToggles)
    }

    /// 选中一个色号时才有：这个色拼完了没有。
    ///
    /// 放在提示行右边，不做成色块上的小按钮 —— 40 点的色块上再叠一个能点的勾，
    /// 手指点下去分不清是要高亮还是要打勾，而这两件事的后果差很远。
    @ViewBuilder
    private func doneControl(colors: [(key: String, count: Int)], doneCount: Int) -> some View {
        if let key = highlightKey, let count = colors.first(where: { $0.key == key })?.count {
            let isDone = currentBoard?.isColorDone(key, count: count) ?? false
            Button {
                toggleColorDone(key: key, count: count, wasDone: isDone, colors: colors)
            } label: {
                // 两句分开写，不写成 `Label(isDone ? "A" : "B", ...)`：三元里两个字面量
                // 会让 `Label` 挑到 `StringProtocol` 那个重载，文案就不进本地化表了。
                if isDone {
                    Label("标记未完成", systemImage: "arrow.uturn.backward").font(.footnote)
                } else {
                    Label("标记已完成", systemImage: "checkmark.circle").font(.footnote)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(isDone ? Theme.ColorToken.Text.secondary : Theme.ColorToken.Status.success)
        } else if doneCount > 0 {
            // 没选色号时报个进度。回到这一屏第一眼要知道的就是「还剩几个色没拼」。
            Text("已完成 \(doneCount) / \(colors.count) 个颜色")
                .font(.footnote.monospacedDigit())
                .foregroundColor(Theme.ColorToken.Text.secondary)
                .fixedSize()
        }
    }

    private func colorChip(key: String, count: Int, isDone: Bool) -> some View {
        let isOn = highlightKey == key
        return VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(colorCache[key] ?? Theme.ColorToken.Surface.strong)
                .frame(width: 40, height: 40)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isOn ? Theme.ColorToken.Morandi.honey : Theme.ColorToken.Border.default,
                                lineWidth: isOn ? 3 : 1)
                )
                // 勾挂在色块右上角，**色块本身一点都不能压暗**：用户就是靠这块颜色
                // 去认手上那袋豆子的，蒙一层灰它就跟旁边那个相近色分不开了。
                //
                // 压在色块里面、不往外探（早先 `offset` 探出去过）：这条色号条外面
                // 套着一个高 76 的横向 ScrollView，探出上边的那半个勾会被它切掉。
                // 底下垫一圈白：绿勾落在绿豆子上时，不垫就跟底色糊成一团。
                .overlay(alignment: .topTrailing) {
                    if isDone {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Theme.ColorToken.Text.onAccent,
                                             Theme.ColorToken.Status.success)
                            .background(Circle().fill(Theme.ColorToken.Text.onAccent))
                            .padding(2)
                    }
                }
            Text(label(for: key))
                .font(.caption2.weight(.medium))
                .foregroundColor(isDone ? Theme.ColorToken.Text.secondary : Theme.ColorToken.Text.primary)
                .lineLimit(1)
            Text("\(count) 颗")
                .font(.caption2.monospacedDigit())
                .foregroundColor(Theme.ColorToken.Text.secondary)
        }
        .frame(width: 56)
        .contentShape(Rectangle())
    }

    /// 打勾 / 取消打勾。
    ///
    /// 打完勾自动跳到下一个还没拼的色号 —— 用户此刻手上刚放下一把豆子，下一步一定是
    /// 「那接着拼哪个」。让他自己回色号条上找的话，找的正是那几个颗数相同、看起来
    /// 差不多的色号。全部拼完就取消高亮并说一声，别停在最后一个色上假装还有事做。
    private func toggleColorDone(key: String, count: Int, wasDone: Bool,
                                 colors: [(key: String, count: Int)]) {
        guard boards.indices.contains(boardIndex) else { return }
        if wasDone {
            boards[boardIndex].clearColorDone(key)
        } else {
            // **在本地这份拷贝上打勾，再拿它去找下一个**，不写完再从 `boards` 读回来 ——
            // 写完同一轮读回来不保证拿到新值（`DragSession` 就是栽在这上面），
            // 读回旧值的话「下一个」会挑中刚打完勾的这个，用户点一下等于原地没动。
            var board = boards[boardIndex]
            board.markColorDone(key, count: count)
            boards[boardIndex] = board
            // 手上正抓着一把豆子、眼睛在板子上，这一下值得有个手感 —— 不用抬头
            // 确认自己到底点着没有。取消那一下不给：那是撤销，本来就要看着屏幕做。
            doneToggles += 1
            if let next = colors.first(where: { !board.isColorDone($0.key, count: $0.count) }) {
                highlightKey = next.key
            } else {
                highlightKey = nil
                flash(String(localized: "这块板的颜色已全部完成"))
            }
        }
        onPersist()
    }

    // MARK: - 板子和零件

    private var currentBoard: PartsBoard? {
        boards.indices.contains(boardIndex) ? boards[boardIndex] : nil
    }

    private var placedIds: Set<UUID> {
        Set(boards.flatMap { $0.placements.map(\.partId) })
    }

    /// 还没摆上板、而且**真的有豆子**的零件。
    ///
    /// 整块都是空的那种（框歪了框到一片背景上）不算 —— 它没有一颗豆子可放，
    /// 摆上去也什么都不会出现。之前没滤掉，零件条里就挂着一个 0×0 的空方块，
    /// 点它没反应，还一直写着「还有 1 个没摆」，用户永远摆不完。
    private var unplaced: [BeadPart] {
        let placed = placedIds
        return parts.filter { !placed.contains($0.id) && $0.beadCount > 0 }
    }

    /// 当前选中的是哪个零件（选中态挂在「摆放」上，这里翻成零件）
    private var selectedPartId: UUID? {
        guard let id = selection else { return nil }
        return currentBoard?.placements.first(where: { $0.id == id })?.partId
    }

    /// 板上每个摆放身上写的号。零件已经不在图纸上了，号是它跟图纸之间唯一的线。
    private func labels(for board: PartsBoard) -> [UUID: String] {
        var result: [UUID: String] = [:]
        for placement in board.placements {
            guard let order = partOrder[placement.partId] else { continue }
            result[placement.id] = "\(order)"
        }
        return result
    }

    /// 这个零件摆在第几块板上、转了几次。没摆上板时是 nil。
    private func placementInfo(of partId: UUID) -> PartOriginalSheet.Placement? {
        for (index, board) in boards.enumerated() {
            guard let hit = board.placements.first(where: { $0.partId == partId }) else { continue }
            return PartOriginalSheet.Placement(boardNumber: index + 1, turns: hit.turns)
        }
        return nil
    }

    /// 打开大图对照。
    ///
    /// 这里**不再补裁一次**：能点开这个按钮就说明零件已经选中了，选中那一下的
    /// `.task(id: selectedPartId)` 早就在裁；而 `originals` 是 @State，裁完这一屏
    /// 连同弹窗都会跟着重画。补的那一刀只会让同一块被并发裁两遍。
    private func inspect(_ partId: UUID) {
        guard let part = parts.first(where: { $0.id == partId }) else {
            // 200pt 的大按钮点了没反应是最难受的一种坏 —— 至少要说一句、留一行日志。
            AppLogger.shared.warning("PartsBoard", "inspect_part_missing", metadata: [
                "partId": partId.uuidString
            ])
            flash(String(localized: "这块对不上任何零件了，回零件清单重新拆一次"))
            return
        }
        inspecting = part
    }

    /// 「上一个 / 下一个」按下去做什么。到头了就返回 nil —— 那一头的按钮变灰。
    ///
    /// 翻的是**零件清单的顺序**（也就是板上写的号），不是这块板上的顺序：
    /// 号是用户唯一记得住的线索，而翻到别的板上的零件时，弹窗里「摆在」那一行会说清楚。
    private func stepAction(from partId: UUID, by delta: Int) -> (() -> Void)? {
        guard parts.count > 1,
              let index = parts.firstIndex(where: { $0.id == partId }) else { return nil }
        let target = index + delta
        guard parts.indices.contains(target) else { return nil }
        let next = parts[target]
        return { inspecting = next }
    }

    /// 把这个零件在图纸上原来那块抠出来。四周留 6% 余量，跟零件清单那屏的小图一个裁法
    /// （`PartsThumbnailMaker.make`）—— 两屏裁得不一样的话，用户会以为自己看的是两个零件。
    ///
    /// **抠不出来要记成 `.unavailable`，不能一声不响地返回。** 裁失败是确定性的
    /// （同一张工作图、同一块 bounds，重开几次都是同一个结果），静默返回的话
    /// `originals[partId]` 停在 nil，屏幕上就是一个永远转下去的圈，而用户不知道该不该等。
    /// 顺带记一条日志：裁跑在后台，nil 本身不带原因，不记的话事后无从查起。
    private func loadOriginal(for partId: UUID?) async {
        guard let partId, let part = parts.first(where: { $0.id == partId }) else { return }
        if case .some(.ready) = originals[partId] { return }
        // 这次根本没有图纸可抠：立刻定论，别让用户等一个不会来的东西。
        guard let work else {
            originals[partId] = .unavailable
            return
        }

        originals[partId] = .loading
        let bounds = part.bounds
        let source = work
        let cropped = await Task.detached(priority: .userInitiated) {
            PartsThumbnailMaker.crop(source, normalized: bounds.insetBy(
                dx: -bounds.width * 0.06, dy: -bounds.height * 0.06
            ))
        }.value

        // 取消 ≠ 失败：用户换选了别的零件而已，把这条退回「没试过」，下次选中重来。
        guard !Task.isCancelled else {
            if case .some(.loading) = originals[partId] { originals[partId] = nil }
            return
        }
        guard let cropped else {
            originals[partId] = .unavailable
            AppLogger.shared.warning("PartsBoard", "part_original_crop_failed", metadata: [
                "partId": partId.uuidString,
                "bounds": "\(bounds)",
                "region": "\(source.region)",
                "workSize": "\(source.image.size)"
            ])
            return
        }
        originals[partId] = .ready(cropped)
    }

    /// 大图角上写什么。三种状态三句话：只有真拿到图纸原图时才敢说「对照」，
    /// 另外两种都得先讲清楚现在画的是识别结果。
    private func previewCaption(_ state: PartOriginalSheet.Original)
    -> (text: String, icon: String) {
        switch state {
        case .ready:
            return (String(localized: "点开对照"), "rectangle.on.rectangle")
        case .loading:
            return (String(localized: "图纸原图还在抠，这是识别结果"), "clock")
        case .unavailable:
            return (String(localized: "图纸原图拿不到，这是识别结果"), "photo.badge.exclamationmark")
        }
    }

    private func aspect(of image: UIImage) -> CGFloat {
        guard image.size.height > 0 else { return 1 }
        return image.size.width / image.size.height
    }

    /// 这个零件的原图现在是什么状态。字典里还没有 = 选中那一下的裁图刚要开始 ——
    /// 但没有图纸时连开始都不会开始，那就直接说拿不到，别先闪一下转圈。
    private func originalState(of partId: UUID) -> PartOriginalSheet.Original {
        if let known = originals[partId] { return known }
        return work == nil ? .unavailable : .loading
    }

    private func name(of partId: UUID) -> String {
        guard let index = parts.firstIndex(where: { $0.id == partId }) else {
            return String(localized: "零件")
        }
        return parts[index].displayName(order: index)
    }

    private func beadCount(of board: PartsBoard) -> Int {
        board.placements.reduce(0) { sum, placement in
            sum + (footprints[placement.id]?.beads.count ?? 0)
        }
    }

    /// 这块板上每个色号有多少颗，多的排前面。
    ///
    /// 顺序的规矩在 `BeadColorTally` —— 颗数一样时也得排得死死的。这条色号条是用户
    /// 一个色一个色往下拼的清单，两个颗数相同的色号换了位置，他会当成已经拼过的那个，
    /// 直接跳过去。
    private var boardColors: [(key: String, count: Int)] {
        guard let board = currentBoard else { return [] }
        var counts: [String: Int] = [:]
        for placement in board.placements {
            guard let footprint = footprints[placement.id] else { continue }
            for bead in footprint.beads { counts[bead.key, default: 0] += 1 }
        }
        return BeadColorTally.ordered(counts)
    }

    private func label(for key: String) -> String {
        key == "#any" ? String(localized: "任意色") : key
    }

    /// 高亮是给「当前这块板」选的，板上没这个色号了就得取消掉。
    ///
    /// 不取消的话：板上每颗豆子都不匹配，于是**整块板压成一片灰**（投到电视上就是一整面灰墙，
    /// 看着像崩了）；而色号条是按当前板算的，那个 chip 已经不在了 ——
    /// 提示还写着「再点一下取消」，却没有东西可以点。用户得随便选个别的颜色再取消才出得来。
    private func dropHighlightIfGone() {
        guard let key = highlightKey else { return }
        if !boardColors.contains(where: { $0.key == key }) { highlightKey = nil }
    }

    /// 形状缓存的失效条件：只跟「哪个零件、转了几次」有关。
    /// 位置故意不算进来 —— 拖动时每挪一格都重算一遍所有零件的形状，会直接卡住。
    ///
    /// 擦 / 补格子改的是格子内容，这里看不见，所以带上 `cellsRevision` 那个计数。
    /// 直接去数格子是不行的：这一句每渲染一帧都要算一次，而单图纸模式一张图纸七万格。
    private var shapeSignature: String {
        boards.flatMap { board in
            board.placements.map { "\($0.id)|\($0.partId)|\($0.turns)" }
        }.joined(separator: ",") + "#\(cellsRevision)"
    }

    /// 板子的现状。任何一处摆放变了（位置、转向、增删、换板尺寸、松紧、格子内容）都会变，
    /// 拿它当「该重算一遍还站不站得住」的触发条件 —— 比在八个改板子的地方各记一笔可靠。
    private var layoutSignature: String {
        var signature = "\(spacing.rawValue)|\(cellsRevision)"
        for board in boards {
            signature += "|\(board.cols)x\(board.rows)"
            for placement in board.placements {
                signature += "|\(placement.id)@\(placement.col),\(placement.row),\(placement.turns)"
            }
        }
        return signature
    }

    private func refreshInvalid() {
        let found = PartsBoardRepair.offendingPlacements(in: boards, parts: parts, spacing: spacing)
        if invalidPlacements != found { invalidPlacements = found }
    }

    /// 跟板上现在的颗数对不上的「已完成」标记，在这儿一并作废。
    ///
    /// 不作废的话那个勾会诈尸：零件被拿下来、色号被擦光、或者颗数改了又改回来之后，标记
    /// 还留在数据里，等颗数正好对上勾就自己回来了 —— 而用户根本没拼过它，照着勾跳过去
    /// 正好漏一色。
    private func pruneDoneColors(using shapes: [UUID: PartFootprint]) {
        var changed = false
        for index in boards.indices where boards[index].doneColors != nil {
            var counts: [String: Int] = [:]
            var ready = true
            for placement in boards[index].placements {
                guard let footprint = shapes[placement.id] else { ready = false; break }
                for bead in footprint.beads { counts[bead.key, default: 0] += 1 }
            }
            // 这块板上还挂着已经不在图纸里的零件（`makeFootprints` 找不到 partId 就跳过它），
            // 此刻数出来的颗数是缺的，照着它删等于把用户刚打的勾抹掉。`revalidateBoards` 里的
            // `PartsBoardRepair` 会把这种孤儿摆放摘掉，签名一变这里再跑一次 —— 这条依赖别断，
            // 断了这些标记就再也清不掉。
            guard ready else { continue }
            var board = boards[index]
            board.pruneDoneColors(matching: counts)
            // **没变就别写**：零件增删 / 转向 / 换板 / 擦补格子都会跑到这儿，无条件写回会把
            // 「有没有改过、要不要存盘」那个标记一直顶起来，白存一整张图纸的 JSON。
            guard board.doneColors != boards[index].doneColors else { continue }
            boards[index] = board
            changed = true
        }
        // 作废了就立刻落盘，理由同 `revalidateBoards`：库里那份跟屏幕上不一致本身就是坑
        //（投屏、导出、下次进来读到的都是旧的）。而「永久作废」不写下去就不叫永久。
        if changed { onPersist() }
    }

    /// 这个零件挪了位置 / 转了向，它用到的那几个色号的「已完成」标记跟着作废。
    ///
    /// 颗数一颗没变，所以 `pruneDoneColors` 那条路发现不了；而它认的 `shapeSignature`
    /// 又故意不含位置（见 `shapeSignature` 的注释），挪一下连跑都不会跑。可板上的豆子
    /// 是照着原来那个位置按上去的 —— 零件一挪，那片豆子整个要重摆，勾还挂着的话用户
    /// 下次接着拼时会直接跳过它。
    ///
    /// 只清这个零件用到的色号：同一块板上别的色跟这次挪动没关系，一并清掉的话用户
    /// 得重打一遍勾。
    ///
    /// 旋转那条路进来时 `footprints` 还是转之前那份（要等 `.task` 重算），不影响 ——
    /// 转向不改色号，前后用到的色号是同一批。
    private func clearDoneColors(touchedBy placementId: UUID) {
        guard boards.indices.contains(boardIndex),
              boards[boardIndex].doneColors != nil,
              let footprint = footprints[placementId] else { return }
        var board = boards[boardIndex]
        for key in Set(footprint.beads.map(\.key)) { board.clearColorDone(key) }
        guard board.doneColors != boards[boardIndex].doneColors else { return }
        boards[boardIndex] = board
        onPersist()
    }

    private func makeFootprints() -> [UUID: PartFootprint] {
        var result: [UUID: PartFootprint] = [:]
        for board in boards {
            for placement in board.placements {
                guard let part = parts.first(where: { $0.id == placement.partId }) else { continue }
                result[placement.id] = part.footprint(turns: placement.turns)
            }
        }
        return result
    }

    /// 色号 → 颜色。**MARD 不能走 `findColor(byCode:preferSystem:)`** ——
    /// 那个重载在 `preferSystem == .mard` 时直接返回 nil，走它的话整块板会是一片黑。
    private func makeColorCache() -> [String: Color] {
        var result: [String: Color] = ["#any": Theme.ColorToken.Morandi.mauve]
        for part in parts {
            for row in part.cells {
                for cell in row {
                    guard case .code(let code) = cell, result[code] == nil else { continue }
                    let bead = colorSystem == .mard
                        ? inventoryManager.findColor(byMardCode: code)
                        : inventoryManager.findColor(byCode: code, preferSystem: colorSystem)
                    result[code] = bead?.color ?? Theme.ColorToken.Surface.strong
                }
            }
        }
        return result
    }

    // MARK: - 排版

    private func autoPackIfNeeded() {
        guard !didAutoPack else { return }
        didAutoPack = true
        guard boards.isEmpty, !parts.isEmpty else { return }
        let size = BeadBoardSize(cols: savedCols, rows: savedRows)
        let used = spacing
        let packed = PartsBoardPacker.pack(parts: parts.filter(\.hasCells), size: size, spacing: used)
        boards = packed.boards
        // 一块板都没排出来（零件全都放不进去）就是「还没排过」，那一档不能落定 ——
        // 落定了 `spacing` 就不再听偏好，用户在菜单里换档会变成点了没反应。
        boardSpacing = packed.boards.isEmpty ? nil : used
        boardIndex = 0
        if !packed.unplaced.isEmpty {
            flash(unplacedNote(packed.unplaced.count, spacing: used))
        }
    }

    /// 「有几个零件没摆上去」该怎么说。
    ///
    /// 紧凑档放不下就是真的比板子大，只能换板。但默认/宽松档的可用区比板子小一圈，
    /// 一个 49 宽的零件在 50×50 板上紧凑放得下、默认放不下 —— 这时候让用户去买大板子
    /// 是把他往最贵的那条路上推，而最便宜的出路（退一档，板子不用换）反倒没人告诉他。
    private func unplacedNote(_ count: Int, spacing: BoardSpacing) -> String {
        spacing == .tight
            ? String(localized: "有 \(count) 个零件超出板子尺寸，请更换更大的板子")
            : String(localized: "有 \(count) 个零件在\(spacing.label)间距下无法放入，请调小间距或更换更大的板子")
    }

    private func repackAll() {
        guard let target = repackTarget else { return }
        repackTarget = nil
        savedCols = target.size.cols
        savedRows = target.size.rows
        // 理由同 `addBoard` —— 记在用户按下「重新排」之后，不记在他填完数的时候。
        customSizes = BeadBoardSize.remember(target.size, in: customSizes)
        // 只有用户亲手选了松紧才动偏好，理由见 `preferredSpacing` 和 `RepackTarget.pickedSpacing`。
        // 写在确认之后：弹窗上点「取消」不该改任何东西。
        if target.pickedSpacing { preferredSpacing = target.spacing }
        let packed = PartsBoardPacker.pack(parts: parts.filter(\.hasCells),
                                           size: target.size, spacing: target.spacing)
        boards = packed.boards
        boardSpacing = packed.boards.isEmpty ? nil : target.spacing
        boardIndex = 0
        selection = nil
        highlightKey = nil
        resetView()
        // 说清「按哪一档排的、排成几块」：换松紧最直观的反馈就是板数变了几块，
        // 而看到板数之前用户得先确认自己换的那一档真的生效了。
        // 有摆不下的也照样报板数 —— 这一下是销毁性的（手动挪的位置全没了），
        // 只说坏消息不说结果的话，用户不知道自己现在手上还剩什么。
        flash(packed.unplaced.isEmpty
              ? String(localized: "已按\(target.spacing.label)间距排列完成，共 \(packed.boards.count) 块板")
              : String(localized: "已按\(target.spacing.label)间距排列 \(packed.boards.count) 块板，还有 \(packed.unplaced.count) 个未能放入"))
    }

    /// 把还没摆的零件接着往板上放：先塞现有的板，塞不下再开新的。
    private func fillRemaining() {
        let size = currentBoard?.size ?? BeadBoardSize(cols: savedCols, rows: savedRows)
        let used = spacing
        var occupancies = boards.map { PartsBoardPacker.occupancy(of: $0, parts: parts, spacing: used) }
        var added = 0

        // 摆放规矩（先大后小、先原方向后转 90°、先塞现有板再开新板）全在 packer 里，
        // 跟进屏自动排走的是同一条路
        for item in PartsBoardPacker.ordered(unplaced) {
            if PartsBoardPacker.placeOne(item.part, footprint: item.footprint, into: &boards,
                                         occupancies: &occupancies, size: size, spacing: used) != nil {
                added += 1
            }
        }
        if !boards.isEmpty { boardSpacing = used }

        flash(added > 0
              ? String(localized: "已新增摆放 \(added) 个")
              : unplacedNote(unplaced.count, spacing: used))
    }

    /// 点了零件条里的一个零件：落到当前这块板上；这块满了就新开一块并切过去。
    ///
    /// **落位之后不选中它。** 选中会把整条零件条换成那个零件的大图（见 `bottomPanel`），
    /// 于是「接着点下一个」变成「先点收起，再点下一个」—— 一次点击换来的是每放一个零件
    /// 多一次点击，而「还有 N 个没摆」那句恰好在它最该确认放成功的时候消失。
    /// 放成功的证据在板上：那儿多了一块带号的零件，条里少了一个。
    private func place(_ part: BeadPart) {
        // 这里只认**当前这块板**（用户点的时候看着的就是它），所以不走 packer 的
        // placeOne（那个会挨块板试过去）；「怎么摆」的规矩还是共用 packer 那一份。
        let options = PartsBoardPacker.candidates(for: part)
        let used = spacing

        if let board = currentBoard,
           let hit = PartsBoardPacker.fit(
               options, in: PartsBoardPacker.occupancy(of: board, parts: parts, spacing: used)) {
            boards[boardIndex].placements.append(PartPlacement(
                partId: part.id, col: hit.col, row: hit.row, turns: hit.candidate.turns
            ))
            return
        }

        let size = currentBoard?.size ?? BeadBoardSize(cols: savedCols, rows: savedRows)
        guard let hit = PartsBoardPacker.fit(
            options, in: BoardOccupancy(cols: size.cols, rows: size.rows, spacing: used)) else {
            flash(unplacedNote(1, spacing: used))
            return
        }
        var board = PartsBoard(size: size)
        board.placements.append(PartPlacement(
            partId: part.id, col: hit.col, row: hit.row, turns: hit.candidate.turns
        ))
        boards.append(board)
        boardSpacing = used
        // switchTo 顺手把选中清掉了，正是这里要的（理由见函数头注释）
        switchTo(boards.count - 1)
        flash(String(localized: "这块板已放不下，已新开一块。"))
    }

    /// 自己填的那块板落地：记进「自己填过的」，再按当初点的是哪一条走。
    ///
    /// 在 sheet 的 `onDismiss` 里跑（理由见挂载处），这时 `customSizeTarget` 已经被清成
    /// nil 了，所以「点的是哪一条」跟着填好的格数一起存进 `pendingCustomSize`。
    /// 直接划走没按「确定」时它是 nil，什么都不做。
    private func applyCustomSize() {
        guard let pending = pendingCustomSize else { return }
        pendingCustomSize = nil
        let size = pending.size
        switch pending.target {
        case .addBoard:
            addBoard(size: size)
        case .repack:
            // 跟菜单里点常见规格走同一个确认弹窗 —— 重排会把手动挪过的位置全抹掉，
            // 「自己填的」不该因为多打了两个数就跳过这一问。
            repackTarget = RepackTarget(size: size, spacing: spacing, pickedSpacing: false)
        }
    }

    private func addBoard(size: BeadBoardSize) {
        let used = spacing
        savedCols = size.cols
        savedRows = size.rows
        // 「最近使用」记的是**真的用上了哪几块板**，不是「填过哪几个数」：填完在确认弹窗上
        // 点了取消的那个尺寸不该被置顶，而菜单里点已有的那块该挪到最前。所以记在这儿，
        // 不记在填数那一屏关掉的时候。常见规格 `remember` 会自己跳过。
        customSizes = BeadBoardSize.remember(size, in: customSizes)
        boards.append(PartsBoard(size: size))
        boardSpacing = used
        switchTo(boards.count - 1)
    }

    private func switchTo(_ index: Int) {
        guard boards.indices.contains(index) else { return }
        boardIndex = index
        selection = nil
        dropHighlightIfGone()
        resetView()
    }

    private func clearCurrentBoard() {
        guard boards.indices.contains(boardIndex) else { return }
        boards[boardIndex].placements = []
        selection = nil
        highlightKey = nil
    }

    private func removeCurrentBoard() {
        guard boards.indices.contains(boardIndex), boards.count > 1 else { return }
        boards.remove(at: boardIndex)
        switchTo(min(boardIndex, boards.count - 1))
    }

    // MARK: - 选中之后能干的事

    private func rotateSelected() {
        guard let id = selection,
              boards.indices.contains(boardIndex),
              let index = boards[boardIndex].placements.firstIndex(where: { $0.id == id }),
              let part = parts.first(where: { $0.id == boards[boardIndex].placements[index].partId })
        else { return }

        let old = boards[boardIndex].placements[index]
        let oldFootprint = part.footprint(turns: old.turns)
        let newTurns = (old.turns + 1) % 4
        let newFootprint = part.footprint(turns: newTurns)
        guard !newFootprint.isEmpty else { return }

        // 转完尽量还在原地：让新旧两块的中心对上，不然零件会莫名其妙跳到别处
        let centerCol = Double(old.col + oldFootprint.minCol) + Double(oldFootprint.width) / 2
        let centerRow = Double(old.row + oldFootprint.minRow) + Double(oldFootprint.height) / 2
        let col = Int((centerCol - Double(newFootprint.width) / 2).rounded()) - newFootprint.minCol
        let row = Int((centerRow - Double(newFootprint.height) / 2).rounded()) - newFootprint.minRow

        let occupancy = PartsBoardPacker.occupancy(of: boards[boardIndex], parts: parts,
                                                   spacing: spacing, ignoring: id)
        if occupancy.canPlace(newFootprint, col: col, row: row) {
            boards[boardIndex].placements[index] = PartPlacement(
                id: id, partId: old.partId, col: col, row: row, turns: newTurns
            )
            clearDoneColors(touchedBy: id)
        } else if let spot = PartsBoardPacker.firstFit(newFootprint, occupancy: occupancy) {
            boards[boardIndex].placements[index] = PartPlacement(
                id: id, partId: old.partId, col: spot.col, row: spot.row, turns: newTurns
            )
            clearDoneColors(touchedBy: id)
            flash(String(localized: "原位置无法旋转，已移至空余位置。"))
        } else {
            // 没转成，板上什么都没变 —— 勾不能动。
            flash(String(localized: "旋转后放不下，请先移开其他零件。"))
        }
    }

    /// 零件的格子被改过之后，板上跟着要处理的事。
    ///
    /// 判定本身在 `PartsBoardRepair`，这里只负责说人话。**判定必须只有一份**：
    /// 改格子的入口有两个（这一屏、以及核对颜色那屏），而只有这一屏看得见板子 ——
    /// 各写各的话，从核对页改出来的粘连没有任何地方会发现（见 `revalidateBoards`）。
    private func afterCellsChanged() {
        cellsRevision += 1
        colorCache = makeColorCache()
        let outcome = PartsBoardRepair.repair(boards: &boards, parts: parts, spacing: spacing)
        footprints = makeFootprints()
        refreshInvalid()
        if !boards.contains(where: { $0.placements.contains { $0.id == selection } }) {
            selection = nil
        }
        dropHighlightIfGone()
        if let note = note(for: outcome) { flash(note) }
    }

    /// 进这一屏就先给所有板子做一次体检。
    ///
    /// 这不是重复劳动：从**核对颜色**那屏擦 / 补过的格子，改完时人还在那一屏，板子
    /// 是在背后被改的 —— 那条路上没有任何地方会发现「这两个零件现在贴上了」。
    /// 用户下次看到板子就是在这儿，那就在这儿兜住，并且说清楚动了什么。
    private func revalidateBoards() {
        guard !boards.isEmpty else { return }
        let outcome = PartsBoardRepair.repair(boards: &boards, parts: parts, spacing: spacing)
        refreshInvalid()
        // **没动过就别写盘。** 挪不开的那种（`outcome` 是空的、但板上还有站不住的）
        // 每次进屏都会走到这儿，而写一次是整张图纸的 JSON —— 白写，还每次都把
        // `dirty` 顶起来。
        guard !outcome.isEmpty else { return }
        footprints = makeFootprints()
        dropHighlightIfGone()
        if let note = note(for: outcome) { flash(note) }
        // 修完就存。屏幕上已经跟用户说「挪到旁边空地了」，库里却还是那份挨着的布局 ——
        // 下次进来虽然会再修一遍（这一句是幂等的），但两边不一致本身就是个坑：
        // 备份、投屏、导出读到的都是没修过的那份。
        onPersist()
    }

    /// 体检动过什么，就跟用户说什么。
    ///
    /// **三件事各说各的，不挑一件说。** 早先是按「挨着 > 挪走 > 拿下来」只说最要紧的一条，
    /// 而「拿下来」恰恰是唯一没有别的地方看得见的：零件从板上消失，也不会回到零件条
    ///（那条只列还有豆子的），板头的计数悄悄少一个。挨着的那种反而有红边和常驻提示，
    /// 根本不缺这一句 —— 所以它压根不进这条提示。
    private func note(for outcome: PartsBoardRepair.Outcome) -> String? {
        var lines: [String] = []
        if !outcome.removed.isEmpty {
            lines.append(String(localized: "有 \(outcome.removed.count) 个零件已无豆子，已从板上移除（如需恢复，请返回「核对颜色」页面补充格子）"))
        }
        if !outcome.orphaned.isEmpty {
            // 这种回核对页也补不回来 —— 零件本身已经不在图纸上了，说法必须跟上面那条分开
            lines.append(String(localized: "有 \(outcome.orphaned.count) 块无法匹配任何零件，已从板上移除"))
        }
        if outcome.moved.count == 1, let moved = outcome.moved.first {
            // 挪的是用户自己摆的位置，能报名字就报名字 —— 「1 个零件」他还得自己找是哪个
            lines.append(String(localized: "「\(name(of: moved))」原地放不下，挪到旁边空地了"))
        } else if !outcome.moved.isEmpty {
            lines.append(String(localized: "有 \(outcome.moved.count) 个零件原地放不下，挪到旁边空地了"))
        }
        return lines.isEmpty ? nil : lines.joined(separator: "；")
    }

    private func takeOffSelected() {
        guard let id = selection, boards.indices.contains(boardIndex) else { return }
        boards[boardIndex].placements.removeAll { $0.id == id }
        selection = nil
        dropHighlightIfGone()
        tab = .parts
    }

    // MARK: - 手势

    /// 手指几乎没动 = 点按。选中 / 取消选中。
    private func endAsTap() {
        guard session.placement != nil else {
            selection = nil
            return
        }
        // 按下时 beginDrag 已经把它选上了，所以这里只处理「本来就选着，再点一下取消」
        if session.wasSelected { selection = nil }
    }

    private func beginDrag(at point: CGPoint) {
        guard let board = currentBoard, let hit = placement(at: point) else { return }
        session.placement = hit.id
        session.originCol = hit.col
        session.originRow = hit.row
        session.wasSelected = selection == hit.id
        session.occupancy = PartsBoardPacker.occupancy(of: board, parts: parts,
                                                       spacing: spacing, ignoring: hit.id)
        selection = hit.id
        drag = Drag(placement: hit.id, originCol: hit.col, originRow: hit.row)
    }

    private func updateMove(_ translation: CGSize) {
        guard let id = session.placement,
              let board = currentBoard,
              let footprint = footprints[id] else { return }
        let cell = layout(for: board).cell
        guard cell > 0 else { return }
        session.deltaCol = Int((translation.width / cell).rounded())
        session.deltaRow = Int((translation.height / cell).rounded())
        session.valid = session.occupancy?.canPlace(
            footprint,
            col: session.originCol + session.deltaCol,
            row: session.originRow + session.deltaRow
        ) ?? false

        var current = Drag(placement: id, originCol: session.originCol, originRow: session.originRow)
        current.deltaCol = session.deltaCol
        current.deltaRow = session.deltaRow
        current.valid = session.valid
        // 手指移动一像素就来一次 onChanged，但吸到格子上之后多半还是原来那一格。
        // 只有真的换了格子、或者「放不放得下」变了才写 @State，否则整块板白重画一遍。
        if drag != current { drag = current }
    }

    private func commitMove() {
        guard let id = session.placement, boards.indices.contains(boardIndex) else { return }
        guard session.deltaCol != 0 || session.deltaRow != 0 else { return }
        guard session.valid else {
            flash(dropRejectionNote(id))
            return
        }
        guard let index = boards[boardIndex].placements.firstIndex(where: { $0.id == id }) else { return }
        boards[boardIndex].placements[index].col = session.originCol + session.deltaCol
        boards[boardIndex].placements[index].row = session.originRow + session.deltaRow
        clearDoneColors(touchedBy: id)
    }

    /// 松手弹回去了，为什么。
    ///
    /// 三种原因用户要做的事完全不同：往里挪一点、先把旁边的挪开、或者压根不该挪到这儿。
    /// 都甩一句「这儿放不下」的话，用户只能靠试 —— 而每试一次都要重新拖一遍。
    private func dropRejectionNote(_ id: UUID) -> String {
        if let occupancy = session.occupancy, let footprint = footprints[id],
           occupancy.blockedByEdge(footprint,
                                   col: session.originCol + session.deltaCol,
                                   row: session.originRow + session.deltaRow) {
            return spacing.margin > 0
                ? String(localized: "此处放不下：板子最外圈需留空，豆子不能超出边界。")
                : String(localized: "此处放不下：已超出板子范围。")
        }
        return spacing.gap >= 2
            ? String(localized: "此处放不下：该档位零件间需留两格间距，请先移开相邻零件。")
            : String(localized: "此处放不下：零件间需留一格间距，熨烫时才不会粘连。")
    }

    /// 屏幕上这一点落在哪个零件上。按摆放顺序倒着找 —— 后摆的画在上面，也就该先被摸到。
    ///
    /// **先按豆子找，找不到才按外接矩形找。** 零件是不规则的，外接矩形之间会互相盖住；
    /// 只看矩形的话，手指明明按在 A 上，动的却是躺在它凹口里的 B。
    private func placement(at point: CGPoint) -> PartPlacement? {
        guard let board = currentBoard else { return nil }
        let layout = layout(for: board)
        guard layout.cell > 0 else { return nil }
        let col = Int(floor((point.x - layout.rect.minX) / layout.cell))
        let row = Int(floor((point.y - layout.rect.minY) / layout.cell))

        for placement in board.placements.reversed() {
            guard let footprint = footprints[placement.id] else { continue }
            if footprint.hasBead(col: col - placement.col, row: row - placement.row) {
                return placement
            }
        }
        // 小零件、细窄处按不准时的兜底：落在外接矩形里也算
        for placement in board.placements.reversed() {
            guard let footprint = footprints[placement.id] else { continue }
            let box = layout.boundingRect(of: footprint, col: placement.col, row: placement.row)
            if box.contains(point) { return placement }
        }
        return nil
    }

    // MARK: - 画布坐标

    /// 送到外屏的东西变了没有。
    ///
    /// **位置必须算进来**：挪一个零件只改 `col`/`row`，别的什么都不变
    /// （见 `commitMove`）。这里要是复用 `shapeSignature`，用户拖完一个零件放下，
    /// 电视上那个零件就一直停在旧位置 —— 而他正抬头照着电视摆豆子。
    /// `shapeSignature` 故意不含位置是为了别在拖动时重算形状，两者要求正相反，不能共用。
    ///
    /// 只看当前这块板：送出去的本来就只有它。
    private var castSignature: String {
        var signature = "\(boardIndex)|\(boards.count)|\(highlightKey ?? "")|\(colorCache.count)|\(cellsRevision)"
        // 描红的是哪几块也要送 —— 只送个数的话，一红一好地换人时电视上标错块。
        signature += "|" + invalidPlacements.map(\.uuidString).sorted().joined(separator: ",")
        for placement in currentBoard?.placements ?? [] {
            signature += "|\(placement.id)@\(placement.col),\(placement.row),\(placement.turns)"
        }
        return signature
    }

    private func publishToExternalDisplay() {
        guard let board = currentBoard else {
            BoardCastSession.shared.stop()
            return
        }
        BoardCastSession.shared.update(.init(
            board: board,
            footprints: footprints,
            colorCache: colorCache,
            highlightKeys: highlightKey.map { [$0] } ?? [],
            caption: String(localized: "第 \(boardIndex + 1) / \(boards.count) 块"),
            labels: labels(for: board),
            invalid: invalidPlacements
        ))
    }

    /// 这一屏当前要画的东西。板子的画法在 `BoardCanvas.swift`，跟外接屏幕共用一份。
    private func renderer(for board: PartsBoard) -> BoardCanvasRenderer {
        BoardCanvasRenderer(
            board: board,
            footprints: footprints,
            colorCache: colorCache,
            highlightKeys: highlightKey.map { [$0] } ?? [],
            labels: labels(for: board),
            selection: selection,
            moving: drag.map {
                .init(placement: $0.placement, deltaCol: $0.deltaCol,
                      deltaRow: $0.deltaRow, valid: $0.valid)
            },
            invalid: invalidPlacements
        )
    }

    private func layout(for board: PartsBoard) -> BoardCanvasLayout {
        .fitting(board, in: canvasSize, zoom: zoom, pan: pan)
    }

    private func unzoomed(_ point: CGPoint) -> CGPoint {
        guard zoom > 0 else { return point }
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        return CGPoint(x: center.x + (point.x - pan.width - center.x) / zoom,
                       y: center.y + (point.y - pan.height - center.y) / zoom)
    }

    /// 平移能走多远。按**板子**放大后的尺寸算，不按画布算：
    /// 板子多半跟画布不是一个比例（板子是正方的，画布是竖长条），放大 10 倍之后
    /// 它仍然比画布窄 —— 按画布算的话手指能一路把整块板推出屏幕，眼前只剩一片空白。
    /// 现在最多推到「板子那条边刚好贴着画布边」，板子始终在眼前。
    private func clampPan(_ offset: CGSize) -> CGSize {
        var content = canvasSize
        if let board = currentBoard {
            let fitted = BoardCanvasLayout.fitting(board, in: canvasSize)
            content = CGSize(width: fitted.rect.width * zoom, height: fitted.rect.height * zoom)
        }
        let limitX = max(0, (content.width - canvasSize.width) / 2)
        let limitY = max(0, (content.height - canvasSize.height) / 2)
        return CGSize(width: min(max(offset.width, -limitX), limitX),
                      height: min(max(offset.height, -limitY), limitY))
    }

    private func resetView() {
        zoom = 1; lastZoom = 1
        pan = .zero; lastPan = .zero
    }

    private func flash(_ text: String) {
        note = text
        noteToken = UUID()
    }
}

// MARK: - 零件条里的小图

/// 直接按格子画，不去原图上抠 —— 这里要认的是「零件长什么形状」，
/// 而形状就在 cells 里，抠图反而糊。
///
/// 对照弹窗（`PartOriginalSheet`）里画「识别出来的样子」用的也是它：
/// 那一屏就是要拿这张图跟图纸原图并排比，两张不是同一套画法的话比出来的差别不作数。
struct PartShapeThumbnail: View {
    let footprint: PartFootprint
    let colors: [String: Color]

    var body: some View {
        Canvas { context, size in
            guard footprint.width > 0, footprint.height > 0 else { return }
            let cell = min(size.width / CGFloat(footprint.width),
                           size.height / CGFloat(footprint.height))
            let originX = (size.width - cell * CGFloat(footprint.width)) / 2
            let originY = (size.height - cell * CGFloat(footprint.height)) / 2
            for bead in footprint.beads {
                let rect = CGRect(
                    x: originX + CGFloat(bead.col - footprint.minCol) * cell,
                    y: originY + CGFloat(bead.row - footprint.minRow) * cell,
                    width: cell, height: cell
                )
                context.fill(
                    Path(rect),
                    with: .color(colors[bead.key] ?? Theme.ColorToken.Surface.strong)
                )
            }
        }
    }
}
