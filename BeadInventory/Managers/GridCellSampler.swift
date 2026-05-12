//
//  GridCellSampler.swift
//  BeadInventory
//
//  拼图模式 - 给定 grid + UIImage，采样每格 → 投票匹配到 BeadColor。
//
//  策略：
//  - 采样位置：避开格子中心（图纸文字在中心），采 8 个位于格内 [15%, 85%] 但
//    避开中央 [35%, 65%] 区域的点。
//  - 每个像素独立分类到最近 BeadColor（Lab ΔE），低于阈值的票数 +1。
//  - 取格内投票最多的色号；若没有任何像素超过阈值，返回 nil（未匹配）。
//  - 候选集：优先用 allowedCodes 限定到图例里出现过的色号——
//    既加速也避免误匹配到八竿子打不着的色号。
//

import UIKit
import CoreGraphics

final class GridCellSampler {
    static let shared = GridCellSampler()
    private init() {}

    /// 单像素匹配 ΔE 阈值。超过此值视为该像素不可信。
    private let perPixelDeltaE: Double = 30.0

    /// 采样位置（8 个点，避开中心文字区域，避开格边网格线）
    private let sampleUVs: [(CGFloat, CGFloat)] = [
        (0.20, 0.20), (0.50, 0.20), (0.80, 0.20),
        (0.20, 0.50),               (0.80, 0.50),
        (0.20, 0.80), (0.50, 0.80), (0.80, 0.80),
    ]

    /// 采样所有格子。
    /// - allowedCodes: 若非 nil，匹配候选集只在该集合内（推荐：项目 beadUsage 出现的色号）
    func sample(image: UIImage,
                grid: BeadPatternGrid,
                availableColors: [BeadColor],
                allowedCodes: Set<String>? = nil) -> [[String?]] {
        let emptyResult: [[String?]] = Array(
            repeating: Array(repeating: nil, count: grid.cols), count: grid.rows
        )
        guard let cgImage = image.cgImage else { return emptyResult }

        guard let normalized = normalizeToRGBA8(cgImage: cgImage) else { return emptyResult }
        let width = normalized.width
        let height = normalized.height
        let imageRect = CGRect(x: 0, y: 0, width: width, height: height)

        // 候选色号 + Lab。优先用 allowedCodes 限定。
        let candidateColors: [BeadColor]
        if let allowed = allowedCodes, !allowed.isEmpty {
            candidateColors = availableColors.filter {
                allowed.contains($0.displayCode(for: grid.colorSystem))
            }
        } else {
            candidateColors = availableColors
        }

        let labCache: [(code: String, lab: (l: Double, a: Double, b: Double))] = candidateColors.compactMap { color in
            guard color.hasCode(for: grid.colorSystem),
                  let rgb = rgbFromHex(color.colorHex) else { return nil }
            return (color.displayCode(for: grid.colorSystem), rgbToLab(rgb))
        }

        guard !labCache.isEmpty else { return emptyResult }

        guard let provider = normalized.dataProvider,
              let data = provider.data,
              let bytes = CFDataGetBytePtr(data) else {
            return emptyResult
        }
        let bytesPerPixel = 4
        let bytesPerRow = normalized.bytesPerRow

        var result: [[String?]] = emptyResult

        for row in 0..<grid.rows {
            for col in 0..<grid.cols {
                let (tl, tr, br, bl) = GridGeometry.cellQuad(
                    row: row, col: col, rows: grid.rows, cols: grid.cols,
                    corners: grid.corners, in: imageRect
                )

                // 8 个采样点 → 各分类 → 投票
                var votes: [String: Int] = [:]
                for (u, v) in sampleUVs {
                    let p = interpolateQuad(tl: tl, tr: tr, br: br, bl: bl, u: u, v: v)
                    let px = Int(p.x.rounded())
                    let py = Int(p.y.rounded())
                    guard px >= 0, px < width, py >= 0, py < height else { continue }
                    let offset = py * bytesPerRow + px * bytesPerPixel
                    let rgb = (
                        r: Double(bytes[offset]),
                        g: Double(bytes[offset + 1]),
                        b: Double(bytes[offset + 2])
                    )
                    let lab = rgbToLab(rgb)

                    var bestCode: String? = nil
                    var bestDE = Double.infinity
                    for (code, refLab) in labCache {
                        let de = deltaE(a: lab, b: refLab)
                        if de < bestDE {
                            bestDE = de
                            bestCode = code
                        }
                    }
                    if let code = bestCode, bestDE <= perPixelDeltaE {
                        votes[code, default: 0] += 1
                    }
                }

                // 取得票最多的，至少需要 2 票（>= 25% of 8 samples）才算可信
                if let winner = votes.max(by: { $0.value < $1.value }),
                   winner.value >= 2 {
                    result[row][col] = winner.key
                }
            }
        }
        return result
    }

    // MARK: - 工具

    private func normalizeToRGBA8(cgImage: CGImage) -> CGImage? {
        let width = cgImage.width
        let height = cgImage.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue |
            CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func interpolateQuad(tl: CGPoint, tr: CGPoint, br: CGPoint, bl: CGPoint,
                                  u: CGFloat, v: CGFloat) -> CGPoint {
        let top = CGPoint(x: tl.x + (tr.x - tl.x) * u, y: tl.y + (tr.y - tl.y) * u)
        let bot = CGPoint(x: bl.x + (br.x - bl.x) * u, y: bl.y + (br.y - bl.y) * u)
        return CGPoint(x: top.x + (bot.x - top.x) * v, y: top.y + (bot.y - top.y) * v)
    }

    private func rgbFromHex(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var s = hex.uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF), Double((v >> 8) & 0xFF), Double(v & 0xFF))
    }

    /// sRGB (0~255) → CIE Lab (D65)
    private func rgbToLab(_ rgb: (r: Double, g: Double, b: Double)) -> (l: Double, a: Double, b: Double) {
        func srgb(_ c: Double) -> Double {
            let cc = c / 255.0
            return cc <= 0.04045 ? cc / 12.92 : pow((cc + 0.055) / 1.055, 2.4)
        }
        let r = srgb(rgb.r), g = srgb(rgb.g), b = srgb(rgb.b)
        let x = r * 0.4124564 + g * 0.3575761 + b * 0.1804375
        let y = r * 0.2126729 + g * 0.7151522 + b * 0.0721750
        let z = r * 0.0193339 + g * 0.1191920 + b * 0.9503041
        let xn = 0.95047, yn = 1.0, zn = 1.08883
        func f(_ t: Double) -> Double {
            t > 216.0 / 24389.0 ? pow(t, 1.0/3.0) : (24389.0/27.0 * t + 16.0) / 116.0
        }
        let fx = f(x / xn), fy = f(y / yn), fz = f(z / zn)
        return (l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }

    private func deltaE(a: (l: Double, a: Double, b: Double),
                        b: (l: Double, a: Double, b: Double)) -> Double {
        let dl = a.l - b.l, da = a.a - b.a, db = a.b - b.b
        return sqrt(dl * dl + da * da + db * db)
    }
}
