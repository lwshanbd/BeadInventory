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

    /// HistoryManager 是单例：用例间排空在途后台加载，避免迟到完成在下一个用例里改单例状态
    /// （顺序无关隔离；挂起的防抖保存已由各用例的 setModelContext 取消）。
    override func tearDown() async throws {
        await HistoryManager.shared.loadTask?.value
        try await super.tearDown()
    }

    /// 新默认加载路径的往返：带 blob 写入 → loadData 后内存只剩 metadata →
    /// hydratedRecord 必须能按 id 把原始 snapshot 字节取回来（含缓存命中路径）。
    func test_hydratedRecord_afterMetadataOnlyReload_returnsOriginalSnapshotBytes() async throws {
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
        mgr.setModelContext(ctx)   // → loadData()（后台异步），records 变成 metadata-only
        await mgr.loadTask?.value  // 等后台加载落定再断言

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
    func test_performSave_metadataOnlyRecord_doesNotWipeStoredBlob() async throws {
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
        await mgr.loadTask?.value  // 等后台加载落定再断言
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

    /// 回归守卫（PR #52 双审 Codex Critical）：loadData 改异步后，加载窗口内（isDataLoaded
    /// 仍为 false）新建的历史记录——即使其防抖保存在加载落定前先触发被跳过——最终也必须
    /// **落库**，不能因 `pendingSave` 被清而永久只留在内存里、退出即丢。
    ///
    /// 该用例确定性地复现「保存先于加载落定触发」（直接调 saveDataImmediately，不依赖 0.1s 防抖）。
    /// 两处修复（performSave 的 pendingSave 保留 + loadData 收尾补存）互为兜底：**两处同时去掉**本
    /// 用例才会挂（任一处单独保留都能让记录最终落库）。要给每处修复单独建回归，需各自只留一处。
    func test_recordCreatedDuringLoad_isPersistedAfterLoadCompletes() async throws {
        let ctx = try makeInMemoryHistoryContext()
        let persistedID = UUID()
        ctx.insert(SDHistoryRecord(
            id: persistedID,
            timestamp: Date(timeIntervalSince1970: 1_000),
            operationType: HistoryOperationType.projectUpdate.rawValue,
            targetName: "已持久化",
            beforeSnapshot: nil,
            afterSnapshot: nil,
            isReverted: false
        ))
        try ctx.save()

        let mgr = HistoryManager.shared
        mgr.setModelContext(ctx)   // 踢出后台加载；执行到这里尚未完成、isDataLoaded=false
        // 加载窗口内新建一条（仅在内存；下面的保存会因 isDataLoaded=false 被守卫跳过）
        mgr.record(type: .projectUpdate, entityName: "加载期间新建")
        let pendingID = mgr.records.first?.id
        XCTAssertNotNil(pendingID, "新建后内存里应有这条")
        // 确定性复现「加载落定前保存先触发」：performSave 跳过。修复前这里会清掉 pendingSave。
        mgr.saveDataImmediately()

        await mgr.loadTask?.value   // 加载落定 → 合并 pending 并补触发保存
        mgr.saveDataImmediately()   // 把补触发的保存真正落库

        // 内存：两条都在
        XCTAssertTrue(mgr.records.contains { $0.id == persistedID }, "原持久化记录应在内存")
        XCTAssertTrue(mgr.records.contains { $0.id == pendingID }, "加载期间新建的记录应在内存")
        // 落库：加载期间新建的记录最终必须进库（不能因 pendingSave 被清而永久丢失）
        let stored = try ctx.fetch(FetchDescriptor<SDHistoryRecord>())
        XCTAssertTrue(stored.contains { $0.id == persistedID }, "原持久化记录应在库")
        XCTAssertTrue(stored.contains { $0.id == pendingID }, "加载期间新建的记录最终应落库")
    }
}
