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
    let onFinish: () -> Void

    @EnvironmentObject var inventoryManager: InventoryManager

    @State private var selectedGroup: PartCellFill = .empty
    @State private var selection: Set<CellRef> = []
    @State private var swatches: [CellRef: UIImage] = [:]
    @State private var showingCodePicker = false
    @State private var pickedCodes: Set<String> = []

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
    }

    // MARK: - 上：色号一排

    private var groupBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(groups, id: \.key) { group in
                    Button {
                        selectedGroup = group.fill
                        selection.removeAll()
                    } label: {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(color(for: group.fill))
                                .frame(width: 16, height: 16)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
                                )
                            Text(label(for: group.fill))
                                .font(.footnote.weight(.medium))
                            Text("\(group.count) 颗")
                                .font(.caption2.monospacedDigit())
                                .foregroundColor(Theme.ColorToken.Text.secondary)
                        }
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.sm)
                        .background(
                            Capsule().fill(
                                groupKey(group.fill) == groupKey(selectedGroup)
                                    ? Theme.ColorToken.Morandi.mauve.opacity(0.22)
                                    : Theme.ColorToken.Surface.elevated
                            )
                        )
                        .overlay(
                            Capsule().stroke(
                                groupKey(group.fill) == groupKey(selectedGroup)
                                    ? Theme.ColorToken.Morandi.mauve
                                    : Color.clear,
                                lineWidth: 1.5
                            )
                        )
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.ColorToken.Text.primary)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
        }
        .background(Theme.ColorToken.Surface.background)
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
                    Text("有不对的点一下")
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

    /// 按颗数从多到少。**空不列在这里** —— 零件轮廓外面、矩形四角、中间镂空
    /// 全是空格，数量比任何一个色号都大，但它不是一种要买要放的豆子，
    /// 摆进来只会把真正要核对的色号挤到后面去。
    /// 某一片本来有豆子却被判成空时，从它现在所在的那个色号里选中改回来即可。
    private var groups: [Group] {
        var counts: [String: (fill: PartCellFill, count: Int)] = [:]
        for part in parts {
            for row in part.cells {
                for cell in row where cell != .empty {
                    let key = groupKey(cell)
                    counts[key, default: (cell, 0)].count += 1
                }
            }
        }
        return counts
            .map { Group(fill: $0.value.fill, count: $0.value.count, key: $0.key) }
            .sorted { $0.count > $1.count }
    }

    /// 图纸上一共要放多少颗豆子（空格不算）
    private var totalBeads: Int {
        groups.reduce(0) { $0 + $1.count }
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
