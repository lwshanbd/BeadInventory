//
//  BoardCanvas.swift
//  BeadInventory
//
//  拼豆板怎么画。
//
//  手机上和外接屏幕（AirPlay 投到电视 / 投影仪）上画的是**同一块板**，所以画法只能有
//  一份。各画一遍的话，哪天改了高亮规则或者豆子的圆角，只改一边是迟早的事 ——
//  而用户是对着电视拼、低头看手机操作的，两边不一样他第一眼就会发现。
//
//  手机上多两样东西：选中的那个零件、正在拖的那个。外屏上都是 nil ——
//  那块屏幕不接受操作，画出来的就是「板子现在长什么样」。
//

import SwiftUI

/// 板子在画布上占哪一块、一格多大
struct BoardCanvasLayout {
    let rect: CGRect
    let cell: CGFloat

    func cellRect(col: Int, row: Int) -> CGRect {
        CGRect(x: rect.minX + CGFloat(col) * cell,
               y: rect.minY + CGFloat(row) * cell,
               width: cell, height: cell)
    }

    /// 零件真正占地方的那一块在屏幕上的位置（不含四周的空白边）
    func boundingRect(of footprint: PartFootprint, col: Int, row: Int) -> CGRect {
        CGRect(x: rect.minX + CGFloat(col + footprint.minCol) * cell,
               y: rect.minY + CGFloat(row + footprint.minRow) * cell,
               width: CGFloat(footprint.width) * cell,
               height: CGFloat(footprint.height) * cell)
    }

    /// 板子整个装进画布，四周留一点边。
    /// `zoom` / `pan` 只有手机上用得着 —— 外屏不接受操作，永远是 1 和 .zero。
    static func fitting(
        _ board: PartsBoard, in canvasSize: CGSize,
        zoom: CGFloat = 1, pan: CGSize = .zero, padding: CGFloat = 12
    ) -> BoardCanvasLayout {
        let available = CGSize(width: max(1, canvasSize.width - padding * 2),
                               height: max(1, canvasSize.height - padding * 2))
        let base = min(available.width / CGFloat(max(board.cols, 1)),
                       available.height / CGFloat(max(board.rows, 1)))
        let width = base * CGFloat(board.cols)
        let height = base * CGFloat(board.rows)
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let origin = CGPoint(x: (canvasSize.width - width) / 2, y: (canvasSize.height - height) / 2)
        return BoardCanvasLayout(
            rect: CGRect(x: center.x + (origin.x - center.x) * zoom + pan.width,
                         y: center.y + (origin.y - center.y) * zoom + pan.height,
                         width: width * zoom, height: height * zoom),
            cell: base * zoom
        )
    }
}

/// 高亮时整块板换成的「舞台」。
///
/// 为什么板底要跟着高亮色变：拼的时候人是抓一把某个色号、照着板子找该往哪儿放。
/// 板底固定成浅色的话，选到浅粉、米白这类色号，高亮和板底几乎一个亮度 ——
/// 屏幕上等于什么都没高亮，用户还以为功能坏了。深色模式下选深蓝、墨绿同理。
/// 所以高亮期间板底整个翻到跟高亮色相反的那一端：这一屏只有一个任务，
/// 就是让那一个色号跳出来，别的都让路。
///
/// 亮度用的是 0.299/0.587/0.114 感知加权。`BIColorSwatch` 判「字压黑还是压白」用的是同一个
/// 公式，但阈值是 0.6 不是这里的 0.5：那边要的是文字读得清（偏向压黑字），
/// 这里要的是把整个色域一刀切成两半，好让下面那条粗线的两道颜色一定各站一边。
///
/// 舞台色刻意写死不走 Theme：它要对抗的是**用户选的那颗豆子**，不是 App 的色彩模式 ——
/// 跟着主题走的话，浅色模式挑浅色豆子这个最难的组合恰好一点都没改善。
struct BoardHighlightStage {
    /// 板底
    let board: Color
    /// 压暗的豆子（不是高亮那个色号的）
    let dimmed: Color
    /// 细格线
    let gridMinor: Color
    /// 每 5 格那条粗线的两道：先描宽的 `gridCasing`，再把窄的 `gridCore` 压在中间，
    /// 于是 casing 只从两边露出来一点。为什么非得两道：
    ///
    /// 这条线得压在豆子**上面**（高亮那片同色豆子几乎连成一块，压底下就整条没了），
    /// 所以它身下可能是三种东西：板底、压暗的豆子、以及**用户随便点亮的那些色号**。
    /// 一个灰色赢不了这三样 —— 灰色本身就是色号：M15 `#757D7B` 亮度 0.480、
    /// H4 `#89858C` 亮度 0.529，跟原来那条中灰粗线撞个正着，抓着这类色号一点高亮，
    /// 整片高亮区一根格线都数不出来。H 系是描边阴影用的灰黑白主力，不是冷门色号。
    ///
    /// 两道分踩色域两端（0.06 配 0.88，或者 0.14 配 0.96），所以不管身下是什么亮度 L，
    /// 两道里较好的那道至少也差 0.41（最差是 L 落在两道正中间的时候）。
    /// 这跟点亮了几个色号、点的是哪几个都无关 —— 用户同时点白色和黑色也一样成立。
    ///
    /// 分工是：`gridCore`（窄、在中间）跟板底反着来，板上绝大多数地方是板底和压暗的豆子，
    /// 平时看到的就是这一道；`gridCasing`（宽、露在两边）在 core 化掉的地方接手。
    /// 于是板底上是一道干净的亮线（或暗线），中灰豆子上是深边夹亮芯，
    /// 纯白豆子上 core 没了、剩两条细的深色边把那条线框出来。
    let gridCasing: Color
    let gridCore: Color
    /// 零件外沿（选中和放不下另有颜色，不走这里）
    let contour: Color

