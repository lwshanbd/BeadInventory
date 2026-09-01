//
//  BackupManager.swift
//  BeadInventory
//
//  自动备份管理器 - 每周首次打开时自动备份数据
//

import Foundation

class BackupManager {
    static let shared = BackupManager()

    private let lastBackupDateKey = "lastWeeklyBackupDate"
    private let backupFolderName = "WeeklyBackups"
    private let maxBackupCount = 8  // 最多保留8个备份（约2个月）

    /// 在飞的自动备份任务。持有它才能取消 —— 原实现是 fire-and-forget。
    @MainActor private var backupTask: Task<Void, Never>?

    /// 归档写出是否正在进行（**手动与自动共用**）。
    ///
    /// `backupTask` 只跟踪自动备份 —— 手动备份从 `BackupRestoreView` 直接调
    /// `performArchiveBackup`，从不赋给它。于是两者可以并发，而它们共用
    /// `BackupAttemptStore` 里**唯一一个** `inFlight` 槽：后开始的会覆盖先开始的记录，
    /// 先结束的会把后者的哨兵清掉。此时若进程被 SIGKILL，就不留残留 ——
    /// `BackupAttemptState` 赖以成立的"记录残留 = 上次被中断"再次失效。
    /// 两者还会在同一秒撞上同名 `.partial`（`generateArchiveName` 是秒精度），
    /// 后者开头的"删同名 partial"会删掉前者正在写的目录。
    ///
    /// 这个标志把两条路径收进同一道闸。它在 MainActor 上读写，而
    /// `performArchiveBackup` 的挂起点都在 `write` 内部 —— 进入时置位、`defer` 清除，
    /// 足以排除重入。
    @MainActor private var archiveWriteInFlight = false

    /// 本周自动备份是否已被抑制（上次尝试被进程中断）。供 UI 提示"可手动备份恢复"。
    @MainActor private(set) var isAutomaticBackupSuppressed = false

    private init() {}

    // MARK: - 备份目录

    private var backupDirectory: URL? {
        guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let backupDir = documentsDirectory.appendingPathComponent(backupFolderName)

        // 确保目录存在
        if !FileManager.default.fileExists(atPath: backupDir.path) {
            try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        }

        return backupDir
    }

    // MARK: - 周检查

    /// 本周是否已完成过备份（标记在写盘成功后才更新，见 performArchiveBackup）。
    private func hasBackedUpThisWeek(now: Date = Date()) -> Bool {
        guard let lastBackupDate = UserDefaults.standard.object(forKey: lastBackupDateKey) as? Date else {
            return false
        }
        return Calendar.current.isDate(now, equalTo: lastBackupDate, toGranularity: .weekOfYear)
    }

    /// 检查是否需要进行每周备份。
    ///
    /// 备份阶段会逐项目从 SwiftData 取图写进归档。取图在 `ProjectImageLoader`（后台 actor）
    /// 上做，主线程只出一次 blob-free 的 metadata 快照。
    /// 在 cold-start 的 onAppear 同步路径里跑这玩意儿可能撞 scene-create watchdog，
    /// 所以把执行延后一个 tick + 5s、走 Task：让首屏先 commit，避免首帧渲染期间被卡。
    @MainActor func checkAndPerformWeeklyBackupIfNeeded(inventoryManager: InventoryManager) {
        // ① 先消费残留尝试记录。**必须在资格判定之前** —— 残留即上次被中断，
        //    据此抑制那一周，避免"最容易被杀的那段"每次启动都重来一遍。
        if BackupAttemptStore.consumeResidualIfNeeded() {
            isAutomaticBackupSuppressed = true
        }

        // ①' 上次恢复没跑完 → 不备份。
        //    此时库处于"metadata 是新的、图只写了一部分"的半恢复状态，把它备下来
        //    等于把半损坏当成正常快照留档，还会挤掉真备份的槽位。
        //    用户在备份页点「重新恢复」把它跑完，日志清掉之后自动备份自然恢复。
        if let residual = RestoreJournal.residual() {
            AppLogger.shared.warning("BackupManager", "automatic_backup_skipped_restore_residual", metadata: [
                "archive": (residual.archivePath as NSString).lastPathComponent
            ])
            return
        }

        // ② 被抑制的周直接跳过。解除条件是一次**手动**备份成功。
        let week = BackupAttemptStore.weekKey()
        if BackupAttemptStore.isSuppressed(week: week) {
            isAutomaticBackupSuppressed = true
            // 键名避开 "key" —— AppLogger 会把含该子串的值脱敏成 ***（见 BackupAttemptState）。
            AppLogger.shared.warning("BackupManager", "automatic_backup_suppressed", metadata: ["week": week])
            print("[BackupManager] 本周自动备份已暂停（上次尝试被中断），可手动备份恢复")
            return
        }

        if hasBackedUpThisWeek() {
            print("[BackupManager] 本周已备份，跳过")
            return
        }

        // 重入保护：onAppear 可能多次触发，别起多个任务互相抢。
        guard backupTask == nil else { return }

        // 推迟到下一次 runloop tick：让首屏 scene-create commit 先完成。
        // 注意：备份仍然要在 MainActor 上跑（SwiftData mainContext 限定主线程），
        // 但它不会再卡在第一帧 commit 里 —— iOS watchdog 不会因此再 0x8BADF00D。
        //
        // 再延后 5s：备份仍要读盘、写盘、算校验和，跟启动后紧接着的 initial load /
        // 首次用户交互挤在同一窗口会明显掉帧。（这条延后原本是为了躲主线程 base64，
        // 那条路径已经没了；理由换成避开启动窗口，结论不变。）
        //
        // **任务现在被持有且可取消**（原来是 fire-and-forget，scenePhase 的
        // .background / .inactive 分支只 stop 了迁移器，对备份一个字都没管 ——
        // 于是这段主线程重活会一路跑到系统挂起，正是最容易被杀的形态）。
        backupTask = Task { @MainActor [weak self] in
            defer { self?.backupTask = nil }
            // 取消 = 跳过本次备份（标记未写，下次启动重试）。
            // 不能用 try?：取消时 sleep 立即抛错，吞掉后 performArchiveBackup 会在 t≈0 无延迟执行，
            // 恰好落回 5s 想避开的启动窗口 —— 取消语义整个反转。
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            // sleep 后复查资格：同一窗口内的重复调用串行到这里时，
            // 第一个已完成备份并写了标记，后续直接跳过，保证幂等。
            guard !self.hasBackedUpThisWeek() else { return }
            guard !BackupAttemptStore.isSuppressed(week: week) else { return }

            // **等待初始加载，而不是跳过。**
            //
            // `performArchiveBackup` 会拒绝对未加载完成的状态拍快照（否则可能写出空归档），
            // 但这个函数**只从 `.onAppear` 调一次**，没有重试也没有 `.active` 上的补调。
            // 直接 return 的话，初始加载稳定超过 5 秒的大库用户会每次启动都在这里止步，
            // `lastWeeklyBackupDate` 从不写入所以资格检查一直通过，于是
            // **自动备份对他们永久失效，且没有任何提示** —— 而库越大越容易踩中，
            // 恰好是最输不起的那批用户。
            guard await self.waitForInitialLoad(inventoryManager) else {
                // **不置 `isAutomaticBackupSuppressed`。** 这里什么都没被抑制 ——
                // 标记没写，下次启动会正常重试。置位的话备份页会显示
                // 「上次自动备份被中断，本周已暂停自动备份」，与事实相反。
                AppLogger.shared.warning("BackupManager", "archive_backup_deferred_load_timeout")
                return
            }
            await self.performArchiveBackup(inventoryManager: inventoryManager)
        }
    }

