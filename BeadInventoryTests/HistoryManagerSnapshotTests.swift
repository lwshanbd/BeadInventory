//
//  HistoryManagerSnapshotTests.swift
//  BeadInventoryTests
//
//  覆盖 PR #51 的 metadata-only 加载 + 按需 hydrate 路径。
//  重点是「静默 blob 丢失」这个对手动测试不可见的回归（只在 metadata-only
//  记录被回存后才发作，症状是未来某次撤回静默失败）。
//

import XCTest
import SwiftData
@testable import BeadInventory

@MainActor
final class HistoryManagerSnapshotTests: XCTestCase {

    /// 仅注册 SDHistoryRecord 的内存 ModelContext（该模型无 relationship，独立成库即可）。
    private func makeInMemoryHistoryContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: SDHistoryRecord.self, configurations: config)
        return ModelContext(container)
    }

    /// 新默认加载路径的往返：带 blob 写入 → loadData 后内存只剩 metadata →
    /// hydratedRecord 必须能按 id 把原始 snapshot 字节取回来（含缓存命中路径）。
    func test_hydratedRecord_afterMetadataOnlyReload_returnsOriginalSnapshotBytes() throws {
        let ctx = try makeInMemoryHistoryContext()
        let before = Data("before-blob".utf8)
        let after = Data("after-blob".utf8)
        let id = UUID()
        ctx.insert(SDHistoryRecord(
            id: id,
            timestamp: Date(),
            operationType: HistoryOperationType.projectUpdate.rawValue,
            targetName: "项目",
            beforeSnapshot: before,
            afterSnapshot: after,
            isReverted: false
        ))
        try ctx.save()

        let mgr = HistoryManager.shared
        mgr.setModelContext(ctx)   // → loadData()，records 变成 metadata-only

        guard let meta = mgr.records.first else {
            return XCTFail("loadData 后应有 1 条记录")
        }
        XCTAssertNil(meta.beforeSnapshot, "metadata-only 加载不应携带 snapshot blob")
        XCTAssertNil(meta.afterSnapshot)

        let hydrated = mgr.hydratedRecord(meta)
        XCTAssertEqual(hydrated.beforeSnapshot, before)
        XCTAssertEqual(hydrated.afterSnapshot, after)
        XCTAssertEqual(hydrated.id, id, "hydrate 不应改变 id 等 metadata")
        XCTAssertFalse(hydrated.isReverted)

        // 第二次走缓存仍返回同样字节
        let hydratedAgain = mgr.hydratedRecord(meta)
        XCTAssertEqual(hydratedAgain.beforeSnapshot, before)
        XCTAssertEqual(hydratedAgain.afterSnapshot, after)
    }

    /// 回归守卫：metadata-only 记录（nil snapshot）进入 performSave 的「更新已存在行」
    /// 分支时，nil-guard 必须保证不会把库里的 blob 抹成 nil。若有人把 guard 改回
    /// 无条件赋值，本测试会失败。
    func test_performSave_metadataOnlyRecord_doesNotWipeStoredBlob() throws {
        let ctx = try makeInMemoryHistoryContext()
        let blob = Data("snapshot-blob".utf8)
        let id = UUID()
        ctx.insert(SDHistoryRecord(
            id: id,
            timestamp: Date(),
            operationType: HistoryOperationType.projectUpdate.rawValue,
            targetName: "项目",
            beforeSnapshot: blob,
            afterSnapshot: nil,
            isReverted: false
        ))
        try ctx.save()

        let mgr = HistoryManager.shared
        mgr.setModelContext(ctx)
        guard let meta = mgr.records.first else {
            return XCTFail("loadData 后应有 1 条记录")
        }
        XCTAssertNil(meta.beforeSnapshot)

        // 改 isReverted 触发 changedLocally，让这条 metadata-only 记录进入更新分支，
        // 但它的 beforeSnapshot 仍是 nil（「没加载」而非「没有」）。
        mgr.records[0] = HistoryRecord(
            id: meta.id,
            timestamp: meta.timestamp,
            operationType: meta.operationType,
            entityName: meta.entityName,
            beforeSnapshot: nil,
            afterSnapshot: nil,
            isReverted: true
        )
        mgr.saveData()
        mgr.saveDataImmediately()

        let reFetched = try ctx.fetch(FetchDescriptor<SDHistoryRecord>()).first
        XCTAssertEqual(
            reFetched?.beforeSnapshot,
            blob,
            "metadata-only 记录回存不应清空库里的 snapshot blob"
        )
        XCTAssertEqual(
            reFetched?.isReverted,
            true,
            "isReverted 这类纯 metadata 更新仍应正常写回"
        )
    }
}
