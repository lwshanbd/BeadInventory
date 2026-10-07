//
//  PartsAssemblyStepView.swift
//  BeadInventory
//
//  多零件模式 · 组装（最后一屏；整条流程的屏序见 PartsSheetFlowView 的头注释）
//
//  板子都拼完、烫完了，桌上摊着几块板，零件还嵌在板上。这时候用户是照着图纸粘：
//  图纸上看到「下一块该粘这个」，然后要去几块板上把它找出来。
//
//  零件一上板就跟图纸长得不一样了（可能转过、翻过，挨着一堆别的零件），
//  几十个零件里靠形状认，认错一块就粘错一块。所以这一屏只回答一个问题：
//  **图纸上这一块，现在在哪块板的哪个位置。**
//
//  点图纸上的零件 → 下面画出它所在的那块板，它自己亮着，同板别的零件压成灰当参照。
//  一个零件拼了两份、分在两块板上，就画两块。
//
//  粘好的勾掉，图纸上那块跟着变灰打勾。几十个零件要粘好几个晚上，
//  下次进来得一眼看出还剩哪些（存在 `BeadPartsSheet.assembledPartIds`）。
//

import SwiftUI

struct PartsAssemblyStepView: View {
    /// 只读：组装这一步不改零件本身
    let parts: [BeadPart]
    let pages: PartsPages
    let boards: [PartsBoard]
    @Binding var assembled: Set<UUID>
    let colorSystem: ColorSystem
    /// 勾一下就存。粘了一晚上，切出去回个消息被系统杀掉，勾过的不能丢。
    let onPersist: () -> Void
    let onFinish: () -> Void

    @EnvironmentObject var inventoryManager: InventoryManager

    @State private var page = 0
    @State private var selection: UUID?
    /// 这一张图纸上有零件的那一块，裁出来摆着。整张图上下往往还有色号表和成品图，
    /// 那些组装时用不上，留着只会把零件挤小。
    @State private var pageImage: UIImage?
    /// `pageImage` 实际对应整张图纸的哪一块（归一化）
    @State private var pageImageRegion: CGRect = .zero
    @State private var colorCache: [String: Color] = [:]

    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var lastPan: CGSize = .zero
    @State private var pinchContentAnchor: CGPoint?
    @State private var pinchScreenPoint: CGPoint = .zero

