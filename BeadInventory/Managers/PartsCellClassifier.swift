//
//  PartsCellClassifier.swift
//  BeadInventory
//
//  多零件模式 - 每一格是什么颜色
//
//  ## 为什么先聚类再匹色号，而不是每格直接去色库里找最近的
//
//  色库有几百个色号，其中不少在 Lab 里挨得很近。逐格独立匹配时，同一片色块里
//  相邻两格因为 JPEG 压缩差了一点点，就可能一个判成 E12、一个判成 E13 ——
//  用户看到的是「一片颜色里混进来几颗别的」，得一格一格改。
//
//  所以先把所有格子的颜色聚成十几类（图纸本来就只用了十几种颜色），一类整体匹一个
//  色号。同一片色块必然判成同一个结果；用户在校色页改一条，那一片跟着全改。
//

import UIKit

enum PartsCellClassifier {

    /// 同一种颜色的两格之间允许的抖动。超过这个距离才算两种颜色。
    /// 取 8：每格用的是众数色（见 `sampleCells`），本身几乎没有噪声，
    /// 只剩 5 bit 量化那点误差；阈值放宽反而会把相邻色阶串成一类。
    private static let mergeDeltaE: Double = 8

    /// 判成「空」的条件：跟图纸背景色的距离在这个范围内。
    /// 零件中间的镂空和零件外面蹭进框里的背景是同一种像素，一起归到空。
    private static let emptyDeltaE: Double = 14

    /// 用户亲手在图上点出来的颜色（底色 / 任意色）的认领范围。
    /// 比 `mergeDeltaE`(8) 宽一点：他点的是某一格，而同一片色块在 JPEG 压缩之后
    /// 各格之间本来就有几个单位的漂移，卡太死会漏掉一半。
    private static let pickedDeltaE: Double = 12

    /// 在图上某一点取色，返回 `RRGGBB`。
    ///
    /// 取的是**一小片的众数色**而不是那一个像素：用户手指点不了那么准，
    /// 而豆子之间还有深色的格线，正好点在线上就会取到一个根本不存在的颜色。
    /// - Parameter patch: 取样方块的边长（归一化，相对整张图纸）。一般给半格。
    static func sampleHex(work: PartsWorkImage, at point: CGPoint, patch: Double) -> String? {
        let side = max(patch, 0.001)
        let rect = CGRect(x: Double(point.x) - side / 2, y: Double(point.y) - side / 2,
                          width: side, height: side)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard rect.width > 0, rect.height > 0,
              let bitmap = PartsBitmap.make(from: work, roi: rect, maxPixels: 4_000)
        else { return nil }
        var histogram: [Int32: Int] = [:]
        for i in 0..<bitmap.pixelCount {
            histogram[bitmap.quantized[i], default: 0] += 1
        }
        guard let winner = histogram.max(by: { $0.value < $1.value })?.key else { return nil }
        return QuantizedRGB.hex(of: Int(winner))
    }

    /// 自己猜一个底色，给「指认底色」那一屏当初值 —— 多数图纸猜得对，用户点头就行。
    static func autoEmptyHex(work: PartsWorkImage, roi: CGRect) -> String? {
        guard let bitmap = PartsBitmap.make(from: work, roi: roi, maxPixels: 400_000) else { return nil }
        return hex(of: PartsDetector.backgroundLab(of: bitmap))
    }

    struct Result {
        /// 填好 rows / cols / cells / gridRect 的零件
        var parts: [BeadPart]
        /// 这张图纸实际用到的颜色，按格数从多到少
        var palette: [PartsPaletteEntry]
        /// 图根本没抠出来、一格都没看到的零件数。
        ///
        /// **必须单独报出来**：抠图失败和「这个零件确实全是背景」在 `cells` 上长得一模一样
        /// （全是 `.empty`）。调用方不据此分流的话，用户看到的是一句「一共 0 颗」，
        /// 而他没做错任何事，也不知道该改哪儿。
        var unreadableParts: Int
        /// 每一格**图上真实的颜色**（`[零件][行][列]`，取不到的格子是 nil）。
        ///
        /// 单图纸模式拿它给 OCR 做交叉校验：格子里印着的色号字样认出来之后，要跟这一格
        /// 实际是什么颜色对一下才敢采纳（见 `SinglePatternClassifier`）。
        /// 光靠 `cells` 是不够的 —— 那里存的是聚类之后配好的色号，
        /// 拿它去校验 OCR 等于让算法自己给自己背书。
        var cellLabs: [[[LabColor?]]]
    }

