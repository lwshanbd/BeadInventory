//
//  ProjectImageLoaderTests.swift
//  BeadInventoryTests
//
//  钉住取图路径的两条不变量：
//    1. **不在主线程读库** —— 这是用户 `.ips` 里那条
//       `CA::Transaction::commit → … → sqlite3_step → _platform_memmove` 主线程栈的直接修复。
//    2. **老数据兜底不外泄原字节** —— `downsampledRawThumbnail` 只返回降级后的 UIImage，
//       原图字节留在 actor 内部，调用方想常驻内存都拿不到。
//

import XCTest
import SwiftData
import UIKit
@testable import BeadInventory

final class ProjectImageLoaderTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func makePNG(side: CGFloat, color: UIColor = .systemTeal) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }.pngData()!
    }

    @MainActor
    private func seed(
        in container: ModelContainer,
        thumbnail: Data?,
        displayThumbnail: Data? = nil,
        finishedImage: Data? = nil
    ) throws -> UUID {
        let ctx = ModelContext(container)
        let record = SDProjectRecord(
            name: "取图测试",
            thumbnail: thumbnail,
            finishedImage: finishedImage,
            displayThumbnail: displayThumbnail
        )
        ctx.insert(record)
        try ctx.save()
        return record.id
    }

    // MARK: - 正确性

    @MainActor
    func test_loader_returns_each_column() async throws {
        let container = try makeContainer()
        let thumb = makePNG(side: 40)
        let display = makePNG(side: 20, color: .systemPink)
        let finished = makePNG(side: 30, color: .systemGreen)
        let id = try seed(in: container, thumbnail: thumb,
                          displayThumbnail: display, finishedImage: finished)

        let loader = ProjectImageLoader(container: container)
        let gotThumb = await loader.thumbnail(for: id)
        let gotDisplay = await loader.displayThumbnail(for: id)
        let gotFinished = await loader.finishedImage(for: id)

        XCTAssertEqual(gotThumb, thumb)
        XCTAssertEqual(gotDisplay, display)
        XCTAssertEqual(gotFinished, finished)
    }

    @MainActor
    func test_loader_returns_nil_for_missing_row() async throws {
        let container = try makeContainer()
        let loader = ProjectImageLoader(container: container)
        let got = await loader.displayThumbnail(for: UUID())
        XCTAssertNil(got)
    }

    /// 老数据（displayThumbnail 缺失）的兜底路径必须出图，且**只出降级后的 UIImage**。
    @MainActor
    func test_downsampled_fallback_produces_small_image_without_exposing_raw_bytes() async throws {
        let container = try makeContainer()
        let big = makePNG(side: 2000)
        let id = try seed(in: container, thumbnail: big, displayThumbnail: nil)

        let loader = ProjectImageLoader(container: container)
        let loaded = await loader.downsampledRawThumbnail(for: id)
        let image = try XCTUnwrap(loaded)

        XCTAssertLessThanOrEqual(
            max(image.size.width, image.size.height),
            CGFloat(ImageDownsampler.defaultMaxPixelSize),
            "兜底路径必须现场降级，不能把原分辨率图交给列表 row"
        )
    }

    // MARK: - 不在主线程（崩溃修复的核心不变量）

    /// `ProjectImageLoader` 是 actor —— 它的方法体不得在主线程执行。
    /// 一旦有人把它改回 `@MainActor`（或把 fetch 挪回 InventoryManager），这条会红。
    @MainActor
    func test_loader_never_runs_on_main_thread() async throws {
        let container = try makeContainer()
        let id = try seed(in: container, thumbnail: makePNG(side: 40),
                          displayThumbnail: makePNG(side: 20))

        let loader = ProjectImageLoader(container: container)
        let ranOnMain = await loader.isCurrentlyOnMainThreadForTesting()
        XCTAssertFalse(ranOnMain, "取图跑在主线程上 —— 首屏 10 个 row 就是 10 次主线程读库")

        // 顺带确认功能没被这条断言绕过
        let got = await loader.displayThumbnail(for: id)
        XCTAssertNotNil(got)
    }

    /// actor 隔离带来的串行化：老数据兜底路径同一时刻只能有一份原图在内存里。
    /// 并发放 8 个请求进去，观测到的最大并发数必须是 1 ——
    /// 否则 10 个 row 各读一份 13MB 就是 130MB 瞬时峰值（jetsam 老路）。
    @MainActor
    func test_loader_serialises_concurrent_requests() async throws {
        let container = try makeContainer()
        var ids: [UUID] = []
        for _ in 0..<8 {
            ids.append(try seed(in: container, thumbnail: makePNG(side: 600), displayThumbnail: nil))
        }

        let loader = ProjectImageLoader(container: container)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { _ = await loader.downsampledRawThumbnail(for: id) }
            }
        }
        let peak = await loader.peakConcurrencyForTesting
        XCTAssertEqual(peak, 1, "actor 应保证取图串行，实测峰值并发 \(peak)")
    }
}
