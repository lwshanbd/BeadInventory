//
//  LaunchDiagnostics.swift
//  BeadInventory
//
//  启动阶段的**跨启动**取证标记。
//
//  ## 它修的是什么
//
//  某用户在连续多轮修复后仍然启动崩溃,团队无法定位,最终卸载重装并丢失全部项目图片。
//  查不出来不是偶然,是结构性的 —— 现场根本不产生证据:
//
//    1. `AppLogger` 是异步缓冲的(8KB / 1.5s),崩得越早,落盘的越少;
//    2. 日志写在 `.cachesDirectory`,系统可在磁盘压力下清除,且不进设备备份;
//    3. 没有远程上报 —— 用户一卸载,唯一的证据永久消失。
//
//  最关键的是:**进程被看门狗或 jetsam 杀掉时,没有任何 in-process 手段能记录"我死了"。**
//  唯一可行的办法是跨启动:启动时落一个标记,正常走完就删掉;下次启动如果读到残留,
//  就知道上一次没走完,以及**最后成功落盘到哪个阶段**。
//
//  ## 语义边界(重要)
//
//  `phase` 的含义是 **「最后一次成功落盘的阶段」**,不是「确定死在这个阶段」。
//  两者的差别在排查时是实质性的:标记停在 `storeOpenBegin` 只能说明
//  「开库开始了,而开库结束没能落盘」—— 可能死在开库里,也可能死在开库之后、
//  下一次 `record` 之前。把它当成"死因定位"会把调查带偏。
//
//  ## 为什么不放在 UserDefaults / Caches
//
//  - UserDefaults 的落盘时机由系统决定,进程被杀时不保证已持久化。
//  - `.cachesDirectory` 会被系统清理(`AppLogger` 已经吃过这个亏)。
//
//  放 `Application Support/LaunchDiagnostics/`。已确认与删库兜底不冲突:
//  `BeadInventoryApp` 的重建路径只删 `default.store` 及其 `-wal` / `-shm`,不碰本目录。
//
//  ## 线程与依赖
//
//  全部同步、纯文件操作,**不依赖 SwiftData / ModelContainer / InventoryManager**。
//  这是刻意的:本类要在 `App.init()` 创建容器**之前**就能工作,将来的"无写入救援模式"
//  也要在不开库的前提下读它。任何对持久层的依赖都会让它失去这个能力。

import Foundation

/// 启动流程里的关键节点。顺序即时间顺序。
enum LaunchPhase: String, Codable {
    case processStart        // 进入 App.init(),尚未做任何重活
    case storeMetricsRead    // store / -wal / -shm 体积已读到(纯文件属性,未开库)
    case storeOpenBegin      // 即将创建 ModelContainer
    case storeOpenEnd        // ModelContainer 创建返回(成功或已进兜底链)
    case managersReady       // InventoryManager / HistoryManager 就绪,init 结束
    case firstFrameActive    // scenePhase 首次 .active
}

/// 一次启动的取证快照。
struct LaunchMarker: Codable {
    let launchID: UUID
    let build: String
    let startedAt: Date

    /// 最后一次**成功落盘**的阶段。见文件头「语义边界」。
    var phase: LaunchPhase

    /// 开库前读到的文件体积(字节)。nil = 尚未读到或文件不存在。
    var storeBytes: Int64?
    var walBytes: Int64?
    var shmBytes: Int64?

    /// `ModelContainer` 创建耗时(毫秒)。nil = 没走到那一步。
    var storeOpenMillis: Double?

    /// 本次进程是否由 **iOS 预热(prewarm)** 拉起。
    ///
    /// 预热会执行 `main()` / `App.init()`,但**可能永远不激活场景** —— 也就是永远不会
    /// 走到 `markLaunchCompleted()`。若不区分,每一次预热都会在下次启动被读成
    /// "上一次启动没走完",把真信号淹没在噪声里。一个会喊狼来了的量具比没有更糟。
    var wasPrewarm: Bool = false
}

enum LaunchDiagnostics {

    // MARK: - 路径

    private static let directoryName = "LaunchDiagnostics"
    private static let markerFileName = "launch_marker.json"

    private static var directoryURL: URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    private static var markerURL: URL? {
        directoryURL?.appendingPathComponent(markerFileName)
    }

    /// SwiftData 默认 store 的位置。**这里刻意不经过 ModelContainer** ——
    /// 本类要在容器创建之前就能读到体积,而拿容器的 `configurations.first?.url` 意味着
    /// 库已经开了,那时候再量已经晚了(开库本身就是嫌疑最大的一步)。
    ///
    /// ## 为什么先找 App Group 容器
    ///
    /// `ModelConfiguration` 的 `groupContainer` 参数**默认是 `.automatic`** ——
    /// App 声明了 App Group 权限(Share Extension 用的 `group.com.beadinventory.shared`)
    /// 时,SwiftData 会把 store 放进 **App Group 容器**,而不是 App 自己的
    /// Application Support。真机/模拟器实测确认:
    ///
    ///     Containers/Shared/AppGroup/<UUID>/Library/Application Support/default.store   533 MB
    ///     Containers/Data/Application/<UUID>/Library/Application Support/               (无 store)
    ///
    /// 查错地方的后果不是"少一个指标",而是**指标恒为 -1 且看起来像"库不存在"** ——
    /// 对一个专门用来定位启动问题的模块,这是最坏的失败形式(静默给出误导性数据)。
    ///
    /// 仍保留 App 自身目录作为兜底:未来若去掉 App Group 权限,`.automatic` 会退回那里。
    private static var defaultStoreURL: URL? {
        let appGroupID = SharedImageManager.appGroupIdentifier
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            let candidate = group
                .appendingPathComponent("Library/Application Support", isDirectory: true)
                .appendingPathComponent("default.store")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        return base.appendingPathComponent("default.store")
    }

