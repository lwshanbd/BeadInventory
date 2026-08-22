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
//  ## 亮的格子为什么不用豆子本来的颜色
//
//  投影是加光：黑色豆子的颜色投出来就是不出光，那一格跟没亮一样 —— 而黑色恰恰是
//  用得最多的色号之一。深蓝、墨绿同理。所以这里把色号的颜色**提到最亮**（保住色相，
//  顺手压一点饱和度，因为纯色越饱和投出来越暗）：黑色变成白光，深蓝变成亮蓝。
//
//  代价是**亮度这一维整个丢了**：黑、白、所有灰阶都会投成同一个白，同色相的深浅两色
//  （深红/亮红）也会撞在一起。同时点亮两个这样的色号时，用户只能靠位置区分。
//  真要分开得再引入亮度以外的编码（比如给第二个色号加描边或点阵），现在故意不做 ——
//  一次抓一把豆子拼一个色号才是常态。
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
            context.fill(path, with: .color(Self.projected(colorCache[key])))
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

    /// 色号的颜色 → 投出来看得见的那个颜色（理由见文件头）。
    /// 查不到色号时给白光：这一格用户照样要按豆子，不能因为图例里少一条就不亮。
    static func projected(_ color: Color?) -> Color {
        guard let color else { return .white }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(color).getHue(&hue, saturation: &saturation,
                                    brightness: &brightness, alpha: &alpha) else { return .white }
        return Color(hue: hue, saturation: min(saturation, 0.6), brightness: 1, opacity: 1)
    }
}

// MARK: - 校准时画在外屏上的东西

/// 四个角标 + 一层稀疏的辅助线。**只在用户开着校准页时画**。
///
/// 四个角各是一种颜色（`ProjectorCorner.markColor`，手机上用的是同一套）：用户站在
/// 桌边、手机在手上，四个角长得一样的话他会把正在调的那个搞错。正在调的那个画得更粗。
///
/// 辅助线每 10 格一条：四个角对上了不代表中间也对上 —— 理论上平面透视保证中间自动对齐，
/// 但投影仪镜头本身有畸变、桌面也可能不平。中间几条线落在豆板的孔上，用户扫一眼
/// 就知道这次对得准不准，不用等拼到一半才发现。
struct ProjectorCalibrationMarks: View {
    let mapping: ProjectorMapping
    let activeCorner: ProjectorCorner

    var body: some View {
        Canvas { context, _ in
            let cols = mapping.boardCols, rows = mapping.boardRows
            guard let tl = mapping.point(col: 0, row: 0),
                  let tr = mapping.point(col: CGFloat(cols), row: 0),
                  let br = mapping.point(col: CGFloat(cols), row: CGFloat(rows)),
                  let bl = mapping.point(col: 0, row: CGFloat(rows)) else { return }

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

            var border = Path()
            border.move(to: tl); border.addLine(to: tr)
            border.addLine(to: br); border.addLine(to: bl)
            border.closeSubpath()
            context.stroke(border, with: .color(.white.opacity(0.6)), lineWidth: 1)

            let corners: [(ProjectorCorner, CGPoint, CGPoint, CGPoint)] = [
                (.topLeft, tl, tr, bl),
                (.topRight, tr, br, tl),
                (.bottomRight, br, bl, tr),
                (.bottomLeft, bl, tl, br)
            ]
            let center = CGPoint(x: (tl.x + tr.x + br.x + bl.x) / 4,
                                 y: (tl.y + tr.y + br.y + bl.y) / 4)
            for (corner, point, next, previous) in corners {
                let isActive = corner == activeCorner
                var bracket = Path()
                bracket.move(to: interpolate(from: point, to: previous, fraction: 0.14))
                bracket.addLine(to: point)
                bracket.addLine(to: interpolate(from: point, to: next, fraction: 0.14))
                context.stroke(bracket, with: .color(corner.markColor),
                               lineWidth: isActive ? 10 : 5)

                // 号写在角往里一点的地方：写在角上就压在用户正要对齐的那条线上了
                context.draw(
                    context.resolve(
                        Text(corner.number)
                            .font(.system(size: isActive ? 52 : 38, weight: .bold))
                            .foregroundStyle(corner.markColor)
                    ),
                    at: interpolate(from: point, to: center, fraction: 0.09),
                    anchor: .center
                )
            }
        }
    }

    private func interpolate(from: CGPoint, to: CGPoint, fraction: CGFloat) -> CGPoint {
        CGPoint(x: from.x + (to.x - from.x) * fraction, y: from.y + (to.y - from.y) * fraction)
    }
}
