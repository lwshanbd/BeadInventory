//
//  StoreCompactionIntegrationTests.swift
//  BeadInventoryTests
//
//  端到端：在**真实文件库**上（不是 in-memory）复现用户那台设备的形态 —— 每行内联一张
//  ~13 MB 的全分辨率 PNG —— 然后跑整条瘦身链路，量三件事：
//
//    1. 逻辑体量（sum(length(ZTHUMBNAIL))）掉了多少 —— 这决定 vacuum / checkpoint /
//       CloudKit 上传的代价，也就是 scene-create 看门狗还会不会被触发
//    2. 库文件本身掉了多少 —— 用户看到的「App 占用」
//    3. 扫描 + 瘦身全程的内存增量 —— 修崩溃的过程本身不能再撞 jetsam
//
//  单元测试已经钉住单条的行为（ThumbnailMigrationCoordinatorTests）；这里钉的是
//  「一整库跑下来」的合计效果，以及**文件层面**的结论 —— 那是单条测试看不到的。
//

import XCTest
import SwiftData
import SQLite3
import UIKit
@testable import BeadInventory

final class StoreCompactionIntegrationTests: XCTestCase {
    private var storeDir: URL!

    override func setUpWithError() throws {
        storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("compaction-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        ThumbnailMigrationCoordinator.resetStubbornIDsForTesting()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storeDir)
        ThumbnailMigrationCoordinator.resetStubbornIDsForTesting()
    }

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

    /// 全分辨率噪声 PNG —— 与 `WhiteScreenReproSeeder` 同款，实测 2400px 出 ~12.9 MB，
    /// 跟用户设备上的真实体量一致。
    private func makeFullResolutionPNG(longEdge: Int) -> Data {
        let width = longEdge, height = Int(Double(longEdge) * 0.75)
        var buffer = Data(count: width * height * 4)
        buffer.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        let cs = CGColorSpaceCreateDeviceRGB()
        let provider = CGDataProvider(data: buffer as CFData)!
        let cg = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        return UIImage(cgImage: cg).pngData()!
    }

    /// 直接查库量逻辑体量 —— 走只读连接，不物化 blob。
    private func logicalBytes(_ storeURL: URL) -> (rows: Int, thumbBytes: Int, fatRows: Int, missingDisplay: Int) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return (0, 0, 0, 0)
        }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT count(*), coalesce(sum(length(ZTHUMBNAIL)), 0), \
        sum(CASE WHEN length(ZTHUMBNAIL) > \(ProjectImageEncoder.compactionThresholdBytes) THEN 1 ELSE 0 END), \
        sum(CASE WHEN ZTHUMBNAIL IS NOT NULL AND ZDISPLAYTHUMBNAIL IS NULL THEN 1 ELSE 0 END) \
        FROM ZSDPROJECTRECORD
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (0, 0, 0, 0) }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return (0, 0, 0, 0) }
        return (
            Int(sqlite3_column_int64(stmt, 0)),
            Int(sqlite3_column_int64(stmt, 1)),
            Int(sqlite3_column_int64(stmt, 2)),
            Int(sqlite3_column_int64(stmt, 3))
        )
    }

    private func fileBytes(_ url: URL) -> Int {
        var total = 0
        for suffix in ["", "-wal", "-shm"] {
            let u = URL(fileURLWithPath: url.path + suffix)
            total += (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    func test_full_store_compaction_end_to_end() async throws {
        let projectCount = 24                       // 24 × ~12.9MB ≈ 310MB，够看出量级又不至于让 CI 跑太久
        let storeURL = storeDir.appendingPathComponent("default.store")
        let config = ModelConfiguration(url: storeURL, cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: SDBrand.self, SDBrandStock.self, SDProjectRecord.self,
            SDBeadUsage.self, SDCustomColor.self, SDHistoryRecord.self, SDColorScheme.self,
            configurations: config
        )

        // ==== 种子：复现用户设备的形态 ====
        // 一半没有 displayThumbnail（老数据形态，同时触发回填分支）
        let pool = (0..<4).map { _ in makeFullResolutionPNG(longEdge: 2400) }
        do {
            let ctx = ModelContext(container)
            for i in 0..<projectCount {
                ctx.insert(SDProjectRecord(
                    name: "E2E-\(i)",
                    thumbnail: pool[i % pool.count],
                    displayThumbnail: i % 2 == 0 ? nil : Data([0xFF, 0xD8, 0xFF])
                ))
                if i % 6 == 5 { try ctx.save() }
            }
            try ctx.save()
        }

        let before = logicalBytes(storeURL)
        let beforeFile = fileBytes(storeURL)
        XCTAssertEqual(before.rows, projectCount)
        XCTAssertEqual(before.fatRows, projectCount, "种子必须全是胖行，否则没在测该测的东西")

        // ==== 跑瘦身 ====
        let memBefore = Self.footprintMB()
        var processed = 0
        var guardCounter = 0
        var excluded = Set<UUID>()
        while guardCounter < 200 {
            guardCounter += 1
            let scan = ProjectImageCompactionScanner.scanCandidates(
                storeURL: storeURL,
                thresholdBytes: ProjectImageEncoder.compactionThresholdBytes,
                limit: 10,
                excluding: excluded
            )
            guard case .success(let candidates) = scan else { return XCTFail("扫描失败：\(scan)") }
            if candidates.isEmpty { break }
            for candidate in candidates {
                excluded.insert(candidate.id)
                let outcome = await ThumbnailMigrationCoordinator.compactOne(
                    projectId: candidate.id, container: container
                )
                XCTAssertTrue(outcome.isMigrated, "项目 \(candidate.id) 瘦身失败：\(outcome)")
                processed += 1
            }
        }
        let memDelta = Self.footprintMB() - memBefore

        let after = logicalBytes(storeURL)
        let afterFile = fileBytes(storeURL)

        print("""
        [e2e] rows=\(projectCount) processed=\(processed)
        [e2e] 逻辑体量  \(before.thumbBytes / 1_048_576)MB → \(after.thumbBytes / 1_048_576)MB \
        (\(before.thumbBytes / max(after.thumbBytes, 1))x)
        [e2e] 库文件    \(beforeFile / 1_048_576)MB → \(afterFile / 1_048_576)MB
        [e2e] 胖行      \(before.fatRows) → \(after.fatRows)
        [e2e] 缺小图    \(before.missingDisplay) → \(after.missingDisplay)
        [e2e] 内存增量  \(Int(memDelta))MB
        """)

        // 1. 逻辑体量降一个数量级 —— 这决定 vacuum / checkpoint / CloudKit 的代价
        XCTAssertEqual(processed, projectCount)
        XCTAssertEqual(after.fatRows, 0, "跑完之后不该还有胖行")
        XCTAssertEqual(after.missingDisplay, 0, "缺小图的行应当在同一次 save 里被补上")
        XCTAssertLessThan(
            after.thumbBytes, before.thumbBytes / 5,
            "逻辑体量没降下来，写放大 / vacuum 代价照旧"
        )

        // 2. 收敛：再扫一遍必须为空（不排除任何 ID）
        let rescan = ProjectImageCompactionScanner.scanCandidates(
            storeURL: storeURL,
            thresholdBytes: ProjectImageEncoder.compactionThresholdBytes,
            limit: 100,
            excluding: []
        )
        guard case .success(let leftovers) = rescan else { return XCTFail("重扫失败：\(rescan)") }
        XCTAssertTrue(
            leftovers.isEmpty,
            "瘦身后仍有 \(leftovers.count) 条被选中 → 每次启动都会重写它们，等于换了个触发器的写放大"
        )

        // 3. 修崩溃的过程本身不能撞 jetsam
        XCTAssertLessThan(memDelta, 300, "瘦身全程内存增量 \(memDelta)MB —— 一次只该有一张图在内存里")
    }
}
