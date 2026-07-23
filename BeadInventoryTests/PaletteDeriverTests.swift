import XCTest
@testable import BeadInventory

final class PaletteDeriverTests: XCTestCase {

    /// 每个通道的容差（HSB 往返取整误差）
    private func assertHexEqual(_ actual: String, _ expected: String,
                                tolerance: Int = 2,
                                file: StaticString = #filePath, line: UInt = #line) {
        func rgb(_ hex: String) -> [Int] {
            let v = UInt32(hex, radix: 16)!
            return [Int((v >> 16) & 0xFF), Int((v >> 8) & 0xFF), Int(v & 0xFF)]
        }
        let a = rgb(actual), e = rgb(expected)
        for i in 0..<3 {
            XCTAssertLessThanOrEqual(abs(a[i] - e[i]), tolerance,
                "\(actual) vs \(expected) channel \(i)", file: file, line: line)
        }
    }

    // MARK: - 默认主题：派生结果 ≈ 原 Asset 色值（无视觉回归）

    func test_creamLatteLight_matchesAssetLadder() {
        let d = PaletteDeriver.neutrals(forBg: "FAF5EC", isDark: false)
        assertHexEqual(d.n50, "F4ECDE")
        assertHexEqual(d.n100, "EFE6D5")
        assertHexEqual(d.n200, "E4D9C5")
        assertHexEqual(d.n400, "A89C87")
        assertHexEqual(d.n600, "7A6B58")
        assertHexEqual(d.n900, "2D261E")
        assertHexEqual(d.surfaceStrong, "EBE2D2")
    }

    func test_creamLatteDark_matchesAssetLadder() {
        let d = PaletteDeriver.neutrals(forBg: "1B1714", isDark: true)
        assertHexEqual(d.n50, "2D2722")
        assertHexEqual(d.n100, "2E281F")
        assertHexEqual(d.n200, "3A3328")
        assertHexEqual(d.n400, "847868")
        assertHexEqual(d.n600, "B8A98F")
        assertHexEqual(d.n900, "F2EAD9")
        assertHexEqual(d.surfaceStrong, "38312A")
    }

    // MARK: - 换色调：中性阶应带上主题 hue

    func test_mistCoastLight_neutralsAreCoolToned() {
        // 雾蓝海岸 light bg #EAF1F6，hue ≈ 205°（蓝）
        let d = PaletteDeriver.neutrals(forBg: "EAF1F6", isDark: false)
        for hex in [d.n50, d.n100, d.n200, d.n400, d.n600, d.n900, d.surfaceStrong] {
            let hsb = PaletteDeriver.hsb(fromHex: hex)!
            if hsb.s > 0.02 {   // 几乎无饱和度时 hue 无意义
                XCTAssertEqual(hsb.h, 205, accuracy: 25, "expected cool hue, got \(hex)")
            }
        }
    }

    func test_mistCoastLight_preservesContrastLadder() {
        // 亮度阶梯的相对顺序必须保留：n50 > n100 > n200 > n400 > n600 > n900（light）
        let d = PaletteDeriver.neutrals(forBg: "EAF1F6", isDark: false)
        let ladder = [d.n50, d.n100, d.n200, d.n400, d.n600, d.n900]
            .map { PaletteDeriver.hsb(fromHex: $0)!.b }
        for i in 1..<ladder.count {
            XCTAssertLessThan(ladder[i], ladder[i-1])
        }
        // 文字主色仍足够深
        XCTAssertLessThan(PaletteDeriver.hsb(fromHex: d.n900)!.b, 0.25)
    }

    func test_darkPreset_preservesContrastLadder() {
        // 雾蓝海岸 dark bg #0D1620：dark 模式阶梯 n50 < ... < n900（越来越亮）
        let d = PaletteDeriver.neutrals(forBg: "0D1620", isDark: true)
        let ladder = [d.n50, d.n200, d.n400, d.n600, d.n900]
            .map { PaletteDeriver.hsb(fromHex: $0)!.b }
        for i in 1..<ladder.count {
            XCTAssertGreaterThan(ladder[i], ladder[i-1])
        }
        XCTAssertGreaterThan(PaletteDeriver.hsb(fromHex: d.n900)!.b, 0.8)
    }

    // MARK: - 边界

    func test_achromaticBg_yieldsGrayNeutrals() {
        let d = PaletteDeriver.neutrals(forBg: "F2F2F2", isDark: false)
        for hex in [d.n50, d.n200, d.n900] {
            XCTAssertEqual(PaletteDeriver.hsb(fromHex: hex)!.s, 0, accuracy: 0.001)
        }
    }

    func test_invalidBg_fallsBackToReferenceLadder() {
        let d = PaletteDeriver.neutrals(forBg: "not-a-hex", isDark: false)
        assertHexEqual(d.n50, "F4ECDE")
        assertHexEqual(d.n900, "2D261E")
    }

    func test_highSaturationBg_isClamped() {
        // 高饱和自定义 bg：任何一档的饱和度都不超过 0.9
        let d = PaletteDeriver.neutrals(forBg: "FFD0D0", isDark: false)
        for hex in [d.n50, d.n100, d.n200, d.n400, d.n600, d.n900] {
            XCTAssertLessThanOrEqual(PaletteDeriver.hsb(fromHex: hex)!.s, 0.9)
        }
    }

    // MARK: - HSB 往返

    func test_hsbRoundTrip() {
        for hex in ["FAF5EC", "EAF1F6", "0D1620", "C8966E", "000000", "FFFFFF"] {
            let hsb = PaletteDeriver.hsb(fromHex: hex)!
            let back = PaletteDeriver.hex(fromH: hsb.h, s: hsb.s, b: hsb.b)
            XCTAssertEqual(back, hex, "round trip failed for \(hex)")
        }
    }
}
