//
//  PartsBoardNumberedLayoutTests.swift
//  BeadInventoryTests
//
//  「按零件编号」这一档排出来的板，错了也是一块摆得整整齐齐的板 —— 用户唯一能察觉的
//  症状是板子比该用的多一块，而他没法知道少一块是不是本来就做得到。所以这里钉的是
//  五条会静默漂移的规矩：竖过来才进得去的零件不许把整块板推走、原方向放得下就不许转、
//  板上的空隙要回填、一块板装的必须是连着的一段号、以及比板子还大的零件只进 unplaced
//  不许开出空板来。
//
//  最后那一条是补票来的：这一档改成「逐个往缝里塞」的那一版把「开板」写在了「问放不放
//  得下」之前，于是每个超尺寸零件白开一块板留在结果里，还会把当前这块只装了几个零件的
//  板提前作废。而那条路只有把板子设小了才走得到，模拟器里走正常流程永远撞不上。
//

import XCTest
@testable import BeadInventory

final class PartsBoardNumberedLayoutTests: XCTestCase {

    /// 造一个 cols × rows、每一格都是豆子的实心零件。
    ///
    /// 用实心是为了算例好手推：`firstFit` 按包围盒扫、`canPlace` 按豆子判，
    /// 实心件让这两者等价，摆位可以拿纸笔算出来。
    private func makePart(cols: Int, rows: Int) -> BeadPart {
        let cells = Array(repeating: Array(repeating: PartCellFill.code("A1"), count: cols), count: rows)
        return BeadPart(rowBand: 0, bounds: .zero, rows: rows, cols: cols, cells: cells)
    }

