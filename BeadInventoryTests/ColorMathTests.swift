import XCTest
@testable import BeadInventory

/// 拼图模式色彩转换 + ΔE 数学的回归测试。
/// 这些是纯函数，一个 sign flip 或通道交换就能毁掉整个识别。
final class ColorMathTests: XCTestCase {

    // MARK: - rgbFromHex

    func testRgbFromHex_withHash() {
        let rgb = GridCellSampler.rgbFromHex("#FF8000")
        XCTAssertNotNil(rgb)
        XCTAssertEqual(rgb?.r, 255)
        XCTAssertEqual(rgb?.g, 128)
        XCTAssertEqual(rgb?.b, 0)
    }

    func testRgbFromHex_withoutHash() {
        let rgb = GridCellSampler.rgbFromHex("FF8000")
        XCTAssertEqual(rgb?.r, 255)
        XCTAssertEqual(rgb?.g, 128)
        XCTAssertEqual(rgb?.b, 0)
    }

    func testRgbFromHex_lowercase() {
        let rgb = GridCellSampler.rgbFromHex("#fbed56")
        XCTAssertEqual(rgb?.r, 0xFB)
        XCTAssertEqual(rgb?.g, 0xED)
        XCTAssertEqual(rgb?.b, 0x56)
    }

    func testRgbFromHex_invalidLength() {
        XCTAssertNil(GridCellSampler.rgbFromHex("#FFF"))     // 3-char shorthand 不支持
        XCTAssertNil(GridCellSampler.rgbFromHex(""))
        XCTAssertNil(GridCellSampler.rgbFromHex("#"))
        XCTAssertNil(GridCellSampler.rgbFromHex("#1234567"))
    }

    func testRgbFromHex_invalidChars() {
        XCTAssertNil(GridCellSampler.rgbFromHex("#GG0000"))
        XCTAssertNil(GridCellSampler.rgbFromHex("#XYZABC"))
    }

    // MARK: - lab(forHex:)

    func testLabFromHex_black() {
        let lab = GridCellSampler.lab(forHex: "#000000")
        XCTAssertNotNil(lab)
        XCTAssertEqual(lab!.l, 0, accuracy: 0.01)
        XCTAssertEqual(lab!.a, 0, accuracy: 0.01)
        XCTAssertEqual(lab!.b, 0, accuracy: 0.01)
    }

    func testLabFromHex_white() {
        let lab = GridCellSampler.lab(forHex: "#FFFFFF")
        XCTAssertNotNil(lab)
        XCTAssertEqual(lab!.l, 100, accuracy: 0.1)
        XCTAssertEqual(lab!.a, 0, accuracy: 0.5)
        XCTAssertEqual(lab!.b, 0, accuracy: 0.5)
    }

    func testLabFromHex_grayHasZeroChroma() {
        let lab = GridCellSampler.lab(forHex: "#808080")
        XCTAssertNotNil(lab)
        // 中灰：L 在中间，a/b 接近 0（无色度）
        XCTAssertEqual(lab!.a, 0, accuracy: 1)
        XCTAssertEqual(lab!.b, 0, accuracy: 1)
        XCTAssertGreaterThan(lab!.l, 30)
        XCTAssertLessThan(lab!.l, 70)
    }

    func testLabFromHex_invalid() {
        XCTAssertNil(GridCellSampler.lab(forHex: "not a hex"))
    }

    // MARK: - deltaE

    func testDeltaE_sameColor_isZero() {
        let lab = LabColor(l: 50, a: 10, b: -20)
        XCTAssertEqual(GridCellSampler.deltaE(lab, lab), 0, accuracy: 0.0001)
    }

    func testDeltaE_isSymmetric() {
        let a = LabColor(l: 50, a: 10, b: -20)
        let b = LabColor(l: 30, a: -5, b: 40)
        let ab = GridCellSampler.deltaE(a, b)
        let ba = GridCellSampler.deltaE(b, a)
        XCTAssertEqual(ab, ba, accuracy: 0.0001)
    }

    func testDeltaE_blackWhite_isLarge() {
        let black = GridCellSampler.lab(forHex: "#000000")!
        let white = GridCellSampler.lab(forHex: "#FFFFFF")!
        // 纯黑到纯白 ΔE 约 100（L 通道差异）
        XCTAssertEqual(GridCellSampler.deltaE(black, white), 100, accuracy: 0.5)
    }

    func testDeltaE_distinguishesYellowFromRed() {
        // 标准红 vs 标准黄：颜色明显不同，ΔE 应该远大于阈值
        let red = GridCellSampler.lab(forHex: "#FF0000")!
        let yellow = GridCellSampler.lab(forHex: "#FFFF00")!
        XCTAssertGreaterThan(GridCellSampler.deltaE(red, yellow), 50)
    }
}
