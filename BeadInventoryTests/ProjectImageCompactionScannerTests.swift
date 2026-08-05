//
//  ProjectImageCompactionScannerTests.swift
//  BeadInventoryTests
//
//  钉住 `ProjectImageCompactionScanner` 成立的那个前提：
//  `WHERE length(ZTHUMBNAIL) > ?` **不会把 blob 内容读进内存**。
//
//  SQLite 对「length() 的实参是直接列引用」有专门优化（代码生成时给 OP_Column 打
//  OPFLAG_LENGTHARG，只读记录头里的 serial type，不追 overflow page 链）。这是实现细节，
//  不是 API 契约 —— 万一未来变了，必须让测试先红，而不是等用户 jetsam。
//
//  对照组是 SwiftData 的 BLOB 谓词：同一个库上实测 +1.26 GB（见
//  InitialLoadMemoryDiagnosticTests），正是「转圈转着转着闪退」的机制。
//

import XCTest
import SwiftData
import UIKit
@testable import BeadInventory

final class ProjectImageCompactionScannerTests: XCTestCase {
    private var storeDir: URL!

    override func setUpWithError() throws {
        storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("compaction-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        ThumbnailMigrationCoordinator.resetStubbornIDsForTesting()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storeDir)
        ThumbnailMigrationCoordinator.resetStubbornIDsForTesting()
    }

    /// jetsam 依据的 phys_footprint（MB）
    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / 1_048_576
    }

    /// 不可压缩的随机字节 —— 保证每行真的占那么多磁盘（用纯色图会被 PNG 压掉，测不出东西）。
    private func makeFatBlob(bytes: Int) -> Data {
        var d = Data(count: bytes)
        d.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        return d
    }

    private func makeStore(
        fatCount: Int,
        fatBytes: Int,
        thinCount: Int
    ) throws -> (container: ModelContainer, storeURL: URL, fatIDs: Set<UUID>) {
        let storeURL = storeDir.appendingPathComponent("scan.store")
        let config = ModelConfiguration(url: storeURL, cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: SDBrand.self, SDBrandStock.self, SDProjectRecord.self,
            SDBeadUsage.self, SDCustomColor.self, SDHistoryRecord.self, SDColorScheme.self,
            configurations: config
        )
        let ctx = ModelContext(container)
        var fatIDs = Set<UUID>()
        for i in 0..<fatCount {
            let r = SDProjectRecord(
                name: "胖行\(i)",
                thumbnail: makeFatBlob(bytes: fatBytes),
                // 已经有小图 —— 保证它被选中的唯一理由是「字节数超阈值」，
                // 否则这个测试会被「缺 displayThumbnail」那条分支蒙混过关。
                displayThumbnail: Data([0xFF, 0xD8, 0xFF])
            )
            ctx.insert(r)
            fatIDs.insert(r.id)
        }
        for i in 0..<thinCount {
            ctx.insert(SDProjectRecord(
                name: "瘦行\(i)",
                thumbnail: makeFatBlob(bytes: 50_000),
                displayThumbnail: Data([0xFF, 0xD8, 0xFF])
            ))
        }
        try ctx.save()
        return (container, storeURL, fatIDs)
    }

    // MARK: - 核心：零物化

    func test_scan_does_not_materialize_blobs() throws {
        // 40 × 13 MB ≈ 520 MB 磁盘。若 length() 真的把 blob 读进来，footprint 会涨几百 MB。
        let fatBytes = 13 * 1024 * 1024
        let (container, storeURL, fatIDs) = try makeStore(
            fatCount: 40, fatBytes: fatBytes, thinCount: 60
        )
        _ = container   // 保活，别让 store 在扫描前被回收

        // 让种子期间的临时内存先落下去
        autoreleasepool { }
        let before = Self.footprintMB()

        let result = ProjectImageCompactionScanner.scanCandidates(
            storeURL: storeURL,
            thresholdBytes: ProjectImageEncoder.compactionThresholdBytes,
            limit: 1000,
            excluding: []
        )

        let after = Self.footprintMB()
        let delta = after - before
        print("[compaction-scan] footprint \(before)MB → \(after)MB  delta=\(delta)MB  (磁盘胖数据 \(40 * fatBytes / 1_048_576)MB)")

        guard case .success(let ids) = result else {
            return XCTFail("扫描失败：\(result)")
        }
        XCTAssertEqual(Set(ids), fatIDs, "应当且仅当命中超阈值的行")

        XCTAssertLessThan(
            delta, 100,
            "扫描增量 \(delta)MB —— length() 把 blob 内容读进内存了，"
            + "SQLite 的 OPFLAG_LENGTHARG 优化不再成立，扫描器必须换实现"
        )
    }

