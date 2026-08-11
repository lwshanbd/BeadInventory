//
//  PartsPaletteExtractor.swift
//  BeadInventory
//
//  多零件模式 - 从零件区里聚出「这张图纸到底用了哪几种颜色」
//
//  为什么要单独有这一步：图纸上的颜色是有限的十几种（右上角那张色号表就是它的图例），
//  但色库里有几百个色号。如果每个格子都直接去几百色里找最近的，一旦某两个色号在
//  Lab 里挨得很近，同一片色块会被判成两三种色号，用户得一格一格改。
//
//  先把「图纸用了哪十几种颜色」聚出来、让用户一次性认领色号，之后几万个格子就只在
//  这十几个已确认的颜色里取最近的 —— 同一片色块必然判成同一个结果，改一条就是改一片。
//

import UIKit

enum PartsPaletteExtractor {

    /// 聚类结果里的一种颜色
    struct Cluster: Equatable {
        var hex: String
        var lab: LabColor
        /// 占零件像素的比例
        var share: Double
    }

    /// 两个聚类中心的最小 Lab 距离。小于这个就并成一类。
    /// 12 是经验值：拼豆图纸上相邻色阶（比如浅粉/更浅的粉）大约差 15~25，
    /// 而同一色块因 JPEG 压缩产生的抖动一般在 6 以内。
    private static let mergeDeltaE: Double = 12

    /// 从位图里聚颜色。只统计落在零件 bbox 里的像素 —— 零件之间的背景不参与，
    /// 否则背景色会以压倒性比例排在第一，把真正的主色挤下去。
    ///
    /// - Parameter maxColors: 最多返回几种。图纸图例通常 8~14 种，留点余量。
    static func extract(
        from bitmap: PartsBitmap,
        partBounds: [CGRect],
        maxColors: Int = 16
    ) -> [Cluster] {
        var counts = [Int: Int]()
        counts.reserveCapacity(2048)
        var total = 0

        let regions: [(x: Int, y: Int, w: Int, h: Int)] = partBounds.isEmpty
            ? [(0, 0, bitmap.width, bitmap.height)]
            : partBounds.map { bitmap.pixelRect(forNormalized: $0) }

        // bbox 会互相重叠（一个零件的框可能罩住邻居的一角），用 visited 去重，
        // 免得重叠区域的颜色被重复计数、占比失真。
        var visited = [Bool](repeating: false, count: bitmap.pixelCount)
        for region in regions {
            guard region.w > 0, region.h > 0 else { continue }
            for y in region.y..<(region.y + region.h) {
                let row = y * bitmap.width
                for x in region.x..<(region.x + region.w) {
                    let i = row + x
                    if visited[i] { continue }
                    visited[i] = true
                    counts[Int(bitmap.quantized[i]), default: 0] += 1
                    total += 1
                }
            }
        }
        guard total > 0 else { return [] }

        // 按桶大小从大到小贪心选中心：跟已选中心距离够远的自立门户，
        // 否则把票投给最近的那个中心。
        let ordered = counts.sorted { $0.value > $1.value }
        var centers: [(lab: LabColor, index: Int, count: Int)] = []
        for (bucket, count) in ordered {
            let lab = QuantizedRGB.labTable[bucket]
            var nearest = -1
            var nearestDE = Double.infinity
            for (i, c) in centers.enumerated() {
                let de = GridCellSampler.deltaE(lab, c.lab)
                if de < nearestDE { nearestDE = de; nearest = i }
            }
            if nearestDE <= mergeDeltaE, nearest >= 0 {
                centers[nearest].count += count
            } else if centers.count < maxColors {
                centers.append((lab: lab, index: bucket, count: count))
            } else if nearest >= 0 {
                // 已经满了：并进最近的一类，不再新开
                centers[nearest].count += count
            }
        }

        return centers
            .sorted { $0.count > $1.count }
            .map { Cluster(hex: QuantizedRGB.hex(of: $0.index),
                           lab: $0.lab,
                           share: Double($0.count) / Double(total)) }
    }

