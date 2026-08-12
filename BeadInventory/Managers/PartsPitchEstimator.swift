//
//  PartsPitchEstimator.swift
//  BeadInventory
//
//  多零件模式 - 量出整张图纸的那张网格
//
//  用户最终要自己确认（他一眼就能看出网格线有没有落在豆子边界上），
//  但不该让他从零开始量。这里先量一个八九不离十的，用户多数情况下只是点个头。
//
//  ## 一张图纸只有一张网格
//
//  图纸上几十个零件是从同一张像素画上切下来的，格子多大、格线在哪，全图是同一个答案。
//  所以这里不按零件一个个量，而是**把所有零件圈在一起当成一张图量一次**：
//  竖格线在每个零件里都出现在同样的相位上，叠在一起信号只会更强；零件之间的空白
//  没有周期性，贡献接近零。量出来的结论 (`PartsGridCalibration`) 直接铺满整张图纸。
//
//  早先是每个零件各量各的相位，于是「这个零件对齐了，换一个又对不上」——
//  因为零件的 bbox 带一圈抗锯齿毛边，每个零件毛边多少不一样。用户得一个一个重对，
//  而这些零件本来就共用同一批格线。
//
//  ## 做法：颜色突变曲线 → 自相关定周期 → 梳齿定相位
//
//  图纸本身画了格线，所以「每列跟前一列的差异」这条曲线是周期性的，周期就是格距。
//
//  **自相关要取「第一个够强的峰」而不是「最高的峰」**：周期的 2 倍、3 倍处同样会出峰，
//  而且往往更高，直接取最大值会把两格认成一格。
//
//  周期定下来之后，再拿一把「梳子」（等距的一排线）在曲线上滑，找让所有齿都压在
//  突变处的那个位置 —— 同时容许周期本身微调几个千分点，因为一张图上上百格累积下来，
//  0.5% 的周期误差就是半格。
//
//  一开始试过另一条路 —— 穷举「这个零件横着是几格」，看那些分界线是不是都落在
//  突变处，取平均分最高的。实测直接翻车：把一个四十几列的零件判成 3 列。
//  原因是平均分可以靠「少画几条线、每条都挑最陡的地方」刷高，格数越少越容易得逞。
//

import UIKit

enum PartsPitchEstimator {

    /// 分析用的工作分辨率。整个零件区一起看，所以比单个零件那会儿给得多。
    private static let analysisPixels = 1_500_000

    /// 量出整张图纸的网格：一格多大 + 格线在哪。
    /// - Returns: 图上找不出规则格线时返回 nil，由调用方给用户一个手动量的初值。
    static func estimateLattice(work: PartsWorkImage, parts: [BeadPart]) -> PartsGridCalibration? {
        guard let bitmap = analysisBitmap(work: work, parts: parts) else { return nil }
        let profiles = gradientProfiles(of: bitmap)
        guard let px = fundamentalPeriod(profile: profiles.columns),
              let py = fundamentalPeriod(profile: profiles.rows),
              let x = refineLattice(profile: profiles.columns, pitch: px, allowPitchDrift: true),
              let y = refineLattice(profile: profiles.rows, pitch: py, allowPitchDrift: true)
        else { return nil }

        let roi = bitmap.roi
        return PartsGridCalibration(
            cellWidth: x.pitch / Double(bitmap.width) * Double(roi.width),
            cellHeight: y.pitch / Double(bitmap.height) * Double(roi.height),
            originX: Double(roi.minX) + x.phase / Double(bitmap.width) * Double(roi.width),
            originY: Double(roi.minY) + y.phase / Double(bitmap.height) * Double(roi.height)
        )
    }

    /// 格距不动，只重新找格线的位置。
    /// 用户手拉过格子大小之后按「自动对齐」走这条 —— 他量的大小不许被改掉。
    static func fitOrigin(
        work: PartsWorkImage, parts: [BeadPart], calibration: PartsGridCalibration
    ) -> CGPoint? {
        guard calibration.isUsable, let bitmap = analysisBitmap(work: work, parts: parts) else { return nil }
        let roi = bitmap.roi
        let pitchX = calibration.cellWidth / Double(roi.width) * Double(bitmap.width)
        let pitchY = calibration.cellHeight / Double(roi.height) * Double(bitmap.height)
        let profiles = gradientProfiles(of: bitmap)
        guard let x = refineLattice(profile: profiles.columns, pitch: pitchX, allowPitchDrift: false),
              let y = refineLattice(profile: profiles.rows, pitch: pitchY, allowPitchDrift: false)
        else { return nil }
        return CGPoint(
            x: Double(roi.minX) + x.phase / Double(bitmap.width) * Double(roi.width),
            y: Double(roi.minY) + y.phase / Double(bitmap.height) * Double(roi.height)
        )
    }

    // MARK: - 内部

    /// 把所有零件圈在一起裁一张图来量。零件之间的空白也在里面，但它不周期，不影响结论。
    private static func analysisBitmap(work: PartsWorkImage, parts: [BeadPart]) -> PartsBitmap? {
        guard var union = parts.first?.bounds else { return nil }
        for part in parts.dropFirst() { union = union.union(part.bounds) }
        let region = union.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard region.width > 0, region.height > 0 else { return nil }
        guard let bitmap = PartsBitmap.make(from: work, roi: region, maxPixels: analysisPixels),
              bitmap.width >= 32, bitmap.height >= 32 else { return nil }
        return bitmap
    }

