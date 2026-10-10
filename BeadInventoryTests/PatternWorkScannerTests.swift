//
//  PatternWorkScannerTests.swift
//  BeadInventoryTests
//
//  工作台「拼图」页靠 `ProjectBlobExistenceScanner.scanPatternWork` 找出哪些项目做过拼图。
//  它查的两列是手写的 SQLite 列名，写错了扫描就返回 `.unsupportedStore`，
//  拼图页会一直空着、什么也不报 —— 所以钉一条：两列都认得，ID 分进对的那一组。
//

import XCTest
import SwiftData
@testable import BeadInventory

final class PatternWorkScannerTests: XCTestCase {
    private var storeDir: URL!

    override func setUpWithError() throws {
        storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pattern-work-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storeDir)
    }

    func test_scanPatternWork_splits_grid_and_parts_projects() throws {
        let storeURL = storeDir.appendingPathComponent("scan.store")
        let config = ModelConfiguration(url: storeURL, cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: SDBrand.self, SDBrandStock.self, SDProjectRecord.self,
            SDBeadUsage.self, SDCustomColor.self, SDHistoryRecord.self, SDColorScheme.self,
            configurations: config
        )
        let ctx = ModelContext(container)

        let gridOnly = SDProjectRecord(name: "单图纸", patternGridData: Data([1]))
        let partsOnly = SDProjectRecord(name: "多零件")
        partsOnly.partsSheetData = Data([2])
        let both = SDProjectRecord(name: "两种都做过", patternGridData: Data([3]))
        both.partsSheetData = Data([4])
        let neither = SDProjectRecord(name: "没进过拼图模式")
        [gridOnly, partsOnly, both, neither].forEach(ctx.insert)
        try ctx.save()

        guard case .success(let ids) = ProjectBlobExistenceScanner.scanPatternWork(storeURL: storeURL) else {
            return XCTFail("scanPatternWork 没认出这两列")
        }
        XCTAssertEqual(ids.grid, [gridOnly.id, both.id])
        XCTAssertEqual(ids.parts, [partsOnly.id, both.id])
    }
}
