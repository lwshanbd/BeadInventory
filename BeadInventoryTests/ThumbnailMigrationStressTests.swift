//
//  ThumbnailMigrationStressTests.swift
//  BeadInventoryTests
//
//  压力测试：批量真实磁盘 I/O + 大 blob，验证 ThumbnailMigrationCoordinator 的修复
//  （build 180 watchdog 崩溃，2026-07-26，详见 ThumbnailMigrationCoordinator.swift 顶部注释）
//  在高负载下依然成立 —— 迁移全程不得让主线程停摆。
//
//  测量方法：用一个跑在 MainActor 上、每 5ms `Task.sleep` 醒一次的 ticker 记录相邻两次
//  醒来之间的实际间隔。这个 ticker 恢复执行必须重新拿到 MainActor 的 executor —— 如果
//  别处代码在主线程上做了同步阻塞 I/O（哪怕只有几十 ms），ticker 就会被真实卡住同样的
//  时长，直接反映在 gap 里。相比"看 App 有没有卡"，这是可重复、可进 CI、不依赖真机热
//  限流也能测出问题的量化验证。
//
//  为了让阻塞（如果重新引入）值得一测：用真实磁盘文件（非 isStoredInMemoryOnly）+
//  120 条约 2MB 随机噪声 PNG（噪声图基本不可压缩，逼近真实"大图 blob"的 I/O 量级），
//  总计约 240MB 写入/读取，跑满整个迁移路径（fetch → downsample → TOCTOU 复核 → save）。
//

import XCTest
import SwiftData
import UIKit
@testable import BeadInventory

/// 每 tick 之间的实际耗时不应远超目标间隔——一旦某次 gap 飙到几十 ms 以上，
/// 说明 MainActor 的 executor 被别处同步占用了，这正是 build 180 崩溃的机制。
@MainActor
private final class MainThreadTicker {
    private(set) var maxGapNanos: UInt64 = 0
    private(set) var tickCount: Int = 0
    private var isRunning = false

    /// 覆盖时长 —— 见 InventoryManagerInitialLoadTests 里同名字段的说明：
    /// 「样本数 > N」实际在量机器负载（`Task.sleep` 在全量并发跑时大幅超时），
    /// 单测常绿、全量必红。覆盖时长与 tick 频率无关，才是「ticker 真的守过整段」的表达。
    private(set) var firstTickAt: DispatchTime?
    private(set) var lastTickAt: DispatchTime?

    var observedSpanNanos: UInt64 {
        guard let first = firstTickAt, let last = lastTickAt,
              last.uptimeNanoseconds > first.uptimeNanoseconds else { return 0 }
        return last.uptimeNanoseconds - first.uptimeNanoseconds
    }

    func run(intervalNanos: UInt64) async {
        isRunning = true
        var lastTick = DispatchTime.now()
        while isRunning {
            try? await Task.sleep(nanoseconds: intervalNanos)
            guard isRunning else { break }
            let now = DispatchTime.now()
            let gap = now.uptimeNanoseconds - lastTick.uptimeNanoseconds
            if gap > maxGapNanos { maxGapNanos = gap }
            lastTick = now
            tickCount += 1
            if firstTickAt == nil { firstTickAt = now }
            lastTickAt = now
        }
    }

    func stop() { isRunning = false }
}

final class ThumbnailMigrationStressTests: XCTestCase {
    private var storeDir: URL!

