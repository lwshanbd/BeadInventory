//
//  BackupArchiveRoundTripTests.swift
//  BeadInventoryTests
//
//  归档 round-trip:manifest 编码 → 解码 → 逐字段比对。
//
//  ## 为什么这组测试是必须的
//
//  这个 App 已经因为"备份少写了一个字段"付出过代价:旧 JSON 格式一直没写 `patternGrid`
//  (源码里自注「S4 follow-up」),实测库里 **595 / 669 个项目**带网格标定 ——
//  用旧备份恢复,这 595 份全部静默丢失。没有任何测试会红。
//
//  新格式初版我自己也漏了 `purchaseRecords`(旧 JSON 里有),是编译器报参数缺失才发现的。
//  两次都说明同一件事:**"我记得都写了"不是保证,逐字段比对才是。**
//
//  所以下面刻意用**全字段非默认值**的 fixture:任何一个字段在编码或解码时被漏掉,
//  比对就会失败。新增字段时,请同步扩充 `makeFullyPopulatedManifest`。

import XCTest
@testable import BeadInventory

final class BackupArchiveRoundTripTests: XCTestCase {

    /// 每个字段都塞非默认值 —— 漏写任何一个都会在比对时暴露。
    private func makeFullyPopulatedManifest() -> BackupArchiveManifest {
        let projectID = UUID()
        let brandID = UUID()

        let project = ArchivedProject(
            id: projectID,
            name: "拼豆项目·全字段",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            totalBeads: 12_345,
            brandId: brandID,
            isArchived: true,
            parentId: UUID(),
            isPlanned: true,
            executedDate: Date(timeIntervalSince1970: 1_700_001_000),
            completedDate: Date(timeIntervalSince1970: 1_700_002_000),
            colorSystemRaw: "MARD",
            beadUsage: [
                ArchivedBeadUsage(colorCode: "A1", brandId: brandID, quantity: 42, isDeducted: true),
                ArchivedBeadUsage(colorCode: "B2", brandId: nil, quantity: 7, isDeducted: false)
            ],
            thumbnail: ArchivedBlobRef(file: "blobs/\(projectID).thumbnail", bytes: 1024, sha256: String(repeating: "a", count: 64)),
            finishedImage: ArchivedBlobRef(file: "blobs/\(projectID).finished", bytes: 2048, sha256: String(repeating: "b", count: 64)),
            displayThumbnail: ArchivedBlobRef(file: "blobs/\(projectID).display", bytes: 512, sha256: String(repeating: "c", count: 64)),
            patternGrid: ArchivedBlobRef(file: "blobs/\(projectID).grid", bytes: 256, sha256: String(repeating: "d", count: 64))
        )

        return BackupArchiveManifest(
            formatVersion: BackupArchiveWriter.currentFormatVersion,
            createdAt: Date(timeIntervalSince1970: 1_700_003_000),
            appVersion: "9.9.9",
            consistencyModel: "per-record",
            projects: [project],
            brands: [ArchivedBrand(id: brandID, name: "咪小窝", sortOrder: 3,
                                   createdAt: Date(timeIntervalSince1970: 1_600_000_000),
                                   lowStockThreshold: 250, colorSystemRaw: "MARD")],
            brandStocks: [ArchivedBrandStock(id: UUID(), brandId: brandID, mardCode: "A1",
                                             stock: 1000, used: 37, isHidden: true)],
            customColors: [ArchivedCustomColor(id: UUID(), colorCode: "MY01", colorName: "珊瑚红",
                                               colorHex: "FF5733",
                                               createdAt: Date(timeIntervalSince1970: 1_600_100_000),
                                               updatedAt: Date(timeIntervalSince1970: 1_600_200_000))],
            purchaseRecords: [ArchivedPurchaseRecord(
                id: UUID(), name: "淘宝订单 001",
                date: Date(timeIntervalSince1970: 1_650_000_000), brandId: brandID,
                items: [ArchivedPurchaseItem(id: UUID(), colorCode: "A1", quantity: 500)],
                note: "含备注"
            )],
            currentBrandId: brandID
        )
    }

