//
//  GridCellSampler.swift
//  BeadInventory
//
//  拼图模式 - 给定 grid + UIImage，采样每格 → 投票匹配到 BeadColor。
//

import UIKit
import CoreGraphics

/// CIE Lab 颜色（D65）
struct LabColor: Equatable {
    let l: Double
    let a: Double
    let b: Double
}

/// 一个格子的采样结果
struct CellSampleResult {
    let avgLab: LabColor?       // 8 个采样点的平均颜色（采样失败时 nil）
    let matchedCode: String?    // ΔE 匹配到的色号；超过阈值返回 nil
}

final class GridCellSampler {
    static let shared = GridCellSampler()
    private init() {}

    /// 单像素匹配 ΔE 阈值。
    private let perPixelDeltaE: Double = 30.0

    /// 采样位置（8 点，避开中心文字 + 格边网格线）
    private let sampleUVs: [(CGFloat, CGFloat)] = [
        (0.20, 0.20), (0.50, 0.20), (0.80, 0.20),
        (0.20, 0.50),               (0.80, 0.50),
        (0.20, 0.80), (0.50, 0.80), (0.80, 0.80),
    ]

    /// 简单版：只返回色号矩阵（保留旧调用方）
    func sample(image: UIImage,
                grid: BeadPatternGrid,
                availableColors: [BeadColor],
                allowedCodes: Set<String>? = nil) -> [[String?]] {
        sampleDetailed(image: image, grid: grid,
                       availableColors: availableColors,
                       allowedCodes: allowedCodes)
            .map { row in row.map { $0.matchedCode } }
    }

    /// 详细版：每格返回 avg Lab + matched code，供下游做交叉校验
    func sampleDetailed(image: UIImage,
                        grid: BeadPatternGrid,
                        availableColors: [BeadColor],
                        allowedCodes: Set<String>? = nil) -> [[CellSampleResult]] {
        let empty: [[CellSampleResult]] = Array(
            repeating: Array(repeating: CellSampleResult(avgLab: nil, matchedCode: nil),
                             count: grid.cols),
            count: grid.rows
        )
        guard let cgImage = image.cgImage else { return empty }
        guard let normalized = normalizeToRGBA8(cgImage: cgImage) else { return empty }

        let width = normalized.width
        let height = normalized.height
        let imageRect = CGRect(x: 0, y: 0, width: width, height: height)

        // 候选色号 + Lab
        let candidateColors: [BeadColor]
        if let allowed = allowedCodes, !allowed.isEmpty {
            candidateColors = availableColors.filter {
                allowed.contains($0.displayCode(for: grid.colorSystem))
            }
        } else {
            candidateColors = availableColors
        }

        let labCache: [(code: String, lab: LabColor)] = candidateColors.compactMap { color in
            guard color.hasCode(for: grid.colorSystem),
                  let lab = GridCellSampler.lab(forHex: color.colorHex) else { return nil }
            return (color.displayCode(for: grid.colorSystem), lab)
        }

        guard !labCache.isEmpty else { return empty }

        guard let provider = normalized.dataProvider,
              let data = provider.data,
              let bytes = CFDataGetBytePtr(data) else {
            return empty
        }
        let bytesPerPixel = 4
        let bytesPerRow = normalized.bytesPerRow

        var result = empty

        for row in 0..<grid.rows {
            for col in 0..<grid.cols {
                let (tl, tr, br, bl) = GridGeometry.cellQuad(
                    row: row, col: col, rows: grid.rows, cols: grid.cols,
                    corners: grid.corners, in: imageRect
                )

                // 收集采样点的 RGB 平均 + 每点投票
                var rSum = 0.0, gSum = 0.0, bSum = 0.0
                var validSamples = 0
                var votes: [String: Int] = [:]
                for (u, v) in sampleUVs {
                    let p = interpolateQuad(tl: tl, tr: tr, br: br, bl: bl, u: u, v: v)
                    let px = Int(p.x.rounded())
                    let py = Int(p.y.rounded())
                    guard px >= 0, px < width, py >= 0, py < height else { continue }
                    let offset = py * bytesPerRow + px * bytesPerPixel
                    let r = Double(bytes[offset])
                    let g = Double(bytes[offset + 1])
                    let b = Double(bytes[offset + 2])
                    rSum += r; gSum += g; bSum += b
                    validSamples += 1

                    let lab = GridCellSampler.rgbToLab((r: r, g: g, b: b))
                    var bestCode: String? = nil
                    var bestDE = Double.infinity
                    for (code, refLab) in labCache {
                        let de = GridCellSampler.deltaE(lab, refLab)
                        if de < bestDE { bestDE = de; bestCode = code }
                    }
                    if let code = bestCode, bestDE <= perPixelDeltaE {
                        votes[code, default: 0] += 1
                    }
                }

                guard validSamples > 0 else { continue }
                let avgRGB = (
                    r: rSum / Double(validSamples),
                    g: gSum / Double(validSamples),
                    b: bSum / Double(validSamples)
                )
                let avgLab = GridCellSampler.rgbToLab(avgRGB)

                let winner = votes.max(by: { $0.value < $1.value })
                let matchedCode = (winner?.value ?? 0) >= 2 ? winner?.key : nil

                result[row][col] = CellSampleResult(avgLab: avgLab, matchedCode: matchedCode)
            }
        }
        return result
    }

    // MARK: - 静态辅助（saveAndContinue 跨模块用 OCR 校验时调用）

    /// 从 hex 字符串（带或不带 #）算 Lab
    static func lab(forHex hex: String) -> LabColor? {
        guard let rgb = rgbFromHex(hex) else { return nil }
        return rgbToLab(rgb)
    }

    /// Lab ΔE 欧氏距离
    static func deltaE(_ a: LabColor, _ b: LabColor) -> Double {
        let dl = a.l - b.l, da = a.a - b.a, db = a.b - b.b
        return sqrt(dl * dl + da * da + db * db)
    }

    static func rgbFromHex(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var s = hex.uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF), Double((v >> 8) & 0xFF), Double(v & 0xFF))
    }

    /// sRGB (0~255) → CIE Lab (D65)
    static func rgbToLab(_ rgb: (r: Double, g: Double, b: Double)) -> LabColor {
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
        return LabColor(l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }

    // MARK: - 内部

    private func normalizeToRGBA8(cgImage: CGImage) -> CGImage? {
        let width = cgImage.width
        let height = cgImage.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue |
            CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: bitmapInfo
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
}
