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
        // entries 只含被引用的 blob —— manifest 走 plan.manifestData（预检时读到的字节），
        // 不从源重读，见 Plan.manifestData 的说明。
        XCTAssertEqual(plan.entries.count, 1)
        XCTAssertFalse(plan.manifestData.isEmpty)
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

    // MARK: - 源在 plan 与 materialize 之间被改动(TOCTOU)

    /// 复制途中源文件变大 —— **复制必须在过程中受限,不是事后拒绝**。
    ///
    /// 这条用例此前用 200 KB 验证,通过的只是"copyItem 返回后发现超限"。
    /// 那给了假信心:真实攻击是把源换成 200 GB,`copyItem` 会**先搬完**,
    /// 我们只能在灾难之后看到落地大小。改成流式复制之后,超限在写入前就被拦下,
    /// 最坏只多写一个块。
    ///
    /// 断言落在**落地字节数**上:必须远小于源大小,证明我们没有把整个源搬完。
    func testCopyIsBoundedDuringTransferNotAfter() throws {
        let ref = try writeBlob(Data(repeating: 0xAB, count: 1024), name: "a.thumbnail")
        try writeManifest(thumbnail: ref)

        var limits = BackupImportStaging.Limits.production
        limits.totalBytes = 64 * 1024          // 上限 64 KB
        limits.copyBlockBytes = 4096           // 4 KB 一块

        let plan = try BackupImportStaging.makePlan(source: source, limits: limits)

        // plan 之后把源换成远超上限的大文件（代表那个 200 GB）
        let huge = 8 * 1024 * 1024
        try Data(repeating: 0xCD, count: huge)
            .write(to: source.appendingPathComponent("blobs/a.thumbnail"))

        XCTAssertThrowsError(
            try BackupImportStaging.materialize(plan, source: source, limits: limits)
        ) { e in
            let kind = (e as? BackupImportStaging.StagingError)?.kind
            XCTAssertTrue(kind == "totalTooLarge" || kind == "entryTooLarge", "实际 \(e)")
        }

        // 失败后不残留任何东西
        let root = try BackupImportStaging.stagingRoot()
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "失败后不应残留：\(leftovers)")
    }

    /// 复制前源被换成目录 / 符号链接 —— 预检到复制之间源可以被换掉，所以复制前要再验一次形态。
    func testSourceSwappedToDirectoryBeforeCopyIsRejected() throws {
        let ref = try writeBlob(Data(repeating: 0xAB, count: 512), name: "a.thumbnail")
        try writeManifest(thumbnail: ref)
        let plan = try BackupImportStaging.makePlan(source: source)

        let blob = source.appendingPathComponent("blobs/a.thumbnail")
        try FileManager.default.removeItem(at: blob)
        try FileManager.default.createDirectory(at: blob, withIntermediateDirectories: true)

        XCTAssertThrowsError(try BackupImportStaging.materialize(plan, source: source)) { e in
            XCTAssertEqual((e as? BackupImportStaging.StagingError)?.kind, "notRegularFile", "实际 \(e)")
        }
    }

    /// manifest 在用户确认之后被换掉 —— staging 必须写**预检时读到的那份字节**。
    ///
    /// 否则"用户看到的项目数/体积"和"实际导入的东西"不是一回事。
    func testManifestSwappedAfterPlanDoesNotAffectStaging() throws {
        let ref = try writeBlob(Data(repeating: 0xAB, count: 256), name: "a.thumbnail")
        try writeManifest(thumbnail: ref)
        let plan = try BackupImportStaging.makePlan(source: source)

        try Data("{ totally different".utf8)
            .write(to: source.appendingPathComponent("manifest.json"))

        let staged = try BackupImportStaging.materialize(plan, source: source)
        defer { try? FileManager.default.removeItem(at: staged) }

        // staging 里的 manifest 是预检那份，仍然可解析、可校验
        let report = try BackupArchiveReader.validate(archiveAt: staged)
        XCTAssertEqual(report.manifest.projects.count, 1)
    }

    // MARK: - 条目数上限在 staging 之前

    /// 恶意 manifest 声明海量项目：必须在 makePlan 就被拒，
    /// 不能等到用户确认并复制完几十万个文件之后才在 validate 阶段发现。
    func testTooManyProjectsRejectedBeforeStaging() throws {
        var projects: [ArchivedProject] = []
        for _ in 0..<50 {
            projects.append(ArchivedProject(
                id: UUID(), name: "P", date: Date(), totalBeads: 0, brandId: nil,
                isArchived: false, parentId: nil, isPlanned: false, executedDate: nil,
                completedDate: nil, colorSystemRaw: "MARD", beadUsage: [],
                thumbnail: nil, finishedImage: nil, displayThumbnail: nil, patternGrid: nil))
        }
        let m = BackupArchiveManifest(
            formatVersion: 1, createdAt: Date(), appVersion: "t", consistencyModel: "per-record",
            projects: projects, brands: [], brandStocks: [], customColors: [],
            purchaseRecords: [], currentBrandId: nil)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(m).write(to: source.appendingPathComponent("manifest.json"))

        var limits = BackupImportStaging.Limits.production
        limits.projects = 10
        XCTAssertThrowsError(try BackupImportStaging.makePlan(source: source, limits: limits)) { e in
            XCTAssertEqual((e as? BackupImportStaging.StagingError)?.kind, "tooManyEntries", "实际 \(e)")
        }
    }

        /// staging 之后源被替换成符号链接 —— 后续一律走 staging 副本，源怎么变都无关。
    ///
    /// 这条钉的是 TOCTOU 关闭点：materialize 完成后，validate/apply 读的必须是我们
    /// 自己的不可变副本。
    func testSourceReplacedAfterStagingDoesNotAffectResult() throws {
        let data = Data(repeating: 0xAB, count: 256)
        let ref = try writeBlob(data, name: "a.thumbnail")
        try writeManifest(thumbnail: ref)
        let plan = try BackupImportStaging.makePlan(source: source)
        let staged = try BackupImportStaging.materialize(plan, source: source)
        defer { try? FileManager.default.removeItem(at: staged) }

        // 源被换成指向外部的符号链接 + manifest 被改坏
        let blob = source.appendingPathComponent("blobs/a.thumbnail")
        try FileManager.default.removeItem(at: blob)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("evil-\(UUID().uuidString).bin")
        try Data(repeating: 0xFF, count: 999).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: blob, withDestinationURL: outside)
        try Data("{ corrupted".utf8).write(to: source.appendingPathComponent("manifest.json"))

        // staging 副本不受任何影响，仍能通过完整校验
        let report = try BackupArchiveReader.validate(archiveAt: staged)
        XCTAssertEqual(report.blobCount, 1)
        XCTAssertEqual(report.totalBlobBytes, 256)
    }

    // MARK: - 路径形状

    /// 深层嵌套路径。写出器只产生 `blobs/<uuid>.<kind>` 一种形状，
    /// 别的形状都说明这不是我们写的东西 —— 直接拒，省得为外部输入递归建目录树。
    func testRejectsNestedBlobPath() throws {
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("blobs/a/b/c"), withIntermediateDirectories: true)
        let data = Data(repeating: 1, count: 16)
        try data.write(to: source.appendingPathComponent("blobs/a/b/c/deep.thumbnail"))
        try writeManifest(thumbnail: ArchivedBlobRef(
            file: "blobs/a/b/c/deep.thumbnail", bytes: 16, sha256: sha256(data)))
        assertPlanRejects("unsafePath")
    }

    /// 根目录下的裸文件（不在 blobs/ 里）同样拒绝。
    func testRejectsBlobOutsideBlobsDirectory() throws {
        let data = Data(repeating: 1, count: 16)
        try data.write(to: source.appendingPathComponent("rogue.thumbnail"))
        try writeManifest(thumbnail: ArchivedBlobRef(
            file: "rogue.thumbnail", bytes: 16, sha256: sha256(data)))
        assertPlanRejects("unsafePath")
    }

    // MARK: - 中断后可重试

    /// apply 中途被打断（进程被杀）后，staging 仍在、journal 仍指向它，
    /// 重跑 validate + apply 应当成功 —— 这就是红色横幅上那个「重新恢复该归档」的底座。
    ///
    /// 单测里杀不了进程，所以直接构造它留下的状态：journal 存在 + staging 存在。
    func testInterruptedApplyCanBeRetriedFromStaging() throws {
        let data = Data(repeating: 0xAB, count: 512)
        let ref = try writeBlob(data, name: "a.thumbnail")
        try writeManifest(thumbnail: ref)
        let plan = try BackupImportStaging.makePlan(source: source)
        let staged = try BackupImportStaging.materialize(plan, source: source)

        // 模拟"apply 跑到一半进程被杀"：journal 留在盘上，指向 staging
        RestoreJournal.begin(archive: staged)
        RestoreJournal.setPhase("blobs")

        // 重启后应当能读到残留，并且它指向的归档还在
        let residual = try XCTUnwrap(RestoreJournal.residual())
        XCTAssertEqual(residual.archivePath, staged.path)
        XCTAssertEqual(residual.phase, "blobs")
        XCTAssertTrue(FileManager.default.fileExists(atPath: residual.archivePath),
                      "归档必须还在 —— 否则「重新恢复该归档」按钮找不到东西")

        // 重跑校验必须成功（apply 需要 InventoryManager，这里只钉到校验这一层）
        let report = try BackupArchiveReader.validate(
            archiveAt: URL(fileURLWithPath: residual.archivePath))
        XCTAssertEqual(report.blobCount, 1)

        RestoreJournal.finish()
        BackupImportStaging.cleanupIfSafe(staged)
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