    var body: some View {
        VStack(spacing: 0) {
            if pages.count > 1 {
                PartsPagePicker(count: pages.count, selection: $page)
            }
            sheetCanvas
            Divider()
            bottomCard
        }
        .navigationTitle("组装")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { DispatchQueue.main.async { onFinish() } }
            }
        }
        .onChange(of: page) { _, _ in
            selection = nil
            zoom = 1; lastZoom = 1
            pan = .zero; lastPan = .zero
        }
        .task { colorCache = makeColorCache() }
        .task(id: page) { await loadPageImage() }
    }

    // MARK: - 图纸

    /// 零件 id → 清单里排第几（1-based），跟零件清单、拼豆板上写的号是同一个
    private var partOrder: [UUID: Int] {
        Dictionary(uniqueKeysWithValues: parts.enumerated().map { ($1.id, $0 + 1) })
    }

    /// 这一张图纸上零件所在的那一块，四周留一点边
    private var partsRegion: CGRect {
        let onPage = parts.filter { $0.pageIndex == page }
        guard var union = onPage.first?.bounds else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        for part in onPage.dropFirst() { union = union.union(part.bounds) }
        let pad = max(union.width, union.height) * 0.03
        return union.insetBy(dx: -pad, dy: -pad)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func loadPageImage() async {
        let region = partsRegion
        let work = pages[page]
        let cropped = await Task.detached(priority: .userInitiated) {
            work.flatMap { PartsThumbnailMaker.cropExact($0, normalized: region) }
        }.value
        guard !Task.isCancelled else { return }
        pageImage = cropped?.image
        pageImageRegion = cropped?.rect ?? region
    }

    private var sheetCanvas: some View {
        GeometryReader { geo in
            let region = pageImageRegion.width > 0 && pageImageRegion.height > 0
                ? pageImageRegion : partsRegion
            // 没图（本机没有这张的原图）时照样画框，框也照样能点 —— 位置信息不靠图
            let display = PartsRegionStepView.aspectFitRect(
                imageSize: pageImage?.size ?? CGSize(width: region.width, height: region.height),
                in: geo.size
            )
            let transform = PartsCanvasTransform(region: region, display: display,
                                                 size: geo.size, zoom: zoom, pan: pan)
            ZStack(alignment: .topLeading) {
                if let pageImage {
                    // 按最终尺寸摆图，不用 scaleEffect（理由同零件清单那屏）
                    let box = transform.screenRect(region)
                    Image(uiImage: pageImage)
                        .resizable()
                        .interpolation(box.width >= pageImage.size.width ? .none : .high)
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)
                }
                AssemblyBoxOverlay(parts: parts, page: page, selection: selection,
                                   assembled: assembled, transform: transform)
                gestureCatcher(in: geo.size, transform: transform)
            }
            .simultaneousGesture(pinchGesture(in: geo.size))
        }
        .background(Theme.ColorToken.Surface.subtle)
        // 图按放大后的尺寸摆，会伸出画布；`.clipped()` 只裁画面不裁点按，
        // 不加 contentShape 的话伸出去那截会盖住上面的翻页条
        .clipped()
        .contentShape(Rectangle())
    }

    private func gestureCatcher(in size: CGSize, transform: PartsCanvasTransform) -> some View {
        // 点选和拖动并进同一个 SimultaneousGesture，分开挂的话拖动会吃掉点按
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                SimultaneousGesture(
                    SpatialTapGesture()
                        .onEnded { value in select(atNormalized: transform.normalized(value.location)) },
                    DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            pan = clampPan(CGSize(
                                width: lastPan.width + value.translation.width,
                                height: lastPan.height + value.translation.height
                            ), in: size)
                        }
                        .onEnded { _ in lastPan = pan }
                )
            )
    }

    private func pinchGesture(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchContentAnchor == nil {
                    pinchScreenPoint = value.startLocation
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    pinchContentAnchor = CGPoint(
                        x: center.x + (value.startLocation.x - pan.width - center.x) / zoom,
                        y: center.y + (value.startLocation.y - pan.height - center.y) / zoom
                    )
                }
                guard let anchor = pinchContentAnchor else { return }
                zoom = max(1, min(8, lastZoom * value.magnification))
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                pan = clampPan(CGSize(
                    width: pinchScreenPoint.x - center.x - (anchor.x - center.x) * zoom,
                    height: pinchScreenPoint.y - center.y - (anchor.y - center.y) * zoom
                ), in: size)
            }
            .onEnded { _ in
                lastZoom = zoom
                lastPan = pan
                pinchContentAnchor = nil
            }
    }

    private func clampPan(_ offset: CGSize, in size: CGSize) -> CGSize {
        let limitX = max(0, (zoom - 1) * size.width / 2)
        let limitY = max(0, (zoom - 1) * size.height / 2)
        return CGSize(width: min(max(offset.width, -limitX), limitX),
                      height: min(max(offset.height, -limitY), limitY))
    }

    /// 点在零件上就选它（再点一次取消），点空白处取消选中
    private func select(atNormalized n: CGPoint) {
        // 框互相重叠时取面积最小的，用户点的多半是压在上面的小零件
        let hit = parts
            .filter { $0.pageIndex == page && $0.bounds.contains(n) }
            .min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
        selection = (hit?.id == selection) ? nil : hit?.id
    }

    // MARK: - 下：在哪块板上

    @ViewBuilder
    private var bottomCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if let id = selection, let part = parts.first(where: { $0.id == id }) {
                selectedCard(part)
            } else {
                summary
            }
        }
        .padding()
        // 高度固定：选没选零件都一样高。跟着内容变的话，一点零件上面的图纸就被压小一截，
        // 连着点几块，手指要找的那块每次都挪了位置
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(height: 340)
        .background(.regularMaterial)
    }

    /// 没选零件时：还剩多少没粘
    private var summary: some View {
        let total = parts.filter { $0.beadCount > 0 }
        let done = total.filter { assembled.contains($0.id) }.count
        return VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("已组装 \(done)/\(total.count)")
                .font(.headline.monospacedDigit())
            Text("点按图纸上的零件查看它在哪块板上")
                .font(.subheadline)
                .foregroundColor(Theme.ColorToken.Text.secondary)
        }
    }

    /// 这个零件分在哪几块板上：板号 + 这块板上属于它的摆放。拼了两份可能在同一块板上，也可能分开。
    private func locations(of part: BeadPart) -> [(index: Int, board: PartsBoard, placements: Set<UUID>)] {
        boards.enumerated().compactMap { index, board in
            let mine = Set(board.placements.filter { $0.partId == part.id }.map(\.id))
            return mine.isEmpty ? nil : (index, board, mine)
        }
    }

    private func selectedCard(_ part: BeadPart) -> some View {
        let order = partOrder[part.id] ?? 0
        let spots = locations(of: part)
        let isDone = assembled.contains(part.id)
        let boardText = spots.isEmpty
            ? String(localized: "未排到拼豆板上")
            : spots.map { String(localized: "板 \($0.index + 1)") }.joined(separator: "、")

        return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(part.displayName(order: order - 1))
                    .font(.headline)
                Text(boardText)
                    .font(.headline)
                    .foregroundColor(Theme.ColorToken.Morandi.mauve)
                Spacer()
                Button {
                    if isDone { assembled.remove(part.id) } else { assembled.insert(part.id) }
                    onPersist()
                } label: {
                    if isDone {
                        Label("标记未组装", systemImage: "arrow.uturn.backward")
                    } else {
                        Label("标记已组装", systemImage: "checkmark")
                    }
                }
                .font(.subheadline)
                .buttonStyle(.bordered)
                .tint(isDone ? nil : Theme.ColorToken.Status.success)
            }

            if spots.count == 1, let spot = spots.first {
                thumbnail(spot.board, focus: spot.placements)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if spots.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.md) {
                        ForEach(spots, id: \.index) { spot in
                            VStack(spacing: Theme.Spacing.xs) {
                                Text("板 \(spot.index + 1)")
                                    .font(.caption.weight(.medium))
                                    .foregroundColor(Theme.ColorToken.Text.secondary)
                                thumbnail(spot.board, focus: spot.placements)
                                    .frame(width: 230, height: 230)
                            }
                        }
                    }
                }
            }
        }
    }

    private func thumbnail(_ board: PartsBoard, focus: Set<UUID>) -> some View {
        AssemblyBoardThumbnail(board: board, focus: focus, parts: parts,
                               partOrder: partOrder, colorCache: colorCache)
    }

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
}

