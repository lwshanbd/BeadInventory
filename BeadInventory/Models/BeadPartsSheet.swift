//
//  BeadPartsSheet.swift
//  BeadInventory
//
//  多零件模式（立体拼图图纸）- 数据模型
//
//  立体拼图的图纸是「一张大图上排着几十个互不相连的小零件」，跟单图纸模式
//  「整张图一个密密麻麻的大网格」不是一回事，所以另起一套模型，不复用
//  BeadPatternGrid。
//
//  ## 坐标约定
//
//  本文件里所有几何量都是**归一化 (0~1)、相对整张源图左上角**的，和
//  `GridCorners` 一致。理由：图纸会被降采样之后再分析（原图动辄十几 MB），
//  存像素值就得跟着记「当时是哪个分辨率」，换一次分析分辨率全部作废。
//  `workingImageSize` 只用来把归一化值翻译回「大约多少像素」给用户看。
//

import Foundation
import CoreGraphics

// MARK: - 格子内容

/// 一格里放什么。三态，缺一不可：
/// - `.empty`    这一格没有豆子（零件中间的镂空、或者零件之外的背景）
/// - `.anyColor` 图例标成「任意色」的区域 —— 有豆子，但用哪个色号由用户自己定
/// - `.code`     具体色号（按所在 sheet 的 `colorSystem` 解释）
///
/// 「任意色」和「空」在图纸上都是浅色一片，肉眼就容易混，算法更容易混。
/// 所以这两者不靠猜：用户在调色板那一屏亲自指认（见 `PartsPaletteEntry.Role`），
/// 逐格分类只是把已确认的结论套上去。
enum PartCellFill: Codable, Equatable, Sendable {
    case empty
    case anyColor
    case code(String)

    /// 是否需要真的放一颗豆子（`.empty` 之外都要）
    var needsBead: Bool {
        if case .empty = self { return false }
        return true
    }
}

// MARK: - 全局网格标定

/// 整张图纸所有零件共用同一个格距 —— 它们本来就是从同一张像素画上切下来的。
/// 所以格子只标定一次，全图通用。单位是归一化的（占图宽 / 图高的比例）。
struct PartsGridCalibration: Codable, Equatable, Sendable {
    /// 一格的宽 / 高，占整张图宽 / 高的比例
    var cellWidth: Double
    var cellHeight: Double
    /// 任意一条竖 / 横网格线的位置（不必是最左 / 最上那条，消费方对格距取模用）
    var originX: Double
    var originY: Double

    /// 归一化格距 → 在给定尺寸下大约多少像素（只用于给用户显示）
    func cellPixelSize(in imageSize: CGSize) -> CGSize {
        CGSize(width: cellWidth * imageSize.width, height: cellHeight * imageSize.height)
    }
}

// MARK: - 零件

/// 零件左上角在全局网格里的整数格坐标
struct PartGridIndex: Codable, Equatable, Sendable {
    var col: Int
    var row: Int
}

struct BeadPart: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    /// 用户起的名字（「左前腿」）。nil = 用自动编号。
    ///
    /// 刻意不在创建时就把「零件 3」写死进去：删掉一个零件之后，写死的名字会跟
    /// 清单上的序号对不上，用户得挨个改名。名字留空、序号由列表位置现算，
    /// 怎么增删都不会错位。
    var customName: String?
    /// 第几行零件（0-based）。图纸是按行排版的，保留行号后清单能按图纸原样分行显示，
    /// 用户对得上号。
    var rowBand: Int
    /// 归一化 bbox（相对整张源图）。第 1 步的产物，第 2 步标定后会 snap 到格边。
    var bounds: CGRect

    // 以下是第 2 步（网格对齐 + 颜色识别）的产物，第 1 步一律为空。
    var gridOrigin: PartGridIndex?
    var rows: Int
    var cols: Int
    /// `[row][col]`。没识别过时是空数组 —— 判断「有没有识别过」用 `hasCells`。
    var cells: [[PartCellFill]]

    init(
        id: UUID = UUID(),
        customName: String? = nil,
        rowBand: Int,
        bounds: CGRect,
        gridOrigin: PartGridIndex? = nil,
        rows: Int = 0,
        cols: Int = 0,
        cells: [[PartCellFill]] = []
    ) {
        self.id = id
        self.customName = customName
        self.rowBand = rowBand
        self.bounds = bounds
        self.gridOrigin = gridOrigin
        self.rows = rows
        self.cols = cols
        self.cells = cells
    }

    var hasCells: Bool { !cells.isEmpty }

    /// 列表里显示的名字。`order` 是它在清单里的位置（0-based）。
    func displayName(order: Int) -> String {
        if let customName, !customName.trimmingCharacters(in: .whitespaces).isEmpty {
            return customName
        }
        return String(localized: "零件 \(order + 1)")
    }

    /// 需要放豆子的格数（识别过才有意义）
    var beadCount: Int {
        cells.reduce(0) { $0 + $1.filter(\.needsBead).count }
    }
}

