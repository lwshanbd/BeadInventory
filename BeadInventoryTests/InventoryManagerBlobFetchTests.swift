//
//  InventoryManagerBlobFetchTests.swift
//  BeadInventoryTests
//
//  覆盖 SwiftData blob 抗物化路径的两个回归点：
//  1. fetchProjectThumbnailData 单列投影（fetchLimit + propertiesToFetch = [\.thumbnail]）
//     后仍返回正确的 thumbnail 字节，未知 id 返回 nil。
//  2. saveData 的 SDProjectRecord 全表 fetch 加 metadata propertiesToFetch 后，
//     metadata 差分写回仍生效，且**不会**把同行的 blob 列清掉（saveData 自 v2.0.x
//     起不写 blob 字段，本用例钉住"单列投影 + 部分物化对象写回"组合的正确性）。
//

import XCTest
import SwiftData
@testable import BeadInventory

@MainActor
final class InventoryManagerBlobFetchTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: SDProjectRecord.self, configurations: config)
        return ModelContext(container)
    }

    private let thumbBytes = Data([0x01, 0x02, 0x03, 0x04])
    private let finishedBytes = Data([0x0A, 0x0B])
    private let displayBytes = Data([0x0C])

    // MARK: - 单 blob fetch

    func test_fetchProjectThumbnailData_returns_thumbnail_column_only_row() throws {
        let ctx = try makeContext()
        let record = SDProjectRecord(
            name: "带图项目",
            thumbnail: thumbBytes,
            finishedImage: finishedBytes,
            displayThumbnail: displayBytes
        )
        ctx.insert(record)
        try ctx.save()

        let m = InventoryManager(modelContext: ctx)
        // 单列投影后仍取到正确 thumbnail（不是同行其它 blob 列的内容）
        XCTAssertEqual(m.fetchProjectThumbnailData(for: record.id), thumbBytes)
    }

    func test_fetchProjectThumbnailData_unknown_id_returns_nil() throws {
        let ctx = try makeContext()
        ctx.insert(SDProjectRecord(name: "其它项目", thumbnail: thumbBytes))
        try ctx.save()

        let m = InventoryManager(modelContext: ctx)
        XCTAssertNil(m.fetchProjectThumbnailData(for: UUID()))
    }

    func test_fetchProjectThumbnailData_project_without_thumbnail_returns_nil() throws {
        let ctx = try makeContext()
        let record = SDProjectRecord(name: "无图项目", finishedImage: finishedBytes)
        ctx.insert(record)
        try ctx.save()

        let m = InventoryManager(modelContext: ctx)
        XCTAssertNil(m.fetchProjectThumbnailData(for: record.id))
    }

    // MARK: - saveData metadata 投影写回

    func test_saveData_metadata_projection_updates_metadata_and_preserves_blobs() throws {
        let ctx = try makeContext()
        let record = SDProjectRecord(
            name: "原名",
            totalBeads: 100,
            thumbnail: thumbBytes,
            finishedImage: finishedBytes,
            displayThumbnail: displayBytes
        )
        ctx.insert(record)
        try ctx.save()
        let projectId = record.id

        let m = InventoryManager(modelContext: ctx)
        m.performInitialLoadIfNeeded(reason: "unitTest")
        XCTAssertTrue(m.hasCompletedInitialLoad, "loadData 应成功完成")

        guard let idx = m.projects.firstIndex(where: { $0.id == projectId }) else {
            return XCTFail("loadData 后应能在内存缓存中找到项目")
        }
        // metadata-only 加载：内存缓存不应持有 blob
        XCTAssertNil(m.projects[idx].thumbnail)

        m.projects[idx].name = "改名后"
        m.saveData()

        // 全行重新取出验证：metadata 已更新、blob 列未被部分物化写回破坏
        var descriptor = FetchDescriptor<SDProjectRecord>(
            predicate: #Predicate { $0.id == projectId }
        )
        descriptor.fetchLimit = 1
        guard let saved = try ctx.fetch(descriptor).first else {
            return XCTFail("保存后项目应仍在持久层")
        }
        XCTAssertEqual(saved.name, "改名后")
        XCTAssertEqual(saved.totalBeads, 100)
        XCTAssertEqual(saved.thumbnail, thumbBytes)
        XCTAssertEqual(saved.finishedImage, finishedBytes)
        XCTAssertEqual(saved.displayThumbnail, displayBytes)
    }
}