    /// 板上任意两个零件的豆子之间都还隔着 `spacing.gap` 格，没有谁压在留边上。
    ///
    /// 判定借的是全 App 那一处（`PartsBoardRepair.offendingPlacements`，它跟
    /// `BoardOccupancy.canPlace` 等价）。挂在几条用例后面而不是单开一条：这一档
    /// 是贴着左上角排完再整体 `recenter` 推到中间的，推的距离比省板那一档大，
    /// 而 margin 算错的症状要等用户拿熨斗烫到那一格才发现。
    private func assertBoardsAreLegal(
        _ boards: [PartsBoard], parts: [BeadPart], spacing: BoardSpacing,
        line: UInt = #line
    ) {
        let offenders = PartsBoardRepair.offendingPlacements(in: boards, parts: parts, spacing: spacing)
        XCTAssertTrue(offenders.isEmpty, "有 \(offenders.count) 个零件贴在一起或压到了留边",
                      file: #filePath, line: line)
    }

    /// 20 × 20 的板，先排一条 18 宽 4 高的横条，再排一条 4 宽 18 高的竖条。
    /// 竖条原方向摆不进横条剩下的地方；竖过来就是 18 × 4，跟横条同一块板还剩一大半。
    /// 早先它会直接另起一块板，把自己和后面所有零件一起搬过去。
    func testTallPartTurnsInsteadOfOpeningANewBoard() {
        let wide = makePart(cols: 18, rows: 4)
        let tall = makePart(cols: 4, rows: 18)
        let parts = [wide, tall]
        let result = PartsBoardPacker.pack(pieces: PartsBoardPacker.Piece.one(each: parts),
                                           size: BeadBoardSize(cols: 20, rows: 20),
                                           spacing: .tight, layout: .numbered)
        XCTAssertEqual(result.boards.count, 1)
        XCTAssertTrue(result.unplaced.isEmpty)
        let turns = result.boards[0].placements.first { $0.partId == tall.id }?.turns
        XCTAssertEqual(turns, 1)
        assertBoardsAreLegal(result.boards, parts: parts, spacing: .tight)
    }

    /// 原方向放得下就不转 —— 板上的零件跟图纸上看到的一个朝向，用户才认得出。
    ///
    /// 用 6 宽 10 高的长方形，两个朝向在空板上都放得下，所以这里问的确实是
    /// 「原方向优先」，不是「只有一个朝向能进」。
    func testPartsKeepTheirOrientationWhenItFits() {
        let parts = (0..<4).map { _ in makePart(cols: 6, rows: 10) }
        let result = PartsBoardPacker.pack(pieces: PartsBoardPacker.Piece.one(each: parts),
                                           size: BeadBoardSize(cols: 30, rows: 30),
                                           spacing: .tight, layout: .numbered)
        XCTAssertEqual(result.boards.count, 1)
        XCTAssertTrue(result.boards[0].placements.allSatisfy { $0.turns == 0 })
    }

    /// 当前这块板上还有缝就塞进去，别急着开新板。
    ///
    /// 20 × 20 紧凑档（留边 0、间隔 1）：4 × 4 的小件落在 (0, 0)，15 × 18 的大件
    /// 只能贴在它右边、从第 5 列排到第 19 列。于是小件底下空出 4 列 × 15 行那一条。
    /// 第三个 3 × 3 的零件放不进大件右边（没有了），也放不进大件底下（只剩两行），
    /// 但那一条竖缝装得下它 —— 扫描顺序上它比板子右下角更靠前。
    ///
    /// 这一条是这次改动的核心防线：一行一行摆的旧算法在这个算例上会开第 2 块板
    /// （行高被 18 高的大件顶满，下一行放不下 3 高的零件），改成挑「离板心最近」
    /// 的 `.center` 扫法会开第 3 块板。
    func testFillsAGapInsteadOfOpeningANewBoard() {
        let corner = makePart(cols: 4, rows: 4)
        let tall = makePart(cols: 15, rows: 18)
        let small = makePart(cols: 3, rows: 3)
        let parts = [corner, tall, small]
        let result = PartsBoardPacker.pack(pieces: PartsBoardPacker.Piece.one(each: parts),
                                           size: BeadBoardSize(cols: 20, rows: 20),
                                           spacing: .tight, layout: .numbered)
        XCTAssertEqual(result.boards.count, 1)
        XCTAssertEqual(result.boards.first?.placements.count, 3)
        assertBoardsAreLegal(result.boards, parts: parts, spacing: .tight)
    }

    /// **一块板装的是连着的一段号。** 板内不要求一行行数下来（回填空隙会插队），
    /// 但前一块板上的号必须全都比后一块板上的小 —— 用户翻到第几块板就知道该找第几十号。
    ///
    /// 算例是照着「回头填前面的板」这一种错法造的：1 号小件占住左上角，2 号大件占满
    /// 剩下的地方，3 号整块板都放不下（另起一块），4 号只装得进第 1 块板剩下的那条缝。
    /// 只问最后一块板排出来是 [[1, 2], [3], [4]]；改成逐块板试过去就是 [[1, 2, 4], [3]]，
    /// 第 1 块板上的 4 号比第 2 块板上的 3 号大，下面那圈断言当场报。
    ///
    /// 这一批里没有插件：插件是单独一组排的，板接在普通件后面，跨到那一段号会往回跳
    /// （见 `PartsBoardPacker.numberedPack` 的文档）。这条不变量只在同一组之内成立。
    func testEachBoardHoldsOneRunOfNumbers() {
        let parts = [makePart(cols: 4, rows: 4), makePart(cols: 15, rows: 18),
                     makePart(cols: 19, rows: 19), makePart(cols: 3, rows: 3)]
        let order = Dictionary(uniqueKeysWithValues: parts.enumerated().map { ($1.id, $0) })
        let result = PartsBoardPacker.pack(pieces: PartsBoardPacker.Piece.one(each: parts),
                                           size: BeadBoardSize(cols: 20, rows: 20),
                                           spacing: .tight, layout: .numbered)

        let perBoard = result.boards.map { $0.placements.compactMap { order[$0.partId] } }
        XCTAssertEqual(perBoard.flatMap { $0 }.count, parts.count)
        // 算例本身要真的排到第二块板，否则下面那圈 zip 是空转
        XCTAssertGreaterThan(perBoard.count, 1)
        XCTAssertFalse(perBoard.contains(where: \.isEmpty), "自动排不该产出空板")
        // 不用 `?? -1` / `?? Int.max` 兜底：空板那样会恒过，而空板正是要挡的东西之一
        for (earlier, later) in zip(perBoard, perBoard.dropFirst()) {
            guard let last = earlier.max(), let first = later.min() else { continue }
            XCTAssertLessThan(last, first)
        }
        assertBoardsAreLegal(result.boards, parts: parts, spacing: .tight)
    }

    /// 比板子还大的零件只进 `unplaced`，不许为它开一块板出来。
    ///
    /// `unplaced` 是唯一告诉用户「这个零件没摆下」的渠道，界面上对着它说
    /// 「有 N 个零件超出板子尺寸，请更换更大的板子」。为它开出来的空板有三重代价：
    /// 用户翻出几块什么都没有的白板、板数报多、以及当前这块只装了几个零件的板被提前
    /// 作废（后面的零件只往最后一块板上塞，那块空板一挤进来，前一块剩下的地方就没人用了）。
    ///
    /// 还有一重更隐的：`PartsBoardStepView.autoPackIfNeeded` 靠「一块板都没排出来」
    /// 判断「还没排过」来决定间距档要不要落定，全是空板会把那道保护骗过去，
    /// 用户在菜单里换间距会变成点了没反应。
    func testAnOversizedPartGoesUnplacedWithoutOpeningABoard() {
        let big = makePart(cols: 40, rows: 40)
        let parts = [makePart(cols: 5, rows: 5), big,
                     makePart(cols: 5, rows: 5), makePart(cols: 5, rows: 5)]
        let result = PartsBoardPacker.pack(pieces: PartsBoardPacker.Piece.one(each: parts),
                                           size: BeadBoardSize(cols: 20, rows: 20),
                                           spacing: .tight, layout: .numbered)
        XCTAssertEqual(result.unplaced, [big.id])
        XCTAssertEqual(result.boards.count, 1, "放不下的那一个不该把当前这块板作废")
        XCTAssertTrue(result.boards.allSatisfy { !$0.placements.isEmpty }, "不该留下空板")
        XCTAssertEqual(result.boards.first?.placements.count, 3)
    }

    /// 全部零件都比板子大时，一块板都不该排出来。
    /// 界面靠「排出来的板是空数组」认定「还没排过」，那一档才不会被落定。
    func testAllPartsOversizedYieldsNoBoards() {
        let parts = (0..<3).map { _ in makePart(cols: 40, rows: 40) }
        let result = PartsBoardPacker.pack(pieces: PartsBoardPacker.Piece.one(each: parts),
                                           size: BeadBoardSize(cols: 20, rows: 20),
                                           spacing: .tight, layout: .numbered)
        XCTAssertTrue(result.boards.isEmpty)
        XCTAssertEqual(result.unplaced.count, 3)
    }
}
