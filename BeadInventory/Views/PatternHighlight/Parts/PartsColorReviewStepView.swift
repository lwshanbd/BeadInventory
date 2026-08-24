//
//  PartsColorReviewStepView.swift
//  BeadInventory
//
//  校色 —— 两条流程共用的一屏：
//    多零件模式第五屏（屏序见 PartsSheetFlowView 的头注释）
//    单图纸模式第三屏（见 SinglePatternFlowView，那边没有「任意色」，主按钮也不一样）
//
//  拼豆是一颗一颗把豆子按进板子，所以用户只关心两件事：
//  **这个色号要用多少颗**、**分别是哪几格**。这一屏就长成那个样子：
//
//    上面一排色号，写的是「H7 · 412 颗」；
//    点 H7，下面把这 412 格从图纸上原样抠出来铺成一片 ——
//    颜色不一致的那几个会自己跳出来；
//    点中它们（可以多选），底下改成别的色号、设为空、或者标成任意色。
//
//  刻意不显示百分比：占 10.6% 对一个一颗一颗放豆子的人没有任何意义。
//

import SwiftUI

struct PartsColorReviewStepView: View {
    let work: PartsWorkImage
    @Binding var parts: [BeadPart]
    let colorSystem: ColorSystem
    /// 上一步 AI 识别色号表得出的「这张图纸每个色号要多少颗」。
    /// 只作参照：核对时用户能直接比对「我认出 2,887 颗，图纸写的是 3,006 颗」，
    /// 差得多就说明这个色号还得再看看。
    let legendCounts: [String: Int]
    /// 把这一屏改过的东西立刻落盘。核对完一个色号、以及在图纸上擦 / 补完格子之后各调一次。
    /// 不然辛辛苦苦对完几百格，手一滑点了返回就全没了（改动只落在内存里的 parts 上）。
    let onPersist: () -> Void
    let onFinish: () -> Void

    /// 有没有「任意色」这一档。单图纸模式没有（理由见 `PartsBaseColorStepView.showsAnyColor`），
    /// 那一档的按钮也就不该出现 —— 点了会在图纸上留下一种它根本不该有的格子。
    var allowsAnyColor: Bool = true
    /// 主按钮怎么说。多零件的下一步是摆拼豆板，单图纸的下一步是照着高亮拼。
    var finishTitle: (Int) -> Text = { Text("去摆拼豆板 · 一共 \($0) 颗") }
    var finishIcon: String = "square.grid.3x3"
    /// 这一屏在核对什么。nil = 一块一块的零件（多零件模式），用零件自己的名字。
    var subjectLabel: String?

    @EnvironmentObject var inventoryManager: InventoryManager

    @State private var selectedGroup: PartCellFill = .empty
    @State private var selection: Set<CellRef> = []
    /// 当前色号的全部格子。算一次存下来 —— 一张平面图纸七万格，
    /// 框选时每拖一下都重新全图扫一遍的话，手指是拖不动的。
    ///
    /// **`nil` 是「还没算」，不是「一格也没有」。** 默认色号在 `.task` 里选，比首帧晚；
    /// 这中间要是拿空数组去画，用户看到的是一句「这个颜色一格也没有」——
    /// 而这一屏正是重开项目时的落地页（见 `PartsSheetFlowView` 恢复 path 那段）。
    ///
    /// 存下来的代价是得手动刷：换色号走 `select`，改格子走 `apply` / `undoLast` / 画笔的
    /// `onCommit`，重排走 `toggleSort`。漏一条不会崩也不会报错 —— `cellRect` 是纯几何算的，
    /// 只会安静地给用户看一张对不上的小图。
    @State private var groupCells: [CellRef]?
    /// 露头才裁的小图缓存（见 `CellSwatchCache`）
    @State private var swatchCache = CellSwatchCache()
    @State private var showingCodePicker = false
    @State private var pickedCodes: Set<String> = []
    /// 已经核对过的色号（按 groupKey）。只是给用户记进度用，不影响数据。
    @State private var confirmed: Set<String> = []
    /// 底下那三个按钮改过的格子，倒着记。**这一屏最容易一下子改错一大片**——
    /// 一格都没选中时它们作用于整类，单图纸模式的「空」那一类是五万格，
    /// 手滑点一下「这类是任意色」，五万格的判色结果当场没了，退出去也捡不回来。
    ///
    /// **只管当前色号上刚做的那一步。** 换色号、核对完这一个、去摆拼豆板、动画笔 ——
    /// 每一样都清空它（`select` / `confirmCurrentGroup` / 主按钮 / 画笔的 `onCommit`）。
    ///
    /// 不这么收的话，撤销条会跟着用户一路挂到别的色号上去：他在 H2 那一屏点「撤销」，
    /// 改回去的是屏幕外的 H7 并且立刻落盘，而眼前的格子一个都不动 —— 一个专门用来
    /// 「防止一下改错一大片」的东西，自己成了在用户看不见的地方改数据的路。
    /// 摆拼豆板那屏改过的格子同理：它跟这一屏共用一份 `parts`，而这一屏还在导航栈里活着
    ///（`path` 是 `[…, .review, .board]`），拿旧值盖回去会把人家刚在板上修好的格子洗掉。
    ///
    /// 代价是「进画笔补两格」之后，之前那次整类操作就撤不回来了。这是明知的取舍：
    /// 画笔改完，这里存的旧值可能已经不是那一格的上一手，硬撤只会盖掉刚补好的格子。
    @State private var undoStack: [CellEdit] = []
    @State private var showingPalette = false

    /// 按颜色排序。开着时铺出来的格子不再按图纸上的先后，而是**最不像这一类的排在最前面**。
    ///
    /// 一个色号动辄上千格，判错的那几格散在中间，靠一格一格看是找不出来的 ——
    /// 而它们多半是因为原图上的颜色离这一类的主色最远才判错的。
    ///（顶不出全部：跟这一类颜色本来就一样的那种判错，排序也没辙，见 `sorted`。）
    @State private var sortByColor = false
    /// 每一格在原图上的众数色（`QuantizedRGB` 索引），`[零件][行][列]`。
    /// nil = 还没量过 —— 量一遍要几百毫秒到几秒，所以等用户真的点「排序」才算。
    ///
    /// **零件那一维是 `parts` 的下标，不是 id**，而且量一次用到底、不作废。这一屏只改格子的
    /// 颜色，不动零件顺序也不动格线，所以成立；哪天这儿加了删零件 / 重对格线的路，
    /// 必须把它置 nil —— 下标错位不会崩（`mode(of:in:)` 兜住了），只会安静地排错。
    @State private var cellModes: [[[Int32]]]?
    /// 正在量颜色
    @State private var samplingColors = false
    /// 量到第几个零件了。单张图纸只有一个零件，量得飞快，就不报数了（nil）。
    @State private var samplingProgress: (done: Int, total: Int)?
    /// 量颜色的活儿。用户退出这一屏要停掉 —— 几十个零件能磨好几秒，
    /// 白算完还要跟下一屏抢 CPU，而且算完往一个已经没人看的界面里写。
    @State private var samplingTask: Task<Void, Never>?
    /// 顶上那条一次性的提示。**不能什么都不说**：点了「排序」没有任何反应、
    /// 或者整组改完发现一格都没变，用户只会以为按钮坏了。
    @State private var note: String?

