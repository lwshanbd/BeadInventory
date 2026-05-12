//
//  GridOCRSampler.swift
//  BeadInventory
//
//  拼图模式 - 用 Apple Vision OCR 识别格子里的色号文字。
//  整图一次 OCR，按 bounding box 映射回格子；只有当识别文字命中图例色号时才采纳。
//

import UIKit
import Vision

final class GridOCRSampler {
    static let shared = GridOCRSampler()
    private init() {}

    /// 对整图跑 OCR，返回稀疏 [row][col] String?——只有 OCR 识别到且命中
    /// allowedCodes 的格子才有值。其余为 nil（调用方应 fall back 到颜色采样）。
    func sample(image: UIImage,
                grid: BeadPatternGrid,
                allowedCodes: Set<String>) -> [[String?]] {
        let empty: [[String?]] = Array(
            repeating: Array(repeating: nil, count: grid.cols), count: grid.rows
        )
        guard let cgImage = image.cgImage, !allowedCodes.isEmpty else { return empty }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false     // 色号不是自然语言，关掉自动纠正
        request.minimumTextHeight = 0.005          // 格子里文字很小
        request.customWords = Array(allowedCodes)  // 告诉 Vision 期望的词

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
}
