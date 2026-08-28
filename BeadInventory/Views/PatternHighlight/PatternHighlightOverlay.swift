//
//  PatternHighlightOverlay.swift
//  BeadInventory
//
//  Canvas 叠层：高亮 + 辅助线
//
//  ## 一格一次绘制会把 App 画死
//
//  第一版是「每一个要亮的格子 fill 一次 + stroke 一次」。零件那么大的网格没问题，
//  整张图纸就不行了：实测一张 220×319 的图纸，点亮一个色号 = 两万次绘制，
//  模拟器上当场 Metal 提交失败、进程被 SIGTRAP 打死（用户看到的是「点一下色号就闪退」）。
//
//  现在做两件事，都不改变画出来的样子：
//
//  - **同一行里连着的格子并成一条**。网格是双线性映射，固定 v 时沿 u 是线性的 ——
//    所以一条 run 的四角就正好是那几格的并集，合并之后一个像素都不差。
//  - **屏幕外的直接不画**。放大之后绝大多数格子在屏幕外，剩下的才是用户在看的。
//
//  两条合起来，绘制次数从「几万」降到「几十条 run 的一次 fill」。
//

import SwiftUI

enum GuideMode: String, CaseIterable {
    case off, five, ten
    var label: String {
        switch self {
        case .off: return String(localized: "关闭辅助线")
        case .five: return String(localized: "每 5 格")
        case .ten: return String(localized: "每 10 格")
        }
    }
    var interval: Int? {
        switch self { case .off: return nil; case .five: return 5; case .ten: return 10 }
    }
}

struct PatternHighlightOverlay: View {
    let grid: BeadPatternGrid
    let highlightedCodes: Set<String>
    let guideMode: GuideMode
    let displayRect: CGRect

    var body: some View {
        Canvas { context, size in
            // 画布之外的东西一律不画。留 4pt 余量，免得边上半格被切掉。
            let visible = CGRect(origin: .zero, size: size).insetBy(dx: -4, dy: -4)

            if !highlightedCodes.isEmpty {
                context.fill(Path(displayRect), with: .color(.black.opacity(0.45)))
                let path = highlightPath(in: visible)
                if !path.isEmpty {
                    context.fill(path, with: .color(.yellow.opacity(0.55)))
                    context.stroke(path, with: .color(.yellow), lineWidth: 1.5)
                }
            }

            if let interval = guideMode.interval {
                for c in stride(from: interval, to: grid.cols, by: interval) {
                    let u = CGFloat(c) / CGFloat(grid.cols)
                    let p1 = GridGeometry.bilinear(u: u, v: 0, corners: grid.corners, in: displayRect)
                    let p2 = GridGeometry.bilinear(u: u, v: 1, corners: grid.corners, in: displayRect)
                    var path = Path()
                    path.move(to: p1); path.addLine(to: p2)
                    context.stroke(path, with: .color(.blue.opacity(0.85)), lineWidth: 1.5)
                }
                for r in stride(from: interval, to: grid.rows, by: interval) {
                    let v = CGFloat(r) / CGFloat(grid.rows)
                    let p1 = GridGeometry.bilinear(u: 0, v: v, corners: grid.corners, in: displayRect)
                    let p2 = GridGeometry.bilinear(u: 1, v: v, corners: grid.corners, in: displayRect)
                    var path = Path()
                    path.move(to: p1); path.addLine(to: p2)
                    context.stroke(path, with: .color(.blue.opacity(0.85)), lineWidth: 1.5)
                }
            }
        }
    }

    /// 要点亮的那些格子，合并成一条 Path。
    private func highlightPath(in visible: CGRect) -> Path {
        var path = Path()
        guard grid.rows > 0, grid.cols > 0 else { return path }
        for row in 0..<min(grid.rows, grid.cellColorCodes.count) {
            let cells = grid.cellColorCodes[row]
            var col = 0
            while col < min(grid.cols, cells.count) {
                guard let code = cells[col], highlightedCodes.contains(code) else {
                    col += 1
                    continue
                }
                // 一直往右吃到不是这一类为止 —— 大片同色是常态，合并之后剩下的 run 很少
                var end = col
                while end + 1 < min(grid.cols, cells.count),
                      let next = cells[end + 1], highlightedCodes.contains(next) {
                    end += 1
                }
                addRun(row: row, from: col, to: end, visible: visible, to: &path)
                col = end + 1
            }
        }
        return path
    }

    private func addRun(row: Int, from: Int, to: Int, visible: CGRect, to path: inout Path) {
        let u0 = CGFloat(from) / CGFloat(grid.cols)
        let u1 = CGFloat(to + 1) / CGFloat(grid.cols)
        let v0 = CGFloat(row) / CGFloat(grid.rows)
        let v1 = CGFloat(row + 1) / CGFloat(grid.rows)
        let tl = GridGeometry.bilinear(u: u0, v: v0, corners: grid.corners, in: displayRect)
        let tr = GridGeometry.bilinear(u: u1, v: v0, corners: grid.corners, in: displayRect)
        let br = GridGeometry.bilinear(u: u1, v: v1, corners: grid.corners, in: displayRect)
        let bl = GridGeometry.bilinear(u: u0, v: v1, corners: grid.corners, in: displayRect)
        let box = CGRect(x: min(tl.x, bl.x), y: min(tl.y, tr.y),
                         width: max(tr.x, br.x) - min(tl.x, bl.x),
                         height: max(bl.y, br.y) - min(tl.y, tr.y))
        guard box.intersects(visible) else { return }
        path.move(to: tl)
        path.addLine(to: tr)
        path.addLine(to: br)
        path.addLine(to: bl)
        path.closeSubpath()
    }
}
