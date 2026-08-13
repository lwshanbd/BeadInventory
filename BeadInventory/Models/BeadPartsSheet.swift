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
//  `workingImageSize` 记着当时那张图多大，供以后校验用（见该字段的注释）。
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
/// 所以这两者不靠猜：用户在「底色和任意色」那一屏点图指认（见 `PartsBaseColorStepView`），
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

/// 整张图纸只有**一张网格**：所有零件都是从同一张像素画上切下来的，
/// 格子多大、格线在哪，全图是同一个答案。这个类型就是那个答案。
///
/// ## 为什么连「格线在哪」也是全局的
///
/// 之前这里只有格距，格线位置由每个零件自己的 bbox 均分。结果就是用户抱怨的那件事：
/// 「一个零件对齐了，换一个又对不上」—— bbox 是连通域外沿，带一圈抗锯齿毛边，
/// 每个零件毛边多少不一样，均分出来的线自然一个零件一个样。用户于是得一个一个重新对，
/// 而这些零件在原图上明明共用同一批格线。
///
/// 现在格线是一条条铺满整张图纸的直线：竖线在 `originX + k · cellWidth`，
/// 横线在 `originY + k · cellHeight`。零件只是"这张网格上的一块矩形区域"，
/// 由 `PartsGrid` 把它吸到最近的格线上。用户调一次，全图跟着变。
struct PartsGridCalibration: Codable, Equatable, Sendable {
    /// 一格的宽 / 高，占整张图宽 / 高的比例
    var cellWidth: Double
    var cellHeight: Double
    /// 任意一条竖格线 / 横格线的位置（归一化，相对整张图纸）。
    /// 取哪一条无所谓 —— 网格是无限铺开的，差一整格是同一张网格。
    var originX: Double
    var originY: Double

    init(cellWidth: Double, cellHeight: Double, originX: Double = 0, originY: Double = 0) {
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.originX = originX
        self.originY = originY
    }

    // 全局格线是后加的字段。老数据（只有格距）解码时补 0 —— 0 也是一条合法的格线，
    // 用户进「量格子」那屏会立刻被自动对齐refit 掉。合成的 init(from:) 遇到缺字段会直接抛，
    // 所以这里必须手写。
    private enum CodingKeys: String, CodingKey {
        case cellWidth, cellHeight, originX, originY
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cellWidth = try c.decode(Double.self, forKey: .cellWidth)
        cellHeight = try c.decode(Double.self, forKey: .cellHeight)
        originX = try c.decodeIfPresent(Double.self, forKey: .originX) ?? 0
        originY = try c.decodeIfPresent(Double.self, forKey: .originY) ?? 0
    }

    var isUsable: Bool { cellWidth > 0 && cellHeight > 0 }

    /// 把一个横坐标吸到最近的竖格线上
    func snappedX(_ x: Double) -> Double {
        guard cellWidth > 0 else { return x }
        return originX + ((x - originX) / cellWidth).rounded() * cellWidth
    }

    /// 把一个纵坐标吸到最近的横格线上
    func snappedY(_ y: Double) -> Double {
        guard cellHeight > 0 else { return y }
        return originY + ((y - originY) / cellHeight).rounded() * cellHeight
    }
}

// MARK: - 零件在全局网格上占的那块

/// 某个零件落在全局网格上的整数格区域。
///
/// 四条边都吸到最近的格线上：零件的真实边界本来就在格线上，
/// bbox 那一圈抗锯齿毛边（最多也就三分之一格）会被吸回去。
struct PartsGrid: Equatable {
    var rect: CGRect
    var rows: Int
    var cols: Int

    init(rect: CGRect, rows: Int, cols: Int) {
        self.rect = rect
        self.rows = rows
        self.cols = cols
    }

    init(covering bounds: CGRect, calibration: PartsGridCalibration) {
        guard calibration.isUsable else {
            rect = bounds; rows = 1; cols = 1
            return
        }
        let cw = CGFloat(calibration.cellWidth)
        let ch = CGFloat(calibration.cellHeight)
        let x0 = CGFloat(calibration.snappedX(Double(bounds.minX)))
        let y0 = CGFloat(calibration.snappedY(Double(bounds.minY)))
        cols = max(1, min(400, Int(((bounds.maxX - x0) / cw).rounded())))
        rows = max(1, min(400, Int(((bounds.maxY - y0) / ch).rounded())))
        rect = CGRect(x: x0, y: y0, width: CGFloat(cols) * cw, height: CGFloat(rows) * ch)
    }
}

// MARK: - 零件