    /// `highlights` 是这一屏点亮的那些色号的颜色。空集不该建舞台，调用方拦在外面。
    ///
    /// 点亮好几个色号时（单图纸模式支持，手上抓着两种豆子一起拼是常事）按**平均亮度**
    /// 选台面：台面只有一面，只能站在这一把豆子整体的反面。用户要是同时点了纯白和纯黑，
    /// 台面必然贴着其中一个 —— 这个没得选，一块板底躲不开色域两端。
    /// 但格线不受影响，两道分踩两端，见 `gridCasing` / `gridCore`。
    init(highlights: [Color]) {
        var total: CGFloat = 0
        for highlight in highlights {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(highlight).getRed(&r, green: &g, blue: &b, alpha: &a)
            total += 0.299 * r + 0.587 * g + 0.114 * b
        }
        let luminance = total / CGFloat(max(highlights.count, 1))

        if luminance > 0.5 {
            // 亮豆子 → 压黑的台面
            board      = Color(white: 0.10)
            dimmed     = Color(white: 0.26)
            gridMinor  = Color(white: 0.20)
            gridCore   = Color(white: 0.88)   // 对着 0.10 的板底
            gridCasing = Color(white: 0.06)   // 对着亮度 > 0.5 的豆子
            contour    = Color(white: 1.0).opacity(0.55)
        } else {
            // 暗豆子 → 提亮的台面
            board      = Color(white: 0.95)
            dimmed     = Color(white: 0.78)
            gridMinor  = Color(white: 0.86)
            gridCore   = Color(white: 0.14)   // 对着 0.95 的板底
            gridCasing = Color(white: 0.96)   // 对着亮度 ≤ 0.5 的豆子
            contour    = Color(white: 0.0).opacity(0.45)
        }
    }
}

/// 画一块板要用到的全部东西
struct BoardCanvasRenderer {
    /// 正在被拖的那个摆放（只有手机上有）
    struct Moving: Equatable {
        let placement: UUID
        let deltaCol: Int
        let deltaRow: Int
        let valid: Bool
    }

    let board: PartsBoard
    /// 板上每个摆放对应的形状
    let footprints: [UUID: PartFootprint]
    /// 色号 → 颜色
    let colorCache: [String: Color]
    /// 只高亮这些色号，别的压成灰。空集 = 全都正常显示。
    ///
    /// 是集合不是单个：单图纸模式的高亮页可以同时点亮好几个色号（手上抓了两种豆子
    /// 一起拼是常事），而这块画布是两种模式共用的。多零件那边传一个就是一个。
    var highlightKeys: Set<String> = []
    /// 每个摆放身上写的编号（摆放 id → 写什么）。空 = 不写。
    ///
    /// 写的是零件在**清单里的序号**，跟「零件清单」那屏图上的号、缩略图上的号是同一个 ——
    /// 排到板上之后零件就脱离图纸了，板上一块灰蓝色的方块到底是图纸上哪一块，
    /// 不写号就只能靠形状猜。号跟着零件上板，用户才对得回去。
    /// 单图纸模式整张图就一个「零件」，没有号可写，传空。
    ///
    /// **点亮了色号时这些号一个都不画**（见 `drawBadges`）—— 那一屏的规矩是「除了那个色号，
    /// 别的都让路」，号也不例外。调用方照常传，画不画由这里定，两块屏幕才不会一块写一块不写。
    var labels: [UUID: String] = [:]
    var selection: UUID?
    var moving: Moving?
    /// 跟旁边挨上了、又挪不开的那些摆放。跟「拖到放不下的地方」画成同一种红 ——
    /// 用户在这块板上只需要认一种「这儿不对」，不该学两套。
    ///
    /// 外屏也要画：人是抬头照着电视摆豆子的，粘连的那两块正是他会照着摆错的地方。
    var invalid: Set<UUID> = []

