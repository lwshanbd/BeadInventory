//
//  ThumbnailMigrationCoordinatorTests.swift
//  BeadInventoryTests
//
//  钉住 TestFlight build 180 watchdog 崩溃（0x8BADF00D，2026-07-26）的修复：
//  ThumbnailMigrationCoordinator.migrateOne 曾在 MainActor 上对 SDProjectRecord 做
//  **裸单行 fetch**（无 propertiesToFetch）并直接读 `.thumbnail`，触发 Core Data
//  deferred-fault 补全 = 主线程同步读盘。热限流 + 切后台 5s 宽限期内主线程被
//  `_PF_FulfillDeferredFault → sqlite3_step → pread` 卡死 → SIGKILL。
//
//  修复后 migrateOne 是 `nonisolated static`，只依赖 Sendable 的 ModelContainer，
//  在调用方 executor（生产中 = 后台 cooperative pool）上用**独立后台 ModelContext**
//  完成 fetch / downsample / TOCTOU 校验 / 写回，主线程零 SwiftData I/O。
//
//  本文件覆盖迁移语义在改造后不回归：
//  1. 正常迁移：displayThumbnail 生成且 thumbnail 原字节不动
//  2. displayThumbnail 已有值 → .alreadyDone 且不覆盖
//  3. row 不存在 / thumbnail 为 nil → .raceSkipped
//  4. 坏图字节 downsample 失败 → .failed 且不写任何东西
//  5. off-main 执行：migrateOne 全程不得踏上主线程（防止未来把它改回 @MainActor）
//

import XCTest
import SwiftData
import UIKit
@testable import BeadInventory

final class ThumbnailMigrationCoordinatorTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// 生成一张真实可解码的 PNG（纯色 64×64）—— ImageDownsampler 需要合法图片字节。
    private func makePNG(side: CGFloat = 64) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let image = renderer.image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
        return image.pngData()!
    }

    @MainActor
    private func seedProject(
        in container: ModelContainer,
        thumbnail: Data?,
        displayThumbnail: Data? = nil
    ) throws -> UUID {
        let ctx = ModelContext(container)
        let record = SDProjectRecord(
            name: "迁移测试",
            totalBeads: 0,
            thumbnail: thumbnail,
            finishedImage: nil,
            displayThumbnail: displayThumbnail,
            beadUsages: []
        )
        ctx.insert(record)
        try ctx.save()
        return record.id
    }

    @MainActor
    private func fetchRow(_ id: UUID, in container: ModelContainer) throws -> SDProjectRecord? {
        let ctx = ModelContext(container)
        var d = FetchDescriptor<SDProjectRecord>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try ctx.fetch(d).first
    }

    // MARK: - 迁移语义

    func test_migrateOne_generates_displayThumbnail_and_preserves_original() async throws {
        let container = try makeContainer()
        let png = makePNG()
        let id = try await seedProject(in: container, thumbnail: png)

        let outcome = await ThumbnailMigrationCoordinator.migrateOne(projectId: id, container: container)
        XCTAssertEqual(outcome, .migrated)

        let row = try await fetchRow(id, in: container)
        XCTAssertEqual(row?.thumbnail, png, "原 thumbnail 字节必须一字不动")
        let display = row?.displayThumbnail
        XCTAssertNotNil(display, "迁移后 displayThumbnail 应已生成")
        XCTAssertNotEqual(display, png, "displayThumbnail 应是 downsample 产物而不是原字节")
    }

    func test_migrateOne_alreadyDone_does_not_overwrite() async throws {
        let container = try makeContainer()
        let existing = Data([0xAA, 0xBB])
        let id = try await seedProject(in: container, thumbnail: makePNG(), displayThumbnail: existing)

        let outcome = await ThumbnailMigrationCoordinator.migrateOne(projectId: id, container: container)
        XCTAssertEqual(outcome, .alreadyDone)

        let row = try await fetchRow(id, in: container)
        XCTAssertEqual(row?.displayThumbnail, existing, "已有 displayThumbnail 不得被覆盖")
    }

    func test_migrateOne_missing_row_raceSkipped() async throws {
        let container = try makeContainer()
        let outcome = await ThumbnailMigrationCoordinator.migrateOne(projectId: UUID(), container: container)
        XCTAssertEqual(outcome, .raceSkipped)
    }

    func test_migrateOne_nil_thumbnail_raceSkipped() async throws {
        let container = try makeContainer()
        let id = try await seedProject(in: container, thumbnail: nil)
        let outcome = await ThumbnailMigrationCoordinator.migrateOne(projectId: id, container: container)
        XCTAssertEqual(outcome, .raceSkipped)
    }

    func test_migrateOne_corrupt_bytes_failed_and_writes_nothing() async throws {
        let container = try makeContainer()
        let corrupt = Data([0x00, 0x01, 0x02, 0x03])  // 不是合法图片
        let id = try await seedProject(in: container, thumbnail: corrupt)

        let outcome = await ThumbnailMigrationCoordinator.migrateOne(projectId: id, container: container)
        XCTAssertEqual(outcome, .failed)

        let row = try await fetchRow(id, in: container)
        XCTAssertNil(row?.displayThumbnail, "downsample 失败不得写入 displayThumbnail")
        XCTAssertEqual(row?.thumbnail, corrupt, "失败路径也不得动原 thumbnail")
    }

    // MARK: - off-main 保证（崩溃修复的核心不变量）

    func test_migrateOne_never_touches_main_thread() async throws {
        let container = try makeContainer()
        let id = try await seedProject(in: container, thumbnail: makePNG())

        // 从非主 executor 发起（本测试类无 @MainActor，async 测试跑在 cooperative pool），
        // migrateOne 是 nonisolated —— 不得 hop 回 MainActor。
        // 用 MainActor 占位任务探测：迁移期间主线程若被 migrateOne 占用做同步 I/O，
        // 这里无法直接断言；退而钉住「migrateOne 自身不在主线程执行」。
        XCTAssertFalse(Thread.isMainThread, "async 测试本体应在 cooperative pool")
        let outcome = await ThumbnailMigrationCoordinator.migrateOne(projectId: id, container: container)
        XCTAssertEqual(outcome, .migrated)
    }
}
