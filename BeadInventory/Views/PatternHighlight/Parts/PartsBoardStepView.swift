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
//  ## 摆放的唯一硬规矩：零件之间空一格
//
//  烫的时候挨着的豆子会连成一片，所以两个零件的豆子之间至少隔一格
//  （见 BeadPartsBoard.swift）。拖到不该去的地方，那个零件会变红、松手弹回原位 ——
//  不是弹一下就完，底下会写清楚为什么。
//
//  ## 高亮
//
//  拼的时候是一个颜色一个颜色抓豆子放的，不是一格一格看图纸的。所以下面那排颜色
//  点一下，板上就只剩这个色号是亮的，其余全部压成灰 —— 眼睛直接扫得出来该往哪儿放。
//

import SwiftUI

struct PartsBoardStepView: View {
    let parts: [BeadPart]
    @Binding var boards: [PartsBoard]
    let colorSystem: ColorSystem
    let onFinish: () -> Void

    @EnvironmentObject var inventoryManager: InventoryManager

    /// 上次用的板子尺寸。同一个人手上的板子基本不会换，记着就不用每次重选。
    @AppStorage("partsBoardCols") private var savedCols = 50
    @AppStorage("partsBoardRows") private var savedRows = 50

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

    @State private var note: String?
    @State private var noteToken = UUID()
    @State private var repackTarget: BeadBoardSize?
    @State private var didAutoPack = false

