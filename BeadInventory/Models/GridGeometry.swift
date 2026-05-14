//
//  GridGeometry.swift
//  BeadInventory
//
//  拼图模式 - 网格几何工具：4 角四边形 + 行列数 → 每格 4 顶点（bilinear）
//

import Foundation
import CoreGraphics

enum GridGeometry {
    /// 给定 4 角和 (rows, cols) 行列数，计算单元格 (row, col) 的 4 个顶点。
    /// 4 个角点构成任意四边形（允许梯形/轻微透视），不要求矩形。
    /// 返回顺序：topLeft, topRight, bottomRight, bottomLeft（CCW from TL）。
    static func cellQuad(row: Int, col: Int,
                         rows: Int, cols: Int,
                         corners: GridCorners,
                         in displayRect: CGRect) -> (CGPoint, CGPoint, CGPoint, CGPoint) {
        let u0 = CGFloat(col) / CGFloat(cols)
        let u1 = CGFloat(col + 1) / CGFloat(cols)
        let v0 = CGFloat(row) / CGFloat(rows)
        let v1 = CGFloat(row + 1) / CGFloat(rows)

        let tl = bilinear(u: u0, v: v0, corners: corners, in: displayRect)
        let tr = bilinear(u: u1, v: v0, corners: corners, in: displayRect)
        let br = bilinear(u: u1, v: v1, corners: corners, in: displayRect)
        let bl = bilinear(u: u0, v: v1, corners: corners, in: displayRect)

        return (tl, tr, br, bl)
    }

    /// 给定归一化 (u, v) 和 4 角四边形，返回在 displayRect 内的实际坐标。
    /// (u, v) ∈ [0, 1]，(0, 0) = topLeft, (1, 1) = bottomRight
    static func bilinear(u: CGFloat, v: CGFloat,
                         corners: GridCorners,
                         in displayRect: CGRect) -> CGPoint {
        let tl = denormalize(corners.topLeft, in: displayRect)
        let tr = denormalize(corners.topRight, in: displayRect)
        let bl = denormalize(corners.bottomLeft, in: displayRect)
        let br = denormalize(corners.bottomRight, in: displayRect)

        let top = lerp(tl, tr, u)
        let bottom = lerp(bl, br, u)
        return lerp(top, bottom, v)
    }

    /// 将归一化坐标 (0~1) 转为 displayRect 内绝对坐标。
    static func denormalize(_ p: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + p.x * rect.width,
                y: rect.minY + p.y * rect.height)
    }

    /// 将 displayRect 内绝对坐标转为归一化坐标 (0~1)。
    static func normalize(_ p: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: (p.x - rect.minX) / max(rect.width, 1),
                y: (p.y - rect.minY) / max(rect.height, 1))
    }

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t,
                y: a.y + (b.y - a.y) * t)
    }
}
