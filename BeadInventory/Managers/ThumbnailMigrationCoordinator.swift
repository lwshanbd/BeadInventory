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
//  本协调器的工作：在 App 启动后空闲阶段，分批把**所有** `thumbnail != nil &&
//  displayThumbnail == nil` 的项目走 `ImageDownsampler.downsample` 生成 displayThumbnail 写回。
//  原 thumbnail 字段**完全不动**（拼图模式仍读全分辨率原图，数据零损失）。
//
//  迁移完成后：
//  - 列表 row 直接读 displayThumbnail（~50-100 KB JPEG，UIImage 解码内存峰值 MB 级）
//  - 详情大图 / 拼图模式继续读原 thumbnail（行为不变）
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

    /// 当前活跃 task 的 generation token。每次 start() bump，旧 task 的 defer 块拿着
    /// 自己的旧 generation 跟当前值比对：相等才允许清空状态。修复了 stop()+start() 之间
    /// 旧 task 误清新 task 状态的 race。
    private var currentGeneration: Int = 0
    private var isRunning: Bool = false
    private var task: Task<Void, Never>?

    private init() {}

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

        AppLogger.shared.info("ThumbnailMigration", "started", metadata: [:])

        var migrated = 0
        var raceSkipped = 0
        var alreadyDone = 0
        var failures = 0
        var pagesFetched = 0

        // **关键 jetsam 防护（round-10 review C1 修复 + round-11 review I1 starvation 修复）**：
        // 分页 fetch，**单次只取 `batchSize` 个 ID**。之前一次 `context.fetch` 把所有
        // `thumbnail != nil && displayThumbnail == nil` 的 SDProjectRecord 整 row 拉出来
        //（含 inline raw thumbnail Data），458 项目用户 × 5-10 MB = 2-5 GB 瞬时内存峰值
        // —— **修 jetsam 的协调器自己撞 jetsam**。
        //
        // 修法三点：
        //   1. `fetchLimit = batchSize`：单次只 fetch 10 个 row
        //   2. `propertiesToFetch = [\.id]`：单列投影，**只取 id 列**，不物化
        //      thumbnail / finishedImage / patternGridData 等 inline blob 字段
        //   3. **`fetchOffset = failedCarry`**：成功的 row 自然从谓词掉出，下一次 fetch
        //      offset=0 就跳过它们；**失败的 row 仍在谓词里**，offset 必须前进过它们才能
        //      访问后面的 candidate。否则 first page 全失败 → 下次 fetch 又返回同一批
        //      → page_no_progress_breaking break → 后面的几百个 valid candidate 永远
        //      不被试到（round-11 review I1 starvation）。
        //
        // offset 增量 = 本页失败数：因为成功 row 从谓词集合掉出，索引不变；失败 row 仍占位，
        // 下次 fetch offset=failedCarry 正好跳过它们。
        //
        // 终止：fetch 返空 = 已过完所有 candidate。失败的 row 留到下次 scenePhase .active
        // 时再重试（reset failedCarry）—— Sentry 上 downsample_failed / save_failed
        // 事件已能 triage 哪些是持久故障。
        var fetchOffset = 0

        while true {
            guard !Task.isCancelled else {
                AppLogger.shared.info("ThumbnailMigration", "cancelled_mid_run", metadata: [
                    "migrated": migrated,
                    "pagesFetched": pagesFetched
                ])
                return
            }

            let pageIDs: [UUID]
            do {
                // 后台 context 扫 candidate —— 即使是 id 单列投影，也不给主线程留同步 I/O。
                pageIDs = try await Self.fetchCandidatePage(
                    container: container,
                    offset: fetchOffset,
                    limit: Self.batchSize
                )
            } catch {
                AppLogger.shared.error("ThumbnailMigration", "fetch_candidates_failed", metadata: [
                    "error": "\(error)",
                    "migrated": migrated,
                    "pagesFetched": pagesFetched,
                    "fetchOffset": fetchOffset
                ])
                return
            }

            if pageIDs.isEmpty {
                // 所有候选都试过了（成功 / 失败 / race-skip / already-done）—— 完成本 run
                break
            }

            pagesFetched += 1
            var pageFailures = 0

            for projectId in pageIDs {
                guard !Task.isCancelled else {
                    AppLogger.shared.info("ThumbnailMigration", "cancelled_mid_page", metadata: [
                        "migrated": migrated,
                        "pagesFetched": pagesFetched
                    ])
                    return
                }
                let outcome = await Self.migrateOne(projectId: projectId, container: container)
                switch outcome {
                case .migrated:
                    migrated += 1
                    // 主线程侧只做纯内存 bookkeeping（Set insert），零 SwiftData I/O。
                    inventoryManager.noteProjectDisplayThumbnailMigrated(projectId: projectId)
                    // 成功 → 谓词集合缩小，offset 不前进，下次 fetch 自然拿到新的
                case .raceSkipped:
                    raceSkipped += 1
                    // .raceSkipped 通常意味着 thumbnail 被并发清掉 → row 不再符合谓词 → 同 .migrated
                case .alreadyDone:
                    alreadyDone += 1
                    // displayThumbnail 被并发填充 → row 不再符合谓词 → 同 .migrated
                case .failed:
                    failures += 1
                    pageFailures += 1   // **关键**：offset 前进过这些 row，才能访问后面 candidate
                case .cancelled:
                    AppLogger.shared.info("ThumbnailMigration", "cancelled_during_migrate_one", metadata: [
                        "projectId": projectId.uuidString,
                        "migrated": migrated
                    ])
                    return
                }
            }

            fetchOffset += pageFailures

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
            "pagesFetched": pagesFetched
        ])
    }

    enum MigrationOutcome {
        case migrated
        case raceSkipped       // row 不存在 / thumbnail 已是 nil（candidate 列表后被并发改动）
        case alreadyDone       // displayThumbnail 已经有值（被 updateProjectThumbnail 抢先填了）
        case failed            // fetch / downsample / save 失败 —— 留给下次重试
        case cancelled         // 上层 stop() / scene background 触发 —— 不计 failures
    }

    /// 分页扫描 candidate id —— `nonisolated`：Swift 5 语言模式下（SE-0338）脱离 MainActor
    /// 在 generic executor 上执行；用独立后台 ModelContext，主线程零 I/O。
    /// 结构化调用（非 detached）保证 Task.isCancelled / 取消传播仍随外层 run task。
    private nonisolated static func fetchCandidatePage(
        container: ModelContainer,
        offset: Int,
        limit: Int
    ) async throws -> [UUID] {
        let bg = ModelContext(container)
        var descriptor = FetchDescriptor<SDProjectRecord>(
            predicate: #Predicate { $0.thumbnail != nil && $0.displayThumbnail == nil }
        )
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset          // 跳过本 run 已经失败过的 row
        descriptor.propertiesToFetch = [\.id]    // 只取 id 列，不物化 blob
        return try bg.fetch(descriptor).map { $0.id }
    }

    /// 单个项目的迁移（**全程后台执行，禁止改回 @MainActor** —— build 180 watchdog 崩溃根因）：
    /// 1. 后台 ModelContext 单行投影取 thumbnail + displayThumbnail 现状
    /// 2. displayThumbnail 已被并发填充 → 跳过避免冗余 CloudKit 上传
    /// 3. downsample（已在后台 executor，直接同步调用，无需再 detached hop）
    /// 4. **全新** ModelContext 重新 fetch 验证 thumbnail 字节没变 + displayThumbnail 仍 nil
    ///    （TOCTOU；必须新 context —— 复用步骤 1 的 context 会命中 registered 对象的 stale
    ///    快照，看不到 downsample 期间主 context 的并发 commit，校验就成了空转）
    /// 5. 同一个新 context 上写回 displayThumbnail + save
    ///
    /// 总是 downsample —— 不再因 "原字节 < 200KB" 直接复用，因为一张 199KB 的 4000×4000 PNG
    /// 解码到 UIImage 仍能爆 60MB（重蹈 jetsam 根因）。
    ///
    /// `internal` 而非 private：ThumbnailMigrationCoordinatorTests 直接钉迁移语义。
    nonisolated static func migrateOne(projectId: UUID, container: ModelContainer) async -> MigrationOutcome {
        // 步骤 1+2：后台单行投影 fetch —— 只物化 thumbnail + displayThumbnail 两列，
        // 不碰同行的 finishedImage / patternGridData。
        let thumbnailData: Data
        do {
            var descriptor = FetchDescriptor<SDProjectRecord>(
                predicate: #Predicate { $0.id == projectId }
            )
            descriptor.fetchLimit = 1
            descriptor.propertiesToFetch = [\.thumbnail, \.displayThumbnail]
            let bg = ModelContext(container)
            guard let sd = try bg.fetch(descriptor).first else {
                return .raceSkipped  // row 被删
            }
            guard let thumb = sd.thumbnail else {
                return .raceSkipped  // thumbnail 被清
            }
            if sd.displayThumbnail != nil {
                return .alreadyDone  // 已被并发填
            }
            thumbnailData = thumb
        } catch {
            AppLogger.shared.error("ThumbnailMigration", "fetch_failed", metadata: [
                "projectId": projectId.uuidString,
                "error": "\(error)"
            ])
            return .failed
        }

        // downsample 前 check cancellation —— 避免 stop() 之后还烧一轮 CPU。
        guard !Task.isCancelled else { return .cancelled }

        // 步骤 3：downsample —— 本函数已在后台 executor，直接同步跑。
        guard let downsampled = ImageDownsampler.downsample(thumbnailData) else {
            AppLogger.shared.error("ThumbnailMigration", "downsample_failed", metadata: [
                "projectId": projectId.uuidString,
                "sourceBytes": thumbnailData.count
            ])
            return .failed
        }
        guard !Task.isCancelled else { return .cancelled }

        // 步骤 4+5：TOCTOU 校验 + 写回，同一个**全新** context 完成，保证「校验通过的
        // 就是被写的那一行状态」。投影仍只取两列；对部分物化对象写 displayThumbnail 不清
        // 其它 blob 列（InventoryManagerBlobFetchTests 已钉住该组合语义）。
        do {
            var descriptor = FetchDescriptor<SDProjectRecord>(
                predicate: #Predicate { $0.id == projectId }
            )
            descriptor.fetchLimit = 1
            descriptor.propertiesToFetch = [\.thumbnail, \.displayThumbnail]
            let bg = ModelContext(container)
            guard let sd = try bg.fetch(descriptor).first else {
                return .raceSkipped
            }
            guard let thumb = sd.thumbnail else {
                return .raceSkipped
            }
            if sd.displayThumbnail != nil {
                return .alreadyDone
            }
            if thumb != thumbnailData {
                // thumbnail 在 downsample 期间被替换 —— 我们的 downsampled 对应的是 OLD thumbnail
                AppLogger.shared.info("ThumbnailMigration", "race_thumbnail_changed_skip", metadata: [
                    "projectId": projectId.uuidString,
                    "oldBytes": thumbnailData.count,
                    "newBytes": thumb.count
                ])
                return .raceSkipped
            }

            // 写回。不进 history（迁移不是用户操作）；revision bump 的取舍见
            // InventoryManager.noteProjectDisplayThumbnailMigrated 注释。
            sd.displayThumbnail = downsampled
            try bg.save()
        } catch {
            AppLogger.shared.error("ThumbnailMigration", "save_failed", metadata: [
                "projectId": projectId.uuidString,
                "error": "\(error)"
            ])
            return .failed
        }

        AppLogger.shared.info("ThumbnailMigration", "migrated_one", metadata: [
            "projectId": projectId.uuidString,
            "sourceBytes": thumbnailData.count,
            "downsampledBytes": downsampled.count
        ])
        return .migrated
    }
}