    private func encodeDecode(_ manifest: BackupArchiveManifest) throws -> BackupArchiveManifest {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupArchiveManifest.self, from: data)
    }

    func testManifestRoundTripPreservesEveryField() throws {
        let original = makeFullyPopulatedManifest()
        let decoded = try encodeDecode(original)

        XCTAssertEqual(decoded.formatVersion, original.formatVersion)
        XCTAssertEqual(decoded.appVersion, original.appVersion)
        XCTAssertEqual(decoded.consistencyModel, original.consistencyModel)
        XCTAssertEqual(decoded.currentBrandId, original.currentBrandId)
        XCTAssertEqual(decoded.createdAt.timeIntervalSince1970,
                       original.createdAt.timeIntervalSince1970, accuracy: 1)

        // 项目
        let p0 = original.projects[0], p1 = decoded.projects[0]
        XCTAssertEqual(p1.id, p0.id)
        XCTAssertEqual(p1.name, p0.name)
        XCTAssertEqual(p1.totalBeads, p0.totalBeads)
        XCTAssertEqual(p1.brandId, p0.brandId)
        XCTAssertEqual(p1.isArchived, p0.isArchived)
        XCTAssertEqual(p1.parentId, p0.parentId)
        XCTAssertEqual(p1.isPlanned, p0.isPlanned)
        XCTAssertEqual(p1.colorSystemRaw, p0.colorSystemRaw)
        XCTAssertEqual(p1.executedDate?.timeIntervalSince1970 ?? -1,
                       p0.executedDate?.timeIntervalSince1970 ?? -1, accuracy: 1)
        XCTAssertEqual(p1.completedDate?.timeIntervalSince1970 ?? -1,
                       p0.completedDate?.timeIntervalSince1970 ?? -1, accuracy: 1)

        // 用量
        XCTAssertEqual(p1.beadUsage.count, 2)
        XCTAssertEqual(p1.beadUsage[0].colorCode, "A1")
        XCTAssertEqual(p1.beadUsage[0].brandId, p0.beadUsage[0].brandId)
        XCTAssertEqual(p1.beadUsage[0].quantity, 42)
        XCTAssertTrue(p1.beadUsage[0].isDeducted)
        XCTAssertNil(p1.beadUsage[1].brandId, "brandId 为 nil 的用量必须仍然是 nil")

        // 四个 blob 引用 —— patternGrid 是旧格式漏掉的那个，必须在场
        XCTAssertEqual(p1.thumbnail?.sha256, p0.thumbnail?.sha256)
        XCTAssertEqual(p1.thumbnail?.bytes, 1024)
        XCTAssertEqual(p1.finishedImage?.bytes, 2048)
        XCTAssertEqual(p1.displayThumbnail?.bytes, 512)
        XCTAssertEqual(p1.patternGrid?.bytes, 256, "patternGrid 不能再丢")
        XCTAssertEqual(p1.patternGrid?.file, p0.patternGrid?.file)

        // 品牌 / 库存 / 自定义色 / 进货记录
        XCTAssertEqual(decoded.brands[0].name, "咪小窝")
        XCTAssertEqual(decoded.brands[0].lowStockThreshold, 250)
        XCTAssertEqual(decoded.brandStocks[0].stock, 1000)
        XCTAssertEqual(decoded.brandStocks[0].used, 37)
        XCTAssertTrue(decoded.brandStocks[0].isHidden)
        XCTAssertEqual(decoded.customColors[0].colorName, "珊瑚红")
        XCTAssertEqual(decoded.customColors[0].colorHex, "FF5733")

        // purchaseRecords：新格式初版漏过它，这条是回归钉子
        XCTAssertEqual(decoded.purchaseRecords.count, 1, "purchaseRecords 不能再丢")
        XCTAssertEqual(decoded.purchaseRecords[0].name, "淘宝订单 001")
        XCTAssertEqual(decoded.purchaseRecords[0].note, "含备注")
        XCTAssertEqual(decoded.purchaseRecords[0].items[0].colorCode, "A1")
        XCTAssertEqual(decoded.purchaseRecords[0].items[0].quantity, 500)
    }

    /// 可选字段全为 nil 时也要能正确 round-trip —— "没有图" 和 "有图" 一样是合法状态。
    func testRoundTripWithAllOptionalsNil() throws {
        let project = ArchivedProject(
            id: UUID(), name: "空", date: Date(), totalBeads: 0, brandId: nil,
            isArchived: false, parentId: nil, isPlanned: false, executedDate: nil,
            completedDate: nil, colorSystemRaw: "MARD", beadUsage: [],
            thumbnail: nil, finishedImage: nil, displayThumbnail: nil, patternGrid: nil
        )
        let manifest = BackupArchiveManifest(
            formatVersion: 1, createdAt: Date(), appVersion: "t", consistencyModel: "per-record",
            projects: [project], brands: [], brandStocks: [], customColors: [],
            purchaseRecords: [], currentBrandId: nil
        )
        let decoded = try encodeDecode(manifest)
        XCTAssertNil(decoded.projects[0].thumbnail)
        XCTAssertNil(decoded.projects[0].patternGrid)
        XCTAssertNil(decoded.currentBrandId)
        XCTAssertTrue(decoded.purchaseRecords.isEmpty)
    }
}
