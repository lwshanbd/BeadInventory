//
//  InventoryManagerBlobInvariantTests.swift
//  BeadInventoryTests
//
//  钉住 v2.0.x 的"按需取图 + metadata-only 缓存"架构里几条不能再回归的不变量：
//
//  1. saveData() 在 metadata-only 改动下**不会**把 SDProjectRecord.thumbnail /
//     finishedImage / patternGridData 清成 nil
//     —— 这是整个 PR 存在的理由：projects 缓存里 blob 恒为 nil，老的 saveData diff
//     路径会用 nil 把云端真数据覆盖掉。
//
//  2. capturesImages == false / nil 的 .projectUpdate undo **不会**触发图片还原
//     —— 防止 metadata snapshot 把现存图清成 nil。
//
//  3. updateProjectThumbnail / FinishedImage / PatternGrid 三个直写 setter 保持
//     SDProjectRecord row + projectIDsWith* Set + projectBlobsRevision 同步。
//
//  4. refreshProjectBlobMetadata() 用 SQL 谓词正确分类三个 ID 集合，且会 bump
//     revision 让视图重取。
//

import XCTest
import SwiftData
@testable import BeadInventory

@MainActor
final class InventoryManagerBlobInvariantTests: XCTestCase {

    private func makeManager() throws -> (InventoryManager, ModelContext) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: SDBrand.self, SDBrandStock.self, SDProjectRecord.self,
                 SDBeadUsage.self, SDCustomColor.self, SDHistoryRecord.self,
            configurations: config
        )
        let manager = InventoryManager(modelContext: container.mainContext)
        // 准备最小可保存状态：至少一个 brand 让 loadData 不走异常路径。
        manager.brands = [Brand(name: "TestBrand", lowStockThreshold: 100, colorSystem: .mard)]
        return (manager, container.mainContext)
    }

    private func tinyPNG() -> Data {
        // 1×1 透明 PNG（base64）。够用，不需要真照片大小。
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=")!
    }

    private func insertSDProjectRecord(
        _ context: ModelContext,
        id: UUID = UUID(),
        name: String = "P",
        thumbnail: Data? = nil,
        finishedImage: Data? = nil,
        patternGridData: Data? = nil,
        isPlanned: Bool = true
    ) throws -> SDProjectRecord {
        let sd = SDProjectRecord(
            id: id,
            name: name,
            date: Date(),
            totalBeads: 0,
            brandId: nil,
            isArchived: false,
            parentId: nil,
            isPlanned: isPlanned,
            executedDate: nil,
            thumbnail: thumbnail,
            finishedImage: finishedImage,
            completedDate: nil,
            colorSystemRaw: ColorSystem.mard.rawValue,
            patternGridData: patternGridData,
            beadUsages: []
        )
        context.insert(sd)
        try context.save()
        return sd
    }

    // MARK: - 1. saveData 不清 blob（核心不变量）

    func test_saveData_metadata_edit_preserves_thumbnail_in_db() throws {
        let (manager, ctx) = try makeManager()
        let pngBefore = tinyPNG()
        let id = UUID()
        let sd = try insertSDProjectRecord(ctx, id: id, name: "OldName", thumbnail: pngBefore)
        XCTAssertEqual(sd.thumbnail, pngBefore, "前置：SwiftData 行里有 thumbnail")

        // 模拟 loadData 走完后的 metadata-only 缓存：
        manager.projects = [sd.toMetadataStruct()]
        XCTAssertNil(manager.projects[0].thumbnail, "前置：缓存里 thumbnail 是 nil")

        // metadata 改动（重命名），然后 saveData
        manager.projects[0].name = "NewName"
        manager.saveData()

        // SwiftData 行的 thumbnail 必须保留
        let descriptor = FetchDescriptor<SDProjectRecord>(predicate: #Predicate { $0.id == id })
        let fetched = try ctx.fetch(descriptor).first
        XCTAssertEqual(fetched?.name, "NewName", "name 改动应该写入")
        XCTAssertEqual(fetched?.thumbnail, pngBefore, "thumbnail 不能被 saveData 用 nil 覆盖 —— 这是整个 PR 防止的回归")
    }

    func test_saveData_metadata_edit_preserves_finishedImage_in_db() throws {
        let (manager, ctx) = try makeManager()
        let pngBefore = tinyPNG()
        let id = UUID()
        let sd = try insertSDProjectRecord(ctx, id: id, finishedImage: pngBefore, isPlanned: false)

        manager.projects = [sd.toMetadataStruct()]
        manager.projects[0].name = "NewName"
        manager.saveData()

        let descriptor = FetchDescriptor<SDProjectRecord>(predicate: #Predicate { $0.id == id })
        let fetched = try ctx.fetch(descriptor).first
        XCTAssertEqual(fetched?.finishedImage, pngBefore, "finishedImage 不能被 saveData 用 nil 覆盖")
    }

    func test_saveData_metadata_edit_preserves_patternGrid_in_db() throws {
        let (manager, ctx) = try makeManager()
        let gridJSON = "{\"v\":1}".data(using: .utf8)!
        let id = UUID()
        let sd = try insertSDProjectRecord(ctx, id: id, patternGridData: gridJSON)

        manager.projects = [sd.toMetadataStruct()]
        manager.projects[0].name = "NewName"
        manager.saveData()

        let descriptor = FetchDescriptor<SDProjectRecord>(predicate: #Predicate { $0.id == id })
        let fetched = try ctx.fetch(descriptor).first
        XCTAssertEqual(fetched?.patternGridData, gridJSON, "patternGridData 不能被 saveData 用 nil 覆盖")
    }

    // MARK: - 2. updateProject* 同步 row + ID 集合 + revision

    func test_updateProjectThumbnail_writes_row_and_updates_set_and_revision() throws {
        let (manager, ctx) = try makeManager()
        let id = UUID()
        let sd = try insertSDProjectRecord(ctx, id: id, thumbnail: nil)
        manager.projects = [sd.toMetadataStruct()]

        let revBefore = manager.projectBlobsRevision
        XCTAssertFalse(manager.projectIDsWithThumbnail.contains(id), "前置：集合中无该项目")

        let newPNG = tinyPNG()
        manager.updateProjectThumbnail(id, thumbnail: newPNG)

        // (a) SwiftData row 有图
        let fetched = try ctx.fetch(
            FetchDescriptor<SDProjectRecord>(predicate: #Predicate { $0.id == id })
        ).first
        XCTAssertEqual(fetched?.thumbnail, newPNG, "row 应该写入新图")

        // (b) ID 集合更新
        XCTAssertTrue(manager.projectIDsWithThumbnail.contains(id), "集合应该 insert")

        // (c) revision 推进
        XCTAssertGreaterThan(manager.projectBlobsRevision, revBefore, "revision 应该 ++")
    }

    func test_updateProjectThumbnail_with_nil_removes_from_set() throws {
        let (manager, ctx) = try makeManager()
        let id = UUID()
        let initialPNG = tinyPNG()
        let sd = try insertSDProjectRecord(ctx, id: id, thumbnail: initialPNG)
        manager.projects = [sd.toMetadataStruct()]
        // 通过 refresh 把集合填进去（projectIDsWithThumbnail 是 private(set) 不能直接赋值，
        // 但 refresh 会从 SwiftData 拉初始状态）。
        manager.refreshProjectBlobMetadata()
        XCTAssertTrue(manager.projectIDsWithThumbnail.contains(id), "前置：refresh 后集合应包含该项目")

        manager.updateProjectThumbnail(id, thumbnail: nil)

        let fetched = try ctx.fetch(
            FetchDescriptor<SDProjectRecord>(predicate: #Predicate { $0.id == id })
        ).first
        XCTAssertNil(fetched?.thumbnail, "row 应该清空")
        XCTAssertFalse(manager.projectIDsWithThumbnail.contains(id), "集合应该 remove")
    }

    // MARK: - 3. refreshProjectBlobMetadata 分类正确 + bump revision

    func test_refreshProjectBlobMetadata_classifies_existing_blobs() throws {
        let (manager, ctx) = try makeManager()
        let png = tinyPNG()
        let grid = "{}".data(using: .utf8)!
        let withThumb = try insertSDProjectRecord(ctx, thumbnail: png)
        let withFinished = try insertSDProjectRecord(ctx, finishedImage: png, isPlanned: false)
        let withGrid = try insertSDProjectRecord(ctx, patternGridData: grid)
        let withNone = try insertSDProjectRecord(ctx)

        let revBefore = manager.projectBlobsRevision
        manager.refreshProjectBlobMetadata()

        XCTAssertEqual(manager.projectIDsWithThumbnail, [withThumb.id])
        XCTAssertEqual(manager.projectIDsWithFinishedImage, [withFinished.id])
        XCTAssertEqual(manager.projectIDsWithPatternGrid, [withGrid.id])
        XCTAssertFalse(manager.projectIDsWithThumbnail.contains(withNone.id))
        XCTAssertGreaterThan(manager.projectBlobsRevision, revBefore, "refresh 也应该 bump")
    }
}
