//
//  PartsBoardRepairTests.swift
//  BeadInventoryTests
//
//  「板上这两个零件挨着没有」这件事**错了没人看得见**：屏幕上是一块摆得整整齐齐的板，
//  错误要等用户把豆子都摆完、熨斗压下去、两块粘成一片才暴露出来。CLAUDE.md 说的
//  「确实会静默出错的纯逻辑」就是指这一类，所以这一份测试值得存在。
//
//  它是补票来的：`offendingPlacements` 上一版按「豆子 × 扩张圈」逐次计数，零件自己
//  相邻的豆子把自己的格子叠到了 2，于是**板上每个多颗豆子的零件都被判成挨着别人**。
//  当时结果没错（`repair` 里还有一道 `canPlace` 复查兜着），所以界面上一切正常，
//  没有任何人会发现 —— 直到有人把那道"多余的"复查删掉。下面第一个用例就是它。
//

import XCTest
@testable import BeadInventory

final class PartsBoardRepairTests: XCTestCase {

    // MARK: - 搭板子

    /// 按一张 `#` / `.` 的图铺一个零件：`#` 是豆子，`.` 是空。
    private func makePart(_ rows: [String]) -> BeadPart {
        let cells = rows.map { row in
            row.map { $0 == "#" ? PartCellFill.code("A1") : PartCellFill.empty }
        }
        return BeadPart(rowBand: 0, bounds: .zero,
                        rows: cells.count, cols: cells.first?.count ?? 0, cells: cells)
    }

    private func makeBoard(
        cols: Int = 20, rows: Int = 20,
        placing: [(part: BeadPart, col: Int, row: Int)]
    ) -> PartsBoard {
        var board = PartsBoard(size: BeadBoardSize(cols: cols, rows: rows))
        board.placements = placing.map {
            PartPlacement(partId: $0.part.id, col: $0.col, row: $0.row)
        }
        return board
    }

    /// 权威判定：给每个摆放单独建一张「别人的占位表」再问 `canPlace` ——
    /// 全 App 的「放得下吗」都走这条（自动排、点零件条落位、拖动校验）。
    /// `offendingPlacements` 只是它的一次扫完版，两者必须永远给同一个答案。
    private func offendersViaCanPlace(
        board: PartsBoard, parts: [BeadPart], spacing: BoardSpacing
    ) -> Set<UUID> {
        var result: Set<UUID> = []
        for placement in board.placements {
            guard let part = parts.first(where: { $0.id == placement.partId }) else { continue }
            let occupancy = PartsBoardPacker.occupancy(of: board, parts: parts,
                                                       spacing: spacing, ignoring: placement.id)
            if !occupancy.canPlace(part.footprint(turns: placement.turns),
                                   col: placement.col, row: placement.row) {
                result.insert(placement.id)
            }
        }
        return result
    }

    // MARK: - 一个零件独自在板上

    /// **这一版曾经全军覆没。** 一个 3×3 的实心零件，孤零零摆在空板正中，
    /// 谁都没挨着 —— 上一版把它的 9 个格子全判成「挨着别人」（自己的豆子互相盖）。
    func testSolidPartAloneIsNotAnOffender() {
        let part = makePart(["###",
                             "###",
                             "###"])
        let board = makeBoard(placing: [(part, 5, 5)])
        for spacing in BoardSpacing.allCases {
            XCTAssertTrue(
                PartsBoardRepair.offendingPlacements(in: board, parts: [part], spacing: spacing).isEmpty,
                "\(spacing) 下，一个零件独自在板上不该被判成挨着别人"
            )
        }
    }

    // MARK: - 两个零件之间隔多少

    func testOneEmptyCellApartIsLegalUnderTightSpacing() {
        // 紧凑档要求「至少空一格」：A 占 0…2 列，B 从第 4 列起 —— 中间空着第 3 列
        let a = makePart(["##", "##"])
        let b = makePart(["##", "##"])
        let board = makeBoard(placing: [(a, 2, 2), (b, 5, 2)])
        XCTAssertTrue(
            PartsBoardRepair.offendingPlacements(in: board, parts: [a, b], spacing: .tight).isEmpty
        )
    }

    func testAdjacentPartsAreBothFlagged() {
        // 贴着放：烫完连成一片，那一刀下去边缘就毁了 —— 两块都得报出来
        let a = makePart(["##", "##"])
        let b = makePart(["##", "##"])
        let board = makeBoard(placing: [(a, 2, 2), (b, 4, 2)])
        let flagged = PartsBoardRepair.offendingPlacements(in: board, parts: [a, b], spacing: .tight)
        XCTAssertEqual(flagged.count, 2)
    }

