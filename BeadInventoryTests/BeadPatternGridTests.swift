import XCTest
@testable import BeadInventory

final class BeadPatternGridTests: XCTestCase {

    private func makeSampleGrid() -> BeadPatternGrid {
        BeadPatternGrid(
            corners: GridCorners(
                topLeft: CGPoint(x: 0.1, y: 0.1),
                topRight: CGPoint(x: 0.9, y: 0.1),
                bottomLeft: CGPoint(x: 0.1, y: 0.9),
                bottomRight: CGPoint(x: 0.9, y: 0.9)
            ),
            rows: 3,
            cols: 3,
            cellColorCodes: [
                ["M24", "M01", nil],
                [nil, "M24", "M01"],
                ["M01", nil, "M24"]
            ],
            lastCalibratedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceImageSize: CGSize(width: 1024, height: 1024),
            colorSystem: .mard
        )
    }

    func testCodableRoundTrip() throws {
        let original = makeSampleGrid()
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BeadPatternGrid.self, from: encoded)
        XCTAssertEqual(decoded, original)
    }

    func testCellColorCodesPreservesNils() throws {
        let original = makeSampleGrid()
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BeadPatternGrid.self, from: encoded)
        // 中间 nil 必须保留，不能被压缩
        XCTAssertNil(decoded.cellColorCodes[0][2])
        XCTAssertEqual(decoded.cellColorCodes[1][1], "M24")
    }

    func testCornersAreNormalizedAndPreserved() throws {
        let original = makeSampleGrid()
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BeadPatternGrid.self, from: encoded)
        XCTAssertEqual(decoded.corners.topLeft, CGPoint(x: 0.1, y: 0.1))
        XCTAssertEqual(decoded.corners.bottomRight, CGPoint(x: 0.9, y: 0.9))
    }
}