    // MARK: - 读取上一次的残留

    /// 读取上一次启动留下的标记。
    ///
    /// **必须在 `begin()` 之前调用** —— `begin()` 会覆盖它。
    ///
    /// - Returns: 非 nil 表示上一次启动**没有走完**(正常结束会删除标记)。
    static func residualMarker() -> LaunchMarker? {
        guard let url = markerURL,
              let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(LaunchMarker.self, from: data)
        } catch {
            // 标记本身坏了(写到一半被杀 / 格式变更)。这本身就是"上次没走完"的证据,
            // 但结构化信息拿不到了。删掉避免它一直卡在这里,并留一条日志。
            AppLogger.shared.warning("LaunchDiagnostics", "residual_marker_undecodable", metadata: [
                "bytes": data.count,
                "error": "\(error)"
            ])
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    // MARK: - 本次启动

    private static var current: LaunchMarker?

    /// 本次进程是否由 iOS 预热拉起。
    ///
    /// `ActivePrewarm` 是系统在预热进程里设置的环境变量。它没有正式文档化的稳定性承诺,
    /// 所以这里只把它当作**降噪信号**用(决定残留该报 error 还是 warning),
    /// 不用它来跳过记录 —— 万一将来这个变量消失,最坏结果是恢复成"预热也记一条",
    /// 而不是"真崩溃不记了"。失效方向必须是安全的那一侧。
    static var isPrewarmLaunch: Bool {
        ProcessInfo.processInfo.environment["ActivePrewarm"] == "1"
    }

    /// 开始记录本次启动。会覆盖任何残留标记 —— 调用方须先取走 `residualMarker()`。
    static func begin(build: String) {
        var marker = LaunchMarker(
            launchID: UUID(),
            build: build,
            startedAt: Date(),
            phase: .processStart,
            wasPrewarm: isPrewarmLaunch
        )
        // 先建目录,失败就整体降级成 no-op(不能让取证代码本身崩掉启动)。
        guard let dir = directoryURL else { return }
        if !FileManager.default.fileExists(atPath: dir.path) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                AppLogger.shared.error("LaunchDiagnostics", "create_directory_failed", metadata: [
                    "error": "\(error)"
                ])
                return
            }
        }
        marker.phase = .processStart
        current = marker
        persist(marker)
    }

    /// 推进到下一个阶段并立即落盘。
    static func record(_ phase: LaunchPhase) {
        guard var marker = current else { return }
        marker.phase = phase
        current = marker
        persist(marker)
    }

    /// 记录开库前的文件体积。**纯 `attributesOfItem`,不开库,零成本。**
    ///
    /// 这三个数字是 H1(WAL 恢复耗时 ∝ WAL 大小)唯一便宜的证伪手段 ——
    /// 一个几百 MB 的 `-wal` 会当场坐实它。
    @discardableResult
    static func recordStoreMetrics() -> (store: Int64?, wal: Int64?, shm: Int64?) {
        let store = fileSize(defaultStoreURL)
        let wal = fileSize(defaultStoreURL.map { URL(fileURLWithPath: $0.path + "-wal") })
        let shm = fileSize(defaultStoreURL.map { URL(fileURLWithPath: $0.path + "-shm") })

        if var marker = current {
            marker.storeBytes = store
            marker.walBytes = wal
            marker.shmBytes = shm
            marker.phase = .storeMetricsRead
            current = marker
            persist(marker)
        }
        return (store, wal, shm)
    }

    /// 记录开库耗时。
    static func recordStoreOpenDuration(millis: Double) {
        guard var marker = current else { return }
        marker.storeOpenMillis = millis
        marker.phase = .storeOpenEnd
        current = marker
        persist(marker)
    }

    /// 本次启动已安全抵达可交互状态 —— 删除标记。
    ///
    /// 只有走到这里,下次启动才不会看到残留。
    static func markLaunchCompleted() {
        current = nil
        guard let url = markerURL else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            // 没有标记文件(begin 因目录创建失败降级成了 no-op)—— 不是错误。
        } catch {
            AppLogger.shared.warning("LaunchDiagnostics", "marker_removal_failed", metadata: [
                "error": "\(error)"
            ])
        }
    }

    // MARK: - 内部

    private static func persist(_ marker: LaunchMarker) {
        guard let url = markerURL else { return }
        do {
            let data = try JSONEncoder().encode(marker)
            // `.atomic` = 写临时文件 + rename,读者永远看不到写了一半的标记。
            try data.write(to: url, options: .atomic)
            // 再 fsync 一次。对「进程被 SIGKILL」其实 .atomic 已经够(字节在页缓存里,
            // 进程死亡不影响),这一步覆盖的是掉电 / panic。文件只有几百字节,代价可忽略。
            if let handle = try? FileHandle(forWritingTo: url) {
                try? handle.synchronize()
                try? handle.close()
            }
        } catch {
            AppLogger.shared.error("LaunchDiagnostics", "persist_failed", metadata: [
                "phase": marker.phase.rawValue,
                "error": "\(error)"
            ])
        }
    }

    private static func fileSize(_ url: URL?) -> Int64? {
        guard let url,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.int64Value
    }
}
