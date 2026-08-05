//
//  InventoryManagerInitialLoadTests.swift
//  BeadInventoryTests
//
//  钉住「打开 App 长时间白屏」的修复本身，而不只是它的副作用。
//
//  背景：`InventoryManager` 是 @MainActor，首次读取由 `RootView.onAppear` 触发。
//  修复前 `loadData()` 在 MainActor 上**同步**跑完整套 SwiftData 全表 fetch
//  （brands / stocks / projects / customColors + 4 个 blob 存在性查询 + 老数据迁移），
//  SwiftUI 因此拿不到机会提交首帧 —— 用户看到的就是系统白色启动画面一直挂着。
//  `AppBackgroundTaskManager.perform` 申请的是后台执行时间，**不切线程**，救不了这个。
//
//  测量方法与 ThumbnailMigrationStressTests 一致：一个跑在 MainActor 上、每 5ms 醒一次的
//  ticker，记录相邻两次醒来之间的真实间隔。ticker 恢复执行必须重新拿到 MainActor 的
//  executor —— 只要首次读取有任何一段回到主线程做同步 I/O，gap 就会被真实拉长。
//
//  这一点很关键：单纯「轮询 hasCompletedInitialLoad 直到变 true」只能证明**最终会完成**，
//  哪怕有人把实现改回同步阻塞，那种测试照样通过。要证明白屏被修好，必须测主线程有没有停摆。
//

import XCTest
import SwiftData
import UIKit
@testable import BeadInventory

/// 每 tick 之间的实际耗时不应远超目标间隔——一旦某次 gap 飙到几百 ms，
/// 说明 MainActor 的 executor 被别处同步占用了，这正是白屏的机制。
@MainActor
private final class MainThreadTicker {
    private(set) var maxGapNanos: UInt64 = 0
    private(set) var tickCount: Int = 0
    private var isRunning = false

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
        }
    }

    func stop() { isRunning = false }
}

@MainActor
final class InventoryManagerInitialLoadTests: XCTestCase {
    private var storeDir: URL!

