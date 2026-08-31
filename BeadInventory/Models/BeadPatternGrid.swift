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
struct GridCorners: Codable, Equatable, Sendable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomLeft: CGPoint
    var bottomRight: CGPoint
}

/// 拼图模式中一张图纸的完整网格描述。
/// 与 ProjectRecord 一对一，存在 ProjectRecord.patternGrid 字段。
///
/// ## 前七个字段是「结论」，后四个是「怎么得到这个结论的」
///
/// `corners` / `rows` / `cols` / `cellColorCodes` 是所有读的人要的东西（高亮、跟图例对账、
/// 备份），从第一版起就没变过，老数据也只有这些。
///
/// 后面四个是**单图纸流程自己要用的中间量**：用户裁的那一块、量出来的格距和格线、
/// 指认的底色。存它们只有一个理由 —— 用户第二天再进来时，能接着上次的继续调，
/// 而不是从一张空白的图重新裁一遍框、重新量一遍格子。老数据一律 nil，
/// 那时流程会当场重新量一次（量格子那屏是 `PartsCellSizeStepView`，两种模式共用）。
struct BeadPatternGrid: Codable, Equatable, Sendable {
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

    // MARK: - 单图纸流程的中间量（老数据为 nil）

    /// 用户裁出来的图纸区域（归一化，相对整张源图）。
    /// **不等于 `corners`**：corners 是把它的四条边吸到格线上之后的那块整数格区域，
    /// 而这个是用户手拖的框 —— 下次进来要还原成他拖的样子，不是吸过的样子。
    var roi: CGRect? = nil

    /// 一格多大、格线在哪。跟多零件模式共用一个类型（同一件事，没必要两套）。
    var calibration: PartsGridCalibration? = nil

    /// 用户在图上指认的底色（`RRGGBB`）。判色时先把这一片摘出去，
    /// 否则整片空白会被硬套到最近的色号上（理由见 `PartsBaseColorStepView` 的头注释）。
    var emptyHex: String? = nil

    /// 用户在「量格子」那屏亲手点过「对齐了」。语义完全同 `BeadPart.gridConfirmed` ——
    /// 那一屏是跟多零件模式共用的，锁不跟着存下来的话，下次进来它会当成「没人对过」，
    /// 一进屏就按当前格距把用户对好的格线重新拟合一遍。
    var gridConfirmed: Bool? = nil

    // MARK: - 这个色拼完了

    /// 这张图纸上哪些色号已经拼完了。key 是格子里存的色号，value 是**按下「已完成」
    /// 那一刻，图上这个色号有多少格**。
    ///
    /// 记格数而不是只记一句「拼过了」：核对页随时能一格一格地擦 / 补，补进来三格 H7
    /// 之后那个勾还挂着的话，用户照着勾跳过去正好漏掉那三格 —— 而这个标记本来就是
    /// 为了防漏。格数对不上就当没标记过，而且是**删掉**不是遮住：遮住的话格数哪天
    /// 绕回原值，勾就自己回来了。整套取舍连同它认不出来的那几种改动，见
    /// `PartsBoard.doneColors` —— 多零件模式一块板一份，单图纸模式整张图纸就是
    /// 一块板，所以这份挂在网格上。
    var doneColors: [String: Int]? = nil
}