    func draw(in context: GraphicsContext, canvas size: CGSize, layout: BoardCanvasLayout) {
        let cell = layout.cell
        guard cell > 0 else { return }
        let viewport = CGRect(origin: .zero, size: size)

        let stage = highlightKeys.isEmpty
            ? nil
            : BoardHighlightStage(highlights: highlightKeys.map { beadColor(for: $0) })

        context.fill(
            Path(roundedRect: layout.rect, cornerRadius: 6),
            with: .color(stage?.board ?? Theme.ColorToken.Surface.elevated)
        )
        context.stroke(
            Path(roundedRect: layout.rect, cornerRadius: 6),
            with: .color(stage?.gridCore ?? Theme.ColorToken.Border.default),
            lineWidth: 1
        )

        // 格线。每 5 格一条深的 —— 拼的时候要数「往右第几格」，
        // 没有参照线的话在一片 100×100 里数到第几格全靠运气。
        //
        // 细线永远画在豆子**底下**。粗线**只有高亮的时候**才改到豆子**上面**去
        // （见下面填充之后那一段）：高亮那片同色豆子几乎连成一块，粗线压在底下就整条没了 ——
        // 而恰恰是这时候用户最需要数格子，他正抓着一把豆子找第几行第几列。
        // 没高亮的时候不动它：那一屏用户看的是图纸本身，格线不该压进豆子的颜色里。
        var minorGrid = Path()
        var majorGrid = Path()
        if cell >= 2.5 {
            for c in 0...board.cols {
                let x = layout.rect.minX + CGFloat(c) * cell
                var path = Path()
                path.move(to: CGPoint(x: x, y: layout.rect.minY))
                path.addLine(to: CGPoint(x: x, y: layout.rect.maxY))
                if c % 5 == 0 { majorGrid.addPath(path) } else { minorGrid.addPath(path) }
            }
            for r in 0...board.rows {
                let y = layout.rect.minY + CGFloat(r) * cell
                var path = Path()
                path.move(to: CGPoint(x: layout.rect.minX, y: y))
                path.addLine(to: CGPoint(x: layout.rect.maxX, y: y))
                if r % 5 == 0 { majorGrid.addPath(path) } else { minorGrid.addPath(path) }
            }
            context.stroke(minorGrid,
                           with: .color(stage?.gridMinor ?? Theme.ColorToken.Border.divider),
                           lineWidth: 0.5)
            if stage == nil {
                context.stroke(majorGrid,
                               with: .color(Theme.ColorToken.Border.default),
                               lineWidth: 1)
            }
        }

        let radius = cell * 0.28
        let inset = min(0.8, cell * 0.08)
        // 高亮的那个色号画得**方**、画得满：这一屏用户是在扫「哪些格子是这个色」，
        // 圆角越大越像一串分开的点，方块才连得成一片、一眼看得出形状。
        // 压暗的那些保持原来的圆角 —— 形状上也拉开差距，不只是靠颜色。
        let highlightRadius = cell * 0.12
        let highlightInset = min(0.35, cell * 0.03)

        // 同色的豆子攒成一条 Path，最后一个色号画一次。
        // 一颗一颗 fill 的话，一块排满的 104×104 就是八千次画调用 ——
        // 而拖动时手指每挪一下整块板都要重画一遍，直接卡成幻灯片。
        // 一块板上的色号顶多十几种，攒完之后画调用也就跟着降到十几次。
        var fills: [String: Path] = [:]
        // 轮廓要按「放不下 / 选中 / 普通」三种样式分开描，跟填充分两轮走
        var contours: [(path: Path, color: Color, width: CGFloat)] = []
        // 编号最后画：它必须压在豆子和轮廓上面，不然一个都看不见
        var badges: [(box: CGRect, text: String, selected: Bool)] = []

        for placement in board.placements {
            guard let footprint = footprints[placement.id] else { continue }
            let moving = self.moving?.placement == placement.id ? self.moving : nil
            let col = placement.col + (moving?.deltaCol ?? 0)
            let row = placement.row + (moving?.deltaRow ?? 0)
            let blocked = moving.map { !$0.valid } ?? invalid.contains(placement.id)

            // 沿着这个零件的外沿描一圈。
            //
            // 少了它，用户根本分不出零件的边界：这类图纸的零件几乎都是
            // 「深色描边 + 浅色填充」，两个零件隔着一格摆在一起，看上去就是连成一片的 ——
            // 明明一格都没挨着，用户看到的却是「你把零件叠一起了」。
            // 框住整个外接矩形也不行：零件是不规则的，矩形会盖到邻居身上，更像叠了。
            var contour = Path()
            for bead in footprint.beads {
                let rect = layout.cellRect(col: col + bead.col, row: row + bead.row)
                guard rect.intersects(viewport) else { continue }
                let fillKey: String
                var isHighlighted = false
                if blocked {
                    fillKey = BoardCanvasRenderer.blockedFillKey
                } else if !highlightKeys.isEmpty {
                    isHighlighted = highlightKeys.contains(bead.key)
                    fillKey = isHighlighted ? bead.key : BoardCanvasRenderer.dimmedFillKey
                } else {
                    fillKey = bead.key
                }
                let shrink = isHighlighted ? highlightInset : inset
                fills[fillKey, default: Path()].addPath(
                    Path(roundedRect: rect.insetBy(dx: shrink, dy: shrink),
                         cornerRadius: isHighlighted ? highlightRadius : radius)
                )

                if !footprint.hasBead(col: bead.col, row: bead.row - 1) {
                    contour.move(to: CGPoint(x: rect.minX, y: rect.minY))
                    contour.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                }
                if !footprint.hasBead(col: bead.col, row: bead.row + 1) {
                    contour.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                    contour.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                }
                if !footprint.hasBead(col: bead.col - 1, row: bead.row) {
                    contour.move(to: CGPoint(x: rect.minX, y: rect.minY))
                    contour.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                }
                if !footprint.hasBead(col: bead.col + 1, row: bead.row) {
                    contour.move(to: CGPoint(x: rect.maxX, y: rect.minY))
                    contour.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                }
            }

            let isSelected = selection == placement.id || moving != nil
            let outline: Color = blocked
                ? Theme.ColorToken.Status.error
                : (isSelected ? Theme.ColorToken.Morandi.honey
                              : stage?.contour ?? Theme.ColorToken.Text.primary.opacity(0.45))
            contours.append((path: contour, color: outline, width: isSelected ? 2.5 : 1))

            // 高亮期间一个号都不写，理由见 `drawBadges`。
            if stage == nil, let text = labels[placement.id], !footprint.isEmpty {
                badges.append((
                    box: layout.boundingRect(of: footprint, col: col, row: row),
                    text: text,
                    selected: isSelected
                ))
            }
        }

        // 几批填充之间的先后只有一处有讲究：零件之间本来就不会重叠，唯独拖到别人身上那一下会 ——
        // 变红的那一份必须盖在上面，不然用户看不出是哪个零件放不下。
        // （填充和格线谁在上面另有讲究，见上面建格线 Path 的地方。）
        for (key, path) in fills where key != BoardCanvasRenderer.blockedFillKey {
            context.fill(path, with: .color(fillColor(for: key, stage: stage)))
        }
        if let blocked = fills[BoardCanvasRenderer.blockedFillKey] {
            context.fill(blocked,
                         with: .color(fillColor(for: BoardCanvasRenderer.blockedFillKey, stage: stage)))
        }

        // 高亮时，每 5 格那条粗线补描在豆子上面，一宽一窄两道（理由见 `BoardHighlightStage`）。
        // 没高亮的时候这条线已经在豆子底下画过了，这里不再动它。
        // `majorGrid` 在 cell < 2.5 时是空的，描空 Path 本身就是空操作。
        if let stage {
            context.stroke(majorGrid, with: .color(stage.gridCasing), lineWidth: 2)
            context.stroke(majorGrid, with: .color(stage.gridCore), lineWidth: 1.2)
        }

        for contour in contours {
            context.stroke(contour.path, with: .color(contour.color), lineWidth: contour.width)
        }

        drawBadges(badges, in: context, cell: cell)
    }

