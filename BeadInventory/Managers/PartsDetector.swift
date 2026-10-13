//
//  PartsDetector.swift
//  BeadInventory
//
//  多零件模式 - 把一张图纸的零件区拆成一个个独立零件
//
//  ## 思路
//
//  立体拼图图纸上的零件之间是「大片背景色」隔开的，所以拆分不需要先知道格子多大，
//  只要回答一个问题：**哪些像素不是背景**。
//
//      估背景色（取零件区四边的众数）
//        → 逐像素跟背景比 Lab 距离，超阈值的算前景
//        → 闭运算把描边上的抗锯齿缺口补上
//        → 8 邻域连通域，一块就是一个零件
//        → 按面积滤掉水印 / 噪点
//        → 小框被大框整个包住的合并进大框（零件内部的孤岛）
//        → 按阅读顺序分栏、分行（见 `readingRows`），还原图纸本来的排版顺序
//
//  ## 深色底的图纸多走两步
//
//  深色底（目前见到的都是深棕）的图纸有两个浅底图纸没有的麻烦：
//
//  - **底色是渐变的**，还叠着大面积半透明插画。只拿四边的众数比，渐变深的那头整片底色都会被当成零件。
//    所以底色改成按位置估：零件区切成小块，每块各估一个，再抹平插值（`backgroundField`）。
//  - **水印数字跟底色差得多**，前景阈值挡不住；零件之间的缝又只有一格宽，水印笔画横穿过去，
//    把两三个零件连成一块。所以连通域之前先拆开：
//      开运算削掉细笔画，剩下的一块块是零件「核心」
//        → 核心在闭运算结果里往外长几步，把削掉的边缘长回来；彼此抢地盘，长到缝中间就停
//        → 还没认领的前景按连通块归位：只挨着一个零件的并进去，谁都不挨的自成一块，
//          挨着好几个的（缝里的水印残渣）也自成一块，多半被面积过滤清掉
//
//  这两步**只在深色底上做**（`isDarkBackground`）。浅底图纸上它们反而添乱：
//  白格子跟底色几乎一样，零件常常只靠细格线连着，开运算会把一个零件拆出好几个核心，
//  一个零件被框成三个；跟底色接近的大块浅色零件，也可能被按位置估成底色。
//  浅底图纸上水印本来就淡，前景阈值挡得住，用不着这两步。
//
//  ## 浅色底、零件带黑描边的图纸先按描边拆
//
//  有的浅底图纸铺着大幅插画、满屏灰色水印，按底色拆会把整个零件区连成一块。
//  这类图纸的零件都有纯黑描边，插画和水印没这么黑，所以只看黑像素就能拆干净。
//  按描边拆出来的框能解释大部分前景时才用它，不然照旧按底色拆，见 `outlinedBoxes`。
//
//  刻意**不用** OpenCV：这套逻辑全是整型数组操作，纯 Swift 写出来行为完全可控，
//  也不用去猜 opencv2 ObjC 包装层的方法签名。
//

import UIKit
import CoreGraphics
import Accelerate

/// 拆出来的一个零件（还没有网格信息）
struct DetectedPart: Equatable, Sendable {
    /// 归一化 bbox（相对整张源图）
    var bounds: CGRect
    /// 工作分辨率下的前景像素数，用来排序 / 判断主次
    var pixelArea: Int
    /// 按阅读顺序数的第几行（0-based）。分栏的图纸，右栏的行号接在左栏后面，见 `readingRows`
    var rowBand: Int
}

/// 检测参数。**这些不暴露给用户** —— 曾经把 `foregroundDeltaE` / `minAreaRatio`
/// 包成一根「灵敏度」滑杆放在界面上，那是在让用户替算法调参：他既不知道该往哪边拉，
/// 也不知道拉了会换来什么。结果不对时用户要做的是在图上直接改那几个框，不是猜刻度。
/// 只有 `splitSelected` / `addPart` 这种「在一个小框里重跑」的场景才改这里的值。
struct PartsDetectionOptions: Equatable, Sendable {
    /// 前景判定阈值（跟背景色的 Lab 距离）。
    /// 小了浅色零件不会漏，但水印和 JPEG 色偏也可能被当成零件；
    /// 大了更干净，但跟背景接近的浅色零件会被吃掉。
    var foregroundDeltaE: Double = 12

    /// 最小零件面积，占零件区总像素的比例。低于这个的连通域丢掉。
    /// 那种平铺的半透明水印文字笔画又细又碎，主要靠这一条清掉。
    var minAreaRatio: Double = 0.0004

    /// 闭运算半径（像素）。1 足够补描边的抗锯齿缺口；再大会把挨得近的两个零件粘一起。
    var closingRadius: Int = 1

    /// 找零件核心的开运算半径，按 `referencePixels` 那么大的图算，实际按工作图大小等比换算。
    /// 比 2r+1 细的笔画不算核心。0 = 不找核心，闭运算后的每一块就是一个零件。
    /// 只在深色底上起作用，见文件头。
    ///
    /// 实测两张深棕底图纸（工作图上一格 10 像素左右）：r=2 削不断横穿零件缝的水印数字，r=3 刚好。
    /// 原图上笔画看着只有三四像素，r=2（5 像素宽）照理削得断；没细查，多半是闭运算把笔画补粗了一圈。
    /// 上限是一格宽：r=5 就是 11 像素，一格宽的零件会整个被削没，没有核心。
    var coreRadius: Int = 3

