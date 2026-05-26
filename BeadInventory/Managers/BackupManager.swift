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

    /// 检查是否需要进行每周备份。
    ///
    /// 自 v2.0.x 起：备份阶段会从 SwiftData 把所有项目的 thumbnail / finishedImage 取出来 base64
    /// 编进 JSON（v1.x 起就这样，只是以前在 InventoryManager.projects 里现成有图）。
    /// 在 cold-start 的 onAppear 同步路径里跑这玩意儿可能撞 scene-create watchdog，
    /// 所以把执行延后一帧 + 走 Task：让首屏先 commit，避免首帧渲染期间被卡。
    @MainActor func checkAndPerformWeeklyBackupIfNeeded(inventoryManager: InventoryManager) {
        let now = Date()

        // 获取上次备份日期
        if let lastBackupDate = UserDefaults.standard.object(forKey: lastBackupDateKey) as? Date {
            // 检查是否在同一周
            if Calendar.current.isDate(now, equalTo: lastBackupDate, toGranularity: .weekOfYear) {
                print("[BackupManager] 本周已备份，跳过")
                return
            }
        }

        // 推迟到下一次 runloop tick：让首屏 scene-create commit 先完成。
        // 注意：备份仍然要在 MainActor 上跑（SwiftData mainContext 限定主线程），
        // 但它不会再卡在第一帧 commit 里 —— iOS watchdog 不会因此再 0x8BADF00D。
        Task { @MainActor in
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

        // 生成备份数据
        let backupData = createBackupData(from: inventoryManager)

        guard let jsonData = try? JSONSerialization.data(withJSONObject: backupData, options: [.prettyPrinted, .sortedKeys]) else {
            print("[BackupManager] 备份数据序列化失败")
            return false
        }

        // 生成文件名：backup_2024-01-15_周一.json
        let fileName = generateBackupFileName()
        let fileURL = backupDir.appendingPathComponent(fileName)

        do {
            try jsonData.write(to: fileURL)

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
        // 一次只持有一张图的 Data，循环结束即释放，峰值内存 ≈ 单张最大图 + JSON 累积体积。
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
            }
            if let finishedImage = manager.fetchProjectFinishedImageData(for: project.id) {
                projectData["finishedImage"] = finishedImage.base64EncodedString()
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
                    colorSystem: colorSystem
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
            (id: project.id,
             thumbnail: project.thumbnail,
             finishedImage: project.finishedImage,
             patternGridData: nil as Data?,
             patternGridProvided: false)
        }
        manager.restoreProjectBlobsFromBackup(entries)

        // 还原结束后从 manager.projects 卸掉 blob 副本，回到「缓存只存 metadata」的常态。
        // 否则 8MB+ 备份还原后会在内存里一直挂着这堆图。
        manager.projects = restoredProjects.map { project in
            var stripped = project
            stripped.thumbnail = nil
            stripped.finishedImage = nil
            stripped.patternGrid = nil
            return stripped
        }

        print("[BackupManager] 恢复成功: \(backup.fileName)")
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
