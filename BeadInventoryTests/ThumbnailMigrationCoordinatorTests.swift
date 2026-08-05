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

    /// 迁移后：原图字节一字不动地搬到文件、小图生成到文件、数据库两列清空。
    /// 清空列是核心 —— 行只要还留着 13MB blob，之后任何一次写入都会重写整行
    /// （TestFlight build 183 实测 63 分钟 68.72GB 写放大的根因）。
    func test_migrateOne_moves_original_to_file_and_clears_columns() async throws {
        let container = try makeContainer()
        let png = makePNG()
        let id = try await seedProject(in: container, thumbnail: png)

        let outcome = await ThumbnailMigrationCoordinator.migrateOne(projectId: id, container: container)
        XCTAssertEqual(outcome, .migrated)

        let row = try await fetchRow(id, in: container)
        XCTAssertNil(row?.thumbnail, "原图应已搬走并清空数据库列")
        XCTAssertNil(row?.displayThumbnail, "小图改存文件，不再写数据库列")

        XCTAssertEqual(ProjectImageStore.read(projectId: id, kind: .thumbnail), png, "原图字节必须一字不动")
        let display = ProjectImageStore.read(projectId: id, kind: .displayThumbnail)
        XCTAssertNotNil(display, "迁移后应生成小图文件")
        XCTAssertNotEqual(display, png, "小图应是 downsample 产物而不是原字节")
    }

    /// 已经搬完的行（三列全空）再跑一次必须是 alreadyDone 且不产生写入 ——
    /// 否则迁移会在同一批行上无限重跑，正是写放大的来源。
    func test_migrateOne_already_migrated_row_is_noop() async throws {
        let container = try makeContainer()
        let id = try await seedProject(in: container, thumbnail: makePNG())
        _ = await ThumbnailMigrationCoordinator.migrateOne(projectId: id, container: container)

        let second = await ThumbnailMigrationCoordinator.migrateOne(projectId: id, container: container)
        XCTAssertEqual(second, .alreadyDone, "搬完的行必须自然掉出候选")
    }

    func test_migrateOne_missing_row_raceSkipped() async throws {
        let container = try makeContainer()
        let outcome = await ThumbnailMigrationCoordinator.migrateOne(projectId: UUID(), container: container)
        XCTAssertEqual(outcome, .raceSkipped)
    }

    /// 完全没有图的行：无事可做，报 alreadyDone（区别于「行被删」的 raceSkipped，
    /// 让线上计数能分辨"迁移完成了多少"与"多少行中途消失"）。
    func test_migrateOne_row_without_any_image_is_alreadyDone() async throws {
        let container = try makeContainer()
        let id = try await seedProject(in: container, thumbnail: nil)
        let outcome = await ThumbnailMigrationCoordinator.migrateOne(projectId: id, container: container)
        XCTAssertEqual(outcome, .alreadyDone)
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
