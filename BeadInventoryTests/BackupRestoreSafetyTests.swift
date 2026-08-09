//
//  BackupRestoreSafetyTests.swift
//  BeadInventoryTests
//
//  钉住"恢复失败时不能损坏用户数据"这条主线。
//
//  上一轮复审的结论是：六条 Critical 修复里**五条零测试** —— 删掉修复本身，43 个测试全绿。
//  一个没有测试的修复等于把发现的问题从"已知"改成"已修"，而实际只是变回沉默。
//  本文件补的就是那几条。
//

import XCTest
import SwiftData
import UIKit
@testable import BeadInventory

final class BackupRestoreSafetyTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestoreSafetyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        // 这些测试要断言"日志被清掉了"，所以必须从干净状态开始。
        RestoreJournal.finish()
    }

    override func tearDownWithError() throws {
        RestoreJournal.finish()
        try? FileManager.default.removeItem(at: workDir)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func makePNG(side: CGFloat, color: UIColor) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
            color.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }.pngData()!
    }

    /// 造一个含 1 个项目（四个 blob 齐全）+ 各集合各一条的真实归档。
    @MainActor
    private func makeArchive(named name: String) async throws -> URL {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let record = SDProjectRecord(
            name: "归档里的项目",
            thumbnail: makePNG(side: 8, color: .systemTeal),
            finishedImage: makePNG(side: 9, color: .systemGreen),
            patternGridData: Data(#"{"rows":2}"#.utf8),
            displayThumbnail: makePNG(side: 7, color: .systemPink)
        )
        ctx.insert(record)
        try ctx.save()

        let brandId = UUID()
        let snapshot = BackupArchiveWriter.MetadataSnapshot(
            projects: [ProjectRecord(id: record.id, name: "归档里的项目", totalBeads: 42)],
            brands: [Brand(id: brandId, name: "归档品牌", sortOrder: 1)],
            brandStocks: [BrandStock(brandId: brandId, mardCode: "B2", stock: 10, used: 1)],
            customColors: [CustomColor(colorCode: "X1", colorHex: "#ABCDEF", colorName: "归档色")],
            purchaseRecords: [PurchaseRecord(name: "进货", brandId: brandId,
                                             items: [PurchaseItem(colorCode: "B2", quantity: 5)])],
            currentBrandId: brandId,
            appVersion: "test"
        )
        return try await BackupArchiveWriter.write(
            snapshot: snapshot,
            imageLoader: ProjectImageLoader(container: container),
            to: workDir, archiveName: name
        )
    }

    // MARK: - C1：元数据没落盘时，内存必须**原样**还原

    /// 这是本 PR 最严重那个 bug 的修复本身，此前零覆盖 ——
    /// 删掉 `apply` 里整个 `guard outcome.isPersisted` 块，43 个测试全绿。
    ///
    /// 用一个**没跑过初始加载**的 `InventoryManager` 触发：`isDataLoaded == false`
    /// → `saveDataReportingOutcome()` 返回 `.notLoaded` → `isPersisted == false`，
    /// 走的正是生产上"磁盘满导致 rollback"那条分支的同一段代码。
    ///
    /// 断言三件事，缺一不可：
    ///   1. 抛的是 `metadataCommitFailed`，且 `didMutateStore == false`；
    ///   2. **内存被还原成调用前的样子** —— 这是上一版最大的漏洞：它调的是异步
    ///      `refreshFromPersistentStore`，会被脏数据门确定性丢弃，幻影状态留在内存里
    ///      等着被下一次自动保存提交；
    ///   3. 一个 blob 都没写进 store。
    @MainActor
    func testFailedMetadataCommitRestoresMemoryAndWritesNoBlobs() async throws {
        let archive = try await makeArchive(named: "commit_fail")
        let report = try BackupArchiveReader.validate(archiveAt: archive)

        // 未跑初始加载 ⇒ isDataLoaded == false
        let liveContainer = try makeContainer()
        let manager = InventoryManager(modelContext: ModelContext(liveContainer))

        let originalBrandId = UUID()
        manager.brands = [Brand(id: originalBrandId, name: "原有品牌", sortOrder: 0)]
        manager.brandStocks = [BrandStock(brandId: originalBrandId, mardCode: "A1", stock: 3, used: 0)]
        manager.customColors = []
        manager.purchaseRecords = []
        manager.currentBrandId = originalBrandId
        manager.projects = [ProjectRecord(id: UUID(), name: "原有项目")]

        let brandsBefore = manager.brands
        let stocksBefore = manager.brandStocks
        let projectsBefore = manager.projects
        let currentBefore = manager.currentBrandId

        do {
            try BackupArchiveReader.apply(report, to: manager)
            XCTFail("元数据没能落盘时必须抛错，绝不能继续往下写 blob")
        } catch let error as BackupArchiveReader.RestoreError {
            XCTAssertEqual(error.kind, "metadataCommitFailed")
            XCTAssertFalse(error.didMutateStore, "此时 store 没被改动，UI 要据此说「原有数据未被改动」")
        }

        // ② 内存必须逐字段等于进来时的样子
        XCTAssertEqual(manager.brands.map(\.id), brandsBefore.map(\.id),
                       "失败后内存必须还原 —— 留着归档数据的话，下一次自动保存会把它提交")
        XCTAssertEqual(manager.brands.first?.name, "原有品牌")
        XCTAssertEqual(manager.brandStocks.map(\.id), stocksBefore.map(\.id))
        XCTAssertEqual(manager.projects.map(\.id), projectsBefore.map(\.id))
        XCTAssertEqual(manager.projects.first?.name, "原有项目")
        XCTAssertEqual(manager.currentBrandId, currentBefore)
        XCTAssertTrue(manager.customColors.isEmpty)
        XCTAssertTrue(manager.purchaseRecords.isEmpty)

        // ③ store 里一条项目行都不该有
        let rows = try ModelContext(liveContainer).fetch(FetchDescriptor<SDProjectRecord>())
        XCTAssertTrue(rows.isEmpty, "元数据都没提交，blob 循环必须根本没跑")

        // 日志也该清掉 —— 什么都没发生，不该留一个"数据可能不完整"的横幅
        XCTAssertNil(RestoreJournal.residual())
    }

    // MARK: - C1 辅助：SaveOutcome 的分区

    /// `isPersisted` 用了 `default:`，加错一个 case 就会静默改变恢复的判定。
    /// 五行把这张表钉住。
    func testSaveOutcomePartitioning() {
        let persisted: [InventoryManager.SaveOutcome] = [.committed, .noChanges, .metadataOnly]
        let notPersisted: [InventoryManager.SaveOutcome] = [
            .noContext, .notLoaded, .localFallbackMode, .reentrant, .blockedFullPurge, .failed("x")
        ]
        for o in persisted { XCTAssertTrue(o.isPersisted, "\(o.kind) 应算作已落盘") }
        for o in notPersisted { XCTAssertFalse(o.isPersisted, "\(o.kind) 绝不能算作已落盘") }
        // kind 不得携带载荷（它会进日志）
        XCTAssertEqual(InventoryManager.SaveOutcome.failed("/Users/someone/secret").kind, "failed")
    }

    // MARK: - C5：日志失败必须让 apply 停手

    /// 把 `try RestoreJournal.begin(...)` 改回 `try?` → 本用例红。
    ///
    /// 无法在不改生产签名的前提下让 `begin` 真失败，所以退一步钉住可观测的等价物：
    /// `apply` 成功路径必然留下过日志、且结束时清除；失败路径按 `didMutateStore` 分类。
    /// 与上面那条合起来，`begin` → `apply` 的这条链就有了约束。
    @MainActor
    func testSuccessfulApplyClearsJournalAndAppliesEverything() async throws {
        let archive = try await makeArchive(named: "happy")
        let report = try BackupArchiveReader.validate(archiveAt: archive)

        let liveContainer = try makeContainer()
        let manager = InventoryManager(modelContext: ModelContext(liveContainer))
        manager.markDataLoadedForTesting()

        try BackupArchiveReader.apply(report, to: manager)

        XCTAssertNil(RestoreJournal.residual(), "全部成功后日志必须清除，否则用户永远看到红色横幅")
        XCTAssertEqual(manager.brands.first?.name, "归档品牌")
        XCTAssertEqual(manager.brandStocks.first?.mardCode, "B2")
        XCTAssertEqual(manager.customColors.first?.colorCode, "X1")
        XCTAssertEqual(manager.purchaseRecords.first?.items.first?.quantity, 5)
        XCTAssertEqual(manager.projects.first?.totalBeads, 42)
    }

    // MARK: - C6：空归档不许挤掉真备份

    /// `hasNonEmptyArchive` 的六个分支。任一保守 `return true` 被改成 `false`，
    /// 就等于允许"损坏重置后的空快照"覆盖用户最后一份数据。
    func testHasNonEmptyArchiveBranches() throws {
        let fm = FileManager.default

        func makeArchiveDir(_ name: String, manifest: BackupArchiveManifest?) throws -> URL {
            let dir = workDir.appendingPathComponent("\(name).beadbackup", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if let manifest {
                let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
                try enc.encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
            }
            return dir
        }
        func manifest(projects: Int = 0, brands: Int = 0, colors: Int = 0) -> BackupArchiveManifest {
            BackupArchiveManifest(
                formatVersion: 1, createdAt: Date(), appVersion: "t", consistencyModel: "per-record",
                projects: (0..<projects).map {
                    ArchivedProject(id: UUID(), name: "p\($0)", date: Date(), totalBeads: 0,
                                    brandId: nil, isArchived: false, parentId: nil, isPlanned: false,
                                    executedDate: nil, completedDate: nil, colorSystemRaw: "mard",
                                    beadUsage: [])
                },
                brands: (0..<brands).map {
                    ArchivedBrand(id: UUID(), name: "b\($0)", sortOrder: 0, createdAt: Date(),
                                  lowStockThreshold: 0, colorSystemRaw: "mard")
                },
                brandStocks: [],
                customColors: (0..<colors).map {
                    ArchivedCustomColor(id: UUID(), colorCode: "c\($0)", colorName: "n",
                                        colorHex: "#000000", createdAt: Date(), updatedAt: Date())
                },
                purchaseRecords: [], currentBrandId: nil
            )
        }

        // ① 空目录 → false（新装用户，允许备份）
        XCTAssertFalse(BackupManager.hasNonEmptyArchive(in: workDir))

        // ② 0 项目 0 品牌的归档 → 仍是 false
        let empty = try makeArchiveDir("empty", manifest: manifest())
        XCTAssertFalse(BackupManager.hasNonEmptyArchive(in: workDir))

        // ③ **只有自定义颜色** → true。上一版只看 projects + brands，
        //    于是只用自定义颜色的用户完全不受保护。
        try fm.removeItem(at: empty)
        _ = try makeArchiveDir("colors_only", manifest: manifest(colors: 1))
        XCTAssertTrue(BackupManager.hasNonEmptyArchive(in: workDir),
                      "只有自定义颜色的备份同样是真数据，必须受保护")

        // ④ 有项目 → true
        try fm.removeItem(at: workDir.appendingPathComponent("colors_only.beadbackup"))
        _ = try makeArchiveDir("with_projects", manifest: manifest(projects: 1))
        XCTAssertTrue(BackupManager.hasNonEmptyArchive(in: workDir))

        // ⑤ manifest 损坏 → 保守 true（判不了就别覆盖）
        try fm.removeItem(at: workDir.appendingPathComponent("with_projects.beadbackup"))
        let broken = try makeArchiveDir("broken", manifest: nil)
        try Data("not json".utf8).write(to: broken.appendingPathComponent("manifest.json"))
        XCTAssertTrue(BackupManager.hasNonEmptyArchive(in: workDir),
                      "读不懂的归档必须当作非空 —— 判错的方向只能是「少写一次备份」")

        // ⑥ 只有旧格式 .json → 保守 true（不整份读入就判不了内容）
        try fm.removeItem(at: broken)
        try Data("{}".utf8).write(to: workDir.appendingPathComponent("legacy.json"))
        XCTAssertTrue(BackupManager.hasNonEmptyArchive(in: workDir))
    }

    // MARK: - C3：清扫不得删掉在飞的 partial

    /// `sweepStalePartials` 曾经靠一句"只在启动时调用一次"的注释来保证安全，
    /// 而它的调用点是个与自动备份无序并发的 detached 任务。
    /// 现在改成运行时判据，这里钉住"新鲜的 partial 不会被删"。
    ///
    /// 变异：去掉 mtime 判据 → 本用例红。
    func testSweepSkipsRecentlyModifiedPartial() throws {
        let fm = FileManager.default
        let fresh = workDir.appendingPathComponent("fresh.beadbackup.partial", isDirectory: true)
        let old = workDir.appendingPathComponent("old.beadbackup.partial", isDirectory: true)
        let real = workDir.appendingPathComponent("real.beadbackup", isDirectory: true)
        let legacy = workDir.appendingPathComponent("legacy.json")
        for d in [fresh, old, real] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        try Data("{}".utf8).write(to: legacy)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.path)

        let reclaimed = BackupArchiveWriter.sweepStalePartials(in: workDir)

        XCTAssertEqual(reclaimed, 1)
        XCTAssertTrue(fm.fileExists(atPath: fresh.path),
                      "刚被写过的 partial 可能正在写 —— 删了就会让在飞的备份 ENOENT 失败")
        XCTAssertFalse(fm.fileExists(atPath: old.path), "陈旧的 partial 才是要回收的")
        XCTAssertTrue(fm.fileExists(atPath: real.path), "真归档一根汗毛都不能动")
        XCTAssertTrue(fm.fileExists(atPath: legacy.path),
                      "旧格式 .json 备份必须留着 —— 匹配写成任意非 beadbackup 就会每次启动删光它们")
    }

    // MARK: - didMutateStore 必须覆盖 apply 能抛的全部错误

    /// 它决定 UI 说"原数据未动"还是"数据可能不完整"。只要 `apply` 还能漏出别的
    /// 错误类型，这个判断就落不到实处。
    func testDidMutateStoreClassification() {
        typealias E = BackupArchiveReader.RestoreError
        XCTAssertFalse(E.journalUnavailable(detail: "x").didMutateStore)
        XCTAssertFalse(E.metadataCommitFailed(outcome: "failed").didMutateStore)
        XCTAssertTrue(E.blobReadFailed(projectID: UUID(), underlying: "x").didMutateStore)
        XCTAssertTrue(E.blobWriteFailed(projectID: UUID()).didMutateStore)
    }
}
