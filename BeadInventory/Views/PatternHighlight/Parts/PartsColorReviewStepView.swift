//
//  PartsColorReviewStepView.swift
//  BeadInventory
//
//  多零件模式 · 第 ④ 屏 - 校色
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
    let onFinish: () -> Void

    @EnvironmentObject var inventoryManager: InventoryManager

    @State private var selectedGroup: PartCellFill = .empty
    @State private var selection: Set<CellRef> = []
    @State private var swatches: [CellRef: UIImage] = [:]
    @State private var showingCodePicker = false
    @State private var pickedCodes: Set<String> = []
    /// 已经核对过的色号（按 groupKey）。只是给用户记进度用，不影响数据。
    @State private var confirmed: Set<String> = []
    @State private var showingPalette = false

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
            cellGrid
            footer
        }
        .navigationTitle("核对颜色")
        .navigationBarTitleDisplayMode(.inline)
        .task { selectDefaultGroup() }
        .task(id: groupKey(selectedGroup)) { await loadSwatches() }
        .sheet(isPresented: $showingCodePicker, onDismiss: applyPickedCode) {
            ColorSelectionView(selectedColors: $pickedCodes, colorSystem: colorSystem)
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
            return "\(group.count) / \(onSheet) 颗"
        }
        return "\(group.count) 颗"
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
    }

    // MARK: - 中：这个色号的所有格子

    private var cellGrid: some View {
        ScrollView {
            let refs = cells(of: selectedGroup)
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
                            image: swatches[ref],
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
                } else {
                    Text("已选 \(selection.count) 格")
                        .font(.footnote)
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                    Button("取消选择") { selection.removeAll() }
                        .font(.footnote)
                }
                Spacer()
                Button {
                    marquee.toggle()
                    marqueeRect = nil
                    if !marquee { cellFrames = [:] }
                } label: {
                    Label(marquee ? "选完了" : "拖着框选",
                          systemImage: marquee ? "checkmark" : "rectangle.dashed")
                        .font(.footnote.weight(.medium))
                }
            }

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

                Button {
                    if selection.isEmpty { selectWholeGroup() }
                    apply(.anyColor)
                } label: {
                    Label(selection.isEmpty ? "这类是任意色" : "任意色", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

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
                Label("完成 · 一共 \(totalBeads) 颗", systemImage: "checkmark").frame(maxWidth: .infinity)
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
        if let next = unconfirmed.first {
            select(next.fill)
        }
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
        if let first = groups.first { selectedGroup = first.fill }
    }

    // MARK: - 抠格子

    /// 把当前这一组的格子从图纸上原样抠出来。
    /// 用真实像素而不是画一个平均色的方块 —— 平均色是算法自己的结论，
    /// 拿它给用户看等于让算法自证清白；原图才能露出「这格其实压在两颗豆子之间」这种错。
    private func loadSwatches() async {
        let refs = cells(of: selectedGroup)
        let snapshot = parts
        let source = work
        // 这一组有多少格就抠多少格。
        //
        // 这里曾经封顶 1500 个，理由是「再多用户也不会一个个看」—— 结果 H7 有 2901 格，
        // 第 1501 格往后全是灰底空方块，用户看到的是「一大堆不知道为什么存在的空白格」，
        // 而且那些格子还照样能被选中、被改。抠一格只是对已解码的大图取个子矩形，
        // 几千次也是毫秒级，本来就不值得为它牺牲正确性。
        let built = await Task.detached(priority: .userInitiated) { () -> [CellRef: UIImage] in
            var result: [CellRef: UIImage] = [:]
            for ref in refs {
                guard ref.part < snapshot.count else { continue }
                let rect = snapshot[ref.part].cellRect(row: ref.row, col: ref.col)
                if let cropped = PartsThumbnailMaker.crop(source, normalized: rect) {
                    result[ref] = cropped
                }
            }
            return result
        }.value
        swatches = built
    }

    // MARK: - 改

    private func selectWholeGroup() {
        selection = Set(cells(of: selectedGroup))
    }

    private func apply(_ fill: PartCellFill) {
        for ref in selection {
            guard ref.part < parts.count,
                  ref.row < parts[ref.part].cells.count,
                  ref.col < parts[ref.part].cells[ref.row].count else { continue }
            parts[ref.part].cells[ref.row][ref.col] = fill
        }
        selection.removeAll()
    }

    private func applyPickedCode() {
        guard let code = pickedCodes.sorted().first else { return }
        apply(.code(code))
        pickedCodes = []
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