    /// 核心最多往外长几步（同样按 `referencePixels` 换算）。
    /// 只需要把开运算削掉的那一圈长回来；长太多会顺着水印笔画伸出去，框被撑大。
    var regrowSteps: Int = 6

    /// 底色按位置分别估。渐变底、带大面积半透明插画的图纸，四周一圈的众数只对得上一部分。
    /// 只在深色底上起作用，见文件头。
    /// 在单个零件的小框里重跑时关掉：那里面大半是零件自己，没有足够的底色可估。
    var localBackground: Bool = true

    /// 浅色底上先试着按黑色描边拆零件，见 `PartsDetector.outlinedBoxes`。
    /// 拆开时关掉：要拆的正是描边连在一起的两个零件，按描边拆还是一块。
    var outlines: Bool = true

    /// 工作分辨率上限。
    ///
    /// 早先是 160 万。深棕底那张长条零件的图纸，零件区压到 160 万像素后一格只剩 6 像素，
    /// 零件之间的缝只有 5 像素，抗锯齿的边各吃掉一两像素，水印一搭就连上了。
    /// 400 万下一格 10 像素，缝和笔画在像素上才拉得开。
    var maxWorkingPixels: Int = 4_000_000

    /// `coreRadius` / `regrowSteps` 是按这么大的工作图定的。
    /// 跟 `maxWorkingPixels` 的默认值碰巧相等，但不是一回事：改工作分辨率时别跟着改这个，
    /// 除非重新实测过那两个半径。
    static let referencePixels = 4_000_000

    /// 四边众数的亮度（L）低于这个就算深色底。实测深棕底在 34~47，粉色浅底在 95 上下，
    /// 中间空得很大，取 60。
    static let darkBackgroundL: Double = 60
}

enum PartsDetector {

    /// 拆零件。耗时在百毫秒级，调用方请放到后台。
    /// - Parameters:
    ///   - image: 已经降采样过的整张图纸
    ///   - roi: 用户圈的零件区（归一化，相对整张图）
    static func detect(
        in work: PartsWorkImage,
        roi: CGRect,
        options: PartsDetectionOptions = PartsDetectionOptions()
    ) -> [DetectedPart] {
        guard let bitmap = PartsBitmap.make(from: work, roi: roi, maxPixels: options.maxWorkingPixels) else {
            return []
        }
        return detect(in: bitmap, options: options)
    }

    /// 已经有位图时的入口（调色板那步会复用同一张位图）
    static func detect(in bitmap: PartsBitmap, options: PartsDetectionOptions) -> [DetectedPart] {
        let w = bitmap.width, h = bitmap.height
        let dark = isDarkBackground(bitmap)
        let mask = foregroundMask(of: bitmap, deltaE: options.foregroundDeltaE,
                                  local: dark && options.localBackground)
        let minArea = max(12, Int(Double(bitmap.pixelCount) * options.minAreaRatio))

        if !dark, options.outlines,
           let outlined = outlinedBoxes(of: bitmap, foreground: mask, minArea: minArea) {
            return assignRowBands(outlined, bitmap: bitmap)
        }

        let closed = close(mask, width: w, height: h, radius: options.closingRadius)
        // 工作图比参考尺寸小（原图本身就小）时，笔画和格子在像素上也跟着小，半径按边长比例缩
        let scale = (Double(bitmap.pixelCount) / Double(PartsDetectionOptions.referencePixels)).squareRoot()
        func scaled(_ v: Int) -> Int { v > 0 ? max(1, Int((Double(v) * scale).rounded())) : 0 }

        let labels = partLabels(
            closed: closed, width: w, height: h,
            coreRadius: dark ? scaled(options.coreRadius) : 0,
            regrowSteps: scaled(options.regrowSteps),
            minCoreArea: minArea
        )
        var found = boxes(of: labels, width: w)
        found = found.filter {
            $0.area >= minArea && $0.w >= 4 && $0.h >= 4
                && !isFrameLine($0, width: w, height: h)
        }
        found = mergeContained(found)

        return assignRowBands(found, bitmap: bitmap)
    }

    // MARK: - 背景 / 前景

    /// 背景色 = 零件区四周一圈的颜色众数。
    /// 用「一圈」而不是全图：用户圈的框本来就该比零件区大一点点，边上几乎全是底色；
    /// 全图众数在零件铺得很满时会被主色抢走。
    static func backgroundLab(of bitmap: PartsBitmap) -> LabColor {
        let w = bitmap.width, h = bitmap.height
        let band = max(1, min(w, h) / 40)
        var counts = [Int32: Int]()
        counts.reserveCapacity(1024)

        func tally(x: Int, y: Int) {
            counts[bitmap.quantized[y * w + x], default: 0] += 1
        }
        for y in 0..<min(band, h) {
            for x in 0..<w { tally(x: x, y: y); tally(x: x, y: h - 1 - y) }
        }
        for x in 0..<min(band, w) {
            for y in 0..<h { tally(x: x, y: y); tally(x: w - 1 - x, y: y) }
        }
        guard let winner = counts.max(by: { $0.value < $1.value })?.key else {
            return LabColor(l: 100, a: 0, b: 0)
        }
        return QuantizedRGB.labTable[Int(winner)]
    }

