//
//  BeadColorTallyTests.swift
//  BeadInventoryTests
//
//  色号条的顺序和「这个色拼完了」这两件事，**错了屏幕上一点看不出来**：
//  顺序错只是"这次进来跟上次长得不太一样"，勾诈尸只是"我记得我标过"——
//  代价要等整块板烫完、发现少了一个颜色才出现。CLAUDE.md 说的
//  「确实会静默出错的纯逻辑」正是这一类。
//

import XCTest
@testable import BeadInventory

final class BeadColorTallyTests: XCTestCase {

    // MARK: - 色号条的顺序

    /// 颗数一样时必须排得死死的。这是这次改动的由来：并列的色号会互相换位置，
    /// 用户照着色号条一个个拼，把换到前面的那个当成已经拼过的，直接跳过去。
    func testTiedCountsFallBackToCode() {
        let counts = ["B1": 5, "A1": 5, "C1": 9]
        XCTAssertEqual(BeadColorTally.ordered(counts).map(\.key), ["C1", "A1", "B1"])
    }

    /// 同一份数据，不管字典是按什么顺序建起来的，排出来都得是同一条。
    func testOrderDoesNotDependOnInsertionOrder() {
        let pairs = [("A1", 5), ("B1", 5), ("C1", 5), ("D1", 5), ("E1", 7)]
        let expected = BeadColorTally.ordered(Dictionary(uniqueKeysWithValues: pairs)).map(\.key)
        for _ in 0..<50 {
            let shuffled = Dictionary(uniqueKeysWithValues: pairs.shuffled())
            XCTAssertEqual(BeadColorTally.ordered(shuffled).map(\.key), expected)
        }
    }

    /// 色号里的数字按数值比，不按字符比：H7 在 H10 前面。
    /// 纯字典序会排成 H10、H7、H8，色号条上看着就是乱的。
    func testCodesWithNumbersSortNumerically() {
        let counts = ["H10": 3, "H7": 3, "H8": 3]
        XCTAssertEqual(BeadColorTally.ordered(counts).map(\.key), ["H7", "H8", "H10"])
    }

    /// 颗数多的还是排前面 —— 二级次序不能把主序顶掉。
    func testCountStillWins() {
        let counts = ["Z9": 100, "A1": 2]
        XCTAssertEqual(BeadColorTally.ordered(counts).map(\.key), ["Z9", "A1"])
    }

    // MARK: - 这块板这个色拼完了

    private func makeBoard() -> PartsBoard {
        PartsBoard(size: BeadBoardSize(cols: 29, rows: 29))
    }

    func testMarkAndClear() {
        var board = makeBoard()
        XCTAssertFalse(board.isColorDone("H7", count: 12))

        board.markColorDone("H7", count: 12)
        XCTAssertTrue(board.isColorDone("H7", count: 12))

        board.clearColorDone("H7")
        XCTAssertFalse(board.isColorDone("H7", count: 12))
        // 清空之后整个字段回到 nil，存盘时不会多带一份空字典
        XCTAssertNil(board.doneColors)
    }

    /// 板上补了三颗 H7，那个勾就得自己掉 —— 不掉的话用户照着勾跳过去，正好漏那三颗。
    func testCountChangeInvalidatesMark() {
        var board = makeBoard()
        board.markColorDone("H7", count: 12)
        XCTAssertFalse(board.isColorDone("H7", count: 15))
        XCTAssertFalse(board.isColorDone("H7", count: 9))
    }

    /// 每块板各记各的：第 1 块板上的 H7 拼完了，不代表第 2 块板上的也拼完了。
    func testMarksArePerBoard() {
        var first = makeBoard()
        var second = makeBoard()
        first.markColorDone("H7", count: 12)
        second.markColorDone("A1", count: 4)

        XCTAssertTrue(first.isColorDone("H7", count: 12))
        XCTAssertFalse(second.isColorDone("H7", count: 12))
    }

    /// 零件被拿下来、色号被擦光之后，标记不能留在数据里 ——
    /// 留着的话零件哪天摆回来、颗数正好对上，那个勾就自己回来了。
    func testPruneDropsColorsNoLongerOnBoard() {
        var board = makeBoard()
        board.markColorDone("H7", count: 12)
        board.markColorDone("A1", count: 4)

        board.pruneDoneColors(keeping: ["A1"])
        XCTAssertFalse(board.isColorDone("H7", count: 12))
        XCTAssertTrue(board.isColorDone("A1", count: 4))

        board.pruneDoneColors(keeping: [])
        XCTAssertNil(board.doneColors)
    }

    // MARK: - 存量图纸

    /// 没有 `doneColors` 这个字段的老板子照样解得出来。
    /// 解不出来的代价是整张图纸打不开 —— 用户几天的活全没了。
    func testDecodesBoardSavedBeforeThisField() throws {
        let json = """
        {
          "id" : "6C6B4A2E-1F1D-4C0E-9F3A-6D2B7E5A1C44",
          "cols" : 29,
          "rows" : 29,
          "placements" : []
        }
        """
        let board = try JSONDecoder().decode(PartsBoard.self, from: Data(json.utf8))
        XCTAssertEqual(board.cols, 29)
        XCTAssertNil(board.doneColors)
        XCTAssertFalse(board.isColorDone("H7", count: 12))
    }

    /// 存了勾的板子，一来一回还是那些勾。
    func testRoundTripsThroughJSON() throws {
        var board = makeBoard()
        board.markColorDone("H7", count: 12)

        let data = try JSONEncoder().encode(board)
        let decoded = try JSONDecoder().decode(PartsBoard.self, from: data)
        XCTAssertEqual(decoded, board)
        XCTAssertTrue(decoded.isColorDone("H7", count: 12))
    }
}
