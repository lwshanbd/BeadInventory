//
//  PartsBoardNumberedLayoutTests.swift
//  BeadInventoryTests
//
//  「按零件编号」这一档排出来的板，错了也是一块摆得整整齐齐的板 —— 用户唯一能察觉的
//  症状是板子比该用的多一块，而他没法知道少一块是不是本来就做得到。所以这里钉的是
//  三条会静默漂移的规矩：竖过来才进得去的零件不许把整块板推走、板上的空隙要回填、
//  以及一块板装的必须是连着的一段号。
//

import XCTest
@testable import BeadInventory

final class PartsBoardNumberedLayoutTests: XCTestCase {

    /// 按一张 `#` / `.` 的图铺一个零件：`#` 是豆子，`.` 是空。
    private func makePart(cols: Int, rows: Int) -> BeadPart {
        let cells = Array(repeating: Array(repeating: PartCellFill.code("A1"), count: cols), count: rows)
        return BeadPart(rowBand: 0, bounds: .zero, rows: rows, cols: cols, cells: cells)
    }

    /// 20 × 20 的板，先排一条 18 宽 4 高的横条，再排一条 4 宽 18 高的竖条。
    /// 竖条原方向要 18 行，第二行起摆不下；竖过来就是 18 × 4，跟横条同一块板还剩一大半。
    /// 早先它会直接另起一块板，把自己和后面所有零件一起搬过去。
    func testTallPartTurnsInsteadOfOpeningANewBoard() {
        let wide = makePart(cols: 18, rows: 4)
        let tall = makePart(cols: 4, rows: 18)
        let result = PartsBoardPacker.pack(parts: [wide, tall],
                                           size: BeadBoardSize(cols: 20, rows: 20),
                                           spacing: .tight, layout: .numbered)
        XCTAssertEqual(result.boards.count, 1)
        XCTAssertTrue(result.unplaced.isEmpty)
        let turns = result.boards[0].placements.first { $0.partId == tall.id }?.turns
        XCTAssertEqual(turns, 1)
    }

    /// 原方向放得下就不转 —— 板上的零件跟图纸上看到的一个朝向，用户才认得出。
    func testPartsKeepTheirOrientationWhenItFits() {
        let parts = (0..<4).map { _ in makePart(cols: 6, rows: 6) }
        let result = PartsBoardPacker.pack(parts: parts,
                                           size: BeadBoardSize(cols: 20, rows: 20),
                                           spacing: .tight, layout: .numbered)
        XCTAssertEqual(result.boards.count, 1)
        XCTAssertTrue(result.boards[0].placements.allSatisfy { $0.turns == 0 })
    }

    /// 行尾放不下时先回填这块板上方的空隙，别急着开新板。
    ///
    /// 4 × 4 的小件占住左上角，紧接着一个 15 × 18 的大件贴着它右边站满整块板：
    /// 小件底下那一块 4 × 13 的地方就空在那儿了。第三个 3 × 3 的零件行尾放不下、
    /// 另起一行也放不下（大件已经顶到板底），但那个空隙装得下它。
    func testFillsAGapInsteadOfOpeningANewBoard() {
        let corner = makePart(cols: 4, rows: 4)
        let tall = makePart(cols: 15, rows: 18)
        let small = makePart(cols: 3, rows: 3)
        let result = PartsBoardPacker.pack(parts: [corner, tall, small],
                                           size: BeadBoardSize(cols: 20, rows: 20),
                                           spacing: .tight, layout: .numbered)
        XCTAssertEqual(result.boards.count, 1)
        XCTAssertEqual(result.boards.first?.placements.count, 3)
    }

    /// **一块板装的是连着的一段号。** 板内不要求一行行数下来（回填空隙会插队），
    /// 但前一块板上的号必须全都比后一块板上的小 —— 用户翻到第几块板就知道该找第几十号。
    func testEachBoardHoldsOneRunOfNumbers() {
        let parts = (0..<12).map { index in
            makePart(cols: index.isMultiple(of: 3) ? 5 : 14, rows: index.isMultiple(of: 3) ? 14 : 5)
        }
        let order = Dictionary(uniqueKeysWithValues: parts.enumerated().map { ($1.id, $0) })
        let result = PartsBoardPacker.pack(parts: parts,
                                           size: BeadBoardSize(cols: 30, rows: 30),
                                           spacing: .standard, layout: .numbered)
        let perBoard = result.boards.map { $0.placements.compactMap { order[$0.partId] } }
        XCTAssertEqual(perBoard.flatMap { $0 }.count, parts.count)
        for (earlier, later) in zip(perBoard, perBoard.dropFirst()) {
            XCTAssertLessThan(earlier.max() ?? -1, later.min() ?? Int.max)
        }
    }
}