    /// 深色底的图纸才按位置估底色、找零件核心，理由见文件头
    static func isDarkBackground(_ bitmap: PartsBitmap) -> Bool {
        backgroundLab(of: bitmap).l < PartsDetectionOptions.darkBackgroundL
    }

    /// 按位置估的底色：零件区切成一格格小块，每块一个底色，像素取所在位置双线性插值
    /// （插值写在 `foregroundMask` 里）。
    fileprivate struct BackgroundField {
        let tile: Int
        let columns: Int
        let rows: Int
        /// rows × columns，行优先
        let grid: [LabColor]
    }

    /// 深色底的图纸常常是上下渐变的（实测一张深棕底从上到下 L 差了 13），
    /// 再叠一层大面积半透明插画。只拿四周一圈的众数去比，渐变深的那头整片底色都会被判成前景。
    ///
    /// 做法：先用四周一圈的众数当「大致底色」，零件区按短边约 24 块（每块至少 8 像素）切成方块，
    /// 每块只看跟大致底色差不太远的像素（≤25，渐变的跨度在这以内，零件颜色多半在外），
    /// 这种像素够多的块取它们的众数当这块的底色。
    /// 跟周围 5×5 小块的中位数差超过 10 的块不信 —— 那多半是零件里恰好有一片颜色接近底色。
    /// 没有底色的块（被零件占满，或者刚被判成不可信）用邻居补，最后 3×3 抹平。
    fileprivate static func backgroundField(of bitmap: PartsBitmap) -> BackgroundField {
        let w = bitmap.width, h = bitmap.height
        let rough = backgroundLab(of: bitmap)
        let tile = max(8, min(w, h) / 24)
        let columns = (w + tile - 1) / tile, rows = (h + tile - 1) / tile

        var isCandidate = [Bool](repeating: false, count: QuantizedRGB.count)
        for i in 0..<QuantizedRGB.count {
            isCandidate[i] = GridCellSampler.deltaE(QuantizedRGB.labTable[i], rough) <= 25
        }

        var grid = [LabColor?](repeating: nil, count: rows * columns)
        var counts = [Int32](repeating: 0, count: QuantizedRGB.count)
        var touched: [Int] = []
        for ty in 0..<rows {
            for tx in 0..<columns {
                let x0 = tx * tile, y0 = ty * tile
                let x1 = min(w, x0 + tile), y1 = min(h, y0 + tile)
                var total = 0
                touched.removeAll(keepingCapacity: true)
                for y in y0..<y1 {
                    let row = y * w
                    for x in x0..<x1 {
                        let q = Int(bitmap.quantized[row + x])
                        guard isCandidate[q] else { continue }
                        if counts[q] == 0 { touched.append(q) }
                        counts[q] += 1
                        total += 1
                    }
                }
                let size = (x1 - x0) * (y1 - y0)
                if total * 100 >= size * 15, let winner = touched.max(by: { counts[$0] < counts[$1] }) {
                    grid[ty * columns + tx] = QuantizedRGB.labTable[winner]
                }
                for q in touched { counts[q] = 0 }
            }
        }

        // 跟周围 5×5 小块的中位数差太多的不信
        var trusted = grid
        for ty in 0..<rows {
            for tx in 0..<columns {
                guard let own = grid[ty * columns + tx] else { continue }
                var ls: [Double] = [], as_: [Double] = [], bs: [Double] = []
                for ny in max(0, ty - 2)...min(rows - 1, ty + 2) {
                    for nx in max(0, tx - 2)...min(columns - 1, tx + 2) {
                        if let c = grid[ny * columns + nx] { ls.append(c.l); as_.append(c.a); bs.append(c.b) }
                    }
                }
                func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
                let med = LabColor(l: median(ls), a: median(as_), b: median(bs))
                if GridCellSampler.deltaE(own, med) > 10 { trusted[ty * columns + tx] = nil }
            }
        }

        // 空块用已知邻居的平均值一圈圈补进去
        if !trusted.contains(where: { $0 != nil }) {
            trusted = [LabColor?](repeating: rough, count: trusted.count)
        }
        while trusted.contains(where: { $0 == nil }) {
            var next = trusted
            for ty in 0..<rows {
                for tx in 0..<columns where trusted[ty * columns + tx] == nil {
                    var sum = (l: 0.0, a: 0.0, b: 0.0), n = 0.0
                    for ny in max(0, ty - 1)...min(rows - 1, ty + 1) {
                        for nx in max(0, tx - 1)...min(columns - 1, tx + 1) {
                            if let c = trusted[ny * columns + nx] {
                                sum.l += c.l; sum.a += c.a; sum.b += c.b; n += 1
                            }
                        }
                    }
                    if n > 0 { next[ty * columns + tx] = LabColor(l: sum.l / n, a: sum.a / n, b: sum.b / n) }
                }
            }
            trusted = next
        }
        let filled = trusted.map { $0! }

        // 3×3 抹平，边上按最近的补
        var smooth = filled
        for ty in 0..<rows {
            for tx in 0..<columns {
                var sum = (l: 0.0, a: 0.0, b: 0.0)
                for dy in -1...1 {
                    let ny = min(max(ty + dy, 0), rows - 1)
                    for dx in -1...1 {
                        let c = filled[ny * columns + min(max(tx + dx, 0), columns - 1)]
                        sum.l += c.l; sum.a += c.a; sum.b += c.b
                    }
                }
                smooth[ty * columns + tx] = LabColor(l: sum.l / 9, a: sum.a / 9, b: sum.b / 9)
            }
        }
        return BackgroundField(tile: tile, columns: columns, rows: rows, grid: smooth)
    }

