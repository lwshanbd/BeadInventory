//
//  BoardProjectorCanvas.swift
//  BeadInventory
//
//  投影仪模式下，投到桌上那块豆板上的画面
//
//  ## 跟电视上那块板不是一回事
//
//  电视上画的是**整块板**（`BoardCanvas`）：人抬头看图，图上什么都在，没选中的色号
//  压成灰。投影仪投的是**豆板本身**：用户低头看的是自己的板子，画面正好盖在板子上 ——
//  这时候把整张图纸都亮出来，等于把每个孔都照亮，他反而看不出该按哪儿。
//
//  所以这一份只画**当前色号的那些格子**，其余全黑。黑的地方投影仪不出光，板子上就是
//  一片暗；亮的地方正好是接下来要按豆子的那些孔。用户抓一把豆子，照着亮的地方按下去，
//  按完在手机上换下一个色号。
//
//  ## 亮的格子用什么颜色
//
//  三种，用户在投影仪模式那一屏里挑（`ProjectorHighlightStyle`）：
//
//  **跟着图纸走**（默认）：按色号本来的颜色投，但要**提到最亮**再投 —— 投影是加光，
//  黑色豆子的颜色投出来就是不出光，那一格跟没亮一样，而黑恰恰是用得最多的色号之一，
//  深蓝、墨绿同理。提亮时保住色相、顺手压一点饱和度（纯色越饱和投出来越暗）：
//  黑变成白光，深蓝变成亮蓝。代价是**亮度这一维整个丢了**：黑、白、所有灰阶都投成
//  同一个白，同色相的深浅两色（深红/亮红）也会撞在一起 —— 同时点亮两个这样的色号时，
//  用户只能靠位置区分。
//
//  **一律白光**：板子上最亮最清楚。反正一次只拼一个色号的时候，格子是什么颜色并不
//  携带信息 —— 亮着的孔就是要按豆子的孔。
//
//  **一律用户挑的那个颜色**：桌面、板子、屋里的灯什么样，只有站在那儿的人知道 ——
//  白板子上投白光反光晃眼、暖光台灯下投黄光看不出来，都是真事。给个颜色让他自己挑，
//  比在这儿猜一个「最合适的颜色」靠谱。
//
//  后两种下所有色号投出来长得一样，同时点亮两个就分不开了。这是用户自己选的，
//  说清楚就行（那一屏选中哪一项，底下就写着那一项的代价），不额外加描边、点阵
//  那类编码 —— 一次抓一把豆子拼一个色号才是常态。
//
//  ## 格子往里缩一点
//
//  一格填满的话，挨着的两格连成一片，数不出是几个孔；而豆板的孔本来就有间距。
//  缩一点之后，投出来的是一颗一颗分开的光斑，正好一颗对一个孔。
//

import SwiftUI

struct ProjectorCanvasRenderer {
    let board: PartsBoard
    let footprints: [UUID: PartFootprint]
    let colorCache: [String: Color]
    /// 只亮这些色号。空 = 一格都不亮（手机上还没点色号）。
    let highlightKeys: Set<String>
    /// 亮的格子投什么颜色（用户在投影仪模式那一屏里挑的）
    let highlight: ProjectorHighlightPaint
    let mapping: ProjectorMapping

    /// 每格四边各往里缩多少（单位：格）
    private static let cellInset: CGFloat = 0.08

    func draw(in context: GraphicsContext) {
        drawBoardOutline(in: context)
        guard !highlightKeys.isEmpty else { return }

        // 同色的格子攒成一条 Path 再画。一格一填的话，一张排满的 104×104 图纸
        // 光是画调用就上万次 —— 而这块画面在用户每换一个色号时都要重画一遍。
        var fills: [String: Path] = [:]
        for placement in board.placements {
            guard let footprint = footprints[placement.id] else { continue }
            for bead in footprint.beads where highlightKeys.contains(bead.key) {
                guard let corners = mapping.cellCorners(
                    col: placement.col + bead.col,
                    row: placement.row + bead.row,
                    inset: Self.cellInset
                ) else { continue }   // 翻到透视中心背后去了，那一格画不出来
                var path = Path()
                path.move(to: corners[0])
                for point in corners.dropFirst() { path.addLine(to: point) }
                path.closeSubpath()
                fills[bead.key, default: Path()].addPath(path)
            }
        }
        for (key, path) in fills {
            context.fill(path, with: .color(highlight.color(for: colorCache[key])))
        }
    }

