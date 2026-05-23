//
//  BuiltinPresetBootstrapTests.swift
//  BeadInventoryTests
//

import XCTest
import SwiftData
@testable import BeadInventory

final class BuiltinPresetBootstrapTests: XCTestCase {

    private func makeInMemoryContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: SDColorScheme.self, configurations: config)
        return ModelContext(container)
    }

    private func sampleBuiltinJSON() -> Data {
        """
        {
          "version": 1,
          "schemes": [
            {"id": "B1A5B100-0000-0000-0000-000000000001",
             "name_key": "color_mode.preset.cream_latte",
             "light": {"bg": "FAF5EC", "bg_elev": "FFFDF8"},
             "dark":  {"bg": "1B1714", "bg_elev": "25201B"}}
          ]
        }
        """.data(using: .utf8)!
    }

    func test_bootstrap_freshDB_insertsAllPresets() throws {
        let suiteName = "Bootstrap-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let ctx = try makeInMemoryContext()
        let mgr = ThemeManager.test_make(defaults: defaults)
        try mgr.bootstrapBuiltinPresets(jsonData: sampleBuiltinJSON(), modelContext: ctx)

        let all = try ctx.fetch(FetchDescriptor<SDColorScheme>())
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id.uuidString, "B1A5B100-0000-0000-0000-000000000001")
        XCTAssertTrue(all.first?.isBuiltin ?? false)
        XCTAssertEqual(defaults.integer(forKey: "theme.builtinVersion"), 1)
    }

    func test_bootstrap_sameVersion_skips() throws {
        let suiteName = "Bootstrap-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(1, forKey: "theme.builtinVersion")
        let ctx = try makeInMemoryContext()
        let mgr = ThemeManager.test_make(defaults: defaults)
        try mgr.bootstrapBuiltinPresets(jsonData: sampleBuiltinJSON(), modelContext: ctx)
        let all = try ctx.fetch(FetchDescriptor<SDColorScheme>())
        XCTAssertEqual(all.count, 0)
    }

    func test_bootstrap_higherVersion_upserts() throws {
        let suiteName = "Bootstrap-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(0, forKey: "theme.builtinVersion")
        let ctx = try makeInMemoryContext()
        let oldID = UUID(uuidString: "B1A5B100-0000-0000-0000-000000000001")!
        ctx.insert(SDColorScheme(
            id: oldID, name: "OldName",
            lightBgHex: "000000", lightBgElevHex: "000000",
            darkBgHex: "000000", darkBgElevHex: "000000",
            isBuiltin: true
        ))
        try ctx.save()

        let mgr = ThemeManager.test_make(defaults: defaults)
        try mgr.bootstrapBuiltinPresets(jsonData: sampleBuiltinJSON(), modelContext: ctx)

        let all = try ctx.fetch(FetchDescriptor<SDColorScheme>())
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.lightBgHex, "FAF5EC")
        XCTAssertEqual(all.first?.name, "color_mode.preset.cream_latte")
    }
}
