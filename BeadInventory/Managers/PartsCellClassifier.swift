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
    ///
    /// 取 6。早先是 8，那时每格颜色是归到量化桶上的（每档 3~4 个单位），得留出这份余量；
    /// 现在判色用的是一簇像素的中位色（`sampleCells`），抖动小得多。8 在实测图纸上把
    /// 206 号米色和 131 号浅肉色（差 8.4）并成了一类，核对页上一组两种颜色，没法整组改。
    /// 6 在同一张图纸上没有把同一种颜色拆成两组。
    ///
    /// **不是 `private`**：核对页的「排序」也拿它并类（`PartsColorReviewStepView.sorted`）。
    /// 两边各写一个数的话，改了这边不会有任何报错，而用户会在核对页看到一种颜色被切成两片。
    static let mergeDeltaE: Double = 6

    /// 判成「空」的条件：跟图纸背景色的距离在这个范围内。
    /// 零件中间的镂空和零件外面蹭进框里的背景是同一种像素，一起归到空。
    private static let emptyDeltaE: Double = 14

    /// 用户亲手在图上点出来的颜色（底色 / 任意色）的认领范围。
    /// 比 `mergeDeltaE`(8) 宽一点：他点的是某一格，而同一片色块在 JPEG 压缩之后
    /// 各格之间本来就有几个单位的漂移，卡太死会漏掉一半。
    private static let pickedDeltaE: Double = 12

    /// 图例里最接近的那个色号离这一类还有这么远，就当**图例解释不了这一类**，
    /// 退回全色库找最近的（见 `assignIdentities`）。
    ///
    /// 取 `mergeDeltaE`(8) 的两倍：8 是「同一种颜色的两格之间的抖动」，翻一倍留够图纸
    /// 压缩和印色偏差的余量；再远就不是同一种豆子了，硬套上去只是给用户一个错色号。
    ///
    /// 这条出路必须有：图例本来就可能不全 —— AI 读出来的码色库里没有（图纸印的是我们
    /// 没收录的品牌）、用户手建的计划项目只挑了几个色号、色号表那一栏干脆漏读了。
    /// 没有出路时，图上十几种颜色会被整整齐齐地塞进仅剩的那几个色号里，
    /// 而且**塞进同一个色号的几类在核对页会合成一组**，用户连「整类改掉」都做不到，
    /// 只能一格一格挑 —— 这正是这条阈值要挡住的下场。
    private static let legendMissDeltaE: Double = 16

    /// 在图上某一点取色，返回 `RRGGBB`。
    ///
    /// 取的是**一小片里占地最大的那种颜色**（`dominantColor`）而不是那一个像素：
    /// 用户手指点不了那么准，而豆子之间还有深色的格线，格子上还可能印着色号字，
    /// 正好点在线上或字上就会取到一个根本不存在的颜色。
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
        guard let winner = dominantColor(histogram) else { return nil }
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
        /// 图例里在色库中查无此码的那些色号（"HR"、"FG" 这种）。
        ///
        /// **必须报给用户**：这些颜色的格子最后按全色库里最接近的色号判，核对页上写的字
        /// 跟图纸色号表上印的不是同一个。不说的话用户只会问「图纸上明明有 HR，
        /// 怎么一个都没有」—— 而他在这一屏找不到任何线索。
        var unknownLegendCodes: [String]
        /// 所在那张图纸在这台设备上没有图、这次没判的零件数。它们原样保留，一格都没动 ——
        /// 原图不走 iCloud，换一台设备、或者点过「拼好了」都会这样，这不是框的问题。
        var skippedParts = 0

        /// 上面那些对不上的色号该怎么跟用户说。nil = 没有这回事，别打扰他。
        /// 两条流程（多零件 / 单图纸）共用一份说法 —— 同一件事在两屏上写成两样只会更难懂。
        var unknownLegendNote: String? {
            guard !unknownLegendCodes.isEmpty else { return nil }
            // 色号表能有几十个色号，全列出来那句话就没人看了。
            let shown = unknownLegendCodes.prefix(4).joined(separator: "、")
            let codes = unknownLegendCodes.count > 4
                ? String(localized: "\(shown) 等 \(unknownLegendCodes.count) 个色号")
                : shown
            return String(localized: "图纸色号表里的 \(codes)，在当前色号体系里对不上色库中的任何一种豆子。这些格子是按最接近的颜色判的，写的色号跟图纸上印的不是同一个 —— 核对时留意一下。")
        }
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
        classify(pages: PartsPages(single: work), parts: parts, roi: roi,
                 calibrations: [calibration], colorSystem: colorSystem,
                 legendCodes: legendCodes, availableColors: availableColors,
                 emptyHex: emptyHex, anyColorHex: anyColorHex, progress: progress)
    }

    /// 零件分在好几张图纸上时。所有零件**一起**聚类 —— 同一种豆子在哪张图上都得是同一个色号。
    /// 每个零件从它自己那张图上取像素、按那张的标定切格（`BeadPart.page`）。
    ///
    /// - Parameters:
    ///   - roi: 第 0 张的零件区。底色没指认时从这里猜。
    ///   - calibrations: 每张一份，下标是第几张
    static func classify(
        pages: PartsPages,
        parts: [BeadPart],
        roi: CGRect,
        calibrations: [PartsGridCalibration?],
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
            ?? pages[0].flatMap { PartsBitmap.make(from: $0, roi: roi, maxPixels: 400_000) }
                .map { PartsDetector.backgroundLab(of: $0) }
        // 任意色：只有用户指认了才有。它不是色号，猜不出来 —— 图纸上它就是一种普通的
        // 淡色，跟别的豆子长得一样，唯一的区别写在色号表那一行字里。
        let anyColorLab = anyColorHex.flatMap { GridCellSampler.lab(forHex: $0) }
        // 图例的码先翻成色库里的豆子。**不能直接拿这些字符串去比**，理由见 resolveLegend。
        let legend = resolveLegend(codes: legendCodes,
                                   availableColors: availableColors,
                                   colorSystem: colorSystem)
        // 图例解释不了的那几类要去全色库兜底。兜底的范围按体系收窄，理由见 `matchableColors`。
        // 图例必须拿**没收窄的**色库去翻：图例里写了 P12，它就得认得出来。
        let matchable = matchableColors(availableColors, legendColors: legend.colors,
                                        colorSystem: colorSystem)

        // 第一趟：把每个零件切格、量出每格的颜色
        var fittedParts: [BeadPart] = []
        var cellLabs: [[[LabColor?]]] = []      // [part][row][col]
        // 被线围死、只有一格大的格子（见 `PartsCellEnclosure`）。颜色再像底色也不能判空。
        var enclosed: [[[Bool]]] = []           // [part][row][col]
        var unreadableParts = 0
        // 所在那张图纸没图的零件：不参与聚类，最后原样放回。下标对着 `parts`。
        var skipped: [Int: BeadPart] = [:]
        for (index, part) in parts.enumerated() {
            // 那张图纸不在这台设备上：别动它的格子。判成一片空的话，手工核对过的颜色就没了，
            // 还会经 iCloud 同步回原来那台设备。
            guard pages.work(for: part) != nil else {
                skipped[index] = part
                progress?(index + 1, parts.count)
                continue
            }
            var updated = part
            // 「量格子」那屏已经给这个零件定好格线了（格距全图共用，相位一个零件一个 ——
            // 图纸上零件是各画各的）。这里必须**照用**，不能再拿全局标定重吸一遍：
            // 那样会把用户刚在那一屏对好的位置整片洗掉。
            // 没定过的（用户跳过了那一屏）才退回它那一张图纸的标定。
            if let rect = part.gridRect, part.rows > 0, part.cols > 0 {
                updated.gridRect = rect
            } else if let calibration = calibrations.indices.contains(part.pageIndex)
                        ? calibrations[part.pageIndex] : nil {
                let grid = part.grid(for: calibration)
                updated.gridRect = grid.rect
                updated.rows = grid.rows
                updated.cols = grid.cols
            }
            let grid = PartsGrid(rect: updated.gridRect ?? part.bounds,
                                 rows: updated.rows, cols: updated.cols)

            let bitmap = pages.work(for: updated).flatMap { cellBitmap(work: $0, part: updated) }
            let sampled = bitmap.flatMap { sampleCells(bitmap: $0, part: updated) }
            if sampled == nil { unreadableParts += 1 }
            let labs = sampled
                ?? [[LabColor?]](repeating: [LabColor?](repeating: nil, count: max(grid.cols, 0)),
                                 count: max(grid.rows, 0))
            cellLabs.append(labs)
            enclosed.append(enclosedLightCells(bitmap: bitmap, part: updated, labs: labs,
                                               backgroundLab: backgroundLab))
            updated.cells = Array(repeating: Array(repeating: .empty, count: grid.cols), count: grid.rows)
            fittedParts.append(updated)
            progress?(index + 1, parts.count)
        }

        // 第二趟：把所有格子的颜色聚成十几类。
        // 被线围死的浅色格子**单独聚**：它们跟白纸同色，混在一起聚的话会跟背景并成一类，
        // 整类被认成空。分开聚、认身份时不给「空」这个选项，它们就只能认色号（或任意色）。
        let mainLabs = cellLabs.indices.map { p in
            cellLabs[p].indices.map { r in
                cellLabs[p][r].indices.map { c in enclosed[p][r][c] ? nil : cellLabs[p][r][c] }
            }
        }
        let enclosedLabs = cellLabs.indices.map { p in
            cellLabs[p].indices.map { r in
                cellLabs[p][r].indices.map { c in enclosed[p][r][c] ? cellLabs[p][r][c] : nil }
            }
        }
        let clusters = cluster(cellLabs: mainLabs)
        let enclosedClusters = cluster(cellLabs: enclosedLabs)

        // 第三趟：每一类认领一个身份（空 / 某个色号）
        var assignments = assignIdentities(
            clusters: clusters,
            backgroundLab: backgroundLab,
            anyColorLab: anyColorLab,
            colorSystem: colorSystem,
            legendColors: legend.colors,
            availableColors: matchable
        )
        var enclosedAssignments = assignIdentities(
            clusters: enclosedClusters,
            backgroundLab: nil,
            anyColorLab: anyColorLab,
            colorSystem: colorSystem,
            legendColors: legend.colors,
            availableColors: matchable
        )

        // 颜色明显不同的两类不许认同一个色号（理由见 `separateDistinctClusters`）。
        // 两份类一起看：白豆子可能一半在普通类、一半在「被线围死」那份里，它们同色，可以同号。
        do {
            var all = assignments + enclosedAssignments
            separateDistinctClusters(identities: &all, clusters: clusters + enclosedClusters,
                                     colorSystem: colorSystem, legendColors: legend.colors,
                                     availableColors: matchable)
            assignments = Array(all[..<assignments.count])
            enclosedAssignments = Array(all[assignments.count...])
        }

        // 第四趟：把结论填回每一格
        for p in fittedParts.indices {
            for r in 0..<fittedParts[p].rows {
                for c in 0..<fittedParts[p].cols {
                    guard let lab = cellLabs[p][r][c] else {
                        fittedParts[p].cells[r][c] = .empty
                        continue
                    }
                    if enclosed[p][r][c] {
                        let index = nearestCluster(lab, enclosedClusters)
                        fittedParts[p].cells[r][c] = enclosedAssignments[index].fill
                    } else {
                        let index = nearestCluster(lab, clusters)
                        fittedParts[p].cells[r][c] = assignments[index].fill
                    }
                }
            }
        }

        let totalCells = fittedParts.reduce(0) { $0 + $1.rows * $1.cols }
        func entries(_ assignments: [Identity], _ clusters: [Cluster]) -> [PartsPaletteEntry] {
            assignments.enumerated().map { index, entry in
                PartsPaletteEntry(
                    hex: entry.hex,
                    pixelShare: totalCells > 0 ? Double(clusters[index].count) / Double(totalCells) : 0,
                    role: entry.role,
                    matchDeltaE: entry.deltaE
                )
            }
        }
        // 两份可能出现同一个色号（白纸那类之外还有白豆子）。核对页按格子里的色号分组，
        // 同号自然并成一组；这份调色板只给「只重判一块」查表用，重复不碍事。
        let palette = entries(assignments, clusters) + entries(enclosedAssignments, enclosedClusters)
        // 没判的那几块按原来的位置插回去，零件清单的顺序不变
        var merged: [BeadPart] = []
        merged.reserveCapacity(parts.count)
        var judged = fittedParts.makeIterator()
        for index in parts.indices {
            if let kept = skipped[index] { merged.append(kept) }
            else if let part = judged.next() { merged.append(part) }
        }
        return Result(parts: merged, palette: palette, unreadableParts: unreadableParts,
                      unknownLegendCodes: legend.unknownCodes, skippedParts: skipped.count)
    }

    // MARK: - 采样

    /// 判色用的每格颜色。取哪一簇跟 `sampleModes` 完全一样，只是**不再归到一个量化桶上**，
    /// 而是取那一簇像素的中位色（`dominantLab`）。
    ///
    /// 为什么要这么细：量化桶每档 RGB 差 8，换成 Lab 是 3~4 个单位。实测一张图纸上 211 号肉色
    /// 和 257 号粉色只差 8.5，JPEG 再一抖、归到桶上，两种颜色的格子就落进同一片，
    /// 聚类把它们并成一类，核对页上一组里一半肉色一半粉色，怎么分色号都分不开。
    /// 中位色是几十个像素一起投出来的，抖动基本抵消。
    ///
    /// 核对页排序仍然用 `sampleModes` 的量化索引：它只是排个先后，不需要这么细。
    /// - Returns: `nil` = 这个零件的图根本没抠出来。
    private static func sampleCells(bitmap: PartsBitmap, part: BeadPart) -> [[LabColor?]]? {
        measureCells(bitmap: bitmap, part: part, pick: dominantLab)
    }

    /// 一个零件格子区的位图。取色和「被线围死」两件事共用这一张，只解一次。
    /// `nil` = 格线没定好，或者图根本没抠出来。
    private static func cellBitmap(work: PartsWorkImage, part: BeadPart) -> PartsBitmap? {
        guard part.rows > 0, part.cols > 0 else { return nil }
        return PartsBitmap.make(from: work, roi: part.gridRect ?? part.bounds,
                               maxPixels: cellSamplingPixels(rows: part.rows, cols: part.cols))
    }

    /// 这个零件里哪些格子「被线围死、颜色又像底色」—— 这些是浅色豆子，不能判空。
    ///
    /// 只挑颜色像底色的格子：别的格子本来就不会被判空，没必要换一条路走。
    /// 「像」放宽到 `emptyDeltaE + mergeDeltaE`：判空看的是聚类中心，单格比中心远几个单位
    /// 照样会跟着整类被判空。
    ///
    /// **整张纸都印满格子的图纸**上，零件外面的白纸也被线围成一格一格，全会被当成豆子。
    /// 认它的办法：零件框最外一圈的浅色格子大半都「被围死」—— 正常图纸上那一圈多半是
    /// 零件外面的白纸，连通到框外。碰到这种就整块不用这条规则，退回只看颜色。
    private static func enclosedLightCells(bitmap: PartsBitmap?, part: BeadPart,
                                           labs: [[LabColor?]],
                                           backgroundLab: LabColor?) -> [[Bool]] {
        let none = labs.map { $0.map { _ in false } }
        guard let bitmap, let backgroundLab, labs.count == part.rows,
              labs.allSatisfy({ $0.count == part.cols }) else { return none }
        let walled = PartsCellEnclosure.enclosedCells(bitmap: bitmap, rows: part.rows, cols: part.cols,
                                                      backgroundLab: backgroundLab)
        var result = none
        var ringLight = 0
        var ringWalled = 0
        for r in 0..<part.rows {
            for c in 0..<part.cols {
                guard let lab = labs[r][c],
                      GridCellSampler.deltaE(lab, backgroundLab) <= emptyDeltaE + mergeDeltaE else { continue }
                result[r][c] = walled[r][c]
                if r == 0 || c == 0 || r == part.rows - 1 || c == part.cols - 1 {
                    ringLight += 1
                    if walled[r][c] { ringWalled += 1 }
                }
            }
        }
        if ringLight >= 4 && ringWalled * 2 > ringLight { return none }
        return result
    }

    /// 量出一个零件每一格的颜色，值是 `QuantizedRGB` 索引，**`-1` = 这一格没量到**。
    ///
    /// **不取平均。** 图纸给每颗豆子都描了一圈深色边，一格才十来个像素，
    /// 边线一平均进去，整格的颜色就被往深处拉；拉的多少又取决于网格差了几分之一格，
    /// 于是同一种豆子的颜色被抹成一条连续的谱，聚类顺着这条谱把淡紫、白、粉全串成一类
    /// —— 实测就是这个下场：一个色号底下混着三四种明显不同的颜色。
    ///
    /// **也不取单个量化桶的众数。** 那是上一版，栽在格子里印的色号字上：底色在 JPEG 里
    /// 抖得厉害，散进几百个桶，每桶只有 2%~3%；黑字却挤在几个深色桶里。字一粗
    /// （「G5」这种两个字挤满中间的，黑字占三分之一），最大的桶就是黑字，整格判成
    /// 近黑的色号 —— 用户看到一片黄豆子被分进了黑色（P49 / B251）。
    ///
    /// 现在是把一格的像素按颜色分成几簇，取占地最大的那簇（`dominantColor`）。
    /// 底色那几百个桶会并成一簇，字和描边各成一簇，底色只要比字多就赢。
    ///
    /// 判色和核对页的「排序」共用这一趟取样。两边必须量出同一个颜色 —— 否则排序会把某一格
    /// 排在「跟这一类很像」的位置上，而它当初正是因为不像才被判错的，用户就永远找不到它。
    ///
    /// - Important: 传进来的 part **必须已经定好格线**（`gridRect` / `rows` / `cols`）。
    ///   这里不做 `classify` 第一趟那种回退标定，没定过的直接返回 nil。
    /// - Returns: `nil` = 这个零件的图**根本没抠出来**（框太小 / 解码失败），一格都没看到。
    ///   早先这里跟「看过了，每格都是背景」一样返回全 nil 的矩阵，两件事在数据上再也分不开。
    static func sampleModes(work: PartsWorkImage, part: BeadPart) -> [[Int32]]? {
        cellBitmap(work: work, part: part).flatMap { sampleModes(bitmap: $0, part: part) }
    }

    private static func sampleModes(bitmap: PartsBitmap, part: BeadPart) -> [[Int32]]? {
        measureCells(bitmap: bitmap, part: part, pick: dominantColor)
            .map { $0.map { $0.map { $0 ?? -1 } } }
    }

    /// 逐格数一遍量化桶，交给 `pick` 从直方图里挑出这一格的颜色。`nil` = 这一格没量到。
    private static func measureCells<T>(bitmap: PartsBitmap, part: BeadPart,
                                        pick: ([Int32: Int]) -> T?) -> [[T?]]? {
        guard part.rows > 0, part.cols > 0 else { return nil }
        var result = [[T?]](repeating: [T?](repeating: nil, count: part.cols), count: part.rows)
        let cellW = Double(bitmap.width) / Double(part.cols)
        let cellH = Double(bitmap.height) / Double(part.rows)

        var counts: [Int32: Int] = [:]
        counts.reserveCapacity(64)
        for r in 0..<part.rows {
            for c in 0..<part.cols {
                // 去掉四周各 15%，大部分描边和蹭进来的邻格就不看了。剩下的描边、
                // 色号字由分簇处理，用不着再往里缩 —— 缩得越多，字占的比例反而越大。
                let x0 = max(0, Int((Double(c) + 0.15) * cellW))
                let x1 = min(bitmap.width - 1, Int((Double(c) + 0.85) * cellW))
                let y0 = max(0, Int((Double(r) + 0.15) * cellH))
                let y1 = min(bitmap.height - 1, Int((Double(r) + 0.85) * cellH))
                guard x1 >= x0, y1 >= y0 else { continue }

                counts.removeAll(keepingCapacity: true)
                for y in y0...y1 {
                    let row = y * bitmap.width
                    for x in x0...x1 {
                        counts[bitmap.quantized[row + x], default: 0] += 1
                    }
                }
                result[r][c] = pick(counts)
            }
        }
        return result
    }

    /// 一小片像素里**占地最大的那种颜色**，返回 `QuantizedRGB` 索引。
    ///
    /// 做法：把这些量化桶按 Lab 分成 3 簇（k-means，按像素数加权），离得近的簇合并，
    /// 取像素最多的那簇，再从簇里挑离簇中心最近的那个桶当代表。分 3 簇是因为一格里通常就三样东西：
    /// 豆子本身、深色的字和描边、两者之间糊出来的过渡色。
    ///
    /// 为什么不直接数哪个桶最多，见 `sampleModes` 的方法头。
    ///
    /// 代表取簇里的一个真实桶，不取簇的平均：平均出来的颜色可能不在任何一个像素上，
    /// 跟 `sampleModes` 返回量化索引的约定也对不上。
    ///
    /// - Parameter histogram: 量化桶 → 像素数
    static func dominantColor(_ histogram: [Int32: Int]) -> Int32? {
        guard let group = dominantGroup(histogram) else { return nil }
        var representative = -1
        var representativeD = Double.infinity
        for i in group.members.sorted() {
            let d = GridCellSampler.deltaE(group.labs[i], group.center)
            if d < representativeD { representativeD = d; representative = i }
        }
        return representative >= 0 ? group.keys[representative] : nil
    }

    /// 跟 `dominantColor` 挑同一簇，返回这一簇的**加权中位色**（L、a、b 各取中位数）。
    ///
    /// 不取平均：簇里会夹着字边上糊出来的过渡色，平均会被它往深处拽；中位数不受这几个影响。
    static func dominantLab(_ histogram: [Int32: Int]) -> LabColor? {
        guard let group = dominantGroup(histogram) else { return nil }
        let members = Array(group.members)
        func median(_ value: (LabColor) -> Double) -> Double {
            let sorted = members.sorted { value(group.labs[$0]) < value(group.labs[$1]) }
            let half = sorted.reduce(0) { $0 + group.weights[$1] } / 2
            var acc = 0.0
            for i in sorted {
                acc += group.weights[i]
                if acc >= half { return value(group.labs[i]) }
            }
            return value(group.labs[sorted.last!])
        }
        return LabColor(l: median { $0.l }, a: median { $0.a }, b: median { $0.b })
    }

    /// `dominantColor` / `dominantLab` 共用的分簇：返回占地最大那一簇。
    private static func dominantGroup(_ histogram: [Int32: Int])
        -> (keys: [Int32], labs: [LabColor], weights: [Double], members: Set<Int>, center: LabColor)? {
        let buckets = histogram.filter { $0.value > 0 }
        guard !buckets.isEmpty else { return nil }
        let keys = Array(buckets.keys)
        if keys.count == 1 {
            let lab = QuantizedRGB.labTable[Int(keys[0])]
            return (keys, [lab], [Double(buckets[keys[0]]!)], [0], lab)
        }
        let weights = keys.map { Double(buckets[$0]!) }
        let labs = keys.map { QuantizedRGB.labTable[Int($0)] }
        func dist2(_ a: LabColor, _ b: LabColor) -> Double {
            let dl = a.l - b.l, da = a.a - b.a, db = a.b - b.b
            return dl * dl + da * da + db * db
        }

        // 初始中心：先取最重的桶，之后每次取「像素数 × 离现有中心距离²」最大的桶。
        // 不用随机 —— 同一张图每次判出来必须一样，否则用户重进一次核对页结果就变了。
        let k = min(3, keys.count)
        var centers = [labs[weights.indices.max { weights[$0] < weights[$1] }!]]
        while centers.count < k {
            var best = -1
            var bestScore = 0.0
            for i in keys.indices {
                let d = centers.map { dist2(labs[i], $0) }.min()!
                let score = weights[i] * d
                if score > bestScore { bestScore = score; best = i }
            }
            guard best >= 0 else { break }   // 剩下的桶全跟某个中心重合
            centers.append(labs[best])
        }

        var assignment = [Int](repeating: 0, count: keys.count)
        for _ in 0..<8 {
            for i in keys.indices {
                var nearest = 0
                var nearestD = Double.infinity
                for (j, center) in centers.enumerated() {
                    let d = dist2(labs[i], center)
                    if d < nearestD { nearestD = d; nearest = j }
                }
                assignment[i] = nearest
            }
            var sums = [(l: Double, a: Double, b: Double, w: Double)](
                repeating: (0, 0, 0, 0), count: centers.count)
            for i in keys.indices {
                let j = assignment[i], w = weights[i]
                sums[j].l += labs[i].l * w
                sums[j].a += labs[i].a * w
                sums[j].b += labs[i].b * w
                sums[j].w += w
            }
            for j in centers.indices where sums[j].w > 0 {
                centers[j] = LabColor(l: sums[j].l / sums[j].w,
                                      a: sums[j].a / sums[j].w,
                                      b: sums[j].b / sums[j].w)
            }
        }

        // **离得近的簇合回去再比大小。** 底色在 JPEG 里抖得散时，3 簇会把底色劈成两半，
        // 每半都比挤成一团的黑字小，黑字反倒赢了 —— 不合并就还是原来那个 bug。
        // 合并距离 20：同一种颜色劈开的两半中心只差几个到十几个单位，
        // 而字和底色差 50 往上，不会被合到一起。
        var groups: [(center: LabColor, weight: Double, members: Set<Int>)] = centers.indices.map { j in
            let members = Set(keys.indices.filter { assignment[$0] == j })
            return (centers[j], members.reduce(0) { $0 + weights[$1] }, members)
        }
        while groups.count > 1 {
            var pair = (0, 1)
            var pairD = Double.infinity
            for i in groups.indices {
                for j in groups.indices where j > i {
                    let d = dist2(groups[i].center, groups[j].center)
                    if d < pairD { pairD = d; pair = (i, j) }
                }
            }
            guard pairD < Self.sameColorClusterDeltaE * Self.sameColorClusterDeltaE else { break }
            let a = groups[pair.0], b = groups[pair.1]
            let total = a.weight + b.weight
            let center = total > 0
                ? LabColor(l: (a.center.l * a.weight + b.center.l * b.weight) / total,
                           a: (a.center.a * a.weight + b.center.a * b.weight) / total,
                           b: (a.center.b * a.weight + b.center.b * b.weight) / total)
                : a.center
            groups[pair.0] = (center, total, a.members.union(b.members))
            groups.remove(at: pair.1)
        }

        let winner = groups.max { $0.weight < $1.weight }!
        return (keys, labs, weights, winner.members, winner.center)
    }

    /// `dominantColor` 分完簇以后，中心离这么近的两簇算同一种颜色被劈开了，合回去。
    private static let sameColorClusterDeltaE: Double = 20

    /// 量一个零件时位图最多用多少像素：保证每格至少 `minCellSide` × `minCellSide`。
    ///
    /// **不能用一个固定上限。** 早先是一律 60 万像素，大零件（几十乘几十格的整块板）被压到
    /// 一格只剩 12 像素左右。格子里印的白字一糊开，占的面积比深色底还大，`dominantColor`
    /// 取到的就是字的浅灰 —— 用户看到的是同一种深棕豆子（G8），小零件上判对了，
    /// 大零件上整片被分进浅灰色号（B212）。实测一格 15 像素起就不再出错，取 24 留余量。
    ///
    /// 位图像素本来就不会超过工作图里这块区域的实际大小（`PartsBitmap.make` 只缩不放），
    /// 所以小零件不受影响；上限 600 万像素是给内存兜底的，一次只量一个零件。
    private static func cellSamplingPixels(rows: Int, cols: Int) -> Int {
        let wanted = rows * cols * minCellSide * minCellSide
        return min(max(600_000, wanted), 6_000_000)
    }

    private static let minCellSide = 24

    /// 把所有零件每一格的颜色量一遍，给核对页排序用。`[零件][行][列]`，`-1` = 没量到。
    ///
    /// 跟 `classify` 的第一趟是同一件事，但这里**只量颜色**（也不做那趟的回退标定）：
    /// 核对页要的就是「这一格的原色离这一类有多远」，跟聚类、跟色号都无关。
    /// 耗时随零件数线性涨（一张平面图纸就是一个零件），调用方请放后台。
    ///
    /// 图没抠出来的零件在这里退化成一整片 `-1`，**不单独报数** —— 调用方（核对页排序）
    /// 对「没量到」只有一种处理：排到最后。`classify` 那边不一样，它必须把
    /// `unreadableParts` 报给用户，因为那关系到「要不要回去把框圈大点」。
    ///
    /// - Parameter progress: (已完成零件数, 总数)
    static func sampleModes(
        work: PartsWorkImage,
        parts: [BeadPart],
        progress: ((Int, Int) -> Void)? = nil
    ) -> [[[Int32]]] {
        sampleModes(pages: PartsPages(single: work), parts: parts, progress: progress)
    }

    /// 同上，每个零件从它自己那张图纸上取（`BeadPart.page`）。那张没图就按「没量到」。
    static func sampleModes(
        pages: PartsPages,
        parts: [BeadPart],
        progress: ((Int, Int) -> Void)? = nil
    ) -> [[[Int32]]] {
        var result: [[[Int32]]] = []
        result.reserveCapacity(parts.count)
        for (index, part) in parts.enumerated() {
            // 用户退出这一屏就别再磨了：几十个零件、每个最多 60 万像素，
            // 白算完还要跟下一屏抢 CPU。没量完的按「没量到」补齐，语义上跟图没抠出来是一样的。
            if Task.isCancelled {
                result.append(contentsOf: parts[index...].map { unmeasured(like: $0) })
                break
            }
            let modes = pages.work(for: part).flatMap { sampleModes(work: $0, part: part) }
            result.append(modes ?? unmeasured(like: part))
            progress?(index + 1, parts.count)
        }
        return result
    }

    private static func unmeasured(like part: BeadPart) -> [[Int32]] {
        [[Int32]](repeating: [Int32](repeating: -1, count: max(part.cols, 0)),
                  count: max(part.rows, 0))
    }

    // MARK: - 只重判一块

    /// 只重判一个零件，颜色身份**沿用上一次判色留下的调色板**。
    ///
    /// 用在「用户回『量格子』把某一块的格线重对了一遍」之后：格线一动，那一块原来的
    /// `cells` 就作废了（行列数都可能变），必须清掉。清掉之后如果不补判，用户回到核对页
    /// 看到的就是「原来的没了、新的没出现」—— 那一块从此在所有色号组里一格都不占。
    ///
    /// **不重新聚类。** 单独拿这一块的颜色去认领色号，同一种豆子很可能认领到跟别的零件
    /// 不一样的色号（聚类中心变了、图例匹配的结果也就变了），用户在核对页看到的是一张
    /// 自相矛盾的表：同一个颜色，这块叫 H7，旁边那块叫 H8。沿用整张图纸那份调色板，
    /// 「同一种颜色全图同一个色号」才成立。
    ///
    /// - Returns: `nil` = 没有调色板可沿用，或者这一块的图根本没抠出来。
    ///   两种都得让调用方自己决定怎么跟用户说，不能在这儿默默返回一片空格子 ——
    ///   那跟「这块真的全是背景」在数据上分不开。
    static func reclassify(
        work: PartsWorkImage,
        part: BeadPart,
        palette: [PartsPaletteEntry]
    ) -> BeadPart? {
        let table: [(lab: LabColor, fill: PartCellFill)] = palette.compactMap { entry in
            guard let lab = GridCellSampler.lab(forHex: entry.hex) else { return nil }
            switch entry.role {
            case .code(let code): return (lab, .code(code))
            case .anyColor: return (lab, .anyColor)
            case .empty: return (lab, .empty)
            }
        }
        guard !table.isEmpty, let bitmap = cellBitmap(work: work, part: part),
              let modes = sampleModes(bitmap: bitmap, part: part) else { return nil }

        // 被线围死的浅色格子：跟 `classify` 一样不许判空（见 `PartsCellEnclosure`）。
        // 底色取调色板里「空」那一类的颜色 —— 这块重判沿用的就是整张图纸那次的结论。
        let labs = modes.map { row in row.map { $0 >= 0 ? QuantizedRGB.labTable[Int($0)] : nil } }
        let emptyLab = palette.first { $0.role == .empty }.flatMap { GridCellSampler.lab(forHex: $0.hex) }
        let walled = enclosedLightCells(bitmap: bitmap, part: part, labs: labs, backgroundLab: emptyLab)

        func nearest(_ lab: LabColor, allowEmpty: Bool) -> PartCellFill? {
            var best: PartCellFill?
            var bestDE = Double.infinity
            for entry in table where allowEmpty || entry.fill != .empty {
                let de = GridCellSampler.deltaE(lab, entry.lab)
                if de < bestDE { bestDE = de; best = entry.fill }
            }
            return best
        }

        // 一张图纸的量化色就那么几十上百种（是像素画），同一个量化色的答案必然相同 ——
        // 记一份就不用为每一格都把调色板扫一遍。
        var memo: [Int32: PartCellFill] = [:]
        var updated = part
        updated.cells = modes.indices.map { r in
            modes[r].indices.map { c -> PartCellFill in
                let index = modes[r][c]
                // 没量到的格子当空。这里跟 `classify` 第四趟对齐：它对 `nil` 的那一格
                // 也是直接判空，两边不一致的话，同一张图纸上补判过的那块会长得不一样。
                guard index >= 0 else { return .empty }
                let lab = QuantizedRGB.labTable[Int(index)]
                // 调色板里一条豆子都没有时只能判空，跟原来一样
                if walled[r][c], let bead = nearest(lab, allowEmpty: false) { return bead }
                if let hit = memo[index] { return hit }
                let best = nearest(lab, allowEmpty: true) ?? .empty
                memo[index] = best
                return best
            }
        }
        return updated
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
        legendColors: [BeadColor],
        availableColors: [BeadColor]
    ) -> [Identity] {
        func table(_ colors: [BeadColor]) -> [(code: String, lab: LabColor)] {
            colors.compactMap { color in
                guard color.hasCode(for: colorSystem),
                      let lab = GridCellSampler.lab(forHex: color.colorHex) else { return nil }
                return (color.displayCode(for: colorSystem), lab)
            }
        }
        let legendTable = table(legendColors)
        let fullTable = table(availableColors)

        // **图纸自己写了用色表，就优先在这张表里选。**
        //
        // 走过两个极端：一版是「图例里 ΔE ≤ 25 才用图例，否则去全色库找最近的」，
        // 太松，认出一堆表上压根没有的色号（全色库里相邻色号的色差中位数才 5 点出头，
        // 总有一个「更近」的）；上一版是「只在图例里选」，太死，就是这个 PR 修的那个下场。
        // 现在的 `legendMissDeltaE`(16) 在两者之间。
        //
        // **调这个数之前先看清方向**：调大 = 图例更容易过关 = 更偏向图纸自己写的色号；
        // 调小 = 更多类退回全色库 = 更容易冒出图纸上没有的色号。想减少「表上没有的色号」
        // 要往**大**调，不是往小调。
        //
        // 但**不能只在图例里选**：图例本身可能不全（那条阈值的注释里列了三种情形）。
        // 只在图例里选时，图上其余的颜色会被硬塞进仅剩的那几个色号，
        // 而且几类塞进同一个色号后在核对页合成一组 —— 连「整类改掉」都做不到。
        // 所以图例里最近的那个也差得远时，退回全色库：至少每一类还是各自一组，
        // 色号也真的接近，用户改一下就对了。

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
            let inLegend = nearest(cluster.lab, in: legendTable)
            // 图例里有一个够像的就用它，图纸上写的就是这个字。
            if let inLegend, inLegend.1 <= legendMissDeltaE {
                return Identity(fill: .code(inLegend.0), role: .code(inLegend.0),
                                hex: hex(of: cluster.lab), deltaE: inLegend.1)
            }
            // 图例解释不了这一类（或者压根没有图例），去全色库里找最近的。
            if let wide = nearest(cluster.lab, in: fullTable), wide.1 < (inLegend?.1 ?? .infinity) {
                return Identity(fill: .code(wide.0), role: .code(wide.0),
                                hex: hex(of: cluster.lab), deltaE: wide.1)
            }
            if let inLegend {
                return Identity(fill: .code(inLegend.0), role: .code(inLegend.0),
                                hex: hex(of: cluster.lab), deltaE: inLegend.1)
            }
            return Identity(fill: .empty, role: .empty, hex: hex(of: cluster.lab), deltaE: nil)
        }
    }

    // MARK: - 不同颜色不同组

    /// 两类颜色差超过这个数，就算「图上看得出是两种颜色」。
    ///
    /// 取 6：同一种豆子被 JPEG 抖出来的碎类，中心离主类一般在 6 以内；而实测串组的那几对
    /// （211 和 257、142 和 209）差 6~9。再小就会把同一种颜色拆成好几组。
    private static let distinctDeltaE: Double = 6

    /// 一类至少占所有豆子格的这么多，才值得单独占一个色号。
    /// 太小的碎类（描边蹭色、几颗杂色）跟着最像的色号走就行，拆出去只会多出一堆几颗的小组。
    private static let distinctMinShare: Double = 0.0025

    /// 按颜色认完色号以后，**颜色明显不同的两类不许落在同一个色号上**。
    ///
    /// ## 为什么
    ///
    /// 核对页是按色号分组的。两类认了同一个色号，在核对页就合成一组：一组里一半米色一半淡黄，
    /// 用户「整组改掉」改不了，只能一格一格挑。实测一张图纸上，图例的卡卡色号跟图上印的颜色
    /// 差 8~19，而图上几种浅色互相只差 4~9，按「离哪个色号最近」去认，好几种颜色会挤进同一个色号。
    ///
    /// 色号认对认错，这里不管 —— 颜色太接近的几种，只靠颜色本来就认不准。这里只保证
    /// **认错了也是整组错**：每种看得出的颜色各自一组，用户整组改一下就对了。
    ///
    /// 图上真的分不开的（差不到 6，比如实测 209 和 62 只差 4）照样会合在一起，这个没办法。
    ///
    /// ## 做法
    ///
    /// 大类按格数从多到少排。每一类先看它认的色号有没有被一个「颜色明显不同」的类占了：
    /// 没有就照用；有就往下找离它第二近、第三近……的色号（图例里的优先，跟 `assignIdentities`
    /// 同一套规则），找到一个没被别的颜色占的为止。找不到就保持原样。
    /// 小碎类最后处理，见函数里第二轮的注释。
    private static func separateDistinctClusters(
        identities: inout [Identity],
        clusters: [Cluster],
        colorSystem: ColorSystem,
        legendColors: [BeadColor],
        availableColors: [BeadColor]
    ) {
        func table(_ colors: [BeadColor]) -> [(code: String, lab: LabColor)] {
            colors.compactMap { color in
                guard color.hasCode(for: colorSystem),
                      let lab = GridCellSampler.lab(forHex: color.colorHex) else { return nil }
                return (color.displayCode(for: colorSystem), lab)
            }
        }
        let legendTable = table(legendColors)
        let fullTable = table(availableColors)

        let beads = identities.indices.filter {
            if case .code = identities[$0].role { return true } else { return false }
        }
        let beadCells = beads.reduce(0) { $0 + clusters[$1].count }
        guard beadCells > 0 else { return }
        let minCount = max(1, Int(Double(beadCells) * distinctMinShare))

        // 色号 → 已经占了它的那些类的颜色
        var taken: [String: [LabColor]] = [:]
        func isFree(_ code: String, for lab: LabColor) -> Bool {
            (taken[code] ?? []).allSatisfy { GridCellSampler.deltaE($0, lab) <= distinctDeltaE }
        }

        // 候选色号：图例里够近的（按远近），再全色库（按远近）。跟 assignIdentities 的取舍一致
        func candidates(_ lab: LabColor) -> [(String, Double)] {
            let inLegend = legendTable
                .map { ($0.code, GridCellSampler.deltaE(lab, $0.lab)) }
                .filter { $0.1 <= legendMissDeltaE }
                .sorted { $0.1 < $1.1 }
            let wide = fullTable
                .map { ($0.code, GridCellSampler.deltaE(lab, $0.lab)) }
                .sorted { $0.1 < $1.1 }
            return inLegend + wide
        }
        func set(_ index: Int, _ code: String, _ deltaE: Double?) {
            identities[index] = Identity(fill: .code(code), role: .code(code),
                                         hex: identities[index].hex, deltaE: deltaE)
        }

        // 第一轮：大类按格数从多到少占色号
        let big = beads.filter { clusters[$0].count >= minCount }
            .sorted { clusters[$0].count > clusters[$1].count }
        for index in big {
            guard case .code(let current) = identities[index].role else { continue }
            let lab = clusters[index].lab
            if isFree(current, for: lab) {
                taken[current, default: []].append(lab)
                continue
            }
            if let pick = candidates(lab).first(where: { isFree($0.0, for: lab) }) {
                set(index, pick.0, pick.1)
                taken[pick.0, default: []].append(lab)
            } else {
                taken[current, default: []].append(lab)
            }
        }

        // 第二轮：小碎类。**不能留在原来认的色号上不管**：那个色号可能刚被一个别的颜色的大类
        // 挪过来占了，碎类留在那儿就又成了混色组。图上离它最近的大类够像，就跟那一类同号
        // （它多半就是那种豆子被描边蹭出来的）；不够像，就找一个没被别的颜色占的色号。
        guard !big.isEmpty else { return }
        for index in beads where clusters[index].count < minCount {
            let lab = clusters[index].lab
            let nearest = big.min {
                GridCellSampler.deltaE(lab, clusters[$0].lab) < GridCellSampler.deltaE(lab, clusters[$1].lab)
            }!
            if GridCellSampler.deltaE(lab, clusters[nearest].lab) <= fragmentFollowDeltaE,
               case .code(let code) = identities[nearest].role {
                set(index, code, identities[nearest].deltaE)
                continue
            }
            guard case .code(let current) = identities[index].role else { continue }
            let near = { (code: String) in
                (taken[code] ?? []).allSatisfy { GridCellSampler.deltaE($0, lab) <= fragmentFollowDeltaE }
            }
            if !near(current), let pick = candidates(lab).first(where: { near($0.0) }) {
                set(index, pick.0, pick.1)
            }
        }
    }

    /// 图例兜不住时，判色可以去哪些色号里找。
    ///
    /// 卡卡的色号分 B、P、R 三系。绝大多数卡卡图纸只用 B 系，P、R 是另外单卖的。
    /// 不收窄的话，图例里没有的那几类颜色会被认成「离得最近」的 P 几、R 几，
    /// 用户手里根本没有这些豆子，还得一组一组改回 B。
    ///
    /// 所以卡卡默认只在 B 系里找。图例（上一步读到的色号表）里出现了哪一系，那一系也放开：
    /// 图纸写了 P12，说明这张图真用 P 系，那 P 系的别的色号也可能出现。
    ///
    /// 只拿掉 B/P/R 这三个标准系里没放开的；自定义色号这类不属于任何一系的照旧留着。
    /// 别的体系不收窄。
    static func matchableColors(
        _ availableColors: [BeadColor],
        legendColors: [BeadColor],
        colorSystem: ColorSystem
    ) -> [BeadColor] {
        guard colorSystem == .kaka else { return availableColors }
        func series(_ color: BeadColor) -> String? {
            guard !color.mardCode.hasPrefix("#") else { return nil }
            let code = color.displayCode(for: colorSystem).uppercased()
            return colorSystem.standardPrefixes.first { code.hasPrefix($0) }
        }
        var allowed: Set<String> = [colorSystem.defaultSeries]
        for color in legendColors where color.hasCode(for: colorSystem) {
            if let prefix = series(color) { allowed.insert(prefix) }
        }
        return availableColors.filter { color in
            guard let prefix = series(color) else { return true }
            return allowed.contains(prefix)
        }
    }

    /// 小碎类离图上最近的大类在这个范围内，就当是同一种豆子，跟它同号。
    private static let fragmentFollowDeltaE: Double = 10

    /// 图例里的色号 → 色库里的豆子。**这一道翻译不能省。**
    ///
    /// 图例存的是扫描那步定下的约定（见 `ScanView.recognizeImage`）：匹配上色库的存
    /// **canonical mardCode**，没匹配上的原样存 AI 从图纸上读到的那个串。而判色要比的、
    /// 格子里存的、用户在核对页看到的，是 `displayCode(for: colorSystem)`。
    ///
    /// 两者只有 MARD 项目上恰好相同。早先这里直接拿字符串比 displayCode，于是卡卡 /
    /// COCO / 盼盼图纸上整张图例作废，只剩几个「mardCode 恰好也是一个合法卡卡码」的巧合
    /// （B11、P3 这种，而且认领的还是另一颗豆子）—— 用户看到的就是
    /// 「核对颜色那屏上面只给了 4 个颜色」，图上其余十几种颜色全被塞进了这 4 个里。
    ///
    /// 查的顺序是**先 mardCode、后本体系**，理由见下面那段注释 —— 关键在于图例里存的
    /// 就是 mardCode，跟项目选了哪个体系无关。
    ///
    /// - Returns: `colors` 是认出来的豆子（去重，保持图例顺序，串已 trim + 大写）；
    ///   `unknownCodes` 是**没能翻成豆子**的那些码，两种来源合在一起：
    ///   色库里根本没有这个码（图纸印的是我们没收录的品牌，"HR"、"FG"），
    ///   以及色库里有这颗豆子、但它在当前体系没有色号（`R5` 出现在卡卡图纸上）。
    ///   后者其实有救 —— 用户把项目的色号体系改回去就对上了 —— 但现在两者混在一个数组里，
    ///   调用方分不开，所以只能说同一句话。要给出那条出路得把这里拆成两支。
    ///
    ///   调用方要把它报给用户：图上如果真用到了这些颜色，那些格子写的色号跟图纸上印的
    ///   不是同一个。**注意不是「一定按全色库最接近的判」** —— 已解析出来的图例色里
    ///   只要有一个够近（≤ `legendMissDeltaE`），那一类照样吃图例的色号。
    ///   「任意色」那一行（AI 约定输出 `any`）不是色号，两边都不算。
    static func resolveLegend(
        codes: [String],
        availableColors: [BeadColor],
        colorSystem: ColorSystem
    ) -> (colors: [BeadColor], unknownCodes: [String]) {
        var byMard: [String: BeadColor] = [:]
        var byDisplay: [String: BeadColor] = [:]
        for color in availableColors where color.hasCode(for: colorSystem) {
            // 这个体系里没有码的豆子直接不要：它在这张图纸上根本没法显示，
            // 判成它等于给用户一个他翻不到的色号。
            byMard[color.mardCode.uppercased()] = byMard[color.mardCode.uppercased()] ?? color
            let display = color.displayCode(for: colorSystem).uppercased()
            byDisplay[display] = byDisplay[display] ?? color
        }

        var colors: [BeadColor] = []
        var seen: Set<UUID> = []
        var unknown: [String] = []
        for raw in codes {
            let key = raw.trimmingCharacters(in: .whitespaces).uppercased()
            guard !key.isEmpty, key != "ANY" else { continue }
            // **先按 mardCode 查。** 图例里这串字是扫描那步存下来的 canonical mardCode ——
            // 项目选的是哪个体系都一样（见方法头注释）。所以卡卡项目里拿到的 "B1"
            // 是 MARD 的 B1（亮绿 E6EE31），**不是**卡卡的 B1（白 FDFBFF）。
            //
            // 反过来说，一个串只要在本体系里是合法色号，扫描那步就一定认出来了、
            // 于是被换成 mardCode 存了进去 —— 所以在这儿先按本体系查，查到的必然是
            // 「mardCode 恰好撞上另一颗豆子的本体系码」那种巧合。卡卡上这样的码有 21 个，
            // 全落在 MARD 的绿色系：B1 会认成白、B11 认成黑、B5 认成灰。
            // （这也是为什么两边不能只留一个：真正该改的是「卡卡项目却存 MARD 码」
            //  这件事本身，那要动 BeadUsage 的存储和存量数据，不在这一层解决。）
            //
            // 本体系码只兜**没匹配上**的那一支：AI 从图纸上读到、我们当时没认出来的原始串。
            // 它按 mardCode 当然也查不到，落到这儿再按本体系试一次不亏。
            guard let color = byMard[key] ?? byDisplay[key] else {
                if !unknown.contains(key) { unknown.append(key) }
                continue
            }
            if seen.insert(color.id).inserted { colors.append(color) }
        }
        return (colors, unknown)
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