    override func setUpWithError() throws {
        storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumbnail-stress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storeDir)
    }

    /// 真实磁盘文件存储（不是内存库）—— 迁移的 fetch/save 要打到真实 SQLite 文件，
    /// 压测才有意义：内存库不会有 pread 之类的磁盘 I/O。
    private func makeFileBackedContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let storeURL = storeDir.appendingPathComponent("stress.store")
        let config = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// 生成一张随机噪声 PNG —— 逐像素随机字节让 PNG 的 DEFLATE 压缩基本失效，
    /// 文件大小逼近原始像素数据大小（不像纯色图那样被压成几 KB），
    /// 用来模拟老项目里"全分辨率照片直接存 blob"的真实体量。
    private func makeNoisyPNG(width: Int, height: Int) -> Data {
        var buffer = Data(count: width * height * 4)
        buffer.withUnsafeMutableBytes { raw in
            arc4random_buf(raw.baseAddress, raw.count)
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
        guard let provider = CGDataProvider(data: buffer as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            fatalError("构造噪声 CGImage 失败")
        }
        guard let png = UIImage(cgImage: cgImage).pngData() else {
            fatalError("噪声图编码 PNG 失败")
        }
        return png
    }

    // MARK: - 压测

    func test_heavy_migration_load_never_stalls_main_thread() async throws {
        let container = try makeFileBackedContainer()

        // ~1100x650 随机噪声（PNG 只编码 RGB 三通道）≈ 2.1MB，基本不可压缩，
        // 落在崩溃报告里描述的"单条 5-10MB"同一量级（取保守值以控制测试时长）。
        let noisyPNG = makeNoisyPNG(width: 1100, height: 650)
        XCTAssertGreaterThan(noisyPNG.count, 1_500_000, "噪声图需要足够大才有压测意义——太小测不出阻塞")

        let projectCount = 120
        let seedCtx = ModelContext(container)
        var ids: [UUID] = []
        ids.reserveCapacity(projectCount)
        for i in 0..<projectCount {
            let record = SDProjectRecord(
                name: "压测项目\(i)",
                totalBeads: 0,
                thumbnail: noisyPNG,
                finishedImage: nil,
                displayThumbnail: nil,
                beadUsages: []
            )
            seedCtx.insert(record)
            ids.append(record.id)
        }
        try seedCtx.save()

        // 120 × ~2MB ≈ 240MB 磁盘数据，验证在这个量级下主线程 tick 始终没有异常空档。
        let ticker = await MainThreadTicker()
        async let tickerRun: Void = ticker.run(intervalNanos: 5_000_000)  // 5ms

        let migrationStart = DispatchTime.now()
        var outcomes: [ThumbnailMigrationCoordinator.MigrationOutcome] = []
        outcomes.reserveCapacity(projectCount)
        for id in ids {
            let outcome = await ThumbnailMigrationCoordinator.compactOne(projectId: id, container: container)
            outcomes.append(outcome)
        }

        let migrationDurationNanos = DispatchTime.now().uptimeNanoseconds - migrationStart.uptimeNanoseconds
        await ticker.stop()
        _ = await tickerRun

        // 正确性：120 个全新种子项目应当全部迁移成功（无 race / 无失败）。
        XCTAssertEqual(outcomes.filter(\.isMigrated).count, projectCount, "120 个全新种子项目应全部瘦身成功，实际 \(outcomes.filter { !$0.isMigrated })")

        let tickCount = await ticker.tickCount
        let maxGapMillis = await Double(ticker.maxGapNanos) / 1_000_000

        // 样本量太少说明 ticker 根本没跑起来（比如迁移瞬间就结束了）——测试本身失效，
        // 不代表通过。
        let observedSpan = await ticker.observedSpanNanos
        XCTAssertGreaterThanOrEqual(tickCount, 3, "ticker 根本没跑起来，maxGap 断言无意义")
        XCTAssertGreaterThan(
            Double(observedSpan), Double(migrationDurationNanos) * 0.5,
            "ticker 只覆盖了迁移过程的 "
            + "\(Int(Double(observedSpan) / Double(max(migrationDurationNanos, 1)) * 100))%，"
            + "maxGap 没有真正守住整段"
        )

        // 阈值校准（非拍脑袋）：对同一台跑测试的机器做过两组对照实验——
        // (a) ticker 完全 idle（零并发负载）500ms 内已测到 46ms 的调度抖动；
        // (b) ticker 并发一段等量级但完全不碰 SwiftData 的纯内存/CPU 负载，gap 仅 6ms
        //     （因为纯内存操作跑得快，没来得及暴露抖动）。
        // 也就是说本沙箱环境的基线抖动本身就有几十 ms，与 SwiftData/CoreData 无关。
        // 而一旦真的退回 build 180 的 bug（迁移在主线程同步做 blob I/O），120 个项目
        // 顺序执行会让主线程连续停摆到秒级（对照当年崩溃日志的 5000ms 看门狗窗口）——
        // 和这里的几十到几百 ms 环境噪声不是一个数量级。800ms 阈值留了充分安全边际：
        // 远高于本环境已实测的噪声上限，又远低于真实回归会产生的秒级停摆，足够灵敏。
        XCTAssertLessThan(
            maxGapMillis, 800,
            "主线程 tick 间隔出现 \(maxGapMillis)ms 的异常空档——说明迁移路径上有代码"
            + "在主线程做了同步阻塞 I/O，这正是 build 180 崩溃的机制（详见"
            + "ThumbnailMigrationCoordinator.swift 顶部注释）"
        )
    }
}