    func testDiagonalTouchIsFlagged() {
        // 斜角的两颗豆子在拼豆板上是碰得到的（见 BeadPartsBoard 文件头）
        let a = makePart(["#"])
        let b = makePart(["#"])
        let board = makeBoard(placing: [(a, 3, 3), (b, 4, 4)])
        XCTAssertEqual(
            PartsBoardRepair.offendingPlacements(in: board, parts: [a, b], spacing: .tight).count, 2
        )
    }

    func testLooseSpacingNeedsTwoEmptyCells() {
        let a = makePart(["#"])
        let b = makePart(["#"])
        // 中间只空一格：紧凑档合法，宽松档不合法
        let tightOK = makeBoard(placing: [(a, 3, 3), (b, 5, 3)])
        XCTAssertTrue(
            PartsBoardRepair.offendingPlacements(in: tightOK, parts: [a, b], spacing: .tight).isEmpty
        )
        XCTAssertEqual(
            PartsBoardRepair.offendingPlacements(in: tightOK, parts: [a, b], spacing: .loose).count, 2
        )
        // 空两格：宽松档也合法
        let looseOK = makeBoard(placing: [(a, 3, 3), (b, 6, 3)])
        XCTAssertTrue(
            PartsBoardRepair.offendingPlacements(in: looseOK, parts: [a, b], spacing: .loose).isEmpty
        )
    }

    // MARK: - 板边

    func testMarginIsRespected() {
        let part = makePart(["#"])
        let board = makeBoard(placing: [(part, 0, 0)])
        // 紧凑档板边用满 —— 贴边合法
        XCTAssertTrue(
            PartsBoardRepair.offendingPlacements(in: board, parts: [part], spacing: .tight).isEmpty
        )
        // 默认档最外面一圈留空 —— 同一个位置就站不住了
        XCTAssertEqual(
            PartsBoardRepair.offendingPlacements(in: board, parts: [part], spacing: .standard).count, 1
        )
    }

    func testPlacementOutsideTheBoardIsFlagged() {
        let part = makePart(["##", "##"])
        let board = makeBoard(placing: [(part, -3, 5)])
        XCTAssertEqual(
            PartsBoardRepair.offendingPlacements(in: board, parts: [part], spacing: .tight).count, 1
        )
    }

    // MARK: - 跟权威判定对拍

    /// 一次扫完的那版跟「逐个建占位表」必须给出**完全一样**的答案。
    /// 上一版的 bug 就是从「看着等价」溜进来的，所以这里拿随机板子硬碰一遍。
    func testMatchesCanPlaceOnRandomBoards() {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next(_ bound: Int) -> Int {                 // 固定种子的小 LCG，跑起来每次一样
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(max(bound, 1)))
        }