    /// 把每个零件切成格子并逐格判色。耗时在秒级，调用方请放后台。
    ///
    /// - Parameter progress: (已完成零件数, 总数)
    static func classify(
        work: PartsWorkImage,
        parts: [BeadPart],
        roi: CGRect,
        calibration: PartsGridCalibration,
        colorSystem: ColorSystem,
        legendCodes: [String],
        availableColors: [BeadColor],
        emptyHex: String? = nil,
        anyColorHex: String? = nil,
        progress: ((Int, Int) -> Void)? = nil
    ) -> Result {
        // 底色：用户指认的优先，没指认才自己猜（从整个零件区取 ——
        // 不能从单个零件的框里取，那里面大半是零件自己）。
        let backgroundLab = emptyHex.flatMap { GridCellSampler.lab(forHex: $0) }
            ?? PartsBitmap.make(from: work, roi: roi, maxPixels: 400_000)
                .map { PartsDetector.backgroundLab(of: $0) }
        // 任意色：只有用户指认了才有。它不是色号，猜不出来 —— 图纸上它就是一种普通的
        // 淡色，跟别的豆子长得一样，唯一的区别写在色号表那一行字里。
        let anyColorLab = anyColorHex.flatMap { GridCellSampler.lab(forHex: $0) }

        // 第一趟：把每个零件切格、量出每格的平均色
        var fittedParts: [BeadPart] = []
        var cellLabs: [[[LabColor?]]] = []      // [part][row][col]
        var unreadableParts = 0
        for (index, part) in parts.enumerated() {
            var updated = part
            // 「量格子」那屏已经给这个零件定好格线了（格距全图共用，相位一个零件一个 ——
            // 图纸上零件是各画各的）。这里必须**照用**，不能再拿全局标定重吸一遍：
            // 那样会把用户刚在那一屏对好的位置整片洗掉。
            // 没定过的（用户跳过了那一屏）才退回全局标定。
            if let rect = part.gridRect, part.rows > 0, part.cols > 0 {
                updated.gridRect = rect
            } else {
                let grid = part.grid(for: calibration)
                updated.gridRect = grid.rect
                updated.rows = grid.rows
                updated.cols = grid.cols
            }
            let grid = PartsGrid(rect: updated.gridRect ?? part.bounds,
                                 rows: updated.rows, cols: updated.cols)

            let sampled = sampleCells(work: work, part: updated)
            if sampled == nil { unreadableParts += 1 }
            let labs = sampled
                ?? [[LabColor?]](repeating: [LabColor?](repeating: nil, count: max(grid.cols, 0)),
                                 count: max(grid.rows, 0))
            cellLabs.append(labs)
            updated.cells = Array(repeating: Array(repeating: .empty, count: grid.cols), count: grid.rows)
            fittedParts.append(updated)
            progress?(index + 1, parts.count)
        }

        // 第二趟：把所有格子的颜色聚成十几类
        let clusters = cluster(cellLabs: cellLabs)

        // 第三趟：每一类认领一个身份（空 / 某个色号）
        let assignments = assignIdentities(
            clusters: clusters,
            backgroundLab: backgroundLab,
            anyColorLab: anyColorLab,
            colorSystem: colorSystem,
            legendCodes: legendCodes,
            availableColors: availableColors
        )

        // 第四趟：把结论填回每一格
        for p in fittedParts.indices {
            for r in 0..<fittedParts[p].rows {
                for c in 0..<fittedParts[p].cols {
                    guard let lab = cellLabs[p][r][c] else {
                        fittedParts[p].cells[r][c] = .empty
                        continue
                    }
                    let index = nearestCluster(lab, clusters)
                    fittedParts[p].cells[r][c] = assignments[index].fill
                }
            }
        }

        let totalCells = fittedParts.reduce(0) { $0 + $1.rows * $1.cols }
        let palette = assignments.enumerated().map { index, entry in
            PartsPaletteEntry(
                hex: entry.hex,
                pixelShare: totalCells > 0 ? Double(clusters[index].count) / Double(totalCells) : 0,
                role: entry.role,
                matchDeltaE: entry.deltaE
            )
        }
        return Result(parts: fittedParts, palette: palette,
                      unreadableParts: unreadableParts, cellLabs: cellLabs)
    }

    // MARK: - 采样

