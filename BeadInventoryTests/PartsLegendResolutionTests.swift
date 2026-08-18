import XCTest
@testable import BeadInventory

/// 拼图模式判色时「图纸色号表 → 色库里的豆子」这一道翻译。
///
/// 值得写测试：错了不会崩、不会报错，只会让核对页少几个色号 ——
/// 而少掉的那些格子被硬塞进剩下的色号里，看起来跟「判得不太准」一模一样。
/// 卡卡 / COCO 图纸上曾经整张图例作废，用户看到的是「上面只给了 4 个颜色」。
final class PartsLegendResolutionTests: XCTestCase {

    /// 三颗豆子，MARD 码和卡卡码故意错开：
    /// 黑豆的 mardCode 是 H7、卡卡码是 B11；而**另一颗**红豆的卡卡码恰好是 H7 那种巧合
    /// 正是老代码栽的地方，所以这里把它也摆进来。
    private let black = BeadColor(colorHex: "000000", mardCode: "H7", cocoCode: "B09", kakaCode: "B11")
    private let white = BeadColor(colorHex: "FFFFFF", mardCode: "H1", cocoCode: "B01", kakaCode: "B1")
    private let red = BeadColor(colorHex: "FF0000", mardCode: "C1", cocoCode: "C01", kakaCode: "H7")
    /// 只有 MARD 码的豆子：卡卡图纸上根本显示不出来。
    private let mardOnly = BeadColor(colorHex: "00FF00", mardCode: "R5")

    private var library: [BeadColor] { [black, white, red, mardOnly] }

    // MARK: - MARD 图纸

    func testMardProject_resolvesCanonicalCodes() {
        let result = PartsCellClassifier.resolveLegend(
            codes: ["H7", "H1"], availableColors: library, colorSystem: .mard
        )
        XCTAssertEqual(result.colors.map(\.mardCode), ["H7", "H1"])
        XCTAssertTrue(result.unknownCodes.isEmpty)
    }

    // MARK: - 非 MARD 图纸（这里是老代码整片失配的地方）

    /// 图例存的是 canonical mardCode（扫描那步的约定），而格子里存的是卡卡码。
    /// 不翻这一道，卡卡项目的图例只剩巧合，判色被锁死在那几个色号上。
    func testKakaProject_legendStoredAsMardCode_stillResolves() {
        let result = PartsCellClassifier.resolveLegend(
            codes: ["H7", "H1"], availableColors: library, colorSystem: .kaka
        )
        XCTAssertEqual(result.colors.map(\.colorHex), ["000000", "FFFFFF"],
                       "H7 是黑豆的 MARD 码，不能认成「卡卡码恰好叫 H7」的那颗红豆")
        XCTAssertTrue(result.unknownCodes.isEmpty)
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

    /// 原始串恰好是本体系的合法码时（COCO 图纸上的 "B09"），按本体系认。
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

    func testDuplicateLegendEntriesCollapse() {
        let result = PartsCellClassifier.resolveLegend(
            codes: ["H7", "H7"], availableColors: library, colorSystem: .mard
        )
        XCTAssertEqual(result.colors.count, 1)
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

    /// 画一张 4×2 的「图纸」，每格一种颜色，一格 40 像素。
    private func makeWork() -> PartsWorkImage {
        let cell = 40.0
        let size = CGSize(width: cell * 4, height: cell * 2)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            for (index, swatch) in Self.swatches.enumerated() {
                let rgb = GridCellSampler.rgbFromHex(swatch.hex)!
                UIColor(red: rgb.r / 255, green: rgb.g / 255, blue: rgb.b / 255, alpha: 1).setFill()
                ctx.fill(CGRect(x: Double(index % 4) * cell, y: Double(index / 4) * cell,
                                width: cell, height: cell))
            }
        }
        return .whole(image)
    }

    private func classify(legend: [String]) -> PartsCellClassifier.Result {
        let part = BeadPart(rowBand: 0, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                            gridRect: CGRect(x: 0, y: 0, width: 1, height: 1), rows: 2, cols: 4)
        return PartsCellClassifier.classify(
            work: makeWork(),
            parts: [part],
            roi: CGRect(x: 0, y: 0, width: 1, height: 1),
            calibration: PartsGridCalibration(cellWidth: 0.25, cellHeight: 0.5),
            colorSystem: .mard,
            legendCodes: legend,
            availableColors: library,
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
        XCTAssertNotNil(result.unknownLegendNote)
    }

    /// 完全没有色号表（用户手建的项目）：照旧退回全色库。
    func testNoLegend_fallsBackToWholeLibrary() {
        XCTAssertEqual(codes(classify(legend: [])), Set(Self.swatches.map(\.code)))
    }
}
