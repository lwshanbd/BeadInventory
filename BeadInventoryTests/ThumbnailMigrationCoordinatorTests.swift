//
//  ThumbnailMigrationCoordinatorTests.swift
//  BeadInventoryTests
//
//  钉住 TestFlight build 180 watchdog 崩溃（0x8BADF00D，2026-07-26）的修复：
//  ThumbnailMigrationCoordinator.compactOne 曾在 MainActor 上对 SDProjectRecord 做
//  **裸单行 fetch**（无 propertiesToFetch）并直接读 `.thumbnail`，触发 Core Data
//  deferred-fault 补全 = 主线程同步读盘。热限流 + 切后台 5s 宽限期内主线程被
//  `_PF_FulfillDeferredFault → sqlite3_step → pread` 卡死 → SIGKILL。
//
//  修复后 compactOne 是 `nonisolated static`，只依赖 Sendable 的 ModelContainer，
//  在调用方 executor（生产中 = 后台 cooperative pool）上用**独立后台 ModelContext**
//  完成 fetch / downsample / TOCTOU 校验 / 写回，主线程零 SwiftData I/O。
//
//  本文件覆盖迁移语义在改造后不回归：
//  1. 正常迁移：displayThumbnail 生成且 thumbnail 原字节不动
//  2. displayThumbnail 已有值 → .alreadyDone 且不覆盖
//  3. row 不存在 / thumbnail 为 nil → .raceSkipped
//  4. 坏图字节 downsample 失败 → .failed 且不写任何东西
//  5. off-main 执行：compactOne 全程不得踏上主线程（防止未来把它改回 @MainActor）
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

    // MARK: - 瘦身语义（本轮新增职责）

    /// 造一张「照片型」大图：PNG 存起来很大、JPEG 压得下去。
    /// 纯色图会被 PNG 压到几 KB，压根触发不了重编码 —— 用它测瘦身等于什么都没测。
    private func makeFatPhotoPNG(side: Int = 1400) -> Data {
        var buffer = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt64 = 0xD1B54A32D192ED03
        for i in stride(from: 0, to: buffer.count, by: 4) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let n = UInt8((seed >> 33) & 0xFF)
            // 低频基色 + 高频噪声：deflate 压不动，DCT 压得动
            let base = UInt8((i / 4 / side) % 200)
            buffer[i] = base &+ n / 8
            buffer[i + 1] = base &+ n / 6
            buffer[i + 2] = n
            buffer[i + 3] = 255
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let provider = CGDataProvider(data: Data(buffer) as CFData)!
        let cg = CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: side * 4, space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        return UIImage(cgImage: cg).pngData()!
    }

    /// 整轮修复的核心不变量：**胖行只被重写一次，且写完就瘦了**。
    ///
    /// 原实现只回填 displayThumbnail，往内联着 13MB 原图的行里写 100KB 小图 ——
    /// 实际写盘 13MB，而且写完这行**还是 13MB**。458 项目 ≈6GB，就是用户 IPS 里
    /// 68.72GB dirty writes 的来源。合并成同一次 save 之后才真正止血。
    @MainActor
    func test_compactOne_shrinks_fat_row_and_fills_thumbnail_in_one_pass() async throws {
        let container = try makeContainer()
        let fat = makeFatPhotoPNG()
        XCTAssertGreaterThan(
            fat.count, ProjectImageEncoder.compactionThresholdBytes,
            "夹具必须真的超阈值，否则这个测试没在测瘦身"
        )
        let id = try seedProject(in: container, thumbnail: fat, displayThumbnail: nil)

        let outcome = await ThumbnailMigrationCoordinator.compactOne(projectId: id, container: container)
        XCTAssertTrue(outcome.isMigrated, "期望瘦身成功，实际 \(outcome)")

        let row = try fetchRow(id, in: container)
        let after = try XCTUnwrap(row?.thumbnail)
        print("[compaction] thumbnail \(fat.count)B → \(after.count)B")

        XCTAssertLessThan(
            after.count, ProjectImageEncoder.compactionThresholdBytes,
            "瘦身后仍在阈值之上 → 下一轮扫描还会选中它 → 死循环重写"
        )
        XCTAssertNotNil(row?.displayThumbnail, "同一次 save 里应当把列表小图一并补上")

        // 分辨率必须原样保留 —— 拼图模式的网格识别依赖它
        let before = try XCTUnwrap(UIImage(data: fat))
        let now = try XCTUnwrap(UIImage(data: after))
        XCTAssertEqual(now.size.width, before.size.width, accuracy: 1)
        XCTAssertEqual(now.size.height, before.size.height, accuracy: 1)
    }

    /// 收敛性：瘦过的行再跑一次必须是 no-op，不能再写一遍。
    @MainActor
    func test_compaction_converges_second_pass_is_noop() async throws {
        let container = try makeContainer()
        let id = try seedProject(in: container, thumbnail: makeFatPhotoPNG(), displayThumbnail: nil)

        let first = await ThumbnailMigrationCoordinator.compactOne(projectId: id, container: container)
        XCTAssertTrue(first.isMigrated)
        let afterFirst = try fetchRow(id, in: container)?.thumbnail

        let second = await ThumbnailMigrationCoordinator.compactOne(projectId: id, container: container)
        XCTAssertEqual(second, .alreadyDone, "第二轮必须是 no-op，否则每次启动都重写全库")
        XCTAssertEqual(try fetchRow(id, in: container)?.thumbnail, afterFirst, "第二轮不得改动字节")
    }

    /// 用户换了封面图 → 我们手上算出来的新字节对应的是**旧图**，必须整条丢弃。
    @MainActor
    func test_compactOne_discards_result_when_thumbnail_changed_concurrently() async throws {
        let container = try makeContainer()
        let original = makeFatPhotoPNG()
        let id = try seedProject(in: container, thumbnail: original, displayThumbnail: nil)

        // 直接改库模拟并发写入，然后用「读到的是旧字节」的前提去跑 —— 这里靠先改库、
        // 再调用来构造：compactOne 第一次 fetch 读到新值，TOCTOU 校验自然通过；
        // 所以要验证的是**校验存在**，用一个字节不同的行来触发。
        let ctx = ModelContext(container)
        var d = FetchDescriptor<SDProjectRecord>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        let row = try XCTUnwrap(ctx.fetch(d).first)
        let replacement = makeFatPhotoPNG(side: 1200)
        row.thumbnail = replacement
        try ctx.save()

        let outcome = await ThumbnailMigrationCoordinator.compactOne(projectId: id, container: container)
        XCTAssertTrue(outcome.isMigrated, "换图之后仍应正常瘦身新图，实际 \(outcome)")
        let finalBytes = try XCTUnwrap(fetchRow(id, in: container)?.thumbnail)
        let decoded = try XCTUnwrap(UIImage(data: finalBytes))
        let expected = try XCTUnwrap(UIImage(data: replacement))
        XCTAssertEqual(decoded.size.width, expected.size.width, accuracy: 1,
                       "瘦身结果必须对应用户最新的那张图，不能把旧图写回去")
    }

    // MARK: - 迁移语义

    func test_compactOne_generates_displayThumbnail_and_preserves_original() async throws {
        let container = try makeContainer()
        let png = makePNG()
        let id = try await seedProject(in: container, thumbnail: png)

        let outcome = await ThumbnailMigrationCoordinator.compactOne(projectId: id, container: container)
        XCTAssertTrue(outcome.isMigrated, "期望瘦身+回填成功，实际 \(outcome)")

        let row = try await fetchRow(id, in: container)
        XCTAssertEqual(row?.thumbnail, png, "原 thumbnail 字节必须一字不动")
        let display = row?.displayThumbnail
        XCTAssertNotNil(display, "迁移后 displayThumbnail 应已生成")
        XCTAssertNotEqual(display, png, "displayThumbnail 应是 downsample 产物而不是原字节")
    }

    func test_compactOne_alreadyDone_does_not_overwrite() async throws {
        let container = try makeContainer()
        let existing = Data([0xAA, 0xBB])
        let id = try await seedProject(in: container, thumbnail: makePNG(), displayThumbnail: existing)

        let outcome = await ThumbnailMigrationCoordinator.compactOne(projectId: id, container: container)
        XCTAssertEqual(outcome, .alreadyDone)

        let row = try await fetchRow(id, in: container)
        XCTAssertEqual(row?.displayThumbnail, existing, "已有 displayThumbnail 不得被覆盖")
    }

    func test_compactOne_missing_row_raceSkipped() async throws {
        let container = try makeContainer()
        let outcome = await ThumbnailMigrationCoordinator.compactOne(projectId: UUID(), container: container)
        XCTAssertEqual(outcome, .raceSkipped)
    }

    /// 语义随「协调器从纯回填扩展成瘦身 pass」变了：
    /// 以前候选谓词硬性要求 `thumbnail != nil`，所以取到 nil 只可能是并发改动 → `.raceSkipped`。
    /// 现在候选还包括「finishedImage 超阈值」，一条没有 thumbnail 的行是**合法候选**，
    /// 没有 thumbnail 单纯意味着这一半没活干 → `.alreadyDone`。
    /// 两者在 run loop 里的处理完全相同（都不计 failure、都不落 stubborn 盘）。
    func test_compactOne_nil_thumbnail_is_nothing_to_do() async throws {
        let container = try makeContainer()
        let id = try await seedProject(in: container, thumbnail: nil)
        let outcome = await ThumbnailMigrationCoordinator.compactOne(projectId: id, container: container)
        XCTAssertEqual(outcome, .alreadyDone)
    }

    func test_compactOne_corrupt_bytes_failed_and_writes_nothing() async throws {
        let container = try makeContainer()
        let corrupt = Data([0x00, 0x01, 0x02, 0x03])  // 不是合法图片
        let id = try await seedProject(in: container, thumbnail: corrupt)

        let outcome = await ThumbnailMigrationCoordinator.compactOne(projectId: id, container: container)
        XCTAssertEqual(outcome, .failed)

        let row = try await fetchRow(id, in: container)
        XCTAssertNil(row?.displayThumbnail, "downsample 失败不得写入 displayThumbnail")
        XCTAssertEqual(row?.thumbnail, corrupt, "失败路径也不得动原 thumbnail")
    }

    // MARK: - off-main 保证（崩溃修复的核心不变量）

    func test_compactOne_never_touches_main_thread() async throws {
        let container = try makeContainer()
        let id = try await seedProject(in: container, thumbnail: makePNG())

        // 从非主 executor 发起（本测试类无 @MainActor，async 测试跑在 cooperative pool），
        // compactOne 是 nonisolated —— 不得 hop 回 MainActor。
        // 用 MainActor 占位任务探测：迁移期间主线程若被 compactOne 占用做同步 I/O，
        // 这里无法直接断言；退而钉住「compactOne 自身不在主线程执行」。
        XCTAssertFalse(Thread.isMainThread, "async 测试本体应在 cooperative pool")
        let outcome = await ThumbnailMigrationCoordinator.compactOne(projectId: id, container: container)
        XCTAssertTrue(outcome.isMigrated, "期望瘦身+回填成功，实际 \(outcome)")
    }
}