        for _ in 0..<400 {
            let cols = 6 + next(9)
            let rows = 6 + next(9)
            let spacing = BoardSpacing.allCases[next(BoardSpacing.allCases.count)]
            var parts: [BeadPart] = []
            var placing: [(part: BeadPart, col: Int, row: Int)] = []
            for _ in 0..<(1 + next(4)) {
                let w = 1 + next(4)
                let h = 1 + next(4)
                var shape = (0..<h).map { _ in String(repeating: "#", count: w) }
                // 挖几个洞，凑出不规则形状（真实零件几乎都是不规则的）
                if next(2) == 0, h > 1, w > 1 {
                    var row = Array(shape[next(h)])
                    row[next(w)] = "."
                    shape[0] = String(row)
                }
                let part = makePart(shape)
                guard !part.footprint(turns: 0).isEmpty else { continue }
                parts.append(part)
                placing.append((part, next(cols) - 1, next(rows) - 1))   // 故意允许伸到板外
            }
            guard !parts.isEmpty else { continue }
            let board = makeBoard(cols: cols, rows: rows, placing: placing)

            XCTAssertEqual(
                PartsBoardRepair.offendingPlacements(in: board, parts: parts, spacing: spacing),
                offendersViaCanPlace(board: board, parts: parts, spacing: spacing),
                "板 \(cols)×\(rows) / \(spacing) 上两套判定给出了不同答案"
            )
        }
    }

    // MARK: - 修

    func testRepairMovesTheCollidingPartAndReportsIt() {
        let a = makePart(["##", "##"])
        let b = makePart(["##", "##"])
        var boards = [makeBoard(placing: [(a, 2, 2), (b, 4, 2)])]     // 贴着
        let outcome = PartsBoardRepair.repair(boards: &boards, parts: [a, b], spacing: .tight)

        XCTAssertEqual(outcome.moved.count, 1, "挪一个就够了，两个都挪是白动用户的东西")
        XCTAssertTrue(outcome.removed.isEmpty)
        XCTAssertTrue(
            PartsBoardRepair.offendingPlacements(in: boards[0], parts: [a, b], spacing: .tight).isEmpty,
            "修完之后不该还有站不住的"
        )
    }

    func testRepairLeavesTheUnfixableInPlaceInsteadOfRemovingIt() {
        // 挪到哪儿都挨着 —— 这时候**不能**悄悄拿下来：用户刚补完一格，零件就从板上
        // 消失了。留在原地，由界面标出来。
        //
        // 板宽必须是 6：两块 3 宽的零件中间还要空一格，分得开得有 7 列。
        //（第一版这里写的 7，于是 repair 真把 B 挪开了，测试当场把作者按住 —— 留个记号。）
        let a = makePart(["###", "###", "###"])
        let b = makePart(["###", "###", "###"])
        var boards = [makeBoard(cols: 6, rows: 3, placing: [(a, 0, 0), (b, 3, 0)])]
        let outcome = PartsBoardRepair.repair(boards: &boards, parts: [a, b], spacing: .tight)

        XCTAssertTrue(outcome.moved.isEmpty)
        XCTAssertEqual(boards[0].placements.count, 2, "挪不动也得留在板上")
        XCTAssertFalse(
            PartsBoardRepair.offendingPlacements(in: boards[0], parts: [a, b], spacing: .tight).isEmpty,
            "留下来的那些必须还报得出来 —— 界面靠它描红边、拦「完成」"
        )
    }

    func testRepairTakesOffEmptyAndOrphanPlacements() {
        let alive = makePart(["##", "##"])
        let erased = makePart(["..", ".."])                 // 用户把它擦光了
        let gone = makePart(["##"])                         // 零件本身已经不在图纸上
        var boards = [makeBoard(placing: [(alive, 2, 2), (erased, 8, 2), (gone, 14, 2)])]

        let outcome = PartsBoardRepair.repair(boards: &boards, parts: [alive, erased], spacing: .tight)

        XCTAssertEqual(outcome.removed, [erased.id], "一颗豆子都不剩的要拿下来")
        XCTAssertEqual(outcome.orphaned, [gone.id], "对不上零件的也要清掉，但说法不一样")
        XCTAssertEqual(boards[0].placements.count, 1)
        XCTAssertEqual(boards[0].placements.first?.partId, alive.id)
    }

    func testRepairIsIdempotent() {
        // 进这一屏每次都会跑一遍，跑第二遍不该再动任何东西 ——
        // 否则用户每进一次板子就自己挪一次位。
        let a = makePart(["##", "##"])
        let b = makePart(["##", "##"])
        var boards = [makeBoard(placing: [(a, 2, 2), (b, 4, 2)])]
        PartsBoardRepair.repair(boards: &boards, parts: [a, b], spacing: .tight)
        let settled = boards
        let second = PartsBoardRepair.repair(boards: &boards, parts: [a, b], spacing: .tight)

        XCTAssertTrue(second.isEmpty, "第二遍不该再报改动")
        XCTAssertEqual(boards, settled, "第二遍不该再动板子")
    }

    // MARK: - 老图纸打得开

    /// 没有 `isConnector` / `gridConfirmed` 的存量零件照样解得出来。
    ///
    /// 这一条**在模拟器里走一遍永远抓不到**：开发自己造的图纸一定带这两个字段，
    /// 只有用户库里的老图纸会撞上。而它塌下来的样子是整张图纸打不开
    /// （`decodePartsSheet` 把解码错误 catch 掉、返回 nil），用户丢的是几天的活。
    ///
    /// 守的是下一个来「清理」这两个三态字段的人：把 `Bool?` 改成 `Bool = false`
    /// 看着更干净，但合成的解码器不认属性默认值，缺字段照样抛。
    func testDecodesPartSavedBeforeConnectorFlag() throws {
        let json = """
        {
          "id" : "3F2A9C10-5B7E-4D21-8A66-1C0E4B9D7F35",
          "rowBand" : 0,
          "bounds" : [[0, 0], [0.2, 0.3]],
          "rows" : 0,
          "cols" : 0,
          "cells" : []
        }
        """
        let part = try JSONDecoder().decode(BeadPart.self, from: Data(json.utf8))
        XCTAssertNil(part.isConnector)
        XCTAssertNil(part.gridConfirmed)
        XCTAssertFalse(part.isConnectorPart)
        XCTAssertFalse(part.isGridConfirmed)
    }
}
