//
//  GridOCRSampler.swift
//  BeadInventory
//
//  拼图模式 - 用 Apple Vision OCR 识别格子里的色号文字。
//  整图一次 OCR，按 bounding box 映射回格子；只有当识别文字命中图例色号时才采纳。
//

import UIKit
import Vision

/// 拼图模式诊断日志，仅 DEBUG 编译输出。Release 包里 644 格 OCR 不再打满 console。
@inline(__always)
private func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}

final class GridOCRSampler {
    static let shared = GridOCRSampler()
    private init() {}

    /// 对所有格子做 per-cell OCR。
    /// 跳过整图 OCR——满是小字的图整图 OCR 慢得离谱，每格裁出来跑反而快。
    /// - cellLabs: 每格的 avg Lab（来自颜色采样），用于 OCR 多候选时按颜色 disambig
    /// - codeToLab: 色号 → Lab 查询表
    /// - progress: (已完成数, 总数)
    func sampleAllCellsPerCell(image: UIImage,
                                grid: BeadPatternGrid,
                                allowedCodes: Set<String>,
                                cellLabs: [[LabColor?]]? = nil,
                                codeToLab: [String: LabColor]? = nil,
                                progress: ((Int, Int) -> Void)? = nil) async -> [[String?]] {
        let empty: [[String?]] = Array(
            repeating: Array(repeating: nil, count: grid.cols), count: grid.rows
        )
        guard let cgImage = image.cgImage, !allowedCodes.isEmpty else { return empty }

        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)

        var allCells: [(row: Int, col: Int)] = []
        for r in 0..<grid.rows {
            for c in 0..<grid.cols {
                allCells.append((r, c))
            }
        }

        var result = empty
        var completed = 0
        let total = allCells.count

        debugLog("[OCRGroup] dispatching \(total) cells with concurrency 4")
        await withTaskGroup(of: (Int, Int, String?).self) { group in
            var inFlight = 0
            let maxConcurrent = 4   // Vision 内部可能有锁，4 比 8 稳
            for pos in allCells {
                if inFlight >= maxConcurrent {
                    if let done = await group.next() {
                        result[done.0][done.1] = done.2
                        completed += 1
                        progress?(completed, total)
                        inFlight -= 1
                    }
                }
                let cellLab = cellLabs?[pos.row][pos.col]
                group.addTask {
                    let code = Self.ocrSingleCell(
                        cgImage: cgImage,
                        row: pos.row, col: pos.col,
                        grid: grid,
                        imageWidth: imageWidth,
                        imageHeight: imageHeight,
                        allowedCodes: allowedCodes,
                        cellAvgLab: cellLab,
                        codeToLab: codeToLab
                    )
                    return (pos.row, pos.col, code)
                }
                inFlight += 1
            }
            debugLog("[OCRGroup] all dispatched; awaiting remaining \(inFlight)")
            for await done in group {
                result[done.0][done.1] = done.2
                completed += 1
                progress?(completed, total)
            }
        }
        debugLog("[OCRGroup] all done; total=\(total) matched=\(result.flatMap { $0 }.compactMap { $0 }.count)")

