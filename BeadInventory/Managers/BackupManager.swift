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

    /// 本周是否已完成过备份（标记在写盘成功后才更新，见 performBackup）。
    private func hasBackedUpThisWeek(now: Date = Date()) -> Bool {
        guard let lastBackupDate = UserDefaults.standard.object(forKey: lastBackupDateKey) as? Date else {
            return false
        }
        return Calendar.current.isDate(now, equalTo: lastBackupDate, toGranularity: .weekOfYear)
    }

    /// 检查是否需要进行每周备份。
    ///
    /// 自 v2.0.x 起：备份阶段会从 SwiftData 把所有项目的 thumbnail / finishedImage 取出来 base64
    /// 编进 JSON（v1.x 起就这样，只是以前在 InventoryManager.projects 里现成有图）。
    /// 在 cold-start 的 onAppear 同步路径里跑这玩意儿可能撞 scene-create watchdog，
    /// 所以把执行延后一个 tick + 5s、走 Task：让首屏先 commit，避免首帧渲染期间被卡。
    @MainActor func checkAndPerformWeeklyBackupIfNeeded(inventoryManager: InventoryManager) {
        if hasBackedUpThisWeek() {
            print("[BackupManager] 本周已备份，跳过")
            return
        }

        // 推迟到下一次 runloop tick：让首屏 scene-create commit 先完成。
        // 注意：备份仍然要在 MainActor 上跑（SwiftData mainContext 限定主线程），
        // 但它不会再卡在第一帧 commit 里 —— iOS watchdog 不会因此再 0x8BADF00D。
        //
        // 再延后 5s：备份要逐项目从 SwiftData 取图 + base64（全程主线程），跟启动后紧接着的
        // initial load / 首次用户交互挤在同一窗口会明显掉帧。晚 5s 做备份没有任何语义差别
        //（本周备份标记在写盘成功后才更新；5s 内退出则下次启动重试）。
        Task { @MainActor in
            // 取消 = 跳过本次备份（标记未写，下次启动重试）。
            // 不能用 try?：取消时 sleep 立即抛错，吞掉后 performBackup 会在 t≈0 无延迟执行，
            // 恰好落回 5s 想避开的启动窗口 —— 取消语义整个反转。
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                return
            }
            // sleep 后复查资格：同一窗口内的重复调用（如 onAppear 重入）串行到这里时，
            // 第一个已完成备份并写了标记，后续直接跳过，保证幂等。
            guard !hasBackedUpThisWeek() else { return }
            performBackup(inventoryManager: inventoryManager)
        }
    }

    // MARK: - 执行备份

    /// 创建备份
    @discardableResult
    @MainActor func performBackup(inventoryManager: InventoryManager) -> Bool {
        guard let backupDir = backupDirectory else {
            print("[BackupManager] 无法获取备份目录")
            return false
        }

        // F1 实测探针。用单调时钟，不用 Date() —— 后者会被系统时间调整影响，
        // 而这里量的是主线程不可响应时长，必须单调。
        #if DEBUG || F1_BENCHMARK
        let benchStart = DispatchTime.now()
        F1Benchmark.checkpoint("1_beforePerformBackup")
        defer {
            // 检查点 5：函数返回后。与检查点 4（写盘后）的差值用于区分
            // “backupData / jsonData 尚未释放” 与 “释放不掉”。
            F1Benchmark.checkpoint("5_afterPerformBackupReturn")
            let millis = Double(DispatchTime.now().uptimeNanoseconds - benchStart.uptimeNanoseconds) / 1_000_000
            F1Benchmark.recordMainThreadDuration(millis: millis)
            // 检查点 6：下一轮 RunLoop 之后 —— autorelease 池排空后的真实回落点。
            DispatchQueue.main.async {
                F1Benchmark.checkpoint("6_afterNextRunLoop")
                F1Benchmark.setState("completed")
            }
        }
        #endif

        // 生成备份数据
        let backupData = createBackupData(from: inventoryManager)

        #if DEBUG || F1_BENCHMARK
        F1Benchmark.checkpoint("2_afterCreateBackupData")
        #endif

        guard let jsonData = try? JSONSerialization.data(withJSONObject: backupData, options: [.prettyPrinted, .sortedKeys]) else {
            print("[BackupManager] 备份数据序列化失败")
            return false
        }

        #if DEBUG || F1_BENCHMARK
        F1Benchmark.checkpoint("3_afterJSONSerialization")
        #endif

        // 生成文件名：backup_2024-01-15_周一.json
        let fileName = generateBackupFileName()
        let fileURL = backupDir.appendingPathComponent(fileName)

        do {
            try jsonData.write(to: fileURL)

            #if DEBUG || F1_BENCHMARK
            F1Benchmark.checkpoint("4_afterWrite")
            #endif

            // 更新上次备份日期
            UserDefaults.standard.set(Date(), forKey: lastBackupDateKey)

            print("[BackupManager] 备份成功: \(fileName)")

            // 清理旧备份
            cleanupOldBackups()

            return true
        } catch {
            print("[BackupManager] 备份写入失败: \(error)")
            return false
        }
    }

    #if DEBUG || F1_BENCHMARK
    /// 进程内复位「本周已备份」标记。
    ///
    /// 实验每轮都要重新触发自动备份,而 `hasBackedUpThisWeek()` 会挡掉。外部
    /// `xcrun simctl spawn defaults delete` 受模拟器偏好域路径影响可能静默失败,
    /// 那会让整轮变成假阴性(看起来"备份没跑",其实是没触发)。所以提供进程内入口,
    /// 并由 `F1Benchmark` 把结果写进结构化结果文件供脚本核对。
    func resetWeeklyBackupStateForBenchmark() {
        UserDefaults.standard.removeObject(forKey: lastBackupDateKey)
        AppLogger.shared.warning("F1Benchmark", "weekly_backup_state_reset")
    }
    #endif

    // MARK: - 备份数据生成

    @MainActor private func createBackupData(from manager: InventoryManager) -> [String: Any] {
        var data: [String: Any] = [:]

        // 元数据
        data["backupDate"] = ISO8601DateFormatter().string(from: Date())
        data["appVersion"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        data["backupType"] = "weekly_auto"

        // 品牌数据
        data["brands"] = manager.brands.map { brand in
            [
                "id": brand.id.uuidString,
                "name": brand.name,
                "sortOrder": brand.sortOrder,
                "createdAt": ISO8601DateFormatter().string(from: brand.createdAt),
                "lowStockThreshold": brand.lowStockThreshold,
                "colorSystem": brand.colorSystem.rawValue
            ]
        }

        // 库存数据
        data["brandStocks"] = manager.brandStocks.map { stock in
            [
                "id": stock.id.uuidString,
                "brandId": stock.brandId.uuidString,
                "mardCode": stock.mardCode,
                "stock": stock.stock,
                "used": stock.used,
                "isHidden": stock.isHidden
            ]
        }

        // 项目数据
        //
        // 注意：自 v2.0.x 起 manager.projects 不再持有 thumbnail / finishedImage Data
        // （为避免 458 项目级用户加载即 ~200MB 内存撞 jetsam）。备份阶段才把图按需取出来 base64。
        //
        // **原注释「峰值内存 ≈ 单张最大图」具有误导性，已更正：**
        // 原始 `Data` 确实逐张释放，但下面写进 projectData 的是 `base64EncodedString()`
        // 产生的 **String**，它随数组一路累积、持有到序列化结束；随后
        // `JSONSerialization.data(...)` 再把整棵树物化成第二份完整拷贝。
        // 也就是说峰值**随项目总数与图片总字节线性增长，不存在单张上界**。
        // 具体倍数正由 F1 实测确定（见实验计划 v3），确定前不在此写死数字。
        #if DEBUG || F1_BENCHMARK
        var benchThumbCount = 0, benchFinishedCount = 0, benchDisplayCount = 0
        var benchThumbBytes: Int64 = 0, benchFinishedBytes: Int64 = 0, benchDisplayBytes: Int64 = 0
        #endif
        data["projects"] = manager.projects.map { project in
            var projectData: [String: Any] = [
                "id": project.id.uuidString,
                "name": project.name,
                "date": ISO8601DateFormatter().string(from: project.date),
                "totalBeads": project.totalBeads,
                "isArchived": project.isArchived,
                "isPlanned": project.isPlanned,
                "colorSystem": project.colorSystem.rawValue
            ]
            if let brandId = project.brandId {
                projectData["brandId"] = brandId.uuidString
            }
            if let completedDate = project.completedDate {
                projectData["completedDate"] = ISO8601DateFormatter().string(from: completedDate)
            }
            if let executedDate = project.executedDate {
                projectData["executedDate"] = ISO8601DateFormatter().string(from: executedDate)
            }
            if let parentId = project.parentId {
                projectData["parentId"] = parentId.uuidString
            }
            // 按需从 SwiftData 取图（projects 缓存里已不含）。
            if let thumbnail = manager.fetchProjectThumbnailData(for: project.id) {
                projectData["thumbnail"] = thumbnail.base64EncodedString()
                #if DEBUG || F1_BENCHMARK
                benchThumbCount += 1; benchThumbBytes += Int64(thumbnail.count)
                #endif
            }
            if let finishedImage = manager.fetchProjectFinishedImageData(for: project.id) {
                projectData["finishedImage"] = finishedImage.base64EncodedString()
                #if DEBUG || F1_BENCHMARK
                benchFinishedCount += 1; benchFinishedBytes += Int64(finishedImage.count)
                #endif
            }
            // displayThumbnail：备份带就写小图，让 restore 直接拿来不用现场降级。
            // displayThumbnailProvided 标志让 restore 区分"老备份没这个字段"和"新备份显式说没小图"。
            projectData["displayThumbnailProvided"] = true
            if let displayThumbnail = manager.fetchProjectDisplayThumbnail(for: project.id) {
                projectData["displayThumbnail"] = displayThumbnail.base64EncodedString()
                #if DEBUG || F1_BENCHMARK
                benchDisplayCount += 1; benchDisplayBytes += Int64(displayThumbnail.count)
                #endif
            }
            projectData["beadUsage"] = project.beadUsage.map { usage in
                [
                    "colorCode": usage.colorCode,
                    "quantity": usage.quantity,
                    "isDeducted": usage.isDeducted
                ]
            }
            return projectData
        }

        #if DEBUG || F1_BENCHMARK
        // 横轴数据：备份**实际读取**的三个字段，实测而非估算。
        // patternGridData 不在此列 —— createBackupData 根本不读它，算进去会压低斜率。
        F1Benchmark.recordBlobBytes(
            thumbnail: (benchThumbCount, benchThumbBytes),
            finished: (benchFinishedCount, benchFinishedBytes),
            display: (benchDisplayCount, benchDisplayBytes)
        )
        #endif

        // 自定义色号
        data["customColors"] = manager.customColors.map { color in
            [
                "id": color.id.uuidString,
                "colorCode": color.colorCode,
                "colorHex": color.colorHex,
                "colorName": color.colorName,
                "createdAt": ISO8601DateFormatter().string(from: color.createdAt),
                "updatedAt": ISO8601DateFormatter().string(from: color.updatedAt)
            ]
        }

        // 运输中记录
        data["purchaseRecords"] = manager.purchaseRecords.map { record in
            var recordData: [String: Any] = [
                "id": record.id.uuidString,
                "name": record.name,
                "date": ISO8601DateFormatter().string(from: record.date),
                "brandId": record.brandId.uuidString
            ]
            if let note = record.note {
                recordData["note"] = note
            }
            recordData["items"] = record.items.map { item in
                [
                    "id": item.id.uuidString,
                    "colorCode": item.colorCode,
                    "quantity": item.quantity
                ]
            }
            return recordData
        }

        // 当前品牌ID
        if let currentBrandId = manager.currentBrandId {
            data["currentBrandId"] = currentBrandId.uuidString
        }

        // 统计信息
        data["stats"] = [
            "brandsCount": manager.brands.count,
            "stocksCount": manager.brandStocks.count,
            "projectsCount": manager.projects.count,
            "customColorsCount": manager.customColors.count,
            "purchaseRecordsCount": manager.purchaseRecords.count
        ]

        return data
    }

    // MARK: - 文件名生成

    private func generateBackupFileName() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: Date())

        // 获取星期几
        dateFormatter.dateFormat = "EEEE"
        dateFormatter.locale = Locale(identifier: "zh_CN")
        let weekdayString = dateFormatter.string(from: Date())

        return "backup_\(dateString)_\(weekdayString).json"
    }

    // MARK: - 获取备份列表

    struct BackupInfo: Identifiable {
        let id = UUID()
        let fileURL: URL
        let fileName: String
        let date: Date
        let fileSize: Int64
        let stats: BackupStats?

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

    /// 获取所有备份
    func getBackupList() -> [BackupInfo] {
        guard let backupDir = backupDirectory else { return [] }

        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: backupDir,
                includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
                options: .skipsHiddenFiles
            )

            return files
                .filter { $0.pathExtension == "json" }
                .compactMap { fileURL -> BackupInfo? in
                    guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                          let creationDate = attributes[.creationDate] as? Date,
                          let fileSize = attributes[.size] as? Int64 else {
                        return nil
                    }

                    // 尝试读取统计信息
                    var stats: BackupStats?
                    if let data = try? Data(contentsOf: fileURL),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let statsDict = json["stats"] as? [String: Int] {
                        stats = BackupStats(
                            brandsCount: statsDict["brandsCount"] ?? 0,
                            stocksCount: statsDict["stocksCount"] ?? 0,
                            projectsCount: statsDict["projectsCount"] ?? 0
                        )
                    }

                    return BackupInfo(
                        fileURL: fileURL,
                        fileName: fileURL.lastPathComponent,
                        date: creationDate,
                        fileSize: fileSize,
                        stats: stats
                    )
                }
                .sorted { $0.date > $1.date }  // 按日期降序
        } catch {
            print("[BackupManager] 获取备份列表失败: \(error)")
            return []
        }
    }

    // MARK: - 恢复备份

    /// 从备份恢复数据
    @MainActor func restoreBackup(from backup: BackupInfo, to manager: InventoryManager) throws {
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
        //   - patternGrid 仅在备份格式 round-trip 这个字段时写（v2.0.x 备份格式还没加，
        //     先一律 `provided: false`，不动用户当前的网格标定。
        //     S4 follow-up：把 patternGrid 加进备份导出 JSON）
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
            return (id: project.id,
                    thumbnail: project.thumbnail,
                    finishedImage: project.finishedImage,
                    patternGridData: nil as Data?,
                    patternGridProvided: false,
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
        //（见 line ~615 effectiveProvided=true + effectiveDisplay=nil），但**不会**自动让
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

        if backups.count > maxBackupCount {
            let toDelete = backups.suffix(from: maxBackupCount)
            for backup in toDelete {
                _ = deleteBackup(backup)
            }
            print("[BackupManager] 清理了 \(toDelete.count) 个旧备份")
        }
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
