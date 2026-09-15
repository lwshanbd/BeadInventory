//
//  PartsBoardCopiesTests.swift
//  BeadInventoryTests
//
//  拼豆板上「复制」「镜像」出来的那几份，错了用户看不出来：重排之后板子照样整整齐齐，
//  只是右耳变回了左耳、多拼的那一份悄悄没了。等他发现，豆子已经烫上去了。
//

import XCTest
@testable import BeadInventory

final class PartsBoardCopiesTests: XCTestCase {

    /// 一个 L 形零件：
    ///
    ///     A1 .
    ///     A1 H7
    private func makeLPart() -> BeadPart {
        BeadPart(rowBand: 0, bounds: .zero, rows: 2, cols: 2,
                 cells: [[.code("A1"), .empty], [.code("A1"), .code("H7")]])
    }

    private func beads(_ footprint: PartFootprint) -> Set<String> {
        Set(footprint.beads.map { "\($0.col),\($0.row),\($0.key)" })
    }

    /// 镜像是左右翻：H7 从右下角跑到左下角，A1 那一竖跑到右边。
    func testMirroredFootprintFlipsLeftRight() {
        let part = makeLPart()
        XCTAssertEqual(beads(part.footprint(turns: 0, mirrored: true)),
                       ["1,0,A1", "1,1,A1", "0,1,H7"])
        let placement = PartPlacement(partId: part.id, col: 0, row: 0, mirrored: true)
        XCTAssertEqual(beads(part.footprint(for: placement)), beads(part.footprint(turns: 0, mirrored: true)))
    }

    /// 重排要保留板上的份数和镜像：一份原样、一份镜像，排完还是一份原样、一份镜像。
    /// 板上一份都没摆的零件照样排一份。
    func testRepackKeepsCopiesAndMirrors() {
        let copied = makeLPart()
        let takenOff = makeLPart()
        let parts = [copied, takenOff]
        let before = [PartsBoard(size: BeadBoardSize(cols: 20, rows: 20), placements: [
            PartPlacement(partId: copied.id, col: 1, row: 1),
            PartPlacement(partId: copied.id, col: 6, row: 1, turns: 3, mirrored: true)
        ])]

        for layout in BoardLayout.allCases {
            let result = PartsBoardPacker.pack(
                pieces: PartsBoardPacker.Piece.keeping(parts, from: before),
                size: BeadBoardSize(cols: 10, rows: 10), spacing: .standard, layout: layout)
            let placements = result.boards.flatMap(\.placements)
            XCTAssertTrue(result.unplaced.isEmpty, "\(layout)")
            XCTAssertEqual(placements.filter { $0.partId == copied.id }.map(\.isMirrored).sorted { !$0 && $1 },
                           [false, true], "\(layout)")
            XCTAssertEqual(placements.filter { $0.partId == takenOff.id }.count, 1, "\(layout)")
            XCTAssertTrue(PartsBoardRepair.offendingPlacements(in: result.boards, parts: parts,
                                                               spacing: .standard).isEmpty, "\(layout)")
        }
    }

    /// 老图纸的摆放 JSON 里没有镜像字段，照样解得出来，而且算没翻。
    func testLegacyPlacementWithoutMirrorFieldDecodes() throws {
        let json = #"{"id":"\#(UUID().uuidString)","partId":"\#(UUID().uuidString)","col":2,"row":3,"turns":1}"#
        let placement = try JSONDecoder().decode(PartPlacement.self, from: Data(json.utf8))
        XCTAssertFalse(placement.isMirrored)
        XCTAssertEqual(placement.turns, 1)
    }
}