        return result
    }

    /// 对单个格子做 OCR：裁剪图像 + 跑 VNRecognizeTextRequest + 文字匹配。
    /// 如果 OCR top 候选中有多个命中图例的色号（典型 E2/E3 这种 1 字符差），
    /// 用 cellAvgLab + codeToLab 按颜色距离选最近的。
    static func ocrSingleCell(cgImage: CGImage,
                              row: Int, col: Int,
                              grid: BeadPatternGrid,
                              imageWidth: CGFloat,
                              imageHeight: CGFloat,
                              allowedCodes: Set<String>,
                              cellAvgLab: LabColor? = nil,
                              codeToLab: [String: LabColor]? = nil) -> String? {
        let cellStart = Date()
        let tlx = grid.corners.topLeft.x * imageWidth
        let tly = grid.corners.topLeft.y * imageHeight
        let brx = grid.corners.bottomRight.x * imageWidth
        let bry = grid.corners.bottomRight.y * imageHeight
        let cellW = (brx - tlx) / CGFloat(grid.cols)
        let cellH = (bry - tly) / CGFloat(grid.rows)
        let margin: CGFloat = 0.1
        let x = tlx + CGFloat(col) * cellW - cellW * margin
        let y = tly + CGFloat(row) * cellH - cellH * margin
        let w = cellW * (1 + 2 * margin)
        let h = cellH * (1 + 2 * margin)
        let rect = CGRect(
            x: max(0, x), y: max(0, y),
            width: min(imageWidth - max(0, x), w),
            height: min(imageHeight - max(0, y), h)
        )
        guard rect.width > 4, rect.height > 4,
              let cropped = cgImage.cropping(to: rect) else {
            debugLog("[OCR] cell(\(row),\(col)) SKIP rect=\(rect)")
            return nil
        }

        // 2× 上采样后再送 OCR：Vision 在更大文字上识别准确率显著更高。
        // 原图每格约 140×175，上采样到 280×350，文字从 ~30px 变 ~60px，
        // "2" 和 "3" 的曲线/拐角差异更清晰。
        let ocrInput = Self.upscale(cropped, factor: 2.0) ?? cropped

        debugLog("[OCR] cell(\(row),\(col)) START crop=\(Int(rect.width))x\(Int(rect.height)) → \(ocrInput.width)x\(ocrInput.height)")

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate   // per-cell 小裁剪用 accurate，更准且不会卡
        request.usesLanguageCorrection = false
        request.customWords = Array(allowedCodes)

        let handler = VNImageRequestHandler(cgImage: ocrInput, options: [:])
        do {
            try handler.perform([request])
        } catch {
            let ms = Int(Date().timeIntervalSince(cellStart) * 1000)
            debugLog("[OCR] cell(\(row),\(col)) ERROR \(ms)ms: \(error.localizedDescription)")
            return nil
        }

        // 收集所有命中图例的候选，按色号去重（保留各色号最高置信度）
        var bestConfByCode: [String: Float] = [:]
        var rawText: String = ""
        if let observations = request.results {
            for obs in observations {
                for candidate in obs.topCandidates(5) {
                    if rawText.isEmpty { rawText = candidate.string }
                    if let code = matchLegendCode(text: candidate.string, allowed: allowedCodes) {
                        let prev = bestConfByCode[code] ?? 0
                        if candidate.confidence > prev {
                            bestConfByCode[code] = candidate.confidence
                        }
                    }
                }
            }
        }

        let matched: String?
        if bestConfByCode.isEmpty {
            matched = nil
        } else if bestConfByCode.count == 1 {
            matched = bestConfByCode.keys.first
        } else if let avgLab = cellAvgLab, let lookup = codeToLab {
            // 多候选 + 颜色信息：选 Lab 距离最近的（处理 E2/E3 这种 OCR 难分辨的近邻色）
            var bestCode: String? = nil
            var bestDE = Double.infinity
            for code in bestConfByCode.keys {
                guard let codeLab = lookup[code] else { continue }
                let de = GridCellSampler.deltaE(avgLab, codeLab)
                if de < bestDE { bestDE = de; bestCode = code }
            }
            matched = bestCode ?? bestConfByCode.max(by: { $0.value < $1.value })?.key
        } else {
            // 多候选但无颜色信息：取置信度最高
            matched = bestConfByCode.max(by: { $0.value < $1.value })?.key
        }

        let ms = Int(Date().timeIntervalSince(cellStart) * 1000)
        let candidatesStr = bestConfByCode.keys.sorted().joined(separator: ",")
        debugLog("[OCR] cell(\(row),\(col)) DONE \(ms)ms raw=\"\(rawText)\" candidates=[\(candidatesStr)] -> \(matched ?? "nil")")
        return matched
    }

    /// 对整图跑 OCR，返回稀疏 [row][col] String?——只有 OCR 识别到且命中
    /// allowedCodes 的格子才有值。其余为 nil（调用方应 fall back 到颜色采样）。
    /// 调用方负责缩图（函数本身不做缩放）。
    func sample(image: UIImage,
                grid: BeadPatternGrid,
                allowedCodes: Set<String>) -> [[String?]] {
        let empty: [[String?]] = Array(
            repeating: Array(repeating: nil, count: grid.cols), count: grid.rows
        )
        guard let cgImage = image.cgImage, !allowedCodes.isEmpty else { return empty }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.minimumTextHeight = 0.01           // 格子里文字相对图大约 1~3%
        request.customWords = Array(allowedCodes)

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return empty
        }

        guard let observations = request.results else { return empty }

        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)
        let imageSize = CGSize(width: imageWidth, height: imageHeight)

        var result = empty

        for obs in observations {
            // 取 top 3 候选，第一个能匹配到图例色号的胜出
            var matchedCode: String? = nil
            for candidate in obs.topCandidates(3) {
                if let code = Self.matchLegendCode(text: candidate.string, allowed: allowedCodes) {
                    matchedCode = code
                    break
                }
            }
            guard let code = matchedCode else { continue }

            // Vision boundingBox 坐标系：左下原点，归一化。需要翻 Y 转到 UIImage 像素坐标。
            let bbox = obs.boundingBox
            let centerX = bbox.midX * imageWidth
            let centerY = (1 - bbox.midY) * imageHeight

            guard let cell = Self.cellFor(
                point: CGPoint(x: centerX, y: centerY),
                grid: grid, imageSize: imageSize
            ) else { continue }

            // 同一格被识别多次时，保留第一次（按 Vision 的顺序）。
            if result[cell.row][cell.col] == nil {
                result[cell.row][cell.col] = code
            }
        }

        return result
    }

    /// 给定图像像素坐标点，返回它落在哪个 cell。轴对齐矩形假设。
    static func cellFor(point: CGPoint, grid: BeadPatternGrid, imageSize: CGSize) -> (row: Int, col: Int)? {
        let tlx = grid.corners.topLeft.x * imageSize.width
        let tly = grid.corners.topLeft.y * imageSize.height
        let brx = grid.corners.bottomRight.x * imageSize.width
        let bry = grid.corners.bottomRight.y * imageSize.height
        guard brx > tlx, bry > tly else { return nil }
        let u = (point.x - tlx) / (brx - tlx)
        let v = (point.y - tly) / (bry - tly)
        if u < 0 || u >= 1 || v < 0 || v >= 1 { return nil }
        let col = min(grid.cols - 1, Int(u * CGFloat(grid.cols)))
        let row = min(grid.rows - 1, Int(v * CGFloat(grid.rows)))
        return (row, col)
    }

    /// 规范化 OCR 返回的文字，匹配 allowedCodes 中的某一个。
    /// - 去除空格 / 标点 / 中文标点
    /// - 转大写
    /// - 精确匹配后才返回；不做模糊匹配以避免误识别。
    static func matchLegendCode(text: String, allowed: Set<String>) -> String? {
        let cleaned = text.uppercased().filter { $0.isLetter || $0.isNumber }
        if cleaned.isEmpty { return nil }
        if allowed.contains(cleaned) { return cleaned }
        return nil
    }

    /// 把图缩到长边 maxDim 以下（默认 2048）。Vision OCR 对超大图非常慢。
    static func downsampledForOCR(_ image: UIImage, maxDim: CGFloat = 2048) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        if longest <= maxDim { return image }
        let scale = maxDim / longest
        let newSize = CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// CGImage 按 factor 倍数上采样，用 .high (Lanczos) 插值。失败返回 nil。
    /// 用途：per-cell 裁剪 → 上采样 → Vision OCR，文字更大识别率更高。
    static func upscale(_ cgImage: CGImage, factor: CGFloat) -> CGImage? {
        let scaledWidth = Int(CGFloat(cgImage.width) * factor)
        let scaledHeight = Int(CGFloat(cgImage.height) * factor)
        guard scaledWidth > 0, scaledHeight > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: scaledWidth,
            height: scaledHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight))
        return context.makeImage()
    }
}