    /// 量出一个零件每一格的颜色。
    ///
    /// **取众数，不取平均。** 图纸给每颗豆子都描了一圈深色边，一格才十来个像素，
    /// 边线一平均进去，整格的颜色就被往深处拉；拉的多少又取决于网格差了几分之一格，
    /// 于是同一种豆子的颜色被抹成一条连续的谱，聚类顺着这条谱把淡紫、白、粉全串成一类
    /// —— 实测就是这个下场：一个色号底下混着三四种明显不同的颜色。
    ///
    /// 众数只认「这一格里最多的那个颜色」。描边再深也只占一圈，占不到一半，直接被无视；
    /// 网格差个几分之一格也不影响结论。
    /// - Returns: `nil` = 这个零件的图**根本没抠出来**（框太小 / 解码失败），一格都没看到。
    ///   早先这里跟「看过了，每格都是背景」一样返回全 nil 的矩阵，两件事在数据上再也分不开。
    private static func sampleCells(work: PartsWorkImage, part: BeadPart) -> [[LabColor?]]? {
        let area = part.gridRect ?? part.bounds
        guard part.rows > 0, part.cols > 0,
              let bitmap = PartsBitmap.make(from: work, roi: area, maxPixels: 600_000) else {
            return nil
        }
        var result = [[LabColor?]](repeating: [LabColor?](repeating: nil, count: part.cols), count: part.rows)
        let cellW = Double(bitmap.width) / Double(part.cols)
        let cellH = Double(bitmap.height) / Double(part.rows)

        var counts: [Int32: Int] = [:]
        counts.reserveCapacity(64)
        for r in 0..<part.rows {
            for c in 0..<part.cols {
                // 取格子中间 60%：既躲开描边，又留够像素让众数有意义
                let x0 = max(0, Int((Double(c) + 0.2) * cellW))
                let x1 = min(bitmap.width - 1, Int((Double(c) + 0.8) * cellW))
                let y0 = max(0, Int((Double(r) + 0.2) * cellH))
                let y1 = min(bitmap.height - 1, Int((Double(r) + 0.8) * cellH))
                guard x1 >= x0, y1 >= y0 else { continue }

                counts.removeAll(keepingCapacity: true)
                for y in y0...y1 {
                    let row = y * bitmap.width
                    for x in x0...x1 {
                        counts[bitmap.quantized[row + x], default: 0] += 1
                    }
                }
                if let winner = counts.max(by: { $0.value < $1.value })?.key {
                    result[r][c] = QuantizedRGB.labTable[Int(winner)]
                }
            }
        }
        return result
    }

    // MARK: - 聚类

    private struct Cluster {
        var lab: LabColor
        var count: Int
    }

    private static func cluster(cellLabs: [[[LabColor?]]]) -> [Cluster] {
        var clusters: [Cluster] = []
        for part in cellLabs {
            for row in part {
                for case let lab? in row {
                    var nearest = -1
                    var nearestDE = Double.infinity
                    for (i, cluster) in clusters.enumerated() {
                        let de = GridCellSampler.deltaE(lab, cluster.lab)
                        if de < nearestDE { nearestDE = de; nearest = i }
                    }
                    if nearestDE <= mergeDeltaE, nearest >= 0 {
                        // 增量更新中心，让中心慢慢挪到这一类的重心上
                        let c = clusters[nearest]
                        let total = Double(c.count + 1)
                        clusters[nearest] = Cluster(
                            lab: LabColor(
                                l: (c.lab.l * Double(c.count) + lab.l) / total,
                                a: (c.lab.a * Double(c.count) + lab.a) / total,
                                b: (c.lab.b * Double(c.count) + lab.b) / total
                            ),
                            count: c.count + 1
                        )
                    } else {
                        clusters.append(Cluster(lab: lab, count: 1))
                    }
                }
            }
        }
        return clusters.sorted { $0.count > $1.count }
    }

    private static func nearestCluster(_ lab: LabColor, _ clusters: [Cluster]) -> Int {
        var best = 0
        var bestDE = Double.infinity
        for (i, cluster) in clusters.enumerated() {
            let de = GridCellSampler.deltaE(lab, cluster.lab)
            if de < bestDE { bestDE = de; best = i }
        }
        return best
    }

    // MARK: - 认领身份

    private struct Identity {
        var fill: PartCellFill
        var role: PartsPaletteEntry.Role
        var hex: String
        var deltaE: Double?
    }

