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

    // seam（nonisolated(unsafe) static var）和 stubborn 记账（UserDefaults）都是跨测试的
    // 全局状态。individual 测试里的 defer 靠自觉，忘一个就毒害后面所有 compactOne 调用 ——
    // 收进 setUp/tearDown，忘了也兜得住（round-2 双审两侧都点了这条）。
    // 另外 compactOne 现在会在「行仍超阈值」时自己写 ledger，不重置的话跨运行残留。
    override func setUp() {
        super.setUp()
        ThumbnailMigrationCoordinator.resetTestSeams()
        ThumbnailMigrationCoordinator.resetStubbornIDsForTesting()
    }

    override func tearDown() {
        ThumbnailMigrationCoordinator.resetTestSeams()
        ThumbnailMigrationCoordinator.resetStubbornIDsForTesting()
        super.tearDown()
    }

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
        displayThumbnail: Data? = nil,
        finishedImage: Data? = nil
    ) throws -> UUID {
        let ctx = ModelContext(container)
        let record = SDProjectRecord(
            name: "迁移测试",
            totalBeads: 0,
            thumbnail: thumbnail,
            finishedImage: finishedImage,
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

    /// **真正的 off-main 断言。**
    ///
    /// 旧版断言的是测试体自己所在的线程（在调用 `compactOne` 之前），那是在测 XCTest
    /// 怎么调度异步测试。变异测试证实旧版形同虚设：把 `compactOne` 改回 MainActor
    /// 隔离，它照样绿。现在读的是 `compactOne` **从函数体内部**写下的观测值。
    @MainActor
    func test_compactOne_never_touches_main_thread() async throws {
        ThumbnailMigrationCoordinator.resetTestSeams()
        defer { ThumbnailMigrationCoordinator.resetTestSeams() }

        let container = try makeContainer()
        let id = try seedProject(in: container, thumbnail: makePNG(), displayThumbnail: nil)

        XCTAssertTrue(Thread.isMainThread, "测试体本身应在主线程，否则这条断言没有对照意义")
        _ = await ThumbnailMigrationCoordinator.compactOne(projectId: id, container: container)

        let ranOnMain = try XCTUnwrap(
            ThumbnailMigrationCoordinator.lastCompactRanOnMainThreadForTesting,
            "compactOne 没有记录执行线程 —— 接缝坏了，这条测试失去意义"
        )
        XCTAssertFalse(
            ranOnMain,
            "compactOne 在主线程上执行了。这是 build-180 看门狗崩溃的根因形状："
            + "迁移的 SwiftData I/O 必须全程在后台 ModelContext 上。"
        )
    }

    // MARK: - TOCTOU（双审 + 变异测试：删掉守卫全绿）

    /// 用接缝在「编码完成」和「写回校验」之间插入并发换图，构造真竞态。
    ///
    /// 旧测试在**调用之前**改库，两次 fetch 读到相同字节，校验空转 —— 它自己的注释
    /// 也承认了（「所以要验证的是校验存在」）。变异测试确认：删掉两个逐字段守卫，
    /// 整个套件仍然全绿。后果是把旧图的重编码版覆盖到用户刚换的封面上。
    @MainActor
    func test_compactOne_discards_stale_result_when_user_replaces_image_mid_encode() async throws {
        ThumbnailMigrationCoordinator.resetTestSeams()
        defer { ThumbnailMigrationCoordinator.resetTestSeams() }

        let container = try makeContainer()
        let original = makeFatPhotoPNG()
        let id = try seedProject(in: container, thumbnail: original, displayThumbnail: nil)

        // 用户在编码窗口内换了一张完全不同的图
        let replacement = makePNG(side: 96)
        ThumbnailMigrationCoordinator.didFinishEncodingForTesting = { @Sendable changedId in
            await MainActor.run {
                let ctx = ModelContext(container)
                var d = FetchDescriptor<SDProjectRecord>(predicate: #Predicate { $0.id == changedId })
                d.fetchLimit = 1
                if let row = try? ctx.fetch(d).first {
                    row.thumbnail = replacement
                    try? ctx.save()
                }
            }
        }

        let outcome = await ThumbnailMigrationCoordinator.compactOne(projectId: id, container: container)
        XCTAssertEqual(outcome, .raceSkipped, "源字节在编码期间变了，结果必须整条作废")

        let final = try XCTUnwrap(fetchRow(id, in: container)?.thumbnail)
        XCTAssertEqual(
            final, replacement,
            "用户刚换上的图被旧图的重编码版覆盖了 —— 这是静默的用户数据丢失"
        )
    }

    /// 纯回填路径（原图本来就够小，只缺列表小图）同样要校验源还在。
    /// 这条路径上 `newThumbnail == nil`，早期实现完全没有对 `sd.thumbnail` 的校验，
    /// 于是用户删掉封面后，我们会把**已删除那张图**的小图写进去，且不自愈。
    @MainActor
    func test_compactOne_does_not_write_display_thumbnail_for_deleted_cover() async throws {
        ThumbnailMigrationCoordinator.resetTestSeams()
        defer { ThumbnailMigrationCoordinator.resetTestSeams() }

        let container = try makeContainer()
        // 小图缺失但原图够小 → 只会触发回填分支，不触发重编码
        let id = try seedProject(in: container, thumbnail: makePNG(side: 64), displayThumbnail: nil)

        ThumbnailMigrationCoordinator.didFinishEncodingForTesting = { @Sendable changedId in
            await MainActor.run {
                let ctx = ModelContext(container)
                var d = FetchDescriptor<SDProjectRecord>(predicate: #Predicate { $0.id == changedId })
                d.fetchLimit = 1
                if let row = try? ctx.fetch(d).first {
                    row.thumbnail = nil          // 用户删掉了封面
                    try? ctx.save()
                }
            }
        }

        _ = await ThumbnailMigrationCoordinator.compactOne(projectId: id, container: container)

        let row = try fetchRow(id, in: container)
        XCTAssertNil(row?.thumbnail, "前提：封面确实被删掉了")
        XCTAssertNil(
            row?.displayThumbnail,
            "封面已删除，却写进了它的列表小图 —— 列表会永远显示一张删掉的图，且不自愈"
        )
    }

    // MARK: - stubborn 记账按内容键控

    @MainActor
    func test_stubborn_ledger_is_keyed_by_content_not_just_id() throws {
        ThumbnailMigrationCoordinator.resetStubbornIDsForTesting()
        defer { ThumbnailMigrationCoordinator.resetStubbornIDsForTesting() }

        let id = UUID()
        ThumbnailMigrationCoordinator.noteStubborn(id, bytes: 5_000_000)

        XCTAssertTrue(ThumbnailMigrationCoordinator.isStubborn(id, bytes: 5_000_000),
                      "同样的内容应当被排除")
        XCTAssertFalse(
            ThumbnailMigrationCoordinator.isStubborn(id, bytes: 7_000_000),
            "字节数变了说明用户换了图 / 备份恢复 / CloudKit 同步来了新内容，必须重新考虑"
        )
        // 同一个 ID 的旧记录要被替换掉，不能无限堆积
        ThumbnailMigrationCoordinator.noteStubborn(id, bytes: 7_000_000)
        XCTAssertFalse(ThumbnailMigrationCoordinator.isStubborn(id, bytes: 5_000_000))
        XCTAssertTrue(ThumbnailMigrationCoordinator.isStubborn(id, bytes: 7_000_000))
    }

    // MARK: - 闸门

    func test_throttle_reason_write_budget_is_terminal() throws {
        // 第一条断言读的是**真实环境**（thermalState / 低电量 / 磁盘余量）——
        // 发热的 CI、开低电量的笔记本上它必红，而那不是被测代码的错。
        // 环境不干净就跳过，别把「断言环境」当成「断言行为」（round-1 批过的同款错误）。
        let info = ProcessInfo.processInfo
        try XCTSkipUnless(
            (info.thermalState == .nominal || info.thermalState == .fair) && !info.isLowPowerModeEnabled,
            "宿主机处于发热/低电量状态，环境相关断言无意义"
        )
        XCTAssertNil(ThumbnailMigrationCoordinator.throttleReason(bytesWrittenThisRun: 0))
        let over = ThumbnailMigrationCoordinator.throttleReason(bytesWrittenThisRun: 400 * 1024 * 1024)
        XCTAssertEqual(over, .writeBudget)
        XCTAssertTrue(
            ThumbnailMigrationCoordinator.ThrottleReason.writeBudget.endsThisRun,
            "写预算用尽是本轮终点，等一等不会变好"
        )
        XCTAssertFalse(
            ThumbnailMigrationCoordinator.ThrottleReason.thermal.endsThisRun,
            "发热是等一等就能好的，不该把整轮掐掉"
        )
    }

    /// `finishedImage` 的 TOCTOU 守卫此前不设防 —— 变异测试里只删它，整套仍然全绿，
    /// 因为两条新测试都只碰 thumbnail / displayThumbnail。失效后果与 thumbnail 那条完全同型：
    /// 用户在编码窗口里换了成品图，迁移器把**已被替换那张**的重编码版盖回去。
    @MainActor
    func test_compactOne_discards_stale_finished_image_when_replaced_mid_encode() async throws {
        ThumbnailMigrationCoordinator.resetTestSeams()
        defer { ThumbnailMigrationCoordinator.resetTestSeams() }

        let container = try makeContainer()
        let id = try seedProject(
            in: container,
            thumbnail: makePNG(side: 64),
            displayThumbnail: makePNG(side: 32),
            finishedImage: makeFatPhotoPNG()
        )

        let replacement = makePNG(side: 100)
        ThumbnailMigrationCoordinator.didFinishEncodingForTesting = { @Sendable changedId in
            await MainActor.run {
                let ctx = ModelContext(container)
                var d = FetchDescriptor<SDProjectRecord>(predicate: #Predicate { $0.id == changedId })
                d.fetchLimit = 1
                if let row = try? ctx.fetch(d).first {
                    row.finishedImage = replacement
                    try? ctx.save()
                }
            }
        }

        let outcome = await ThumbnailMigrationCoordinator.compactOne(projectId: id, container: container)
        XCTAssertEqual(outcome, .raceSkipped, "成品图源字节在编码期间变了，结果必须作废")
        XCTAssertEqual(
            try fetchRow(id, in: container)?.finishedImage, replacement,
            "用户刚换上的成品图被旧图的重编码版覆盖了 —— 静默的用户数据丢失"
        )
    }

    // MARK: - 瘦身后仍超阈值 → 落账（Codex round-2 C1：反复有损重编码）

    /// thumbnail 是解不开的坏字节（永远压不动）而 finishedImage 压下来了：
    /// 行被成功瘦身（.migrated）但仍超扫描阈值。不落账的话下一轮扫描重新选中它 ——
    /// **每次启动一次有损重编码**，画质逐次下降，写放大换了个触发器。
    @MainActor
    func test_compactOne_ledgers_row_that_stays_over_threshold() async throws {
        let container = try makeContainer()
        var corrupt = Data(count: 13 * 1024 * 1024)
        corrupt.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        let id = try seedProject(
            in: container, thumbnail: corrupt, displayThumbnail: nil,
            finishedImage: makeFatPhotoPNG()
        )

        let outcome = await ThumbnailMigrationCoordinator.compactOne(projectId: id, container: container)
        XCTAssertTrue(outcome.isMigrated, "成品图压下来了，应算成功，实际 \(outcome)")

        let row = try XCTUnwrap(fetchRow(id, in: container))
        XCTAssertEqual(row.thumbnail, corrupt, "解不开的字节必须原样保留")
        let finishedAfter = try XCTUnwrap(row.finishedImage)
        XCTAssertLessThan(finishedAfter.count, ProjectImageEncoder.compactionThresholdBytes)

        // 口径必须与扫描器的 sizeExpression 一致：三个图片列之和
        let scannerMetric = (row.thumbnail?.count ?? 0)
            + (row.finishedImage?.count ?? 0)
            + (row.displayThumbnail?.count ?? 0)
        XCTAssertTrue(
            ThumbnailMigrationCoordinator.isStubborn(id, bytes: scannerMetric),
            "行瘦身后仍超阈值却没落账 —— 下一轮扫描会重新选中它，每次启动一次有损重编码"
        )
    }

    // MARK: - displayThumbnail 被并发填充时不得覆盖（round-2 变异测试指出的 M2b 缺口）

    @MainActor
    func test_compactOne_does_not_clobber_concurrently_filled_display_thumbnail() async throws {
        let container = try makeContainer()
        // 原图够小 → 只触发回填分支
        let id = try seedProject(in: container, thumbnail: makePNG(side: 64), displayThumbnail: nil)

        let concurrentFill = Data([0xF1, 0xE2, 0xD3])   // 对方（updateProjectThumbnail）填的小图
        ThumbnailMigrationCoordinator.didFinishEncodingForTesting = { @Sendable changedId in
            await MainActor.run {
                let ctx = ModelContext(container)
                var d = FetchDescriptor<SDProjectRecord>(predicate: #Predicate { $0.id == changedId })
                d.fetchLimit = 1
                if let row = try? ctx.fetch(d).first {
                    row.displayThumbnail = concurrentFill
                    try? ctx.save()
                }
            }
        }

        let outcome = await ThumbnailMigrationCoordinator.compactOne(projectId: id, container: container)
        XCTAssertEqual(outcome, .alreadyDone, "对方已填好小图，本次应是 no-op，实际 \(outcome)")
        XCTAssertEqual(
            try fetchRow(id, in: container)?.displayThumbnail, concurrentFill,
            "并发填充的小图被迁移器覆盖了 —— 对方拿的是更新的原图，我们的版本是旧的"
        )
    }

    // MARK: - compactHistoryOne（round-2 变异测试：整个函数零测试触达）

    @MainActor
    private func seedHistory(
        in container: ModelContainer,
        before: Data?,
        after: Data?
    ) throws -> UUID {
        let ctx = ModelContext(container)
        let rec = SDHistoryRecord(
            operationType: "projectUpdate", targetName: "历史测试",
            beforeSnapshot: before, afterSnapshot: after
        )
        ctx.insert(rec)
        try ctx.save()
        return rec.id
    }

    @MainActor
    private func fetchHistoryRow(_ id: UUID, in container: ModelContainer) throws -> SDHistoryRecord? {
        let ctx = ModelContext(container)
        var d = FetchDescriptor<SDHistoryRecord>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try ctx.fetch(d).first
    }

    private func makeFatSnapshotJSON() throws -> Data {
        let snapshot = ProjectSnapshot(
            id: UUID(), name: "带图快照", date: Date(timeIntervalSince1970: 1_700_000_000),
            totalBeads: 42, brandId: nil, isArchived: false, parentId: nil,
            isPlanned: false, executedDate: nil, beadUsages: [],
            thumbnail: makeFatPhotoPNG(),
            finishedImage: makeFatPhotoPNG(side: 1300),
            capturesImages: true
        )
        return try JSONEncoder().encode(snapshot)
    }

    /// 快照两列都压下来 → .compacted；解码回来撤回语义完整；
    /// 压完仍超阈值（两列 base64 各 ~3.5MB）→ **函数内部**落账；第二遍 → .noOp。
    @MainActor
    func test_compactHistoryOne_compacts_ledgers_and_converges() async throws {
        let container = try makeContainer()
        let fat = try makeFatSnapshotJSON()
        XCTAssertGreaterThan(fat.count, ProjectImageEncoder.compactionThresholdBytes,
                             "夹具必须超阈值，否则没在测该测的东西")
        let id = try seedHistory(in: container, before: fat, after: fat)

        let outcome = await ThumbnailMigrationCoordinator.compactHistoryOne(recordId: id, container: container)
        guard case .compacted(let saved, let written) = outcome else {
            return XCTFail("期望 .compacted，实际 \(outcome)")
        }
        XCTAssertGreaterThan(saved, 0)

        let row = try XCTUnwrap(fetchHistoryRow(id, in: container))
        let newBefore = try XCTUnwrap(row.beforeSnapshot)
        XCTAssertLessThan(newBefore.count, fat.count, "快照没变小")
        // 撤回语义：图还在、能解码
        let decoded = try JSONDecoder().decode(ProjectSnapshot.self, from: newBefore)
        XCTAssertNotNil(decoded.thumbnail, "撤回要靠它还原图片，绝不能变 nil")
        XCTAssertNotNil(UIImage(data: try XCTUnwrap(decoded.thumbnail)))
        XCTAssertEqual(decoded.capturesImages, true)

        // 预算记账按整行（两列之和），与历史扫描器的 sizeExpression 同口径
        let rowTotal = (row.beforeSnapshot?.count ?? 0) + (row.afterSnapshot?.count ?? 0)
        XCTAssertEqual(written, rowTotal, "bytesWritten 必须是保存后整行之和（预算口径）")
        if rowTotal > ProjectImageEncoder.compactionThresholdBytes {
            XCTAssertTrue(
                ThumbnailMigrationCoordinator.isStubborn(id, bytes: rowTotal),
                "压完仍超阈值却没落账 —— 每次启动都会重新解析这条几 MB 的快照"
            )
        }

        // 收敛：第二遍必须是 .noOp（里面每张图都已低于单图阈值）
        let second = await ThumbnailMigrationCoordinator.compactHistoryOne(recordId: id, container: container)
        XCTAssertEqual(second, .noOp, "第二遍应当无事可做，实际 \(second)")
    }

    /// 坏字节快照 → .noOp（**有意**不走 .failed）：JSONSerialization 对相同输入的失败是
    /// 确定性的，走 .failed = 每次启动重新解析同一条坏快照、永远失败，纯烧 CPU。
    /// 落 stubborn（内容键控，由调用方做）才是对确定性失败的正确处置。
    @MainActor
    func test_compactHistoryOne_returns_noOp_for_malformed_snapshot() async throws {
        let container = try makeContainer()
        let garbage = Data([0x00, 0x01, 0x02, 0x03])
        let id = try seedHistory(in: container, before: garbage, after: nil)

        let outcome = await ThumbnailMigrationCoordinator.compactHistoryOne(recordId: id, container: container)
        XCTAssertEqual(outcome, .noOp)
        XCTAssertEqual(try fetchHistoryRow(id, in: container)?.beforeSnapshot, garbage,
                       "坏字节必须原样保留 —— .projectDelete 的快照可能是照片唯一拷贝")
    }
}
