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
    /// 第几行（0-based）
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

    /// 图纸是一行行排版的，用户说「第三行第二个」时得对得上。
    /// 按 bbox 的竖直中心聚行：跟当前行的中心差超过「典型零件高度的一半」就换行。
    static func assignRowBands(_ boxes: [Box], bitmap: PartsBitmap) -> [DetectedPart] {
        guard !boxes.isEmpty else { return [] }
        let heights = boxes.map { $0.h }.sorted()
        let medianHeight = Double(heights[heights.count / 2])
        let tolerance = max(4.0, medianHeight * 0.5)

        let byY = boxes.sorted { $0.midY < $1.midY }
        var bands: [[Box]] = []
        var current: [Box] = []
        var bandAnchor = byY[0].midY
        for box in byY {
            if current.isEmpty || box.midY - bandAnchor <= tolerance {
                current.append(box)
                // 锚点用行内均值，免得一行里越靠后的零件把行心越拖越低
                bandAnchor = current.map(\.midY).reduce(0, +) / Double(current.count)
            } else {
                bands.append(current)
                current = [box]
                bandAnchor = box.midY
            }
        }
        if !current.isEmpty { bands.append(current) }

        var result: [DetectedPart] = []
        for (bandIndex, band) in bands.enumerated() {
            for box in band.sorted(by: { $0.x < $1.x }) {
                result.append(DetectedPart(
                    bounds: bitmap.normalizedRect(x: box.x, y: box.y, w: box.w, h: box.h),
                    pixelArea: box.area,
                    rowBand: bandIndex
                ))
            }
        }
        return result
    }
}
