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
//  ## 做法：颜色突变曲线 → 自相关出候选 → 梳齿定格距和相位
//
//  图纸本身画了格线，所以「每列跟前一列的差异」这条曲线是周期性的，周期就是格距。
//
//  **自相关要取「第一个够强的峰」而不是「最高的峰」**：周期的 2 倍、3 倍处同样会出峰，
//  而且往往更高，直接取最大值会把两格认成一格。
//
//  自相关给两个种子（横竖各一个），每个种子再展开成它的 1/2 ~ 1/8 一起当候选。
//  最终的格距是拿一把「梳子」（等距的一排线）在曲线上滑出来的：每个候选在 ±3% 范围内
//  按几个千分点的步长微调，取让齿都压在突变处的那个 —— 一张图上上百格累积下来，
//  0.5% 的周期误差就是半格。
//
//  **候选之间不是比总分，是在「每条齿都压中」的那些里取最细的**（见 `sharedLattice`）：
//  平面图纸每 5 格一条粗黑线，比总分的话永远是「5 格」那把梳子赢。
//
//  **格距横竖只有一个数。** 豆子是方的，横 12.3 竖 12.9 这种结果没有任何意义，而且用户在
//  界面上救不回来（把手只能等比缩放）。所以同一个候选的评分是两个方向的和，一个格距一起定。
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
        // 横竖各量各的会量出 12.3 和 12.9 —— 一个长方形的「格子」。豆子是方的，
        // 这种结果没有任何意义，而且用户在界面上救不回来（把手只能等比缩放，
        // 长方形缩放还是长方形）。所以格距**一个数**，两个方向一起定。
        guard let lattice = sharedLattice(columns: profiles.columns, rows: profiles.rows) else { return nil }

        let roi = bitmap.roi
        return PartsGridCalibration(
            cellWidth: lattice.pitch / Double(bitmap.width) * Double(roi.width),
            cellHeight: lattice.pitch / Double(bitmap.height) * Double(roi.height),
            originX: Double(roi.minX) + lattice.phaseX / Double(bitmap.width) * Double(roi.width),
            originY: Double(roi.minY) + lattice.phaseY / Double(bitmap.height) * Double(roi.height)
        )
    }

    /// 单个零件分析用的工作分辨率。一个零件比整片零件区小得多，给这么多就够梳齿用了；
    /// 五十几个零件要挨个跑，再高就等得住人了。
    private static let partAnalysisPixels = 200_000

    /// 用给定的格距，**单独**给一个零件找它自己的格线位置。
    ///
    /// 图纸上的零件是各画各的：零件 A 的格线和零件 B 的格线压根不属于同一批
    /// （用户拿真实图纸确认过）。格距是共用的 —— 同一张纸上豆子一样大；相位不是。
    /// 所以整张图一个相位这件事从一开始就不成立，只能一个零件一个零件地定。
    ///
    /// - Returns: 这个零件太小（装不下四格）或者图上没有周期信号时返回 nil，
    ///   调用方保持它现在的格线不动。
    static func fitOrigin(
        work: PartsWorkImage, bounds: CGRect, calibration: PartsGridCalibration
    ) -> CGPoint? {
        guard calibration.isUsable else { return nil }
        let region = bounds.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard region.width > 0, region.height > 0,
              let bitmap = PartsBitmap.make(from: work, roi: region, maxPixels: partAnalysisPixels),
              bitmap.width >= 16, bitmap.height >= 16 else { return nil }
        return fitPhase(in: bitmap, calibration: calibration)
    }

    /// 格距不动，只重新找格线的位置（整片零件区一起看）。
    static func fitOrigin(
        work: PartsWorkImage, parts: [BeadPart], calibration: PartsGridCalibration
    ) -> CGPoint? {
        guard calibration.isUsable, let bitmap = analysisBitmap(work: work, parts: parts) else { return nil }
        return fitPhase(in: bitmap, calibration: calibration)
    }

    private static func fitPhase(
        in bitmap: PartsBitmap, calibration: PartsGridCalibration
    ) -> CGPoint? {
        let roi = bitmap.roi
        let pitchX = calibration.cellWidth / Double(roi.width) * Double(bitmap.width)
        let pitchY = calibration.cellHeight / Double(roi.height) * Double(bitmap.height)
        let profiles = gradientProfiles(of: bitmap)
        guard let x = refineLattice(profile: profiles.columns, pitch: pitchX),
              let y = refineLattice(profile: profiles.rows, pitch: pitchY)
        else { return nil }
        return CGPoint(
            x: Double(roi.minX) + x / Double(bitmap.width) * Double(roi.width),
            y: Double(roi.minY) + y / Double(bitmap.height) * Double(roi.height)
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

    /// 横竖共用一个格距，各自有各自的相位。
    ///
    /// 候选格距取自两条曲线各自的基本周期（哪条更干净事先不知道，两个都试），
    /// 每个候选上下微调几个千分点 —— 自相关只能到零点几像素的精度，而整张图上百格累积
    /// 下来千分之五的误差就是半格。
    ///
    /// ## 还要试候选的整数分之一，并且**优先取最细的那个**
    ///
    /// 很多平面图纸每 5 格画一条粗黑线。那条线又粗又黑，自相关的最强峰因此落在
    /// 「5 格」上 —— 实测一张 30×30 的图纸被判成 5×5 格、一格 150 像素。
    /// 用户拿加减号（一次 0.1 像素）是修不回来的。
    ///
    /// 分不出来的原因是**平均分选不出基频**：5 格那把梳子的齿全压在粗线上，分很高；
    /// 1 格那把梳子六分之一的齿在粗线上、其余在细线上，平均反而更低。两把梳子都「对」，
    /// 只是一把是另一把的子集。
    ///
    /// 所以判据换成「**每一条齿都压在突变处**」（看最弱的那几条齿，见 `bestPhase` 的
    /// `weakest`）：格距减半的话，一半的齿会落在格子中间拿负分，直接出局；
    /// 而 5 格那把和 1 格那把都全中，这时取**最小**的那个 —— 它才是基频。
    /// 图纸没画粗线时，分之一的候选全都过不了这一关，行为跟以前一模一样。
    private static func sharedLattice(
        columns: [Double], rows: [Double]
    ) -> (pitch: Double, phaseX: Double, phaseY: Double)? {
        var seeds: [Double] = []
        for seed in [fundamentalPeriod(profile: columns), fundamentalPeriod(profile: rows)].compactMap({ $0 }) {
            // 两条曲线量出来差不多时只留一个：搜索范围本来就覆盖 ±3%
            guard !seeds.contains(where: { abs($0 - seed) < $0 * 0.01 }) else { continue }
            seeds.append(seed)
        }
        guard !seeds.isEmpty else { return nil }

        // 候选 = 每个基本周期本身 + 它的 1/2 ~ 1/8。
        // 一格小于 4 像素就不试了：那个分辨率下「格线」和「格子中间」本来就分不开。
        var candidates: [Double] = []
        for seed in seeds {
            for divisor in 1...8 {
                let pitch = seed / Double(divisor)
                guard pitch >= 4 else { break }
                guard !candidates.contains(where: { abs($0 - pitch) < $0 * 0.01 }) else { continue }
                candidates.append(pitch)
            }
        }

        var scored: [(pitch: Double, phaseX: Double, phaseY: Double, score: Double, weakest: Double)] = []
        for seed in candidates {
            let step = max(0.02, seed * 0.002)
            var best: (pitch: Double, phaseX: Double, phaseY: Double, score: Double, weakest: Double)?
            var pitch = seed * 0.97
            while pitch <= seed * 1.03 + 1e-9 {
                defer { pitch += step }
                guard let x = bestPhase(profile: columns, pitch: pitch),
                      let y = bestPhase(profile: rows, pitch: pitch) else { continue }
                let score = x.score + y.score
                if best == nil || score > best!.score {
                    best = (pitch, x.phase, y.phase, score, min(x.weakest, y.weakest))
                }
            }
            if let best { scored.append(best) }
        }
        guard !scored.isEmpty else { return nil }

        // 每条齿都压在突变处的那些里，取最细的 —— 它是基频，粗的那些是它的整数倍。
        // 门槛给 0.1 个标准差：曲线已经标准化过（0 是平均水平），压在真格线上的
        // 至少也得比平均高一点点。
        if let finest = scored.filter({ $0.weakest > 0.1 }).min(by: { $0.pitch < $1.pitch }) {
            return (finest.pitch, finest.phaseX, finest.phaseY)
        }
        guard let best = scored.max(by: { $0.score < $1.score }) else { return nil }
        return (best.pitch, best.phaseX, best.phaseY)
    }

    /// 格距不动，只找相位。用户手拉过大小之后按「自动对齐」走这条 —— 他量的多大就是多大。
    private static func refineLattice(profile: [Double], pitch: Double) -> Double? {
        bestPhase(profile: profile, pitch: pitch)?.phase
    }

    /// 拿一把齿距为 `pitch` 的梳子在曲线上滑，找齿全部压在突变处的那个位置。
    /// - Returns: 相位（第一条线的位置，像素）、平均分，以及**最弱的那几条齿**有多弱
    ///   （十分位数）。后者用来判断「是不是每一条齿都压在了突变处」——
    ///   平均分高只说明多数齿压对了，而格距取成两倍时正好有一半的齿落在格子中间
    ///   （见 `sharedLattice`）。曲线装不下四格时返回 nil。
    private static func bestPhase(
        profile: [Double], pitch: Double
    ) -> (phase: Double, score: Double, weakest: Double)? {
        let n = profile.count
        guard pitch >= 3, Double(n) >= pitch * 4 else { return nil }
        let lines = Int(Double(n - 1) / pitch)
        guard lines >= 3 else { return nil }

        var best: (phase: Double, score: Double, weakest: Double)?
        var phase = 0.0
        let phaseStep = max(0.1, pitch / 60)
        var teeth: [Double] = []
        teeth.reserveCapacity(lines + 1)
        while phase < pitch {
            defer { phase += phaseStep }
            teeth.removeAll(keepingCapacity: true)
            for k in 0...lines {
                let x = Int((phase + Double(k) * pitch).rounded())
                guard x >= 0, x <= n - 1 else { continue }
                let lo = max(0, x - 1), hi = min(n - 1, x + 1)
                teeth.append((lo...hi).map { profile[$0] }.max() ?? 0)
            }
            guard !teeth.isEmpty else { continue }
            // 分母固定用 `lines + 1`（原来就是这样）。改成 `teeth.count` 的话，
            // 末齿越界被丢掉的那些相位会凭空得分更高 —— 那会改掉**已经上线**的
            // `refineLattice` / `fitOrigin` 选出来的相位，而这次改动本来不该碰它们。
            let score = teeth.reduce(0, +) / Double(lines + 1)
            guard best == nil || score > best!.score else { continue }
            // 十分位数而不是最小值：图纸边上那一条格线常常被裁掉一半，
            // 拿最小值当判据的话，一条弱齿就能把一个完全正确的格距否掉。
            //
            // 索引不能写成 `Int(count * 0.1) - 1` —— 那个式子在 count < 20 时恒为 0，
            // 也就是**恰好退回最小值**，而多零件模式的每个零件都在这个区间里，
            // 于是这条判据在那边从来没按设计工作过。
            let sorted = teeth.sorted()
            let weakest = sorted[Int(Double(sorted.count - 1) * 0.1)]
            best = (phase, score, weakest)
        }
        return best
    }
}
