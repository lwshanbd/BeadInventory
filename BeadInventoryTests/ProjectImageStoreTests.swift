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
        // 顺序要紧：先删目录（此时 override 还生效，删的是本用例的隔离目录），再清 override。
        // 旧实现反过来，导致 deleteAll 解析到真实 Application Support —— 什么也没清到。
        try? FileManager.default.removeItem(at: storeDir)
        ProjectImageStore.rootOverrideForTesting = nil
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

    /// 播种一行，返回 id。
    @discardableResult
    private func seedProject(
        in container: ModelContainer,
        thumbnail: Data?,
        finishedImage: Data? = nil,
        displayThumbnail: Data? = nil
    ) throws -> UUID {
        let ctx = ModelContext(container)
        let record = SDProjectRecord(
            name: "种子", totalBeads: 0,
            thumbnail: thumbnail, finishedImage: finishedImage,
            displayThumbnail: displayThumbnail, beadUsages: []
        )
        ctx.insert(record)
        try ctx.save()
        seededProjectIDs.append(record.id)
        return record.id
    }

    /// 用独立 context 读回一行（避免拿到被测 context 里已注册的实例）。
    private func fetchRow(_ id: UUID, in container: ModelContainer) throws -> SDProjectRecord? {
        let ctx = ModelContext(container)
        var d = FetchDescriptor<SDProjectRecord>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try ctx.fetch(d).first
    }

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

    // MARK: - 不变量 5：文件写入失败时，绝不清空数据库列（PR #59 双审 C1）

    /// 这是本 PR 首版最严重的缺陷：`_setProjectBlobsDirectly` 丢弃 `write` 的返回值，
    /// 然后无论如何清空数据库列 —— 盘满 / 沙盒错误时用户的原图两边都没有，永久丢失。
    ///
    /// 用只读目录模拟写入失败。断言：整个操作失败、数据库列原封不动、读取仍能拿到原字节、
    /// 存在性集合不谎报。
    func test_file_write_failure_preserves_database_column() throws {
        let container = try makeContainer()
        let original = makeNoisePNG(longEdge: 400)
        let projectId = try seedProject(in: container, thumbnail: original)

        let m = InventoryManager(modelContext: ModelContext(container))
        m.projects = [ProjectRecord(id: projectId, name: "只读目录", totalBeads: 0)]

        // 把图片根目录指到一个不可写的位置 —— 写入必失败
        let readOnly = storeDir.appendingPathComponent("readonly", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly.path)
        ProjectImageStore.rootOverrideForTesting = readOnly
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnly.path)
        }

        let replacement = makeNoisePNG(longEdge: 401)
        let ok = m.updateProjectThumbnail(projectId, thumbnail: replacement)

        XCTAssertFalse(ok, "文件写入失败时整个操作必须失败，不能报告成功")
        let row = try XCTUnwrap(fetchRow(projectId, in: container))
        XCTAssertEqual(row.thumbnail, original, "写入失败时数据库列必须原封不动——清了就是永久丢图")
        XCTAssertEqual(m.fetchProjectThumbnailData(for: projectId), original, "读取应仍能拿到原图")
    }

    /// 派生缓存（displayThumbnail）写失败时同样不清库列，但不阻断整个操作。
    func test_display_thumbnail_write_failure_does_not_clear_column() throws {
        let container = try makeContainer()
        let small = makeNoisePNG(longEdge: 80)
        let projectId = try seedProject(in: container, thumbnail: nil, displayThumbnail: small)

        let m = InventoryManager(modelContext: ModelContext(container))
        let readOnly = storeDir.appendingPathComponent("readonly2", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly.path)
        ProjectImageStore.rootOverrideForTesting = readOnly
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnly.path)
        }

        _ = m._setProjectBlobsDirectly(projectId: projectId, displayThumbnail: .some(makeNoisePNG(longEdge: 81)))
        let row = try XCTUnwrap(fetchRow(projectId, in: container))
        XCTAssertEqual(row.displayThumbnail, small, "小图写失败也不能清库列，否则列表退化成现场降采样")
        XCTAssertFalse(m.projectIDsWithDisplayThumbnail.contains(projectId), "写失败不得声称文件存在")
    }

    // MARK: - 不变量 6：成品图走同一条受检路径（PR #59 双审 C3）

    /// 首版 `_setProjectFinishedImageDirectly` 仍直写 `sd.finishedImage`，而读取已改成文件
    /// 优先，导致：换图看到旧图、删图重启复活、该行重新成为迁移候选。
    func test_finished_image_update_goes_to_file_not_database_column() throws {
        let container = try makeContainer()
        let projectId = try seedProject(in: container, thumbnail: nil)
        let m = InventoryManager(modelContext: ModelContext(container))
        m.projects = [ProjectRecord(id: projectId, name: "成品图", totalBeads: 0)]

        let finished = makeNoisePNG(longEdge: 300)
        m.updateProjectFinishedImage(projectId, finishedImage: finished)

        let row = try XCTUnwrap(fetchRow(projectId, in: container))
        XCTAssertNil(row.finishedImage, "成品图必须落文件，数据库列保持 nil——留在行里就是写放大复发")
        XCTAssertTrue(ProjectImageStore.exists(projectId: projectId, kind: .finishedImage))
        XCTAssertEqual(m.fetchProjectFinishedImageData(for: projectId), finished)

        // 换一张：读取必须返回新图（首版这里会返回旧图）
        let replacement = makeNoisePNG(longEdge: 301)
        m.updateProjectFinishedImage(projectId, finishedImage: replacement)
        XCTAssertEqual(m.fetchProjectFinishedImageData(for: projectId), replacement, "换图后必须读到新图")

        // 删除：文件要真的消失（首版只清了本来就是 nil 的库列，文件残留 → 重启复活）
        m.updateProjectFinishedImage(projectId, finishedImage: nil)
        XCTAssertFalse(ProjectImageStore.exists(projectId: projectId, kind: .finishedImage),
                       "删除成品图后文件必须消失，否则下次启动会被并回存在性集合、图片复活")
        XCTAssertNil(m.fetchProjectFinishedImageData(for: projectId))
        XCTAssertFalse(m.projectIDsWithFinishedImage.contains(projectId))
    }

    // MARK: - 不变量 7：目录读取失败 ≠ 没有图（PR #59 双审）

    func test_directory_listing_failure_is_distinguishable_from_empty() throws {
        // 根目录不存在 = 还没迁移，正常空集
        ProjectImageStore.rootOverrideForTesting = storeDir.appendingPathComponent("never-created")
        XCTAssertEqual(ProjectImageStore.projectIDs(with: .thumbnail), [],
                       "目录不存在是迁移前的正常状态，应返回空集")

        // 根目录存在但不可读 = 读取失败，必须返回 nil 而不是空集
        let unreadable = storeDir.appendingPathComponent("unreadable", isDirectory: true)
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadable.path)
        }
        ProjectImageStore.rootOverrideForTesting = unreadable
        XCTAssertNil(ProjectImageStore.projectIDs(with: .thumbnail),
                     "读取失败必须返回 nil——当成空集会让所有项目的图同时消失")
    }
}
