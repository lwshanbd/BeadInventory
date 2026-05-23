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
        XCTAssertEqual(withHash.cgColor, withoutHash.cgColor)
    }

    func test_colorPalette_codableRoundTrip() throws {
        let p = ColorPalette(bg: "FAF5EC", bgElev: "FFFDF8")
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(ColorPalette.self, from: data)
        XCTAssertEqual(p, decoded)
    }
}
