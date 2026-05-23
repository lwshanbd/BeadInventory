//
//  ThemeManagerTests.swift
//  BeadInventoryTests
//

import XCTest
@testable import BeadInventory

final class ThemeManagerTests: XCTestCase {

    func sampleScheme(id: UUID = UUID(), isBuiltin: Bool = false) -> AppColorScheme {
        AppColorScheme(
            id: id,
            name: "Sample",
            light: ColorPalette(bg: "AABBCC", bgElev: "DDEEFF"),
            dark:  ColorPalette(bg: "112233", bgElev: "445566"),
            isBuiltin: isBuiltin,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    func test_apply_both_setsAllFour_andActiveID() {
        let mgr = ThemeManager()
        let s = sampleScheme()
        mgr.apply(scheme: s, target: .both)
        XCTAssertEqual(mgr.resolvedLight, s.light)
        XCTAssertEqual(mgr.resolvedDark,  s.dark)
        XCTAssertEqual(mgr.activeSchemeID, s.id)
    }

    func test_apply_lightOnly_keepsDark_andActiveIDNil() {
        let mgr = ThemeManager(resolvedLight: .defaultLight, resolvedDark: .defaultDark)
        let originalDark = mgr.resolvedDark
        let s = sampleScheme()
        mgr.apply(scheme: s, target: .lightOnly)
        XCTAssertEqual(mgr.resolvedLight, s.light)
        XCTAssertEqual(mgr.resolvedDark, originalDark)
        XCTAssertNil(mgr.activeSchemeID)
    }

    func test_apply_darkOnly_keepsLight_andActiveIDNil() {
        let mgr = ThemeManager(resolvedLight: .defaultLight, resolvedDark: .defaultDark)
        let originalLight = mgr.resolvedLight
        let s = sampleScheme()
        mgr.apply(scheme: s, target: .darkOnly)
        XCTAssertEqual(mgr.resolvedDark, s.dark)
        XCTAssertEqual(mgr.resolvedLight, originalLight)
        XCTAssertNil(mgr.activeSchemeID)
    }
}
