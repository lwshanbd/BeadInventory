//
//  PartsSheetUsageTests.swift
//  BeadInventoryTests
//
//  核对完颜色之后按格子颗数扣库存。这件事错了屏幕上什么都看不出来：扣减清单照样是
//  一列色号加一列数字，只是数字不对，等用户拼到一半发现豆子不够才知道。
//  这里只管数法本身：所有零件的格子都算、复制过的乘份数、摆没摆上板不影响、等着补判色时不给答案、空格不算、
//  任意色有去处、翻不出来的码不丢。真实的色号翻译在 `PartsSheetUsageSyncTests`。
//

import XCTest
@testable import BeadInventory

final class PartsSheetUsageTests: XCTestCase {

    /// 造一个判过色的零件，`cells` 按行给，`nil` 是空格，`"any"` 是任意色。
    private func makePart(_ rows: [[String?]]) -> BeadPart {
        let cells = rows.map { row in
            row.map { code -> PartCellFill in
                guard let code else { return .empty }
                return code == "any" ? .anyColor : .code(code)
            }
        }
        return BeadPart(rowBand: 0, bounds: .zero,
                        rows: cells.count, cols: cells.first?.count ?? 0, cells: cells)
    }

    private func makeSheet(parts: [BeadPart], boards: [PartsBoard]? = nil) -> BeadPartsSheet {
        BeadPartsSheet(roi: .zero, workingImageSize: .zero, colorSystem: .mard,
                       parts: parts, boards: boards)
    }

    /// 翻译原样返回：这几条只看数得对不对。
    private func usage(of sheet: BeadPartsSheet) -> [String: Int] {
        guard let counts = PartsSheetUsage.cellCounts(in: sheet) else { return [:] }
        return PartsSheetUsage.beadUsage(from: counts, anyColorCode: PartsSheetUsage.anyColorCode) { code, _ in code }
            .reduce(into: [:]) { $0[$1.colorCode] = $1.quantity }
    }

    // MARK: - 数的是所有零件的格子

    /// 一个零件都没摆上板，也照样全算。扣多少颗跟摆没摆上板没有关系。
    func testCountsEveryPartWithoutBoards() {
        let a = makePart([["H7", "H7"], ["A1", nil]])
        let b = makePart([["H7", nil]])
        XCTAssertEqual(usage(of: makeSheet(parts: [a, b])), ["H7": 3, "A1": 1])
    }

    /// 复制过的零件按要拼的份数乘，没复制的按一份。
    func testCopiesMultiplyCounts() {
        var copied = makePart([["H7", "A1"]])
        copied.copies = 2
        let single = makePart([["H7", nil]])
        XCTAssertEqual(usage(of: makeSheet(parts: [copied, single])), ["H7": 3, "A1": 2])
    }

    /// 份数记在零件上，跟板上摆了几份无关：取下一份待会儿再摆，扣减不能跟着少。
    func testTakingCopiesOffTheBoardDoesNotChangeCounts() {
        var part = makePart([["H7", "A1"]])
        part.copies = 2
        let both = [PartsBoard(size: BeadBoardSize(cols: 50, rows: 50), placements: [
            PartPlacement(partId: part.id, col: 0, row: 0),
            PartPlacement(partId: part.id, col: 10, row: 10, mirrored: true)
        ])]
        let none = [PartsBoard(size: BeadBoardSize(cols: 50, rows: 50))]
        XCTAssertEqual(usage(of: makeSheet(parts: [part], boards: both)), ["H7": 2, "A1": 2])
        XCTAssertEqual(usage(of: makeSheet(parts: [part], boards: none)), ["H7": 2, "A1": 2])
    }

    /// 有零件划好了网格却没有格子（重调网格之后等着补判色），数出来缺一块，不能给答案。
    func testPartAwaitingJudgementYieldsNil() {
        let judged = makePart([["H7", "H7"]])
        let pending = BeadPart(rowBand: 0, bounds: .zero, rows: 2, cols: 2)
        XCTAssertNil(PartsSheetUsage.cellCounts(in: makeSheet(parts: [judged, pending])))
        XCTAssertNil(PartsSheetUsage.cellCounts(in: makeSheet(parts: [])))
    }

    /// 还没划网格的零件没有格子，核对页不算它，这里也不算，也不挡着其它零件出结果。
    func testUngriddedPartIsIgnoredLikeReviewScreen() {
        let judged = makePart([["H7", "H7"]])
        let ungridded = BeadPart(rowBand: 0, bounds: .zero)
        XCTAssertEqual(usage(of: makeSheet(parts: [judged, ungridded])), ["H7": 2])
    }

    // MARK: - 任意色

    /// 任意色扣到约定的色号上，并且告诉翻译方这一条是任意色，好让它去认自定义色号。
    func testAnyColorGoesToTheAnyColorCode() {
        let sheet = makeSheet(parts: [makePart([["any", "any", "H7"]])])
        let counts = PartsSheetUsage.cellCounts(in: sheet) ?? [:]

        var sources: [String: PartsSheetUsage.CodeSource] = [:]
        let result = PartsSheetUsage.beadUsage(from: counts, anyColorCode: "任意色") { code, source in
            sources[code] = source
            return code
        }
        XCTAssertEqual(result.reduce(into: [:]) { $0[$1.colorCode] = $1.quantity }, ["任意色": 2, "H7": 1])
        XCTAssertEqual(sources["任意色"], .anyColor)
        XCTAssertEqual(sources["H7"], .cellCode)
    }

    // MARK: - 翻译之后

    /// 两个码翻到同一颗豆子上要合成一条，不能扣两次。
    func testCodesResolvingToSameBeadAreMerged() {
        let counts = ["B2": 2, "B300": 1]
        let result = PartsSheetUsage.beadUsage(from: counts, anyColorCode: "任意色") { _, _ in "H2" }
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.colorCode, "H2")
        XCTAssertEqual(result.first?.quantity, 3)
    }

    /// 翻不出来的码原样留着，不能把这几颗悄悄抹掉。
    func testUnresolvableCodeIsKept() {
        let result = PartsSheetUsage.beadUsage(from: ["???": 4], anyColorCode: "任意色") { _, _ in nil }
        XCTAssertEqual(result.map(\.colorCode), ["???"])
        XCTAssertEqual(result.first?.quantity, 4)
    }

    /// 颗数多的排前面；一样多时按色号。执行扣减那一屏每次打开都得是同一个次序。
    func testOrderIsStable() {
        let counts = PartsSheetUsage.cellCounts(in: makeSheet(parts: [makePart([["A1", "A1", "A1"], ["H10", "H7", nil]])])) ?? [:]
        let codes = PartsSheetUsage.beadUsage(from: counts, anyColorCode: "任意色") { code, _ in code }.map(\.colorCode)
        XCTAssertEqual(codes, ["A1", "H7", "H10"])
    }

    /// 比的是色号和颗数，不是 id。不然每存一次进度都会被当成「改了」。
    func testIsSameUsageIgnoresIdentity() {
        let lhs = [BeadUsage(colorCode: "H7", quantity: 3), BeadUsage(colorCode: "A1", quantity: 1)]
        let rhs = [BeadUsage(colorCode: "A1", quantity: 1), BeadUsage(colorCode: "H7", quantity: 3)]
        XCTAssertTrue(PartsSheetUsage.isSameUsage(lhs, rhs))
        XCTAssertFalse(PartsSheetUsage.isSameUsage(lhs, [BeadUsage(colorCode: "H7", quantity: 3)]))
    }
}
