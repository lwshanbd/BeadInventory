//
//  ThumbnailMigrationCoordinator.swift
//  BeadInventory
//
//  项目图片存量瘦身 + displayThumbnail 回填的后台协调器 —— 崩溃修复的关键迁移路径。
//
//  背景：早期版本把全分辨率 PNG 直接存到 `SDProjectRecord.thumbnail`（字段名是
//  "thumbnail" 但实际存的是原图），单条可达 5-10 MB。计划列表滑动时即使懒加载 + LazyVStack，
//  row 解码全分辨率 PNG → UIImage 也会瞬时撑爆内存（5MB PNG → 30+MB UIImage × 10 row ≈ jetsam）。
//
//  本协调器现在做**两件事**（原本只做第 2 件）：
//
//    1. **瘦身**：把超过 `ProjectImageEncoder.compactionThresholdBytes` 的 `thumbnail` /
//       `finishedImage` 走 `ProjectImageEncoder.recompress` 重编码（分辨率原样保留，
//       只撤回无损 PNG）。
//    2. **回填**：给缺 `displayThumbnail` 的行生成列表小图。
//
//  **两件事必须合并成同一次 `save()`** —— 这是本轮改动的核心，不是顺手优化：
//
//  三个图片字段都是 inline BLOB，SQLite 改行内任何一列都要重写整条记录（含全部
//  overflow page）。原实现只做第 2 件，往一条内联着 13 MB 原图的行里写 100 KB 的
//  displayThumbnail —— 实际写盘 13 MB，而且写完这行**还是 13 MB**。458 项目 ≈ 6 GB，
//  加 WAL + checkpoint = 用户 IPS 里那 68.72 GB dirty writes。
//  合并之后：胖行一生只被重写一次，且**写完就瘦了**，下一轮扫描不会再选中它。
//
//  瘦身完成后：
//  - 列表 row 直接读 displayThumbnail（~50-100 KB JPEG，UIImage 解码内存峰值 MB 级）
//  - 详情大图 / 拼图模式继续读 thumbnail —— 分辨率没变，拼图模式网格标定是归一化
//    0-1 坐标（`GridGeometry.denormalize`），不受重编码影响
//  - 库从 GB 级回到百 MB 级 → CoreData+CloudKit 的 vacuum / WAL checkpoint 不再持
//    EXCLUSIVE 锁数十秒 → 首屏那次 fetch 不再被拖过 scene-create 看门狗的 2.06s
//
//  设计要点：
//  - **主线程零 SwiftData I/O（TestFlight build 180 watchdog 崩溃修复，2026-07-26）**：
//    迁移的全部数据库访问（分页扫描、单行取 blob、TOCTOU 复核、写回 save）都跑在
//    `nonisolated` 后台函数里的独立 `ModelContext(container)` 上。此前的 `migrateOne`（现 `compactOne`）在
//    MainActor 上裸单行 fetch（无 propertiesToFetch）再读 `.thumbnail`，对主 context 里
//    已被 metadata 投影注册过的对象触发 Core Data deferred-fault 补全 = **主线程同步读盘**
//    （崩溃栈：`_PF_FulfillDeferredFault → sqlite3_step → pread`）。热限流（Thermal
//    Level 4）下这次读盘拖过切后台的 5s 宽限期 → 看门狗 0x8BADF00D SIGKILL。
//    修复后主线程只剩纯内存 bookkeeping（`noteProjectDisplayThumbnailMigrated`），
//    切后台瞬间主线程永远是空闲的，随时能应答 suspend。
//  - **不阻塞 UI**：每个 batch 之间 sleep 让出 runloop
//  - **幂等可中断**：下一次启动从 displayThumbnail == nil 的余量继续
//  - **不进 history**：迁移不是用户操作
//  - **不进 iCloud 优先级队列**：一次 save 一个，CloudKit 按需要慢慢同步上传
//  - **失败容忍**：单个项目 downsample / save 失败仅 logError，不阻断其它项目
//  - **TOCTOU 校验**：downsample 期间用户可能改 thumbnail，写回前用**全新** ModelContext
//    重新验证字节匹配（新 context 才能看到并发 commit，同 context 复用 registered 对象会
//    拿到 stale 值使校验空转）
//
//  触发时机：BeadInventoryApp 在 scenePhase .active 时调用一次 start（idempotent —— 已在
//  跑则跳过）。scenePhase .background 时调 stop()，理由：
//    (a) 释放后台 CPU（downsample 在 app 被 suspend 之前还会跑，浪费电量）
//    (b) 让接下来的 manager.saveData() 在没有并发 SwiftData 写入的稳定 store 上完成最终 flush
//  注意 stop() 只是尽快收尾 —— 即使某次后台 fetch/save 正在飞行中，它也不在主线程上，
//  不影响系统对 suspend 的 5s 应答窗口。

import Foundation
import SwiftUI
import SwiftData

@MainActor
final class ThumbnailMigrationCoordinator {
    static let shared = ThumbnailMigrationCoordinator()

    /// 启动后延迟启动时间，让出 UI 首屏 commit + iCloud 初次同步窗口。
    private static let initialDelaySeconds: UInt64 = 5

    /// 每批处理项目数。
    private static let batchSize: Int = 10

    /// 批与批之间的 sleep（纳秒）。
    private static let batchSleepNanos: UInt64 = 1_000_000_000

    /// 被闸门挡住时的重试间隔 —— 比批间 sleep 长得多，避免在发热 / 低电量时空转唤醒。
    private static let throttledRetryNanos: UInt64 = 30_000_000_000

    /// 连续被闸门挡住多少次就收工（等下次 scenePhase .active 再来）。
    /// 30s × 10 = 5 分钟；再耗下去不如把 CPU 还给用户。
    private static let maxConsecutiveThrottles: Int = 10

    /// 单次 run 的写入预算，按**整行重写量**记账，且逐行**事前预留**
    ///（用 candidate.bytes 这个上界先扣再动手，见 run loop）——
    /// 不是事后发现超了才停，单行不会把预算冲破到未知量级。
    ///
    /// 记账口径很重要：本文件的中心论点就是「改任何一列都要重写整条记录，含未改动的列」。
    /// 只算新写入的图片字节会系统性低估 —— 一条 thumbnail 13 MB→1.5 MB 而
    /// finishedImage 仍是 13 MB 的行，实际写盘约 14.5 MB，却只被计 1.5 MB。
    /// 低估的倍数正好是整个 PR 在讲的那个倍数，那预算就形同虚设。
    /// 所以 `compactOne` 汇报的是**保存后整行的估算大小**。
    ///
    /// 存在的意义是兜底：万一某个假设错了，预算保证单次启动的写入量有上限，不会重演 68 GB。
    private static let writeBudgetBytesPerRun: Int = 300 * 1024 * 1024

