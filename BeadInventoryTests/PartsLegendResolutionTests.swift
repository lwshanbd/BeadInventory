import XCTest
@testable import BeadInventory

/// 拼图模式判色时「图纸色号表 → 色库里的豆子」这一道翻译。
///
/// 值得写测试：错了不会崩、不会报错，只会让核对页少几个色号 ——
/// 而少掉的那些格子被硬塞进剩下的色号里，看起来跟「判得不太准」一模一样。
/// 卡卡 / COCO 图纸上曾经整张图例作废，用户看到的是「上面只给了 4 个颜色」。
final class PartsLegendResolutionTests: XCTestCase {

    /// 这两颗是色库里真实存在的一对撞名豆子（`allcolors.json`）：
    /// 橄榄绿的 MARD 码是 `B11`、卡卡码是 `B140`；而黑豆的**卡卡码**恰好也叫 `B11`。
    /// 卡卡上这样的撞名有 21 个，全落在 MARD 的绿色系。
    private let olive = BeadColor(colorHex: "5D722A", mardCode: "B11", kakaCode: "B140")
    private let black = BeadColor(colorHex: "000000", mardCode: "H7", cocoCode: "B09", kakaCode: "B11")
    private let white = BeadColor(colorHex: "FFFFFF", mardCode: "H1", cocoCode: "B01", kakaCode: "B1")
    /// 只有 MARD 码的豆子：卡卡图纸上根本显示不出来。
    private let mardOnly = BeadColor(colorHex: "00FF00", mardCode: "R5")

    private var library: [BeadColor] { [olive, black, white, mardOnly] }

    // MARK: - MARD 图纸

    func testMardProject_resolvesCanonicalCodes() {
        let result = PartsCellClassifier.resolveLegend(
            codes: ["H7", "H1"], availableColors: library, colorSystem: .mard
        )
        XCTAssertEqual(result.colors.map(\.mardCode), ["H7", "H1"])
        XCTAssertTrue(result.unknownCodes.isEmpty)
    }

    // MARK: - 非 MARD 图纸（这里是老代码整片失配的地方）

    /// **卡卡项目里，图例存的那串字仍然是 MARD 码。**
    ///
    /// 扫描那步（`ScanView.recognizeImage`）不管项目选了什么体系，认出来的一律换成
    /// canonical mardCode 存下来。所以图纸上印着卡卡的 `B140`（橄榄绿），
    /// 数据库里存的是 `B11` —— 按卡卡码去查它，查到的是黑豆。整片绿色会变成黑色。
    ///
    /// 这条守的是 21 个真实色号，全是绿色系。
    func testKakaProject_storedCodeIsMardCode_notTheKakaLookalike() {
        let result = PartsCellClassifier.resolveLegend(
            codes: ["B11"], availableColors: library, colorSystem: .kaka
        )
        XCTAssertEqual(result.colors.map(\.colorHex), ["5D722A"],
                       "B11 是橄榄绿的 MARD 码，不能认成「卡卡码恰好叫 B11」的那颗黑豆")
    }

    /// 这个体系里没有码的豆子不能进候选：判成它等于给用户一个他在图纸上翻不到的色号。
    func testKakaProject_dropsColorsWithoutKakaCode() {
        let result = PartsCellClassifier.resolveLegend(
            codes: ["R5"], availableColors: library, colorSystem: .kaka
        )
        XCTAssertTrue(result.colors.isEmpty)
        XCTAssertEqual(result.unknownCodes, ["R5"])
    }

    // MARK: - AI 没匹配上的原始串

    /// 色号表上印的是我们没收录的品牌码时，扫描那步原样存下来。
    /// 这种码在色库里查不到 —— 必须报出来，不能默默丢掉。
    func testUnknownCodesAreReported() {
        let result = PartsCellClassifier.resolveLegend(
            codes: ["H7", "HR", "FG", "hr"], availableColors: library, colorSystem: .mard
        )
        XCTAssertEqual(result.colors.map(\.mardCode), ["H7"])
        XCTAssertEqual(result.unknownCodes, ["HR", "FG"], "大小写不同的同一个码只报一次")
    }

