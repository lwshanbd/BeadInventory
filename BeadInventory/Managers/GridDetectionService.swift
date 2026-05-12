//
//  GridDetectionService.swift
//  BeadInventory
//
//  拼图模式 - 网格自动检测入口。
//  顺序尝试两种算法（PR3 算法 B 留接口待后续补），返回最高置信度结果。
//

import Foundation
import UIKit

struct GridDetectionResult {
    let corners: GridCorners
    let rows: Int
    let cols: Int
    let confidence: Double      // 0~1，< 0.5 视为"请手动确认"
}

final class GridDetectionService {
    static let shared = GridDetectionService()
    private init() {}

    /// 异步检测整图网格。失败或置信度极低（< 0.2）时返回 nil。
    func detect(image: UIImage) async -> GridDetectionResult? {
        await withCheckedContinuation { cont in
            Task.detached(priority: .userInitiated) {
                let result = self.detectSync(image: image, roi: nil)
                cont.resume(returning: result)
            }
        }
    }

    /// 异步在 ROI 内检测网格（用户已用 2 角圈定区域）。
    /// 返回 corners 仍是相对整图的归一化坐标，但 rows/cols 在 ROI 内计数。
    func detect(image: UIImage, roi: CGRect) async -> GridDetectionResult? {
        await withCheckedContinuation { cont in
            Task.detached(priority: .userInitiated) {
                let result = self.detectSync(image: image, roi: roi)
                cont.resume(returning: result)
            }
        }
    }

    /// 约束拟合：用户已知行列数，反推 4 角。
    /// 比通用 Hough 鲁棒得多——边缘标号/水印等噪声不会被选中，
    /// 因为它们的边不在等距 rows×cols 网格上。
    func fitWithUserRowsCols(image: UIImage, rows: Int, cols: Int, roi: CGRect?) async -> GridDetectionResult? {
        await withCheckedContinuation { cont in
            Task.detached(priority: .userInitiated) {
                let nsRoi = roi.map { NSValue(cgRect: $0) }
                let result = GridDetectionBridge.fitGrid(
                    withRows: rows, cols: cols, image: image, roi: nsRoi
                )?.toSwiftResult()
                cont.resume(returning: result)
            }
        }
    }

    private func detectSync(image: UIImage, roi: CGRect?) -> GridDetectionResult? {
        let nsRoi = roi.map { NSValue(cgRect: $0) }

        // 算法 A：HoughLines（带网格线的图纸首选）
        if let r = GridDetectionBridge.detectGrid(withHoughLines: image, roi: nsRoi),
           r.confidence >= 0.4 {  // 阈值从 0.5 放宽到 0.4
            return r.toSwiftResult()
        }

        // 算法 C：findContours 兜底
        if let r = GridDetectionBridge.detectGrid(withContours: image, roi: nsRoi),
           r.confidence >= 0.2 {
            return r.toSwiftResult()
        }

        return nil
    }
}

private extension GridDetectionResultBridge {
    func toSwiftResult() -> GridDetectionResult {
        GridDetectionResult(
            corners: GridCorners(
                topLeft: topLeft,
                topRight: topRight,
                bottomLeft: bottomLeft,
                bottomRight: bottomRight
            ),
            rows: rows,
            cols: cols,
            confidence: confidence
        )
    }
}