    private static func assignIdentities(
        clusters: [Cluster],
        backgroundLab: LabColor?,
        anyColorLab: LabColor?,
        colorSystem: ColorSystem,
        legendCodes: [String],
        availableColors: [BeadColor]
    ) -> [Identity] {
        func table(_ colors: [BeadColor]) -> [(code: String, lab: LabColor)] {
            colors.compactMap { color in
                guard color.hasCode(for: colorSystem),
                      let lab = GridCellSampler.lab(forHex: color.colorHex) else { return nil }
                return (color.displayCode(for: colorSystem), lab)
            }
        }
        let legendSet = Set(legendCodes)
        let legendTable = table(availableColors.filter { legendSet.contains($0.displayCode(for: colorSystem)) })
        let fullTable = table(availableColors)

        // **图纸自己写了用色表，就只在这张表里选。**
        //
        // 上一版是「图例里 ΔE ≤ 25 才用图例，否则去几百色的全色库里找最近的」，
        // 结果图纸上明明只有十来种豆子，却认出一堆表上压根没有的色号 ——
        // 用户实测：黑色的 H7 被判成了 23。全色库里总有一个色差更小的，
        // 但那个色号这张图纸上根本不存在，用户拿着它去翻库存只会一头雾水。
        //
        // 代价是：图例漏写的颜色会被硬套到最近的那个图例色号上。这个代价可以接受 ——
        // 它会整类扎堆出现在核对那一屏，用户一眼看得见，一次就能整类改掉；
        // 而散落在几百个色号里的假色号是找都找不出来的。
        // 图例为空（用户手动建的项目、没识别色号表）时才退回全色库。
        let table = legendTable.isEmpty ? fullTable : legendTable

        return clusters.map { cluster in
            // **先认任意色，再认底色，最后才轮到色号。**
            //
            // 顺序不能反。任意色和底色都不是色号，可它们在图上是实实在在的一大片格子：
            // 不先摘出去，就会被硬套到最近的那个色号上 —— 这张图纸上「任意色」有两千多颗，
            // 一旦混进某个色号，用户在核对页看到的是「这个色号里掺了一大堆不该有的」，
            // 而它们和真的那些混在同一类里，整类改也不是、一格格挑也不是。
            //
            // 这也是为什么这两样必须让用户指认：底色每张图纸都不一样（这张是浅粉），
            // 任意色更是完全看不出来 —— 它在图上就是一种普通的淡紫豆子，
            // 「它代表任意色」这件事只写在色号表那一行字里。
            if let anyColorLab, GridCellSampler.deltaE(cluster.lab, anyColorLab) <= pickedDeltaE {
                return Identity(fill: .anyColor, role: .anyColor, hex: hex(of: cluster.lab), deltaE: nil)
            }
            if let backgroundLab, GridCellSampler.deltaE(cluster.lab, backgroundLab) <= emptyDeltaE {
                return Identity(fill: .empty, role: .empty, hex: hex(of: cluster.lab), deltaE: nil)
            }
            if let hit = nearest(cluster.lab, in: table) {
                return Identity(fill: .code(hit.0), role: .code(hit.0), hex: hex(of: cluster.lab), deltaE: hit.1)
            }
            return Identity(fill: .empty, role: .empty, hex: hex(of: cluster.lab), deltaE: nil)
        }
    }

    private static func nearest(_ lab: LabColor, in table: [(code: String, lab: LabColor)]) -> (String, Double)? {
        var best: (String, Double)?
        for (code, reference) in table {
            let de = GridCellSampler.deltaE(lab, reference)
            if best == nil || de < best!.1 { best = (code, de) }
        }
        return best
    }

    /// Lab → 近似 sRGB hex，只用来在界面上显示一个色块
    private static func hex(of lab: LabColor) -> String {
        func f(_ t: Double) -> Double { t > 6.0/29 ? t * t * t : 3 * (6.0/29) * (6.0/29) * (t - 4.0/29) }
        let fy = (lab.l + 16) / 116
        let fx = fy + lab.a / 500
        let fz = fy - lab.b / 200
        let x = 0.95047 * f(fx), y = 1.0 * f(fy), z = 1.08883 * f(fz)
        func gamma(_ c: Double) -> Double {
            let v = c <= 0.0031308 ? 12.92 * c : 1.055 * pow(max(c, 0), 1 / 2.4) - 0.055
            return max(0, min(255, v * 255))
        }
        let r = gamma(x * 3.2404542 - y * 1.5371385 - z * 0.4985314)
        let g = gamma(-x * 0.9692660 + y * 1.8760108 + z * 0.0415560)
        let b = gamma(x * 0.0556434 - y * 0.2040259 + z * 1.0572252)
        return String(format: "%02X%02X%02X", Int(r.rounded()), Int(g.rounded()), Int(b.rounded()))
    }
}
