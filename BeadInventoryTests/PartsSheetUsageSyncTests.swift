//
//  PartsSheetUsageSyncTests.swift
//  BeadInventoryTests
//
//  计划用量换成格子颗数的那一步，以及扣库存、撤销两头。错了都是静默的：
//  - 卡卡图纸格子里的 B11 是黑豆，MARD 的 B11 是橄榄绿。翻错了扣的是另一颗豆子。
//  - 有零件等着补判色时就同步，计划会少一块，执行时少扣。
//  - 格子没变也同步，用户手调过的数被悄悄盖掉。
//  - 撤销不写回用量，AI 读出来的那份数就再也找不回来。
//  - 扣不动的那一行（比如没建自定义色号的「任意色」）被记成已扣，库存却一颗没动。
//
//  `HistoryManager.shared` 换成内存库：测试挂在 App 宿主里跑，不换的话每跑一次就往
//  模拟器真实库（可能还有 iCloud）里写一条「修改计划」。
//

import XCTest
import SwiftData
@testable import BeadInventory

@MainActor
final class PartsSheetUsageSyncTests: XCTestCase {

    /// 撞名的两颗豆子，取自 `PartsLegendResolutionTests`。
    private let olive = BeadColor(colorHex: "5D722A", mardCode: "B11", kakaCode: "B140")
    private let black = BeadColor(colorHex: "000000", mardCode: "H7", cocoCode: "B09", kakaCode: "B11")

    private var manager: InventoryManager!
    private weak var previousHistoryOwner: InventoryManager?

    override func setUp() async throws {
        try await super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: SDHistoryRecord.self, configurations: config)
        HistoryManager.shared.setModelContext(ModelContext(container))
        await HistoryManager.shared.loadTask?.value

