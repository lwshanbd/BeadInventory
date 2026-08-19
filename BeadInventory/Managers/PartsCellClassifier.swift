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
    /// 取 8：每格用的是众数色（见 `sampleModes`），本身几乎没有噪声，
    /// 只剩 5 bit 量化那点误差；阈值放宽反而会把相邻色阶串成一类。
    ///
    /// **不是 `private`**：核对页的「排序」也拿它并类（`PartsColorReviewStepView.sorted`）。
    /// 两边各写一个 8 的话，改了这边不会有任何报错，而用户会在核对页看到一种颜色被切成两片。
    static let mergeDeltaE: Double = 8

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
        /// 图例里在色库中查无此码的那些色号（"HR"、"FG" 这种）。
        ///
        /// **必须报给用户**：这些颜色的格子最后按全色库里最接近的色号判，核对页上写的字
        /// 跟图纸色号表上印的不是同一个。不说的话用户只会问「图纸上明明有 HR，
        /// 怎么一个都没有」—— 而他在这一屏找不到任何线索。
        var unknownLegendCodes: [String]

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
        // 底色：用户指认的优先，没指认才自己猜（从整个零件区取 ——
        // 不能从单个零件的框里取，那里面大半是零件自己）。
        let backgroundLab = emptyHex.flatMap { GridCellSampler.lab(forHex: $0) }
            ?? PartsBitmap.make(from: work, roi: roi, maxPixels: 400_000)
                .map { PartsDetector.backgroundLab(of: $0) }
        // 任意色：只有用户指认了才有。它不是色号，猜不出来 —— 图纸上它就是一种普通的
        // 淡色，跟别的豆子长得一样，唯一的区别写在色号表那一行字里。
        let anyColorLab = anyColorHex.flatMap { GridCellSampler.lab(forHex: $0) }
        // 图例的码先翻成色库里的豆子。**不能直接拿这些字符串去比**，理由见 resolveLegend。
        let legend = resolveLegend(codes: legendCodes,
                                   availableColors: availableColors,
                                   colorSystem: colorSystem)

        // 第一趟：把每个零件切格、量出每格的众数色
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
            legendColors: legend.colors,
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
        return Result(parts: fittedParts, palette: palette, unreadableParts: unreadableParts,
                      unknownLegendCodes: legend.unknownCodes)
    }

    // MARK: - 采样

    /// 把 `sampleModes` 量出来的量化色索引换成 Lab。取众数的理由见 `sampleModes`。
    /// - Returns: `nil` = 这个零件的图根本没抠出来（原样透传 `sampleModes`）。
    private static func sampleCells(work: PartsWorkImage, part: BeadPart) -> [[LabColor?]]? {
        guard let modes = sampleModes(work: work, part: part) else { return nil }
        return modes.map { row in
            row.map { $0 >= 0 ? QuantizedRGB.labTable[Int($0)] : nil }
        }
    }

    /// 量出一个零件每一格的颜色，值是 `QuantizedRGB` 索引，**`-1` = 这一格没量到**。
    ///
    /// **取众数，不取平均。** 图纸给每颗豆子都描了一圈深色边，一格才十来个像素，
    /// 边线一平均进去，整格的颜色就被往深处拉；拉的多少又取决于网格差了几分之一格，
    /// 于是同一种豆子的颜色被抹成一条连续的谱，聚类顺着这条谱把淡紫、白、粉全串成一类
    /// —— 实测就是这个下场：一个色号底下混着三四种明显不同的颜色。
    ///
    /// 众数只认「这一格里最多的那个颜色」。描边再深也只占一圈，占不到一半，直接被无视；
    /// 网格差个几分之一格也不影响结论。
    ///
    /// 判色和核对页的「排序」共用这一趟取样。两边必须量出同一个颜色 —— 否则排序会把某一格
    /// 排在「跟这一类很像」的位置上，而它当初正是因为不像才被判错的，用户就永远找不到它。
    ///
    /// - Important: 传进来的 part **必须已经定好格线**（`gridRect` / `rows` / `cols`）。
    ///   这里不做 `classify` 第一趟那种回退标定，没定过的直接返回 nil。
    /// - Returns: `nil` = 这个零件的图**根本没抠出来**（框太小 / 解码失败），一格都没看到。
    ///   早先这里跟「看过了，每格都是背景」一样返回全 nil 的矩阵，两件事在数据上再也分不开。
    static func sampleModes(work: PartsWorkImage, part: BeadPart) -> [[Int32]]? {
        let area = part.gridRect ?? part.bounds
        guard part.rows > 0, part.cols > 0,
              let bitmap = PartsBitmap.make(from: work, roi: area, maxPixels: 600_000) else {
            return nil
        }
        var result = [[Int32]](repeating: [Int32](repeating: -1, count: part.cols), count: part.rows)
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
                    result[r][c] = winner
                }
            }
        }
        return result
    }

    /// 把所有零件每一格的众数色量一遍，给核对页排序用。`[零件][行][列]`，`-1` = 没量到。
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
        var result: [[[Int32]]] = []
        result.reserveCapacity(parts.count)
        for (index, part) in parts.enumerated() {
            // 用户退出这一屏就别再磨了：几十个零件、每个最多 60 万像素，
            // 白算完还要跟下一屏抢 CPU。没量完的按「没量到」补齐，语义上跟图没抠出来是一样的。
            if Task.isCancelled {
                result.append(contentsOf: parts[index...].map { unmeasured(like: $0) })
                break
            }
            result.append(sampleModes(work: work, part: part) ?? unmeasured(like: part))
            progress?(index + 1, parts.count)
        }
        return result
    }

    private static func unmeasured(like part: BeadPart) -> [[Int32]] {
        [[Int32]](repeating: [Int32](repeating: -1, count: max(part.cols, 0)),
                  count: max(part.rows, 0))
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
