//
//  ColorSchemeSyncTests.swift
//  BeadInventoryTests
//
//  SDColorScheme CloudKit 同步路径烟雾测试。
//  SDColorScheme 已注册在 CurrentSchema.models 中，容器使用 cloudKitDatabase: .automatic，
//  SwiftData 会自动处理跨设备同步，无需 InventoryManager 中的额外差量合并代码。
//

import XCTest
import SwiftData
@testable import BeadInventory

final class ColorSchemeSyncTests: XCTestCase {

    // MARK: - Helpers

    private func makeInMemoryContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: SDColorScheme.self, configurations: config)
        return ModelContext(container)
    }

    // MARK: - Tests

    /// 验证 SDColorScheme 能正确写入并从同一 context 中再读出（持久化层基本回路）
    func test_sdColorScheme_persistsAndReloads() throws {
        let ctx = try makeInMemoryContext()

        let id = UUID()
        ctx.insert(SDColorScheme(
            id: id,
            name: "test",
            lightBgHex: "AAAAAA",
            lightBgElevHex: "BBBBBB",
            darkBgHex: "111111",
            darkBgElevHex: "222222",
            isBuiltin: false
        ))
        try ctx.save()

        let fetched = try ctx.fetch(
            FetchDescriptor<SDColorScheme>(predicate: #Predicate { $0.id == id })
        )
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.name, "test")
        XCTAssertEqual(fetched.first?.lightBgHex, "AAAAAA")
        XCTAssertEqual(fetched.first?.lightBgElevHex, "BBBBBB")
        XCTAssertEqual(fetched.first?.darkBgHex, "111111")
        XCTAssertEqual(fetched.first?.darkBgElevHex, "222222")
        XCTAssertFalse(fetched.first?.isBuiltin ?? true)
    }

    /// 验证 isBuiltin=true 的内置预设能被正确持久化（bootstrap 路径保护）
    func test_sdColorScheme_builtin_persistsAndReloads() throws {
        let ctx = try makeInMemoryContext()

        let builtinID = UUID(uuidString: "B1A5B100-0000-0000-0000-000000000001")!
        ctx.insert(SDColorScheme(
            id: builtinID,
            name: "color_mode.preset.cream_latte",
            lightBgHex: "FAF5EC",
            lightBgElevHex: "FFFDF8",
            darkBgHex: "1B1714",
            darkBgElevHex: "25201B",
            isBuiltin: true
        ))
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<SDColorScheme>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertTrue(fetched.first?.isBuiltin ?? false)
        XCTAssertEqual(fetched.first?.id, builtinID)
        XCTAssertEqual(fetched.first?.lightBgHex, "FAF5EC")
    }

    /// 验证 updatedAt 字段存储正确（冲突解决用途）
    func test_sdColorScheme_updatedAt_roundTrips() throws {
        let ctx = try makeInMemoryContext()

        let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
        let id = UUID()
        ctx.insert(SDColorScheme(
            id: id,
            name: "timestamped",
            lightBgHex: "CCCCCC",
            lightBgElevHex: "DDDDDD",
            darkBgHex: "333333",
            darkBgElevHex: "444444",
            isBuiltin: false,
            createdAt: referenceDate,
            updatedAt: referenceDate
        ))
        try ctx.save()

        let fetched = try ctx.fetch(
            FetchDescriptor<SDColorScheme>(predicate: #Predicate { $0.id == id })
        )
        let fetchedDate = try XCTUnwrap(fetched.first).updatedAt
        XCTAssertEqual(fetchedDate.timeIntervalSince1970,
                       referenceDate.timeIntervalSince1970,
                       accuracy: 1.0)
    }
}
