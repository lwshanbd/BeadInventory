//
//  InventoryManagerBlobFetchTests.swift
//  BeadInventoryTests
//
//  覆盖 SwiftData blob 抗物化路径的两个回归点：
//  1. fetchProjectThumbnailData 单列投影（fetchLimit + propertiesToFetch = [\.thumbnail]）
//     后仍返回正确的 thumbnail 字节，未知 id 返回 nil。
//  2. saveData 的 SDProjectRecord 全表 fetch 加 metadata propertiesToFetch 后，
//     metadata 差分写回仍生效，且**不会**把同行的 blob 列清掉、beadUsages 关系不丢
//    （saveData 自 v2.0.x 起不写 blob 字段，本用例钉住"单列投影 + 部分物化对象写回"组合）。
//
//  双审（PR #55）后的加固：
//  - schema 用 App 同款 `Schema(versionedSchema: CurrentSchema.self)`，不再只注册单模型。
//  - 种子数据 / 被测 manager / 验证 fetch 各用**独立 ModelContext**：同一 context 里
//    fetch 会直接返回 registered 的全量物化实例，投影和写回都不会真正打到 store 层，
//    断言等于空转。分 context 才能复现「冷启动新 context + 部分物化写回」的真实场景。
//

import XCTest
import SwiftData
@testable import BeadInventory

@MainActor
final class InventoryManagerBlobFetchTests: XCTestCase {
    /// App 同款 schema 的内存容器。测试里所有 context 都从它派生。
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private let thumbBytes = Data([0x01, 0x02, 0x03, 0x04])
    private let finishedBytes = Data([0x0A, 0x0B])
    private let displayBytes = Data([0x0C])

    /// 用独立 context 播种一条项目记录，返回其 id。
    private func seedProject(
        in container: ModelContainer,
        name: String,
        totalBeads: Int = 0,
        thumbnail: Data? = nil,
        finishedImage: Data? = nil,
        displayThumbnail: Data? = nil,
        beadUsages: [SDBeadUsage] = []
    ) throws -> UUID {
        let seedCtx = ModelContext(container)
        let record = SDProjectRecord(
            name: name,
            totalBeads: totalBeads,
            thumbnail: thumbnail,
            finishedImage: finishedImage,
            displayThumbnail: displayThumbnail,
            beadUsages: beadUsages
        )
        seedCtx.insert(record)
        try seedCtx.save()
        return record.id
    }

    private func fetchProject(_ id: UUID, in container: ModelContainer) throws -> SDProjectRecord? {
        let verifyCtx = ModelContext(container)
        var descriptor = FetchDescriptor<SDProjectRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try verifyCtx.fetch(descriptor).first
    }

    // MARK: - 单 blob fetch

    func test_fetchProjectThumbnailData_returns_thumbnail_column_only_row() throws {
        let container = try makeContainer()
        let projectId = try seedProject(
            in: container,
            name: "带图项目",
            thumbnail: thumbBytes,
            finishedImage: finishedBytes,
            displayThumbnail: displayBytes
        )

        // manager 用全新 context：投影 fetch 必须真正打到 store 层，
        // 而不是拿播种 context 里 registered 的全量实例。
        let m = InventoryManager(modelContext: ModelContext(container))
        // 单列投影后仍取到正确 thumbnail（不是同行其它 blob 列的内容）
        XCTAssertEqual(m.fetchProjectThumbnailData(for: projectId), thumbBytes)
    }

    func test_fetchProjectThumbnailData_unknown_id_returns_nil() throws {
        let container = try makeContainer()
        _ = try seedProject(in: container, name: "其它项目", thumbnail: thumbBytes)

        let m = InventoryManager(modelContext: ModelContext(container))
        XCTAssertNil(m.fetchProjectThumbnailData(for: UUID()))
    }

    func test_fetchProjectThumbnailData_project_without_thumbnail_returns_nil() throws {
        let container = try makeContainer()
        let projectId = try seedProject(in: container, name: "无图项目", finishedImage: finishedBytes)

        let m = InventoryManager(modelContext: ModelContext(container))
        XCTAssertNil(m.fetchProjectThumbnailData(for: projectId))
    }

    // MARK: - saveData metadata 投影写回

    func test_saveData_metadata_projection_updates_metadata_and_preserves_blobs_and_usages() async throws {
        let container = try makeContainer()
        let projectId = try seedProject(
            in: container,
            name: "原名",
            totalBeads: 100,
            thumbnail: thumbBytes,
            finishedImage: finishedBytes,
            displayThumbnail: displayBytes,
            beadUsages: [SDBeadUsage(colorCode: "H01", quantity: 100, isDeducted: true)]
        )

        let m = InventoryManager(modelContext: ModelContext(container))
        m.performInitialLoadIfNeeded(reason: "unitTest")
        // 首次读取必须异步返回，给 SwiftUI 提交首帧和绘制 loading overlay 的机会。
        XCTAssertTrue(m.isInitialLoadInProgress)
        XCTAssertFalse(m.hasCompletedInitialLoad)

        // 确定性等待，不用轮询 sleep：`initialLoadTask` 是 `private(set)`，
        // 跟 `HistoryManager.loadTask` 同一约定。
        await m.initialLoadTask?.value
        XCTAssertTrue(m.hasCompletedInitialLoad, "后台 loadData 应成功完成")
        XCTAssertTrue(m.projectIDsWithThumbnail.contains(projectId))
        XCTAssertTrue(m.projectIDsWithFinishedImage.contains(projectId))

        guard let idx = m.projects.firstIndex(where: { $0.id == projectId }) else {
            return XCTFail("loadData 后应能在内存缓存中找到项目")
        }
        // metadata-only 加载：内存缓存不应持有 blob
        XCTAssertNil(m.projects[idx].thumbnail)
        XCTAssertEqual(m.projects[idx].beadUsage.count, 1, "beadUsages 关系应随 metadata 加载")

        m.projects[idx].name = "改名后"
        m.saveData()

        // 用第三个独立 context 验证 store 行：metadata 已更新、
        // 部分物化写回没有清掉 blob 列、beadUsages 关系未丢/未复制。
        guard let saved = try fetchProject(projectId, in: container) else {
            return XCTFail("保存后项目应仍在持久层")
        }
        XCTAssertEqual(saved.name, "改名后")
        XCTAssertEqual(saved.totalBeads, 100)
        XCTAssertEqual(saved.thumbnail, thumbBytes)
        XCTAssertEqual(saved.finishedImage, finishedBytes)
        XCTAssertEqual(saved.displayThumbnail, displayBytes)
        let savedUsages = saved.beadUsages ?? []
        XCTAssertEqual(savedUsages.count, 1, "beadUsages 关系应原样保留（不丢、不重复）")
        XCTAssertEqual(savedUsages.first?.colorCode, "H01")
        XCTAssertEqual(savedUsages.first?.quantity, 100)
    }
}