    /// 框选模式。开着时列表不跟手滚动，拖一条对角线就把扫过的格子全选上。
    /// 一个色号动不动上千格，一格一格点是不可能的。
    @State private var marquee = false
    /// 正在拖的那个选框。**用的是格子那一片自己的坐标（`gridSpace`），不是屏幕坐标。**
    ///
    /// 手指拖到列表最下面时，列表会自己接着往下滚（见 `runAutoScroll`）——
    /// 那么这一笔的起点就得钉在内容上：钉在屏幕上的话，往下滚多少起点就跟着跑多少，
    /// 框永远只有屏幕那么大，用户一笔只能选到眼前这一屏。
    @State private var marqueeRect: CGRect?
    /// 这一笔的起点（`gridSpace` 坐标）。nil = 现在没在拖。
    @State private var marqueeAnchor: CGPoint?
    /// 手指现在按在屏幕的哪儿。自动滚的时候手指可以一动不动、拖动事件一个都不来，
    /// 但内容在走 —— 每滚一下都要拿它重算一次「框到哪儿了」。
    @State private var marqueeFinger: CGPoint?
    /// 这一次拖动开始前已经选中的，用来支持「框好几片」
    @State private var marqueeBase: Set<CellRef> = []
    /// 现在铺在屏幕上的那些格子的位置（`gridSpace` 坐标）。只在框选模式下收集 ——
    /// 平时收集会让格子进出屏幕时白白重算一份 preference 字典。
    @State private var cellFrames: [CellRef: CGRect] = [:]
    /// 这一笔从头到现在**见过的所有**格子的位置。滚出屏幕的格子会从 `cellFrames` 里消失，
    /// 光拿它算的话，刚框中的格子一滚出视野就又被取消选中了。
    ///
    /// 存的是内容坐标，所以滚动之后照样有效；格子那一片一换（换色号、排序、改过格子）
    /// 必须清掉，见 `setGroupCells`。
    @State private var marqueeFrames: [CellRef: CGRect] = [:]
    /// 格子那一片的左上角现在在屏幕的哪儿。手指是屏幕坐标、框是内容坐标，靠它换算。
    @State private var gridOrigin: CGPoint = .zero
    /// 列表这个窗口在屏幕上的位置。自动滚**起步**时靠它换算出「现在贴着顶的是哪一行」
    /// （见 `topVisibleIndex`）—— 手指在不在边上是拿当场的 `viewport` 判的，不读这个。
    /// 只在拖动事件里写，所以自动滚跑起来时它一定已经是新的。
    @State private var gridViewport: CGRect = .zero
    /// 自动往上 / 往下滚：0 停，±1 慢，±2 快（手指越贴边滚得越快）。
    /// 数值本身就是 `.task(id:)` 的 id —— 快慢一变就重起一个循环。
    @State private var autoScrollDir = 0
    /// 自动滚已经滚到第几格了（`groupCells` 的下标，取那一行最左边那格）。
    ///
    /// 自己数着往下走，而不是每一步现看屏幕上滚到哪儿：上一步的滚动动画还没走完，
    /// 现看会看到一个走到一半的位置，于是每一步都少滚一点，越滚越慢还一顿一顿的。
    ///
    /// 代价是它会跟真实位置脱节：滚到底时 `scrollTo(anchor: .top)` 够不着最后那几行，
    /// 下标却照数不误。所以**换方向时必须清掉重量**（见 `updateAutoScroll`），
    /// 不然往回拖会先空走十几拍、列表纹丝不动。
    @State private var autoScrollIndex: Int?

    /// 格子那一片自己的坐标系。滚动不影响它，所以量到的格子位置一直有效。
    private let gridSpace = "PartsColorReviewGrid"

    /// 正在图纸上擦 / 补格子的那一块
    @State private var brushTarget: BrushTarget?
    /// 挑一块来擦 / 补（只有多零件模式要挑）
    @State private var showingPartPicker = false
    /// 挑好了、等挑零件那一屏关掉之后再打开画笔。
    ///
    /// **不能在同一拍里关一个 sheet 开另一个** —— SwiftUI 只 present 一个，
    /// 另一个的标志停在 true 却没有界面（`PartsSheetFlowView` 的 Prompt 那段写过这件事）。
    /// 更糟的是 `BrushTarget.id` 就是零件 id：被吞之后再挑**同一个零件**，
    /// `.sheet(item:)` 认不出身份变化，那个零件的入口就永久死了，还没有任何提示。
    @State private var pendingBrushId: UUID?
    /// 挑零件那一屏的行。开之前算一次就够 —— 放在 sheet 的内容闭包里的话，
    /// 每次求值都要给所有零件重建一遍 `PartFootprint`（板子那屏专门缓存它就是因为这个贵）。
    @State private var pickerRows: [PartBrushPickerSheet.Row] = []
    private struct BrushTarget: Identifiable {
        let id: UUID
    }

    /// 一格的坐标：第几个零件、第几行、第几列
    struct CellRef: Hashable {
        let part: Int
        let row: Int
        let col: Int
    }

    /// 一次「改成…」：每一格连着它的上一手，撤销就是照着放回去。
    ///
    /// **一条数组而不是 refs / olds 两条平行的。** 两条的内存一模一样
    ///（`CellRef` 24 字节、`PartCellFill` 16 字节，合起来 40，拼成一条也是 40，量过），
    /// 但配对关系就得靠下标自己对齐 —— 那是白给的一类错位 bug。
    ///
    /// 逐格记旧值而不是只记「这一类原来是什么」：整组操作确实是同一个旧值，
    /// 但框选出来的那批不保证 —— `groupCells` 是存下来的，可能已经比 `parts` 陈旧
    ///（同 `groupCells` 那段注释）。
    ///
    /// 一格 40 字节，五万格一步约 2MB，所以 `pushUndo` 只留最近几步。
    private struct CellEdit {
        let cells: [(ref: CellRef, old: PartCellFill)]
        let newFill: PartCellFill
    }

    private let columns = [GridItem(.adaptive(minimum: 34), spacing: 6)]