    /// 剩余磁盘低于此值就不跑 —— 瘦身过程中 WAL 会临时涨，盘满时写失败会让
    /// 本来好好的行进入半吊子状态。这批用户刚被写了 68 GB，盘紧不是小概率事件。
    private static let minFreeDiskBytes: Int64 = 500 * 1024 * 1024

    /// 「试过但压不下去」的项目 —— 每轮扫描要排除它们，否则同一行每轮都被选中重写。
    ///
    /// 典型成因：一张本来就编码高效的大图（比如 3 MB 的纯色块 PNG），
    /// `recompress` 判定「重编码后反而更大」返回 nil，但它的字节数仍在扫描阈值之上。
    /// 这类行留在库里是可以接受的（3 MB ≪ 13 MB），但绝不能让它把迁移器拖进死循环。
    private static let stubbornDefaultsKey = "ProjectImageCompaction.stubbornProjectIDs"

    /// 当前活跃 task 的 generation token。每次 start() bump，旧 task 的 defer 块拿着
    /// 自己的旧 generation 跟当前值比对：相等才允许清空状态。修复了 stop()+start() 之间
    /// 旧 task 误清新 task 状态的 race。
    private var currentGeneration: Int = 0
    private var isRunning: Bool = false
    private var task: Task<Void, Never>?

    private init() {}

    // MARK: - 暂停闸门

    /// 为什么要有闸门：瘦身是纯后台的空闲任务，一条也不做用户不会有任何感知
    /// （列表读 displayThumbnail，没有就走现场降级），但它做得太猛会烧 CPU / 写盘 /
    /// 发热，而**发热正是用户那份 IPS 的现场条件**（`Thermal Level: 3 / serious`）。
    /// 在已经过热的机器上继续跑重编码，等于往看门狗手里递刀。
    enum ThrottleReason: String {
        case thermal            // 机器已经烫了
        case lowPower           // 用户开了低电量模式，明确表达了「省着点用」
        case lowDisk            // 盘紧，WAL 涨不动
        case writeBudget        // 本轮写够了，下次启动接着来

        /// 这个原因是「等一等就能好」还是「本轮到此为止」。
        ///
        /// 放在类型上而不是散在两个调用方的 `==` 里：项目阶段原本写
        /// `reason == .writeBudget || ...`，历史阶段却把**所有**原因都当终止，
        /// 于是一次瞬时发热只让项目阶段歇 30 秒，却把历史阶段整轮掐掉。
        /// 策略上收之后两边行为一致，也不会再各自漂移。
        var endsThisRun: Bool { self == .writeBudget }
    }

    /// 返回非 nil 表示「现在不该干活」。
    /// `nonisolated` —— 在后台 executor 上直接调，不回主线程。
    nonisolated static func throttleReason(bytesWrittenThisRun: Int) -> ThrottleReason? {
        if bytesWrittenThisRun >= writeBudgetBytesPerRun { return .writeBudget }

        let info = ProcessInfo.processInfo
        switch info.thermalState {
        case .serious, .critical: return .thermal
        case .nominal, .fair: break
        @unknown default: break
        }
        if info.isLowPowerModeEnabled { return .lowPower }

        if let free = freeDiskBytes(), free < minFreeDiskBytes { return .lowDisk }
        return nil
    }

