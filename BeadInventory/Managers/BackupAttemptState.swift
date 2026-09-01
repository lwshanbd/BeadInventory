//
//  BackupAttemptState.swift
//  BeadInventory
//
//  每周自动备份的**尝试状态机**。跨启动持久化。
//
//  ## 它修的是什么
//
//  原实现只有一个「本周已备份」时间戳,而且写在**写盘成功之后**
//  (`BackupManager` 的备份写出 `do` 块内)。后果是:
//
//      备份途中被杀 → 标记从未写入 → hasBackedUpThisWeek() 下次仍为 false
//        → 下次启动原样重来 → 再被杀 → …
//
//  这是一个**结构上无法自行退出的循环**。而备份**曾经**是启动窗口里最重的一段
//  (主线程累积全库图片的 base64),于是"最容易被杀的那段"和"被杀就无限重试的那段"
//  是同一段。改成流式写出后峰值已经平掉,但被 jetsam / 看门狗打断的可能性依然存在,
//  所以这个状态机保留。
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
//  注:本仓库另一处「原子写 + fsync 小 JSON」是 `RestoreJournal`。两处稳定下来之后
//  值得抽一个共用小工具;现在不动
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

    /// 见 `consumeResidualIfNeeded`。进程级一次性闸。
    @MainActor private static var didConsumeResidualThisLaunch = false

    static func load() -> BackupState {
        guard let url = fileURL else {
            AppLogger.shared.error("BackupState", "state_location_unavailable")
            return interruptedFallback(reason: "noLocation")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            // 首次运行,正常。
            //
            // **两个 code 都要认**：`Data(contentsOf:)` 对不存在的文件抛的是
            // `fileReadNoSuchFile`(260) 而不是 `fileNoSuchFile`(4)。只认后者的话，
            // 每一次全新安装都会走进下面的"读不出来"分支、被抑制掉当周备份 ——
            // 模拟器上第一次跑就撞到了。
            return BackupState()
        } catch {
            // **读失败不能和"文件不存在"压成同一个结果。** 前者（权限 / IO / 数据保护
            // 未解锁）返回空状态的话,残留就看不见了 —— 而这个文件存在的唯一理由
            // 就是让残留可见。按被中断处理。
            AppLogger.shared.error("BackupState", "state_unreadable_treating_as_interrupted", metadata: [
                "error": "\(error)"
            ])
            return interruptedFallback(reason: "unreadable")
        }
        do {
            return try JSONDecoder().decode(BackupState.self, from: data)
        } catch {
            // 记录本身坏了(写到一半被杀 / 格式变更)。这**本身就是"上次没走完"的证据**,
            // 但结构化信息拿不到了 —— 保守起见按"被中断"处理:抑制当周。
            AppLogger.shared.warning("BackupState", "state_undecodable_treating_as_interrupted", metadata: [
                "bytes": data.count, "error": "\(error)"
            ])
            return interruptedFallback(reason: "undecodable")
        }
    }

    /// 状态读不出来时的兜底：按"上次被中断"处理,抑制当周。
    ///
    /// **必须把兜底状态写回盘**。否则损坏的文件永远不会被修复,而 `load()` 每次都会
    /// 用**当时**的 `weekKey()` 重新合成一份抑制 —— 下一周再来一次,抑制就从"单周"
    /// 变成了永久,自动备份再也不会跑,而横幅还在说"上次自动备份被中断"。
    /// 写回之后,这一周过去抑制就自然失效。
    private static func interruptedFallback(reason: String) -> BackupState {
        let repaired = BackupState(inFlight: nil, suppressedWeekKey: weekKey(), lastDeferredReason: reason)
        save(repaired)
        return repaired
    }

    /// - Returns: 是否确实落盘。**调用方在"哨兵必须先在盘上"的场景要检查它** ——
    ///   见 `beginAttempt`。
    @discardableResult
    private static func save(_ state: BackupState) -> Bool {
        guard let dir = directoryURL, let url = fileURL else {
            AppLogger.shared.error("BackupState", "state_location_unavailable_on_save")
            return false
        }
        if !FileManager.default.fileExists(atPath: dir.path) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                AppLogger.shared.error("BackupState", "create_directory_failed", metadata: ["error": "\(error)"])
                return false
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
            return true
        } catch {
            AppLogger.shared.error("BackupState", "persist_failed", metadata: ["error": "\(error)"])
            return false
        }
    }

    // MARK: - 生命周期

    /// 消费残留记录。**必须在资格判定之前调用一次。**
    ///
    /// 读到残留 = 上一次尝试没有正常收尾 = 进程被中断 → 抑制该记录所属的那一周。
    ///
    /// - Returns: 本次是否发现并处理了残留(供调用方记日志 / 弹提示)。
    /// `@MainActor`：本方法带一个进程级一次性闸（见下），靠主 actor 串行化，
    /// 不另引入锁。唯一调用方 `checkAndPerformWeeklyBackupIfNeeded` 本来就在主 actor 上。
    @MainActor
    @discardableResult
    static func consumeResidualIfNeeded() -> Bool {
        // **本进程只消费一次。** 根视图 onAppear 可能重入,若此时本进程自己的备份
        // 正在写(inFlight 是我们刚写的),第二次调用会把它当成"上次被杀"的残留,
        // 于是错误地抑制整整一周。残留判定只对"启动时盘上已有的记录"成立。
        guard !didConsumeResidualThisLaunch else { return false }
        didConsumeResidualThisLaunch = true

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
    ///
    /// - Returns: 哨兵是否确实落盘。**落不下去调用方就该放弃本次备份** ——
    ///   哨兵不在盘上,进程被杀后下次启动读不到残留,于是不抑制、原样重来,
    ///   正是本文件要打断的那个循环。而磁盘将满既是哨兵写失败的原因、
    ///   也是备份被杀的原因,两者高度相关。放弃一次备份 ≪ 无限崩溃循环。
    @discardableResult
    static func beginAttempt(week: String = weekKey(), phase: String = "start") -> Bool {
        var state = load()
        state.inFlight = BackupAttemptRecord(
            attemptID: UUID(), weekKey: week, startedAt: Date(), phase: phase
        )
        return save(state)
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