    /// 把编号写在每个零件正中间。
    ///
    /// 位置取零件外接矩形的中心：贴左上角的话，零件之间只隔一格，号会压到邻居身上 ——
    /// 而这个号存在的意义正是「分清谁是谁」。不规则零件的中心偶尔落在镂空里，
    /// 那反而更好认（不挡豆子）。
    ///
    /// **装不下就不写**（除非它是选中的那个）：一块 100×100 的板缩在手机上，
    /// 一格才三四个点，五十几个号会叠成一团糊，比不写还糟。用户捏一下放大就出来了；
    /// 而选中的那个不管多小都写 —— 他刚点了它，屏幕上必须回答「这是几号」。
    ///
    /// **点亮某个色号的时候一个号都不写**（调用方在收集阶段就拦掉了，所以这里不接 `stage`）。
    /// 那一屏用户在数「哪几个格子是这个色」，一颗一颗按豆子 —— 号压在豆子上就是在
    /// 挡他正要数的东西，而「这是几号」在那一刻根本不是他的问题。要看号，取消高亮就有。
    private func drawBadges(
        _ badges: [(box: CGRect, text: String, selected: Bool)],
        in context: GraphicsContext,
        cell: CGFloat
    ) {
        guard !badges.isEmpty else { return }
        // 跟着格子大小走：放大之后号也跟着大，不然一块放大 8 倍的板上还是那个米粒大的号。
        let preferred = min(max(cell * 1.7, 10), 20)

        for badge in badges {
            let fill: Color = badge.selected
                ? Theme.ColorToken.Morandi.honey
                : Theme.ColorToken.Surface.background.opacity(0.88)
            let ink: Color = badge.selected ? .black : Theme.ColorToken.Text.primary

            // 先按理想字号试，装不下再退到最小可读的 10pt；还装不下就只有选中的那个硬写。
            var drawn: (text: GraphicsContext.ResolvedText, pill: CGRect)?
            for size in [preferred, 10] where drawn == nil {
                let resolved = context.resolve(
                    Text(badge.text).font(.system(size: size, weight: .bold)).foregroundStyle(ink)
                )
                let measured = resolved.measure(in: CGSize(width: 400, height: 400))
                let pill = CGRect(
                    x: badge.box.midX - measured.width / 2 - size * 0.28,
                    y: badge.box.midY - measured.height / 2 - size * 0.1,
                    width: measured.width + size * 0.56,
                    height: measured.height + size * 0.2
                )
                if pill.width <= badge.box.width, pill.height <= badge.box.height {
                    drawn = (resolved, pill)
                } else if size == 10, badge.selected {
                    drawn = (resolved, pill)
                }
            }
            guard let drawn else { continue }

            context.fill(
                Path(roundedRect: drawn.pill, cornerRadius: drawn.pill.height / 2),
                with: .color(fill)
            )
            context.draw(drawn.text, at: CGPoint(x: badge.box.midX, y: badge.box.midY), anchor: .center)
        }
    }

