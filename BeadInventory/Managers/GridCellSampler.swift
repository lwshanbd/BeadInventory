//
//  GridCellSampler.swift
//  BeadInventory
//
//  拼图模式 - 给定 grid + UIImage，采样每格中心区域 → 匹配最近 BeadColor。
//

import UIKit
import CoreGraphics

final class GridCellSampler {
    static let shared = GridCellSampler()
    private init() {}

    /// 色匹配 ΔE 阈值。> 阈值视为未匹配（返回 nil）。
    private let deltaEThreshold: Double = 18.0

    /// 每格采样每边 N，总 N×N 像素。
    private let samplesPerCellSide: Int = 5

    /// 采样所有格子。返回 [row][col] 色号矩阵（nil = 未匹配）。
    func sample(image: UIImage,
                grid: BeadPatternGrid,
                availableColors: [BeadColor]) -> [[String?]] {
        let emptyResult: [[String?]] = Array(
            repeating: Array(repeating: nil, count: grid.cols), count: grid.rows
        )
        guard let cgImage = image.cgImage else { return emptyResult }

        // 标准化为 RGBA8 位图，避免不同 colorSpace 像素布局差异
        guard let normalized = normalizeToRGBA8(cgImage: cgImage) else { return emptyResult }
        let width = normalized.width
        let height = normalized.height
        let imageRect = CGRect(x: 0, y: 0, width: width, height: height)

        // 提前算可匹配色的 Lab
        let labCache: [(code: String, lab: (l: Double, a: Double, b: Double))] = availableColors.compactMap { color in
            guard color.hasCode(for: grid.colorSystem),
                  let rgb = rgbFromHex(color.colorHex) else { return nil }
            return (color.displayCode(for: grid.colorSystem), rgbToLab(rgb))
        }

        guard !labCache.isEmpty else { return emptyResult }

        // 取像素数据
        guard let provider = normalized.dataProvider,
              let data = provider.data,
              let bytes = CFDataGetBytePtr(data) else {
            return emptyResult
        }
        let bytesPerPixel = 4  // RGBA8
        let bytesPerRow = normalized.bytesPerRow

        var result: [[String?]] = emptyResult

        for row in 0..<grid.rows {
            for col in 0..<grid.cols {
                let (tl, tr, br, bl) = GridGeometry.cellQuad(
                    row: row, col: col, rows: grid.rows, cols: grid.cols,
                    corners: grid.corners, in: imageRect
                )

                // 取中心 60% 区域：(u, v) ∈ [0.2, 0.8] 范围均匀采样
                var rSum = 0.0, gSum = 0.0, bSum = 0.0
                var samples = 0
                let n = samplesPerCellSide
                for i in 0..<n {
                    for j in 0..<n {
                        let u = 0.2 + 0.6 * (CGFloat(i) + 0.5) / CGFloat(n)
                        let v = 0.2 + 0.6 * (CGFloat(j) + 0.5) / CGFloat(n)
                        let p = interpolateQuad(tl: tl, tr: tr, br: br, bl: bl, u: u, v: v)
                        let px = Int(p.x.rounded())
                        let py = Int(p.y.rounded())
                        guard px >= 0, px < width, py >= 0, py < height else { continue }
                        let offset = py * bytesPerRow + px * bytesPerPixel
                        rSum += Double(bytes[offset])
                        gSum += Double(bytes[offset + 1])
                        bSum += Double(bytes[offset + 2])
                        samples += 1
                    }
                }
                guard samples > 0 else { continue }
                let avgRGB = (
                    r: rSum / Double(samples),
                    g: gSum / Double(samples),
                    b: bSum / Double(samples)
                )
                let avgLab = rgbToLab(avgRGB)

                var bestCode: String? = nil
                var bestDeltaE = Double.infinity
                for (code, lab) in labCache {
                    let de = deltaE(a: avgLab, b: lab)
                    if de < bestDeltaE {
                        bestDeltaE = de
                        bestCode = code
                    }
                }
                if bestDeltaE <= deltaEThreshold {
                    result[row][col] = bestCode
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