struct BeadPart: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    /// 用户起的名字（「左前腿」）。nil = 用自动编号。
    ///
    /// 刻意不在创建时就把「零件 3」写死进去：删掉一个零件之后，写死的名字会跟
    /// 清单上的序号对不上，用户得挨个改名。名字留空、序号由列表位置现算，
    /// 怎么增删都不会错位。
    var customName: String?
    /// 第几行零件（0-based）。图纸是按行排版的，保留行号后清单能按图纸上的先后顺序排，
    /// 用户对得上号（清单本身是自适应网格，不是一行一行铺的）。
    var rowBand: Int
    /// 归一化 bbox（相对整张源图）。第 1 步的产物，第 2 步标定后会 snap 到格边。
    var bounds: CGRect

    // 以下是第 2 步（网格对齐 + 颜色识别）的产物，第 1 步一律为空。

    /// 网格实际覆盖的范围（归一化）。**不等于 `bounds`**：
    /// bounds 是连通域外沿，带一圈抗锯齿毛边；这个是把它的四条边吸到全局格线上之后
    /// 得到的真正的 rows × cols 格区域（见 `PartsGrid`）。
    /// nil 表示还没对齐过，此时退回用 bounds。
    var gridRect: CGRect?
    var rows: Int
    var cols: Int
    /// `[row][col]`。没识别过时是空数组 —— 判断「有没有识别过」用 `hasCells`。
    var cells: [[PartCellFill]]

    /// 用户在「量格子」那屏亲手点过「对齐了」。
    ///
    /// 点过之后这个零件的网格就锁住：之后再改格距、再按自动对齐，都只作用在还没确认过的
    /// 零件上，不回头动它。图纸上的零件是各画各的，用户一个一个对过来，对好的那几个不该
    /// 因为后面调了一下又被推走 —— 那样他永远收敛不了。
    ///
    /// **Optional 是为了老数据**：合成的 `init(from:)` 对 Optional 用 decodeIfPresent，
    /// 缺字段解出 nil（等于没确认过）；写成非 Optional 的 Bool 会让所有存量图纸解码直接抛。
    var gridConfirmed: Bool?

    init(
        id: UUID = UUID(),
        customName: String? = nil,
        rowBand: Int,
        bounds: CGRect,
        gridRect: CGRect? = nil,
        rows: Int = 0,
        cols: Int = 0,
        cells: [[PartCellFill]] = [],
        gridConfirmed: Bool? = nil
    ) {
        self.id = id
        self.customName = customName
        self.rowBand = rowBand
        self.bounds = bounds
        self.gridRect = gridRect
        self.rows = rows
        self.cols = cols
        self.cells = cells
        self.gridConfirmed = gridConfirmed
    }

    var hasCells: Bool { !cells.isEmpty }

    /// 用户亲手确认过这个零件的网格
    var isGridConfirmed: Bool { gridConfirmed == true }

    /// 这个零件落在全局网格上的那块区域。全图共用一张网格，所以这里不带任何
    /// 「这个零件自己的」参数 —— 换个零件看，格线还是那批格线。
    func grid(for calibration: PartsGridCalibration) -> PartsGrid {
        PartsGrid(covering: bounds, calibration: calibration)
    }

    /// 第 (row, col) 格在整张图里的归一化矩形。均分的是 `gridRect`（四条边吸到全局格线之后的），
    /// 没对齐过时退回 `bounds`。
    func cellRect(row: Int, col: Int) -> CGRect {
        guard rows > 0, cols > 0 else { return .zero }
        let area = gridRect ?? bounds
        let w = area.width / CGFloat(cols)
        let h = area.height / CGFloat(rows)
        return CGRect(x: area.minX + CGFloat(col) * w,
                      y: area.minY + CGFloat(row) * h,
                      width: w, height: h)
    }

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
    /// 做分析时那张图的尺寸（像素）。存下来是为了以后能判断「换的这张图跟当初分析的
    /// 不是一个宽高比」—— 目前只是记着，还没有哪一屏读它。
    var workingImageSize: CGSize
    var colorSystem: ColorSystem
    var parts: [BeadPart]
    var palette: [PartsPaletteEntry]
    /// 第 2 步的产物，第 1 步为 nil
    var calibration: PartsGridCalibration?
    /// 用户给「任意色」最终指定的色号。预留字段：目前只是存下来跟着图纸走，
    /// 还没有哪一步会拿它去扣库存。
    var anyColorCode: String?
    /// 用户在图上指认的**底色**（`RRGGBB`）。每张图纸底色都不一样，
    /// 不先摘出去，那一大片空白会被硬套到最近的色号上。nil = 还没指认，判色时自己猜。
    var emptyHex: String?
    /// 用户在图上指认的**任意色**（`RRGGBB`）。这个猜不出来 ——
    /// 它在图上就是一种普通豆子，「代表任意色」只写在色号表那一行字里。
    var anyColorHex: String?
    /// 零件摆在拼豆板上的位置。最后一步的产物，之前的步骤都是 nil。
    ///
    /// 刻意用 Optional 而不是 `[PartsBoard] = []`：合成的 `init(from:)` 不认
    /// 属性默认值，缺字段一律抛错 —— 那样所有存量图纸一进来就解不出来。
    /// Optional 缺字段解成 nil，老数据照常打得开。
    var boards: [PartsBoard]?
    /// `boards` 是按哪一档松紧排出来的。
    ///
    /// 必须跟着图纸走，不能只当成一个 App 设置：拖动校验用的松紧要是跟当初排版用的
    /// 对不上，用户会撞见一块「自己排出来的样子、自己却拖不回去」的板。
    /// 同样是 Optional（理由见 `boards`）；老图纸解出 nil —— 当年只有一种排法，
    /// 那一档现在叫 `BoardSpacing.tight`。
    var boardSpacing: BoardSpacing?
    var lastUpdatedAt: Date

    init(
        roi: CGRect,
        workingImageSize: CGSize,
        colorSystem: ColorSystem,
        parts: [BeadPart] = [],
        palette: [PartsPaletteEntry] = [],
        calibration: PartsGridCalibration? = nil,
        anyColorCode: String? = nil,
        emptyHex: String? = nil,
        anyColorHex: String? = nil,
        boards: [PartsBoard]? = nil,
        boardSpacing: BoardSpacing? = nil,
        lastUpdatedAt: Date = Date()
    ) {
        self.roi = roi
        self.workingImageSize = workingImageSize
        self.colorSystem = colorSystem
        self.parts = parts
        self.palette = palette
        self.calibration = calibration
        self.anyColorCode = anyColorCode
        self.emptyHex = emptyHex
        self.anyColorHex = anyColorHex
        self.boards = boards
        self.boardSpacing = boardSpacing
        self.lastUpdatedAt = lastUpdatedAt
    }

}
