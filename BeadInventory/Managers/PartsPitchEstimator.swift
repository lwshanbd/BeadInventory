//
//  PartsPitchEstimator.swift
//  BeadInventory
//
//  多零件模式 - 猜一格有多大
//
//  用户最终要自己确认格子大小（他一眼就能看出网格线有没有落在豆子边界上），
//  但不该让他从零开始量。这里先猜一个八九不离十的值，用户多数情况下只是点个头。
//
//  ## 做法：颜色突变曲线 → 自相关 → 取第一个够强的峰
//
//  图纸本身画了格线，所以「每列跟前一列的差异」这条曲线是周期性的，
//  周期就是格距。自相关能把这个周期挑出来。
//
//  **关键是取「第一个够强的峰」而不是「最高的峰」**：自相关在周期的 2 倍、3 倍处
//  同样会出峰，而且往往更高，直接取最大值会把格子认成两格并一格。
//
//  一开始试过另一条路 —— 穷举「这个零件横着是几格」，看那些分界线是不是都落在
//  突变处，取平均分最高的。实测直接翻车：把一个四十几列的零件判成 3 列。
//  原因是平均分可以靠「少画几条线、每条都挑最陡的地方」刷高，格数越少越容易得逞。
//

import UIKit

enum PartsPitchEstimator {

    /// 从若干个零件猜整张图纸的格距（归一化，占图宽 / 图高的比例）。
    ///
    /// - Parameter samples: 拿来量的零件。挑大的几个 —— 零件越大，格线越多，
    ///   得分曲线的峰越尖锐。
    /// - Returns: 一个零件都量不出来时返回 nil，由调用方给用户一个手动量的初值。
    static func estimate(work: PartsWorkImage, parts: [BeadPart], sampleCount: Int = 5) -> PartsGridCalibration? {
        let samples = parts
            .sorted { $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height }
            .prefix(sampleCount)
        guard !samples.isEmpty else { return nil }

        var widths: [Double] = []
        var heights: [Double] = []
        for part in samples {
            guard let bitmap = PartsBitmap.make(from: work, roi: part.bounds, maxPixels: 400_000),
                  bitmap.width >= 8, bitmap.height >= 8 else { continue }
            let profiles = gradientProfiles(of: bitmap)
            // 周期是像素数；bbox 精确等于 cols 格，所以四舍五入回整数格再反算格距，
            // 这样每个零件给出的估计天然是自洽的。
            if let period = fundamentalPeriod(profile: profiles.columns) {
                let cols = max(1, Int((Double(bitmap.width) / period).rounded()))
                widths.append(Double(part.bounds.width) / Double(cols))
            }
            if let period = fundamentalPeriod(profile: profiles.rows) {
                let rows = max(1, Int((Double(bitmap.height) / period).rounded()))
                heights.append(Double(part.bounds.height) / Double(rows))
            }
        }
        guard let w = median(widths), let h = median(heights) else { return nil }
        return PartsGridCalibration(cellWidth: w, cellHeight: h)
    }

    // MARK: - 内部

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

    // MARK: - 把网格贴到零件上

    /// 一个零件最终的网格：覆盖范围（归一化）+ 行列数。
    struct FittedGrid: Equatable, Sendable {
        var rect: CGRect
        var rows: Int
        var cols: Int
    }