    /// 豆板边框描一圈暗线。
    ///
    /// 为什么留着这一圈：拼到一半有人碰了桌子、或者投影仪被蹭了一下，画面就跟板子
    /// 错开了 —— 而只亮几十个格子的时候，用户很难一眼看出「整体偏了半格」。
    /// 边框正好落在板子的外沿上，偏没偏一看便知。画得很暗，不会跟亮的格子抢眼。
    /// 只画那一圈板框。手机上还没打开拼图模式时用 —— 外屏一整块纯黑的话，
    /// 用户连「校准还在不在」都看不出来。
    func drawOutlineOnly(in context: GraphicsContext) {
        drawBoardOutline(in: context)
    }

    private func drawBoardOutline(in context: GraphicsContext) {
        guard let outline = boardOutlinePath else { return }
        context.stroke(outline, with: .color(.white.opacity(0.28)), lineWidth: 2)
    }

    var boardOutlinePath: Path? {
        let cols = mapping.boardCols, rows = mapping.boardRows
        guard let tl = mapping.point(col: 0, row: 0),
              let tr = mapping.point(col: CGFloat(cols), row: 0),
              let br = mapping.point(col: CGFloat(cols), row: CGFloat(rows)),
              let bl = mapping.point(col: 0, row: CGFloat(rows)) else { return nil }
        var path = Path()
        path.move(to: tl)
        path.addLine(to: tr)
        path.addLine(to: br)
        path.addLine(to: bl)
        path.closeSubpath()
        return path
    }
}

// MARK: - 亮的格子用什么颜色

/// 三种投法。存在 `BoardProjector` 里，手机那一屏和外屏读的是同一份。
/// `rawValue` 直接落进 UserDefaults —— 改 case 名等于把用户的选择清掉。
enum ProjectorHighlightStyle: String, CaseIterable, Identifiable {
    /// 跟着图纸的色号走（暗色会被提亮，见 `ProjectorHighlightPaint.brightened`）
    case pattern
    /// 一律白光
    case white
    /// 一律用户挑的那个颜色
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pattern: return String(localized: "跟着图纸")
        case .white: return String(localized: "白色")
        case .custom: return String(localized: "自定义")
        }
    }

    /// 选中这一项时底下显示的那句话。三句都得说到「代价是什么」——
    /// 用户是站在投影仪旁边挑的，挑完才发现两个色号撞色就晚了。
    var explanation: String {
        switch self {
        case .pattern:
            return String(localized: "按色号本来的颜色投。黑、深蓝这类投出来是不亮的，会自动提到最亮 —— 色相还在，深浅没了：黑和白都是白光。")
        case .white:
            return String(localized: "不管当前是哪个色号，一律投白光。板子上最亮、边界最清楚，代价是同时点亮两个色号时它们长得一样。")
        case .custom:
            return String(localized: "一律投你挑的这个颜色。白板子上白光晃眼、或者屋里灯偏黄看不清时，换一个更好认的颜色。代价跟白色一样：同时点亮两个色号时它们长得一样。")
        }
    }
}

/// 「色号本来的颜色」→「投到板子上的那个颜色」。
///
/// 图例上那个圆点也走这儿（见 `BoardExternalDisplayView.legend`）：抬头看到的是什么
/// 颜色，图例上就得是什么颜色，不然黑色色号会变成「一个看不见的点」配「一片白格子」。
///
/// 两个字段都不给默认值：默认是「上次存的那一套」，只有 `BoardProjector` 知道
/// （见它的 `defaultCustomHex`）。这里再写一个默认值，就会有两份说法。
struct ProjectorHighlightPaint {
    var style: ProjectorHighlightStyle
    /// `style == .custom` 时用它。别的模式下也留着 —— 用户切走再切回来，
    /// 上次挑的那个颜色还在。
    var custom: Color

