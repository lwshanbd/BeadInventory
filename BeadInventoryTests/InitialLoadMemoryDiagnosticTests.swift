//
//  InitialLoadMemoryDiagnosticTests.swift
//  BeadInventoryTests
//
//  诊断：2.4GB 拼图模式种子库上，冷启动 60s 内进程峰值 RSS 实测冲到 5.7GB
//  （模拟器无 jetsam 所以只是慢；真机前台 ~1.2-2.5GB 就会被杀 = 用户报的
//  「转圈转着转着闪退」）。该次启动迁移数为 0，唯一重活是首次加载的后台 fetch
//  （durationMs=14382）—— 怀疑 propertiesToFetch 投影没有挡住 blob 物化。
//
//  本测试把 fetchInitialPersistentData 的各阶段拆开，逐段量 phys_footprint
//  （jetsam 依据的指标，比 RSS 更贴近真机行为），定位内存到底被哪个查询吃掉。
//

import XCTest
import SwiftData
import UIKit
@testable import BeadInventory

final class InitialLoadMemoryDiagnosticTests: XCTestCase {
    private var storeDir: URL!

    override func setUpWithError() throws {
        storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("memdiag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storeDir)
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

    private func makeNoisePNG(longEdge: Int) -> Data {
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

    func test_diagnose_initial_load_memory_by_stage() throws {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let url = storeDir.appendingPathComponent("memdiag.store")
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])

        // 120 条 × ~13MB ≈ 1.5GB —— 与真实复现库同量级，控制测试时长
        let pool = (0..<3).map { _ in makeNoisePNG(longEdge: 2400) }
        print("MEMDIAG seed bytesEach=\(pool[0].count)")
        let ctx = ModelContext(container)
        for i in 0..<120 {
            ctx.insert(SDProjectRecord(
                name: "MD-\(i)",
                totalBeads: i,
                thumbnail: pool[i % pool.count],
                finishedImage: i % 5 == 0 ? pool[i % pool.count] : nil,
                displayThumbnail: nil,
                beadUsages: []
            ))
            if i % 20 == 19 { try ctx.save() }
        }
        try ctx.save()

        let base = Self.footprintMB()
        print("MEMDIAG baseline=\(Int(base))MB")

        // 独立后台 context —— 与 fetchInitialPersistentData 完全一致的姿势
        let bg = ModelContext(container)

        func stage(_ name: String, _ body: () throws -> Int) rethrows {
            let before = Self.footprintMB()
            let n = try body()
            let after = Self.footprintMB()
            print("MEMDIAG stage=\(name) rows=\(n) delta=\(Int(after - before))MB now=\(Int(after))MB")
        }

        try stage("brands") {
            try bg.fetch(FetchDescriptor<SDBrand>()).count
        }
        try stage("stocks") {
            try bg.fetch(FetchDescriptor<SDBrandStock>()).count
        }
        try stage("projects_metadata_projected") {
            var d = FetchDescriptor<SDProjectRecord>(
                sortBy: [SortDescriptor(\.date, order: .reverse)]
            )
            d.propertiesToFetch = [
                \.id, \.name, \.date, \.totalBeads, \.brandId, \.isArchived,
                \.parentId, \.isPlanned, \.executedDate, \.completedDate, \.colorSystemRaw
            ]
            let rows = try bg.fetch(d)
            let structs = rows.map { $0.toMetadataStruct() }
            return structs.count
        }
        var legacyFinished = Set<UUID>()
        var legacyThumb = Set<UUID>()
        try stage("exists_finishedImage_swiftdata") {
            var d = FetchDescriptor<SDProjectRecord>(predicate: #Predicate { $0.finishedImage != nil })
            d.propertiesToFetch = [\.id]
            legacyFinished = Set(try bg.fetch(d).map { $0.id })
            return legacyFinished.count
        }
        try stage("exists_thumbnail_swiftdata") {
            var d = FetchDescriptor<SDProjectRecord>(predicate: #Predicate { $0.thumbnail != nil })
            d.propertiesToFetch = [\.id]
            legacyThumb = Set(try bg.fetch(d).map { $0.id })
            return legacyThumb.count
        }

        // ==== 修复后的主路径：raw SQLite 头部扫描 ====
        var scanned: ProjectBlobExistence?
        let scanBefore = Self.footprintMB()
        stage_scan: do {
            scanned = ProjectBlobExistenceScanner.scan(storeURL: url)
        }
        let scanDelta = Self.footprintMB() - scanBefore
        print("MEMDIAG stage=scanner_raw_sqlite delta=\(Int(scanDelta))MB")

        let existence = try XCTUnwrap(scanned, "文件库上扫描器不应回退")
        // 正确性：与 SwiftData 查询逐集合一致
        XCTAssertEqual(existence.finishedImage, legacyFinished)
        XCTAssertEqual(existence.thumbnail, legacyThumb)
        XCTAssertEqual(existence.thumbnail.count, 120, "种子里全部 120 条都带 thumbnail")
        XCTAssertEqual(existence.finishedImage.count, 24, "i%5==0 的 24 条带 finishedImage")
        XCTAssertTrue(existence.patternGrid.isEmpty)
        XCTAssertTrue(existence.displayThumbnail.isEmpty)

        // 内存：头部扫描不物化 blob。对照上面 SwiftData 同款查询 +1.2GB 量级，
        // 阈值 100MB 已留足噪声余量，真回归（重新物化）会超出一个数量级。
        XCTAssertLessThan(
            scanDelta, 100,
            "存在性扫描增加了 \(Int(scanDelta))MB —— blob 又被物化进内存了，真机会被 jetsam"
        )
    }
}
