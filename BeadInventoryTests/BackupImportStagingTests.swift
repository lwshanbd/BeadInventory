//
//  BackupImportStagingTests.swift
//  BeadInventoryTests
//
//  导入 staging 的对抗测试。
//
//  这层直接吃**用户从「文件」App 选来的外部 package**,是全工程唯一一处不可信输入入口。
//  下面每条都对应一种真实可构造的攻击或损坏。
//
//  被钉住的核心不变量:
//
//    1. **只复制 manifest 引用的条目。** 目录里塞的额外文件(比如一个 200 GB 的垃圾文件)
//       一概不进来 —— 这同时消掉了 `BackupArchiveReader.validate()` 的盲区:
//       它只遍历 manifest 引用的 blob,**从不列举目录实际内容**,看不见额外文件。
//       所以"先整体 copyItem 再校验"是资源耗尽入口,必须按清单流式复制。
//    2. **大小以源文件实际值为准**,不信 manifest 的声明值。
//    3. **符号链接一律拒绝**,不跟进。

import XCTest
import CryptoKit
@testable import BeadInventory

final class BackupImportStagingTests: XCTestCase {

    private var source: URL!

    override func setUpWithError() throws {
        source = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-src-\(UUID().uuidString).beadbackup")
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("blobs"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: source)
        // 清掉本组用例产生的 staging
        if let root = try? BackupImportStaging.stagingRoot() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - 构造

    private func sha256(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    private func writeBlob(_ data: Data, name: String) throws -> ArchivedBlobRef {
        try data.write(to: source.appendingPathComponent("blobs/\(name)"))
        return ArchivedBlobRef(file: "blobs/\(name)", bytes: data.count, sha256: sha256(data))
    }

    private func writeManifest(thumbnail: ArchivedBlobRef?,
                               formatVersion: Int = BackupArchiveWriter.currentFormatVersion) throws {
        let project = ArchivedProject(
            id: UUID(), name: "P", date: Date(), totalBeads: 0, brandId: nil,
            isArchived: false, parentId: nil, isPlanned: false, executedDate: nil,
            completedDate: nil, colorSystemRaw: "MARD", beadUsage: [],
            thumbnail: thumbnail, finishedImage: nil, displayThumbnail: nil, patternGrid: nil)
        let m = BackupArchiveManifest(
            formatVersion: formatVersion, createdAt: Date(), appVersion: "t",
            consistencyModel: "per-record", projects: [project],
            brands: [], brandStocks: [], customColors: [], purchaseRecords: [], currentBrandId: nil)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(m).write(to: source.appendingPathComponent("manifest.json"))
    }

    private func assertPlanRejects(_ kind: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try BackupImportStaging.makePlan(source: source), file: file, line: line) { e in
            guard let err = e as? BackupImportStaging.StagingError else {
                return XCTFail("期望 StagingError，实际 \(e)", file: file, line: line)
            }
            XCTAssertEqual(err.kind, kind, "拒绝原因不符：实际 \(err)", file: file, line: line)
        }
    }

    // MARK: - 核心不变量:未引用的文件不进 staging

    /// 目录里塞一个 manifest 完全没引用的大文件。
    ///
    /// 这条是整个 staging 设计存在的理由：`validate()` 只走 manifest 引用的 blob，
    /// **看不见**这种文件。若按"先整体复制再校验"做，复制这一步就会把它搬进来
    /// （真实攻击里可以是 200 GB），盘先满了才轮到校验。
    func testUnreferencedFilesAreNotCopied() throws {
        let ref = try writeBlob(Data(repeating: 0xAB, count: 1024), name: "a.thumbnail")
        try writeManifest(thumbnail: ref)
        // 未被引用的"垃圾"文件（测试里用 1 MB 代表那个 200 GB）
        try Data(repeating: 0xFF, count: 1024 * 1024)
            .write(to: source.appendingPathComponent("blobs/unreferenced.bin"))
        try Data(repeating: 0xFF, count: 4096)
            .write(to: source.appendingPathComponent("stray-at-root.bin"))

        let plan = try BackupImportStaging.makePlan(source: source)
        // 计划里只有 manifest.json + 被引用的那一个 blob
        XCTAssertEqual(plan.entries.count, 2)
        XCTAssertFalse(plan.entries.contains { $0.relativePath.contains("unreferenced") })
        XCTAssertFalse(plan.entries.contains { $0.relativePath.contains("stray") })

        let staged = try BackupImportStaging.materialize(plan, source: source)
        defer { try? FileManager.default.removeItem(at: staged) }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: staged.appendingPathComponent("blobs/unreferenced.bin").path),
            "未被引用的文件绝不能进 staging")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: staged.appendingPathComponent("stray-at-root.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: staged.appendingPathComponent("blobs/a.thumbnail").path))

        // staging 出来的东西必须能通过完整校验
        let report = try BackupArchiveReader.validate(archiveAt: staged)
        XCTAssertEqual(report.blobCount, 1)
    }

