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
//        → 8 邻域连通域标记
//        → 按面积滤掉水印 / 噪点
//        → 小框被大框整个包住的合并进大框（零件内部的孤岛）
//        → 按 bbox 竖直位置聚成「行」，还原图纸本来的排版顺序
//
//  刻意**不用** OpenCV：这套逻辑全是整型数组操作，纯 Swift 写出来行为完全可控，
//  也不用去猜 opencv2 ObjC 包装层的方法签名。
//

import UIKit
import CoreGraphics

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

    /// 工作分辨率上限
    var maxWorkingPixels: Int = 1_600_000
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
        let mask = foregroundMask(of: bitmap, deltaE: options.foregroundDeltaE)
        let closed = close(mask: mask, width: bitmap.width, height: bitmap.height, radius: options.closingRadius)
        var boxes = connectedBoxes(mask: closed, width: bitmap.width, height: bitmap.height)

        let minArea = max(12, Int(Double(bitmap.pixelCount) * options.minAreaRatio))
        boxes = boxes.filter {
            $0.area >= minArea && $0.w >= 4 && $0.h >= 4
                && !isFrameLine($0, width: bitmap.width, height: bitmap.height)
        }
        boxes = mergeContained(boxes)

        return assignRowBands(boxes, bitmap: bitmap)
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

    private static func foregroundMask(of bitmap: PartsBitmap, deltaE: Double) -> [Bool] {
        let bg = backgroundLab(of: bitmap)
        // 每个量化桶只判一次，像素级只剩查表
        var isForeground = [Bool](repeating: false, count: QuantizedRGB.count)
        for i in 0..<QuantizedRGB.count {
            isForeground[i] = GridCellSampler.deltaE(QuantizedRGB.labTable[i], bg) > deltaE
        }
        var mask = [Bool](repeating: false, count: bitmap.pixelCount)
        for i in 0..<bitmap.pixelCount {
            mask[i] = isForeground[Int(bitmap.quantized[i])]
        }
        return mask
    }

    // MARK: - 形态学

    /// 闭运算（先膨胀后腐蚀），把描边上被抗锯齿冲淡的一两个像素缺口补回来，
    /// 免得一个零件被切成好几块。半径故意小 —— 大了会把相邻零件粘成一个。
    private static func close(mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        guard radius > 0 else { return mask }
        var m = mask
        for _ in 0..<radius { m = dilate(m, width: width, height: height) }
        for _ in 0..<radius { m = erode(m, width: width, height: height) }
        return m
    }

    private static func dilate(_ mask: [Bool], width: Int, height: Int) -> [Bool] {
        var out = [Bool](repeating: false, count: mask.count)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where mask[row + x] {
                for dy in -1...1 {
                    let ny = y + dy
                    guard ny >= 0, ny < height else { continue }
                    for dx in -1...1 {
                        let nx = x + dx
                        guard nx >= 0, nx < width else { continue }
                        out[ny * width + nx] = true
                    }
                }
            }
        }
        return out
    }

    private static func erode(_ mask: [Bool], width: Int, height: Int) -> [Bool] {
        var out = [Bool](repeating: false, count: mask.count)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                guard mask[row + x] else { continue }
                var keep = true
                loop: for dy in -1...1 {
                    let ny = y + dy
                    if ny < 0 || ny >= height { keep = false; break loop }
                    for dx in -1...1 {
                        let nx = x + dx
                        if nx < 0 || nx >= width || !mask[ny * width + nx] { keep = false; break loop }
                    }
                }
                out[row + x] = keep
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

    /// 8 邻域连通域标记（两趟 + union-find），返回每个连通域的 bbox 和面积。
    static func connectedBoxes(mask: [Bool], width: Int, height: Int) -> [Box] {
        var labels = [Int32](repeating: 0, count: mask.count)   // 0 = 背景
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
        func union(_ a: Int32, _ b: Int32) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[Int(max(ra, rb))] = min(ra, rb) }
        }

        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                guard mask[row + x] else { continue }
                // 已扫描过的 4 个邻居：左、左上、上、右上
                var neighbors: [Int32] = []
                if x > 0, labels[row + x - 1] != 0 { neighbors.append(labels[row + x - 1]) }
                if y > 0 {
                    let up = (y - 1) * width
                    if x > 0, labels[up + x - 1] != 0 { neighbors.append(labels[up + x - 1]) }
                    if labels[up + x] != 0 { neighbors.append(labels[up + x]) }
                    if x + 1 < width, labels[up + x + 1] != 0 { neighbors.append(labels[up + x + 1]) }
                }
                if neighbors.isEmpty {
                    let newLabel = Int32(parent.count)
                    parent.append(newLabel)
                    labels[row + x] = newLabel
                } else {
                    let m = neighbors.min()!
                    labels[row + x] = m
                    for n in neighbors where n != m { union(m, n) }
                }
            }
        }

        // 第二趟：归到根 label 上累 bbox
        var boxes = [Int32: Box]()
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let l = labels[row + x]
                guard l != 0 else { continue }
                let root = find(l)
                if var b = boxes[root] {
                    let nx = min(b.x, x), ny = min(b.y, y)
                    let mx = max(b.maxX, x + 1), my = max(b.maxY, y + 1)
                    b.x = nx; b.y = ny; b.w = mx - nx; b.h = my - ny
                    b.area += 1
                    boxes[root] = b
                } else {
                    boxes[root] = Box(x: x, y: y, w: 1, h: 1, area: 1)
                }
            }
        }
        return Array(boxes.values)
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
