//
//  ThumbnailMigrationCoordinator.swift
//  BeadInventory
//
//  老项目数据的 displayThumbnail 后台分批生成 —— jetsam 修复的关键迁移路径。
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
//    `nonisolated` 后台函数里的独立 `ModelContext(container)` 上。此前 migrateOne 在
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

    /// 单次 run 的写入预算。瘦身一条 ≈ 一次行重写（重编码后的字节数，通常 < 1 MB），
    /// 300 MB 够覆盖几百条；超了就收工，下次启动接着跑。
    /// 存在的意义是**兜底**：万一某个假设错了（比如某类图重编码后反而变大），
    /// 预算保证单次启动的写入量有上限，不会重演 68 GB。
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
    ) async -> Result<[UUID], StoreScanFailure> {
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
    ) async -> Result<[UUID], StoreScanFailure> {
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

    nonisolated static func loadStubbornIDs() -> Set<UUID> {
        let raw = UserDefaults.standard.stringArray(forKey: stubbornDefaultsKey) ?? []
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    nonisolated static func noteStubborn(_ id: UUID) {
        var ids = loadStubbornIDs()
        guard ids.insert(id).inserted else { return }
        UserDefaults.standard.set(ids.map(\.uuidString), forKey: stubbornDefaultsKey)
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
            "stubbornCount": Self.loadStubbornIDs().count
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
        let stubborn = Self.loadStubbornIDs()
        var excluded = stubborn

        while true {
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
                if reason == .writeBudget || consecutiveThrottles >= Self.maxConsecutiveThrottles {
                    break
                }
                do {
                    try await Task.sleep(nanoseconds: Self.throttledRetryNanos)
                } catch {
                    return  // cancelled
                }
                continue
            }
            consecutiveThrottles = 0

            let pageIDs: [UUID]
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
                AppLogger.shared.warning("ThumbnailMigration", "scan_candidates_failed", metadata: [
                    "failure": "\(failure)", "migrated": migrated, "pagesFetched": pagesFetched
                ])
                return
            }

            if pageIDs.isEmpty { break }   // 全库已经没有胖行 / 缺小图的行了

            pagesFetched += 1

            for projectId in pageIDs {
                guard !Task.isCancelled else {
                    AppLogger.shared.info("ThumbnailMigration", "cancelled_mid_page", metadata: [
                        "migrated": migrated, "pagesFetched": pagesFetched
                    ])
                    return
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
                    Self.noteStubborn(projectId)
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
        var excluded = Set<UUID>()

        while true {
            guard !Task.isCancelled else { return }
            // 闸门与项目阶段共用同一份写预算 —— 两个阶段加起来不超过单次 run 的上限。
            if let reason = Self.throttleReason(bytesWrittenThisRun: bytesWritten) {
                AppLogger.shared.info("ThumbnailMigration", "history_throttled", metadata: [
                    "reason": reason.rawValue, "compacted": compacted
                ])
                break
            }

            let ids: [UUID]
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
                return
            }
            if ids.isEmpty { break }

            for id in ids {
                guard !Task.isCancelled else { return }
                // 无条件排除 —— 与项目阶段同理，扫描是按当前库状态重查而非游标翻页，
                // 处理完仍符合条件的行会让循环永不终止。
                excluded.insert(id)
                let result = await Self.compactHistoryOne(recordId: id, container: container)
                if result.changed {
                    compacted += 1
                    saved += result.bytesSaved
                    bytesWritten += max(0, result.bytesWritten)
                }
            }

            do {
                try await Task.sleep(nanoseconds: Self.batchSleepNanos)
            } catch {
                return
            }
        }

        if compacted > 0 {
            AppLogger.shared.info("ThumbnailMigration", "history_completed", metadata: [
                "compacted": compacted,
                "bytesSaved": saved
            ])
        }
    }

    /// 单条历史记录的快照瘦身。全程后台 context，理由同 `compactOne`。
    ///
    /// 撤回语义完全不变 —— 图片还在快照里，只是变小了。刻意**不**做「删掉老快照里的图」：
    /// `.projectDelete` 的快照是那张图删除之后的唯一拷贝，删了就是永久数据丢失。
    nonisolated static func compactHistoryOne(
        recordId: UUID,
        container: ModelContainer
    ) async -> (changed: Bool, bytesSaved: Int, bytesWritten: Int) {
        let originalBefore: Data?
        let originalAfter: Data?
        do {
            var descriptor = FetchDescriptor<SDHistoryRecord>(
                predicate: #Predicate { $0.id == recordId }
            )
            descriptor.fetchLimit = 1
            descriptor.propertiesToFetch = [\.beforeSnapshot, \.afterSnapshot]
            let bg = ModelContext(container)
            guard let row = try bg.fetch(descriptor).first else { return (false, 0, 0) }
            originalBefore = row.beforeSnapshot
            originalAfter = row.afterSnapshot
        } catch {
            AppLogger.shared.error("ThumbnailMigration", "history_fetch_failed", metadata: [
                "recordId": recordId.uuidString, "error": "\(error)"
            ])
            return (false, 0, 0)
        }

        guard !Task.isCancelled else { return (false, 0, 0) }

        let newBefore = originalBefore.flatMap(HistorySnapshotCompactor.compact)
        guard !Task.isCancelled else { return (false, 0, 0) }
        let newAfter = originalAfter.flatMap(HistorySnapshotCompactor.compact)
        guard newBefore != nil || newAfter != nil else { return (false, 0, 0) }

        var bytesSaved = 0
        var bytesWritten = 0
        do {
            var descriptor = FetchDescriptor<SDHistoryRecord>(
                predicate: #Predicate { $0.id == recordId }
            )
            descriptor.fetchLimit = 1
            descriptor.propertiesToFetch = [\.beforeSnapshot, \.afterSnapshot]
            let bg = ModelContext(container)
            guard let row = try bg.fetch(descriptor).first else { return (false, 0, 0) }

            // TOCTOU：历史记录本身是 append-only 的，但撤回会改 isReverted、
            // trim 会删行，所以仍然按字段校验一次再写。
            if let newBefore, row.beforeSnapshot == originalBefore {
                row.beforeSnapshot = newBefore.data
                bytesSaved += newBefore.bytesSaved
                bytesWritten += newBefore.data.count
            }
            if let newAfter, row.afterSnapshot == originalAfter {
                row.afterSnapshot = newAfter.data
                bytesSaved += newAfter.bytesSaved
                bytesWritten += newAfter.data.count
            }
            guard bg.hasChanges else { return (false, 0, 0) }
            try bg.save()
        } catch {
            AppLogger.shared.error("ThumbnailMigration", "history_save_failed", metadata: [
                "recordId": recordId.uuidString, "error": "\(error)"
            ])
            return (false, 0, 0)
        }
        return (true, bytesSaved, bytesWritten)
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

        // 步骤 4+5：TOCTOU 校验 + 一次性写回，同一个**全新** context 完成，
        // 保证「校验通过的就是被写的那一行状态」。
        var writtenBytes = 0
        do {
            var descriptor = FetchDescriptor<SDProjectRecord>(
                predicate: #Predicate { $0.id == projectId }
            )
            descriptor.fetchLimit = 1
            descriptor.propertiesToFetch = [\.thumbnail, \.finishedImage, \.displayThumbnail]
            let bg = ModelContext(container)
            guard let sd = try bg.fetch(descriptor).first else {
                return .raceSkipped
            }

            // 每个字段**独立**校验：用户在编码期间只换了封面图的话，成品图那半的工作
            // 仍然有效，不该一起丢掉。
            if let newThumbnail {
                guard sd.thumbnail == originalThumbnail else {
                    AppLogger.shared.info("ThumbnailMigration", "race_thumbnail_changed_skip", metadata: [
                        "projectId": projectId.uuidString,
                        "oldBytes": originalThumbnail?.count ?? 0,
                        "newBytes": sd.thumbnail?.count ?? 0
                    ])
                    return .raceSkipped
                }
                sd.thumbnail = newThumbnail
                writtenBytes += newThumbnail.count
            }
            if let newFinished {
                guard sd.finishedImage == originalFinished else {
                    AppLogger.shared.info("ThumbnailMigration", "race_finished_changed_skip", metadata: [
                        "projectId": projectId.uuidString
                    ])
                    return .raceSkipped
                }
                sd.finishedImage = newFinished
                writtenBytes += newFinished.count
            }
            if let newDisplayThumbnail {
                // 小图被并发填了就不覆盖 —— 对方（updateProjectThumbnail）拿的是更新的原图。
                if sd.displayThumbnail == nil {
                    sd.displayThumbnail = newDisplayThumbnail
                    writtenBytes += newDisplayThumbnail.count
                }
            }

            guard bg.hasChanges else { return .alreadyDone }
            // 不进 history（迁移不是用户操作）；revision bump 的取舍见
            // InventoryManager.noteProjectDisplayThumbnailMigrated 注释。
            try bg.save()
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