    func color(for patternColor: Color?) -> Color {
        switch style {
        case .pattern: return Self.brightened(patternColor)
        case .white: return .white
        case .custom: return custom
        }
    }

    /// 保住色相、压一点饱和度、亮度拉满（理由见文件头）。
    /// 查不到色号时给白光：这一格用户照样要按豆子，不能因为图例里少一条就不亮。
    ///
    /// `private`：投出来的颜色只有 `color(for:)` 一个出口。绕过它直接调这儿，
    /// 就是图例曾经犯过的那个错 —— 用户选了白光，图例还按图纸的颜色画。
    private static func brightened(_ color: Color?) -> Color {
        guard let color else { return .white }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(color).getHue(&hue, saturation: &saturation,
                                    brightness: &brightness, alpha: &alpha) else { return .white }
        return Color(hue: hue, saturation: min(saturation, 0.6), brightness: 1, opacity: 1)
    }

    /// 这个颜色暗到投出来看不见了没有。只用来在手机上提醒一句 ——
    /// **不替用户改掉他挑的颜色**：他可能就是要压暗（屋里很黑、板子反光）。
    ///
    /// 按人眼的亮度算，不用 HSB 那个 brightness：后者是 RGB 里最大的那个分量，
    /// 纯蓝算出来是满值 —— 而纯蓝正是在取色盘上看着挺醒目、投到板子上几乎看不见的
    /// 那一类。用这个公式纯蓝是 0.07，会被拦下；默认那个亮黄是 0.81，不会误伤。
    static func isTooDarkToProject(_ color: Color) -> Bool {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return false }
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue < 0.2
    }
}

// MARK: - 校准时画在外屏上的东西

/// 四个角标 + 一层稀疏的辅助线。**只在用户开着校准页时画**。
///
/// 角标是个由格子拼出来的直角（`ProjectorCornerArrow`）：拐角那个亮块就是豆板
/// 最角上那个孔，两条胳膊沿着板子的两条边各再亮几个孔。用户要做的就是把拐角那块光
/// 挪到板子角上那个孔里 —— 对没对上，看那个孔有没有被照亮就行，不用判断
/// 「一条线该压在哪儿」。
///
/// **九格一样大。** 一开始是越往里画越小、想让它看着像个箭头，实际投出来反而糟：
/// 用户拿每一块光去比孔，大小不一的时候「这块是不是没照准」变成了「这块本来就该小」，
/// 判据就废了。一样大才比得出来。
///
/// 四个角各是一种颜色（`ProjectorCorner.markColor`，手机上用的是同一套）：用户站在
/// 桌边、手机在手上，四个角长得一样的话他会把正在调的那个搞错。正在调的那个更亮，
/// 箭尖还描一圈白。
///
/// 四条边的正中间和板子正中间再各点一个白记号（`ProjectorAlignmentMarks`，边上那四个
/// 缺了朝外的一笔、是「T」）：四个角对上了不代表中间也对上 —— 镜头畸变最厉害的地方
/// 就是边的中间。这几处有没有照进孔里，是用户唯一能自己判断「中间准不准」的办法。
///
/// 辅助线每 10 格一条，管的是另一件事：整块画面有没有整体歪掉。
struct ProjectorCalibrationMarks: View {
    let mapping: ProjectorMapping
    let activeCorner: ProjectorCorner

    /// 角标和对齐记号每边往里缩多少（单位：格）。两处必须一致 ——
    /// 用户是拿它们互相比着看「哪块偏了」的，大小不一样就没法比。
    private static let markInset: CGFloat = 0.05

