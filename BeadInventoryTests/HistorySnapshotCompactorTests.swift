//
//  HistorySnapshotCompactorTests.swift
//  BeadInventoryTests
//
//  历史表是项目表之外的**第二个**独立膨胀源：快照走 JSONEncoder，`Data` 被编成 base64
//  （+33%），`.projectUpdate` 还会把同一份快照同时写进 before / after 两列 ——
//  单条可达 ~34 MB，`maxRecords = 100` 时历史表单独可达 GB 级。
//
//  这里钉三件事：
//    1. 快照里的图确实变小了
//    2. **撤回语义完全不变** —— 图还在、其余字段一个不少（这是不能破的那条）
//    3. 收敛：瘦过的快照再跑一次是 no-op
//

import XCTest
import UIKit
@testable import BeadInventory

final class HistorySnapshotCompactorTests: XCTestCase {

    /// 照片型大图：PNG 存起来很大、JPEG 压得下去（纯色图压根触发不了重编码）。
    private func makeFatPhotoPNG(side: Int = 1400) -> Data {
        var buffer = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt64 = 0xA24BAED4963EE407
        for i in stride(from: 0, to: buffer.count, by: 4) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let n = UInt8((seed >> 33) & 0xFF)
            let base = UInt8((i / 4 / side) % 200)
            buffer[i] = base &+ n / 8
            buffer[i + 1] = base &+ n / 6
            buffer[i + 2] = n
            buffer[i + 3] = 255
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let provider = CGDataProvider(data: Data(buffer) as CFData)!
        let cg = CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: side * 4, space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        return UIImage(cgImage: cg).pngData()!
    }

    private func makeSnapshot(thumbnail: Data?, finishedImage: Data?) -> ProjectSnapshot {
        ProjectSnapshot(
            id: UUID(),
            name: "带图快照",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            totalBeads: 1234,
            brandId: UUID(),
            isArchived: false,
            parentId: nil,
            isPlanned: false,
            executedDate: Date(timeIntervalSince1970: 1_700_000_500),
            beadUsages: [
                BeadUsageSnapshot(colorCode: "H2", brandId: nil, quantity: 40, isDeducted: true),
                BeadUsageSnapshot(colorCode: "B5", brandId: nil, quantity: 7, isDeducted: false)
            ],
            thumbnail: thumbnail,
            finishedImage: finishedImage,
            colorSystem: .mard,
            capturesImages: true,
            patternGridData: nil,
            completedDate: Date(timeIntervalSince1970: 1_700_000_900),
            displayThumbnail: Data([0xFF, 0xD8, 0xFF, 0xE0])
        )
    }

    // MARK: - 体积

    func test_compact_shrinks_images_inside_snapshot() throws {
        let fat = makeFatPhotoPNG()
        let encoded = try JSONEncoder().encode(makeSnapshot(thumbnail: fat, finishedImage: fat))
        XCTAssertGreaterThan(
            encoded.count, ProjectImageEncoder.compactionThresholdBytes,
            "夹具必须真的是胖快照，否则这个测试没在测该测的东西"
        )

        let result = try XCTUnwrap(HistorySnapshotCompactor.compact(encoded))
        print("[history] snapshot \(encoded.count)B → \(result.data.count)B  saved=\(result.bytesSaved)B")

        XCTAssertLessThan(result.data.count, encoded.count / 2, "至少要减半才值得重写这一行")
        XCTAssertEqual(result.bytesSaved, encoded.count - result.data.count)
    }

    // MARK: - 撤回语义（不能破的那条）

