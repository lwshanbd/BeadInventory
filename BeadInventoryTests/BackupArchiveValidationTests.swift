//
//  BackupArchiveValidationTests.swift
//  BeadInventoryTests
//
//  归档校验器的对抗测试。
//
//  这些用例不是"覆盖率"性质的 —— 归档将来可由用户从「文件」App 导入,
//  也就是说 **manifest 是不可信输入**。下面每一条都对应一种真实可构造的攻击或损坏,
//  而恢复恰恰是在用户数据已经出问题时才做的操作:此时再给他一个半损坏的库,
//  是所有结果里最坏的一个。
//
//  契约是:**`validate()` 通过之前,一个字节都不写入 store。**

import XCTest
import CryptoKit
@testable import BeadInventory

final class BackupArchiveValidationTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-test-\(UUID().uuidString).beadbackup")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("blobs"), withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - 构造工具

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 写一个 blob 文件并返回**如实**的引用。
    @discardableResult
    private func writeBlob(_ data: Data, name: String) throws -> ArchivedBlobRef {
        let url = root.appendingPathComponent("blobs/\(name)")
        try data.write(to: url)
        return ArchivedBlobRef(file: "blobs/\(name)", bytes: data.count, sha256: sha256(data))
    }

    private func writeManifest(
        formatVersion: Int = BackupArchiveWriter.currentFormatVersion,
        thumbnail: ArchivedBlobRef?
    ) throws {
        let project = ArchivedProject(
            id: UUID(), name: "P", date: Date(), totalBeads: 0, brandId: nil,
            isArchived: false, parentId: nil, isPlanned: false, executedDate: nil,
            completedDate: nil, colorSystemRaw: "MARD", beadUsage: [],
            thumbnail: thumbnail, finishedImage: nil, displayThumbnail: nil, patternGrid: nil
        )
        let manifest = BackupArchiveManifest(
            formatVersion: formatVersion, createdAt: Date(), appVersion: "test",
            consistencyModel: "per-record", projects: [project],
            brands: [], brandStocks: [], customColors: [], purchaseRecords: [], currentBrandId: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: root.appendingPathComponent("manifest.json"))
    }

    /// 按 `kind` 比对拒绝原因。
    ///
    /// 不比 `description` —— 那是给人看的文案，会随实现变化（而且带 payload，
    /// 用它做断言就是把测试钉在错误消息的措辞上）。
    private func assertRejects(
        _ expectedKind: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try BackupArchiveReader.validate(archiveAt: root), file: file, line: line) { error in
            guard let actual = error as? BackupArchiveReader.ValidationError else {
                return XCTFail("期望 ValidationError，实际 \(error)", file: file, line: line)
            }
            XCTAssertEqual(actual.kind, expectedKind,
                           "拒绝原因不符：期望 \(expectedKind)，实际 \(actual)", file: file, line: line)
        }
    }

    // MARK: - 正常路径

    func testValidArchivePasses() throws {
        let ref = try writeBlob(Data(repeating: 0xAB, count: 1024), name: "a.thumbnail")
        try writeManifest(thumbnail: ref)

        let report = try BackupArchiveReader.validate(archiveAt: root)
        XCTAssertEqual(report.blobCount, 1)
        XCTAssertEqual(report.totalBlobBytes, 1024)
        XCTAssertEqual(report.manifest.consistencyModel, "per-record")
    }

    // MARK: - 路径穿越

    /// manifest 声明一个用 `..` 跳出归档根的路径 —— 通过就等于把任意文件当图片读进库。
    func testRejectsParentDirectoryTraversal() throws {
        try writeManifest(thumbnail: ArchivedBlobRef(
            file: "blobs/../../../../etc/passwd", bytes: 1, sha256: "x"
        ))
        assertRejects("unsafeBlobPath")
    }

    func testRejectsAbsolutePath() throws {
        try writeManifest(thumbnail: ArchivedBlobRef(file: "/etc/passwd", bytes: 1, sha256: "x"))
        assertRejects("unsafeBlobPath")
    }

    /// 只做路径字符串检查挡不住这个:归档里放一条指向外部的符号链接,
    /// 路径本身完全"干净",解析后却在根外。
    func testRejectsSymlinkEscapingArchiveRoot() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString).bin")
        try Data(repeating: 0x01, count: 32).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let link = root.appendingPathComponent("blobs/sneaky.thumbnail")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        try writeManifest(thumbnail: ArchivedBlobRef(
            file: "blobs/sneaky.thumbnail", bytes: 32, sha256: sha256(Data(repeating: 0x01, count: 32))
        ))
        assertRejects("unsafeBlobPath")
    }

    // MARK: - 完整性

    func testRejectsChecksumMismatch() throws {
        let data = Data(repeating: 0xAB, count: 512)
        let url = root.appendingPathComponent("blobs/a.thumbnail")
        try data.write(to: url)
        // 大小如实、校验和撒谎 —— 模拟内容被篡改。
        try writeManifest(thumbnail: ArchivedBlobRef(
            file: "blobs/a.thumbnail", bytes: 512, sha256: String(repeating: "0", count: 64)
        ))
        assertRejects("checksumMismatch")
    }

    func testRejectsSizeMismatch() throws {
        let data = Data(repeating: 0xAB, count: 512)
        try data.write(to: root.appendingPathComponent("blobs/a.thumbnail"))
        try writeManifest(thumbnail: ArchivedBlobRef(
            file: "blobs/a.thumbnail", bytes: 999, sha256: sha256(data)
        ))
        assertRejects("blobSizeMismatch")
    }

    func testRejectsMissingBlob() throws {
        try writeManifest(thumbnail: ArchivedBlobRef(
            file: "blobs/nope.thumbnail", bytes: 10, sha256: "x"
        ))
        assertRejects("blobMissing")
    }

    // MARK: - 格式版本

    /// 未来格式一律拒绝。"尽力而为"解析只会用半懂的数据覆盖用户旧数据。
    func testRejectsFutureFormatVersion() throws {
        let ref = try writeBlob(Data(repeating: 0x01, count: 8), name: "a.thumbnail")
        try writeManifest(formatVersion: BackupArchiveWriter.currentFormatVersion + 1, thumbnail: ref)
        assertRejects("unsupportedFormatVersion")
    }

    func testRejectsMissingManifest() throws {
        assertRejects("manifestMissing")
    }

    func testRejectsUndecodableManifest() throws {
        try Data("{ not json".utf8).write(to: root.appendingPathComponent("manifest.json"))
        assertRejects("manifestUndecodable")
    }

    // MARK: - 半成品不可见

    /// `.partial` 是中断留下的半成品。被列出来就意味着用户可能拿残缺数据覆盖好数据。
    func testPartialArchivesAreNotListed() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("list-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("good.beadbackup"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("broken.beadbackup.partial"), withIntermediateDirectories: true)

        let listed = BackupArchiveWriter.listArchives(in: dir)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.lastPathComponent, "good.beadbackup")
    }
}
