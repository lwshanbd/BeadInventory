import XCTest
@testable import BeadInventory

/// OCR 后文字归一化 + bounding-box → cell 反映射的回归测试。
/// 这些是纯函数，一个 off-by-one 或全角标点遗漏就能让识别系统系统性误判。
final class GridOCRMappingTests: XCTestCase {

    private let legend: Set<String> = ["A4", "M24", "H2", "E15"]

    // MARK: - matchLegendCode

    func testMatch_exact() {
        XCTAssertEqual(GridOCRSampler.matchLegendCode(text: "A4", allowed: legend), "A4")
    }

    func testMatch_caseInsensitive() {
        XCTAssertEqual(GridOCRSampler.matchLegendCode(text: "a4", allowed: legend), "A4")
        XCTAssertEqual(GridOCRSampler.matchLegendCode(text: "m24", allowed: legend), "M24")
    }

    func testMatch_stripsWhitespace() {
        XCTAssertEqual(GridOCRSampler.matchLegendCode(text: " A4 ", allowed: legend), "A4")
        XCTAssertEqual(GridOCRSampler.matchLegendCode(text: "M 24", allowed: legend), "M24")
    }

    func testMatch_stripsPunctuation() {
        XCTAssertEqual(GridOCRSampler.matchLegendCode(text: "A4.", allowed: legend), "A4")
        XCTAssertEqual(GridOCRSampler.matchLegendCode(text: "M24,", allowed: legend), "M24")
    }

    func testMatch_notInLegend() {
        XCTAssertNil(GridOCRSampler.matchLegendCode(text: "Z99", allowed: legend))
        XCTAssertNil(GridOCRSampler.matchLegendCode(text: "A5", allowed: legend))
    }

    func testMatch_emptyAndBlank() {
        XCTAssertNil(GridOCRSampler.matchLegendCode(text: "", allowed: legend))
        XCTAssertNil(GridOCRSampler.matchLegendCode(text: "   ", allowed: legend))
        XCTAssertNil(GridOCRSampler.matchLegendCode(text: ".,!", allowed: legend))
    }

    func testMatch_emptyAllowed() {
        XCTAssertNil(GridOCRSampler.matchLegendCode(text: "A4", allowed: []))
    }

    // MARK: - cellFor

    private func makeGrid(rows: Int, cols: Int) -> BeadPatternGrid {
        BeadPatternGrid(
            corners: GridCorners(
                topLeft: CGPoint(x: 0, y: 0),
                topRight: CGPoint(x: 1, y: 0),
                bottomLeft: CGPoint(x: 0, y: 1),
                bottomRight: CGPoint(x: 1, y: 1)
            ),
            rows: rows,
            cols: cols,
            cellColorCodes: Array(repeating: Array(repeating: nil, count: cols), count: rows),
            lastCalibratedAt: Date(),
            sourceImageSize: CGSize(width: 100, height: 100),
            colorSystem: .mard
        )
    }

    func testCellFor_topLeft() {
        let grid = makeGrid(rows: 10, cols: 10)
        let size = CGSize(width: 100, height: 100)
        let cell = GridOCRSampler.cellFor(point: CGPoint(x: 5, y: 5), grid: grid, imageSize: size)
        XCTAssertEqual(cell?.row, 0)
        XCTAssertEqual(cell?.col, 0)
    }

    func testCellFor_center() {
        let grid = makeGrid(rows: 10, cols: 10)
        let size = CGSize(width: 100, height: 100)
        let cell = GridOCRSampler.cellFor(point: CGPoint(x: 55, y: 55), grid: grid, imageSize: size)
        XCTAssertEqual(cell?.row, 5)
        XCTAssertEqual(cell?.col, 5)
    }

    func testCellFor_bottomRight() {
        let grid = makeGrid(rows: 10, cols: 10)
        let size = CGSize(width: 100, height: 100)
        let cell = GridOCRSampler.cellFor(point: CGPoint(x: 99, y: 99), grid: grid, imageSize: size)
        XCTAssertEqual(cell?.row, 9)
        XCTAssertEqual(cell?.col, 9)
    }

    func testCellFor_outsideRect_returnsNil() {
        let grid = makeGrid(rows: 10, cols: 10)
        let size = CGSize(width: 100, height: 100)
        XCTAssertNil(GridOCRSampler.cellFor(point: CGPoint(x: -1, y: 50), grid: grid, imageSize: size))
        XCTAssertNil(GridOCRSampler.cellFor(point: CGPoint(x: 50, y: 101), grid: grid, imageSize: size))
        XCTAssertNil(GridOCRSampler.cellFor(point: CGPoint(x: 200, y: 50), grid: grid, imageSize: size))
    }

    func testCellFor_degenerateRect_returnsNil() {
        let degenerate = BeadPatternGrid(
            corners: GridCorners(
                topLeft: CGPoint(x: 0.5, y: 0.5),
                topRight: CGPoint(x: 0.5, y: 0.5),
                bottomLeft: CGPoint(x: 0.5, y: 0.5),
                bottomRight: CGPoint(x: 0.5, y: 0.5)
            ),
            rows: 10, cols: 10,
            cellColorCodes: Array(repeating: Array(repeating: nil, count: 10), count: 10),
            lastCalibratedAt: Date(),
            sourceImageSize: CGSize(width: 100, height: 100),
            colorSystem: .mard
        )
        let size = CGSize(width: 100, height: 100)
        XCTAssertNil(GridOCRSampler.cellFor(point: CGPoint(x: 50, y: 50),
                                            grid: degenerate, imageSize: size))
    }
}
