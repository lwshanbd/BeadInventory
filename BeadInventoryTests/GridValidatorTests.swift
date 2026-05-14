import XCTest
@testable import BeadInventory

final class GridValidatorTests: XCTestCase {
    private func grid(cells: [[String?]]) -> BeadPatternGrid {
        BeadPatternGrid(
            corners: GridCorners(
                topLeft: CGPoint(x: 0, y: 0),
                topRight: CGPoint(x: 1, y: 0),
                bottomLeft: CGPoint(x: 0, y: 1),
                bottomRight: CGPoint(x: 1, y: 1)
            ),
            rows: cells.count,
            cols: cells.first?.count ?? 0,
            cellColorCodes: cells,
            lastCalibratedAt: Date(),
            sourceImageSize: CGSize(width: 100, height: 100),
            colorSystem: .mard
        )
    }

    private func usage(_ pairs: [(String, Int)]) -> [BeadUsage] {
        pairs.map { BeadUsage(colorCode: $0.0, quantity: $0.1) }
    }

    func testAllMatch() {
        let g = grid(cells: [["A", "A", "B"], ["A", "B", nil]])
        let u = usage([("A", 3), ("B", 2)])
        XCTAssertEqual(GridValidator.mismatches(grid: g, beadUsage: u), [])
    }

    func testMissingCodeInLegend() {
        let g = grid(cells: [["A", "C"]])
        let u = usage([("A", 1)])
        let diff = GridValidator.mismatches(grid: g, beadUsage: u)
        XCTAssertEqual(diff.count, 1)
        XCTAssertEqual(diff.first?.code, "C")
        XCTAssertEqual(diff.first?.gridCount, 1)
        XCTAssertEqual(diff.first?.legendCount, 0)
    }

    func testCountMismatch() {
        let g = grid(cells: [["A", "A", "A"]])
        let u = usage([("A", 5)])
        let diff = GridValidator.mismatches(grid: g, beadUsage: u)
        XCTAssertEqual(diff.count, 1)
        XCTAssertEqual(diff.first?.gridCount, 3)
        XCTAssertEqual(diff.first?.legendCount, 5)
    }

    func testNilCellsExcluded() {
        let g = grid(cells: [[nil, nil, "A"]])
        let u = usage([("A", 1)])
        XCTAssertEqual(GridValidator.mismatches(grid: g, beadUsage: u), [])
    }

    func testSortedByAbsDelta() {
        let g = grid(cells: [["A", "B", "C", "C", "C"]])
        let u = usage([("A", 0), ("B", 0), ("C", 10)])  // C delta=-7, A delta=1, B delta=1
        let diff = GridValidator.mismatches(grid: g, beadUsage: u)
        XCTAssertEqual(diff.first?.code, "C", "应按 |delta| 降序")
    }
}
