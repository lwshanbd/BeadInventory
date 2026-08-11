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
                        .onTapGesture {
                            if selection.contains(ref) { selection.remove(ref) } else { selection.insert(ref) }
                        }
                    }
                }
                .padding(Theme.Spacing.lg)
            }
        }
    }

    // MARK: - 下：操作

    private var footer: some View {
        VStack(spacing: Theme.Spacing.md) {
            if selection.isEmpty {
                Text("这里是被判成「\(label(for: selectedGroup))」的所有格子。有不对的就点中它，可以多选。")
                    .font(.footnote)
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                // 整类一起改。图纸上那种「整片白其实是镂空、不是豆子」的情况，
                // 一格一格点几百下不现实，得能一次说清楚。
                HStack(spacing: Theme.Spacing.sm) {
                    Button {
                        selectWholeGroup()
                        pickedCodes = []
                        showingCodePicker = true
                    } label: {
                        Label("这类都改成…", systemImage: "paintpalette").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        selectWholeGroup()
                        apply(.anyColor)
                    } label: {
                        Label("这类是任意色", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        selectWholeGroup()
                        apply(.empty)
                    } label: {
                        Label("这类没有豆子", systemImage: "square.dashed").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .font(.footnote)
                .lineLimit(1)
            } else {
                HStack {
                    Text("已选 \(selection.count) 格")
                        .font(.footnote)
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                    Spacer()
                    Button("取消选择") { selection.removeAll() }
                        .font(.footnote)
                }
                HStack(spacing: Theme.Spacing.sm) {
                    Button {
                        pickedCodes = []
                        showingCodePicker = true
                    } label: {
                        Label("改成别的色号", systemImage: "paintpalette").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        apply(.anyColor)
                    } label: {
                        Label("任意色", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        apply(.empty)
                    } label: {
                        Label("设为空", systemImage: "square.dashed").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .font(.footnote)
                .lineLimit(1)
            }

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

    private func color(for fill: PartCellFill) -> Color {
        switch fill {
        case .empty: return Theme.ColorToken.Surface.subtle
        case .anyColor: return Theme.ColorToken.Morandi.mauve
        case .code(let code):
            guard let bead = inventoryManager.findColor(byCode: code, preferSystem: colorSystem) else {
                return Theme.ColorToken.Surface.subtle
            }
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
        // 一次最多抠 1500 个，再多用户也不会一个个看，先让界面出来
        let capped = Array(refs.prefix(1500))
        let built = await Task.detached(priority: .userInitiated) { () -> [CellRef: UIImage] in
            var result: [CellRef: UIImage] = [:]
            for ref in capped {
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
