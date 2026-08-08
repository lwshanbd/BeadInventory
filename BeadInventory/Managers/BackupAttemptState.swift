//
//  BackupAttemptState.swift
//  BeadInventory
//
//  每周自动备份的**尝试状态机**。跨启动持久化。
//
//  ## 它修的是什么
//
//  原实现只有一个「本周已备份」时间戳,而且写在**写盘成功之后**
//  (`BackupManager.performBackup` 的 `do` 块内)。后果是:
//
//      备份途中被杀 → 标记从未写入 → hasBackedUpThisWeek() 下次仍为 false
//        → 下次启动原样重来 → 再被杀 → …
//
//  这是一个**结构上无法自行退出的循环**。而备份恰恰是启动窗口里最重的一段
//  (主线程累积全库图片的 base64,实测 388 MB 图片 → 518 MB 字符串同时驻留,
//  主线程阻塞 3.14 秒),于是"最容易被杀的那段"和"被杀就无限重试的那段"是同一段。
//
//  ## 为什么不能只用一个布尔值 / 只把标记提前写
//
//  - **只把标记提前写**:等于崩溃当周直接放弃备份,用一次数据保护换循环中断,代价太大;
//    而且分不清"被杀"与"磁盘满"这类可恢复失败。
//  - **只用布尔值**:进程被 SIGKILL 时没有任何机会写"我是被中断的"。所以必须反过来 ——
//    **开工前落一条"进行中"记录,正常收尾时清掉**;下次启动读到残留,即可判定上次被中断。
//    这是唯一能在进程外观测到 SIGKILL 的手段。
//
//  ## 失败分类(关键)
//
//  只有**进程中断**才抑制。可恢复失败(用户取消 / 切后台 / 磁盘不足 / 序列化失败)
//  都清掉记录并允许后续重试 —— 否则一次磁盘满就会让用户永久失去自动备份。
//
//  抑制的粒度是**单周**,且一次**手动**备份成功即解除。两头都堵死:
//  既不会永久停备,也不会在下一次启动就又撞上同一段高危代码。
//
//  ## 线程与依赖
//
//  纯文件操作,不依赖 SwiftData / InventoryManager。原子写 + `synchronize()`。
//
//  注:这是本仓库第三处「原子写 + fsync 小 JSON」(另两处是 `LaunchDiagnostics` 与
//  `F1BenchmarkRecorder`)。等这批工作落定后值得抽一个共用小工具;现在不动
//  已验证过的那两处,避免为重构引入回归。

import Foundation

/// 一次备份尝试的结束原因。`nil`(记录残留)= 进程被中断。
enum BackupAttemptEndReason: String, Codable {
    case completed              // 正常完成
    case userCancelled          // 用户主动取消
    case backgrounded           // 切后台 / 非活跃,主动让出
    case lowDisk                // 磁盘不足
    case serializationFailed    // 序列化失败
}

/// 备份尝试记录。开工前落盘,收尾时清除。
struct BackupAttemptRecord: Codable {
    let attemptID: UUID
    /// 所属周 —— 抑制只作用于这一周。
    let weekKey: String
    let startedAt: Date
    /// 进行到哪一阶段(诊断用;判定"是否被中断"只看记录在不在)。
    var phase: String
}

/// 持久化的备份状态。
struct BackupState: Codable {
    /// 非 nil = 有一次尝试没有正常收尾。**下次启动读到它就说明上次被中断。**
    var inFlight: BackupAttemptRecord?
    /// 被抑制的周。该周不再自动备份。
    var suppressedWeekKey: String?
    /// 最近一次可恢复失败的原因(诊断用,不影响资格)。
    var lastDeferredReason: String?
}

enum BackupAttemptStore {

    // MARK: - 周标识

    /// `2026-W32` 形式。用 ISO 周,与 `hasBackedUpThisWeek` 的 `.weekOfYear` 口径一致。
    static func weekKey(for date: Date = Date(), calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        let year = comps.yearForWeekOfYear ?? 0
        let week = comps.weekOfYear ?? 0
        return String(format: "%04d-W%02d", year, week)
    }

    // MARK: - 读写