    private static func foregroundMask(of bitmap: PartsBitmap, deltaE: Double, local: Bool) -> [Bool] {
        var mask = [Bool](repeating: false, count: bitmap.pixelCount)
        guard local else {
            let bg = backgroundLab(of: bitmap)
            // 每个量化桶只判一次，像素级只剩查表
            var isForeground = [Bool](repeating: false, count: QuantizedRGB.count)
            for i in 0..<QuantizedRGB.count {
                isForeground[i] = GridCellSampler.deltaE(QuantizedRGB.labTable[i], bg) > deltaE
            }
            for i in 0..<bitmap.pixelCount {
                mask[i] = isForeground[Int(bitmap.quantized[i])]
            }
            return mask
        }
        let field = backgroundField(of: bitmap)
        let w = bitmap.width
        let limit = deltaE * deltaE
        // 小块中心之间双线性插值，最外一圈中心以外按最近的取。
        // 每行先把上下两排小块混好，行内只剩左右混：逐像素做完整的双线性在 Debug 下要好几秒。
        var rowL = [Double](repeating: 0, count: field.columns)
        var rowA = rowL, rowB = rowL
        QuantizedRGB.labTable.withUnsafeBufferPointer { table in
            bitmap.quantized.withUnsafeBufferPointer { q in
                mask.withUnsafeMutableBufferPointer { out in
                    for y in 0..<bitmap.height {
                        let fy = min(max((Double(y) + 0.5) / Double(field.tile) - 0.5, 0), Double(field.rows - 1))
                        let y0 = Int(fy), y1 = min(y0 + 1, field.rows - 1), ty = fy - Double(y0)
                        for c in 0..<field.columns {
                            let top = field.grid[y0 * field.columns + c], bottom = field.grid[y1 * field.columns + c]
                            rowL[c] = top.l + (bottom.l - top.l) * ty
                            rowA[c] = top.a + (bottom.a - top.a) * ty
                            rowB[c] = top.b + (bottom.b - top.b) * ty
                        }
                        let row = y * w
                        for x in 0..<w {
                            let fx = min(max((Double(x) + 0.5) / Double(field.tile) - 0.5, 0), Double(field.columns - 1))
                            let x0 = Int(fx), x1 = min(x0 + 1, field.columns - 1), tx = fx - Double(x0)
                            let c = table[Int(q[row + x])]
                            let dl = c.l - (rowL[x0] + (rowL[x1] - rowL[x0]) * tx)
                            let da = c.a - (rowA[x0] + (rowA[x1] - rowA[x0]) * tx)
                            let db = c.b - (rowB[x0] + (rowB[x1] - rowB[x0]) * tx)
                            out[row + x] = dl * dl + da * da + db * db > limit
                        }
                    }
                }
            }
        }
        return mask
    }

    // MARK: - 按描边拆

    /// 描边算「黑」的亮度上限
    static let outlineMaxL: Double = 40

    /// 按黑色描边拆零件。不是有描边的图纸就返回 nil，走原来的按底色拆。
    ///
    /// 有的图纸背景花得很：底下铺满大幅浅色插画，再盖一层灰色水印数字。
    /// 按底色拆时，插画线条和水印都跟底色差得多，被当成前景，把整个零件区连成一大块，
    /// 最后被 `isFrameLine` 当边框扔掉，几乎一个零件都框不出来。
    ///
    /// 但这类图纸的零件都有一圈纯黑描边，格子之间也是深色格线；插画、水印再花也没这么黑。
    /// 所以只看黑像素：一个零件的描边和格线连成一整块，零件之间被底色隔开，
    /// 这一块的外接框就是零件的框。
    ///
    /// 怎么判断这张图是不是这种图纸：按底色拆出来的前景，大部分要落在这些框里（`coverage`），
    /// 这些框里大部分也得是前景（`density`）。没有描边、只有格子里印着黑色数字的图纸，
    /// 数字拆出来的小框只占前景的一小部分，过不了第一条。
    static func outlinedBoxes(of bitmap: PartsBitmap, foreground: [Bool], minArea: Int) -> [Box]? {
        let w = bitmap.width, h = bitmap.height
        var isDark = [Bool](repeating: false, count: QuantizedRGB.count)
        for i in 0..<QuantizedRGB.count { isDark[i] = QuantizedRGB.labTable[i].l < outlineMaxL }
        var dark = [Bool](repeating: false, count: bitmap.pixelCount)
        for i in 0..<bitmap.pixelCount { dark[i] = isDark[Int(bitmap.quantized[i])] }
        // 描边缩小后偶尔断开一两个像素，补上
        dark = close(dark, width: w, height: h, radius: 1)

        var found = boxes(of: labelComponents(dark, width: w, height: h).labels, width: w)
        // 描边是空心的，像素数远小于零件面积，按外接框的面积滤。
        // 插画和水印不够黑，到不了这一步，剩下的小块多半是真零件（两三格的小插件），门槛放低
        found = found.filter {
            $0.w * $0.h >= minArea / 4 && $0.w >= 4 && $0.h >= 4
                && !isFrameLine($0, width: w, height: h)
        }
        found = mergeContained(found)
        guard !found.isEmpty else { return nil }

        var inBox = [Bool](repeating: false, count: bitmap.pixelCount)
        for box in found {
            for y in box.y..<box.maxY {
                for x in box.x..<box.maxX { inBox[y * w + x] = true }
            }
        }
        var total = 0, covered = 0, boxArea = 0
        for i in 0..<bitmap.pixelCount {
            if foreground[i] { total += 1; if inBox[i] { covered += 1 } }
            if inBox[i] { boxArea += 1 }
        }
        guard total > 0, boxArea > 0 else { return nil }
        let coverage = Double(covered) / Double(total)
        let density = Double(covered) / Double(boxArea)
        guard coverage >= 0.5, density >= 0.5 else { return nil }
        return found
    }