    private enum Tab: Hashable { case parts, colors }

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
        .navigationTitle("摆到拼豆板")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { boardMenu }
        }
        .task {
            colorCache = makeColorCache()
            autoPackIfNeeded()
        }
        .task(id: shapeSignature) { footprints = makeFootprints() }
        // 接了电视 / 投影仪的话，把当前这块板送过去（没接就没人读，见 BoardCastSession）。
        // 拖动过程中的临时状态不送 —— 外屏是给人抬头看「板子现在长什么样」的，
        // 跟着手指抖没有意义。
        .onChange(of: castSignature) { _, _ in publishToExternalDisplay() }
        .onAppear { publishToExternalDisplay() }
        .onDisappear { BoardCastSession.shared.stop() }
        .task(id: noteToken) {
            guard note != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { note = nil }
        }
        .alert("重新排一遍？", isPresented: Binding(
            get: { repackTarget != nil },
            set: { if !$0 { repackTarget = nil } }
        )) {
            Button("取消", role: .cancel) { repackTarget = nil }
            Button("重新排", role: .destructive) { repackAll() }
        } message: {
            Text("会按 \(repackTarget?.label ?? "") 的板子重新摆一遍，你手动挪过的位置就没了。")
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
                        ForEach(BeadBoardSize.presets) { size in
                            Button(size.label) { addBoard(size: size) }
                        }
                    } label: {
                        Label("加一块", systemImage: "plus")
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.sm)
                            .background(Capsule().fill(Theme.ColorToken.Surface.elevated))
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
            }

            if let board = currentBoard {
                Text("\(board.size.label) · 摆了 \(board.placements.count) 个零件 · \(beadCount(of: board)) 颗豆子")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(Theme.ColorToken.Text.secondary)
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
            Section("全部重排成") {
                ForEach(BeadBoardSize.presets) { size in
                    Button(size.label) { repackTarget = size }
                }
            }
            if let board = currentBoard, !board.placements.isEmpty {
                Button("把这块板清空", role: .destructive) { clearCurrentBoard() }
            }
            if boards.count > 1, currentBoard?.placements.isEmpty == true {
                Button("删掉这块空板", role: .destructive) { removeCurrentBoard() }
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
                        description: Text("上面「加一块」挑一个尺寸。")
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

    private var bottomPanel: some View {
        VStack(spacing: Theme.Spacing.md) {
            if let id = selection, let placement = currentBoard?.placements.first(where: { $0.id == id }) {
                selectedActions(placement)
            }

            Picker("", selection: $tab) {
                Text("零件").tag(Tab.parts)
                Text("颜色").tag(Tab.colors)
            }
            .pickerStyle(.segmented)

            switch tab {
            case .parts: partsTray
            case .colors: colorTray
            }

            Button(action: onFinish) {
                Label("完成", systemImage: "checkmark").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.regularMaterial)
    }

    private func selectedActions(_ placement: PartPlacement) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(name(of: placement.partId))
                .font(.footnote.weight(.medium))
                .foregroundColor(Theme.ColorToken.Text.primary)
                .lineLimit(1)

            Spacer(minLength: Theme.Spacing.sm)

            Button { rotateSelected() } label: {
                Label("转 90°", systemImage: "rotate.right")
            }
            .buttonStyle(.bordered)

            Button(role: .destructive) { takeOffSelected() } label: {
                Label("拿下来", systemImage: "arrow.down.left")
            }
            .buttonStyle(.bordered)
        }
        .font(.footnote)
        .lineLimit(1)
    }

    /// 还没摆上板的零件。点一下就落到当前这块板上 ——
    /// 从这么小一个缩略图一路拖到放大了的板上，手指中途一抖就得重来。
    /// 落位之后再拖着挪，起手点是板上那个实实在在的零件。
    private var partsTray: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text(unplaced.isEmpty
                     ? "零件都摆上去了"
                     : "还有 \(unplaced.count) 个没摆")
                    .font(.footnote)
                    .foregroundColor(Theme.ColorToken.Text.secondary)
                Spacer()
                if !unplaced.isEmpty {
                    Button { fillRemaining() } label: {
                        Label("自动排", systemImage: "square.grid.3x3.fill")
                            .font(.footnote.weight(.medium))
                    }
                }
            }

            if unplaced.isEmpty {
                Text("拼完这块板可以在上面切到下一块。")
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
            PartShapeThumbnail(footprint: footprint, colors: colorCache)
                .frame(width: 48, height: 48)
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

    /// 这块板上用到的颜色。点一下只剩它是亮的 —— 抓一把 H7 的时候，
    /// 眼睛要的是「哪几个坑」，不是「这一格是什么色号」。
    private var colorTray: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(highlightKey.map { "只亮着「\(label(for: $0))」，再点一下取消" }
                 ?? "点一个颜色，板上只留它是亮的")
                .font(.footnote)
                .foregroundColor(Theme.ColorToken.Text.secondary)

            if boardColors.isEmpty {
                Text("这块板还什么都没摆。")
                    .font(.caption)
                    .foregroundColor(Theme.ColorToken.Text.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 76)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.sm) {
                        ForEach(boardColors, id: \.key) { entry in
                            Button {
                                highlightKey = highlightKey == entry.key ? nil : entry.key
                            } label: {
                                colorChip(key: entry.key, count: entry.count)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(height: 76)
            }
        }
    }

    private func colorChip(key: String, count: Int) -> some View {
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
            Text(label(for: key))
                .font(.caption2.weight(.medium))
                .foregroundColor(Theme.ColorToken.Text.primary)
                .lineLimit(1)
            Text("\(count) 颗")
                .font(.caption2.monospacedDigit())
                .foregroundColor(Theme.ColorToken.Text.secondary)
        }
        .frame(width: 56)
        .contentShape(Rectangle())
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

    private var boardColors: [(key: String, count: Int)] {
        guard let board = currentBoard else { return [] }
        var counts: [String: Int] = [:]
        for placement in board.placements {
            guard let footprint = footprints[placement.id] else { continue }
            for bead in footprint.beads { counts[bead.key, default: 0] += 1 }
        }
        return counts.map { (key: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
    }

    private func label(for key: String) -> String {
        key == "#any" ? String(localized: "任意色") : key
    }

    /// 形状缓存的失效条件：只跟「哪个零件、转了几次」有关。
    /// 位置故意不算进来 —— 拖动时每挪一格都重算一遍所有零件的形状，会直接卡住。
    private var shapeSignature: String {
        boards.flatMap { board in
            board.placements.map { "\($0.id)|\($0.partId)|\($0.turns)" }
        }.joined(separator: ",")
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
        let packed = PartsBoardPacker.pack(parts: parts.filter(\.hasCells), size: size)
        boards = packed.boards
        boardIndex = 0
        if !packed.unplaced.isEmpty {
            flash(String(localized: "有 \(packed.unplaced.count) 个零件比板子还大，换块大的试试"))
        }
    }

    private func repackAll() {
        guard let size = repackTarget else { return }
        repackTarget = nil
        savedCols = size.cols
        savedRows = size.rows
        let packed = PartsBoardPacker.pack(parts: parts.filter(\.hasCells), size: size)
        boards = packed.boards
        boardIndex = 0
        selection = nil
        resetView()
        flash(packed.unplaced.isEmpty
              ? String(localized: "排好了，一共 \(packed.boards.count) 块板")
              : String(localized: "有 \(packed.unplaced.count) 个零件比板子还大，换块大的试试"))
    }

    /// 把还没摆的零件接着往板上放：先塞现有的板，塞不下再开新的。
    private func fillRemaining() {
        let size = currentBoard?.size ?? BeadBoardSize(cols: savedCols, rows: savedRows)
        var occupancies = boards.map { PartsBoardPacker.occupancy(of: $0, parts: parts) }
        var added = 0

        // 摆放规矩（先大后小、先原方向后转 90°、先塞现有板再开新板）全在 packer 里，
        // 跟进屏自动排走的是同一条路
        for item in PartsBoardPacker.ordered(unplaced) {
            if PartsBoardPacker.placeOne(item.part, footprint: item.footprint,
                                         into: &boards, occupancies: &occupancies, size: size) != nil {
                added += 1
            }
        }

        flash(added > 0
              ? String(localized: "又摆上去 \(added) 个")
              : String(localized: "这些零件比板子还大，摆不进去"))
    }

    /// 点了零件条里的一个零件：落到当前这块板上；这块满了就新开一块并切过去。
    private func place(_ part: BeadPart) {
        // 这里只认**当前这块板**（用户点的时候看着的就是它），所以不走 packer 的
        // placeOne（那个会挨块板试过去）；「怎么摆」的规矩还是共用 packer 那一份。
        let options = PartsBoardPacker.candidates(for: part)

        if let board = currentBoard,
           let hit = PartsBoardPacker.fit(options, in: PartsBoardPacker.occupancy(of: board, parts: parts)) {
            let placement = PartPlacement(
                partId: part.id, col: hit.col, row: hit.row, turns: hit.candidate.turns
            )
            boards[boardIndex].placements.append(placement)
            selection = placement.id
            return
        }

        let size = currentBoard?.size ?? BeadBoardSize(cols: savedCols, rows: savedRows)
        guard let hit = PartsBoardPacker.fit(options, in: BoardOccupancy(cols: size.cols, rows: size.rows)) else {
            flash(String(localized: "这个零件比板子还大，换块大的试试"))
            return
        }
        var board = PartsBoard(size: size)
        let placement = PartPlacement(
            partId: part.id, col: hit.col, row: hit.row, turns: hit.candidate.turns
        )
        board.placements.append(placement)
        boards.append(board)
        switchTo(boards.count - 1)
        selection = placement.id
        flash(String(localized: "这块板放不下了，新开了一块"))
    }

    private func addBoard(size: BeadBoardSize) {
        savedCols = size.cols
        savedRows = size.rows
        boards.append(PartsBoard(size: size))
        switchTo(boards.count - 1)
    }

    private func switchTo(_ index: Int) {
        guard boards.indices.contains(index) else { return }
        boardIndex = index
        selection = nil
        resetView()
    }

    private func clearCurrentBoard() {
        guard boards.indices.contains(boardIndex) else { return }
        boards[boardIndex].placements = []
        selection = nil
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

        let occupancy = PartsBoardPacker.occupancy(of: boards[boardIndex], parts: parts, ignoring: id)
        if occupancy.canPlace(newFootprint, col: col, row: row) {
            boards[boardIndex].placements[index] = PartPlacement(
                id: id, partId: old.partId, col: col, row: row, turns: newTurns
            )
        } else if let spot = PartsBoardPacker.firstFit(newFootprint, occupancy: occupancy) {
            boards[boardIndex].placements[index] = PartPlacement(
                id: id, partId: old.partId, col: spot.col, row: spot.row, turns: newTurns
            )
            flash(String(localized: "原地转不开，挪到旁边空地了"))
        } else {
            flash(String(localized: "转过来就放不下了，先挪开点别的"))
        }
    }

    private func takeOffSelected() {
        guard let id = selection, boards.indices.contains(boardIndex) else { return }
        boards[boardIndex].placements.removeAll { $0.id == id }
        selection = nil
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
        session.occupancy = PartsBoardPacker.occupancy(of: board, parts: parts, ignoring: hit.id)
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
            flash(String(localized: "这儿放不下：零件之间要空一格，烫的时候才不会粘住"))
            return
        }
        guard let index = boards[boardIndex].placements.firstIndex(where: { $0.id == id }) else { return }
        boards[boardIndex].placements[index].col = session.originCol + session.deltaCol
        boards[boardIndex].placements[index].row = session.originRow + session.deltaRow
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

    /// 送到外屏的东西变了没有。板子换了、零件形状变了、高亮换了色号才要重送。
    private var castSignature: String {
        "\(boardIndex)|\(boards.count)|\(highlightKey ?? "")|\(shapeSignature)|\(colorCache.count)"
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
            highlightKey: highlightKey,
            boardIndex: boardIndex,
            boardCount: boards.count
        ))
    }

    /// 这一屏当前要画的东西。板子的画法在 `BoardCanvas.swift`，跟外接屏幕共用一份。
    private func renderer(for board: PartsBoard) -> BoardCanvasRenderer {
        BoardCanvasRenderer(
            board: board,
            footprints: footprints,
            colorCache: colorCache,
            highlightKey: highlightKey,
            selection: selection,
            moving: drag.map {
                .init(placement: $0.placement, deltaCol: $0.deltaCol,
                      deltaRow: $0.deltaRow, valid: $0.valid)
            }
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
    /// 板子多半跟画布不是一个比例（50×52 这种长条最明显），放大 10 倍之后
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
private struct PartShapeThumbnail: View {
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
