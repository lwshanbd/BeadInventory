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
    /// 存下来的代价是得手动刷，而且只有两条路：换色号走 `select`，改格子走 `apply`。
    /// 漏一条不会崩也不会报错 —— `cellRect` 是纯几何算的，只会安静地给用户看一张对不上的小图。
    @State private var groupCells: [CellRef]?
    /// 露头才裁的小图缓存（见 `CellSwatchCache`）
    @State private var swatchCache = CellSwatchCache()
    @State private var showingCodePicker = false
    @State private var pickedCodes: Set<String> = []
    /// 已经核对过的色号（按 groupKey）。只是给用户记进度用，不影响数据。
    @State private var confirmed: Set<String> = []
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
    /// 排不动时说一句。**不能什么都不说**：点了「排序」没有任何反应，用户只会以为按钮坏了。
    @State private var sortNote: String?

    /// 框选模式。开着时列表不滚动，拖一条对角线就把扫过的格子全选上。
    /// 一个色号动不动上千格，一格一格点是不可能的。
    @State private var marquee = false
    /// 正在拖的那个选框（全局坐标）
    @State private var marqueeRect: CGRect?
    /// 这一次拖动开始前已经选中的，用来支持「框好几片」
    @State private var marqueeBase: Set<CellRef> = []
    /// 屏幕上每一格的位置（全局坐标）。只在框选模式下收集 ——
    /// 平时收集会让每一帧滚动都重算几百条 preference。
    @State private var cellFrames: [CellRef: CGRect] = [:]

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

    private let columns = [GridItem(.adaptive(minimum: 34), spacing: 6)]

    var body: some View {
        VStack(spacing: 0) {
            groupBar
            Divider()
            if sortByColor { sortHint }
            if let sortNote { noteBar(sortNote) }
            cellGrid
            footer
        }
        .overlay { if samplingColors { samplingOverlay } }
        .onDisappear {
            samplingTask?.cancel()
            samplingTask = nil
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
                    // 铺出来的那一片是**存下来的**（`groupCells`），擦 / 补完必须自己刷 ——
                    // 擦掉的格子不刷就还留在这一组里，补上的格子进不来。
                    // 小图缓存不用动：那是按 `CellRef` 从图纸上裁的，格子改成什么颜色跟它
                    // 无关，新进这一组的那几格会自己按需裁（见 `swatch(for:)`）。
                    groupCells = orderedCells(of: selectedGroup)
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
        marquee = false
        groupCells = orderedCells(of: fill)
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

    /// 排不动的时候说一句。用户点了「排序」，屏幕上必须有个交代。
    private func noteBar(_ text: String) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
            Text(text)
            Spacer(minLength: 0)
            Button("知道了") { sortNote = nil }
        }
        .font(.caption)
        .foregroundStyle(Theme.ColorToken.Status.warning)
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

    private var cellGrid: some View {
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
                                                               value: [ref: geo.frame(in: .global)])
                                    }
                                }
                            }
                            .onTapGesture {
                                if selection.contains(ref) { selection.remove(ref) } else { selection.insert(ref) }
                            }
                        }
                    }
                    .padding(Theme.Spacing.lg)
                }
            }
        }
        .scrollDisabled(marquee)
        .onPreferenceChange(CellFramesKey.self) { cellFrames = $0 }
        .overlay { if marquee { marqueeLayer } }
    }

    /// 框选那一层。盖在格子上面自己收手势 —— 全部用全局坐标，
    /// 免得再去换算列表滚到哪儿了。
    private var marqueeLayer: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())

                if let rect = marqueeRect {
                    Rectangle()
                        .fill(Theme.ColorToken.Morandi.mauve.opacity(0.18))
                        .overlay(Rectangle().stroke(Theme.ColorToken.Morandi.mauve, lineWidth: 1.5))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX - origin.x, y: rect.midY - origin.y)
                        .allowsHitTesting(false)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { value in
                        if marqueeRect == nil { marqueeBase = selection }
                        let rect = CGRect(corner: value.startLocation, to: value.location)
                        marqueeRect = rect
                        selection = marqueeBase.union(
                            cellFrames.filter { $0.value.intersects(rect) }.keys
                        )
                    }
                    .onEnded { _ in marqueeRect = nil }
            )
            .simultaneousGesture(
                // 框选模式下单点也要能加减一格，不然想补一格还得先退出去
                SpatialTapGesture(coordinateSpace: .global).onEnded { value in
                    guard let hit = cellFrames.first(where: { $0.value.contains(value.location) })?.key
                    else { return }
                    if selection.contains(hit) { selection.remove(hit) } else { selection.insert(hit) }
                }
            )
        }
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
                    marqueeRect = nil
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

            Button(action: onFinish) {
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
            sortNote = nil
            groupCells = cells(of: selectedGroup)
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
                    sortNote = String(localized: "取不到图纸上的颜色，排不了序。回去看看零件的框是不是圈得太小。")
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
            sortNote = String(localized: "这一片的原图取不到，排不了序。")
            return
        }
        sortByColor = true
        sortNote = nil
        groupCells = ordered
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
        for ref in selection {
            guard ref.part < updated.count,
                  ref.row < updated[ref.part].cells.count,
                  ref.col < updated[ref.part].cells[ref.row].count else { continue }
            updated[ref.part].cells[ref.row][ref.col] = fill
        }
        parts = updated
        selection.removeAll()
        // 改过的格子已经不属于当前这一组了，铺出来的那片要跟着少掉
        groupCells = orderedCells(of: selectedGroup)
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
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(isSelected ? Theme.ColorToken.Morandi.mauve : Theme.ColorToken.Border.divider,
                        lineWidth: isSelected ? 3 : 1)
        )
        .contentShape(Rectangle())
    }
}
