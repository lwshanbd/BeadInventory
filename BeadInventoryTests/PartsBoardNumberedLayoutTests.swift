//
//  PartsBoardNumberedLayoutTests.swift
//  BeadInventoryTests
//
//  「按零件编号」这一档排出来的板，错了也是一块摆得整整齐齐的板 —— 用户唯一能察觉的
//  症状是板子比该用的多一块，而他没法知道少一块是不是本来就做得到。所以这里钉的是
//  两条会静默漂移的规矩：竖过来才进得去的零件不许把整块板推走，以及号不许被重排。
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

    /// 号的次序就是传进来的次序：板一块块看下去、板内一行行看下去，编号只增不减。
    /// 这是这一档存在的全部理由，转朝向不许把它打乱。
    func testPlacementsFollowThePartOrder() {
        let parts = (0..<12).map { index in
            makePart(cols: index.isMultiple(of: 3) ? 5 : 14, rows: index.isMultiple(of: 3) ? 14 : 5)
        }
        let order = Dictionary(uniqueKeysWithValues: parts.enumerated().map { ($1.id, $0) })
        let result = PartsBoardPacker.pack(parts: parts,
                                           size: BeadBoardSize(cols: 30, rows: 30),
                                           spacing: .standard, layout: .numbered)
        let sequence = result.boards.flatMap { $0.placements.compactMap { order[$0.partId] } }
        XCTAssertEqual(sequence, sequence.sorted())
        XCTAssertEqual(sequence.count, parts.count)
    }
}