    // MARK: - 选行条件

    func test_scan_picks_rows_missing_display_thumbnail() throws {
        let storeURL = storeDir.appendingPathComponent("scan.store")
        let config = ModelConfiguration(url: storeURL, cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: SDBrand.self, SDBrandStock.self, SDProjectRecord.self,
            SDBeadUsage.self, SDCustomColor.self, SDHistoryRecord.self, SDColorScheme.self,
            configurations: config
        )
        let ctx = ModelContext(container)
        // 小图缺失但字节数很小 —— 只能靠第二条命中条件选中
        let needsBackfill = SDProjectRecord(
            name: "老数据", thumbnail: Data(repeating: 7, count: 40_000), displayThumbnail: nil
        )
        ctx.insert(needsBackfill)
        ctx.insert(SDProjectRecord(
            name: "干净", thumbnail: Data(repeating: 7, count: 40_000),
            displayThumbnail: Data([0xFF, 0xD8, 0xFF])
        ))
        try ctx.save()

        let result = ProjectImageCompactionScanner.scanCandidates(
            storeURL: storeURL,
            thresholdBytes: ProjectImageEncoder.compactionThresholdBytes,
            limit: 100,
            excluding: []
        )
        guard case .success(let ids) = result else { return XCTFail("扫描失败：\(result)") }
        XCTAssertEqual(ids, [needsBackfill.id])
    }

    func test_scan_honours_exclusions_and_limit() throws {
        let (container, storeURL, fatIDs) = try makeStore(
            fatCount: 5, fatBytes: 3 * 1024 * 1024, thinCount: 0
        )
        _ = container

        let excluded = Set(fatIDs.prefix(2))
        let result = ProjectImageCompactionScanner.scanCandidates(
            storeURL: storeURL,
            thresholdBytes: ProjectImageEncoder.compactionThresholdBytes,
            limit: 100,
            excluding: excluded
        )
        guard case .success(let ids) = result else { return XCTFail("扫描失败：\(result)") }
        XCTAssertEqual(Set(ids), fatIDs.subtracting(excluded),
                       "排除集合必须生效 —— 否则 stubborn 行每轮都被重新选中，死循环重写")

        // limit 生效，且**排除项不占 limit 名额**（实现里多取 excluding.count 行再过滤）
        let limited = ProjectImageCompactionScanner.scanCandidates(
            storeURL: storeURL,
            thresholdBytes: ProjectImageEncoder.compactionThresholdBytes,
            limit: 2,
            excluding: excluded
        )
        guard case .success(let limitedIDs) = limited else { return XCTFail("扫描失败：\(limited)") }
        XCTAssertEqual(limitedIDs.count, 2)
        XCTAssertTrue(Set(limitedIDs).isDisjoint(with: excluded))
    }

    /// 库文件不存在（in-memory 测试库就是这种）必须报 `.unsupportedStore` 而不是 `.transient` ——
    /// 调用方靠这个区分「永久回退」和「稍后重试」。
    func test_scan_reports_unsupported_for_missing_store() {
        let missing = storeDir.appendingPathComponent("nope.store")
        let result = ProjectImageCompactionScanner.scanCandidates(
            storeURL: missing, thresholdBytes: 1000, limit: 10, excluding: []
        )
        XCTAssertEqual(result, .failure(.unsupportedStore))
    }
}