    /// 图片**还在**，只是变小了；其余字段一字不差。
    /// 这里刻意不做「删掉老快照里的图」那种省地方的做法 —— `.projectDelete` 的快照是
    /// 那张图删除之后的唯一拷贝。
    func test_compact_preserves_every_field_and_keeps_images_present() throws {
        // 两张都要**超过**阈值，否则没超的那张会被正确地原样保留，
        // 下面「变小了」的断言就无从谈起（阈值以下不动是有意行为，
        // 由 test_compact_returns_nil_for_snapshot_without_fat_images 覆盖）。
        let original = makeSnapshot(thumbnail: makeFatPhotoPNG(), finishedImage: makeFatPhotoPNG(side: 1300))
        let encoded = try JSONEncoder().encode(original)

        let result = try XCTUnwrap(HistorySnapshotCompactor.compact(encoded))
        let decoded = try JSONDecoder().decode(ProjectSnapshot.self, from: result.data)

        // 图还在，且确实变小了
        let newThumb = try XCTUnwrap(decoded.thumbnail, "撤回要靠它还原图片，绝不能变 nil")
        let newFinished = try XCTUnwrap(decoded.finishedImage, "同上")
        XCTAssertLessThan(newThumb.count, try XCTUnwrap(original.thumbnail).count)
        XCTAssertLessThan(newFinished.count, try XCTUnwrap(original.finishedImage).count)
        XCTAssertNotNil(UIImage(data: newThumb), "重编码后必须仍是可解码的图片")
        XCTAssertNotNil(UIImage(data: newFinished))

        // 其余字段逐个核对
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.date, original.date)
        XCTAssertEqual(decoded.totalBeads, original.totalBeads)
        XCTAssertEqual(decoded.brandId, original.brandId)
        XCTAssertEqual(decoded.isArchived, original.isArchived)
        XCTAssertEqual(decoded.parentId, original.parentId)
        XCTAssertEqual(decoded.isPlanned, original.isPlanned)
        XCTAssertEqual(decoded.executedDate, original.executedDate)
        XCTAssertEqual(decoded.completedDate, original.completedDate)
        XCTAssertEqual(decoded.colorSystem, original.colorSystem)
        XCTAssertEqual(decoded.capturesImages, original.capturesImages,
                       "capturesImages 被改掉的话，undo 会以为这条不带图，反而把图清空")
        XCTAssertEqual(decoded.displayThumbnail, original.displayThumbnail,
                       "displayThumbnail 本来就小，不该被动")
        XCTAssertEqual(decoded.beadUsages.count, original.beadUsages.count)
        for (a, b) in zip(decoded.beadUsages, original.beadUsages) {
            XCTAssertEqual(a.colorCode, b.colorCode)
            XCTAssertEqual(a.quantity, b.quantity)
            XCTAssertEqual(a.isDeducted, b.isDeducted)
            XCTAssertEqual(a.brandId, b.brandId)
        }
    }

    /// 嵌套结构（删除快照里带子项目数组）也要覆盖到 —— 通用 JSON 遍历的意义就在这里。
    func test_compact_reaches_images_nested_in_arrays() throws {
        let child = makeSnapshot(thumbnail: makeFatPhotoPNG(), finishedImage: nil)
        let payload: [String: Any] = [
            "parent": ["name": "父项目"],
            "children": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(child))]
        ]
        let encoded = try JSONSerialization.data(withJSONObject: payload)

        let result = try XCTUnwrap(
            HistorySnapshotCompactor.compact(encoded),
            "嵌在数组里的图必须也被遍历到，否则删除快照这类形状永远瘦不下来"
        )
        XCTAssertLessThan(result.data.count, encoded.count / 2)

        // 结构没被破坏
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: result.data) as? [String: Any]
        )
        XCTAssertEqual((root["parent"] as? [String: Any])?["name"] as? String, "父项目")
        XCTAssertEqual((root["children"] as? [Any])?.count, 1)
    }

    // MARK: - 收敛 / 不做无谓重写

    func test_compact_is_idempotent() throws {
        let encoded = try JSONEncoder().encode(
            makeSnapshot(thumbnail: makeFatPhotoPNG(), finishedImage: nil)
        )
        let first = try XCTUnwrap(HistorySnapshotCompactor.compact(encoded))
        XCTAssertNil(
            HistorySnapshotCompactor.compact(first.data),
            "瘦过的快照必须是 no-op，否则每次启动都重写整张历史表"
        )
    }

    func test_compact_returns_nil_for_snapshot_without_fat_images() throws {
        let encoded = try JSONEncoder().encode(
            makeSnapshot(thumbnail: Data([0xFF, 0xD8, 0xFF]), finishedImage: nil)
        )
        XCTAssertNil(HistorySnapshotCompactor.compact(encoded))
    }

    func test_compact_returns_nil_for_non_json() {
        XCTAssertNil(HistorySnapshotCompactor.compact(Data([0x00, 0x01, 0x02])))
    }
}