    var body: some View {
        VStack(spacing: 0) {
            groupBar
            Divider()
            if sortByColor { sortHint }
            if let note { noteBar(note) }
            if let last = undoStack.last { undoBar(last) }
            cellGrid
            footer
        }
        .overlay { if samplingColors { samplingOverlay } }
        .onDisappear {
            samplingTask?.cancel()
            samplingTask = nil
            // 手势被系统打断时（来电、上滑回桌面）`onEnded` 不保证会来。不收的话，
            // 下次从「摆拼豆板」返回，`.task(id:)` 会拿着上一笔的旧手指位置重新起来 ——
            // 没人碰屏幕，列表自己滚，还一路往 selection 里塞格子。
            endMarqueeDrag()
        }
        .navigationTitle("核对颜色")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // 这一屏改的是「这一格是什么颜色」。另一半 —— 「这一格到底有没有豆子」——
                // 在这儿是解不了的：一个本该有豆子的空格躺在几万个空格中间，
                // 用户在铺出来的格子里根本找不到它。所以给一条去图纸上直接改的路。
                Button {
                    if parts.count == 1 {
                        brushTarget = BrushTarget(id: parts[0].id)
                    } else {
                        pickerRows = parts.enumerated().map { index, part in
                            PartBrushPickerSheet.Row(
                                id: part.id,
                                name: part.displayName(order: index),
                                beadCount: part.beadCount,
                                footprint: part.footprint(turns: 0)
                            )
                        }
                        showingPartPicker = true
                    }
                } label: {
                    // 图标和字自己拼，**不用 `Label`**：导航栏里的 `Label` 一律只画图标，
                    // `.labelStyle(.titleAndIcon)` 也压不住它（试过）。光一个橡皮图标，
                    // 用户得先猜它是干什么的 —— 而这一屏最需要的那件事
                    //（「这一格根本没有豆子」）就藏在它后面。
                    // 名字跟拼豆板那屏的按钮一致，两处是同一件事。
                    HStack(spacing: 4) {
                        Image(systemName: "eraser")
                        Text("改格子")
                    }
                }
                // 量颜色的那几秒也关掉。挡屏的那层盖不住导航栏（overlay 加在 VStack 上，
                // 而工具栏项是画到导航栏里去的），不关的话用户能在转圈的时候把画笔叫出来。
                .disabled(parts.isEmpty || samplingColors)
            }
        }
        .task { selectDefaultGroup() }
        .sheet(isPresented: $showingCodePicker, onDismiss: applyPickedCode) {
            ColorSelectionView(
                selectedColors: $pickedCodes,
                colorSystem: colorSystem,
                suggestedColors: patternColors,
                focusColor: currentGroupColor
            )
            .environmentObject(inventoryManager)
        }
        .sheet(isPresented: $showingPalette) {
            PartsPaletteSheet(
                rows: groups.map { group in
                    PartsPaletteSheet.Row(
                        key: group.key,
                        label: label(for: group.fill),
                        color: color(for: group.fill),
                        found: group.count,
                        onSheet: legendCount(for: group.fill),
                        isConfirmed: confirmed.contains(group.key),
                        isSelected: group.key == groupKey(selectedGroup)
                    )
                },
                onPick: { key in
                    if let hit = groups.first(where: { $0.key == key }) {
                        select(hit.fill)
                    }
                    showingPalette = false
                }
            )
        }
        .sheet(isPresented: $showingPartPicker, onDismiss: {
            // 等这一屏真的关掉了再开画笔，理由见 `pendingBrushId`
            if let id = pendingBrushId {
                pendingBrushId = nil
                brushTarget = BrushTarget(id: id)
            }
        }) {
            PartBrushPickerSheet(
                rows: pickerRows,
                colors: swatchColors,
                onPick: { id in
                    pendingBrushId = id
                    showingPartPicker = false
                }
            )
        }
        .sheet(item: $brushTarget) { target in
            PartCellBrushView(
                work: work,
                partId: target.id,
                parts: $parts,
                colorSystem: colorSystem,
                subject: brushSubject(for: target.id),
                allowsAnyColor: allowsAnyColor,
                onCommit: {
                    onPersist()
                    // 画笔动过格子之后，这里存的旧值可能已经不是那一格的上一手了 ——
                    // 再撤销就会把用户刚补好的格子一起盖回去。所以进过画笔，之前那几步
                    // 就撤不回来了（画笔那屏有自己的撤销，但它撤不了这一屏的整组操作）。
                    undoStack.removeAll()
                    // 铺出来的那一片是**存下来的**（`groupCells`），擦 / 补完必须自己刷 ——
                    // 擦掉的格子不刷就还留在这一组里，补上的格子进不来。
                    // 小图缓存不用动：那是按 `CellRef` 从图纸上裁的，格子改成什么颜色跟它
                    // 无关，新进这一组的那几格会自己按需裁（见 `swatch(for:)`）。
                    setGroupCells(orderedCells(of: selectedGroup))
                    // 选中的是 (零件下标, row, col)，而刚才那些格子可能已经换了一组 ——
                    // 留着的话，底下那排「这类都改成…」会作用到一批
                    // 用户以为自己早就取消掉的格子上。
                    selection.removeAll()
                }
            )
            .environmentObject(inventoryManager)
        }
    }

    /// 擦 / 补那一屏底下写的是在改哪一块
    private func brushSubject(for id: UUID) -> String {
        if let subjectLabel { return subjectLabel }
        guard let index = parts.firstIndex(where: { $0.id == id }) else {
            return String(localized: "这一块")
        }
        return parts[index].displayName(order: index)
    }

    /// 挑零件那一屏的小图要用的颜色表
    private var swatchColors: [String: Color] {
        var result: [String: Color] = ["#any": Theme.ColorToken.Morandi.mauve]
        for group in groups {
            guard case .code(let code) = group.fill else { continue }
            result[code] = color(for: group.fill)
        }
        return result
    }

    // MARK: - 上：色号一排

    private var groupBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.sm) {
                    ForEach(groups, id: \.key) { group in
                        Button { select(group.fill) } label: { chip(for: group) }
                            .buttonStyle(.plain)
                            .foregroundColor(Theme.ColorToken.Text.primary)
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
            }

            // 横着划过十几个色号才找得到要看的那一个，太难受了 —— 给一个展开，一屏看全。
            Button { showingPalette = true } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 44, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundColor(Theme.ColorToken.Text.secondary)
            .background(Theme.ColorToken.Surface.background)
        }
        .background(Theme.ColorToken.Surface.background)
    }

    /// 一个色号的小胶囊。写两个数：**认出来多少颗 / 图纸写多少颗**。
    /// 后面那个是上一步 AI 读色号表得到的，两个数差得多就说明这个色号还得再看看 ——
    /// 光给一个「2,887 颗」，用户没有任何参照物去判断它对不对。
    private func chip(for group: Group) -> some View {
        let isSelected = group.key == groupKey(selectedGroup)
        return HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(color(for: group.fill))
                .frame(width: 16, height: 16)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
                )
            if confirmed.contains(group.key) {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(Theme.ColorToken.Status.success)
            }
            Text(label(for: group.fill))
                .font(.footnote.weight(.medium))
            Text(countText(for: group))
                .font(.caption2.monospacedDigit())
                .foregroundColor(Theme.ColorToken.Text.secondary)
        }
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

    private func countText(for group: Group) -> String {
        if let onSheet = legendCount(for: group.fill) {
            return String(localized: "\(group.count) / \(onSheet) 颗")
        }
        return String(localized: "\(group.count) 颗")
    }

    /// 图纸色号表里写的颗数。空白和任意色不在表里，所以没有。
    private func legendCount(for fill: PartCellFill) -> Int? {
        guard case .code(let code) = fill else { return nil }
        return legendCounts[code]
    }

    private func select(_ fill: PartCellFill) {
        selectedGroup = fill
        selection.removeAll()
        // 撤销只管当前色号上刚做的那一步（理由见 `undoStack`）—— 换了色号就收
        undoStack.removeAll()
        marquee = false
        setGroupCells(orderedCells(of: fill))
    }

    // MARK: - 中：这个色号的所有格子

    /// 排序开着时顶上那条字。**必须有**：格子的先后一变，用户第一反应是「图纸怎么乱了」——
    /// 得当场告诉他现在是按什么排的、该往哪儿看。
    private var sortHint: some View {
        Label("同一种颜色排在一起，最不像「\(label(for: selectedGroup))」的排在最前面",
              systemImage: "arrow.up.arrow.down")
            .font(.caption)
            .foregroundStyle(Theme.ColorToken.Text.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.sm)
            .background(Theme.ColorToken.Surface.subtle)
    }

    /// 说一句就完事的提示条。用户点了个按钮，屏幕上必须有个交代。
    private func noteBar(_ text: String) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
            Text(text)
            Spacer(minLength: 0)
            Button("知道了") { note = nil }
        }
        .font(.caption)
        .foregroundStyle(Theme.ColorToken.Status.warning)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Theme.ColorToken.Surface.subtle)
    }

    /// 刚改完一片格子之后的那条回执 + 一条退路。
    ///
    /// 顺带补上了原来根本没有的回执：整类操作点下去，屏幕上只是一片格子悄悄消失了，
    /// 用户既不知道改掉了多少格，也没有任何办法确认自己点的是不是想点的那个按钮。
    /// 所以这里把「改了多少格、改成了什么」写出来，撤销就摆在同一行。
    private func undoBar(_ edit: CellEdit) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            // 灰只给说明那半边。整行一起灰的话（`.foregroundStyle` 挂在 HStack 上），
            // 按钮跟旁边那句字一个颜色一个字号，看着就不像能点的东西 ——
            // 而这一条存在的全部意义就是那个按钮。
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(Theme.ColorToken.Text.secondary)
            Text("刚把 \(edit.cells.count) 格改成「\(label(for: edit.newFill))」")
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(Theme.ColorToken.Text.secondary)
            Spacer(minLength: 0)
            Button(action: undoLast) {
                Label("撤销", systemImage: "arrow.uturn.backward")
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Theme.ColorToken.Surface.subtle)
    }

    /// 量颜色的那几秒。把这一屏挡住，免得用户以为没反应又点一遍。
    /// 导航栏在这层外面，「改格子」那个按钮是另外用 `.disabled` 关掉的。
    private var samplingOverlay: some View {
        ZStack {
            Color.black.opacity(0.12).ignoresSafeArea()
            VStack(spacing: Theme.Spacing.md) {
                ProgressView()
                // 多零件模式几十个零件要好几秒，得报个数；单张图纸太快，报了反而闪一下
                Text(samplingProgress.map {
                    String(localized: "正在看每格原本是什么颜色…（\($0.done)/\($0.total)）")
                } ?? String(localized: "正在看每格原本是什么颜色…"))
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
            }
            .padding(Theme.Spacing.xl)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(.regularMaterial)
            )
        }
    }

    /// 这一组的格子铺成一片。
    ///
    /// **框选模式下不能挂 `.scrollDisabled(true)`**（以前挂着）：它连
    /// `proxy.scrollTo` 一起挡掉，手指拖到边上时列表怎么也滚不动 —— 而那正是
    /// 「拖到最下面接着往下选」唯一的实现路子。列表不跟手滚，靠的是盖在上面那一层
    /// 自己收走了拖动手势（`marqueeLayer`），实测 ScrollView 抢不走。
    private var cellGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // 还没算出来（groupCells == nil）就什么都别说 —— 说「一格也没有」是撒谎
                if let refs = groupCells {
                    if refs.isEmpty {
                        ContentUnavailableView(
                            "这个颜色一格也没有",
                            systemImage: "square.dashed",
                            description: Text("上面换一个色号看看。")
                        )
                        .padding(.top, Theme.Spacing.xxl)
                    } else {
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(refs, id: \.self) { ref in
                                CellSwatch(
                                    image: swatch(for: ref),
                                    isSelected: selection.contains(ref)
                                )
                                .background {
                                    if marquee {
                                        GeometryReader { geo in
                                            Color.clear.preference(key: CellFramesKey.self,
                                                                   value: [ref: geo.frame(in: .named(gridSpace))])
                                        }
                                    }
                                }
                                .onTapGesture {
                                    if selection.contains(ref) { selection.remove(ref) } else { selection.insert(ref) }
                                }
                            }
                        }
                        .padding(Theme.Spacing.lg)
                        .coordinateSpace(name: gridSpace)
                        // 这一片的左上角跑到屏幕哪儿了 —— 手指（屏幕坐标）换算成内容坐标全靠它。
                        // **跟上面那份格子位置一样，只在框选模式下收**：这个值滚动每一帧都在变，
                        // 平时也收的话，每帧都要往 @State 里写一次，body 跟着整个重算 ——
                        // 而 body 里的色号栏要把所有零件逐格数一遍（`groups`），
                        // 七万格的图纸滚起来会当场发涩。
                        .background {
                            if marquee {
                                GeometryReader { geo in
                                    Color.clear.preference(key: GridOriginKey.self,
                                                           value: geo.frame(in: .global).origin)
                                }
                            }
                        }
                    }
                }
            }
            .onPreferenceChange(CellFramesKey.self) { frames in
                cellFrames = frames
                guard marquee else { return }
                // 见过的格子存下来：自动往下滚的时候，先框中的那些已经滚出屏幕了
                marqueeFrames.merge(frames) { _, new in new }
                if marqueeAnchor != nil { updateMarqueeSelection() }
            }
            .onPreferenceChange(GridOriginKey.self) { origin in
                guard let origin else { return }
                gridOrigin = origin
                // 滚动本身就在改「框到哪儿了」—— 手指不动也要跟着重算
                if marqueeAnchor != nil { updateMarqueeSelection() }
            }
            .overlay { if marquee { marqueeLayer } }
            .task(id: autoScrollDir) { await runAutoScroll(proxy) }
        }
    }

    /// 框选那一层。盖在格子上面自己收手势。
    private var marqueeLayer: some View {
        GeometryReader { geo in
            let viewport = geo.frame(in: .global)
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())

                if let rect = marqueeRect {
                    // 框是内容坐标：自动滚过之后，它的上半截已经在屏幕外面了，
                    // 底下 `.clipped()` 会把露到列表外的部分切掉。
                    let onScreen = rect.offsetBy(dx: gridOrigin.x - viewport.minX,
                                                 dy: gridOrigin.y - viewport.minY)
                    // 这个框是压在花花绿绿的图纸格子上的，底下什么颜色都可能有：
                    // 一道莫兰迪灰调的细边，碰上灰紫、藕粉那几格就整条看不见了，
                    // 用户拖了半天不知道自己框到哪儿。改成深色芯 + 白色包边两道 ——
                    // 底下是深豆时白边跳出来，是浅豆时深芯跳出来，总有一道分得开。
                    // 里面那层填充仍然很淡：这一屏是用来看颜色的，框住的格子被染一层紫
                    // 就没法判断它到底是哪个色号了 —— 「框到哪儿了」交给两道边说。
                    Rectangle()
                        .fill(Theme.ColorToken.Fill.mauve.opacity(0.2))
                        .overlay(Rectangle().stroke(Color.white, lineWidth: 5))
                        .overlay(Rectangle().stroke(Theme.ColorToken.Morandi.mauve, lineWidth: 3))
                        .frame(width: onScreen.width, height: onScreen.height)
                        .position(x: onScreen.midX, y: onScreen.midY)
                        .allowsHitTesting(false)
                }
            }
            .clipped()
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { value in
                        if marqueeAnchor == nil {
                            marqueeBase = selection
                            marqueeAnchor = toGrid(value.startLocation)
                            marqueeFrames = cellFrames
                            autoScrollIndex = nil
                        }
                        marqueeFinger = value.location
                        gridViewport = viewport
                        updateMarqueeSelection()
                        updateAutoScroll(finger: value.location, viewport: viewport)
                    }
                    .onEnded { _ in endMarqueeDrag() }
            )
            .simultaneousGesture(
                // 框选模式下单点也要能加减一格，不然想补一格还得先退出去
                SpatialTapGesture(coordinateSpace: .global).onEnded { value in
                    let point = toGrid(value.location)
                    guard let hit = cellFrames.first(where: { $0.value.contains(point) })?.key
                    else { return }
                    if selection.contains(hit) { selection.remove(hit) } else { selection.insert(hit) }
                }
            )
        }
    }

    /// 屏幕坐标 → 格子那一片自己的坐标
    private func toGrid(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - gridOrigin.x, y: point.y - gridOrigin.y)
    }

    /// 按现在的起点和手指位置，重新算一遍框住了哪些格子。
    /// 手指动了要算，**列表自己滚了也要算** —— 滚动同样在改这个框盖住的范围。
    private func updateMarqueeSelection() {
        guard let anchor = marqueeAnchor, let finger = marqueeFinger else { return }
        let rect = CGRect(corner: anchor, to: toGrid(finger))
        marqueeRect = rect
        selection = marqueeBase.union(
            marqueeFrames.filter { $0.value.intersects(rect) }.keys
        )
    }

    /// 手指拖到列表上 / 下边上时，让列表自己接着滚。
    /// 框选模式下列表不跟手滚动，没有这一下的话，一次框选最多只能选到眼前这一屏。
    ///
    /// 边上这一条 76 点差不多两行格子高（一行 40）：窄了手指得贴着屏幕边才触发、
    /// 而那儿正好被指腹挡着看不见；宽了想在底下几行静止框选都做不到。
    /// 进去一半开始慢滚、贴到最边上快滚 —— 只有两挡，用户不用学。
    private func updateAutoScroll(finger: CGPoint, viewport: CGRect) {
        let zone: CGFloat = 76
        let dir: Int
        if finger.y > viewport.maxY - zone {
            dir = finger.y > viewport.maxY - zone / 2 ? 2 : 1
        } else if finger.y < viewport.minY + zone {
            dir = finger.y < viewport.minY + zone / 2 ? -2 : -1
        } else {
            dir = 0
        }
        guard dir != autoScrollDir else { return }
        // 掉头了就把自己数的那个下标清掉（理由见 `autoScrollIndex`）。
        // 只是慢挡换快挡（1→2）不清 —— 那样会白丢一次连续性。
        if dir.signum() != autoScrollDir.signum() { autoScrollIndex = nil }
        autoScrollDir = dir
    }

    /// 滚一行的结果。**「这一帧还量不到」和「到头了」必须分开** ——
    /// 手指停在边上不动时不会再有拖动事件，循环一停就没人重启，
    /// 一次瞬时的量不到会让这一整笔框选都不再自动滚。
    private enum ScrollStep {
        case scrolled
        /// 格子的位置还没送到（刚开框选、刚换色号就马上拖）。等下一拍再试。
        case notReady
        case reachedEnd
    }

    /// 自动滚的那个循环。手指停在边上一动不动也要接着滚，所以它是自己跑的，
    /// 不挂在拖动事件上。`autoScrollDir` 一变（换方向、换快慢、松手）就整个重来。
    ///
    /// **`@MainActor` 不能去掉。** 不标的话，从 `.task` 那个主线程闭包 await 进来会直接
    /// 跳到后台线程（SE-0338），于是 `withAnimation` + `scrollTo` 在主线程外面动布局、
    /// `ScrollViewProxy` 被跨线程传 —— 模拟器上照样跑得好好的，崩在用户手机上。
    @MainActor
    private func runAutoScroll(_ proxy: ScrollViewProxy) async {
        guard autoScrollDir != 0 else { return }
        let step = autoScrollDir > 0 ? 1 : -1
        // 一行 40 点（`CellSwatch` 的 34 + `columns` 的 spacing 6，改那两处这里要跟着改）：
        // 慢挡约每秒 200 点，快挡约每秒 570 点。
        let interval: Double = abs(autoScrollDir) > 1 ? 0.07 : 0.2
        while !Task.isCancelled {
            if scrollOneRow(proxy, step: step, duration: interval) == .reachedEnd { return }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    /// 往下（或往上）滚一行。
    private func scrollOneRow(_ proxy: ScrollViewProxy, step: Int, duration: Double) -> ScrollStep {
        guard let refs = groupCells, !refs.isEmpty else { return .notReady }
        // 列数每一拍现量。存下来的话，起手那一下要是还没量到（`cellFrames` 是空的），
        // 这一笔就会一直按错的列数走 —— 按 1 走就是一拍挪一格，`scrollTo` 的目标还在同一行，
        // 屏幕一动不动却以为自己在滚。
        guard let columns = measureColumns(),
              let base = autoScrollIndex ?? topVisibleIndex(in: refs) else { return .notReady }
        let target = min(max(base + step * columns, 0), refs.count - 1)
        guard target != base else { return .reachedEnd }
        autoScrollIndex = target
        // 动画时长跟循环的间隔一样长，一步接一步，看着就是匀速在滚
        withAnimation(.linear(duration: duration)) {
            proxy.scrollTo(refs[target], anchor: .top)
        }
        return .scrolled
    }

    /// 现在贴着列表上边的那一格是第几个（取那一行最左边那格）。
    /// 只在自动滚的第一步用一次，之后自己数（见 `autoScrollIndex`）。
    private func topVisibleIndex(in refs: [CellRef]) -> Int? {
        let top = gridViewport.minY - gridOrigin.y
        var bestRef: CellRef?
        var bestY = CGFloat.greatestFiniteMagnitude
        var bestX = CGFloat.greatestFiniteMagnitude
        for (ref, frame) in cellFrames where frame.maxY > top + 1 {
            if frame.minY < bestY - 1 {
                bestRef = ref
                bestY = frame.minY
                bestX = frame.minX
            } else if abs(frame.minY - bestY) <= 1, frame.minX < bestX {
                bestRef = ref
                bestX = frame.minX
            }
        }
        guard let bestRef else { return nil }
        return refs.firstIndex(of: bestRef)
    }

    /// 一行铺得下几格。`LazyVGrid` 是自适应列数，只能从量到的格子位置反推。
    /// nil = 这一帧还没量到。
    ///
    /// 同一行的格子上边缘一样高，按 `minY` 分桶（除以 2 是给浮点抖动留的余量），
    /// 取最满的那一行 —— 这一组的最后一行本来就可能不满。
    private func measureColumns() -> Int? {
        var perRow: [Int: Int] = [:]
        for frame in cellFrames.values {
            perRow[Int((frame.minY / 2).rounded()), default: 0] += 1
        }
        return perRow.values.max()
    }

    /// 松手 / 退出框选：这一笔到此为止，自动滚也停下。
    private func endMarqueeDrag() {
        autoScrollDir = 0
        autoScrollIndex = nil
        marqueeAnchor = nil
        marqueeFinger = nil
        marqueeRect = nil
    }

    // MARK: - 下：操作

    /// 底部只留一行提示 + 一排动作。
    ///
    /// 这里曾经写着「这里是被判成「P10」的所有格子。有不对的就点中它，可以多选。」——
    /// 上面的色号已经高亮着、格子已经铺在眼前了，这句话说的全是用户看得见的事。
    /// 屏幕下半截被字占满，真正要按的按钮反而被挤扁。
    private var footer: some View {
        VStack(spacing: Theme.Spacing.md) {
            HStack {
                if selection.isEmpty {
                    Text(unconfirmed.isEmpty
                         ? "每个色号都核对过了"
                         : "还有 \(unconfirmed.count) 个没核对")
                        .font(.footnote)
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                        // 右边挤着两个按钮，字一大这句就放不下。HStack 里的 Text 空间不够时
                        // 是直接截（「还有 7 个没…」），不会自己换行 —— 得明说可以往下长。
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("已选 \(selection.count) 格")
                        .font(.footnote)
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("取消选择") { selection.removeAll() }
                        .font(.footnote)
                }
                Spacer()
                Button(action: toggleSort) {
                    Label("排序", systemImage: sortByColor
                          ? "arrow.up.arrow.down.circle.fill"
                          : "arrow.up.arrow.down")
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                }
                .disabled(samplingColors)
                Button {
                    marquee.toggle()
                    endMarqueeDrag()
                    marqueeFrames = [:]
                    if !marquee { cellFrames = [:] }
                } label: {
                    Label(marquee ? "选完了" : "拖着框选",
                          systemImage: marquee ? "checkmark" : "rectangle.dashed")
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                }
                .padding(.leading, Theme.Spacing.md)
            }
            // **`lineLimit(1)` 只给按钮，别给整行**：加在 HStack 上会把左边那句
            // 「还有 7 个没核对」也截成「还有 7 个没…」，而那句话本来是可以换行放下的。

            // 没选中任何一格时，这三个按钮作用于整类 —— 图纸上那种
            // 「整片白其实是镂空、不是豆子」的情况，一格一格点几百下不现实。
            HStack(spacing: Theme.Spacing.sm) {
                Button {
                    if selection.isEmpty { selectWholeGroup() }
                    pickedCodes = []
                    showingCodePicker = true
                } label: {
                    Label(selection.isEmpty ? "这类都改成…" : "改成别的色号", systemImage: "paintpalette")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if allowsAnyColor {
                    Button {
                        if selection.isEmpty { selectWholeGroup() }
                        apply(.anyColor)
                    } label: {
                        Label(selection.isEmpty ? "这类是任意色" : "任意色", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    if selection.isEmpty { selectWholeGroup() }
                    apply(.empty)
                } label: {
                    Label(selection.isEmpty ? "这类没有豆子" : "设为空", systemImage: "square.dashed")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .font(.footnote)
            .lineLimit(1)

            // 一个色号一个色号地收工。以前只有一个「完成」，用户看完一个色号
            // 没有任何地方可以「记一笔」，十几个色号翻下来根本不记得看到哪儿了。
            Button(action: confirmCurrentGroup) {
                Label(confirmed.contains(groupKey(selectedGroup))
                      ? "「\(label(for: selectedGroup))」已核对"
                      : "「\(label(for: selectedGroup))」没问题，看下一个",
                      systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .font(.footnote)
            .buttonStyle(.bordered)
            .disabled(confirmed.contains(groupKey(selectedGroup)) && unconfirmed.isEmpty)

            Button {
                // 下一屏（摆拼豆板）跟这一屏共用一份 parts，而这一屏还留在导航栈里 ——
                // 退路留着，回来一撤就会把人家在板上刚改好的格子盖掉。
                undoStack.removeAll()
                onFinish()
            } label: {
                Label {
                    finishTitle(totalBeads)
                } icon: {
                    Image(systemName: finishIcon)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.regularMaterial)
    }

    // MARK: - 分组

    private struct Group {
        let fill: PartCellFill
        let count: Int
        var key: String
    }

    /// 色号按颗数从多到少，**「空白」永远排最后**。
    ///
    /// 空格数量比任何一个色号都大（零件轮廓外面、矩形四角、中间镂空全是空），
    /// 按颗数排会把真正要核对的色号全挤到后面去，所以钉在末尾。
    ///
    /// 但它必须在：图纸底色各不相同，底色判错时一整片本该是豆子的格子会被判成空，
    /// 而空格不进任何色号组 —— 列表里没有这一项的话，那些格子在这一屏根本点不到，
    /// 用户除了退出去重来没有第二条路。
    private var groups: [Group] {
        var counts: [String: (fill: PartCellFill, count: Int)] = [:]
        for part in parts {
            for row in part.cells {
                for cell in row {
                    let key = groupKey(cell)
                    counts[key, default: (cell, 0)].count += 1
                }
            }
        }
        let all = counts.map { Group(fill: $0.value.fill, count: $0.value.count, key: $0.key) }
        let beads = all.filter { $0.fill != .empty }.sorted { $0.count > $1.count }
        return beads + all.filter { $0.fill == .empty }
    }

    /// 图纸上一共要放多少颗豆子（空格不算）
    private var totalBeads: Int {
        groups.filter { $0.fill != .empty }.reduce(0) { $0 + $1.count }
    }

    /// 还没核对过的色号（空白也算一项 —— 底色判错是最常见的一种错）
    private var unconfirmed: [Group] {
        groups.filter { !confirmed.contains($0.key) }
    }

    /// 记下「这个色号我看过了」，然后自动跳到下一个还没看的。
    /// 十几个色号一个个点过去，用户很难记得自己看到哪儿了。
    private func confirmCurrentGroup() {
        confirmed.insert(groupKey(selectedGroup))
        selection.removeAll()
        // 「这个色号没问题」就是一个收工点：下面这一行会落盘，退路到此为止。
        //（后面多半会 `select` 到下一个色号，那里也清 —— 但没有下一个时走不到。）
        undoStack.removeAll()
        // 每核对完一个色号就落一次盘：这一屏的修改一直只在内存里的 parts 上，
        // 之前要走到「去摆拼豆板」才存。用户对完一个点「看下一个」，就当是存盘点。
        onPersist()
        if let next = unconfirmed.first {
            select(next.fill)
        }
    }

    /// 这张图纸自己用到的那些颜色 —— 上一步 AI 读色号表读出来的（`legendCounts` 的来源）。
    ///
    /// 判色判错时，用户要改成的那个正确色号几乎一定就在这十几个里面：图纸上就摆着
    /// 这么多种豆子。选色盘把它们排在最前面，用户不用再去四百多个色号里翻。
    ///
    /// 按**图纸写的**颗数从多到少排 —— 跟上面那条色号栏不是一个顺序，那条按**认出多少颗**
    /// 排。两个数不一样正是「认出 X 颗 / 图纸写 Y 颗」那个对照存在的理由。
    private var patternColors: [BeadColor] {
        legendCounts
            .sorted { $0.value > $1.value }
            .compactMap { bead(for: $0.key) }
    }

    /// 当前正在核对的这一组是哪颗豆子。只用来决定选色盘打开时停在哪个系列 ——
    /// 万一 AI 连色号表都读漏了，从判成的这个色号的邻居开始翻最省事。
    private var currentGroupColor: BeadColor? {
        guard case .code(let code) = selectedGroup else { return nil }
        return bead(for: code)
    }

    private func groupKey(_ fill: PartCellFill) -> String {
        switch fill {
        case .empty: return "#empty"
        case .anyColor: return "#any"
        case .code(let code): return code
        }
    }

    private func label(for fill: PartCellFill) -> String {
        switch fill {
        case .empty: return String(localized: "空")
        case .anyColor: return String(localized: "任意色")
        case .code(let code): return code.isEmpty ? String(localized: "未定色号") : code
        }
    }

    /// 色号 → 色库里那颗豆子。
    ///
    /// **MARD 不能走 `findColor(byCode:preferSystem:)`** —— 那个重载在
    /// `preferSystem == .mard` 时会跳过整段匹配直接返回 nil（它只负责「别跨品牌乱碰」，
    /// MARD 自己那一路留给了 `findColor(byMardCode:)`）。之前这里一律走前者，
    /// 于是 MARD 图纸上每一个色号的小方块都取不到颜色，全成了一片黑。
    ///
    /// 判色那步存进 `cells` 的就是 `displayCode(for: colorSystem)`，所以这里按体系分流。
    private func bead(for code: String) -> BeadColor? {
        colorSystem == .mard
            ? inventoryManager.findColor(byMardCode: code)
            : inventoryManager.findColor(byCode: code, preferSystem: colorSystem)
    }

    private func color(for fill: PartCellFill) -> Color {
        switch fill {
        case .empty: return Theme.ColorToken.Surface.subtle
        case .anyColor: return Theme.ColorToken.Morandi.mauve
        case .code(let code):
            guard let bead = bead(for: code) else { return Theme.ColorToken.Surface.subtle }
            return bead.color
        }
    }

    // MARK: - 排序

    /// 点「排序」。第一次点要先把每一格原本是什么颜色量一遍，之后再点就是纯排。
    ///
    /// 每一条都自己把 `groupCells` 摆好，**不走 `orderedCells`** —— 那个函数读的是
    /// `sortByColor` / `cellModes`，而这里刚写完它们，同一轮读回来不保证是新值
    ///（`PartsBoardStepView.DragSession` 栽过一次）。读到旧值的下场是点了排序没反应。
    private func toggleSort() {
        if sortByColor {
            sortByColor = false
            note = nil
            setGroupCells(cells(of: selectedGroup))
            return
        }
        if let modes = cellModes {
            turnSortOn(using: modes)
            return
        }
        let source = work
        let snapshot = parts
        samplingColors = true
        samplingProgress = nil
        samplingTask = Task.detached(priority: .userInitiated) {
            let modes = PartsCellClassifier.sampleModes(work: source, parts: snapshot) { done, total in
                // 多零件模式一屏几十个零件，量一遍是好几秒。光转圈的话用户不知道还要等多久。
                guard total > 1 else { return }
                Task { @MainActor in samplingProgress = (done, total) }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                samplingColors = false
                samplingTask = nil
                // 一格都没量到（图全没抠出来）就别把这份结果存下来：存了之后再点「排序」
                // 会走上面那条快路径，永远不会再量一次，用户除了退出整条流程没有别的办法。
                guard modes.contains(where: { $0.contains { $0.contains { $0 >= 0 } } }) else {
                    note = String(localized: "取不到图纸上的颜色，排不了序。回去看看零件的框是不是圈得太小。")
                    return
                }
                cellModes = modes
                turnSortOn(using: modes)
            }
        }
    }

    /// 真的排出来了才把开关打开。
    ///
    /// **不能无脑 `sortByColor = true`**：`sorted` 排不动时原样交回格子，而顶上那条
    /// 「同一种颜色排在一起…」照样显示 —— 用户翻两屏没看到异常就会认为这个色号没问题，
    /// 而这一屏存在的全部意义就是找出那几个异常。「什么都没发生」必须长得跟「排好了」不一样。
    private func turnSortOn(using modes: [[[Int32]]]) {
        guard let ordered = sorted(cells(of: selectedGroup), using: modes) else {
            sortByColor = false
            note = String(localized: "这一片的原图取不到，排不了序。")
            return
        }
        sortByColor = true
        note = nil
        setGroupCells(ordered)
    }

    /// 这一组的格子，按当前排序方式给出来。排序关着就是图纸上的先后（从上到下、从左到右）。
    private func orderedCells(of fill: PartCellFill) -> [CellRef] {
        let refs = cells(of: fill)
        guard sortByColor, let modes = cellModes else { return refs }
        return sorted(refs, using: modes) ?? refs
    }

    /// 按颜色排：**一种颜色一片，最不像这一类的那片排在最前面**。
    ///
    /// 只按「离代表色多远」排是不够的：那是一圈一圈的等距排法，红偏亮和红偏绿可能离
    /// 代表色一样远，于是两种根本不像的颜色被排到了一起。所以先把这一组里出现过的颜色
    /// 并成几类（`PartsCellClassifier.mergeDeltaE`），**整类整类地摆**，一类之内再按
    /// 离本类中心多远排。
    ///
    /// 「什么颜色」比的是每格的**众数色**（`PartsCellClassifier.sampleModes`，取众数的
    /// 理由写在那儿）。
    ///
    /// 主色类取**格子最多的那一类**，不取平均：一组里混进来的几十格杂色会把平均值拽偏，
    /// 于是真正的主色反倒排到前面去了。
    ///
    /// 分不开的情况是存在的，而且没法靠排序解决：图纸上的白豆子和留白本来就是同一个颜色，
    /// 判色分不开它们，排序照样分不开 —— 那种只能靠「改格子」在图纸上直接补。
    ///
    /// - Returns: `nil` = 这一组一格都没量到，**排不了**。调用方必须据此把开关关掉，
    ///   不能显示「已按颜色排序」（见 `turnSortOn`）。
    private func sorted(_ refs: [CellRef], using modes: [[[Int32]]]) -> [CellRef]? {
        let colors = refs.map { mode(of: $0, in: modes) }
        var counts: [Int32: Int] = [:]
        for color in colors where color >= 0 { counts[color, default: 0] += 1 }
        guard !counts.isEmpty else { return nil }
        guard refs.count > 1 else { return refs }

        let clusters = cluster(counts)
        // 主色类 = 格子最多的那一类。counts 非空 ⇒ 至少并出一类，所以这里一定有值。
        let dominant = clusters.groups.indices.max { clusters.groups[$0].count < clusters.groups[$1].count }!
        let dominantCenter = clusters.groups[dominant].center

        // 整类之间：离主色类越远的越靠前。同距离的按类的下标断，免得两类交错。
        let rank = clusters.groups.indices.sorted { lhs, rhs in
            let ld = GridCellSampler.deltaE(clusters.groups[lhs].center, dominantCenter)
            let rd = GridCellSampler.deltaE(clusters.groups[rhs].center, dominantCenter)
            return ld != rd ? ld > rd : lhs < rhs
        }
        var order = [Int](repeating: 0, count: clusters.groups.count)
        for (position, index) in rank.enumerated() { order[index] = position }

        // 每个量化色的排序键**先算好存起来**，而不是在比较函数里现查字典。
        // 一组五万格是八十万次比较，每次比较查四回字典 —— 那是三百万次哈希，
        // 而且整个 sorted 是在主线程上跑的（换个色号、改一格都会重排一次）。
        // 没量到的（-1）给 Int.max：它们不是「像」，是「不知道」，摆最前面等于让用户白找一趟。
        var keyOfColor: [Int32: (rank: Int, distance: Double)] = [:]
        for (color, group) in clusters.belongsTo {
            keyOfColor[color] = (order[group],
                                 GridCellSampler.deltaE(QuantizedRGB.labTable[Int(color)],
                                                        clusters.groups[group].center))
        }
        let keys = colors.map { keyOfColor[$0] ?? (Int.max, 0) }

        return refs.indices.sorted { l, r in
            if keys[l].rank != keys[r].rank { return keys[l].rank < keys[r].rank }
            // 一类之内：离本类中心越远的越靠前
            if keys[l].distance != keys[r].distance { return keys[l].distance > keys[r].distance }
            // 同距离的不同颜色也得分开摆，否则「同一种颜色连成一片」就不成立了
            if colors[l] != colors[r] { return colors[l] < colors[r] }
            return l < r                // Swift 的 sort 不保证稳定，同色的先后自己钉住
        }.map { refs[$0] }
    }

    private struct ColorGroup {
        var center: LabColor
        var count: Int
    }

    /// 把这一组出现过的颜色并成几类。**按格数从多到少并**，让最大的那几种颜色先立住类中心；
    /// 反过来先并杂色的话，主色会被一格一格的噪点拽着走。
    ///
    /// 阈值直接用判色那步的 `PartsCellClassifier.mergeDeltaE`。两边各写一个 8 的话，
    /// 改了那边这边不会有任何报错，而用户会看到判色认为是一种颜色的格子在这屏被切成两片。
    ///
    /// **这是贪心的准入判断，不是「一类之内两两 ΔE ≤ 8」的硬边界**：类中心会随着后并进来的
    /// 颜色慢慢挪，所以一个当初按 ΔE ≤ 8 收进来的颜色，最后可能离本类中心超过 8。
    /// 判色那步（`PartsCellClassifier.cluster`）用的是同一套贪心，两边保持一致比各自更严格更要紧。
    ///
    /// 一组格子再多，里头不同的量化色也就几十上百种（图纸是像素画），所以这里的两两比较
    /// 可以放心用 —— 真正贵的是逐格算，那一步在上面已经按量化色去重掉了。
    private func cluster(_ counts: [Int32: Int]) -> (groups: [ColorGroup], belongsTo: [Int32: Int]) {
        var groups: [ColorGroup] = []
        var belongsTo: [Int32: Int] = [:]
        let byCount = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        for (color, n) in byCount {
            let lab = QuantizedRGB.labTable[Int(color)]
            var nearest = -1
            var nearestDE = Double.infinity
            for (index, group) in groups.enumerated() {
                let de = GridCellSampler.deltaE(lab, group.center)
                if de < nearestDE { nearestDE = de; nearest = index }
            }
            if nearestDE <= PartsCellClassifier.mergeDeltaE, nearest >= 0 {
                let old = groups[nearest]
                let total = Double(old.count + n)
                groups[nearest] = ColorGroup(
                    center: LabColor(
                        l: (old.center.l * Double(old.count) + lab.l * Double(n)) / total,
                        a: (old.center.a * Double(old.count) + lab.a * Double(n)) / total,
                        b: (old.center.b * Double(old.count) + lab.b * Double(n)) / total
                    ),
                    count: old.count + n
                )
                belongsTo[color] = nearest
            } else {
                groups.append(ColorGroup(center: lab, count: n))
                belongsTo[color] = groups.count - 1
            }
        }
        return (groups, belongsTo)
    }

    private func mode(of ref: CellRef, in modes: [[[Int32]]]) -> Int32 {
        guard ref.part < modes.count,
              ref.row < modes[ref.part].count,
              ref.col < modes[ref.part][ref.row].count else { return -1 }
        return modes[ref.part][ref.row][ref.col]
    }

    private func cells(of fill: PartCellFill) -> [CellRef] {
        let key = groupKey(fill)
        var result: [CellRef] = []
        for (p, part) in parts.enumerated() {
            for r in 0..<part.rows where r < part.cells.count {
                for c in 0..<part.cols where c < part.cells[r].count {
                    if groupKey(part.cells[r][c]) == key {
                        result.append(CellRef(part: p, row: r, col: c))
                    }
                }
            }
        }
        return result
    }

    private func selectDefaultGroup() {
        if let first = groups.first { select(first.fill) }
    }

    // MARK: - 抠格子

    /// 把一格从图纸上原样抠出来。
    /// 用真实像素而不是画一个平均色的方块 —— 平均色是算法自己的结论，
    /// 拿它给用户看等于让算法自证清白；原图才能露出「这格其实压在两颗豆子之间」这种错。
    ///
    /// **谁露头才裁谁。** 以前是进屏之前把整组格子一次性裁完塞进一个字典，格子一多就撑不住。
    /// 这里封过两次顶，两次的坑还不一样，别把它们记成一回事：
    ///   · 1500 只封了裁图，格子照样全铺出来 —— 第 1501 格往后是灰底空方块，还照样能选能改。
    ///     用户看到的是「一大堆不知道为什么存在的空白格」，所以被拿掉过一次。
    ///   · 拿掉之后单图纸模式来了：一张平面图纸七万格，光「空」这一类就五万多，全裁完是
    ///     几十秒白屏。于是 3000 又封了回来，这次连列表一起封 —— 换来的是「这个色号只让你
    ///     看前 3000 格」，剩下的格子在这一屏根本点不到，判错了只能退出去重来。
    ///
    /// 两次封顶都是在给「一次性全裁」擦屁股。LazyVGrid 只实例化屏幕上那一屏（二三十格），
    /// 而裁一格是 `CGImage.cropping` + `UIImage(cgImage:)`，两步都不碰像素 —— 改成滚到哪儿
    /// 裁到哪儿之后这个前提没了，封顶不是被放宽，是失去了存在的理由。
    ///
    /// 注意这是**在 body 里同步跑的**（以前是 `Task.detached`）。哪天 crop 里加了缩放、调色
    /// 这类真活儿，七万格的滚动会当场死掉。
    private func swatch(for ref: CellRef) -> UIImage? {
        swatchCache.image(for: ref, source: work.image) {
            guard ref.part < parts.count else { return nil }
            let rect = parts[ref.part].cellRect(row: ref.row, col: ref.col)
            return PartsThumbnailMaker.crop(work, normalized: rect)
        }
    }

    // MARK: - 改

    /// 换一片格子（换色号、排序、改过格子之后重算）。
    ///
    /// **量到的格子位置必须跟着作废**：那些位置是按上一片格子的排布量的，留着的话，
    /// 框选会框中一批早就不在这一组里的格子 —— 底下「这类都改成…」会作用到它们身上，
    /// 而用户在屏幕上根本看不见自己选中了什么。
    private func setGroupCells(_ new: [CellRef]?) {
        defer { groupCells = new }
        // 铺出来的还是原来那一片（排序前后顺序一样是常事）就别动缓存：
        // `cellFrames` 只有 preference 变了才会重填，而格子一格没挪、preference 就不会再来 ——
        // 清了就一直空着，框选当场变成「框得出来、一格也选不中」。
        guard new != groupCells else { return }
        cellFrames = [:]
        marqueeFrames = [:]
        endMarqueeDrag()
    }

    private func selectWholeGroup() {
        selection = Set(groupCells ?? [])
    }

    /// 改格子。**先在本地改完再一次性写回 binding。**
    ///
    /// 逐格写 `parts[...]…= fill` 的话，每一格都是一次完整的 binding get→modify→set，
    /// 而 getter 交出来的临时数组会多持一份 `cells`，于是每次赋值都触发一次 COW。
    /// 整类操作（「这类没有豆子」作用于整组）在单图纸的空组上是五万格 —— 五万次状态写。
    private func apply(_ fill: PartCellFill) {
        var updated = parts
        var edits: [(ref: CellRef, old: PartCellFill)] = []
        edits.reserveCapacity(selection.count)
        for ref in selection {
            guard ref.part < updated.count,
                  ref.row < updated[ref.part].cells.count,
                  ref.col < updated[ref.part].cells[ref.row].count else { continue }
            let old = updated[ref.part].cells[ref.row][ref.col]
            // 本来就是这个色号的那些格子不记 —— 记了会让撤销条报一个比实际大的数
            guard old != fill else { continue }
            edits.append((ref, old))
            updated[ref.part].cells[ref.row][ref.col] = fill
        }
        // 一格都没变（在选色盘里挑回了这一组本来的色号）。**必须说一句** ——
        // 屏幕上什么都不动的话，用户不知道是自己挑错了还是这个按钮坏了。
        guard !edits.isEmpty else {
            note = String(localized: "这 \(selection.count) 格本来就是「\(label(for: fill))」，没有改动")
            selection.removeAll()
            return
        }
        parts = updated
        selection.removeAll()
        // 改过的格子已经不属于当前这一组了，铺出来的那片要跟着少掉
        setGroupCells(orderedCells(of: selectedGroup))
        pushUndo(CellEdit(cells: edits, newFill: fill))
    }

    /// 撤销栈只留最近 5 步。一步最大是整组几万格的旧值（五万格约 2MB），
    /// 封 5 步等于最多常驻十来兆；不封的话用户在一个色号上来回改就会一路涨上去。
    private func pushUndo(_ edit: CellEdit) {
        undoStack.append(edit)
        if undoStack.count > 5 { undoStack.removeFirst(undoStack.count - 5) }
    }

    /// 把上一次「改成…」放回去。
    ///
    /// **要落盘**：`apply` 自己不落盘（落盘在核对完一个色号、或画笔提交那两处），
    /// 但改错的那一片有可能已经被后来某一次落盘写进去了 ——
    /// 撤销完不写一次，用户退出去再进来，撤掉的东西又回来了。
    private func undoLast() {
        guard let last = undoStack.popLast() else { return }
        var updated = parts
        for (ref, old) in last.cells {
            guard ref.part < updated.count,
                  ref.row < updated[ref.part].cells.count,
                  ref.col < updated[ref.part].cells[ref.row].count else { continue }
            updated[ref.part].cells[ref.row][ref.col] = old
        }
        parts = updated
        // 数据刚被改回去，用户在这之后新点 / 新框的那批格子可能已经不在当前这一组里了
        selection.removeAll()
        setGroupCells(orderedCells(of: selectedGroup))
        onPersist()
    }

    /// 选色盘交回来的**永远是 mardCode** —— `ColorSelectionView` 不管传进去的
    /// `colorSystem` 是什么，往 selection 里插的都是 `color.mardCode`。
    /// 而这一屏 `cells` 里存的是 `displayCode(for: colorSystem)`（判色那步写进去的就是它）。
    /// 直接把 mardCode 写回去的话，COCO / 漫漫这些非 MARD 图纸上用户改一次色号，
    /// 就在格子里留下一个本体系查不到的码：色块变灰、自成一组、跟色号表的颗数也对不上，
    /// 而且会跟着落盘。所以这里先翻回当前体系的显示码。
    private func applyPickedCode() {
        defer { pickedCodes = [] }
        guard let picked = pickedCodes.sorted().first,
              let bead = inventoryManager.findColor(byMardCode: picked),
              bead.hasCode(for: colorSystem) else { return }
        apply(.code(bead.displayCode(for: colorSystem)))
    }
}

// MARK: - 展开看全部色号

/// 上面那条横向色号栏的展开版：一屏看全，顺便把两个数摆开写清楚。
///
/// 横着划过十几个胶囊才找得到要看的那一个，本身就难受；更要紧的是
/// 「认出来 2,887 颗 / 图纸写 3,006 颗」这组对照在胶囊里只能挤成一个斜杠，
/// 得有个地方把它说明白 —— 差得多的那几个色号就是最该重看的。
private struct PartsPaletteSheet: View {
    struct Row: Identifiable {
        let key: String
        let label: String
        let color: Color
        /// 逐格判色认出来的颗数
        let found: Int
        /// 图纸色号表里写的颗数（空白 / 任意色没有）
        let onSheet: Int?
        let isConfirmed: Bool
        let isSelected: Bool

        var id: String { key }
    }

    let rows: [Row]
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(rows) { row in
                Button { onPick(row.key) } label: {
                    HStack(spacing: Theme.Spacing.md) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(row.color)
                            .frame(width: 30, height: 30)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.label)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(Theme.ColorToken.Text.primary)
                            Text(detail(for: row))
                                .font(.caption.monospacedDigit())
                                .foregroundColor(Theme.ColorToken.Text.secondary)
                        }

                        Spacer()

                        if row.isConfirmed {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(Theme.ColorToken.Status.success)
                        }
                        if row.isSelected {
                            Image(systemName: "eye")
                                .foregroundColor(Theme.ColorToken.Morandi.mauve)
                        }
                    }
                    // 整行都能点。少了这一句，点到色块和文字之间那段空白就没反应 ——
                    // 一行里能点的地方和不能点的地方长得一模一样，最让人火大。
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("这张图纸的颜色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func detail(for row: Row) -> String {
        guard let onSheet = row.onSheet else {
            return String(localized: "认出 \(row.found) 颗")
        }
        let gap = row.found - onSheet
        if gap == 0 {
            return String(localized: "认出 \(row.found) 颗，跟图纸写的一样")
        }
        return String(localized: "认出 \(row.found) 颗，图纸写 \(onSheet) 颗（差 \(abs(gap)) 颗）")
    }
}

// MARK: - 裁好的小图存哪儿

/// 裁过的格子留一份，往回滚不用重裁。
///
/// 不是 `@State` 字典是有原因的：按需裁图会在滚动过程中一格一格往里加，
/// 每加一格都让整片格子重画的话，滚动会直接卡住。这里是个引用类型，
/// 存进来不惊动 SwiftUI。
@MainActor
private final class CellSwatchCache {
    /// 上一次裁的是哪张工作图。进这一屏先拿到的是低清兜底版，高清版在后台裁好之后
    /// 才换上来 —— 换了图不清空的话，用户看到的一直是一格十来个像素的马赛克。
    ///
    /// 靠的是「升级一定新建一个 `UIImage`」（两个流程视图的 `upgradeWorkImage` 都是
    /// `UIGraphicsImageRenderer` 重画一份）。哪天那边改成复用同一个实例，这里的 `!==`
    /// 就永远不成立，而且不会报任何错。
    ///
    /// 存强引用而不是 `ObjectIdentifier`：已释放对象的地址会被新分配复用，
    /// 那会假命中，整屏给用户看错图。
    private var source: UIImage?
    private var images: [PartsColorReviewStepView.CellRef: UIImage] = [:]

    /// 攒到这个数就**整批**扔掉重来（不是 LRU —— 屏幕上那二三十格也一起扔，下一帧原样重裁）。
    /// 这么粗暴还行得通，是因为重裁一格是 `CGImage.cropping`，不碰像素。
    /// 8000 只要够装下「滚很久也不至于爆」，具体多少不敏感。
    private static let flushThreshold = 8000

    func image(
        for ref: PartsColorReviewStepView.CellRef,
        source: UIImage,
        make: () -> UIImage?
    ) -> UIImage? {
        if self.source !== source {
            self.source = source
            images.removeAll(keepingCapacity: true)
        }
        if let hit = images[ref] { return hit }
        guard let made = make() else { return nil }
        if images.count >= Self.flushThreshold { images.removeAll(keepingCapacity: true) }
        images[ref] = made
        return made
    }
}

// MARK: - 擦 / 补哪一块

/// 要在图纸上擦 / 补格子，先得说清楚是哪一块零件。
///
/// 列表里画的是**识别出来的形状**（跟零件清单、拼豆板上是同一张画法），不是原图：
/// 用户在这一屏要找的是「哪一块认错了」，而认错的地方本来就长在这张图上。
/// 名字之外还写颗数 —— 一块本该有一百多颗、却只认出七颗的零件，一眼就看得出来。
private struct PartBrushPickerSheet: View {
    struct Row: Identifiable {
        let id: UUID
        let name: String
        let beadCount: Int
        let footprint: PartFootprint
    }

    let rows: [Row]
    let colors: [String: Color]
    let onPick: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(rows) { row in
                Button { onPick(row.id) } label: {
                    HStack(spacing: Theme.Spacing.md) {
                        PartShapeThumbnail(footprint: row.footprint, colors: colors)
                            .frame(width: 44, height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                                    .fill(Theme.ColorToken.Surface.subtle)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(Theme.ColorToken.Text.primary)
                            Text("\(row.beadCount) 颗")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(Theme.ColorToken.Text.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(Theme.ColorToken.Text.tertiary)
                    }
                    // 整行都能点。少了这一句，点到图和字之间那段空白就没反应。
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("改哪一块的格子")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 格子在屏幕上的位置

/// 格子那一片的左上角跑到屏幕哪儿了。手指是屏幕坐标、选框是内容坐标，靠它换算（见 `cellGrid`）。
private struct GridOriginKey: PreferenceKey {
    /// **必须是 Optional。** 没设过这个 preference 的兄弟节点会拿默认值一起参与合并，
    /// 写成 `CGPoint.zero` 的话，真值会被它们盖回 (0, 0) —— 手指和格子从此对不上号。
    static let defaultValue: CGPoint? = nil
    static func reduce(value: inout CGPoint?, nextValue: () -> CGPoint?) {
        value = nextValue() ?? value
    }
}

/// 框选要知道每一格现在画在哪儿。只在框选模式下收集（见 `cellGrid`）。
private struct CellFramesKey: PreferenceKey {
    static let defaultValue: [PartsColorReviewStepView.CellRef: CGRect] = [:]
    static func reduce(
        value: inout [PartsColorReviewStepView.CellRef: CGRect],
        nextValue: () -> [PartsColorReviewStepView.CellRef: CGRect]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - 一格

private struct CellSwatch: View {
    let image: UIImage?
    let isSelected: Bool

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    // 像素画放大用最近邻，插值会把边缘糊掉，反而看不出这格是不是压在两颗豆之间
                    .interpolation(.none)
                    .scaledToFill()
            } else {
                Theme.ColorToken.Surface.subtle
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        // 选中的那一圈同样压在图纸颜色上（理由见框选那一层）：单描边总有撞色的时候，
        // 一格藕紫色豆子套一圈莫兰迪紫，选没选中根本看不出来。这里也是深芯 + 白包边，
        // 彩色那道仍是原来的 3 点（浅色豆子上白边会隐进去，全靠它），外面再包 1 点白；
        // 一共往外撑 2.5 点，比格子之间那 6 点间距窄，不会跟旁边那格粘上。
        .overlay {
            let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
            if isSelected {
                shape.stroke(Color.white, lineWidth: 5)
                    .overlay(shape.stroke(Theme.ColorToken.Morandi.mauve, lineWidth: 3))
            } else {
                shape.stroke(Theme.ColorToken.Border.divider, lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
    }
}
