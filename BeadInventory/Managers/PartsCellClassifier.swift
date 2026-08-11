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

    struct Result {
        /// 填好 rows / cols / cells / gridRect 的零件
        var parts: [BeadPart]
        /// 这张图纸实际用到的颜色，按格数从多到少
        var palette: [PartsPaletteEntry]
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
        progress: ((Int, Int) -> Void)? = nil
    ) -> Result {
        // 背景色从整个零件区取（不是从单个零件的框里取 —— 那里面大半是零件自己）
        let backgroundLab = PartsBitmap.make(from: work, roi: roi, maxPixels: 400_000)
            .map { PartsDetector.backgroundLab(of: $0) }

        // 第一趟：把每个零件切格、量出每格的平均色
        var fittedParts: [BeadPart] = []
        var cellLabs: [[[LabColor?]]] = []      // [part][row][col]
        for (index, part) in parts.enumerated() {
            var updated = part
            // 用户在「量格子」那屏手动调过的零件已经带着 gridRect 和行列数，
            // 直接用他的结论 —— 自动重贴会把手动修正覆盖掉。
            let rows: Int, cols: Int
            if part.gridRect != nil, part.rows > 0, part.cols > 0 {
                rows = part.rows
                cols = part.cols
            } else {
                let fitted = PartsPitchEstimator.fitGrid(work: work, part: part, calibration: calibration)
                rows = fitted?.rows ?? part.gridSize(for: calibration).rows
                cols = fitted?.cols ?? part.gridSize(for: calibration).cols
                updated.gridRect = fitted?.rect
            }
            updated.rows = rows
            updated.cols = cols

            let labs = sampleCells(work: work, part: updated)
            cellLabs.append(labs)
            updated.cells = Array(repeating: Array(repeating: .empty, count: cols), count: rows)
            fittedParts.append(updated)
            progress?(index + 1, parts.count)
        }

        // 第二趟：把所有格子的颜色聚成十几类
        let clusters = cluster(cellLabs: cellLabs)

        // 第三趟：每一类认领一个身份（空 / 某个色号）
        let assignments = assignIdentities(
            clusters: clusters,
            backgroundLab: backgroundLab,
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
        return Result(parts: fittedParts, palette: palette)
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
    private static func sampleCells(work: PartsWorkImage, part: BeadPart) -> [[LabColor?]] {
        let area = part.gridRect ?? part.bounds
        guard part.rows > 0, part.cols > 0,
              let bitmap = PartsBitmap.make(from: work, roi: area, maxPixels: 600_000) else {
            return Array(repeating: Array(repeating: nil, count: max(part.cols, 0)), count: max(part.rows, 0))
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

        return clusters.map { cluster in
            if let backgroundLab, GridCellSampler.deltaE(cluster.lab, backgroundLab) <= emptyDeltaE {
                return Identity(fill: .empty, role: .empty, hex: hex(of: cluster.lab), deltaE: nil)
            }
            // 图例里够近就用图例的：图例是这张图纸自己声明的用色表
            if let hit = nearest(cluster.lab, in: legendTable), hit.1 <= 25 {
                return Identity(fill: .code(hit.0), role: .code(hit.0), hex: hex(of: cluster.lab), deltaE: hit.1)
            }
            if let hit = nearest(cluster.lab, in: fullTable) {
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