    // MARK: - 大小以源文件实际值为准

    /// manifest 谎报大小（说 1 字节、实际 5 MB）。预检必须按**实际**算，否则
    /// 磁盘预检和总量上限都会被绕过。
    func testUsesActualFileSizeNotDeclared() throws {
        let data = Data(repeating: 0xAB, count: 5 * 1024 * 1024)
        try data.write(to: source.appendingPathComponent("blobs/a.thumbnail"))
        try writeManifest(thumbnail: ArchivedBlobRef(
            file: "blobs/a.thumbnail", bytes: 1, sha256: sha256(data)))

        let plan = try BackupImportStaging.makePlan(source: source)
        XCTAssertGreaterThan(plan.totalBytes, 5 * 1024 * 1024,
                             "总量必须按源文件实际大小计，不能采信 manifest 的声明值")
    }

    func testRejectsOversizedEntry() throws {
        let url = source.appendingPathComponent("blobs/big.thumbnail")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: UInt64(BackupArchiveReader.maxBlobBytes) + 1)
        try h.close()
        try writeManifest(thumbnail: ArchivedBlobRef(file: "blobs/big.thumbnail", bytes: 1, sha256: "x"))
        assertPlanRejects("entryTooLarge")
    }

    // MARK: - 路径与链接

    func testRejectsSymlinkEntry() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString).bin")
        try Data(repeating: 1, count: 16).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("blobs/link.thumbnail"), withDestinationURL: outside)
        try writeManifest(thumbnail: ArchivedBlobRef(file: "blobs/link.thumbnail", bytes: 16, sha256: "x"))
        // safeBlobURL 先判出越界；无论落在哪一条，都必须拒绝。
        XCTAssertThrowsError(try BackupImportStaging.makePlan(source: source)) { e in
            let kind = (e as? BackupImportStaging.StagingError)?.kind
            XCTAssertTrue(kind == "symlinkRejected" || kind == "unsafePath", "实际 \(e)")
        }
    }

    func testRejectsPathTraversal() throws {
        try writeManifest(thumbnail: ArchivedBlobRef(
            file: "blobs/../../../../etc/passwd", bytes: 1, sha256: "x"))
        assertPlanRejects("unsafePath")
    }

    // MARK: - 清单本身

    func testRejectsMissingManifest() throws {
        assertPlanRejects("manifestMissing")
    }

    func testRejectsWrongFormatVersion() throws {
        let ref = try writeBlob(Data(repeating: 1, count: 8), name: "a.thumbnail")
        try writeManifest(thumbnail: ref, formatVersion: 99)
        assertPlanRejects("unsupportedFormatVersion")
    }

    func testRejectsMissingReferencedBlob() throws {
        try writeManifest(thumbnail: ArchivedBlobRef(file: "blobs/nope.thumbnail", bytes: 8, sha256: "x"))
        assertPlanRejects("entryMissing")
    }

    // MARK: - staging 生命周期

    /// `RestoreJournal` 指向这份 staging 时**绝不能删** —— 用户重跑恢复靠的就是它。
    /// 删了的话，红色横幅上那个"重新恢复该归档"按钮会找不到归档。
    func testStagingRetainedWhileRestoreJournalPointsAtIt() throws {
        let ref = try writeBlob(Data(repeating: 0xAB, count: 128), name: "a.thumbnail")
        try writeManifest(thumbnail: ref)
        let plan = try BackupImportStaging.makePlan(source: source)
        let staged = try BackupImportStaging.materialize(plan, source: source)

        RestoreJournal.begin(archive: staged)
        defer { RestoreJournal.finish() }

        BackupImportStaging.cleanupIfSafe(staged)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path),
                      "恢复日志指向它时必须保留，否则重试机制失效")

        RestoreJournal.finish()
        BackupImportStaging.cleanupIfSafe(staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path),
                       "日志清除后应当回收")
    }
}
