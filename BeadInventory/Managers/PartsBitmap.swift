//
//  PartsBitmap.swift
//  BeadInventory
//
//  多零件模式 - 分析用的位图缓冲 + Lab 查表
//
//  拆零件和提调色板都要「把 ROI 里的像素一个个看一遍」，两边共用这一层：
//  一次解码、一次降采样、一张 Lab 查表，避免同一张图被翻两遍。
//

import UIKit
import CoreGraphics

/// 5 bit/通道量化后的颜色索引空间（32 × 32 × 32）。
/// 拼豆图纸是像素画，同一格内颜色本来就是纯色块，5 bit 完全够分；
/// 好处是可以把 sRGB→Lab 这条带 pow 的转换预先算成 32768 项的表，
/// 之后每个像素只剩一次数组下标 —— 200 万像素也就是几十毫秒的事。
enum QuantizedRGB {
    static let bitsPerChannel = 5
    static let levels = 1 << bitsPerChannel          // 32
    static let count = levels * levels * levels      // 32768

    @inline(__always)
    static func index(r: UInt8, g: UInt8, b: UInt8) -> Int {
        let rq = Int(r) >> (8 - bitsPerChannel)
        let gq = Int(g) >> (8 - bitsPerChannel)
        let bq = Int(b) >> (8 - bitsPerChannel)
        return (rq << (2 * bitsPerChannel)) | (gq << bitsPerChannel) | bq
    }

    /// 量化索引 → 该桶的中心颜色（0~255）
    @inline(__always)
    static func center(of index: Int) -> (r: Double, g: Double, b: Double) {
        let mask = levels - 1
        let rq = (index >> (2 * bitsPerChannel)) & mask
        let gq = (index >> bitsPerChannel) & mask
        let bq = index & mask
        // +0.5 取桶中心，再放大回 0~255
        let step = 256.0 / Double(levels)
        return ((Double(rq) + 0.5) * step,
                (Double(gq) + 0.5) * step,
                (Double(bq) + 0.5) * step)
    }

    static func hex(of index: Int) -> String {
        let c = center(of: index)
        return String(format: "%02X%02X%02X",
                      Int(c.r.rounded()).clampedToByte,
                      Int(c.g.rounded()).clampedToByte,
                      Int(c.b.rounded()).clampedToByte)
    }

    /// 量化桶 → Lab 的静态查表。全表一次算完（32768 次转换，毫秒级），
    /// 之后所有像素查表即可。
    static let labTable: [LabColor] = {
        var table = [LabColor]()
        table.reserveCapacity(count)
        for i in 0..<count {
            let c = center(of: i)
            table.append(GridCellSampler.rgbToLab(c))
        }
        return table
    }()
}

private extension Int {
    var clampedToByte: Int { Swift.max(0, Swift.min(255, self)) }
}

/// 分析用的「工作图」：一张位图 + 它对应整张图纸的哪一块。
///
/// ## 为什么需要这层
///
/// 整张图纸是竖长条，直接按长边压到 2000px，宽度只剩八百多，零件区又只占其中一半 ——
/// 一格豆子最后只有十来个像素，量格子、判色、抠格子全建在这个分辨率上，糊得很明显。
///
/// 所以第一屏（圈零件区）用整张的低清版看个大概就行，从确定零件区开始，
/// 换成**从原图里把零件区裁出来**的高清版：同样的内存预算，全花在真正要看的那块上。
///
/// 全流程的几何量仍然是「相对整张图纸」的归一化坐标（跟 BeadPartsSheet 一致），
/// 由这个类型负责翻译到当前这块图上，调用方不用关心手里拿的是整张还是一块。
struct PartsWorkImage {
    let image: UIImage
    /// `image` 对应整张图纸的哪一块（归一化）。整张图时是单位矩形。
    let region: CGRect