    /// 按 mardCode 查不到时，才轮到本体系的码 —— 兜的是「AI 读到了、我们当时没匹配上」
    /// 那一支（色库里没有任何豆子的 mardCode 叫 "B09"，所以只可能是 COCO 码）。
    /// 删掉这条兜底，这种图例条目会被误报成「色库里没有」。
    func testRawBrandCodeResolvesByDisplayCode() {
        let result = PartsCellClassifier.resolveLegend(
            codes: ["B09"], availableColors: library, colorSystem: .coco
        )
        XCTAssertEqual(result.colors.map(\.colorHex), ["000000"])
    }

    /// 「任意色」是色号表上的一行字，不是色号：既不进候选，也不算「色库里没有」。
    func testAnyColorIsNeitherResolvedNorReported() {
        let result = PartsCellClassifier.resolveLegend(
            codes: ["any", "H7"], availableColors: library, colorSystem: .mard
        )
        XCTAssertEqual(result.colors.map(\.mardCode), ["H7"])
        XCTAssertTrue(result.unknownCodes.isEmpty)
    }
}

/// 判色整条链路：图上有几种颜色，核对页就该有几组。
///
/// 用户实测撞上的正是它的反面 —— 色号表里十几个色号，能在色库里查到的只有 4 个，
/// 于是图上所有颜色被塞进那 4 个色号，核对页「上面只给了 4 个颜色」，
/// 剩下的全得一格一格自己改。
final class PartsClassifyLegendCoverageTests: XCTestCase {

    /// 八种拉得很开的颜色，当成图纸上的八种豆子。
    private static let swatches: [(code: String, hex: String)] = [
        ("A1", "FF0000"), ("A2", "00FF00"), ("A3", "0000FF"), ("A4", "FFFF00"),
        ("A5", "00FFFF"), ("A6", "FF8800"), ("A7", "000000"), ("A8", "FFFFFF"),
    ]

    private var library: [BeadColor] {
        Self.swatches.map { BeadColor(colorHex: $0.hex, mardCode: $0.code) }
    }