// MARK: - 图纸上的框

private struct AssemblyBoxOverlay: View {
    let parts: [BeadPart]
    let page: Int
    let selection: UUID?
    let assembled: Set<UUID>
    let transform: PartsCanvasTransform

    var body: some View {
        Canvas { context, _ in
            for (index, part) in parts.enumerated() where part.pageIndex == page {
                let r = transform.screenRect(part.bounds)
                let path = Path(roundedRect: r, cornerRadius: 2)
                let selected = selection == part.id
                let done = assembled.contains(part.id)

                if selected {
                    // 选中用橙色（同零件清单），这张图上没有哪个颜色跟它撞
                    context.fill(path, with: .color(.orange.opacity(0.3)))
                    context.stroke(path, with: .color(.orange), lineWidth: 2.5)
                } else if done {
                    // 粘好的蒙一层白：剩下没粘的在图上自己就跳出来了
                    context.fill(path, with: .color(.white.opacity(0.65)))
                    context.stroke(path, with: .color(Theme.ColorToken.Status.success), lineWidth: 1)
                } else {
                    context.stroke(path, with: .color(.cyan), lineWidth: 1)
                }

                // 号和勾太小就不画，五十几个挤在一起谁都看不清；点一下选中的那个总会画
                guard min(r.width, r.height) >= 16 || selected else { continue }
                let badgeY = r.minY > 8 ? r.minY - 5 : r.minY + 5
                let badgeColor: Color = selected ? .orange : (done ? Theme.ColorToken.Status.success : .cyan)
                context.fill(
                    Path(ellipseIn: CGRect(x: r.minX - 6, y: badgeY - 6, width: 13, height: 13)),
                    with: .color(badgeColor)
                )
                context.draw(
                    Text("\(index + 1)").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.black),
                    at: CGPoint(x: r.minX + 0.5, y: badgeY)
                )
                if done, !selected {
                    let size = min(22, min(r.width, r.height) * 0.6)
                    var mark = context.resolve(Image(systemName: "checkmark.circle.fill"))
                    mark.shading = .color(Theme.ColorToken.Status.success)
                    context.draw(mark, in: CGRect(x: r.midX - size / 2, y: r.midY - size / 2,
                                                  width: size, height: size))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 板子缩略图

/// 一整块板，只有 `focus` 那几个摆放亮着。画法跟拼豆板那屏是同一份（`BoardCanvasRenderer`），
/// 用户在这里看到的板跟他拼的时候看到的长得一样，才对得上手边那块实物。
private struct AssemblyBoardThumbnail: View {
    let board: PartsBoard
    let focus: Set<UUID>
    let parts: [BeadPart]
    let partOrder: [UUID: Int]
    let colorCache: [String: Color]

    var body: some View {
        let byId = Dictionary(uniqueKeysWithValues: parts.map { ($0.id, $0) })
        var footprints: [UUID: PartFootprint] = [:]
        var labels: [UUID: String] = [:]
        for placement in board.placements {
            guard let part = byId[placement.partId] else { continue }
            footprints[placement.id] = part.footprint(for: placement)
            if focus.contains(placement.id), let order = partOrder[part.id] {
                labels[placement.id] = "\(order)"
            }
        }
        let renderer = BoardCanvasRenderer(
            board: board,
            footprints: footprints,
            colorCache: colorCache,
            labels: labels,
            selected: focus,
            focus: focus
        )
        return Canvas { context, size in
            let layout = BoardCanvasLayout.fitting(board, in: size, padding: 4)
            renderer.draw(in: context, canvas: size, layout: layout)
        }
    }
}