    override func setUpWithError() throws {
        storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("initial-load-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        // 图片文件存储隔离到本用例自己的目录（否则跨测试类串数据）
        ProjectImageStore.rootOverrideForTesting = storeDir.appendingPathComponent("images", isDirectory: true)
    }

    override func tearDownWithError() throws {
        ProjectImageStore.rootOverrideForTesting = nil
        // 只有没把容器交给 HistoryManager.shared 的用例才能删目录，理由见
        // `retainedForHistorySingleton` 的注释。
        if !storeDirMustOutliveTest {
            try? FileManager.default.removeItem(at: storeDir)
        }
    }

    /// 交给 `HistoryManager.shared`（进程级单例）的容器必须活过用例。
    ///
    /// 单例内部用 DispatchSource 做防抖保存，`setModelContext` 只能取消尚未派发的 work item；
    /// 已经进入主队列的那一次拦不住。用例结束就删 store 目录的话，那次迟到的 save 会对着
    /// 不存在的库触发 SwiftData 的 `EXC_BREAKPOINT`，**整个测试进程崩溃**（实测：
    /// 全量套件跑到后面必崩，单独跑每个用例都通过）。所以这里把容器和目录都留到进程结束 ——
    /// 临时目录由系统回收，代价远小于让整个套件不可信。
    private static var retainedForHistorySingleton: [ModelContainer] = []
    private var storeDirMustOutliveTest = false

    /// 真实磁盘文件存储（不是内存库）—— 首次读取的 fetch 要打到真实 SQLite 文件，
    /// 才谈得上复现「首次开库 + 大表扫描」的耗时；内存库没有 pread 之类的磁盘 I/O。
    private func makeFileBackedContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let storeURL = storeDir.appendingPathComponent("initial-load.store")
        let config = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// 随机噪声 PNG：逐像素随机字节让 DEFLATE 基本失效，文件大小逼近原始像素数据，
    /// 模拟老项目里「全分辨率照片直接存 blob」的真实体量。
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

    /// 播种一个「大库」：品牌 + 整套库存 + 带大 blob 的项目。
    /// 数量级参照历史事故里反复出现的重度用户（数百项目 / 每品牌整套色号库存）。
    @discardableResult
    private func seedLargeStore(
        in container: ModelContainer,
        brandCount: Int,
        stocksPerBrand: Int,
        projectCount: Int,
        blob: Data
    ) throws -> [UUID] {
        let ctx = ModelContext(container)
        var brandIDs: [UUID] = []
        for b in 0..<brandCount {
            let brand = SDBrand(from: Brand(name: "品牌\(b)", sortOrder: b))
            ctx.insert(brand)
            brandIDs.append(brand.id)
            for s in 0..<stocksPerBrand {
                ctx.insert(SDBrandStock(from: BrandStock(
                    brandId: brand.id,
                    mardCode: "H\(String(format: "%03d", s))",
                    stock: 1000,
                    used: 0
                )))
            }
        }
        for p in 0..<projectCount {
            // 一半带 thumbnail、一半带 finishedImage，让 4 个 blob 存在性查询都有活干。
            ctx.insert(SDProjectRecord(
                name: "项目\(p)",
                totalBeads: p,
                thumbnail: p % 2 == 0 ? blob : nil,
                finishedImage: p % 2 == 1 ? blob : nil,
                displayThumbnail: nil,
                beadUsages: []
            ))
        }
        try ctx.save()
        return brandIDs
    }

    // MARK: - 白屏修复的核心回归点

    /// 大库首次读取全程，主线程不得出现异常停摆。
    ///
    /// 这是「打开 App 长时间白屏」这个用户反馈的直接量化验证：白屏 = 首帧提交被主线程
    /// 同步 I/O 挡住。只要 ticker 在整个读取期间都能按时醒来，SwiftUI 就有机会提交首帧
    /// 并画出 loading overlay，用户看到的就是转圈而不是白屏。
    func test_initial_load_never_stalls_main_thread() async throws {
        let container = try makeFileBackedContainer()

        // ~900x520 随机噪声 ≈ 1.4MB/张，60 张约 84MB —— 足以让「回到主线程物化 blob」
        // 的回归以百毫秒级停摆暴露出来，同时控制测试时长。
        let blob = makeNoisyPNG(width: 900, height: 520)
        XCTAssertGreaterThan(blob.count, 1_000_000, "噪声图需要足够大才有压测意义——太小测不出阻塞")

        try seedLargeStore(
            in: container,
            brandCount: 10,
            stocksPerBrand: 200,
            projectCount: 200,
            blob: blob
        )

        // 先在后台把本库的**读路径**预热一遍，再开始计时。
        //
        // 这不是为了让数字好看，而是为了把「本 PR 负责的部分」隔离出来单独量。实测同一
        // 用例、同一份数据的两组对照：
        //   - 不预热：ticker maxGap ≈ 210ms，ticks=7，总耗时 252ms
        //     —— 主线程从后台 fetch 一开始就被占住，直到 210ms 才放开。
        //   - 预热后：ticker maxGap ≈ 12ms，ticks=42，总耗时 260ms
        //     —— 总耗时几乎一样，但主线程全程自由。
        // 即：**读取本身从不占主线程（本 PR 修好的部分），但 SwiftData 对某个 store 的
        // 「第一次读」会阻塞主线程约 210ms，且即使 fetch 是从 detached 任务发起的也一样。**
        // 那 210ms 不是本 PR 引入、也不是本 PR 能修的（属于 SwiftData 首次开库/建查询计划
        // 的固有成本，见项目记忆「SwiftData 第一次取数会同步开库」），单独跟进。
        //
        // 所以这里预热掉它，让本用例专注钉住「读取工作不得回主线程」这一条 —— 阈值也才
        // 能从 800ms 收到 150ms，对真回归（读取退回主线程，本数据量下 250–480ms）才灵敏。
        await Task.detached {
            let bg = ModelContext(container)
            _ = try? bg.fetch(FetchDescriptor<SDBrand>())
            _ = try? bg.fetch(FetchDescriptor<SDBrandStock>())
            _ = try? bg.fetch(FetchDescriptor<SDProjectRecord>())
            _ = try? bg.fetch(FetchDescriptor<SDCustomColor>())
        }.value

        let m = InventoryManager(modelContext: ModelContext(container))

        let ticker = MainThreadTicker()
        async let tickerRun: Void = ticker.run(intervalNanos: 5_000_000)  // 5ms

        m.performInitialLoadIfNeeded(reason: "unitTest.mainThreadStall")

        // 本用例是两层防线，分别管两种回归：
        //
        // 第一层（下面这两条，确定性、零 flaky）：首次读取必须**立刻**返回、把主线程让出去。
        //   实测把 loadData 里的异步分支删掉退回同步实现后，正是这两条报错 —— 因为同步版本
        //   在 performInitialLoadIfNeeded 返回时就已经加载完了。
        // 第二层（末尾的 ticker maxGap）：管「异步窗口里仍有部分活儿跑回主线程」这种
        //   局部回归 —— 那种情况下这两条仍会通过，只有 ticker 能测出来。
        XCTAssertTrue(m.isInitialLoadInProgress, "首次读取应处于进行中：同步返回说明活儿又回到主线程了")
        XCTAssertFalse(m.hasCompletedInitialLoad, "首次读取不得同步完成，否则 SwiftUI 没机会提交首帧")

        await m.initialLoadTask?.value

        ticker.stop()
        _ = await tickerRun

        // 正确性：主线程没被堵住的同时，数据必须真的读上来了。
        XCTAssertTrue(m.hasCompletedInitialLoad, "后台读取应成功完成")
        XCTAssertEqual(m.brands.count, 10)
        XCTAssertEqual(m.brandStocks.count, 10 * 200)
        XCTAssertEqual(m.projects.count, 200)
        XCTAssertEqual(m.projectIDsWithThumbnail.count, 100)
        XCTAssertEqual(m.projectIDsWithFinishedImage.count, 100)
        // metadata-only：内存缓存不得持有 blob（否则又是 jetsam 同型事故）
        XCTAssertTrue(m.projects.allSatisfy { $0.thumbnail == nil && $0.finishedImage == nil })

        // 下限从 20 调到 5：blob 存在性判断改走 raw SQLite 头部扫描后，同一份数据的
        // 后台读取从约 210ms 降到约 75ms（真实提速，不是测试放水），5ms 一跳自然只剩十几个
        // 采样点。这条断言的作用是「确认 ticker 真的覆盖了读取过程」，不是衡量耗时。
        XCTAssertGreaterThan(
            ticker.tickCount, 5,
            "ticker 应在整个读取期间持续打点，样本太少说明测试没有真正覆盖读取过程"
        )

        // 阈值校准（实测，非拍脑袋），同一台机器四组对照：
        //   (a) ticker 完全空转 600ms × 3 轮：maxGap 7 / 15 / 7 ms —— 环境噪声基线。
        //   (b) 主线程故意同步忙等 400ms：maxGap 406ms —— 说明 ticker 灵敏度是准的。
        //   (c) 本用例（读路径已预热）：maxGap 约 12ms，ticks=42 —— 与空转基线同级，
        //       即整条后台读取确实没在主线程干活。
        //   (d) 同一用例不预热：maxGap 约 210ms，ticks=7 —— 见上方预热处的说明，
        //       那是 SwiftData「首次读」的固有成本，不在本 PR 范围内。
        // 真回归（fetch 退回主线程）在本数据量下是 250–480ms 的连续停摆。
        // 150ms 阈值：比实测基线(12ms)高一个数量级留足余量，又远低于真回归量级，足够灵敏。
        let maxGapMillis = Double(ticker.maxGapNanos) / 1_000_000
        XCTAssertLessThan(
            maxGapMillis, 150,
            "主线程 tick 出现 \(maxGapMillis)ms 空档——首次读取路径上有代码在主线程做同步阻塞 I/O，"
            + "这正是「打开 App 长时间白屏」的机制"
        )
    }

    // MARK: - 启动链路整体守卫（给「下一次白屏」用的网）

    /// 复刻真实启动顺序，量整条链路对主线程的占用。
    ///
    /// **这条用例不是为了验证某一个修复，是为了兜住下一个。**
    /// 白屏已经修过三轮，每轮都是同一个形状：某个东西在首帧前同步跑 ——
    ///   #51/#52: `CKContainer` 首次握手、`Tips.configure`、history 整表物化 snapshot blob
    ///   #57(本 PR): `InventoryManager` 首次 SwiftData 全表 fetch
    /// 每次都靠用户报障才发现。这条用例把「启动链路必须让出主线程」变成可自动回归的断言：
    /// 以后谁往 `App.init` 或 `RootView.onAppear` 里加了同步重活，这里直接红。
    ///
    /// 两条断言分别对应白屏的两种成因：
    ///   1. `tickCount > 0` —— 整条链路**从不让出主线程**，SwiftUI 连一帧都提交不了。
    ///      这正是 #51/#52 时期 `App.init` 同步开库 1s 的形状。
    ///   2. `maxGap` 有上限 —— 让出了，但中间有长时间停摆，同样画不出加载态。
    ///
    /// 注意这条**故意不预热 store**（跟上面那条主线程停摆用例相反）：它量的就是用户真实
    /// 感受到的冷启动，包含 SwiftData 首次开库的固有成本。所以阈值比上面那条宽。
    func test_launch_sequence_yields_main_actor_and_never_stalls() async throws {
        let container = try makeFileBackedContainer()
        try seedLargeStore(
            in: container,
            brandCount: 10,
            stocksPerBrand: 200,
            projectCount: 200,
            blob: makeNoisyPNG(width: 900, height: 520)
        )

        let ticker = MainThreadTicker()
        async let tickerRun: Void = ticker.run(intervalNanos: 5_000_000)

        // ---- 复刻 BeadInventoryApp.init 的同步段 ----
        // 容器要交给 HistoryManager.shared，必须活过本用例（见 retainedForHistorySingleton）
        storeDirMustOutliveTest = true
        Self.retainedForHistorySingleton.append(container)

        let manager = InventoryManager(modelContext: ModelContext(container))
        HistoryManager.shared.setModelContext(container.mainContext)
        HistoryManager.shared.inventoryManager = manager

        // ---- 复刻 RootView.onAppear ----
        manager.performInitialLoadIfNeeded(reason: "unitTest.launchSequence")

        // 两条后台链路都收敛后才算启动完成。
        await manager.initialLoadTask?.value
        await HistoryManager.shared.loadTask?.value

        ticker.stop()
        _ = await tickerRun

        XCTAssertGreaterThan(
            ticker.tickCount, 0,
            "整条启动链路一次都没让出主线程 —— SwiftUI 连第一帧都提交不了，用户看到的就是白屏。"
            + "检查是不是往 App.init / RootView.onAppear 里加了同步的持久层或磁盘操作。"
        )
        XCTAssertTrue(manager.hasCompletedInitialLoad, "启动后库存应加载完成")

        // 阈值锚在**真实看门狗预算**上，不是拍脑袋：2026-08-05 的线上崩溃报告里
        // `scene-create watchdog transgression: exhausted real (wall clock) time
        // allowance of 2.06 seconds` —— 首帧超过约 2s 画不出来，系统就 SIGKILL。
        // 所以这里超过 2000ms 就意味着生产环境会被杀。
        //
        // 为什么放这么宽：本用例**故意不预热** store，量的是含 SwiftData 首次读
        //（实测约 210ms）的真实冷启动，因而对机器负载敏感 —— 全量套件并发跑时实测到过
        // 1162ms，单独跑只要 1.6s 总耗时、gap 远低于阈值。想要灵敏的回归检测看上面
        // test_initial_load_never_stalls_main_thread（预热后阈值收到 150ms）。
        // 本用例的硬保证是上面那条 `tickCount > 0`：它确定性地钉住「链路必须让出主线程」，
        // 正是 #51/#52 两轮白屏的形状，不受负载影响。
        let maxGapMillis = Double(ticker.maxGapNanos) / 1_000_000
        XCTAssertLessThan(
            maxGapMillis, 2000,
            "启动链路上主线程出现 \(maxGapMillis)ms 停摆 —— 这是白屏的直接成因。"
            + "对照上面 test_initial_load_never_stalls_main_thread 的分解数据定位是哪一段。"
        )
    }

    // MARK: - refresh 路径（2.4GB 种子库实测的白屏真凶）

    /// 首次加载完成后的 refresh 同样不得堵主线程。
    ///
    /// 2026-08-05 用 2.4GB 拼图模式种子库在模拟器实测：CloudKit / 跨 context 保存触发的
    /// 变更通知走旧的同步 refresh，每次堵主线程 2.0-2.7s、启动后 30s 内连发 4 次 ——
    /// 此时 loading 遮罩早已消失，用户看到的是整个 App 冻住。这才是 #51/#52/#57 三轮
    /// 修完仍在报的「白屏」真凶：前三轮全部只看了首次加载路径。
    func test_refresh_after_initial_load_runs_off_main_and_picks_up_store_changes() async throws {
        let container = try makeFileBackedContainer()
        try seedLargeStore(
            in: container,
            brandCount: 10,
            stocksPerBrand: 200,
            projectCount: 200,
            blob: makeNoisyPNG(width: 900, height: 520)
        )
        // 预热读路径，隔离 SwiftData 首读固有开销（理由见上一个用例的注释）
        await Task.detached {
            let bg = ModelContext(container)
            _ = try? bg.fetch(FetchDescriptor<SDBrand>())
            _ = try? bg.fetch(FetchDescriptor<SDBrandStock>())
            _ = try? bg.fetch(FetchDescriptor<SDProjectRecord>())
            _ = try? bg.fetch(FetchDescriptor<SDCustomColor>())
        }.value

        let m = InventoryManager(modelContext: ModelContext(container))
        m.performInitialLoadIfNeeded(reason: "unitTest.refreshStall")
        await m.initialLoadTask?.value
        XCTAssertTrue(m.hasCompletedInitialLoad)
        let before = m.projects.count

        // 模拟远端 / 其它 context 写入（正是触发 refresh 的真实场景）
        let bg = ModelContext(container)
        bg.insert(SDProjectRecord(name: "RemoteAdded", totalBeads: 1, beadUsages: []))
        try bg.save()

        let ticker = MainThreadTicker()
        async let tickerRun: Void = ticker.run(intervalNanos: 5_000_000)

        m.refreshFromPersistentStore(reason: "unitTest.refresh")
        // refresh 必须异步：同步实现下这里已经刷完了。
        XCTAssertNotNil(m.refreshTask, "refresh 应该在后台执行——同步返回说明活儿又回到主线程了")
        XCTAssertEqual(m.projects.count, before, "refresh 不得同步完成")

        await m.refreshTask?.value
        ticker.stop()
        _ = await tickerRun

        XCTAssertEqual(m.projects.count, before + 1, "refresh 应拉到其它 context 新写入的项目")
        XCTAssertTrue(m.projects.contains { $0.name == "RemoteAdded" })

        let maxGapMillis = Double(ticker.maxGapNanos) / 1_000_000
        XCTAssertLessThan(
            maxGapMillis, 150,
            "refresh 把主线程堵了 \(maxGapMillis)ms —— 这正是 2.4GB 库上实测 2-2.7s 冻屏的机制"
        )
    }

    /// 内存里有未保存编辑时，后台 refresh 的结果必须被丢弃，不得整份盖掉用户改动。
    ///
    /// 旧同步实现靠「主线程被占住、用户根本没机会编辑」来保证这一点；异步化之后
    /// fetch 在途窗口有几百 ms 到数秒，这个闸门（基线脏检查）是替代保障。
    func test_refresh_discards_result_when_local_unsaved_edits_exist() async throws {
        let container = try makeFileBackedContainer()
        try seedLargeStore(
            in: container,
            brandCount: 3,
            stocksPerBrand: 50,
            projectCount: 10,
            blob: makeNoisyPNG(width: 600, height: 360)
        )
        let m = InventoryManager(modelContext: ModelContext(container))
        m.performInitialLoadIfNeeded(reason: "unitTest.dirtyGuard")
        await m.initialLoadTask?.value
        XCTAssertTrue(m.hasCompletedInitialLoad)

        // 未保存的本地编辑：基线（refreshBaselines 已在加载时建立）与内存出现差异
        let edited = m.brands + [Brand(name: "本地未保存新品牌")]
        m.brands = edited

        m.refreshFromPersistentStore(reason: "unitTest.dirtyRefresh")
        XCTAssertNotNil(m.refreshTask)
        await m.refreshTask?.value

        XCTAssertEqual(m.brands, edited, "refresh 结果应被丢弃——应用它会把未保存的本地编辑整份盖掉")
    }

    // MARK: - 异步化之后新增的竞态闸门

    /// 用户在读取在途时点「以本地模式继续」，随后的后台结果不得覆盖内存。
    ///
    /// 同步实现里「在途」窗口是 0，所以这个竞态不存在；改成异步后窗口有几百毫秒到数秒，
    /// 用户在这段时间里已经可以浏览并修改内存中的数据。若不作废在途结果，
    /// 它返回时会把用户刚改的内容整份盖掉 —— 属于静默数据丢失。
    func test_local_fallback_during_flight_discards_stale_background_result() async throws {
        let container = try makeFileBackedContainer()
        let blob = makeNoisyPNG(width: 700, height: 420)
        try seedLargeStore(
            in: container,
            brandCount: 4,
            stocksPerBrand: 150,
            projectCount: 30,
            blob: blob
        )

        let m = InventoryManager(modelContext: ModelContext(container))
        m.performInitialLoadIfNeeded(reason: "unitTest.fallbackRace")
        XCTAssertTrue(m.isInitialLoadInProgress)

        let inFlightTask = m.initialLoadTask
        XCTAssertNotNil(inFlightTask, "应存在在途的后台读取任务")

        // 用户放弃等待，进入本地模式，并在内存里留下自己的改动。
        m.continueInLocalFallbackMode(reason: "unitTest")
        XCTAssertTrue(m.isUsingLocalFallbackMode)
        XCTAssertTrue(m.hasCompletedInitialLoad, "本地模式应立即解除 UI 屏蔽")

        let userEditedBrand = Brand(name: "用户在本地模式下新建的品牌")
        m.brands = [userEditedBrand]

        // 等在途读取真正跑完（它无法被取消，只能让结果失效）。
        await inFlightTask?.value

        // 关键断言：后台结果必须被丢弃，用户的内存改动原封不动。
        XCTAssertEqual(
            m.brands, [userEditedBrand],
            "在途后台读取的结果覆盖了用户在本地模式下的改动——代次闸门失效"
        )
        XCTAssertTrue(m.isUsingLocalFallbackMode, "过期结果不应把用户拉出本地模式")
    }

    /// 读取迟迟不返回时，超时看门狗必须放出出口按钮，而不是让 UI 永远转圈。
    ///
    /// 这是异步化引入的新失败模式：旧同步实现卡死至少还会被系统看门狗杀掉进程；异步版本
    /// 里 `await` 不返回就等于一个软死锁 —— ContentView 的「重试 / 以本地模式继续 /
    /// 关闭 iCloud 同步」三个按钮只在 `initialLoadErrorMessage != nil` 时才渲染，
    /// 不给超时兜底的话用户连退出的按钮都看不到。
    func test_initial_load_timeout_surfaces_escape_hatch() async throws {
        let container = try makeFileBackedContainer()
        try seedLargeStore(
            in: container,
            brandCount: 10,
            stocksPerBrand: 200,
            projectCount: 200,
            blob: makeNoisyPNG(width: 900, height: 520)
        )

        let m = InventoryManager(modelContext: ModelContext(container))
        // 把超时压到远小于这个库的真实读取耗时（实测约 250ms），稳定触发超时分支。
        m.initialLoadTimeout = 0.02
        m.performInitialLoadIfNeeded(reason: "unitTest.timeout")

        // 等到出口按钮的渲染条件成立（`initialLoadErrorMessage != nil`）。
        let deadline = Date().addingTimeInterval(5)
        while m.initialLoadErrorMessage == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertNotNil(
            m.initialLoadErrorMessage,
            "读取超时后必须给出错误信息——否则 ContentView 三个出口按钮一个都不会渲染，用户永远转圈"
        )
        XCTAssertFalse(m.isInitialLoadInProgress, "超时后不应仍标记为加载中")

        // 超时后用户点「重试」必须能真正重新发起（不被在途标志挡住）。
        // 注意顺序：看门狗在 `retryInitialLoad` 内部就按当时的 `initialLoadTimeout` 布防，
        // 所以必须先把超时调回正常值，否则这一轮会再次被 20ms 判负。
        m.initialLoadTimeout = 20
        m.retryInitialLoad(reason: "unitTest.retryAfterTimeout")
        XCTAssertNotNil(m.initialLoadTask, "超时后重试应能真正发起新一轮读取")
        await m.initialLoadTask?.value
        XCTAssertTrue(m.hasCompletedInitialLoad, "重试应当成功收敛")
        XCTAssertEqual(m.brands.count, 10)
        XCTAssertEqual(m.brandStocks.count, 10 * 200)
    }

    /// 重试会作废在途读取并真正重新发起一轮，而不是被 `isLoadingPersistentStore` 静默挡掉。
    func test_retry_during_flight_starts_a_new_load_instead_of_no_op() async throws {
        let container = try makeFileBackedContainer()
        try seedLargeStore(
            in: container,
            brandCount: 3,
            stocksPerBrand: 120,
            projectCount: 12,
            blob: makeNoisyPNG(width: 600, height: 360)
        )

        let m = InventoryManager(modelContext: ModelContext(container))
        m.performInitialLoadIfNeeded(reason: "unitTest.retryRace")
        let firstTask = m.initialLoadTask
        XCTAssertNotNil(firstTask)

        m.retryInitialLoad(reason: "unitTest.retry")
        let secondTask = m.initialLoadTask
        XCTAssertNotNil(secondTask, "重试应真正发起新一轮读取，而不是被在途标志挡掉变成空操作")

        await firstTask?.value
        await secondTask?.value

        // 新一轮读取正常收敛，数据完整。
        XCTAssertTrue(m.hasCompletedInitialLoad)
        XCTAssertEqual(m.brands.count, 3)
        XCTAssertEqual(m.brandStocks.count, 3 * 120)
        XCTAssertEqual(m.projects.count, 12)
    }
}
