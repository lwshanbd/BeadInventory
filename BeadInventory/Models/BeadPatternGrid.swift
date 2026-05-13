//
//  BeadPatternGrid.swift
//  BeadInventory
//
//  拼图模式 - 网格数据模型
//

import Foundation
import CoreGraphics

/// 网格 4 个角点，归一化坐标 (0~1)，相对源图片左上角。
/// 支持四边形（梯形）以容忍轻微透视，不强制矩形。
struct GridCorners: Codable, Equatable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomLeft: CGPoint
    var bottomRight: CGPoint
}

/// 拼图模式中一张图纸的完整网格描述。
/// 与 ProjectRecord 一对一，存在 ProjectRecord.patternGrid 字段。
struct BeadPatternGrid: Codable, Equatable {
    /// 4 个归一化角点
    var corners: GridCorners

    /// 行数（纵向方向的格子数）
    var rows: Int
    /// 列数（横向方向的格子数）
    var cols: Int

    /// [row][col] 二维色号矩阵，nil 表示空白格或未匹配
    var cellColorCodes: [[String?]]

    /// 最近一次标定/采样时间
    var lastCalibratedAt: Date

    /// 标定时的图像尺寸（像素）。用于：换图后检测一致性 / 报告 corners 是否仍有效
    var sourceImageSize: CGSize

    /// 关联项目的色号体系（MARD / 卡卡等），与 ProjectRecord.colorSystem 一致
    var colorSystem: ColorSystem
}
