//
//  BackupArchiveWriterTests.swift
//  BeadInventoryTests
//
//  写出器此前**一个测试都没有** —— 而它是本模块里唯一能造成永久数据丢失的部件。
//
//  已有的 `BackupArchiveRoundTripTests` 手工构造 manifest、编码再解码，那测的是 Swift 合成的
//  `Codable`，**测不到写出器的映射**。历史上丢 `patternGrid`（595/669 个项目）和漏
//  `purchaseRecords` 的 bug 都发生在映射里，那种测试一条也拦不住。
//
//  这里全部走**真实路径**：真的 SwiftData 容器 → 真的 `ProjectImageLoader` →
//  真的 `BackupArchiveWriter.write` → 真的 `BackupArchiveReader.validate`。
//

import XCTest
import SwiftData
import UIKit
@testable import BeadInventory

final class BackupArchiveWriterTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - 夹具

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func makePNG(side: CGFloat, color: UIColor) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }.pngData()!
    }

    private func partials() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "partial" } ?? []
    }

    // MARK: - 全字段 / 全 blob 的真实往返
    //
    // 这条替代了原来那个 manifest→manifest 的假往返。它能挡住的变异（每一条都对应
    // 真实发生过或差点发生的 bug）：
    //
    //   · `BackupArchive.swift` 里 `purchaseRecords:` 改成 `[]`      → 本用例红
    //   · 删掉 `patternGrid` 的 writeBlob 块                          → 本用例红
    //   · 四个 blob 里任意一个从写出映射中漏掉                          → 本用例红
    //
    // 旧夹具四个 blob 只填 thumbnail，所以后两条它一条也测不到。
    @MainActor
    func testWriterPreservesAllFourBlobsAndAllCollections() async throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)

        let thumb = makePNG(side: 12, color: .systemTeal)
        let finished = makePNG(side: 14, color: .systemGreen)
        let display = makePNG(side: 10, color: .systemPink)
        let grid = Data(#"{"rows":3,"cols":4}"#.utf8)

        let record = SDProjectRecord(
            name: "全字段项目",
            totalBeads: 777,
            thumbnail: thumb,
            finishedImage: finished,
            patternGridData: grid,
            displayThumbnail: display
        )
        ctx.insert(record)
        try ctx.save()

        let brandId = UUID()
        let snapshot = BackupArchiveWriter.MetadataSnapshot(
            projects: [ProjectRecord(id: record.id, name: "全字段项目", totalBeads: 777)],
            brands: [Brand(id: brandId, name: "测试品牌", sortOrder: 3)],
            brandStocks: [BrandStock(brandId: brandId, mardCode: "A1", stock: 50, used: 7)],
            customColors: [CustomColor(colorCode: "C9", colorHex: "#123456", colorName: "自定义")],
            purchaseRecords: [PurchaseRecord(
                name: "一次进货", brandId: brandId,
                items: [PurchaseItem(colorCode: "A1", quantity: 25)]
            )],
            currentBrandId: brandId,
            appVersion: "test"
        )

        let url = try await BackupArchiveWriter.write(
            snapshot: snapshot,
            imageLoader: ProjectImageLoader(container: container),
            to: workDir, archiveName: "roundtrip"
        )

        let report = try BackupArchiveReader.validate(archiveAt: url)
        let m = report.manifest

        // 四个 blob 全部落盘（这是旧夹具的盲区）
        XCTAssertEqual(report.blobCount, 4, "四种 blob 必须都写出去；少一种就是一次静默的图片丢失")
        let p = try XCTUnwrap(m.projects.first)
        XCTAssertNotNil(p.thumbnail)
        XCTAssertNotNil(p.finishedImage)
        XCTAssertNotNil(p.displayThumbnail)
        XCTAssertNotNil(p.patternGrid, "patternGrid 就是旧格式静默丢掉的那个字段")

        // 字节逐一比对 —— 只断言"非 nil"挡不住写错源的变异
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent(p.thumbnail!.file)), thumb)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent(p.finishedImage!.file)), finished)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent(p.displayThumbnail!.file)), display)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent(p.patternGrid!.file)), grid)

        // 五个集合一个都不能丢（purchaseRecords 是历史上漏过的那个）
        XCTAssertEqual(m.brands.count, 1)
        XCTAssertEqual(m.brandStocks.count, 1)
        XCTAssertEqual(m.customColors.count, 1)
        XCTAssertEqual(m.purchaseRecords.count, 1, "purchaseRecords 曾经整个漏掉过，编译器发现的，不是测试")
        XCTAssertEqual(m.purchaseRecords.first?.items.count, 1, "嵌套 items 也要跟着走")
        XCTAssertEqual(m.currentBrandId, brandId)
        XCTAssertTrue(partials().isEmpty, "成功提交后不该留下 .partial")
    }

    // MARK: - 失败必须回收 .partial

    /// 写出中途失败时，`.partial` 必须被回收。
    ///
    /// 泄漏是永久的：归档名带 `HHmmss` 所以两次运行永不撞名，而 `.partial` 的扩展名让
    /// `listArchives` / `getBackupList` / `cleanupOldBackups` 全都看不见它。
    /// 又因为 `stop()` 挂在 `.inactive` 上，取消是常态 —— 用户每拉一次控制中心就漏一份。
    ///
    /// 触发方式用的是真实失败路径：快照里有一个 store 里并不存在的项目，
    /// `blobs(for:)` 会抛错（它**刻意不返回"没有图"**，见该方法注释）。
    ///
    /// 变异检查：删掉 `write()` 里的 `defer { ... removeItem(partialURL) }` → 本用例红。
    @MainActor
    func testFailedWriteReclaimsPartial() async throws {
        let container = try makeContainer()

        let snapshot = BackupArchiveWriter.MetadataSnapshot(
            projects: [ProjectRecord(id: UUID(), name: "库里并不存在的项目")],
            brands: [], brandStocks: [], customColors: [], purchaseRecords: [],
            currentBrandId: nil, appVersion: "test"
        )

        do {
            _ = try await BackupArchiveWriter.write(
                snapshot: snapshot,
                imageLoader: ProjectImageLoader(container: container),
                to: workDir, archiveName: "will_fail"
            )
            XCTFail("项目行不存在时必须抛错，绝不能当成「这条没图」继续写")
        } catch {
            // 预期
        }

        XCTAssertTrue(partials().isEmpty,
                      "失败后 .partial 必须被回收，否则每次中断都永久占盘且 App 内不可见")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: workDir.appendingPathComponent("will_fail.beadbackup").path),
            "失败绝不能产出可列出的归档"
        )
    }

    // MARK: - 启动清扫

    /// 进程被 SIGKILL 时 `write()` 的 defer 不会执行，那种 `.partial` 只能靠启动清扫回收。
    ///
    /// 变异检查：让 `sweepStalePartials` 返回 0 且不删任何东西 → 第一条断言红。
    /// 把过滤条件写成"删所有目录" → 第二条断言红。
    func testSweepRemovesPartialsButKeepsRealArchives() throws {
        let fm = FileManager.default
        let stale = workDir.appendingPathComponent("backup_a.beadbackup.partial", isDirectory: true)
        let real = workDir.appendingPathComponent("backup_b.beadbackup", isDirectory: true)
        try fm.createDirectory(at: stale, withIntermediateDirectories: true)
        try fm.createDirectory(at: real, withIntermediateDirectories: true)

        let reclaimed = BackupArchiveWriter.sweepStalePartials(in: workDir)

        XCTAssertEqual(reclaimed, 1)
        XCTAssertFalse(fm.fileExists(atPath: stale.path), "残留的 .partial 必须被清掉")
        XCTAssertTrue(fm.fileExists(atPath: real.path), "真归档一根汗毛都不能动")
    }

    // MARK: - 恢复日志

    /// `RestoreJournal.begin` 必须能**失败并让调用方知道**。
    ///
    /// 它以前每一步都是 `try?` 且返回 Void：磁盘将满时日志写不下去，`apply` 照常改数据，
    /// 半恢复状态就永远不会被发现 —— 而磁盘将满既是日志写失败的原因，也是后续
    /// blob 写失败的原因，两者高度相关。
    ///
    /// 这里只能钉住正常路径可用 + 生命周期正确（注入一个坏目录需要改生产签名，不值得）。
    func testRestoreJournalLifecycle() throws {
        let archive = workDir.appendingPathComponent("some.beadbackup")

        try RestoreJournal.begin(archive: archive)
        defer { RestoreJournal.finish() }

        let entry = try XCTUnwrap(RestoreJournal.residual(), "begin 之后必须读得到残留")
        XCTAssertEqual(entry.archivePath, archive.path)
        XCTAssertEqual(entry.phase, "metadata")

        RestoreJournal.setPhase("blobs")
        XCTAssertEqual(RestoreJournal.residual()?.phase, "blobs")

        RestoreJournal.finish()
        XCTAssertNil(RestoreJournal.residual(), "全部成功后日志必须被清除，否则用户会永远看到红色横幅")
    }
}