    /// 给定格距，把网格**对齐到这个零件的图像内容上**。
    ///
    /// 为什么不能直接拿零件的 bbox 均分：bbox 是连通域的外沿，
    /// 而前景掩膜会把描边周围抗锯齿出来的那一两个像素也算进去。工作分辨率下一格才五六个
    /// 像素，这一圈毛边就是三分之一格 —— 均分出来的线整排压在豆子中间，而且越往右
    /// 偏得越多。实测就是这个现象。
    ///
    /// 所以这里在 bbox 附近搜一遍「起点 + 格距」，让所有格线尽量落在颜色突变的地方。
    /// 格距允许在用户给的值上下浮动 6%：用户是用手指量的，本来就不可能精确。
    /// - Parameters:
    ///   - forcedCols/forcedRows: 用户在界面上手点过的格数。传了就用它，不再从格距反推 ——
    ///     否则用户点 +1 之后这里又按 bbox 算回原来的数，按钮看起来像没反应。
    static func fitGrid(
        work: PartsWorkImage,
        part: BeadPart,
        calibration: PartsGridCalibration,
        forcedCols: Int? = nil,
        forcedRows: Int? = nil
    ) -> FittedGrid? {
        let cols = forcedCols ?? max(1, Int((Double(part.bounds.width) / calibration.cellWidth).rounded()))
        let rows = forcedRows ?? max(1, Int((Double(part.bounds.height) / calibration.cellHeight).rounded()))

        // 往外放两格再搜，保证真正的边界落在搜索范围里面
        let margin = CGSize(width: calibration.cellWidth * 2, height: calibration.cellHeight * 2)
        let expanded = part.bounds
            .insetBy(dx: -margin.width, dy: -margin.height)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let bitmap = PartsBitmap.make(from: work, roi: expanded, maxPixels: 400_000),
              bitmap.width >= 16, bitmap.height >= 16 else { return nil }

        let profiles = gradientProfiles(of: bitmap)
        // 格距按「这个零件的 bbox ÷ 格数」算，而不是直接用全局值：
        // 用户点 +1 改的就是格数，格距必须跟着走，否则线的疏密不变。
        let cellW = forcedCols != nil ? Double(part.bounds.width) / Double(cols) : calibration.cellWidth
        let cellH = forcedRows != nil ? Double(part.bounds.height) / Double(rows) : calibration.cellHeight
        let pitchX = cellW / Double(expanded.width) * Double(bitmap.width)
        let pitchY = cellH / Double(expanded.height) * Double(bitmap.height)
        // 网格的起点应该就在零件左上角附近，允许它在正负一格半里找 ——
        // 放开整个搜索窗口去找的话，得分最高的位置常常整片飘到零件外面（那里
        // 有水印和图纸底纹的规则纹理，同样能刷出高分）。
        let expectedX = Double(part.bounds.minX - expanded.minX) / Double(expanded.width) * Double(bitmap.width)
        let expectedY = Double(part.bounds.minY - expanded.minY) / Double(expanded.height) * Double(bitmap.height)
        guard let x = fitAxis(profile: profiles.columns, lines: cols, pitch: pitchX,
                              expectedStart: expectedX, tolerance: pitchX * 1.5),
              let y = fitAxis(profile: profiles.rows, lines: rows, pitch: pitchY,
                              expectedStart: expectedY, tolerance: pitchY * 1.5) else { return nil }

        let rect = CGRect(
            x: expanded.minX + CGFloat(x.start / Double(bitmap.width)) * expanded.width,
            y: expanded.minY + CGFloat(y.start / Double(bitmap.height)) * expanded.height,
            width: CGFloat(x.pitch * Double(cols) / Double(bitmap.width)) * expanded.width,
            height: CGFloat(y.pitch * Double(rows) / Double(bitmap.height)) * expanded.height
        )
        return FittedGrid(rect: rect, rows: rows, cols: cols)
    }

    /// 在一条曲线上找网格的**起点**，让 lines+1 条等距线尽量都落在峰上。
    ///
    /// **格距是给定的，这里不动它。** 早先允许它在给定值上下浮动 6%，理由是
    /// 「用手指量的不可能准」；结果每个零件的格子大小都不一样，同一张图纸上
    /// 一格到底多大变成了一件说不清的事。格距全图一个数，这里只解相位。
    private static func fitAxis(
        profile: [Double], lines: Int, pitch: Double,
        expectedStart: Double, tolerance: Double
    ) -> (start: Double, pitch: Double)? {
        let n = profile.count
        let span = pitch * Double(lines)
        guard lines >= 1, pitch >= 2, span <= Double(n - 1) else { return nil }

        var best: (start: Double, score: Double)?
        let lower = max(0, expectedStart - tolerance)
        let upper = min(Double(n - 1) - span, expectedStart + tolerance)
        guard lower <= upper else { return nil }
        var start = lower
        while start <= upper {
            var total = 0.0
            for k in 0...lines {
                let x = Int((start + Double(k) * pitch).rounded())
                let lo = max(0, x - 1), hi = min(n - 1, x + 1)
                total += (lo...hi).map { profile[$0] }.max() ?? 0
            }
            let score = total / Double(lines + 1)
            if best == nil || score > best!.score { best = (start, score) }
            start += 0.25
        }
        guard let best else { return nil }
        return (best.start, pitch)
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
