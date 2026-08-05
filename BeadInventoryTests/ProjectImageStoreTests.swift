//
//  ProjectImageStoreTests.swift
//  BeadInventoryTests
//
//  钉住「图片搬出 SQLite 行」这个修复的三条不变量。
//
//  为什么这个修复存在（2026-08-05，两份用户报告实证）：
//  - TestFlight 2.0.0(183) 磁盘写入报告：63 分钟写入 **68.72 GB**（18MB/s 持续）
//  - App Store 1.8.0(157) 崩溃：scene-create watchdog 0x8BADF00D，主线程 CPU 仅 18%
//    —— 不是在算，是在等被写入打满的 SQLite 队列
//
//  机制：thumbnail/finishedImage/displayThumbnail 是 inline BLOB，单条原图 13MB。
//  SQLite 更新任何一列都重写整行，所以「写 110KB 小图」实际写盘 13MB。
//

import XCTest
import SwiftData
import UIKit
@testable import BeadInventory

@MainActor
final class ProjectImageStoreTests: XCTestCase {
    private var storeDir: URL!
    private var seededProjectIDs: [UUID] = []

    override func setUpWithError() throws {
        storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("imgstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        seededProjectIDs = []
        // 图片文件存储隔离到本用例自己的目录（否则跨测试类串数据）
        ProjectImageStore.rootOverrideForTesting = storeDir.appendingPathComponent("images", isDirectory: true)
    }

    override func tearDownWithError() throws {
        ProjectImageStore.rootOverrideForTesting = nil
        try? FileManager.default.removeItem(at: storeDir)
        // ProjectImageStore 写的是真实 Application Support 目录，用例之间必须自己清干净
        for id in seededProjectIDs {
            ProjectImageStore.deleteAll(projectId: id)
        }
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let url = storeDir.appendingPathComponent("imgstore.store")
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func makeNoisePNG(longEdge: Int) -> Data {
        let w = longEdge, h = Int(Double(longEdge) * 0.75)
        var buf = Data(count: w * h * 4)
        buf.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        let cs = CGColorSpaceCreateDeviceRGB()
        let provider = CGDataProvider(data: buf as CFData)!
        let cg = CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: cs, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        return UIImage(cgImage: cg).pngData()!
    }

    /// store 文件在磁盘上的实际字节数（含 WAL）—— 用来量「行有没有真的变小」。
    private func storeBytes() -> Int {
        let fm = FileManager.default
        var total = 0
        for suffix in ["", "-wal", "-shm"] {
            let url = storeDir.appendingPathComponent("imgstore.store" + suffix)
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int {
                total += size
            }
        }
        return total
    }

    // MARK: - 不变量 1：图片写入不再让数据库膨胀

    /// 写图片时数据库文件不得随图片体量增长 —— 这是 68.72GB 写放大的直接回归点。
    func test_writing_images_does_not_grow_the_sqlite_store() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let manager = InventoryManager(modelContext: ctx)

        // updateProjectThumbnail 需要项目同时存在于内存数组与数据库行
        var ids: [UUID] = []
        for i in 0..<5 {
            let record = SDProjectRecord(name: "P\(i)", totalBeads: i, beadUsages: [])
            ctx.insert(record)
            ids.append(record.id)
            seededProjectIDs.append(record.id)
            manager.projects.append(ProjectRecord(id: record.id, name: "P\(i)", totalBeads: i))
        }
        try ctx.save()
        let baselineBytes = storeBytes()

        // 每个项目写一张 ~13MB 原图
        let png = makeNoisePNG(longEdge: 2400)
        XCTAssertGreaterThan(png.count, 10_000_000, "原图要足够大才测得出行膨胀")
        for id in ids {
            manager.updateProjectThumbnail(id, thumbnail: png)
        }

        let afterBytes = storeBytes()
        let growthMB = Double(afterBytes - baselineBytes) / 1_048_576
        let imagesMB = Double(png.count * ids.count) / 1_048_576

        // 5 × 13MB = 65MB 图片，数据库增长必须远小于它（旧实现是 1:1 甚至更多）。
        XCTAssertLessThan(
            growthMB, 5,
            "写 \(Int(imagesMB))MB 图片让数据库涨了 \(Int(growthMB))MB —— 图片又回到行里了，"
            + "这正是 68.72GB 写放大的机制"
        )

        // 图片确实存在且内容正确
        for id in ids {
            XCTAssertEqual(manager.fetchProjectThumbnailData(for: id), png)
            XCTAssertTrue(ProjectImageStore.exists(projectId: id, kind: .thumbnail))
        }
    }

    // MARK: - 不变量 2：存量数据读得到（迁移完成前）

    /// 直接写进数据库列的存量图片，读取路径必须仍能拿到 —— 否则老用户升级即丢图。
    func test_legacy_images_still_readable_from_database_column() throws {
        let container = try makeContainer()
        let seedCtx = ModelContext(container)
        let png = makeNoisePNG(longEdge: 600)
        let record = SDProjectRecord(
            name: "存量项目", totalBeads: 1,
            thumbnail: png, finishedImage: png, displayThumbnail: nil, beadUsages: []
        )
        seedCtx.insert(record)
        try seedCtx.save()
        seededProjectIDs.append(record.id)

        let manager = InventoryManager(modelContext: ModelContext(container))
        // 文件里没有，必须回退到数据库列
        XCTAssertFalse(ProjectImageStore.exists(projectId: record.id, kind: .thumbnail))
        XCTAssertEqual(manager.fetchProjectThumbnailData(for: record.id), png)
        XCTAssertEqual(manager.fetchProjectFinishedImageData(for: record.id), png)
    }

    // MARK: - 不变量 3：迁移先落文件再清列（断电不丢图）

    /// 迁移必须把字节搬到文件、清空数据库列，且全程可断点续做。
    func test_migration_moves_images_to_files_and_shrinks_rows() async throws {
        let container = try makeContainer()
        let seedCtx = ModelContext(container)
        let png = makeNoisePNG(longEdge: 2400)
        var ids: [UUID] = []
        for i in 0..<3 {
            let r = SDProjectRecord(
                name: "老数据\(i)", totalBeads: i,
                thumbnail: png, finishedImage: nil, displayThumbnail: nil, beadUsages: []
            )
            seedCtx.insert(r)
            ids.append(r.id)
            seededProjectIDs.append(r.id)
        }
        try seedCtx.save()

        for id in ids {
            let outcome = await ThumbnailMigrationCoordinator.migrateOne(projectId: id, container: container)
            XCTAssertEqual(outcome, .migrated, "项目 \(id) 应完成搬运")
        }

        let verifyCtx = ModelContext(container)
        for id in ids {
            // 数据库列已清空 —— 行永久变小，往后任何写入都不再重写 13MB
            var d = FetchDescriptor<SDProjectRecord>(predicate: #Predicate { $0.id == id })
            d.fetchLimit = 1
            let row = try XCTUnwrap(verifyCtx.fetch(d).first)
            XCTAssertNil(row.thumbnail, "原图应已搬走并清空数据库列")
            XCTAssertNil(row.displayThumbnail)

            // 字节完整落在文件里
            XCTAssertEqual(ProjectImageStore.read(projectId: id, kind: .thumbnail), png)
            XCTAssertTrue(ProjectImageStore.exists(projectId: id, kind: .displayThumbnail))
        }

        // 幂等：再跑一次应报 alreadyDone，不产生任何写入
        let second = await ThumbnailMigrationCoordinator.migrateOne(projectId: ids[0], container: container)
        XCTAssertEqual(second, .alreadyDone, "搬完的行必须自然掉出候选，否则会无限重跑")
    }

    /// 删除项目要连图片文件一起清掉，不留孤儿占磁盘。
    func test_deleting_project_removes_image_files() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let manager = InventoryManager(modelContext: ctx)
        manager.performInitialLoadIfNeeded(reason: "unitTest")

        let png = makeNoisePNG(longEdge: 400)
        let sd = SDProjectRecord(name: "待删项目", totalBeads: 0, beadUsages: [])
        ctx.insert(sd)
        try ctx.save()
        seededProjectIDs.append(sd.id)
        let project = ProjectRecord(id: sd.id, name: "待删项目", totalBeads: 0)
        manager.projects.append(project)
        manager.updateProjectThumbnail(project.id, thumbnail: png)
        XCTAssertTrue(ProjectImageStore.exists(projectId: project.id, kind: .thumbnail))

        manager.deleteProject(id: project.id)
        XCTAssertFalse(
            ProjectImageStore.exists(projectId: project.id, kind: .thumbnail),
            "删除项目后图片文件应一并清掉，否则磁盘上会堆孤儿文件"
        )
    }
}