    /// 画一张一行 N 格的「图纸」，每格一种颜色，一格 40 像素。
    private func makeWork(_ hexes: [String]) -> PartsWorkImage {
        let cell = 40.0
        let size = CGSize(width: cell * Double(hexes.count), height: cell)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            for (index, hex) in hexes.enumerated() {
                let rgb = GridCellSampler.rgbFromHex(hex)!
                UIColor(red: rgb.r / 255, green: rgb.g / 255, blue: rgb.b / 255, alpha: 1).setFill()
                ctx.fill(CGRect(x: Double(index) * cell, y: 0, width: cell, height: cell))
            }
        }
        return .whole(image)
    }

    private func classify(
        legend: [String],
        hexes: [String]? = nil,
        colors: [BeadColor]? = nil,
        colorSystem: ColorSystem = .mard
    ) -> PartsCellClassifier.Result {
        let hexes = hexes ?? Self.swatches.map(\.hex)
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let part = BeadPart(rowBand: 0, bounds: unit, gridRect: unit, rows: 1, cols: hexes.count)
        return PartsCellClassifier.classify(
            work: makeWork(hexes),
            parts: [part],
            roi: unit,
            calibration: PartsGridCalibration(cellWidth: 1 / Double(hexes.count), cellHeight: 1),
            colorSystem: colorSystem,
            legendCodes: legend,
            availableColors: colors ?? library,
            // 底色指认成一个图上没有的颜色，免得自动猜底色把某一种豆子判成空 ——
            // 这里要测的是色号，不是空格。
            emptyHex: "FF00FF"
        )
    }

    private func codes(_ result: PartsCellClassifier.Result) -> Set<String> {
        var found: Set<String> = []
        for row in result.parts[0].cells {
            for cell in row {
                if case .code(let code) = cell { found.insert(code) }
            }
        }
        return found
    }

    /// 色号表齐全时：老老实实照色号表判，八种颜色八个色号。
    func testFullLegend_everyColorKeepsItsOwnCode() {
        let result = classify(legend: Self.swatches.map(\.code))
        XCTAssertEqual(codes(result), Set(Self.swatches.map(\.code)))
        XCTAssertTrue(result.unknownLegendCodes.isEmpty)
    }

    /// 色号表只查得到 2 个色号（其余印的是色库里没有的品牌码）时，
    /// **剩下六种颜色不能被塞进这 2 个色号** —— 那样它们在核对页会合成两组，
    /// 用户连「整类改掉」都做不到。
    func testLegendCoversOnlyPartOfTheSheet() {
        let result = classify(legend: ["A1", "A2", "HR", "FG"])
        XCTAssertEqual(codes(result), Set(Self.swatches.map(\.code)),
                       "图上八种颜色，判出来也该是八个色号")
        XCTAssertEqual(result.unknownLegendCodes, ["HR", "FG"],
                       "查不到的色号要报出来，好告诉用户这几组的字跟图纸上印的不一样")
    }

    /// 完全没有色号表（用户手建的项目）：照旧退回全色库。
    func testNoLegend_fallsBackToWholeLibrary() {
        XCTAssertEqual(codes(classify(legend: [])), Set(Self.swatches.map(\.code)))
    }

    /// 卡卡图纸整条链路：图例存的是 canonical mardCode，格子里要写的是卡卡码。
    ///
    /// 这里曾经整片失配：图例作废，判色被锁在几个「mardCode 恰好也是合法卡卡码」的
    /// 巧合上，而且认领的是另一颗豆子。
    func testKakaSheet_legendInMardCodes_cellsSpeakKakaCodes() {
        // 图例里这两个码（C1 / C2）在卡卡体系里不是合法色号，走的是 mardCode 兜底那一支。
        let library = [
            BeadColor(colorHex: "FF0000", mardCode: "C1", kakaCode: "R9"),
            BeadColor(colorHex: "00FF00", mardCode: "C2", kakaCode: "P3"),
            // 图例里没有的第三种颜色，用来确认它不会被塞进上面两个色号
            BeadColor(colorHex: "0000FF", mardCode: "C3", kakaCode: "B77"),
            // 卡卡没有这一颗，而且它**比 C3 更接近那一格的颜色** —— 少了 `table()` 里的
            // hasCode 过滤，它就会赢，用户会拿到一个在卡卡色号表上翻不到的色号。
            BeadColor(colorHex: "0000F0", mardCode: "C4"),
        ]
        let result = classify(legend: ["C1", "C2"],
                              hexes: ["FF0000", "00FF00", "0000F4"],
                              colors: library,
                              colorSystem: .kaka)
        XCTAssertEqual(codes(result), ["R9", "P3", "B77"])
        XCTAssertTrue(result.unknownLegendCodes.isEmpty)
    }

    /// **图例里有一个够像的，就别去全色库里挑更像的。**
    ///
    /// 这条守的是 `legendMissDeltaE` 本身：格子色离图例色 ΔE≈11.5，离色库里另一颗
    /// 不在图例上的豆子只有 ΔE≈0.4。判色必须写图例上那个色号 —— 图纸上印的就是它，
    /// 用户拿着它去翻库存才对得上。阈值被调小、或者「图例优先」那一支被删掉，这条会挂。
    func testLegendWinsOverACloserColorOutsideIt() {
        let onSheet = BeadColor(colorHex: "35709F", mardCode: "L1")
        let closer = BeadColor(colorHex: "4181C1", mardCode: "W1")
        let result = classify(legend: ["L1"], hexes: ["4080C0"],
                              colors: [onSheet, closer])
        XCTAssertEqual(codes(result), ["L1"],
                       "图例里的 L1 已经够像了，不该被色库里更近的 W1 顶掉")
    }

    /// 卡卡图纸上，图例里那颗豆子压根没有卡卡码时：不能默默当它不存在，
    /// 得报出来（用户在卡卡体系下根本翻不到这个色号）。
    func testKakaSheet_legendColorWithoutKakaCodeIsReported() {
        let library = [BeadColor(colorHex: "FF0000", mardCode: "C1"),
                       BeadColor(colorHex: "00FF00", mardCode: "C2", kakaCode: "P3")]
        let result = classify(legend: ["C1"], hexes: ["00FF00"],
                              colors: library, colorSystem: .kaka)
        XCTAssertEqual(result.unknownLegendCodes, ["C1"])
    }
}
