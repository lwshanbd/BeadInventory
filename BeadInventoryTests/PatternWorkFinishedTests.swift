//
//  PatternWorkFinishedTests.swift
//  BeadInventoryTests
//
//  拼完时间从网格 / 零件数据挪到 `SDProjectRecord.patternFinishedAt` 之后，概况怎么判「拼完」。
//
//  这里错了用户看不见报错，只会发现工作台分组不对：
//  - 老用户升级后，拼完的项目还记在零件数据里。项目那一列是空的，兜底一删，它们就全回到「正在拼」。
//  - 项目那一列有值时必须以它为准，两种模式一个说法。
//

import XCTest
import SwiftData
@testable import BeadInventory

final class PatternWorkFinishedTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func makeSheet(legacyFinishedAt: Date?) -> BeadPartsSheet {
        var sheet = BeadPartsSheet(
            roi: CGRect(x: 0, y: 0, width: 1, height: 1),
            workingImageSize: CGSize(width: 100, height: 100),
            colorSystem: .mard,
            lastUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        sheet.finishedAt = legacyFinishedAt
        return sheet
    }

    @MainActor
    private func seed(in container: ModelContainer, sheet: BeadPartsSheet, column: Date?) throws -> UUID {
        let ctx = ModelContext(container)
        let record = SDProjectRecord(name: "拼完测试")
        record.partsSheetData = try JSONEncoder().encode(sheet)
        record.patternFinishedAt = column
        ctx.insert(record)
        try ctx.save()
        return record.id
    }

    @MainActor
    func test_legacy_finishedAt_in_parts_sheet_still_counts_as_finished() async throws {
        let container = try makeContainer()
        let id = try seed(in: container, sheet: makeSheet(legacyFinishedAt: Date(timeIntervalSince1970: 1_700_100_000)), column: nil)

        let work = await ProjectImageLoader(container: container).patternWork(for: id)

        XCTAssertFalse(work.unreadable)
        XCTAssertEqual(work.parts?.stage, .finished, "项目那一列是空的，老数据里记着拼完，就得算拼完")
    }

    @MainActor
    func test_column_wins_and_drives_updatedAt() async throws {
        let container = try makeContainer()
        let finishedAt = Date(timeIntervalSince1970: 1_700_200_000)
        let id = try seed(in: container, sheet: makeSheet(legacyFinishedAt: nil), column: finishedAt)

        let work = await ProjectImageLoader(container: container).patternWork(for: id)

        XCTAssertEqual(work.parts?.stage, .finished)
        XCTAssertEqual(work.parts?.updatedAt, finishedAt, "拼完时间比数据的最后改动晚，排序要按拼完时间")
    }

    @MainActor
    func test_no_finished_anywhere_is_in_progress() async throws {
        let container = try makeContainer()
        let id = try seed(in: container, sheet: makeSheet(legacyFinishedAt: nil), column: nil)

        let work = await ProjectImageLoader(container: container).patternWork(for: id)

        XCTAssertEqual(work.parts?.stage, .inProgress)
    }
}