    /// 有界地等待初始加载完成。
    ///
    /// - Returns: `true` = 可以拍快照；`false` = 超时或处于本地回退模式，本次放弃。
    ///
    /// 轮询而非订阅：`hasCompletedInitialLoad` 是计算属性、没有可等待的信号，
    /// 而这条路径每次启动最多跑一遍，2 秒一次的代价可以忽略。
    @MainActor
    private func waitForInitialLoad(
        _ manager: InventoryManager, timeout: TimeInterval = 60
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            // 回退模式下的内存状态不可信，等下去也不会变好 —— 直接放弃本次。
            if manager.isUsingLocalFallbackMode { return false }
            if manager.hasCompletedInitialLoad { return true }
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return false   // 取消
            }
        }
        return false
    }

    /// 生产路径的备份 —— 走流式归档写出器。
    ///
    /// 与被它取代的 JSON 路径的差别:
    ///
    ///     峰值内存     随项目数线性增长 → 与项目总数无关（受单个项目的 blob 总量约束）
    ///     产出体积     省掉 base64 白付的 +33%
    ///     patternGrid  丢失 → 保住（旧格式压根没写这个字段）
    ///     partsSheet   保住（旧 JSON 有，新格式初版漏了，见 BackupArchive 的格式定义）
    ///
    /// 图片经 `ProjectImageLoader` 逐项目取(单次 fetch,同一事务视图),写完即释放,
    /// 主线程只做一次 blob-free 的 metadata 快照。
    ///
    /// 峰值受**单个项目的 blob 总量**约束,不是"单张图" —— 逐记录一致要求一次取回
    /// 该项目的全部 blob。关键是它**不随项目总数增长**,那才是病灶形状。
    @discardableResult
    @MainActor func performArchiveBackup(
        inventoryManager: InventoryManager, isManual: Bool = false
    ) async -> Bool {
        guard let backupDir = backupDirectory else {
            AppLogger.shared.error("BackupManager", "archive_backup_no_directory")
            return false
        }
        guard let loader = inventoryManager.imageLoader else {
            AppLogger.shared.error("BackupManager", "archive_backup_no_image_loader")
            return false
        }

        // 手动与自动共用这道闸 —— 见 `archiveWriteInFlight` 的说明。
        guard !archiveWriteInFlight else {
            AppLogger.shared.warning("BackupManager", "archive_backup_rejected_concurrent", metadata: [
                "isManual": isManual
            ])
            print("[BackupManager] 已有备份在进行中，跳过本次")
            return false
        }

        // **不能对一个还没加载好、或明知不可信的内存状态拍快照。**
        //
        // 具体事故形状：库损坏 → `BeadInventoryApp.init` 落到重置或内存分支 → App 以空库打开。
        // `lastWeeklyBackupDate` 存在 UserDefaults 里，不随 store 重置消失，所以若已跨周，
        // 自动备份会在 t+5s 触发，`projects` 为空，写出一个**完全合法的 0 项目归档**，
        // 然后 `cleanupOldBackups()` 按时间降序把最老的那个**真备份**删掉。
        // 同一次启动既丢了数据，又销毁了恢复材料；每周重复，八个槽位全变空档。
        //
        // 冷启动时初始加载没在 5 秒内跑完、以及本地回退模式，都是同一类不可信状态。
        guard inventoryManager.hasCompletedInitialLoad else {
            AppLogger.shared.warning("BackupManager", "archive_backup_deferred_not_loaded")
            print("[BackupManager] 初始加载未完成，跳过本次备份")
            return false
        }
        guard !inventoryManager.isUsingLocalFallbackMode else {
            AppLogger.shared.warning("BackupManager", "archive_backup_deferred_local_fallback")
            print("[BackupManager] 本地回退模式，跳过本次备份")
            return false
        }
        // 加载完成但一件东西都没有：可能是新装用户（合法），也可能是刚被重置的损坏库。
        // 区分不了，所以看盘上有没有**非空**的既有备份 —— 有的话，这次空快照不该覆盖它们。
        // 新装用户没有既有备份，因此不受影响。
        //
        // 只挡自动备份：手动点「立即备份」是用户的明确意图（比如他确实清空了库并想留档），
        // 替他否决没有道理。自动备份没有这种意图信号，只能保守。
        //
        // "空"必须覆盖**全部**持久化集合。上一版只看 projects + brands，于是一个只有
        // 自定义颜色（或只有进货记录）的用户不受保护 —— 他的库同样会被判成空、
        // 同样会写出空归档挤掉真备份。
        let snapshotIsEmpty = inventoryManager.projects.isEmpty
            && inventoryManager.brands.isEmpty
            && inventoryManager.brandStocks.isEmpty
            && inventoryManager.customColors.isEmpty
            && inventoryManager.purchaseRecords.isEmpty
        if !isManual && snapshotIsEmpty && hasNonEmptyExistingBackup() {
            AppLogger.shared.warning("BackupManager", "archive_backup_refused_empty_snapshot")
            print("[BackupManager] 当前数据为空但已有非空备份，拒绝写出空归档")
            return false
        }

        // 闸在 beginAttempt 之前合上、函数退出时打开 —— 覆盖整个哨兵生命周期。
        archiveWriteInFlight = true
        defer { archiveWriteInFlight = false }

        // 开工记录：**必须在任何重活之前落盘**。进程被 SIGKILL 时没机会写"我被中断了"，
        // 只能反过来：先落"进行中"，正常收尾清掉；下次启动读到残留即判定中断。
        // 哨兵落不下去就放弃本次备份 —— 见 `beginAttempt` 的返回值说明。
        guard BackupAttemptStore.beginAttempt() else {
            AppLogger.shared.error("BackupManager", "archive_backup_aborted_no_sentinel")
            print("[BackupManager] 无法记录备份哨兵，跳过本次备份")
            return false
        }


        // 主线程只取 blob-free 的 metadata 快照（projects 缓存本来就不带 blob）。
        let snapshot = BackupArchiveWriter.MetadataSnapshot(
            projects: inventoryManager.projects,
            brands: inventoryManager.brands,
            brandStocks: inventoryManager.brandStocks,
            customColors: inventoryManager.customColors,
            purchaseRecords: inventoryManager.purchaseRecords,
            currentBrandId: inventoryManager.currentBrandId,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        )

        do {
            let url = try await BackupArchiveWriter.write(
                snapshot: snapshot, imageLoader: loader,
                to: backupDir, archiveName: generateArchiveName(),
                onPhase: { BackupAttemptStore.updatePhase($0) }
            )
            UserDefaults.standard.set(Date(), forKey: lastBackupDateKey)
            BackupAttemptStore.finishAttempt(.completed)

            // 手动备份成功 = 这台设备当前状态下备份跑得完 → 解除抑制。
            // 这是抑制的**唯一**主动解除路径（自动备份被抑制时压根不运行，
            // 所以它自己的成功无法解除）；此外还有跨周自然失效。
            if isManual {
                BackupAttemptStore.clearSuppression()
                isAutomaticBackupSuppressed = false
            }

            cleanupOldBackups()
            AppLogger.shared.info("BackupManager", "archive_backup_completed", metadata: [
                "name": url.lastPathComponent
            ])
            return true
        } catch {
            // 取消属可恢复失败（用户切后台），与磁盘/IO 失败一样不触发抑制 ——
            // 只有"记录残留、从未收尾"才判定为进程中断。
            let reason: BackupAttemptEndReason =
                (error as? BackupArchiveWriter.WriteError).map {
                    if case .cancelled = $0 { return .backgrounded } else { return .lowDisk }
                } ?? .lowDisk
            BackupAttemptStore.finishAttempt(reason)
            AppLogger.shared.error("BackupManager", "archive_backup_failed", metadata: [
                "error": "\(error)"
            ])
            return false
        }
    }

    /// 归档目录名。不含扩展名 —— 由写出器补 `.beadbackup`。
    private func generateArchiveName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "backup_\(f.string(from: Date()))"
    }

    /// 请求取消在飞的自动备份。App 进入 `.inactive` / `.background` 时调用。
    ///
    /// 与 `ThumbnailMigrationCoordinator.stop()` 对齐 —— 之前只有迁移器被停，备份却没人管。
    ///
    /// **这里只发取消请求，不碰尝试记录、也不清 `backupTask`。**
    ///
    /// 原来这三件事一起做，那是错的：`cancel()` 是协作式的，写出器只在下一个项目迭代
    /// 开头才观察到取消（`BackupArchiveWriter.write` 里的 `Task.isCancelled`），
    /// 所以 `stop()` 返回时写入**仍在进行**。而这段窗口正是 App 挂起期间 —— jetsam
    /// 最可能下手的时刻。记录如果此时已被清掉，进程被 SIGKILL 就不留残留，
    /// `consumeResidualIfNeeded()` 什么也读不到，
    /// **`BackupAttemptState` 赖以成立的那条不变量（"记录残留 = 上次被中断"）当场失效。**
    ///
    /// 收尾交给任务自己：正常结束走 `.completed`，抛错走 catch 里的 `finishAttempt`
    /// （取消映射为 `.backgrounded`，属可恢复失败、不触发抑制）。
    /// `backupTask` 由任务体的 `defer` 清空 —— 那才是它真正结束的时刻，
    /// 提前清会让下一次 `checkAndPerformWeeklyBackupIfNeeded` 越过重入保护。
    ///
    /// 另注：`stop()` 可能在 5 秒 sleep 期间被调用，那时 `beginAttempt()` 还没执行；
    /// 此时本来就没有记录可收尾，由任务自己 `return` 即可。
    @MainActor func stop() {
        guard let task = backupTask else { return }
        task.cancel()
        AppLogger.shared.info("BackupManager", "automatic_backup_cancel_requested")
    }

    // MARK: - 获取备份列表

    /// 备份的格式。新写出的一律是 `.archiveV1`；`.legacyJSON` **只读**，不再产生。
    enum BackupFormat {
        case archiveV1      // <name>.beadbackup/ 目录：manifest + 二进制 blob
        case legacyJSON     // 旧的单个巨型 JSON（图片 base64 内嵌）
    }

    struct BackupInfo: Identifiable {
        let id = UUID()
        let fileURL: URL
        let fileName: String
        let date: Date
        let fileSize: Int64
        let stats: BackupStats?
        let format: BackupFormat

        var formattedDate: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy年M月d日 EEEE"
            formatter.locale = Locale(identifier: "zh_CN")
            return formatter.string(from: date)
        }

        var formattedSize: String {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter.string(fromByteCount: fileSize)
        }
    }

    struct BackupStats {
        let brandsCount: Int
        let stocksCount: Int
        let projectsCount: Int
    }

    /// 回收中断的备份写出留下的 `.beadbackup.partial`。
    ///
    /// **可以在任何时候调用。** 安全性由 `BackupArchiveWriter.sweepStalePartials` 的
    /// in-flight 认领 + 时间阈值两道运行时检查保证，不依赖调用时机（详见该函数注释）。
    func sweepStaleBackupPartials() {
        guard let dir = backupDirectory else { return }
        BackupArchiveWriter.sweepStalePartials(in: dir)
    }

    /// 盘上是否已有**非空**的既有备份。
    ///
    /// 用于判断"当前内存为空"到底是新装用户还是刚被重置的损坏库 —— 后者绝不能拿空快照
    /// 去挤掉真备份（见 `performArchiveBackup` 的拒绝逻辑）。
    ///
    /// 只读 manifest，不碰 blob。旧 JSON 无法在不整份读入的情况下判断内容
    /// （那正是 `getBackupList` 特意避免的 4.4 GB 读取），所以**一律当作非空** ——
    /// 判错的方向是"少写一次备份"，而不是"删掉用户最后一份数据"。
    private func hasNonEmptyExistingBackup() -> Bool {
        guard let backupDir = backupDirectory else { return false }
        return BackupManager.hasNonEmptyArchive(in: backupDir)
    }

    /// `hasNonEmptyExistingBackup` 的纯函数内核 —— 只依赖一个目录，因此可测。
    ///
    /// 抽出来是因为它守着"空归档不许挤掉真备份"这条闸，而它有六个可以独立改坏的分支
    /// （三条保守 `return true` 的兜底、legacy `.json` 判定、空/非空 manifest），
    /// 埋在 private 实例方法里一条都测不到。
    static func hasNonEmptyArchive(in backupDir: URL) -> Bool {
        for url in BackupArchiveWriter.listArchives(in: backupDir) {
            let manifestURL = url.appendingPathComponent("manifest.json")
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: manifestURL.path),
                  let size = (attrs[.size] as? NSNumber)?.int64Value,
                  size <= BackupArchiveReader.maxManifestBytes,
                  let data = try? Data(contentsOf: manifestURL) else {
                // 读不出来 = 判断不了 = 保守当作非空。
                return true
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let m = try? decoder.decode(BackupArchiveManifest.self, from: data) else { return true }
            // 与 `snapshotIsEmpty` 同口径 —— 两处必须一起看，否则会出现
            // "内存判为空、盘上判为非空"这种不对称。
            if !m.projects.isEmpty || !m.brands.isEmpty || !m.brandStocks.isEmpty
                || !m.customColors.isEmpty || !m.purchaseRecords.isEmpty { return true }
        }

        if let files = try? FileManager.default.contentsOfDirectory(
            at: backupDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ), files.contains(where: { $0.pathExtension == "json" }) {
            return true
        }
        return false
    }

    /// 获取所有备份
    func getBackupList() -> [BackupInfo] {
        guard let backupDir = backupDirectory else { return [] }

        var result: [BackupInfo] = []

        // ① 新格式：.beadbackup 目录。stats 从 manifest 读 —— manifest 只含 metadata，
        //    体积与图片无关（只有 metadata，量级是 MB 而不是 GB）。
        for url in BackupArchiveWriter.listArchives(in: backupDir) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            // 兜底方向必须是**保守 = 保留**。列表按 date 降序，`cleanupOldBackups`
            // 删的是排在最后的那些 —— 兜底成 `distantPast` 的话，一次瞬时的属性读取
            // 失败会被转写成"这是最老的备份"然后把它删掉。用 `distantFuture` 让它
            // 排在最前、不参与轮转淘汰，宁可多留一份。
            let date: Date
            if let creationDate = attrs?[.creationDate] as? Date {
                date = creationDate
            } else {
                AppLogger.shared.warning("BackupManager", "archive_attrs_unreadable", metadata: [
                    "name": url.lastPathComponent
                ])
                date = .distantFuture
            }
            var stats: BackupStats?
            var size: Int64 = 0
            let manifestURL = url.appendingPathComponent("manifest.json")
            if let mAttrs = try? FileManager.default.attributesOfItem(atPath: manifestURL.path),
               let mSize = (mAttrs[.size] as? NSNumber)?.int64Value,
               mSize <= BackupArchiveReader.maxManifestBytes,
               let data = try? Data(contentsOf: manifestURL) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let m = try? decoder.decode(BackupArchiveManifest.self, from: data) {
                    stats = BackupStats(brandsCount: m.brands.count,
                                        stocksCount: m.brandStocks.count,
                                        projectsCount: m.projects.count)
                }
            }
            size = directorySize(url)
            result.append(BackupInfo(fileURL: url, fileName: url.lastPathComponent,
                                     date: date, fileSize: size, stats: stats, format: .archiveV1))
        }

        // ② 旧格式：单个 .json。**只读兼容，不再产生。**
        //
        // 这里**刻意不读文件内容**。原实现为了取 stats 会
        // `Data(contentsOf:)` + `JSONSerialization` 把**每一个**备份整个读进内存并完整解析 ——
        // 旧格式单份可达数百 MB，保留 8 份的话，打开备份列表这个动作本身就要读几个 GB。
        // 那是与 F1 完全同类的 OOM，而且发生在用户主动点进来的页面上。
        // 旧备份的 stats 显示为空是完全可以接受的代价。
        if let files = try? FileManager.default.contentsOfDirectory(
            at: backupDir, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
            options: .skipsHiddenFiles
        ) {
            for fileURL in files where fileURL.pathExtension == "json" {
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                      let creationDate = attributes[.creationDate] as? Date,
                      let fileSize = attributes[.size] as? Int64 else { continue }
                result.append(BackupInfo(fileURL: fileURL, fileName: fileURL.lastPathComponent,
                                         date: creationDate, fileSize: fileSize,
                                         stats: nil, format: .legacyJSON))
            }
        }

        return result.sorted { $0.date > $1.date }
    }

    /// 目录总字节数。只做一层 `blobs/` 遍历 —— 归档结构是固定的，不需要通用递归。
    private func directorySize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        let fm = FileManager.default
        for sub in [url, url.appendingPathComponent("blobs")] {
            guard let entries = try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for e in entries {
                if let n = (try? fm.attributesOfItem(atPath: e.path))?[.size] as? NSNumber {
                    total += n.int64Value
                }
            }
        }
        return total
    }

    // MARK: - 恢复备份

    /// 从备份恢复数据。按格式分发。
    ///
    /// **新格式的恢复路径是"先完整校验、再应用"** —— 校验不通过一个字节都不写入 store。
    /// 旧 JSON 保留只读兼容,但它的恢复是分段落盘的(先写 metadata 再写图),
    /// 中途失败会留下半恢复状态;这是既有行为,没有在本次改动范围内重写。
    @MainActor func restoreBackup(from backup: BackupInfo, to manager: InventoryManager) async throws {
        switch backup.format {
        case .archiveV1:
            // **校验必须离开主 actor。** `validate()` 是无隔离的 static func，从 @MainActor
            // 调用就跑在主线程上，而它要读遍并 SHA-256 每一个 blob（GB 量级）；
            // 紧接着 `apply` 再读一遍。原来这条路径外面套的
            // `DispatchQueue.main.asyncAfter` 什么也没买到 —— 调用点本来就在主线程。
            // 两遍全量同步 I/O + 哈希卡住 UI，正是本 PR 在修的那个看门狗形状（0x8BADF00D）。
            //
            // `apply` 留在主 actor：它写 SwiftData mainContext，本来就必须在主线程。
            let url = backup.fileURL
            let report = try await Task.detached(priority: .userInitiated) {
                try BackupArchiveReader.validate(archiveAt: url)
            }.value
            try BackupArchiveReader.apply(report, to: manager)
            AppLogger.shared.info("BackupManager", "archive_restore_completed", metadata: [
                "projects": report.manifest.projects.count, "blobs": report.blobCount
            ])
            // 与 legacy 路径同理（见 `restoreLegacyJSONBackup` 末尾的长注释）：
            // restore 会改写 displayThumbnail，而协调器只在 scenePhase 转 .active 时启动，
            // 恢复是在前台做的、不会触发新 transition。不显式重启的话，需要 backfill 的
            // 项目要等下次启动，中间列表全走现场降级。stop + start 是 idempotent 的。
            ThumbnailMigrationCoordinator.shared.stop()
            ThumbnailMigrationCoordinator.shared.start(inventoryManager: manager)
        case .legacyJSON:
            try restoreLegacyJSONBackup(from: backup, to: manager)
        }
    }

    @MainActor private func restoreLegacyJSONBackup(from backup: BackupInfo, to manager: InventoryManager) throws {
        let data = try Data(contentsOf: backup.fileURL)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BackupError.invalidFormat
        }

        // 解析品牌
        var restoredBrands: [Brand] = []
        if let brandsArray = json["brands"] as? [[String: Any]] {
            for brandDict in brandsArray {
                guard let idString = brandDict["id"] as? String,
                      let id = UUID(uuidString: idString),
                      let name = brandDict["name"] as? String else {
                    continue
                }

                let sortOrder = brandDict["sortOrder"] as? Int ?? 0
                let lowStockThreshold = brandDict["lowStockThreshold"] as? Int ?? 100

                var createdAt = Date()
                if let createdAtString = brandDict["createdAt"] as? String {
                    createdAt = ISO8601DateFormatter().date(from: createdAtString) ?? Date()
                }

                let colorSystem: ColorSystem
                if let colorSystemRaw = brandDict["colorSystem"] as? String {
                    colorSystem = ColorSystem(rawValue: colorSystemRaw) ?? .mard
                } else {
                    colorSystem = .mard
                }

                let brand = Brand(
                    id: id,
                    name: name,
                    sortOrder: sortOrder,
                    createdAt: createdAt,
                    lowStockThreshold: lowStockThreshold,
                    colorSystem: colorSystem
                )
                restoredBrands.append(brand)
            }
        }

        // 解析库存
        var restoredStocks: [BrandStock] = []
        if let stocksArray = json["brandStocks"] as? [[String: Any]] {
            for stockDict in stocksArray {
                guard let idString = stockDict["id"] as? String,
                      let id = UUID(uuidString: idString),
                      let brandIdString = stockDict["brandId"] as? String,
                      let brandId = UUID(uuidString: brandIdString),
                      let mardCode = stockDict["mardCode"] as? String else {
                    continue
                }

                let stock = BrandStock(
                    id: id,
                    brandId: brandId,
                    mardCode: mardCode,
                    stock: stockDict["stock"] as? Int ?? 0,
                    used: stockDict["used"] as? Int ?? 0,
                    isHidden: stockDict["isHidden"] as? Bool ?? false
                )
                restoredStocks.append(stock)
            }
        }

        // 解析项目
        var restoredProjects: [ProjectRecord] = []
        // 备份对 displayThumbnail 是否提供过的标志（按 project.id 跟踪），让 restoreProjectBlobsFromBackup
        // 知道老备份（field 不存在）跟新备份显式 nil 的区别。
        var displayProvidedById: [UUID: Bool] = [:]
        // 图纸标定数据（拼图网格 / 多零件图纸）也走旁路 dict：它们不在 ProjectRecord 上
        // （partsSheet 只有 SwiftData 列），只能直接交给 restoreProjectBlobsFromBackup。
        // provided=false（老备份没这两个字段）时 restore 不动 store 上的现有值。
        var gridById: [UUID: (data: Data?, provided: Bool)] = [:]
        var partsById: [UUID: (data: Data?, provided: Bool)] = [:]
        if let projectsArray = json["projects"] as? [[String: Any]] {
            for projectDict in projectsArray {
                guard let idString = projectDict["id"] as? String,
                      let id = UUID(uuidString: idString),
                      let name = projectDict["name"] as? String else {
                    continue
                }

                var date = Date()
                if let dateString = projectDict["date"] as? String {
                    date = ISO8601DateFormatter().date(from: dateString) ?? Date()
                }

                var brandId: UUID?
                if let brandIdString = projectDict["brandId"] as? String {
                    brandId = UUID(uuidString: brandIdString)
                }

                var completedDate: Date?
                if let completedDateString = projectDict["completedDate"] as? String {
                    completedDate = ISO8601DateFormatter().date(from: completedDateString)
                }

                var executedDate: Date?
                if let executedDateString = projectDict["executedDate"] as? String {
                    executedDate = ISO8601DateFormatter().date(from: executedDateString)
                }

                var parentId: UUID?
                if let parentIdString = projectDict["parentId"] as? String {
                    parentId = UUID(uuidString: parentIdString)
                }

                // 解析缩略图和成品图
                var thumbnail: Data?
                if let thumbnailBase64 = projectDict["thumbnail"] as? String {
                    thumbnail = Data(base64Encoded: thumbnailBase64)
                }
                var finishedImage: Data?
                if let finishedImageBase64 = projectDict["finishedImage"] as? String {
                    finishedImage = Data(base64Encoded: finishedImageBase64)
                }
                // displayThumbnail：新备份会带 displayThumbnailProvided=true。老备份没这个字段，
                // 视为"未提供" → restore 不动 store 旧的 displayThumbnail，让迁移协调器后续 backfill。
                var displayThumbnail: Data?
                let displayThumbnailProvided = projectDict["displayThumbnailProvided"] as? Bool ?? false
                if let displayBase64 = projectDict["displayThumbnail"] as? String {
                    displayThumbnail = Data(base64Encoded: displayBase64)
                }

                var beadUsage: [BeadUsage] = []
                if let usageArray = projectDict["beadUsage"] as? [[String: Any]] {
                    for usageDict in usageArray {
                        guard let colorCode = usageDict["colorCode"] as? String,
                              let quantity = usageDict["quantity"] as? Int else {
                            continue
                        }
                        let usage = BeadUsage(
                            colorCode: colorCode,
                            quantity: quantity,
                            isDeducted: usageDict["isDeducted"] as? Bool ?? false
                        )
                        beadUsage.append(usage)
                    }
                }

                // 读取色号体系（兼容旧备份数据）
                let colorSystemRaw = projectDict["colorSystem"] as? String ?? "MARD"
                let colorSystem = ColorSystem(rawValue: colorSystemRaw) ?? .mard

                let project = ProjectRecord(
                    id: id,
                    name: name,
                    date: date,
                    beadUsage: beadUsage,
                    brandId: brandId,
                    isArchived: projectDict["isArchived"] as? Bool ?? false,
                    parentId: parentId,
                    isPlanned: projectDict["isPlanned"] as? Bool ?? false,
                    executedDate: executedDate,
                    thumbnail: thumbnail,
                    finishedImage: finishedImage,
                    completedDate: completedDate,
                    colorSystem: colorSystem,
                    patternGrid: nil,
                    displayThumbnail: displayThumbnail
                )
                // 把 displayThumbnailProvided 标志记到旁路 dict，让 restore 路径能区分
                // "老备份没字段" vs "新备份显式说没小图"
                displayProvidedById[project.id] = displayThumbnailProvided
                gridById[project.id] = (
                    data: (projectDict["patternGrid"] as? String).flatMap { Data(base64Encoded: $0) },
                    provided: projectDict["patternGridProvided"] as? Bool ?? false
                )
                partsById[project.id] = (
                    data: (projectDict["partsSheet"] as? String).flatMap { Data(base64Encoded: $0) },
                    provided: projectDict["partsSheetProvided"] as? Bool ?? false
                )
                restoredProjects.append(project)
            }
        }

        // 解析自定义色号
        var restoredCustomColors: [CustomColor] = []
        if let colorsArray = json["customColors"] as? [[String: Any]] {
            for colorDict in colorsArray {
                guard let idString = colorDict["id"] as? String,
                      let id = UUID(uuidString: idString),
                      let colorCode = colorDict["colorCode"] as? String,
                      let colorHex = colorDict["colorHex"] as? String else {
                    continue
                }

                // 备份文件是用户手上的 JSON —— 手改过、早期版本导出的、传坏了的都有可能。
                // 这是唯一一条能把非法色值送进 `CustomColor` 的路（界面输入那条在
                // `CustomColorEditView` 里就卡死了 3/6 位纯十六进制）。挡在门口，
                // 别等渲染时才发现：那时只剩一格颜色不对，看不出是哪条数据。
                let hexBody = colorHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
                guard hexBody.count == 3 || hexBody.count == 6,
                      hexBody.allSatisfy(\.isHexDigit) else {
                    AppLogger.shared.error("Backup", "custom_color_bad_hex",
                                           metadata: ["code": colorCode, "hex": colorHex])
                    continue
                }

                var createdAt = Date()
                if let createdAtString = colorDict["createdAt"] as? String {
                    createdAt = ISO8601DateFormatter().date(from: createdAtString) ?? Date()
                }
                var updatedAt = Date()
                if let updatedAtString = colorDict["updatedAt"] as? String {
                    updatedAt = ISO8601DateFormatter().date(from: updatedAtString) ?? Date()
                }

                let customColor = CustomColor(
                    id: id,
                    colorCode: colorCode,
                    colorHex: colorHex,
                    colorName: colorDict["colorName"] as? String ?? "",
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
                restoredCustomColors.append(customColor)
            }
        }

        // 解析运输中记录
        var restoredPurchaseRecords: [PurchaseRecord] = []
        if let recordsArray = json["purchaseRecords"] as? [[String: Any]] {
            for recordDict in recordsArray {
                guard let idString = recordDict["id"] as? String,
                      let id = UUID(uuidString: idString),
                      let brandIdString = recordDict["brandId"] as? String,
                      let brandId = UUID(uuidString: brandIdString),
                      let name = recordDict["name"] as? String else {
                    continue
                }

                var date = Date()
                if let dateString = recordDict["date"] as? String {
                    date = ISO8601DateFormatter().date(from: dateString) ?? Date()
                }

                var items: [PurchaseItem] = []
                if let itemsArray = recordDict["items"] as? [[String: Any]] {
                    for itemDict in itemsArray {
                        guard let colorCode = itemDict["colorCode"] as? String,
                              let quantity = itemDict["quantity"] as? Int else {
                            continue
                        }
                        var itemId = UUID()
                        if let itemIdString = itemDict["id"] as? String,
                           let parsedId = UUID(uuidString: itemIdString) {
                            itemId = parsedId
                        }
                        items.append(PurchaseItem(id: itemId, colorCode: colorCode, quantity: quantity))
                    }
                }

                let record = PurchaseRecord(
                    id: id,
                    name: name,
                    date: date,
                    brandId: brandId,
                    items: items,
                    note: recordDict["note"] as? String
                )
                restoredPurchaseRecords.append(record)
            }
        }

        // 解析当前品牌ID
        var restoredCurrentBrandId: UUID?
        if let currentBrandIdString = json["currentBrandId"] as? String {
            restoredCurrentBrandId = UUID(uuidString: currentBrandIdString)
        }

        // 应用恢复的数据
        manager.brands = restoredBrands
        manager.brandStocks = restoredStocks
        // 注意：把含图的 restoredProjects 直接塞给 manager.projects 只是临时态 ——
        // saveData 不会把 thumbnail/finishedImage 写回 SDProjectRecord（自 v2.0.x 起
        // blob 字段走专门的 update* 直写接口）。所以下面会单独把图持久化。
        manager.projects = restoredProjects
        manager.customColors = restoredCustomColors
        manager.purchaseRecords = restoredPurchaseRecords
        manager.currentBrandId = restoredCurrentBrandId

        // 保存到持久化存储（写入 metadata，不含 blob）
        manager.saveData()

        // 持久化项目图片 —— 走 `restoreProjectBlobsFromBackup` 批量直写：
        //   - 跳过 history 记录（restore 不应灌历史）
        //   - 跳过 updateProjectFinishedImage 的 `!isPlanned` 守卫
        //   - thumbnail / finishedImage 总是写（含 nil 清空：备份说没图就清旧图）
        //   - patternGrid / partsSheet 仅在备份带了对应字段时写（老备份 provided=false，
        //     不动用户当前的网格标定和多零件进度）
        let entries = restoredProjects.map { project in
            // displayThumbnail：
            //   - 新备份显式带（provided=true）→ 用备份里的值，老备份的 stale displayThumbnail 会被清掉，
            //     由迁移协调器现场 backfill（避免跟 raw thumbnail 不一致）
            //   - 老备份没字段（provided=false）→ 不动 store 旧值
            // 老备份强制 provided=true + value=nil 也是合理选择：让所有老备份恢复后都走迁移路径
            // 重新生成 displayThumbnail，避免 stale 跟新 thumbnail 错位。
            let providedFromBackup = displayProvidedById[project.id] ?? false
            let effectiveProvided = true   // 老备份也强制让 store 清掉 displayThumbnail
            let effectiveDisplay: Data? = providedFromBackup ? project.displayThumbnail : nil
            let grid = gridById[project.id] ?? (data: nil, provided: false)
            let parts = partsById[project.id] ?? (data: nil, provided: false)
            return (id: project.id,
                    thumbnail: project.thumbnail,
                    finishedImage: project.finishedImage,
                    patternGridData: grid.data,
                    patternGridProvided: grid.provided,
                    partsSheetData: parts.data,
                    partsSheetProvided: parts.provided,
                    displayThumbnail: effectiveDisplay,
                    displayThumbnailProvided: effectiveProvided)
        }
        let restoreResult = manager.restoreProjectBlobsFromBackup(entries)

        // 还原结束后从 manager.projects 卸掉 blob 副本，回到「缓存只存 metadata」的常态。
        // 否则 8MB+ 备份还原后会在内存里一直挂着这堆图。
        manager.projects = restoredProjects.map { project in
            var stripped = project
            stripped.thumbnail = nil
            stripped.finishedImage = nil
            stripped.patternGrid = nil
            stripped.displayThumbnail = nil
            return stripped
        }

        // 区分完整恢复和部分恢复。partial failure 时 logError 已经在
        // restoreProjectBlobsFromBackup 里写过（含失败 ID 采样），这里再打印一条
        // 用户可见的文案 + 把数字塞进 logInfo 让 Sentry 能跟踪发生率。
        if restoreResult.hasFailures {
            print("[BackupManager] 恢复部分成功: \(backup.fileName) — \(restoreResult.succeeded)/\(entries.count) 项目图片写回，\(restoreResult.failedIDs.count) 项目失败（详见 logError: restore_blobs_partial_failure）")
            AppLogger.shared.warning("BackupManager", "restore_completed_with_failures", metadata: [
                "fileName": backup.fileName,
                "succeeded": restoreResult.succeeded,
                "failed": restoreResult.failedIDs.count,
                "total": entries.count
            ])
        } else {
            print("[BackupManager] 恢复成功: \(backup.fileName)")
            AppLogger.shared.info("BackupManager", "restore_completed", metadata: [
                "fileName": backup.fileName,
                "projects": entries.count
            ])
        }

        // **round-10 review I2**：restore 路径 force-clear 了老备份的 stale displayThumbnail
        //（见本方法里构造 entries 处的 effectiveProvided=true + effectiveDisplay=nil），但**不会**自动让
        // 迁移协调器再扫一遍 —— 协调器只在 scenePhase .active transition 时 start。restore
        // 是在前台 .active 状态下触发的，**不会**触发新 transition。
        // 如果协调器已经跑完 + isRunning=false → restore 后清空的 displayThumbnail 要等下次
        // 启动才 backfill，中间所有列表浏览走 fallback 现场降级（仍安全但更慢 + 显示 stale
        // 直到下次启动）。
        // 显式 stop + start：旧 task（如果还在跑）被取消、新 task 立刻起来扫 displayThumbnail
        // == nil 的新候选集。是 idempotent 的。
        ThumbnailMigrationCoordinator.shared.stop()
        ThumbnailMigrationCoordinator.shared.start(inventoryManager: manager)
    }

    // MARK: - 删除备份

    func deleteBackup(_ backup: BackupInfo) -> Bool {
        do {
            try FileManager.default.removeItem(at: backup.fileURL)
            print("[BackupManager] 删除备份: \(backup.fileName)")
            return true
        } catch {
            print("[BackupManager] 删除备份失败: \(error)")
            return false
        }
    }

    // MARK: - 清理旧备份

    private func cleanupOldBackups() {
        let backups = getBackupList()
        guard backups.count > maxBackupCount else { return }

        // 上次恢复没跑完时，日志指向的那份归档是**唯一能把库修回去的材料**，
        // 轮转不许碰它 —— 删掉它，用户就永远停在半恢复状态了。
        let protectedPath = RestoreJournal.residual()
            .map { URL(fileURLWithPath: $0.archivePath).standardizedFileURL }

        var deleted = 0
        for backup in backups.suffix(from: maxBackupCount) {
            if let protectedPath, backup.fileURL.standardizedFileURL == protectedPath {
                AppLogger.shared.warning("BackupManager", "cleanup_skipped_restore_source", metadata: [
                    "name": backup.fileName
                ])
                continue
            }
            if deleteBackup(backup) { deleted += 1 }
        }
        print("[BackupManager] 清理了 \(deleted) 个旧备份")
    }

    // MARK: - 错误类型

    enum BackupError: LocalizedError {
        case invalidFormat
        case readFailed
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .invalidFormat:
                return String(localized: "备份文件格式无效")
            case .readFailed:
                return String(localized: "读取备份文件失败")
            case .writeFailed:
                return String(localized: "写入备份文件失败")
            }
        }
    }
}