    // MARK: - 形态学

    /// 闭运算（先膨胀后腐蚀），把描边上被抗锯齿冲淡的一两个像素缺口补回来，
    /// 免得一个零件被切成好几块。半径故意小 —— 大了会把相邻零件粘成一个。
    static func close(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        guard radius > 0 else { return mask }
        let dilated = squareFilter(mask, width: width, height: height, radius: radius, erode: false)
        return squareFilter(dilated, width: width, height: height, radius: radius, erode: true)
    }

    /// 开运算（先腐蚀后膨胀）：比 2r+1 细的东西整个消失，够粗的原样留下。
    /// 像素画的零件全是横平竖直的方块，用方形结构元素，够粗的部分形状一点不变。
    static func open(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        guard radius > 0 else { return mask }
        let eroded = squareFilter(mask, width: width, height: height, radius: radius, erode: true)
        return squareFilter(eroded, width: width, height: height, radius: radius, erode: false)
    }

    /// 边长 2r+1 的方形腐蚀 / 膨胀 = 窗口里取最小 / 最大值，交给 vImage。
    /// 自己写的双重循环在 Debug 下每遍 400 万像素要半秒，这一步要做好几遍。
    /// 窗口伸出图外的部分不算（贴着图边的零件腐蚀时不会被削掉一圈）。
    private static func squareFilter(_ mask: [Bool], width w: Int, height h: Int,
                                     radius r: Int, erode: Bool) -> [Bool] {
        var out = mask
        let side = vImagePixelCount(2 * r + 1)
        // Bool 在内存里就是一个 0/1 字节，直接当 8 位灰度图用，取完最小 / 最大还是 0/1
        mask.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress!),
                                           height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                var destination = vImage_Buffer(data: dst.baseAddress!,
                                                height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                let error = erode
                    ? vImageMin_Planar8(&source, &destination, nil, 0, 0, side, side, vImage_Flags(kvImageNoFlags))
                    : vImageMax_Planar8(&source, &destination, nil, 0, 0, side, side, vImage_Flags(kvImageNoFlags))
                // 失败时 out 还是输入的原样：开运算等于没做，深色底又会粘成一块，却不报任何错。
                // 参数都是合法的，真碰上多半是内存不够；留个日志，别让它悄悄退化。
                if error != kvImageNoError {
                    assertionFailure("vImage morphology failed: \(error)")
                    AppLogger.shared.warning("PartsDetector", "morphology_failed", metadata: [
                        "error": error, "width": w, "height": h, "radius": r, "erode": erode
                    ])
                }
            }
        }
        return out
    }

    // MARK: - 连通域

    struct Box: Equatable {
        var x: Int, y: Int, w: Int, h: Int
        var area: Int
        var midY: Double { Double(y) + Double(h) / 2 }
        var maxX: Int { x + w }
        var maxY: Int { y + h }

        func contains(_ other: Box) -> Bool {
            other.x >= x && other.y >= y && other.maxX <= maxX && other.maxY <= maxY
        }
    }

    /// 8 邻域连通域标记（两趟 + union-find）。返回每个像素的编号（0 = 背景，其余从 1 连续编）和块数。
    static func labelComponents(_ mask: [Bool], width: Int, height: Int) -> (labels: [Int32], count: Int) {
        var labels = [Int32](repeating: 0, count: mask.count)
        var parent: [Int32] = [0]                                // parent[0] 占位

        func find(_ a: Int32) -> Int32 {
            var root = a
            while parent[Int(root)] != root { root = parent[Int(root)] }
            // 路径压缩
            var cur = a
            while parent[Int(cur)] != root {
                let next = parent[Int(cur)]
                parent[Int(cur)] = root
                cur = next
            }
            return root
        }

        mask.withUnsafeBufferPointer { m in
            labels.withUnsafeMutableBufferPointer { lab in
                for y in 0..<height {
                    let row = y * width
                    for x in 0..<width {
                        guard m[row + x] else { continue }
                        // 已扫描过的 4 个邻居：左、左上、上、右上
                        let up = row - width
                        let n0: Int32 = x > 0 ? lab[row + x - 1] : 0
                        let n1: Int32 = y > 0 && x > 0 ? lab[up + x - 1] : 0
                        let n2: Int32 = y > 0 ? lab[up + x] : 0
                        let n3: Int32 = y > 0 && x + 1 < width ? lab[up + x + 1] : 0
                        var smallest: Int32 = 0
                        func meet(_ n: Int32) {
                            guard n != 0, n != smallest else { return }
                            if smallest == 0 { smallest = n; return }
                            let ra = find(smallest), rb = find(n)
                            if ra != rb { parent[Int(max(ra, rb))] = min(ra, rb) }
                            smallest = min(smallest, n)
                        }
                        meet(n0); meet(n1); meet(n2); meet(n3)
                        if smallest == 0 {
                            smallest = Int32(parent.count)
                            parent.append(smallest)
                        }
                        lab[row + x] = smallest
                    }
                }
            }
        }

        // 第二趟：归到根上，重新连续编号
        var compact = [Int32](repeating: 0, count: parent.count)
        for i in 1..<parent.count { parent[i] = find(Int32(i)) }
        var count: Int32 = 0
        for i in 1..<parent.count where parent[i] == Int32(i) {
            count += 1
            compact[i] = count
        }
        for i in 1..<parent.count { compact[i] = compact[Int(parent[i])] }
        labels.withUnsafeMutableBufferPointer { lab in
            compact.withUnsafeBufferPointer { compact in
                for i in 0..<lab.count where lab[i] != 0 { lab[i] = compact[Int(lab[i])] }
            }
        }
        return (labels, Int(count))
    }

    /// 每个像素归哪个零件（0 = 背景）。
    ///
    /// `coreRadius` 为 0 时就是闭运算结果的连通域。否则：
    /// 1. 开运算找核心，太小的核心不算（水印笔画交叉处偶尔会剩一小团）；
    /// 2. 核心在闭运算结果里同步往外长，每步一圈，先到先得，最多 `regrowSteps` 步 ——
    ///    两个零件被水印连着时，各自长到缝中间就停，不会并成一块；
    /// 3. 闭运算结果里没被任何核心认领的部分，按它们自己的连通域分块：
    ///    只挨着一个零件的归那个零件，一个都不挨的自己算一块（细得整个被削没的小零件靠这条留下来），
    ///    挨着好几个的也自己算一块（缝里的水印残渣，多半被后面的面积过滤清掉）。
    static func partLabels(closed: [Bool], width w: Int, height h: Int,
                           coreRadius: Int, regrowSteps: Int, minCoreArea: Int) -> [Int32] {
        guard coreRadius > 0 else { return labelComponents(closed, width: w, height: h).labels }

        let cores = open(closed, width: w, height: h, radius: coreRadius)
        var (labels, count) = labelComponents(cores, width: w, height: h)
        var coreArea = [Int](repeating: 0, count: count + 1)
        for l in labels where l != 0 { coreArea[Int(l)] += 1 }
        for i in labels.indices where labels[i] != 0 && coreArea[Int(labels[i])] < minCoreArea {
            labels[i] = 0
        }

        // 往外长：每步只从上一步新长出来的那圈出发，所以是同步的一圈圈扩。
        // 第一圈 = 8 邻域里贴着还没认领的前景的核心像素。跟往外长、连通域一样用 8 邻域，
        // 不然只在斜角上挨着核心的细结构进不来，会被单独拆成一块。
        // 「贴着」用 3×3 膨胀一次求出来：逐像素查 8 个邻居在 Debug 下要好几秒。
        var unclaimed = [Bool](repeating: false, count: closed.count)
        for i in closed.indices where closed[i] && labels[i] == 0 { unclaimed[i] = true }
        let nearUnclaimed = squareFilter(unclaimed, width: w, height: h, radius: 1, erode: false)
        var frontier: [Int] = []
        for i in labels.indices where labels[i] != 0 && nearUnclaimed[i] { frontier.append(i) }

        closed.withUnsafeBufferPointer { closed in
            labels.withUnsafeMutableBufferPointer { lab in
                var step = 0
                while step < regrowSteps, !frontier.isEmpty {
                    var grown: [Int] = []
                    for i in frontier {
                        let l = lab[i]
                        let x = i % w, y = i / w
                        for ny in max(0, y - 1)...min(h - 1, y + 1) {
                            for nx in max(0, x - 1)...min(w - 1, x + 1) {
                                let j = ny * w + nx
                                if closed[j] && lab[j] == 0 {
                                    lab[j] = l
                                    grown.append(j)
                                }
                            }
                        }
                    }
                    frontier = grown
                    step += 1
                }
            }
        }

        // 没被认领的按连通块分，再看每块挨着谁
        var rest = [Bool](repeating: false, count: closed.count)
        var anyRest = false
        for i in closed.indices where closed[i] && labels[i] == 0 { rest[i] = true; anyRest = true }
        if anyRest {
            let (others, otherCount) = labelComponents(rest, width: w, height: h)
            // 只挨着一个零件的那块归它：零件里只靠细格线连着的一片（开运算削掉了，
            // 核心长 `regrowSteps` 步又够不到），不归回去就成了套在零件框外的另一个框。
            // 同时挨着两个零件的（缝里的水印残渣）不归任何一边，自己成块，多半被面积过滤掉。
            // 谁都不挨的也自己成块，编号接在核心后面。
            var touching = [Int32](repeating: 0, count: otherCount + 1)   // 0 没挨着，-1 挨着不止一个
            // 8 邻域，跟连通域一致。只有挨着已认领像素的那些要查邻居，同样先膨胀一次圈出来
            var claimed = [Bool](repeating: false, count: labels.count)
            for i in labels.indices where labels[i] != 0 { claimed[i] = true }
            let nearClaimed = squareFilter(claimed, width: w, height: h, radius: 1, erode: false)
            for i in others.indices where others[i] != 0 && nearClaimed[i] {
                let o = Int(others[i])
                guard touching[o] != -1 else { continue }
                let x = i % w, y = i / w
                for ny in max(0, y - 1)...min(h - 1, y + 1) {
                    for nx in max(0, x - 1)...min(w - 1, x + 1) {
                        let j = ny * w + nx
                        guard others[j] == 0, labels[j] != 0 else { continue }
                        if touching[o] == 0 { touching[o] = labels[j] } else if touching[o] != labels[j] { touching[o] = -1 }
                    }
                }
            }
            let offset = Int32(count)
            for i in others.indices where others[i] != 0 {
                let t = touching[Int(others[i])]
                labels[i] = t > 0 ? t : others[i] + offset
            }
        }
        return labels
    }

    /// 每个编号的 bbox 和像素数
    static func boxes(of labels: [Int32], width: Int) -> [Box] {
        let maxLabel = Int(labels.max() ?? 0)
        guard maxLabel > 0 else { return [] }
        var minX = [Int](repeating: Int.max, count: maxLabel + 1), minY = minX
        var maxX = [Int](repeating: -1, count: maxLabel + 1), maxY = maxX
        var area = [Int](repeating: 0, count: maxLabel + 1)
        labels.withUnsafeBufferPointer { lab in
            for i in 0..<lab.count {
                let l = Int(lab[i])
                guard l != 0 else { continue }
                let x = i % width, y = i / width
                if x < minX[l] { minX[l] = x }
                if x > maxX[l] { maxX[l] = x }
                if y < minY[l] { minY[l] = y }
                if y > maxY[l] { maxY[l] = y }
                area[l] += 1
            }
        }
        return (1...maxLabel).compactMap { l in
            area[l] > 0
                ? Box(x: minX[l], y: minY[l], w: maxX[l] - minX[l] + 1, h: maxY[l] - minY[l] + 1, area: area[l])
                : nil
        }
    }

    /// 图纸边框 / 分栏色带这类「不可能是零件」的连通域。
    ///
    /// 判据是两条形状上的硬事实，跟具体图纸无关：
    /// - **横跨整个零件区**：一个零件不会从最左一直连到最右（框宽 ≥95%）。
    ///   实测那张纸鸢图纸的三条脏数据（顶栏边线、底部粉色色带、分栏线）全在这一条上。
    /// - **发丝**：只有一两个像素粗、却拉得极长。一格豆子在工作分辨率下有十几像素，
    ///   所以最窄的「一豆宽」零件也不会细到这个程度。
    static func isFrameLine(_ box: Box, width: Int, height: Int) -> Bool {
        if box.w >= Int(Double(width) * 0.95) { return true }
        if box.h >= Int(Double(height) * 0.95) { return true }
        let hairThreshold = max(3, Int(Double(max(width, height)) * 0.004))
        let short = min(box.w, box.h), long = max(box.w, box.h)
        return short <= hairThreshold && long >= short * 8
    }

    /// 小框整个落在大框里的，并进大框。
    ///
    /// 零件内部常有跟描边不相连的孤岛（腮红点、镂空里的小装饰），它们是独立连通域，
    /// 但用户心里那是同一个零件。只在**完全包含**时合并 —— 只是重叠不合并，
    /// 不然两个挨着的零件会被越并越大。
    static func mergeContained(_ boxes: [Box]) -> [Box] {
        let sorted = boxes.sorted { $0.area > $1.area }
        var kept: [Box] = []
        for box in sorted {
            if let hostIndex = kept.firstIndex(where: { $0.contains(box) }) {
                kept[hostIndex].area += box.area
            } else {
                kept.append(box)
            }
        }
        return kept
    }

    // MARK: - 分行

    /// 图纸是一行行排版的，用户说「第三行第二个」时得对得上。顺序规则见 `readingRows`。
    static func assignRowBands(_ boxes: [Box], bitmap: PartsBitmap) -> [DetectedPart] {
        let rects = boxes.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }
        var result: [DetectedPart] = []
        for (bandIndex, row) in readingRows(rects).enumerated() {
            for index in row {
                let box = boxes[index]
                result.append(DetectedPart(
                    bounds: bitmap.normalizedRect(x: box.x, y: box.y, w: box.w, h: box.h),
                    pixelArea: box.area,
                    rowBand: bandIndex
                ))
            }
        }
        return result
    }

    /// 按图纸上的先后排：一行一行从上到下，行里一列一列从左到右，同一列里从上到下。
    /// 返回每一行里的下标，已经排好。
    ///
    /// **分行看竖直方向重不重叠，不看中心线。** 图纸上同一行的零件高矮差很多，
    /// 一行里常常是几个高的零件，旁边夹着一摞上下叠放的小零件。早先按竖直中心聚类：
    /// 小零件的中心跟高零件差得远，阈值又取「典型高度的一半」，结果一行会被切成好几行，
    /// 或者两行被并成一行，再按横坐标一排，编号就在两行之间上下来回跳。
    ///
    /// 列同理：一摞叠着的小零件横向重叠，算一列，从上往下数，不按左边缘谁更靠左。
    ///
    /// 有的图纸左右分栏（左边一栏大件、右边一栏小件，中间一条从上到下的空白）。
    /// 两栏的行是各排各的，对不齐，整张一起分行会左一行右一行地交替编号。
    /// 所以先按这种竖缝切栏，一栏编完再编下一栏。
    static func readingRows(_ rects: [CGRect]) -> [[Int]] {
        panels(of: Array(rects.indices), rects: rects).flatMap { panel in
            bands(of: panel, rects: rects, along: \.minY, \.maxY).map { row in
                bands(of: row, rects: rects, along: \.minX, \.maxX).flatMap { column in
                    column.sorted { rects[$0].minY < rects[$1].minY }
                }
            }
        }
    }

    /// 按从上到下没有任何零件压着的竖缝切栏。缝要**明显比同一行里零件之间的间隙宽**才算：
    /// 至少是行内间隙中位数的 3 倍，并且不窄于零件总宽的 3%。
    /// 只有几个大零件、排得横平竖直的图纸，列与列之间也是一条贯穿上下的空白，
    /// 但那只是普通的行内间隙，切开就成了一列一列竖着编。
    /// 量不出任何行内间隙（每行只有一个框，或者行里的框横向都挨着）时不切。
    private static func panels(of indices: [Int], rects: [CGRect]) -> [[Int]] {
        guard indices.count > 1 else { return [indices] }
        var gaps: [CGFloat] = []
        for row in bands(of: indices, rects: rects, along: \.minY, \.maxY) {
            let inRow = row.map { rects[$0] }.sorted { $0.minX < $1.minX }
            for (a, b) in zip(inRow, inRow.dropFirst()) where b.minX > a.maxX {
                gaps.append(b.minX - a.maxX)
            }
        }
        guard !gaps.isEmpty else { return [indices] }
        let byX = indices.sorted { rects[$0].minX < rects[$1].minX }
        let total = (byX.map { rects[$0].maxX }.max() ?? 0) - rects[byX[0]].minX
        let minGutter = max(gaps.sorted()[gaps.count / 2] * 3, total * 0.03)
        var panels: [[Int]] = [[]]
        var reach = rects[byX[0]].maxX
        for index in byX {
            if rects[index].minX - reach >= minGutter { panels.append([]) }
            panels[panels.count - 1].append(index)
            reach = max(reach, rects[index].maxX)
        }
        return panels
    }

    /// 沿一个方向把框分成一段一段：按起点排，跟当前这段重叠到「两者里较短那个的一半」就并进去。
    /// 用较短的那个当基准：一个矮零件挨着高零件时，重叠的部分占矮零件的大半，
    /// 但只占高零件的一小截；按高的算就会被错切开。
    ///
    /// 「这一段」的范围取成员起点、终点各自的中位数，**不取并集**。框画大了、竖着跨两行的
    /// 情况很常见，取并集的话一个这样的框就把这一行撑到下一行去，下一行整行被并进来，
    /// 编号又变成两行交替（在一张大件一行、小插件一行交替排的真实图纸上实测过）。
    private static func bands(
        of indices: [Int], rects: [CGRect],
        along lower: KeyPath<CGRect, CGFloat>, _ upper: KeyPath<CGRect, CGFloat>
    ) -> [[Int]] {
        func median(_ values: [CGFloat]) -> CGFloat { values.sorted()[values.count / 2] }
        let sorted = indices.sorted { rects[$0][keyPath: lower] < rects[$1][keyPath: lower] }
        var bands: [[Int]] = []
        var lows: [CGFloat] = [], highs: [CGFloat] = []
        for index in sorted {
            let low = rects[index][keyPath: lower], high = rects[index][keyPath: upper]
            if !bands.isEmpty {
                let spanLow = median(lows), spanHigh = max(median(highs), spanLow)
                let overlap = min(spanHigh, high) - max(spanLow, low)
                let shorter = min(spanHigh - spanLow, high - low)
                if overlap > 0, overlap >= shorter * 0.5 {
                    bands[bands.count - 1].append(index)
                    lows.append(low)
                    highs.append(high)
                    continue
                }
            }
            bands.append([index])
            lows = [low]
            highs = [high]
        }
        return bands
    }
}
