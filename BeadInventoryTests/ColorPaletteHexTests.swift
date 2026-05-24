import XCTest
import SwiftUI
@testable import BeadInventory

final class ColorPaletteHexTests: XCTestCase {

    func test_uiColorFromHex_validHex_returnsCorrectColor() {
        let c = UIColor(themeHex: "FAF5EC")
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(r, 0.980, accuracy: 0.005)
        XCTAssertEqual(g, 0.961, accuracy: 0.005)
        XCTAssertEqual(b, 0.925, accuracy: 0.005)
    }

    func test_uiColorFromHex_invalidHex_returnsFallback() {
        let c = UIColor(themeHex: "ZZZZZZ", fallback: .red)
        XCTAssertEqual(c, .red)
    }

    func test_uiColorFromHex_acceptsLeadingHash() {
        let withHash = UIColor(themeHex: "#FAF5EC")
        let withoutHash = UIColor(themeHex: "FAF5EC")
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0
        withHash.getRed(&r1, green: &g1, blue: &b1, alpha: nil)
        withoutHash.getRed(&r2, green: &g2, blue: &b2, alpha: nil)
        XCTAssertEqual(r1, r2, accuracy: 0.001)
        XCTAssertEqual(g1, g2, accuracy: 0.001)
        XCTAssertEqual(b1, b2, accuracy: 0.001)
    }

    func test_uiColorFromHex_acceptsLowercase() {
        let lower = UIColor(themeHex: "faf5ec")
        let upper = UIColor(themeHex: "FAF5EC")
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0
        lower.getRed(&r1, green: &g1, blue: &b1, alpha: nil)
        upper.getRed(&r2, green: &g2, blue: &b2, alpha: nil)
        XCTAssertEqual(r1, r2, accuracy: 0.001)
        XCTAssertEqual(g1, g2, accuracy: 0.001)
        XCTAssertEqual(b1, b2, accuracy: 0.001)
    }

    func test_colorPalette_codableRoundTrip() throws {
        let p = ColorPalette(bg: "FAF5EC", bgElev: "FFFDF8")
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(ColorPalette.self, from: data)
        XCTAssertEqual(p, decoded)
    }
}