        manager = InventoryManager()
        manager.beadColors = [olive, black]
        manager.customColors = []
        manager.brandStocks = []
        previousHistoryOwner = HistoryManager.shared.inventoryManager
        HistoryManager.shared.inventoryManager = manager
    }

    override func tearDown() async throws {
        HistoryManager.shared.inventoryManager = previousHistoryOwner
        manager = nil
        await HistoryManager.shared.loadTask?.value
        try await super.tearDown()
    }

    private func plan(_ system: ColorSystem, usage: [BeadUsage] = [BeadUsage(colorCode: "H7", quantity: 99)]) -> ProjectRecord {
        ProjectRecord(name: "计划", beadUsage: usage, isPlanned: true, colorSystem: system)
    }

    private func sheet(_ system: ColorSystem, cells: [[PartCellFill]]) -> BeadPartsSheet {
        let part = BeadPart(rowBand: 0, bounds: .zero, rows: cells.count, cols: cells.first?.count ?? 0, cells: cells)
        return BeadPartsSheet(roi: .zero, workingImageSize: .zero, colorSystem: system, parts: [part])
    }

    private func table(_ usage: [BeadUsage]) -> [String: Int] {
        usage.reduce(into: [:]) { $0[$1.colorCode, default: 0] += $1.quantity }
    }

    // MARK: - 色号翻译

    /// 卡卡图纸上的 B11 是黑豆，要存成 mardCode H7，不能原样存 B11（那是 MARD 的橄榄绿）。
    func testKakaCellCodeBecomesItsMardCode() {
        let p = plan(.kaka)
        manager.projects = [p]
        let s = sheet(.kaka, cells: [[.code("B11"), .code("B11"), .code("B11")]])

        XCTAssertNotNil(manager.syncPlannedUsageFromPartsSheet(p.id, sheet: s))
        XCTAssertEqual(table(manager.projects[0].beadUsage), ["H7": 3])
        XCTAssertEqual(manager.projects[0].totalBeads, 3)
    }

    /// MARD 图纸上格子里的码本身就是 mardCode。
    func testMardCellCodeStaysMardCode() {
        let p = plan(.mard)
        manager.projects = [p]
        let s = sheet(.mard, cells: [[.code("B11"), .code("H7")]])

        XCTAssertNotNil(manager.syncPlannedUsageFromPartsSheet(p.id, sheet: s))
        XCTAssertEqual(table(manager.projects[0].beadUsage), ["B11": 1, "H7": 1])
    }

    /// 任意色落在用户建的同名自定义色号上。
    func testAnyColorResolvesToCustomColor() {
        manager.customColors = [CustomColor(colorCode: PartsSheetUsage.anyColorCode, colorHex: "CCCCCC")]
        let p = plan(.kaka)
        manager.projects = [p]
        let s = sheet(.kaka, cells: [[.anyColor, .anyColor, .code("B11")]])

        XCTAssertNotNil(manager.syncPlannedUsageFromPartsSheet(p.id, sheet: s))
        XCTAssertEqual(table(manager.projects[0].beadUsage), ["#任意色": 2, "H7": 1])
    }

    // MARK: - 什么时候不动计划

    /// 有零件划好网格、等着补判色：计划保持原样。
    func testIncompleteSheetLeavesPlanAlone() {
        let p = plan(.mard)
        manager.projects = [p]
        var s = sheet(.mard, cells: [[.code("H7")]])
        s.parts.append(BeadPart(rowBand: 0, bounds: .zero, rows: 1, cols: 1))

        XCTAssertNil(manager.syncPlannedUsageFromPartsSheet(p.id, sheet: s))
        XCTAssertEqual(table(manager.projects[0].beadUsage), ["H7": 99])
    }

    /// 格子跟上次同步时一样：用户之后手调过的数不被盖掉。
    func testUnchangedCellsKeepManualEdits() {
        let edited = plan(.mard, usage: [BeadUsage(colorCode: "H7", quantity: 120)])
        manager.projects = [edited]
        var s = sheet(.mard, cells: [[.code("H7"), .code("H7")]])
        s.syncedCellCounts = ["H7": 2]

        XCTAssertNil(manager.syncPlannedUsageFromPartsSheet(edited.id, sheet: s))
        XCTAssertEqual(table(manager.projects[0].beadUsage), ["H7": 120])
    }

    /// 已经执行过的项目、父项目都不动。
    func testExecutedAndParentProjectsAreNotTouched() {
        let executed = ProjectRecord(name: "已执行", beadUsage: [BeadUsage(colorCode: "H7", quantity: 99)],
                                     isPlanned: false, colorSystem: .mard)
        let parent = plan(.mard)
        let child = ProjectRecord(name: "子", beadUsage: [BeadUsage(colorCode: "H7", quantity: 1)],
                                  parentId: parent.id, isPlanned: true, colorSystem: .mard)
        manager.projects = [executed, parent, child]
        let s = sheet(.mard, cells: [[.code("B11")]])

        XCTAssertNil(manager.syncPlannedUsageFromPartsSheet(executed.id, sheet: s))
        XCTAssertNil(manager.syncPlannedUsageFromPartsSheet(parent.id, sheet: s))
        XCTAssertEqual(table(manager.projects[0].beadUsage), ["H7": 99])
        XCTAssertEqual(table(manager.projects[1].beadUsage), ["H7": 99])
    }

    // MARK: - 撤销

    /// 撤销这条「修改计划」要把 AI 读出来的那份用量写回去。
    func testUndoRestoresPreviousUsage() {
        let p = plan(.mard)
        manager.projects = [p]
        XCTAssertNotNil(manager.syncPlannedUsageFromPartsSheet(p.id, sheet: sheet(.mard, cells: [[.code("B11")]])))
        XCTAssertEqual(table(manager.projects[0].beadUsage), ["B11": 1])

        guard let record = HistoryManager.shared.records.first(where: { $0.operationType == .planUpdate }) else {
            return XCTFail("同步之后应记一条修改计划")
        }
        guard case .success = HistoryManager.shared.revert(record.id) else {
            return XCTFail("撤销应当成功")
        }
        XCTAssertEqual(table(manager.projects[0].beadUsage), ["H7": 99])
        XCTAssertEqual(manager.projects[0].totalBeads, 99)
    }

    // MARK: - 扣库存

    /// 扣不动的那一行要如实记成没扣，扣得动的照常扣。
    func testExecuteMarksUndeductibleRowAsNotDeducted() {
        let brand = Brand(name: "品牌", colorSystem: .mard)
        manager.brands = [brand]
        manager.brandStocks = [BrandStock(brandId: brand.id, mardCode: "H7", stock: 100)]
        let p = plan(.mard, usage: [BeadUsage(colorCode: "H7", quantity: 10),
                                    BeadUsage(colorCode: "任意色", quantity: 5)])
        manager.projects = [p]

        XCTAssertTrue(manager.executePlannedProject(p.id, withBrand: brand.id))
        let rows = manager.projects[0].beadUsage
        XCTAssertEqual(rows.first { $0.colorCode == "H7" }?.isDeducted, true)
        XCTAssertEqual(rows.first { $0.colorCode == "任意色" }?.isDeducted, false)
        XCTAssertEqual(manager.getStock(brandId: brand.id, mardCode: "H7")?.used, 10)
    }
}