    // MARK: - 自动匹色号

    /// 给每个聚类猜一个色号。
    ///
    /// 候选池分两层：**先在项目图例（beadUsage）里找**，找不到够近的再放开到整个色库。
    /// 图例就是这张图纸自己声明的用色表，优先它能避免「明明图例里写着 E12，
    /// 却因为色库里有个更接近的冷门色号而匹到别的去」。
    ///
    /// - Returns: 与 `clusters` 等长；每项是 (色号, ΔE)，实在匹不上时为 nil。
    static func autoMatch(
        clusters: [Cluster],
        colorSystem: ColorSystem,
        legendCodes: [String],
        availableColors: [BeadColor]
    ) -> [(code: String, deltaE: Double)?] {
        func labTable(for colors: [BeadColor]) -> [(code: String, lab: LabColor)] {
            colors.compactMap { color in
                guard color.hasCode(for: colorSystem),
                      let lab = GridCellSampler.lab(forHex: color.colorHex) else { return nil }
                return (color.displayCode(for: colorSystem), lab)
            }
        }
        let legendSet = Set(legendCodes)
        let legendTable = labTable(for: availableColors.filter {
            legendSet.contains($0.displayCode(for: colorSystem))
        })
        let fullTable = labTable(for: availableColors)

        /// 图例里够近就用图例的。25 是「同色族深浅变化」的量级，
        /// 超过它说明图例里根本没有这个颜色，该放开找了。
        let legendAcceptDeltaE: Double = 25

        func nearest(_ lab: LabColor, in table: [(code: String, lab: LabColor)]) -> (String, Double)? {
            var best: (String, Double)?
            for (code, ref) in table {
                let de = GridCellSampler.deltaE(lab, ref)
                if best == nil || de < best!.1 { best = (code, de) }
            }
            return best
        }

        return clusters.map { cluster in
            if let hit = nearest(cluster.lab, in: legendTable), hit.1 <= legendAcceptDeltaE {
                return (code: hit.0, deltaE: hit.1)
            }
            if let hit = nearest(cluster.lab, in: fullTable) {
                return (code: hit.0, deltaE: hit.1)
            }
            return nil
        }
    }

    /// 聚类 + 自动匹色号 + 猜「哪一条是背景（空）」，一次性产出调色板初值。
    ///
    /// 只自动认「空」一条：背景色是可以算出来的（零件区四周的众数），
    /// 而「任意色」在像素上跟普通颜色毫无区别，猜了也是瞎猜 —— 留给用户点。
    static func buildInitialPalette(
        bitmap: PartsBitmap,
        partBounds: [CGRect],
        colorSystem: ColorSystem,
        legendCodes: [String],
        availableColors: [BeadColor]
    ) -> [PartsPaletteEntry] {
        let clusters = extract(from: bitmap, partBounds: partBounds)
        guard !clusters.isEmpty else { return [] }
        let matches = autoMatch(
            clusters: clusters,
            colorSystem: colorSystem,
            legendCodes: legendCodes,
            availableColors: availableColors
        )
        let bg = PartsDetector.backgroundLab(of: bitmap)

        return clusters.enumerated().map { index, cluster in
            let isBackground = GridCellSampler.deltaE(cluster.lab, bg) <= mergeDeltaE
            if isBackground {
                return PartsPaletteEntry(hex: cluster.hex, pixelShare: cluster.share, role: .empty)
            }
            if let match = matches[index] {
                return PartsPaletteEntry(
                    hex: cluster.hex,
                    pixelShare: cluster.share,
                    role: .code(match.code),
                    matchDeltaE: match.deltaE
                )
            }
            return PartsPaletteEntry(hex: cluster.hex, pixelShare: cluster.share, role: .empty)
        }
    }
}
