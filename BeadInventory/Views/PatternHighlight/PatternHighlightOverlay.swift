//
//  PatternHighlightOverlay.swift
//  BeadInventory
//
//  Canvas 叠层：高亮 + 辅助线
//

import SwiftUI

enum GuideMode: String, CaseIterable {
    case off, five, ten
    var label: String {
        switch self {
        case .off: return "关闭辅助线"
        case .five: return "每 5 格"
        case .ten: return "每 10 格"
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
        Canvas { context, _ in
            if !highlightedCodes.isEmpty {
                context.fill(Path(displayRect), with: .color(.black.opacity(0.45)))
                for row in 0..<grid.rows {
                    for col in 0..<grid.cols {
                        guard let code = grid.cellColorCodes[row][col],
                              highlightedCodes.contains(code) else { continue }
                        let (tl, tr, br, bl) = GridGeometry.cellQuad(
                            row: row, col: col, rows: grid.rows, cols: grid.cols,
                            corners: grid.corners, in: displayRect
                        )
                        var path = Path()
                        path.move(to: tl); path.addLine(to: tr)
                        path.addLine(to: br); path.addLine(to: bl)
                        path.closeSubpath()
                        context.fill(path, with: .color(.yellow.opacity(0.55)))
                        context.stroke(path, with: .color(.yellow), lineWidth: 1.5)
                    }
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
}