    var body: some View {
        Canvas { context, _ in
            let cols = mapping.boardCols, rows = mapping.boardRows

            var guides = Path()
            for c in stride(from: 10, to: cols, by: 10) {
                if let a = mapping.point(col: CGFloat(c), row: 0),
                   let b = mapping.point(col: CGFloat(c), row: CGFloat(rows)) {
                    guides.move(to: a); guides.addLine(to: b)
                }
            }
            for r in stride(from: 10, to: rows, by: 10) {
                if let a = mapping.point(col: 0, row: CGFloat(r)),
                   let b = mapping.point(col: CGFloat(cols), row: CGFloat(r)) {
                    guides.move(to: a); guides.addLine(to: b)
                }
            }
            context.stroke(guides, with: .color(.white.opacity(0.35)), lineWidth: 1)

            if let tl = mapping.point(col: 0, row: 0),
               let tr = mapping.point(col: CGFloat(cols), row: 0),
               let br = mapping.point(col: CGFloat(cols), row: CGFloat(rows)),
               let bl = mapping.point(col: 0, row: CGFloat(rows)) {
                var border = Path()
                border.move(to: tl); border.addLine(to: tr)
                border.addLine(to: br); border.addLine(to: bl)
                border.closeSubpath()
                context.stroke(border, with: .color(.white.opacity(0.6)), lineWidth: 1)
            }

            drawAlignmentMarks(in: context)

            for corner in ProjectorCorner.allCases {
                draw(corner: corner, isActive: corner == activeCorner, in: context)
            }
        }
    }

    /// 四条边正中 + 板子正中那几个白记号。缩得跟角标一样多，
    /// 用户是拿它跟孔比对的，缩多了就看不出照没照进孔里。
    private func drawAlignmentMarks(in context: GraphicsContext) {
        let marks = ProjectorAlignmentMarks(cols: mapping.boardCols, rows: mapping.boardRows)
        var path = Path()
        for cell in marks.cells {
            guard let corners = mapping.cellCorners(col: cell.col, row: cell.row,
                                                    inset: Self.markInset)
            else { continue }
            path.move(to: corners[0])
            for point in corners.dropFirst() { path.addLine(to: point) }
            path.closeSubpath()
        }
        context.fill(path, with: .color(.white.opacity(0.9)))
    }

    private func draw(corner: ProjectorCorner, isActive: Bool, in context: GraphicsContext) {
        let arrow = ProjectorCornerArrow(corner: corner,
                                         cols: mapping.boardCols,
                                         rows: mapping.boardRows)
        let color = corner.markColor.opacity(isActive ? 1 : 0.55)
        for cell in arrow.cells {
            // 九格同一个内缩：用户是拿每一块光去比一个孔的，大小一变，「这块没照准」
            // 和「这块本来就该小」就分不开了。缩 0.05 是为了两格之间留条缝，
            // 缩多了反而看不出盖没盖住那个孔。
            guard let corners = mapping.cellCorners(col: cell.col, row: cell.row,
                                                    inset: Self.markInset)
            else { continue }
            var path = Path()
            path.move(to: corners[0])
            for point in corners.dropFirst() { path.addLine(to: point) }
            path.closeSubpath()
            context.fill(path, with: .color(color))
            // 正在调的那个角，拐角那格再描一圈白：四个角标形状一样，光靠颜色深浅，
            // 隔着一米看不出哪个是「现在按微调动的那个」。
            //
            // 描边宽度跟着格子走：一格只有两三个点的时候（大画面 + 小板子），
            // 固定 2 点的白边会往外溢出一整圈，那块光就比一个孔还宽，
            // 「拐角这格盖住一个孔」这个判据当场作废。
            if isActive, cell.distance == 0 {
                context.stroke(path, with: .color(.white.opacity(0.9)),
                               lineWidth: max(0.5, min(2, mapping.averageCellSize * 0.2)))
            }
        }

        // 号写在两条胳膊夹出来那个直角的里面。字号跟着格子走 —— 桌上一块 25cm 的板
        // 在三米宽的画面里只占一小块，固定字号会把整个角标压在底下。
        //
        // 下限只有 8 点：`labelAnchor` 离拐角 5.4 格，一格两三个点的时候，字再大一点
        // 就压到胳膊和拐角上了 —— 而那几块光正是这一屏唯一要看的东西。投影仪打三米宽，
        // 8 点也有一厘米多高，桌边看得清。
        guard let at = mapping.point(col: arrow.labelAnchor.x, row: arrow.labelAnchor.y)
        else { return }
        let size = min(56, max(8, mapping.averageCellSize * 3))
        context.draw(
            context.resolve(
                Text(corner.number)
                    .font(.system(size: isActive ? size : size * 0.75, weight: .bold))
                    .foregroundStyle(color)
            ),
            at: at,
            anchor: .center
        )
    }
}