    /// 攒填充用的两个假色号：拖到放不下的地方整个零件变红、高亮时别的色号压成灰。
    /// 它们和真色号一样只是「一批同色的豆子」，所以走同一个分组。
    static let blockedFillKey = "#blocked"
    static let dimmedFillKey = "#dimmed"

    /// 色号 → 这颗豆子本来的颜色。查不到给个中性块，别在板上留一片空的。
    private func beadColor(for key: String) -> Color {
        colorCache[key] ?? Theme.ColorToken.Surface.strong
    }

    /// 攒填充用的 key → 真正画上去的颜色。`stage` 为 nil 就是没高亮的普通视图。
    ///
    /// 压暗色只有高亮时才会攒出来，所以走到那一支时 `stage` 一定在。它**不能**退回
    /// `Border.default` —— 那正好是没高亮时每 5 格那条粗线的颜色，一大片压暗的豆子铺开，
    /// 粗线就化在里面了（用户报的「分割线很不明显」就是这么来的）。
    private func fillColor(for key: String, stage: BoardHighlightStage?) -> Color {
        switch key {
        case BoardCanvasRenderer.blockedFillKey: return Theme.ColorToken.Status.error
        case BoardCanvasRenderer.dimmedFillKey: return stage?.dimmed ?? beadColor(for: key)
        default: return beadColor(for: key)
        }
    }

}