// MARK: - 图纸调色板

/// 从图纸上聚出来的一种颜色，以及用户认定它代表什么。
///
/// 这一层的意义：把「图纸上的某个 RGB」和「色号 / 任意色 / 空」的对应关系
/// **一次性确认清楚**，后面几万个格子的分类就只是在这十几个已知颜色里取最近的，
/// 不用再去几百色的色库里赌。用户改一条，所有用到这个颜色的格子跟着改。
struct PartsPaletteEntry: Identifiable, Codable, Equatable, Sendable {
    enum Role: Codable, Equatable, Sendable {
        /// 具体色号（按 sheet 的 colorSystem 解释）
        case code(String)
        /// 图例里的「任意色」
        case anyColor
        /// 不是豆子：零件中间的镂空 / 背景
        case empty
    }

    var id: UUID
    /// 聚类中心颜色，`RRGGBB`（不带 #）
    var hex: String
    /// 这个颜色在零件区里占的像素比例，用来排序 + 帮用户判断「这是主色还是杂色」
    var pixelShare: Double
    var role: Role
    /// 自动匹色号时的 Lab 距离。越大越不可信，UI 上据此提示用户「这条看一眼」。
    /// 用户手动改过之后置 nil（不再是自动结果）。
    var matchDeltaE: Double?

    init(
        id: UUID = UUID(),
        hex: String,
        pixelShare: Double,
        role: Role,
        matchDeltaE: Double? = nil
    ) {
        self.id = id
        self.hex = hex
        self.pixelShare = pixelShare
        self.role = role
        self.matchDeltaE = matchDeltaE
    }
}

// MARK: - 整张图纸

/// 一个项目的多零件图纸数据。与 ProjectRecord 一对一，
/// 存在 `SDProjectRecord.partsSheetData`（JSON）。
struct BeadPartsSheet: Codable, Equatable, Sendable {
    /// 用户圈的零件区（排除掉顶部色号表、底部装配图），归一化
    var roi: CGRect
    /// 做分析时那张图的尺寸（像素）。只用于把归一化值翻译成「大约多少像素」显示，
    /// 以及换图后提示宽高比对不上。
    var workingImageSize: CGSize
    var colorSystem: ColorSystem
    var parts: [BeadPart]
    var palette: [PartsPaletteEntry]
    /// 第 2 步的产物，第 1 步为 nil
    var calibration: PartsGridCalibration?
    /// 用户给「任意色」最终指定的色号。nil = 还没定，扣库存时要先问。
    var anyColorCode: String?
    var lastUpdatedAt: Date

    init(
        roi: CGRect,
        workingImageSize: CGSize,
        colorSystem: ColorSystem,
        parts: [BeadPart] = [],
        palette: [PartsPaletteEntry] = [],
        calibration: PartsGridCalibration? = nil,
        anyColorCode: String? = nil,
        lastUpdatedAt: Date = Date()
    ) {
        self.roi = roi
        self.workingImageSize = workingImageSize
        self.colorSystem = colorSystem
        self.parts = parts
        self.palette = palette
        self.calibration = calibration
        self.anyColorCode = anyColorCode
        self.lastUpdatedAt = lastUpdatedAt
    }

    /// 调色板里被指认为「任意色」的那一条（最多一条有意义，多条时取第一条）
    var anyColorEntry: PartsPaletteEntry? {
        palette.first { $0.role == .anyColor }
    }

    /// 调色板里代表「空」的条目
    var emptyEntries: [PartsPaletteEntry] {
        palette.filter { $0.role == .empty }
    }
}
