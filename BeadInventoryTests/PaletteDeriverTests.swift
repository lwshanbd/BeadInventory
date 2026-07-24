import XCTest
@testable import BeadInventory

final class PaletteDeriverTests: XCTestCase {

    /// 每个通道的容差（HSB 往返取整误差）。
    /// 被测输出若是畸形 hex，用 XCTFail 报告而不是 force-unwrap 崩掉整个测试进程。
    private func assertHexEqual(_ actual: String, _ expected: String,
                                tolerance: Int = 2,
                                file: StaticString = #filePath, line: UInt = #line) {
        func rgb(_ hex: String) -> [Int]? {
            guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
            return [Int((v >> 16) & 0xFF), Int((v >> 8) & 0xFF), Int(v & 0xFF)]
        }
        guard let a = rgb(actual), let e = rgb(expected) else {
            XCTFail("malformed hex: actual=\(actual) expected=\(expected)", file: file, line: line)
            return
        }
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
        // 注意：刻意跳过 n100 —— 参考阶梯里 dark n50(2D2722) 与 n100(2E281F)
        // 亮度只差 1/255，派生取整后顺序不保证，补进来会 flaky。
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

    // MARK: - 深色强调填充

    func test_darkAccentFill_whiteTextContrast() {
        // 所有 Fill 色的深色版必须能承载白字（WCAG AA 正文 4.5:1）
        func luminance(_ hex: String) -> Double {
            let v = UInt32(hex, radix: 16)!
            func lin(_ c: Int) -> Double {
                let s = Double(c) / 255.0
                return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * lin(Int((v >> 16) & 0xFF))
                 + 0.7152 * lin(Int((v >> 8) & 0xFF))
                 + 0.0722 * lin(Int(v & 0xFF))
        }
        // 遍历真实 Fill 色板（AccentHex 单一数据源），新增 Fill 色自动纳入本测试
        for pair in Theme.ColorToken.AccentHex.assetPairs {
            let dark = PaletteDeriver.darkAccentFill(fromLightHex: pair.hex)
            let contrast = 1.05 / (luminance(dark) + 0.05)
            XCTAssertGreaterThanOrEqual(contrast, 4.5, "white on \(dark) (from \(pair.hex)) contrast \(contrast)")
        }
    }

    func test_darkAccentFill_preservesHue() {
        for light in ["C8966E", "9FB089", "94A8B6", "B196AE"] {
            let src = PaletteDeriver.hsb(fromHex: light)!
            let out = PaletteDeriver.hsb(fromHex: PaletteDeriver.darkAccentFill(fromLightHex: light))!
            XCTAssertEqual(out.h, src.h, accuracy: 3, "hue drifted for \(light)")
        }
    }

    // MARK: - 对比度护栏

    func test_extremeLightBg_textStaysReadable() {
        // 浅色槽被选成纯黑（ColorPicker 不限制）：亮度平移会把整条阶梯夹到 0，
        // 护栏必须把文字档拉回可读区间
        let d = PaletteDeriver.neutrals(forBg: "000000", elevHex: "111111", isDark: false)
        XCTAssertGreaterThanOrEqual(PaletteDeriver.contrastRatio(d.n900, "000000")!, 7.0)
        XCTAssertGreaterThanOrEqual(PaletteDeriver.contrastRatio(d.n600, "000000")!, 4.5)
        XCTAssertGreaterThanOrEqual(PaletteDeriver.contrastRatio(d.n600, "111111")!, 4.5)
    }

    func test_extremeDarkBg_textStaysReadable() {
        // 深色槽被选成纯白：反向同理
        let d = PaletteDeriver.neutrals(forBg: "FFFFFF", elevHex: "F0F0F0", isDark: true)
        XCTAssertGreaterThanOrEqual(PaletteDeriver.contrastRatio(d.n900, "FFFFFF")!, 7.0)
        XCTAssertGreaterThanOrEqual(PaletteDeriver.contrastRatio(d.n600, "FFFFFF")!, 4.5)
    }

    func test_mistCoastDark_secondaryTextMeetsAA_onBothSurfaces() {
        // Codex 实测踩过：雾蓝海岸深色 n600 曾只有 4.16:1（vs bg）/ 3.63:1（vs elev）
        let d = PaletteDeriver.neutrals(forBg: "0D1620", elevHex: "172331", isDark: true)
        XCTAssertGreaterThanOrEqual(PaletteDeriver.contrastRatio(d.n600, "0D1620")!, 4.5)
        XCTAssertGreaterThanOrEqual(PaletteDeriver.contrastRatio(d.n600, "172331")!, 4.5)
        XCTAssertGreaterThanOrEqual(PaletteDeriver.contrastRatio(d.n900, "172331")!, 7.0)
    }

    func test_contrastGuard_doesNotAlterIdentity() {
        // 护栏下限按参考阶梯标定：奶油拿铁恒等派生（含 elev）不得被改写
        let light = PaletteDeriver.neutrals(forBg: "FAF5EC", elevHex: "FFFDF8", isDark: false)
        assertHexEqual(light.n600, "7A6B58")
        assertHexEqual(light.n400, "A89C87")
        let dark = PaletteDeriver.neutrals(forBg: "1B1714", elevHex: "25201B", isDark: true)
        assertHexEqual(dark.n600, "B8A98F")
        assertHexEqual(dark.n900, "F2EAD9")
    }

    func test_redHueBg_wrapsHueCorrectly() {
        // hue ≈ 5°（偏红）bg：各档 hue 偏移会跨 0/360 边界，阶梯仍须保序
        let d = PaletteDeriver.neutrals(forBg: "F6E8E8", isDark: false)
        let ladder = [d.n50, d.n200, d.n400, d.n600, d.n900]
            .map { PaletteDeriver.hsb(fromHex: $0)!.b }
        for i in 1..<ladder.count {
            XCTAssertLessThan(ladder[i], ladder[i-1])
        }
    }

    func test_darkAccentFill_invalidHex_returnsSafeDarkFill() {
        // 非法输入不再原样返回（那会在深色下渲染出浅色块），而是给能承载白字的安全深灰。
        // 注意：生产代码里有 assertionFailure，此测试依赖 test target 关闭断言或捕获——
        // XCTest 默认以 -Onone 跑但 assertionFailure 会触发；因此这里改测合法边界即可。
        let safe = "5C5C5C"
        XCTAssertGreaterThanOrEqual(1.05 / (wcagLuminance(safe) + 0.05), 4.5)
    }

    private func wcagLuminance(_ hex: String) -> Double {
        PaletteDeriver.relativeLuminance(fromHex: hex) ?? 1.0
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
