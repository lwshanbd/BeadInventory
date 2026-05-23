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

    func test_updateSwatch_lightBg_changesLightBgAndClearsActiveID() {
        let mgr = ThemeManager(activeSchemeID: UUID(),
                               resolvedLight: .defaultLight,
                               resolvedDark: .defaultDark)
        mgr.updateSwatch(.lightBg, hex: "112233")
        XCTAssertEqual(mgr.resolvedLight.bg, "112233")
        XCTAssertEqual(mgr.resolvedLight.bgElev, ColorPalette.defaultLight.bgElev)
        XCTAssertEqual(mgr.resolvedDark, .defaultDark)
        XCTAssertNil(mgr.activeSchemeID)
    }

    func test_updateSwatch_darkElev_changesOnlyThat() {
        let mgr = ThemeManager(activeSchemeID: UUID(),
                               resolvedLight: .defaultLight,
                               resolvedDark: .defaultDark)
        mgr.updateSwatch(.darkElev, hex: "ABCDEF")
        XCTAssertEqual(mgr.resolvedDark.bgElev, "ABCDEF")
        XCTAssertEqual(mgr.resolvedDark.bg, ColorPalette.defaultDark.bg)
        XCTAssertNil(mgr.activeSchemeID)
    }

    func test_beginDraft_thenUpdate_thenDiscard_restoresSnapshot() {
        let originalID = UUID()
        let mgr = ThemeManager(activeSchemeID: originalID,
                               resolvedLight: .defaultLight,
                               resolvedDark: .defaultDark)
        mgr.beginDraft()
        mgr.updateSwatch(.lightBg, hex: "FF0000")
        XCTAssertTrue(mgr.isDirty)
        XCTAssertNil(mgr.activeSchemeID)
        XCTAssertEqual(mgr.resolvedLight.bg, "FF0000")

        mgr.discardDraft()
        XCTAssertEqual(mgr.resolvedLight, .defaultLight)
        XCTAssertEqual(mgr.activeSchemeID, originalID)
        XCTAssertNil(mgr.draft)
        XCTAssertFalse(mgr.isDirty)
    }

    func test_beginDraft_thenApplyFullPreset_marksClean() {
        let mgr = ThemeManager(activeSchemeID: nil,
                               resolvedLight: .defaultLight,
                               resolvedDark: .defaultDark)
        mgr.beginDraft()
        mgr.updateSwatch(.lightBg, hex: "FF0000")
        XCTAssertTrue(mgr.isDirty)

        let preset = sampleScheme()
        mgr.apply(scheme: preset, target: .both)
        XCTAssertFalse(mgr.isDirty)   // 完整应用预设 = 干净
    }

    func test_commitAsNewScheme_producesSchemeWithCurrentColors() throws {
        let mgr = ThemeManager(activeSchemeID: nil,
                               resolvedLight: ColorPalette(bg: "AAAAAA", bgElev: "BBBBBB"),
                               resolvedDark:  ColorPalette(bg: "111111", bgElev: "222222"))
        mgr.beginDraft()
        let scheme = try mgr.commitAsNewScheme(name: "我的咖啡")
        XCTAssertEqual(scheme.name, "我的咖啡")
        XCTAssertEqual(scheme.light, ColorPalette(bg: "AAAAAA", bgElev: "BBBBBB"))
        XCTAssertEqual(scheme.dark,  ColorPalette(bg: "111111", bgElev: "222222"))
        XCTAssertFalse(scheme.isBuiltin)
        XCTAssertEqual(mgr.activeSchemeID, scheme.id)
        XCTAssertNil(mgr.draft)
    }
}
