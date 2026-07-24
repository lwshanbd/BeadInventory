import XCTest
import UIKit
@testable import BeadInventory

/// 派生数学与 token 层之间「胶水」的回归测试：
/// - dynamicNeutral 的 trait 分派（light/dark 判断、keypath 取值、hex→UIColor 整条链）
/// - AccentHex 硬编码值与 Asset Catalog light 分量的一致性（防三处硬编码漂移）
final class ThemeDynamicColorTests: XCTestCase {

    private var appBundle: Bundle { Bundle(for: InventoryManager.self) }

    private func rgb(_ color: UIColor) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: nil)
        return (r, g, b)
    }

    private func assertSameColor(_ a: UIColor, _ b: UIColor,
                                 _ message: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let ca = rgb(a), cb = rgb(b)
        XCTAssertEqual(ca.r, cb.r, accuracy: 0.004, message, file: file, line: line)
        XCTAssertEqual(ca.g, cb.g, accuracy: 0.004, message, file: file, line: line)
        XCTAssertEqual(ca.b, cb.b, accuracy: 0.004, message, file: file, line: line)
    }

    // MARK: - dynamicNeutral trait 分派

    func test_dynamicNeutral_resolvesLightAndDarkLadders() {
        let defaults = UserDefaults(suiteName: "ThemeDynamicColorTests-\(UUID().uuidString)")!
        let tm = ThemeManager.test_make(defaults: defaults)

        let lightExpected = PaletteDeriver.neutrals(
            forBg: ColorPalette.defaultLight.bg,
            elevHex: ColorPalette.defaultLight.bgElev, isDark: false)
        let darkExpected = PaletteDeriver.neutrals(
            forBg: ColorPalette.defaultDark.bg,
            elevHex: ColorPalette.defaultDark.bgElev, isDark: true)

        let keyPaths: [(KeyPath<DerivedNeutrals, ColorHex>, String)] = [
            (\.n50, "n50"), (\.n200, "n200"), (\.n600, "n600"), (\.n900, "n900"),
            (\.surfaceStrong, "surfaceStrong"),
        ]
        for (kp, name) in keyPaths {
            let dynamic = tm.dynamicNeutral(kp)
            let resolvedLight = dynamic.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
            let resolvedDark = dynamic.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
            assertSameColor(resolvedLight, UIColor(themeHex: lightExpected[keyPath: kp]),
                            "light \(name) 应等于浅色派生阶梯对应档")
            assertSameColor(resolvedDark, UIColor(themeHex: darkExpected[keyPath: kp]),
                            "dark \(name) 应等于深色派生阶梯对应档")
        }
    }

    func test_dynamicNeutral_followsSwatchEdit() {
        // 派生必须跟随 updateSwatch（将来若加缓存忘了失效，这条是唯一防线）
        let defaults = UserDefaults(suiteName: "ThemeDynamicColorTests-\(UUID().uuidString)")!
        let tm = ThemeManager.test_make(defaults: defaults)
        tm.updateSwatch(.lightBg, hex: "EAF1F6")   // 雾蓝海岸浅色

        let expected = PaletteDeriver.neutrals(
            forBg: "EAF1F6", elevHex: tm.resolvedLight.bgElev, isDark: false)
        let resolved = tm.dynamicNeutral(\.n600)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        assertSameColor(resolved, UIColor(themeHex: expected.n600),
                        "updateSwatch 后浅色 n600 应按新 bg 派生")
    }

    func test_updateSwatch_rejectsInvalidHex() {
        let defaults = UserDefaults(suiteName: "ThemeDynamicColorTests-\(UUID().uuidString)")!
        let tm = ThemeManager.test_make(defaults: defaults)
        let before = tm.resolvedLight.bg
        tm.updateSwatch(.lightBg, hex: "not-a-hex")
        XCTAssertEqual(tm.resolvedLight.bg, before, "非法 hex 应被拒绝并保留旧值")
        tm.updateSwatch(.lightBg, hex: "#eaf1f6")
        XCTAssertEqual(tm.resolvedLight.bg, "EAF1F6", "合法 hex（带#小写）应归一化后接受")
    }

    // MARK: - AccentHex 与 Asset Catalog 一致性

    func test_accentHexes_matchAssetLightComponents() {
        for pair in Theme.ColorToken.AccentHex.assetPairs {
            guard let asset = UIColor(named: pair.assetName, in: appBundle, compatibleWith: nil) else {
                XCTFail("Asset missing: \(pair.assetName)")
                continue
            }
            let lightResolved = asset.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
            assertSameColor(lightResolved, UIColor(themeHex: pair.hex),
                            "AccentHex.\(pair.assetName) 与 Asset light 分量漂移——改了 colorset 记得同步 AccentHex")
        }
    }
}