    private static var directoryURL: URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        return base.appendingPathComponent("BackupState", isDirectory: true)
    }

    private static var fileURL: URL? {
        directoryURL?.appendingPathComponent("attempt.json")
    }

    static func load() -> BackupState {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url) else { return BackupState() }
        do {
            return try JSONDecoder().decode(BackupState.self, from: data)
        } catch {
            // 记录本身坏了(写到一半被杀 / 格式变更)。这**本身就是"上次没走完"的证据**,
            // 但结构化信息拿不到了 —— 保守起见按"被中断"处理:抑制当周。
            AppLogger.shared.warning("BackupState", "state_undecodable_treating_as_interrupted", metadata: [
                "bytes": data.count, "error": "\(error)"
            ])
            return BackupState(inFlight: nil, suppressedWeekKey: weekKey(), lastDeferredReason: "undecodable")
        }
    }

    private static func save(_ state: BackupState) {
        guard let dir = directoryURL, let url = fileURL else { return }
        if !FileManager.default.fileExists(atPath: dir.path) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                AppLogger.shared.error("BackupState", "create_directory_failed", metadata: ["error": "\(error)"])
                return
            }
        }
        do {
            let data = try JSONEncoder().encode(state)
            // `.atomic` 保证读者不会看到写了一半的状态;fsync 覆盖掉电 / panic。
            // 对「进程被 SIGKILL」(本例的主要威胁)`.atomic` 本身已足够。
            try data.write(to: url, options: .atomic)
            if let handle = try? FileHandle(forWritingTo: url) {
                try? handle.synchronize()
                try? handle.close()
            }
        } catch {
            AppLogger.shared.error("BackupState", "persist_failed", metadata: ["error": "\(error)"])
        }
    }

    // MARK: - 生命周期

    /// 消费残留记录。**必须在资格判定之前调用一次。**
    ///
    /// 读到残留 = 上一次尝试没有正常收尾 = 进程被中断 → 抑制该记录所属的那一周。
    ///
    /// - Returns: 本次是否发现并处理了残留(供调用方记日志 / 弹提示)。
    @discardableResult
    static func consumeResidualIfNeeded() -> Bool {
        var state = load()
        guard let residual = state.inFlight else { return false }

        // 字段名用 `week` 而不是 `weekKey`：AppLogger 的脱敏规则会把含 "key" 的键值
        // 一律替换成 ***（防的是 API key），实测 weekKey 被打码 —— 而这恰恰是排查时
        // 最需要看的字段。规则本身是对的，改字段名。
        AppLogger.shared.error("BackupState", "previous_attempt_interrupted", metadata: [
            "attemptID": residual.attemptID.uuidString,
            "week": residual.weekKey,
            "phase": residual.phase,
            "startedAt": ISO8601DateFormatter().string(from: residual.startedAt)
        ])
        AppLogger.shared.flushNow()

        state.inFlight = nil
        // 只抑制**残留记录所属的那一周**,不是"当前这一周" —— 跨周之后不该继续背着
        // 上一周的失败。
        state.suppressedWeekKey = residual.weekKey
        state.lastDeferredReason = "interrupted"
        save(state)
        return true
    }

    /// 该周是否被抑制。
    static func isSuppressed(week: String = weekKey()) -> Bool {
        load().suppressedWeekKey == week
    }

    /// 开工。**必须在真正开始生成备份内容之前调用。**
    static func beginAttempt(week: String = weekKey(), phase: String = "start") {
        var state = load()
        state.inFlight = BackupAttemptRecord(
            attemptID: UUID(), weekKey: week, startedAt: Date(), phase: phase
        )
        save(state)
    }

    static func updatePhase(_ phase: String) {
        var state = load()
        guard state.inFlight != nil else { return }
        state.inFlight?.phase = phase
        save(state)
    }

    /// 收尾。
    ///
    /// **除 `completed` 外的原因都属可恢复失败** —— 清掉记录并允许后续重试,
    /// 不抑制。只有"记录残留"(即从未调用本方法)才判定为中断并抑制。
    static func finishAttempt(_ reason: BackupAttemptEndReason) {
        var state = load()
        state.inFlight = nil
        if reason != .completed {
            state.lastDeferredReason = reason.rawValue
            AppLogger.shared.warning("BackupState", "attempt_deferred", metadata: ["reason": reason.rawValue])
        }
        save(state)
    }

    /// 解除抑制。**仅在一次手动备份成功后调用** ——
    /// 手动成功意味着这台设备当前状态下备份是能跑完的,可以恢复自动。
    static func clearSuppression() {
        var state = load()
        guard state.suppressedWeekKey != nil else { return }
        state.suppressedWeekKey = nil
        state.lastDeferredReason = nil
        save(state)
        AppLogger.shared.info("BackupState", "suppression_cleared")
    }

    #if DEBUG || F1_BENCHMARK
    /// 实验复位:清空全部状态。
    static func resetForBenchmark() {
        save(BackupState())
    }
    #endif
}