    /// 横向 / 纵向的「颜色突变强度」曲线。
    /// `columns[x]` = 第 x 列跟第 x-1 列的整体差异；格线所在的列会明显更高。
    private static func gradientProfiles(of bitmap: PartsBitmap) -> (columns: [Double], rows: [Double]) {
        let w = bitmap.width, h = bitmap.height
        var columns = [Double](repeating: 0, count: w)
        var rows = [Double](repeating: 0, count: h)

        // 只用亮度：格线通常是深色细线，亮度差已经足够，比算三通道快得多
        var luminance = [Double](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            luminance[i] = bitmap.lab(at: i).l
        }
        for y in 0..<h {
            let row = y * w
            for x in 1..<w {
                columns[x] += abs(luminance[row + x] - luminance[row + x - 1])
            }
        }
        for y in 1..<h {
            let row = y * w, prev = (y - 1) * w
            for x in 0..<w {
                rows[y] += abs(luminance[row + x] - luminance[prev + x])
            }
        }
        return (normalize(columns), normalize(rows))
    }

    /// 减去均值再除以标准差。这样「落在格线上」得正分、「落在格子中间」得负分，
    /// 于是把格数猜成 2 倍时（一半的线落在格子中间）平均分会掉下来，不会被误选。
    private static func normalize(_ values: [Double]) -> [Double] {
        guard values.count > 1 else { return values }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        let sd = variance.squareRoot()
        guard sd > 0.0001 else { return values.map { _ in 0 } }
        return values.map { ($0 - mean) / sd }
    }

    /// 曲线的基本周期（像素，可以是小数）。找不到规则周期时返回 nil。
    private static func fundamentalPeriod(profile: [Double]) -> Double? {
        let n = profile.count
        guard n >= 24 else { return nil }
        let maxLag = n / 3
        guard maxLag >= 4 else { return nil }

        var correlation = [Double](repeating: 0, count: maxLag + 1)
        for lag in 0...maxLag {
            var sum = 0.0
            for x in 0..<(n - lag) { sum += profile[x] * profile[x + lag] }
            correlation[lag] = sum / Double(n - lag)
        }
        guard correlation[0] > 0 else { return nil }
        let normalized = correlation.map { $0 / correlation[0] }

        // 一格至少 3 个像素，否则「格线」和「格子中间」在这个分辨率下本来就分不开
        var peaks: [(lag: Int, value: Double)] = []
        for lag in 3..<maxLag where normalized[lag] > normalized[lag - 1] && normalized[lag] >= normalized[lag + 1] {
            peaks.append((lag, normalized[lag]))
        }
        guard let strongest = peaks.max(by: { $0.value < $1.value }), strongest.value > 0.12 else { return nil }

        // 取第一个达到最强峰 60% 的峰。整数倍处的峰往往更高，直接取最大值
        // 会把「两格」当成「一格」。
        guard let fundamental = peaks.first(where: { $0.value >= strongest.value * 0.6 }) else { return nil }

        // 抛物线插值：峰只落在整数 lag 上，插一下才能把 10.9 这种周期还原出来
        let lag = fundamental.lag
        let (a, b, c) = (normalized[lag - 1], normalized[lag], normalized[lag + 1])
        let denominator = a - 2 * b + c
        let offset = denominator == 0 ? 0 : 0.5 * (a - c) / denominator
        return Double(lag) + max(-0.5, min(0.5, offset))
    }

    /// 拿一把等距的梳子在曲线上滑，找齿全部压在突变处的那个位置。
    ///
    /// - Parameter allowPitchDrift: 是否容许齿距在给定值上下微调。
    ///   自动量的时候要（自相关只能到零点几像素的精度，而整张图上百格累积下来
    ///   千分之五的误差就是半格）；用户手拉过大小之后不要 —— 他量的多大就是多大。
    /// - Returns: 齿距（像素）和相位（第一条线的位置，像素）。
    private static func refineLattice(
        profile: [Double], pitch: Double, allowPitchDrift: Bool
    ) -> (pitch: Double, phase: Double)? {
        let n = profile.count
        guard pitch >= 3, Double(n) >= pitch * 4 else { return nil }

        var pitches: [Double] = [pitch]
        if allowPitchDrift {
            let step = max(0.02, pitch * 0.002)
            var p = pitch * 0.97
            pitches = []
            while p <= pitch * 1.03 + 1e-9 {
                pitches.append(p)
                p += step
            }
        }

        var best: (pitch: Double, phase: Double, score: Double)?
        for candidate in pitches {
            let lines = Int(Double(n - 1) / candidate)
            guard lines >= 3 else { continue }
            var phase = 0.0
            let phaseStep = max(0.1, candidate / 60)
            while phase < candidate {
                var total = 0.0
                for k in 0...lines {
                    let x = Int((phase + Double(k) * candidate).rounded())
                    guard x >= 0, x <= n - 1 else { continue }
                    let lo = max(0, x - 1), hi = min(n - 1, x + 1)
                    total += (lo...hi).map { profile[$0] }.max() ?? 0
                }
                let score = total / Double(lines + 1)
                if best == nil || score > best!.score { best = (candidate, phase, score) }
                phase += phaseStep
            }
        }
        guard let best else { return nil }
        return (best.pitch, best.phase)
    }
}
