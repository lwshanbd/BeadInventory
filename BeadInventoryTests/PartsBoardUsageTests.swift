//
//  PartsBoardUsageTests.swift
//  BeadInventoryTests
//
//  排完板之后扣库存按板上摆着的颗数算。这件事错了屏幕上什么都看不出来 —— 扣减清单
//  照样是一列色号加一列数字，只是数字不对，等用户拼到一半发现豆子不够（或者盒子里
//  莫名其妙多出一把）才知道。所以这几条钉的全是「看不见的错」：
//  没摆上板的零件不许算进去、同一个零件摆两遍要算两遍、空格不是豆子、
//  任意色得有去处、以及卡卡图纸上格子里那个码必须翻成 mardCode 再扣。
//

import XCTest
@testable import BeadInventory

final class PartsBoardUsageTests: XCTestCase {

    /// 造一个零件，`cells` 按行给，每格写色号；`nil` 表示空格。
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

    private func makeSheet(
        parts: [BeadPart],
        boards: [PartsBoard]?,
        colorSystem: ColorSystem = .mard,
        anyColorCode: String? = nil
    ) -> BeadPartsSheet {
        BeadPartsSheet(roi: .zero, workingImageSize: .zero, colorSystem: colorSystem,
                       parts: parts, anyColorCode: anyColorCode, boards: boards)
    }

    private func board(_ placements: [PartPlacement]) -> PartsBoard {
        PartsBoard(size: BeadBoardSize(cols: 50, rows: 50), placements: placements)
    }

    /// 原样返回：这几条不看色号翻译，只看数得对不对。
    private func usage(of sheet: BeadPartsSheet) -> [String: Int] {
        PartsBoardUsage.beadUsage(in: sheet) { code, _ in code }
            .reduce(into: [:]) { $0[$1.colorCode] = $1.quantity }
    }

    // MARK: - 数的是板上的

    /// 图纸上两个零件，只摆上去一个。扣的是摆上去那个。
    func testOnlyPlacedPartsAreCounted() {
        let placed = makePart([["H7", "H7"], ["A1", nil]])
        let leftOut = makePart([["H7", "H7"], ["H7", "H7"]])
        let sheet = makeSheet(parts: [placed, leftOut],
                              boards: [board([PartPlacement(partId: placed.id, col: 0, row: 0)])])

        XCTAssertEqual(usage(of: sheet), ["H7": 2, "A1": 1])
    }

    /// 同一个零件摆了两遍（两块板上各一个），豆子就得抓两份。
    func testSamePartPlacedTwiceCountsTwice() {
        let part = makePart([["H7", "A1"]])
        let sheet = makeSheet(parts: [part], boards: [
            board([PartPlacement(partId: part.id, col: 0, row: 0)]),
            board([PartPlacement(partId: part.id, col: 10, row: 10)])
        ])

        XCTAssertEqual(usage(of: sheet), ["H7": 2, "A1": 2])
    }

    /// 转 90° 摆进去的零件还是那些格子，颗数不变。
    func testRotationDoesNotChangeCounts() {
        let part = makePart([["H7", "H7", nil], [nil, "A1", nil]])
        let sheet = makeSheet(parts: [part],
                              boards: [board([PartPlacement(partId: part.id, col: 0, row: 0, turns: 1)])])

        XCTAssertEqual(usage(of: sheet), ["H7": 2, "A1": 1])
    }

    /// 还没排板子（老图纸、或者用户没走到最后一屏）就一条都不给，
    /// 调用方据此保留计划里原来那份数，不会把它清空。
    func testNoBoardsYieldsNothing() {
        let part = makePart([["H7", "H7"]])
        XCTAssertTrue(PartsBoardUsage.beadUsage(in: makeSheet(parts: [part], boards: nil)) { code, _ in code }.isEmpty)
        XCTAssertTrue(PartsBoardUsage.beadUsage(in: makeSheet(parts: [part], boards: [])) { code, _ in code }.isEmpty)
    }

    // MARK: - 任意色

    /// 任意色扣到约定的那个自定义色号上，不会凭空消失。
    func testAnyColorGoesToTheAnyColorCode() {
        let part = makePart([["any", "any", "H7"]])
        let sheet = makeSheet(parts: [part],
                              boards: [board([PartPlacement(partId: part.id, col: 0, row: 0)])])

        XCTAssertEqual(usage(of: sheet), [PartsBoardUsage.anyColorCode: 2, "H7": 1])
    }

    /// 图纸自己指定过任意色用哪个色号时听它的。
    func testAnyColorHonoursTheSheetOverride() {
        let part = makePart([["any", "any"]])
        let sheet = makeSheet(parts: [part],
                              boards: [board([PartPlacement(partId: part.id, col: 0, row: 0)])],
                              anyColorCode: "H7")

        XCTAssertEqual(usage(of: sheet), ["H7": 2])
    }

    // MARK: - 色号翻译

    /// 格子里存的是图纸体系的显示码，扣库存要的是 mardCode。翻译这一道不能省：
    /// 卡卡的 B2 跟 MARD 的 B2 是两颗完全不同的豆子。
    func testCellCodesAreTranslatedAndMerged() {
        let part = makePart([["B2", "B2", "B300"]])
        let sheet = makeSheet(parts: [part],
                              boards: [board([PartPlacement(partId: part.id, col: 0, row: 0)])],
                              colorSystem: .kaka)

        // 两个卡卡码翻到同一颗豆子上时要合成一条，不能扣两次。
        let translated = ["B2": "A1", "B300": "A1"]
        let result = PartsBoardUsage.beadUsage(in: sheet) { code, _ in translated[code] }
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.colorCode, "A1")
        XCTAssertEqual(result.first?.quantity, 3)
    }

    /// 翻不动的码原样留着 —— 扣的时候会落成「未扣减」，用户在清单上看得见，
    /// 比把这几百颗悄悄抹掉强。
    func testUnresolvableCodeIsKept() {
        let part = makePart([["???"]])
        let sheet = makeSheet(parts: [part],
                              boards: [board([PartPlacement(partId: part.id, col: 0, row: 0)])])

        XCTAssertEqual(usage(of: sheet), ["???": 1])
    }

    // MARK: - 顺序和比较

    /// 颗数多的排前面；一样多时按色号。扣减清单每次打开都得是同一个次序。
    func testOrderIsStable() {
        let part = makePart([["A1", "A1", "A1"], ["H10", "H7", nil]])
        let sheet = makeSheet(parts: [part],
                              boards: [board([PartPlacement(partId: part.id, col: 0, row: 0)])])

        let codes = PartsBoardUsage.beadUsage(in: sheet) { code, _ in code }.map(\.colorCode)
        XCTAssertEqual(codes, ["A1", "H7", "H10"])
    }

    /// 比的是色号和颗数，不是 id。不然每存一次进度都会被当成「改了」。
    func testIsSameUsageIgnoresIdentity() {
        let lhs = [BeadUsage(colorCode: "H7", quantity: 3), BeadUsage(colorCode: "A1", quantity: 1)]
        let rhs = [BeadUsage(colorCode: "A1", quantity: 1), BeadUsage(colorCode: "H7", quantity: 3)]
        XCTAssertTrue(PartsBoardUsage.isSameUsage(lhs, rhs))
        XCTAssertFalse(PartsBoardUsage.isSameUsage(lhs, [BeadUsage(colorCode: "H7", quantity: 3)]))
    }
}