    /// 取值失败返回 nil —— 此时**不**拦（宁可跑也不要因为读不到容量就永久停摆，
    /// 真写不进去时 save 会自己失败并记 log）。
    private nonisolated static func freeDiskBytes() -> Int64? {
        let url = URL.applicationSupportDirectory
        guard let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ) else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
    }

    // MARK: - 后台扫描包装

    /// 把同步扫描器挪出主线程。
    ///
    /// `run()` / `runHistoryPhase()` 是 `@MainActor` 类的实例方法，**直接调这两个同步
    /// 扫描器就是在主线程上开 SQLite 连接、跑全表扫描**，而扫描器设了
    /// `sqlite3_busy_timeout(db, 2_000)` —— 库被 CloudKit 的 vacuum 持锁时，
    /// 每一批都可能把主线程钉住 2 秒。
    ///
    /// 也就是说：专治主线程 store I/O 的这个 PR，自己在主线程上放了一条带 2 秒超时的
    /// 同步 SQLite 路径，形状和它要修的看门狗崩溃一模一样。`compactOne` 是
    /// `nonisolated static async` 所以本来就在后台，唯独扫描漏了。
    ///
    /// 用 `Task.detached` 而不是 `nonisolated func`：后者在 Swift 5 语言模式下仍可能
    /// 在调用方的 executor 上同步跑完，detached 保证换线程。
    private nonisolated static func scanCandidatesOffMain(
        storeURL: URL,
        limit: Int,
        excluding: Set<UUID>
    ) async -> Result<[ProjectImageCompactionScanner.Candidate], StoreScanFailure> {
        await Task.detached(priority: .utility) {
            ProjectImageCompactionScanner.scanCandidates(
                storeURL: storeURL,
                thresholdBytes: ProjectImageEncoder.compactionThresholdBytes,
                limit: limit,
                excluding: excluding
            )
        }.value
    }

    private nonisolated static func scanHistoryCandidatesOffMain(
        storeURL: URL,
        limit: Int,
        excluding: Set<UUID>
    ) async -> Result<[ProjectImageCompactionScanner.Candidate], StoreScanFailure> {
        await Task.detached(priority: .utility) {
            ProjectImageCompactionScanner.scanHistoryCandidates(
                storeURL: storeURL,
                thresholdBytes: ProjectImageEncoder.compactionThresholdBytes,
                limit: limit,
                excluding: excluding
            )
        }.value
    }

    // MARK: - stubborn 记账

    /// 记账键是 `"<uuid>:<当时的字节数>"` 而不是裸 uuid。
    ///
    /// 只按 ID 记的话，这一行**永远**被排除：用户换了张图、从备份恢复、或者 CloudKit
    /// 从一台没升级的设备同步来一张新胖图 —— 全都不会被重新考虑，而这些新内容很可能
    /// 是压得动的。带上字节数之后，内容一变键就对不上，自然重新进入候选。
    private nonisolated static func stubbornKey(_ id: UUID, bytes: Int) -> String {
        "\(id.uuidString):\(bytes)"
    }

    nonisolated static func loadStubbornKeys() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: stubbornDefaultsKey) ?? [])
    }

    nonisolated static func isStubborn(_ id: UUID, bytes: Int) -> Bool {
        loadStubbornKeys().contains(stubbornKey(id, bytes: bytes))
    }

    nonisolated static func noteStubborn(_ id: UUID, bytes: Int) {
        var keys = loadStubbornKeys()
        // 同一个 ID 的旧记录（旧字节数）清掉，避免无限增长
        keys = keys.filter { !$0.hasPrefix(id.uuidString + ":") }
        keys.insert(stubbornKey(id, bytes: bytes))
        UserDefaults.standard.set(Array(keys), forKey: stubbornDefaultsKey)
    }

    /// 测试用 —— 清掉记账，让下一轮重新考虑所有行。
    nonisolated static func resetStubbornIDsForTesting() {
        UserDefaults.standard.removeObject(forKey: stubbornDefaultsKey)
    }

    /// 启动迁移。重入安全 —— 已经在跑就直接返回。
    /// priority .utility：迁移是空闲任务，CPU 重活（downsample）与 I/O 都不该抢用户交互资源。
    func start(inventoryManager: InventoryManager) {
        guard !isRunning else { return }
        guard task == nil else { return }
        currentGeneration &+= 1
        let myGeneration = currentGeneration
        isRunning = true
        task = Task(priority: .utility) { @MainActor [weak self, weak inventoryManager] in
            defer {
                if let self, self.currentGeneration == myGeneration {
                    self.isRunning = false
                    self.task = nil
                }
            }
            guard let inventoryManager else { return }
            await self?.run(inventoryManager: inventoryManager)
        }
    }

    /// 停止迁移（App 后台 / 终止时调用）。
    /// 旧 task 退出时的 defer 块靠 generation token 识别"这不是我的 generation 了"跳过清状态。
    func stop() {
        task?.cancel()
        isRunning = false
        task = nil
    }

    // MARK: - 内部实现

    // 注：`run()` 仍是 private，只能经 `start()` 触达，而没有测试调 `start()` ——
    // 也就是说 run loop 的终止条件（`excluded.insert`）目前仍**没有**测试覆盖，
    // 变异测试证实删掉它不会让任何测试变红。`StoreCompactionIntegrationTests` 是在
    // 测试体里重新实现了一遍循环，验证的是测试作者写的循环而不是这一个。
    //
    // 正确的修法是把项目阶段抽成 `nonisolated static func runProjectPhase(...)` 并返回一个统计结构体
    // 让集成测试直接调发布代码。本轮没做 —— 抽取涉及七个计数器和两处 labeled break，
    // 机械改写风险高于收益，留作 follow-up，不在这里放一个空壳类型假装已经做了。
    private func run(inventoryManager: InventoryManager) async {
        // 先睡 5s 让出冷启动 + 首屏 commit
        do {
            try await Task.sleep(nanoseconds: Self.initialDelaySeconds * 1_000_000_000)
        } catch {
            return  // 被取消
        }
        guard !Task.isCancelled else { return }

        guard let container = inventoryManager.modelContext?.container else {
            AppLogger.shared.warning("ThumbnailMigration", "no_model_context_skipping", metadata: [:])
            return
        }

        guard let storeURL = container.configurations.first?.url else {
            AppLogger.shared.warning("ThumbnailMigration", "no_store_url_skipping", metadata: [:])
            return
        }

        // storeURL / 候选数进日志：瘦身「跑了但一条都没选中」和「压根没跑」在用户设备上
        // 长得一模一样，出问题时没有这两个字段无从下手。
        AppLogger.shared.info("ThumbnailMigration", "started", metadata: [
            "storeURL": storeURL.lastPathComponent,
            "storeExists": FileManager.default.fileExists(atPath: storeURL.path),
            "storeDir": String(storeURL.deletingLastPathComponent().path.suffix(60)),
            "stubbornCount": Self.loadStubbornKeys().count
        ])

        var migrated = 0
        var raceSkipped = 0
        var alreadyDone = 0
        var failures = 0
        var pagesFetched = 0
        var bytesWritten = 0
        var consecutiveThrottles = 0

        // **候选发现走 raw SQLite，不走 SwiftData 谓词。**
        //
        // 原实现用 `#Predicate { thumbnail != nil && displayThumbnail == nil }` +
        // `propertiesToFetch = [\.id]`，看起来只取 id —— 实测（InitialLoadMemoryDiagnosticTests）
        // SwiftData 仍会把命中行的 blob 内容 SELECT 进内存（120 条 × 13 MB → +1.26 GB）。
        // 投影只控制生成对象的字段，不控制 SELECT 出来的列。分页 limit=10 只是把
        // 单次峰值压到 ~130 MB，没有消除问题。
        //
        // `ProjectImageCompactionScanner` 用只读连接跑
        // `WHERE length(ZTHUMBNAIL) > ?`，SQLite 对「length() 实参是直接列引用」有专门
        // 优化（OPFLAG_LENGTHARG），只读记录头的 serial type，不追 overflow page 链。
        //
        // **本轮已处理的行一律排除**，不管结果是什么。
        //
        // 这条不是优化，是终止条件：扫描是「按当前库状态重新查」而不是游标翻页，
        // 所以只要有一行处理完之后仍然符合扫描条件，下一轮就会原样再查到它 —— 死循环。
        // 会落到这种情况的至少有两类：字节坏掉导致 downsample 失败的行、
        // 以及并发被改动而跳过的行。原实现靠 `fetchOffset += pageFailures` 打补丁，
        // 「本轮处理过的就不再考虑」是同一件事更直接的表达，且对所有 outcome 一致成立。
        //
        // 只有 `.stubborn`（试过但压不下去）会**落盘**跨启动排除；其余的下次启动重新给机会。
        // **不要**用 stubborn 集合预填 `excluded`。
        //
        // 那样等于把 ID 无条件喂给扫描器的 `excluding:`，行就再也不会作为候选返回，
        // 于是下面按字节数的二次确认永远够不到 —— round 2 引入内容键控
        //（「用户换图 / 备份恢复 / CloudKit 同步来新图之后就该重新考虑」）成了摆设，
        // 行为跟只按 ID 拉黑完全一样。历史阶段从空集起所以是对的；两边不一致就是线索。
        //
        // 从空集起之后终止性不受影响：stubborn 命中会 `excluded.insert` + `continue`，
        // 其余 outcome 也一律 insert，每个被扫到的候选本轮内都会离开候选集。
        var excluded = Set<UUID>()

        // 打标签：下面 switch 里的失败分支要跳出的是**这个循环**，
        // 裸 `break` 只会跳出 switch（这条正是编译器帮我抓到的）。
        scanLoop: while true {
            guard !Task.isCancelled else {
                AppLogger.shared.info("ThumbnailMigration", "cancelled_mid_run", metadata: [
                    "migrated": migrated, "pagesFetched": pagesFetched, "bytesWritten": bytesWritten
                ])
                return
            }

            // 闸门：发热 / 低电量 / 盘紧 / 写够了 —— 任何一条命中就先歇着。
            // 用户那份 IPS 的现场条件就是 `Thermal Level: 3 / serious`，
            // 在已经烫的机器上继续跑重编码等于往看门狗手里递刀。
            if let reason = Self.throttleReason(bytesWrittenThisRun: bytesWritten) {
                consecutiveThrottles += 1
                AppLogger.shared.info("ThumbnailMigration", "throttled", metadata: [
                    "reason": reason.rawValue,
                    "consecutive": consecutiveThrottles,
                    "migrated": migrated,
                    "bytesWritten": bytesWritten
                ])
                // 写预算用尽是本次 run 的终点，不是等一等就能好的 —— 直接收工。
                if reason.endsThisRun || consecutiveThrottles >= Self.maxConsecutiveThrottles {
                    break scanLoop
                }
                do {
                    try await Task.sleep(nanoseconds: Self.throttledRetryNanos)
                } catch {
                    return  // cancelled
                }
                continue
            }
            consecutiveThrottles = 0

            let pageIDs: [ProjectImageCompactionScanner.Candidate]
            switch await Self.scanCandidatesOffMain(
                storeURL: storeURL,
                limit: Self.batchSize,
                excluding: excluded
            ) {
            case .success(let ids):
                pageIDs = ids
                if pagesFetched == 0 {
                    AppLogger.shared.info("ThumbnailMigration", "first_scan", metadata: [
                        "candidates": ids.count, "excluded": excluded.count
                    ])
                }
            case .failure(let failure):
                // 这里**不回退 SwiftData BLOB 谓词** —— 那条路径实测 +1.26 GB，
                // 而扫描失败最可能的时机（store 正忙）恰恰是最不该吃内存的时候。
                // 瘦身是空闲任务，晚一次启动做完没有任何代价。
                // `.unsupportedStore` 是永久状态（schema 保险丝烧了 = 整个瘦身功能失效），
                // 用 error 让监控看得见；`.transient` 只是这次忙，warning 即可。
                if failure == .unsupportedStore {
                    AppLogger.shared.error("ThumbnailMigration", "scan_candidates_unsupported", metadata: [
                        "migrated": migrated, "pagesFetched": pagesFetched
                    ])
                } else {
                    AppLogger.shared.warning("ThumbnailMigration", "scan_candidates_failed", metadata: [
                        "failure": "\(failure)", "migrated": migrated, "pagesFetched": pagesFetched
                    ])
                }
                // **跳出循环而不是 return** —— 两张表是独立的，项目表扫描失败不该
                // 把历史阶段一起连坐掉（`.unsupportedStore` 时那等于永久禁用）。
                break scanLoop
            }

            if pageIDs.isEmpty { break }   // 全库已经没有胖行 / 缺小图的行了

            pagesFetched += 1

            for candidate in pageIDs {
                guard !Task.isCancelled else {
                    AppLogger.shared.info("ThumbnailMigration", "cancelled_mid_page", metadata: [
                        "migrated": migrated, "pagesFetched": pagesFetched
                    ])
                    return
                }
                let projectId = candidate.id
                // 内容没变过的 stubborn 行直接跳过，连行都不用取。
                // （扫描器按 ID 排除是粗筛 —— 字节数变了说明用户换了图 / 备份恢复 /
                // CloudKit 同步来了新内容，那就该重新给它一次机会。）
                if Self.isStubborn(projectId, bytes: candidate.bytes) {
                    excluded.insert(projectId)
                    alreadyDone += 1
                    continue
                }
                // 预算逐行检查，且做**事前预留**：把即将处理的这行按 `candidate.bytes`
                //（扫描器报的压缩前行体量）预扣进去再比。压缩输出 ≤ 输入、小图回填只加
                // ~150KB，所以 candidate.bytes 是本行落盘量的可靠上界 —— 检查通过才动手，
                // 单行不会把预算冲破到未知量级。事后按实际值记账（compactOne 返回的整行大小）。
                if Self.throttleReason(bytesWrittenThisRun: bytesWritten + candidate.bytes)?.endsThisRun == true {
                    AppLogger.shared.info("ThumbnailMigration", "write_budget_reached_mid_page", metadata: [
                        "migrated": migrated, "bytesWritten": bytesWritten,
                        "nextRowBytes": candidate.bytes
                    ])
                    break scanLoop
                }
                let outcome = await Self.compactOne(projectId: projectId, container: container)
                // 无条件排除 —— 见上面 `excluded` 的注释，这是本轮的终止条件。
                // 放在 switch 之前，保证任何新增 outcome 分支都不会漏掉它。
                if outcome != .cancelled { excluded.insert(projectId) }

                switch outcome {
                case .migrated(let written, let filledDisplayThumbnail):
                    migrated += 1
                    bytesWritten += written
                    if filledDisplayThumbnail {
                        // 主线程侧只做纯内存 bookkeeping（Set insert），零 SwiftData I/O。
                        inventoryManager.noteProjectDisplayThumbnailMigrated(projectId: projectId)
                    }
                case .raceSkipped:
                    raceSkipped += 1
                case .alreadyDone:
                    alreadyDone += 1
                case .stubborn:
                    // 压不下去（比如本来就编码高效的大 PNG）。**落盘**跨启动排除，
                    // 否则每次启动都要把它重新解码一遍才发现压不动，纯烧电。
                    // 键带上当时的字节数 —— 内容一变就重新考虑。
                    Self.noteStubborn(projectId, bytes: candidate.bytes)
                case .failed:
                    failures += 1
                case .cancelled:
                    AppLogger.shared.info("ThumbnailMigration", "cancelled_during_compact_one", metadata: [
                        "projectId": projectId.uuidString, "migrated": migrated
                    ])
                    return
                }
            }

            // 页间 sleep —— 让出 UI，让 CloudKit 慢慢上传
            do {
                try await Task.sleep(nanoseconds: Self.batchSleepNanos)
            } catch {
                return  // cancelled
            }
        }

        AppLogger.shared.info("ThumbnailMigration", "completed", metadata: [
            "migrated": migrated,
            "raceSkipped": raceSkipped,
            "alreadyDone": alreadyDone,
            "failures": failures,
            "pagesFetched": pagesFetched,
            "bytesWritten": bytesWritten
        ])

        // 第二阶段：历史表。项目表瘦完了如果不管它，库照样是 GB 级 ——
        // 快照走 JSONEncoder，`Data` 被编成 base64（+33%），`.projectUpdate` 还会把
        // 同一份快照同时写进 before / after 两列，单条可达 ~34MB。
        await runHistoryPhase(storeURL: storeURL, container: container, bytesAlreadyWritten: bytesWritten)
    }

    private func runHistoryPhase(
        storeURL: URL,
        container: ModelContainer,
        bytesAlreadyWritten: Int
    ) async {
        var bytesWritten = bytesAlreadyWritten
        var compacted = 0
        var saved = 0
        var failures = 0
        var noOpSkipped = 0
        var raceOrCancelled = 0
        var historyThrottles = 0
        var excluded = Set<UUID>()

        historyLoop: while true {
            guard !Task.isCancelled else { return }
            // 闸门与项目阶段共用同一份写预算 —— 两个阶段加起来不超过单次 run 的上限。
            if let reason = Self.throttleReason(bytesWrittenThisRun: bytesWritten) {
                AppLogger.shared.info("ThumbnailMigration", "history_throttled", metadata: [
                    "reason": reason.rawValue, "compacted": compacted
                ])
                // 与项目阶段用同一条策略（见 ThrottleReason.endsThisRun）——
                // 以前这里把所有原因都当终止，瞬时发热会把整个历史阶段掐掉。
                if reason.endsThisRun { break historyLoop }
                historyThrottles += 1
                // **连续**计数：成功拿到一页就归零（见下）。原来只增不减，于是一个健康但
                // 偶尔遇到瞬时发热的历史阶段，累计 10 次非相邻闸门就退出了 ——
                // 而它比的是 maxConsecutiveThrottles。项目阶段一直是对的，这里漏了。
                if historyThrottles >= Self.maxConsecutiveThrottles { break historyLoop }
                do {
                    try await Task.sleep(nanoseconds: Self.throttledRetryNanos)
                } catch {
                    return
                }
                continue
            }

            let ids: [ProjectImageCompactionScanner.Candidate]
            switch await Self.scanHistoryCandidatesOffMain(
                storeURL: storeURL,
                limit: Self.batchSize,
                excluding: excluded
            ) {
            case .success(let scanned):
                ids = scanned
            case .failure(let failure):
                // 同项目阶段：**不**回退 SwiftData BLOB 查询。
                AppLogger.shared.warning("ThumbnailMigration", "history_scan_failed", metadata: [
                    "failure": "\(failure)", "compacted": compacted
                ])
                // 跳出循环而不是 return —— 否则下面的 history_completed 永远不记录，
                // 与它自己「无条件汇报」的注释矛盾。（裸 break 只跳出 switch。）
                break historyLoop
            }
            if ids.isEmpty { break historyLoop }
            historyThrottles = 0   // 成功拿到一页 = 闸门不再连续命中

            for candidate in ids {
                guard !Task.isCancelled else { return }
                let id = candidate.id
                // 无条件排除 —— 与项目阶段同理，扫描是按当前库状态重查而非游标翻页，
                // 处理完仍符合条件的行会让循环永不终止。
                excluded.insert(id)

                // 跨启动排除：一条含两张已经压到 ~1.2MB 图的 `.projectUpdate` 快照，
                // base64 之后约 3MB，**永久**高于扫描阈值，而里面每张图都低于阈值所以
                // `recompress` 全部正确 no-op。不记账的话它每次冷启动都被完整 JSON 解析
                // + base64 解码一遍，零写入 —— 最多 100 条 × 2 列，纯烧 CPU。
                if Self.isStubborn(id, bytes: candidate.bytes) {
                    noOpSkipped += 1
                    continue
                }
                // 事前预留，同项目阶段：candidate.bytes（两列压缩前之和）是本行落盘量上界。
                if Self.throttleReason(bytesWrittenThisRun: bytesWritten + candidate.bytes)?.endsThisRun == true {
                    AppLogger.shared.info("ThumbnailMigration", "history_write_budget_reached_mid_page", metadata: [
                        "compacted": compacted, "bytesWritten": bytesWritten,
                        "nextRowBytes": candidate.bytes
                    ])
                    break historyLoop
                }
                switch await Self.compactHistoryOne(recordId: id, container: container) {
                case .compacted(let bytesSaved, let written):
                    compacted += 1
                    saved += bytesSaved
                    bytesWritten += written
                case .noOp:
                    // 只有「真的一张图都不用动」才落盘记账，否则下次冷启动还要把这条
                    // 几十 MB 的快照完整解析一遍
                    Self.noteStubborn(id, bytes: candidate.bytes)
                    noOpSkipped += 1
                case .failed:
                    failures += 1
                case .skipped:
                    // 取消 / 竞态：**不**落盘。切一次后台就把正在处理的那条永久拉黑，
                    // 而处理最慢的恰恰是最大的那些。
                    raceOrCancelled += 1
                }
            }

            do {
                try await Task.sleep(nanoseconds: Self.batchSleepNanos)
            } catch {
                return
            }
        }

        // **无条件汇报。** 以前是 `if compacted > 0` —— 于是「历史表本来就干净」和
        // 「100 条全失败」产出完全相同的遥测（都是一片空白）。
        AppLogger.shared.info("ThumbnailMigration", "history_completed", metadata: [
            "compacted": compacted,
            "failures": failures,
            "noOpSkipped": noOpSkipped,
            "raceOrCancelled": raceOrCancelled,
            "bytesSaved": saved
        ])
    }

    /// 单条历史记录的快照瘦身。全程后台 context，理由同 `compactOne`。
    ///
    /// 撤回语义完全不变 —— 图片还在快照里，只是变小了。刻意**不**做「删掉老快照里的图」：
    /// `.projectDelete` 的快照是那张图删除之后的唯一拷贝，删了就是永久数据丢失。
    /// 单条历史记录的处理结果。
    ///
    /// 早期是 `(changed: Bool, failed: Bool, bytesSaved: Int, bytesWritten: Int)`，三个问题：
    ///   - 两个相邻 Bool 靠位置构造（八处 `return (false, true, 0, 0)` 之类），写反了不报错；
    ///   - `(changed: true, failed: true)` 这种无意义组合可以表示；
    ///   - 调用方是 `if changed / else if failed / else`，而 `else` 分支会**落盘永久拉黑**。
    ///     取消和 TOCTOU 竞态都落在那个 else 里 —— 用户切一次后台，正在处理的那条快照就被
    ///     永久排除（历史行 append-only，字节数不会再变，内容键控也救不回来），
    ///     而处理最慢、最容易被取消的恰恰是最大的那些。
    ///
    /// 改成枚举：非法组合不可表示；调用方是穷尽 `switch`，将来新增 outcome 是编译错误
    /// 而不是静默掉进「永久拉黑」。
    enum HistoryOutcome: Equatable {
        /// 真的写回了。`bytesWritten` 供写预算记账，`bytesSaved` 供遥测。
        case compacted(bytesSaved: Int, bytesWritten: Int)
        /// 扫描选中了它，但一张图都不用动 —— **只有这个** outcome 该落 stubborn 记账。
        case noOp
        /// fetch / save 抛错。下次启动重试。
        case failed
        /// 取消，或 TOCTOU 竞态。**不落盘**，下次重来。
        case skipped
    }

    nonisolated static func compactHistoryOne(
        recordId: UUID,
        container: ModelContainer
    ) async -> HistoryOutcome {
        let originalBefore: Data?
        let originalAfter: Data?
        do {
            var descriptor = FetchDescriptor<SDHistoryRecord>(
                predicate: #Predicate { $0.id == recordId }
            )
            descriptor.fetchLimit = 1
            descriptor.propertiesToFetch = [\.beforeSnapshot, \.afterSnapshot]
            let bg = ModelContext(container)
            guard let row = try bg.fetch(descriptor).first else { return .skipped }
            originalBefore = row.beforeSnapshot
            originalAfter = row.afterSnapshot
        } catch {
            AppLogger.shared.error("ThumbnailMigration", "history_fetch_failed", metadata: [
                "recordId": recordId.uuidString, "error": "\(error)"
            ])
            return .failed
        }

        guard !Task.isCancelled else { return .skipped }

        // 显式 autoreleasepool —— 与 `ProjectImageEncoder.recompress` 同理，而且这里更狠：
        // `HistorySnapshotCompactor.compact` 要把一个可达 34 MB 的快照 `JSONSerialization`
        // 成 autoreleased NSDictionary 树、逐张 base64 解码、再编码回去，每条调两次。
        // `recompress` 内部那个 pool 只盖住图片字节，盖不住 JSON 树和 base64 字符串
        //（而 base64 的 +33% 正是这个压缩器存在的理由）。
        var newBefore: HistorySnapshotCompactor.Result?
        autoreleasepool { newBefore = originalBefore.flatMap(HistorySnapshotCompactor.compact) }
        guard !Task.isCancelled else { return .skipped }
        var newAfter: HistorySnapshotCompactor.Result?
        autoreleasepool { newAfter = originalAfter.flatMap(HistorySnapshotCompactor.compact) }
        // afterSnapshot 的压缩可能长达数秒 —— stop() 落在这中间时，下面还有一次
        // fetch + save，不查取消就白做且顶着「用户已要求停止」写库（Codex round-2）。
        guard !Task.isCancelled else { return .skipped }
        // 一张图都不用动 —— 不是失败，调用方会据此落 stubborn 记账避免下次重新解析。
        //
        // 注意 `compact` 返回 nil 也包括「快照不是合法 JSON / 重编码失败」。这里**有意**
        // 不把它们与「真没图可压」区分开走 .failed：这些失败对同一份输入是确定性的
        //（JSONSerialization / ImageIO 对相同字节的行为可复现），走 .failed = 每次启动
        // 重新解析同一条几十 MB 的坏快照、永远失败 —— 纯烧 CPU。落 stubborn（内容键控）
        // 才是对确定性失败的正确处置；compact 内部已对这两类分别记了 error 日志，遥测可分。
        guard newBefore != nil || newAfter != nil else { return .noOp }

        var bytesSaved = 0
        var bytesWritten = 0
        do {
            var descriptor = FetchDescriptor<SDHistoryRecord>(
                predicate: #Predicate { $0.id == recordId }
            )
            descriptor.fetchLimit = 1
            descriptor.propertiesToFetch = [\.beforeSnapshot, \.afterSnapshot]
            let bg = ModelContext(container)
            guard let row = try bg.fetch(descriptor).first else { return .skipped }

            // TOCTOU：历史记录本身是 append-only 的，但撤回会改 isReverted、
            // trim 会删行，所以仍然按字段校验一次再写。
            if let newBefore, row.beforeSnapshot == originalBefore {
                row.beforeSnapshot = newBefore.data
                bytesSaved += newBefore.bytesSaved
            }
            if let newAfter, row.afterSnapshot == originalAfter {
                row.afterSnapshot = newAfter.data
                bytesSaved += newAfter.bytesSaved
            }
            // 两条 TOCTOU 都没通过 = 并发改动，不是 no-op，**不能**落盘拉黑
            guard bg.hasChanges else { return .skipped }
            try bg.save()

            // 预算记账按**整行**（两列保存后之和），与项目阶段同口径 —— 只算改动列会
            // 系统性低估（SQLite 重写整条记录，含没动的那一列）。
            bytesWritten = (row.beforeSnapshot?.count ?? 0) + (row.afterSnapshot?.count ?? 0)

            // 同 compactOne：压过了但行仍超扫描阈值（比如两列各剩 ~1.8MB）→ 落账，
            // 否则每次启动都重新解析。键的口径 = 历史扫描器的 sizeExpression（两列之和）。
            if bytesWritten > ProjectImageEncoder.compactionThresholdBytes {
                Self.noteStubborn(recordId, bytes: bytesWritten)
                AppLogger.shared.info("ThumbnailMigration", "history_compacted_but_still_over_threshold", metadata: [
                    "recordId": recordId.uuidString,
                    "rowBytes": bytesWritten
                ])
            }
        } catch {
            AppLogger.shared.error("ThumbnailMigration", "history_save_failed", metadata: [
                "recordId": recordId.uuidString, "error": "\(error)"
            ])
            return .failed
        }
        return .compacted(bytesSaved: bytesSaved, bytesWritten: bytesWritten)
    }

    enum MigrationOutcome: Equatable {
        /// 成功写回。`bytesWritten` 是本行新写入的图片字节总量（写预算记账用）；
        /// `filledDisplayThumbnail` 表示本次是否补上了列表小图（决定要不要通知主线程更新集合）。
        case migrated(bytesWritten: Int, filledDisplayThumbnail: Bool)
        case raceSkipped       // row 不存在 / thumbnail 已是 nil（候选列表之后被并发改动）
        case alreadyDone       // 已经够瘦且小图齐全（被 updateProjectThumbnail 抢先做了）
        case stubborn          // 试过了但压不下去 —— 落盘记账，以后不再考虑
        case failed            // fetch / 编码 / save 失败 —— 下次启动重试
        case cancelled         // 上层 stop() / scene background 触发 —— 不计 failures

        /// 断言便利 —— 调用方通常只关心「成没成」，不关心写了多少字节。
        var isMigrated: Bool {
            if case .migrated = self { return true }
            return false
        }
    }

    // MARK: - 测试接缝

    /// `compactOne` 内部是否踏上过主线程 —— 由 `compactOne` 自己写入。
    /// 采样点有两个：函数入口（赋值），和写回阶段（`if Thread.isMainThread` 置 true）——
    /// 只采入口的话，将来有人把 fetch/save 包进 `MainActor.run` 这种局部回归探测不到。
    ///
    /// 为什么需要它：`test_compactOne_never_touches_main_thread` 原本断言的是**测试体**
    /// 所在的线程（在调用 `compactOne` 之前），那是在测 XCTest 怎么调度异步测试，
    /// 不是在测被测代码。变异测试证实：把 `compactOne` 改回 MainActor 隔离，
    /// 两个守卫测试全绿 —— build-180 崩溃修复本身根本没被钉住。
    nonisolated(unsafe) static var lastCompactRanOnMainThreadForTesting: Bool?

    /// 编码完成、写回之前的钩子。**只有测试会设置它。**
    ///
    /// TOCTOU 校验同样是变异测试里存活下来的（删掉两个逐字段守卫全绿）：名字叫
    /// `..._when_thumbnail_changed_concurrently` 的那个测试在调用**之前**改库，
    /// 于是两次 fetch 读到相同字节，校验空转。要真正构造竞态就得能在这两次 fetch
    /// 中间插入写入。
    nonisolated(unsafe) static var didFinishEncodingForTesting: (@Sendable (UUID) async -> Void)?

    nonisolated static func resetTestSeams() {
        lastCompactRanOnMainThreadForTesting = nil
        didFinishEncodingForTesting = nil
    }

    /// 单个项目的瘦身 + 回填（**全程后台执行，禁止改回 @MainActor** —— build 180 watchdog 崩溃根因）。
    ///
    /// 1. 后台 ModelContext 单行投影取 thumbnail / finishedImage / displayThumbnail 现状
    /// 2. 三件事各自决定要不要做：
    ///    - thumbnail 超阈值 → `ProjectImageEncoder.recompress`
    ///    - finishedImage 超阈值 → 同上
    ///    - displayThumbnail 为 nil → `ImageDownsampler.downsample`（用**重编码后**的字节，
    ///      省一次大图解码）
    /// 3. 一件都不用做 → `.alreadyDone`；该做的都做了但一个都没成功变小 → `.stubborn`
    /// 4. **全新** ModelContext 重新 fetch 做 TOCTOU 校验（必须新 context —— 复用步骤 1 的
    ///    context 会命中 registered 对象的 stale 快照，看不到编码期间主 context 的并发 commit，
    ///    校验就成了空转）
    /// 5. 同一个新 context 上**一次性**写回全部改动 + 一次 save
    ///
    /// 第 5 步的「一次 save」是整轮修复的核心：三个图片字段都是 inline BLOB，SQLite 改行内
    /// 任何一列都要重写整条记录（含 overflow page）。分两次写就是把 13 MB 的行重写两遍。
    /// 合并之后胖行一生只被重写一次，且**写完就瘦了**。
    ///
    /// `internal` 而非 private：ThumbnailMigrationCoordinatorTests 直接钉语义。
    nonisolated static func compactOne(projectId: UUID, container: ModelContainer) async -> MigrationOutcome {
        // 从**函数体内部**记录线程 —— 这是 off-main 不变量唯一诚实的观测点。
        lastCompactRanOnMainThreadForTesting = Thread.isMainThread

        // 步骤 1：后台单行投影 fetch。
        // 三列一起取（峰值 = thumbnail + finishedImage），因为它们要合并成同一次 save；
        // 分开取会变成两次行重写，正是本轮要消灭的东西。patternGridData 不碰。
        let originalThumbnail: Data?
        let originalFinished: Data?
        let hasDisplayThumbnail: Bool
        do {
            var descriptor = FetchDescriptor<SDProjectRecord>(
                predicate: #Predicate { $0.id == projectId }
            )
            descriptor.fetchLimit = 1
            descriptor.propertiesToFetch = [\.thumbnail, \.finishedImage, \.displayThumbnail]
            let bg = ModelContext(container)
            guard let sd = try bg.fetch(descriptor).first else {
                return .raceSkipped  // row 被删
            }
            originalThumbnail = sd.thumbnail
            originalFinished = sd.finishedImage
            hasDisplayThumbnail = sd.displayThumbnail != nil
        } catch {
            AppLogger.shared.error("ThumbnailMigration", "fetch_failed", metadata: [
                "projectId": projectId.uuidString,
                "error": "\(error)"
            ])
            return .failed
        }

        guard !Task.isCancelled else { return .cancelled }

        // 步骤 2：算出这一行要写什么。nil = 该字段不动。
        var newThumbnail: Data?
        var newFinished: Data?
        var newDisplayThumbnail: Data?

        if let thumb = originalThumbnail {
            newThumbnail = ProjectImageEncoder.recompress(thumb)?.data
        }
        guard !Task.isCancelled else { return .cancelled }

        if let finished = originalFinished {
            newFinished = ProjectImageEncoder.recompress(finished)?.data
        }
        guard !Task.isCancelled else { return .cancelled }

        // 列表小图：用重编码后的字节生成（更小 → 解码更快），没重编码就用原字节。
        // 同 recompress，显式 pool —— downsample 内部也要建 CGImageSource / CGImage / UIImage。
        var displayThumbnailFailed = false
        if !hasDisplayThumbnail, let source = newThumbnail ?? originalThumbnail {
            autoreleasepool {
                newDisplayThumbnail = ImageDownsampler.downsample(source)
            }
            if newDisplayThumbnail == nil {
                // 字节坏掉 / 格式解不开。**不**阻断瘦身 —— 瘦身才是修崩溃的那一半，
                // 而且列表本来就有现场降级兜底。但要保留失败信号，见下面 return 分支。
                displayThumbnailFailed = true
                AppLogger.shared.error("ThumbnailMigration", "downsample_failed", metadata: [
                    "projectId": projectId.uuidString,
                    "sourceBytes": source.count
                ])
            }
        }

        guard newThumbnail != nil || newFinished != nil || newDisplayThumbnail != nil else {
            // 一件都没做成。三种情况要分开报，否则监控上无从 triage：
            let stillOversized =
                (originalThumbnail?.count ?? 0) > ProjectImageEncoder.compactionThresholdBytes
                || (originalFinished?.count ?? 0) > ProjectImageEncoder.compactionThresholdBytes

            if displayThumbnailFailed {
                // 想生成小图但字节解不开，且没有任何别的改动可写 —— 这是真失败。
                // （若重编码那半成功了则不会走到这里，那属于部分进展，算 .migrated。）
                return .failed
            }
            if stillOversized {
                // 行仍然超阈值，但 recompress 判定「压不下去」（比如本来就编码高效的大 PNG）。
                // 落盘排除，否则下一轮扫描又会选中它，每次启动白解码一遍。
                AppLogger.shared.info("ThumbnailMigration", "stubborn_row", metadata: [
                    "projectId": projectId.uuidString,
                    "thumbnailBytes": originalThumbnail?.count ?? 0,
                    "finishedBytes": originalFinished?.count ?? 0
                ])
                return .stubborn
            }
            // 行本来就是干净的：够瘦 + 小图齐全（或压根没有 thumbnail 可降）。
            return .alreadyDone
        }

        guard !Task.isCancelled else { return .cancelled }

        // 测试接缝：让测试能在「编码完成」和「写回校验」之间插入并发写入，
        // 从而真正构造 TOCTOU 竞态。生产环境恒为 nil。
        if let hook = didFinishEncodingForTesting {
            await hook(projectId)
        }

        // 步骤 4+5：TOCTOU 校验 + 一次性写回，同一个**全新** context 完成，
        // 保证「校验通过的就是被写的那一行状态」。
        var writtenBytes = 0
        do {
            var descriptor = FetchDescriptor<SDProjectRecord>(
                predicate: #Predicate { $0.id == projectId }
            )
            descriptor.fetchLimit = 1
            // patternGridData 只读不写 —— 拉进来是给预算记账用的：SQLite 重写整行时
            // 它同样要被重写，漏掉它预算就系统性偏低（Codex round-2 C2）。
            descriptor.propertiesToFetch = [\.thumbnail, \.finishedImage, \.displayThumbnail, \.patternGridData]
            let bg = ModelContext(container)
            guard let sd = try bg.fetch(descriptor).first else {
                return .raceSkipped
            }
            // 写回阶段也采样线程 —— 入口采样挡不住「将来有人把 fetch/save 包进
            // MainActor.run」这种局部回归（round-2 测试 agent 指出入口采样的盲区）。
            if Thread.isMainThread { lastCompactRanOnMainThreadForTesting = true }

            // **先把库里的现值抄下来再动手。** 下面会给 `sd.thumbnail` 赋新值，
            // 之后再拿 `sd.thumbnail` 去比 `originalThumbnail` 比的就是自己刚写的东西了。
            // （displayThumbnail 那条守卫最初就是这么写错的，集成测试当场变红。）
            let dbThumbnail = sd.thumbnail
            let dbFinished = sd.finishedImage
            let dbDisplayThumbnail = sd.displayThumbnail

            // 每个字段**独立**校验：用户在编码期间只换了封面图的话，成品图那半的工作
            // 仍然有效，不该一起丢掉。
            if let newThumbnail {
                guard dbThumbnail == originalThumbnail else {
                    AppLogger.shared.info("ThumbnailMigration", "race_thumbnail_changed_skip", metadata: [
                        "projectId": projectId.uuidString,
                        "oldBytes": originalThumbnail?.count ?? 0,
                        "newBytes": dbThumbnail?.count ?? 0
                    ])
                    return .raceSkipped
                }
                sd.thumbnail = newThumbnail
            }
            if let newFinished {
                guard dbFinished == originalFinished else {
                    AppLogger.shared.info("ThumbnailMigration", "race_finished_changed_skip", metadata: [
                        "projectId": projectId.uuidString
                    ])
                    return .raceSkipped
                }
                sd.finishedImage = newFinished
            }
            if let newDisplayThumbnail {
                // 两个条件缺一不可：
                //  - `displayThumbnail == nil`：被并发填了就不覆盖（对方拿的是更新的原图）
                //  - `thumbnail == originalThumbnail`：**小图是从它派生的**，源变了结果就作废
                //
                // 少了第二个条件会漏掉纯回填路径（`newThumbnail == nil`，即原图本来就够小，
                // 三条扫描谓词之一）：那条路径上没有任何对 `sd.thumbnail` 的校验。
                // 用户在编码窗口里删掉封面 → 我们把**已删除那张图**的小图写进一条
                // `thumbnail` 已是 nil 的行 → 列表永远显示删掉的封面，而且不自愈
                //（小图非 nil 了，扫描不再选它）。
                if dbDisplayThumbnail == nil, dbThumbnail == originalThumbnail {
                    sd.displayThumbnail = newDisplayThumbnail
                }
            }

            guard bg.hasChanges else { return .alreadyDone }
            // 不进 history（迁移不是用户操作）；revision bump 的取舍见
            // InventoryManager.noteProjectDisplayThumbnailMigrated 注释。
            try bg.save()

            // 写入记账按**整行**算，不是按「新写进去的那几个字段」。
            // SQLite 重写整条记录（含没改动的列），只算新字节会低估到预算失效。
            //
            // 两个口径，别混：
            //  - `scannerMetricBytes`（三个图片列之和）：**必须**与
            //    `ProjectImageCompactionScanner` 的 sizeExpression 逐字对应 —— stubborn
            //    键靠这个数字对得上，口径漂移 = 记账永远失配 = 拉黑失效。
            //  - `writtenBytes`（再加 patternGridData）：预算口径，整行重写的估算。
            let scannerMetricBytes = (sd.thumbnail?.count ?? 0)
                + (sd.finishedImage?.count ?? 0)
                + (sd.displayThumbnail?.count ?? 0)
            writtenBytes = scannerMetricBytes + (sd.patternGridData?.count ?? 0)

            // 瘦身**成功**但行仍超阈值（典型：thumbnail 是解不开的坏字节而 finishedImage
            // 压下来了）：不落账的话下一轮扫描会重新选中它 → **每次启动一次有损重编码**，
            // 画质逐次下降，写放大换了个触发器（Codex round-2 C1）。
            // 记到 stubborn（内容键控）—— 用户换图后字节数变化，自然重新考虑。
            let stillOver = (sd.thumbnail?.count ?? 0) > ProjectImageEncoder.compactionThresholdBytes
                || (sd.finishedImage?.count ?? 0) > ProjectImageEncoder.compactionThresholdBytes
            if stillOver {
                Self.noteStubborn(projectId, bytes: scannerMetricBytes)
                AppLogger.shared.info("ThumbnailMigration", "compacted_but_still_over_threshold", metadata: [
                    "projectId": projectId.uuidString,
                    "rowImageBytes": scannerMetricBytes
                ])
            }
        } catch {
            AppLogger.shared.error("ThumbnailMigration", "save_failed", metadata: [
                "projectId": projectId.uuidString,
                "error": "\(error)"
            ])
            return .failed
        }

        AppLogger.shared.info("ThumbnailMigration", "compacted_one", metadata: [
            "projectId": projectId.uuidString,
            "thumbnailBefore": originalThumbnail?.count ?? 0,
            "thumbnailAfter": newThumbnail?.count ?? originalThumbnail?.count ?? 0,
            "finishedBefore": originalFinished?.count ?? 0,
            "finishedAfter": newFinished?.count ?? originalFinished?.count ?? 0,
            "displayThumbnailFilled": newDisplayThumbnail != nil
        ])
        return .migrated(bytesWritten: writtenBytes, filledDisplayThumbnail: newDisplayThumbnail != nil)
    }
}