    static func whole(_ image: UIImage) -> PartsWorkImage {
        PartsWorkImage(image: image, region: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// 整张图纸的归一化矩形 → 本工作图内部的归一化矩形
    func localRect(_ whole: CGRect) -> CGRect {
        guard region.width > 0, region.height > 0 else { return .zero }
        return CGRect(
            x: (whole.minX - region.minX) / region.width,
            y: (whole.minY - region.minY) / region.height,
            width: whole.width / region.width,
            height: whole.height / region.height
        )
    }

    /// 本工作图内部的归一化矩形 → 整张图纸的归一化矩形
    func wholeRect(_ local: CGRect) -> CGRect {
        CGRect(
            x: region.minX + local.minX * region.width,
            y: region.minY + local.minY * region.height,
            width: local.width * region.width,
            height: local.height * region.height
        )
    }

    /// 一格在这张工作图上大约有多少像素 —— 用来判断分辨率够不够
    func pixels(forNormalizedWidth width: Double) -> Double {
        guard region.width > 0 else { return 0 }
        return width / Double(region.width) * Double(image.size.width)
    }
}

/// 图纸某个区域的降采样位图，逐像素带一个量化颜色索引。
struct PartsBitmap {
    /// 工作分辨率下的宽高
    let width: Int
    let height: Int
    /// 每个像素的 `QuantizedRGB` 索引，长度 = width * height
    let quantized: [Int32]
    /// 本位图对应源图里的哪一块（归一化）
    let roi: CGRect

    var pixelCount: Int { width * height }

    @inline(__always)
    func lab(at i: Int) -> LabColor {
        QuantizedRGB.labTable[Int(quantized[i])]
    }

    /// 把本位图内的坐标翻译成整张源图的归一化坐标
    @inline(__always)
    func normalizedPoint(x: Int, y: Int) -> CGPoint {
        CGPoint(x: roi.minX + (CGFloat(x) / CGFloat(max(width, 1))) * roi.width,
                y: roi.minY + (CGFloat(y) / CGFloat(max(height, 1))) * roi.height)
    }

    /// 把本位图内的矩形翻译成整张源图的归一化矩形
    func normalizedRect(x: Int, y: Int, w: Int, h: Int) -> CGRect {
        let tl = normalizedPoint(x: x, y: y)
        let br = normalizedPoint(x: x + w, y: y + h)
        return CGRect(x: tl.x, y: tl.y, width: br.x - tl.x, height: br.y - tl.y)
    }

    /// 反向：源图归一化矩形 → 本位图内的像素矩形（截断到边界内）
    func pixelRect(forNormalized rect: CGRect) -> (x: Int, y: Int, w: Int, h: Int) {
        guard roi.width > 0, roi.height > 0 else { return (0, 0, 0, 0) }
        let x0 = Int(((rect.minX - roi.minX) / roi.width * CGFloat(width)).rounded(.down))
        let y0 = Int(((rect.minY - roi.minY) / roi.height * CGFloat(height)).rounded(.down))
        let x1 = Int(((rect.maxX - roi.minX) / roi.width * CGFloat(width)).rounded(.up))
        let y1 = Int(((rect.maxY - roi.minY) / roi.height * CGFloat(height)).rounded(.up))
        let cx0 = max(0, min(width, x0))
        let cy0 = max(0, min(height, y0))
        let cx1 = max(cx0, min(width, x1))
        let cy1 = max(cy0, min(height, y1))
        return (cx0, cy0, cx1 - cx0, cy1 - cy0)
    }

    // MARK: - 构建

    /// 从工作图 + 归一化 ROI（**相对整张图纸**）造位图。
    ///
    /// - Parameter maxPixels: 工作分辨率上限。超过就等比缩小 —— 内存和耗时是平方级省下来的。
    /// - Returns: ROI 太小或解码失败时返回 nil。
    static func make(from work: PartsWorkImage, roi wholeROI: CGRect, maxPixels: Int) -> PartsBitmap? {
        let local = work.localRect(wholeROI)
        guard let bitmap = make(from: work.image, localROI: local, maxPixels: maxPixels) else { return nil }
        // 位图自己记的 roi 要换算回「相对整张图纸」，下游的几何计算才对得上
        return PartsBitmap(
            width: bitmap.width, height: bitmap.height,
            quantized: bitmap.quantized,
            roi: work.wholeRect(bitmap.roi)
        )
    }

    private static func make(from image: UIImage, localROI roi: CGRect, maxPixels: Int) -> PartsBitmap? {
        guard let cg = image.cgImage else { return nil }
        let fullPixels = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        let roiPixels = CGRect(
            x: roi.minX * CGFloat(cg.width),
            y: roi.minY * CGFloat(cg.height),
            width: roi.width * CGFloat(cg.width),
            height: roi.height * CGFloat(cg.height)
        ).intersection(fullPixels).integral

        guard roiPixels.width >= 8, roiPixels.height >= 8,
              let cropped = cg.cropping(to: roiPixels) else { return nil }

        let srcW = cropped.width
        let srcH = cropped.height
        let scale = min(1.0, (Double(maxPixels) / Double(srcW * srcH)).squareRoot())
        let w = max(8, Int((Double(srcW) * scale).rounded()))
        let h = max(8, Int((Double(srcH) * scale).rounded()))

        let bytesPerRow = w * 4
        var raw = [UInt8](repeating: 0, count: bytesPerRow * h)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let drawn: Bool = raw.withUnsafeMutableBytes { buf -> Bool in
            guard let base = buf.baseAddress,
                  let ctx = CGContext(
                    data: base, width: w, height: h,
                    bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo
                  ) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        var quantized = [Int32](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let o = i * 4
            quantized[i] = Int32(QuantizedRGB.index(r: raw[o], g: raw[o + 1], b: raw[o + 2]))
        }

        // 用实际落到 ROI 的整数像素矩形回算归一化 ROI —— 上面 `.integral` 会取整，
        // 直接沿用调用方传进来的 roi 会有半像素级的系统偏移，标定格子时会被放大。
        let actualROI = CGRect(
            x: roiPixels.minX / CGFloat(cg.width),
            y: roiPixels.minY / CGFloat(cg.height),
            width: roiPixels.width / CGFloat(cg.width),
            height: roiPixels.height / CGFloat(cg.height)
        )
        return PartsBitmap(width: w, height: h, quantized: quantized, roi: actualROI)
    }
}
