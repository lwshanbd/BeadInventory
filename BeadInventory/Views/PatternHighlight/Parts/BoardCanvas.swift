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
/// 亮度用的是 0.299/0.587/0.114 感知加权，跟 `BIColorSwatch` 判「字压黑还是压白」同一套。
/// 舞台色刻意写死不走 Theme：它要对抗的是**用户选的那颗豆子**，不是 App 的色彩模式 ——
/// 跟着主题走的话，浅色模式挑浅色豆子这个最难的组合恰好一点都没改善。
struct BoardHighlightStage {
    /// 板底
    let board: Color
    /// 压暗的豆子（不是高亮那个色号的）
    let dimmed: Color
    /// 格线：细的、每 5 格那条粗的
    let gridMinor: Color
    let gridMajor: Color
    /// 零件外沿（选中和放不下另有颜色，不走这里）
    let contour: Color

    init(highlight: Color) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(highlight).getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b

        if luminance > 0.5 {
            // 亮豆子 → 压黑的台面
            board     = Color(white: 0.10)
            dimmed    = Color(white: 0.26)
            gridMinor = Color(white: 0.20)
            gridMajor = Color(white: 0.52)
            contour   = Color(white: 1.0).opacity(0.55)
        } else {
            // 暗豆子 → 提亮的台面
            board     = Color(white: 0.95)
            dimmed    = Color(white: 0.78)
            gridMinor = Color(white: 0.86)
            gridMajor = Color(white: 0.48)
            contour   = Color(white: 0.0).opacity(0.45)
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
    /// 只高亮这一个色号，别的压成灰。nil = 全都正常显示。
    var highlightKey: String?
    var selection: UUID?
    var moving: Moving?

    func draw(in context: GraphicsContext, canvas size: CGSize, layout: BoardCanvasLayout) {
        let cell = layout.cell
        guard cell > 0 else { return }
        let viewport = CGRect(origin: .zero, size: size)

        let stage = highlightKey.map { BoardHighlightStage(highlight: fillColor(for: $0)) }

        context.fill(
            Path(roundedRect: layout.rect, cornerRadius: 6),
            with: .color(stage?.board ?? Theme.ColorToken.Surface.elevated)
        )
        context.stroke(
            Path(roundedRect: layout.rect, cornerRadius: 6),
            with: .color(stage?.gridMajor ?? Theme.ColorToken.Border.default),
            lineWidth: 1
        )

        // 格线。每 5 格一条深的 —— 拼的时候要数「往右第几格」，
        // 没有参照线的话在一片 100×100 里数到第几格全靠运气。
        //
        // 细线画在豆子**底下**，粗线画在豆子**上面**（见下面 drawMajorGrid 的调用点）。
        // 高亮时那一片同色豆子几乎连成一块，粗线要是也压在底下就整条看不见了 ——
        // 而恰恰是这时候用户最需要数格子：他正抓着一把豆子找第几行第几列。
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

        for placement in board.placements {
            guard let footprint = footprints[placement.id] else { continue }
            let moving = self.moving?.placement == placement.id ? self.moving : nil
            let col = placement.col + (moving?.deltaCol ?? 0)
            let row = placement.row + (moving?.deltaRow ?? 0)
            let blocked = moving.map { !$0.valid } ?? false

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
                } else if let highlightKey {
                    isHighlighted = bead.key == highlightKey
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
        }

        // 先后顺序只有一处有讲究：零件之间本来就不会重叠，唯独拖到别人身上那一下会 ——
        // 变红的那一份必须盖在上面，不然用户看不出是哪个零件放不下。
        for (key, path) in fills where key != BoardCanvasRenderer.blockedFillKey {
            context.fill(path, with: .color(stage.map { fillColor(for: key, stage: $0) }
                                            ?? fillColor(for: key)))
        }
        if let blocked = fills[BoardCanvasRenderer.blockedFillKey] {
            context.fill(blocked, with: .color(fillColor(for: BoardCanvasRenderer.blockedFillKey)))
        }

        // 每 5 格那条粗线画在豆子上面，理由见上面建 Path 的地方。
        if cell >= 2.5 {
            context.stroke(majorGrid,
                           with: .color(stage?.gridMajor ?? Theme.ColorToken.Border.default),
                           lineWidth: stage == nil ? 1 : 1.2)
        }

        for contour in contours {
            context.stroke(contour.path, with: .color(contour.color), lineWidth: contour.width)
        }
    }

    /// 攒填充用的两个假色号：拖到放不下的地方整个零件变红、高亮时别的色号压成灰。
    /// 它们和真色号一样只是「一批同色的豆子」，所以走同一个分组。
    static let blockedFillKey = "#blocked"
    static let dimmedFillKey = "#dimmed"

    private func fillColor(for key: String) -> Color {
        switch key {
        case BoardCanvasRenderer.blockedFillKey: return Theme.ColorToken.Status.error
        case BoardCanvasRenderer.dimmedFillKey: return Theme.ColorToken.Border.default
        default: return colorCache[key] ?? Theme.ColorToken.Surface.strong
        }
    }

    /// 高亮期间的取色：压暗的那批交给舞台，真色号照原样画。
    ///
    /// 压暗色**不能**再用 `Border.default` —— 那正好是每 5 格那条粗线的颜色，
    /// 一大片压暗的豆子铺开，粗线就化在里面了（用户报的「分割线很不明显」就是这么来的）。
    private func fillColor(for key: String, stage: BoardHighlightStage) -> Color {
        key == BoardCanvasRenderer.dimmedFillKey ? stage.dimmed : fillColor(for: key)
    }

}
