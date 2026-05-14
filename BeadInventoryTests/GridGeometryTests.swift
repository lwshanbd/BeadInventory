import XCTest
@testable import BeadInventory

final class GridGeometryTests: XCTestCase {
    private let displayRect = CGRect(x: 0, y: 0, width: 100, height: 100)

    private func rectCorners() -> GridCorners {
        GridCorners(
            topLeft: CGPoint(x: 0, y: 0),
            topRight: CGPoint(x: 1, y: 0),
            bottomLeft: CGPoint(x: 0, y: 1),
            bottomRight: CGPoint(x: 1, y: 1)
        )
    }

    func testBilinearAtCorners() {
        let c = rectCorners()
        XCTAssertEqual(GridGeometry.bilinear(u: 0, v: 0, corners: c, in: displayRect),
                       CGPoint(x: 0, y: 0))
        XCTAssertEqual(GridGeometry.bilinear(u: 1, v: 0, corners: c, in: displayRect),
                       CGPoint(x: 100, y: 0))
        XCTAssertEqual(GridGeometry.bilinear(u: 1, v: 1, corners: c, in: displayRect),
                       CGPoint(x: 100, y: 100))
        XCTAssertEqual(GridGeometry.bilinear(u: 0.5, v: 0.5, corners: c, in: displayRect),
                       CGPoint(x: 50, y: 50))
    }

    func testCellQuadUniformGrid() {
        let c = rectCorners()
        let (tl, tr, br, bl) = GridGeometry.cellQuad(row: 0, col: 0, rows: 10, cols: 10,
                                                     corners: c, in: displayRect)
        XCTAssertEqual(tl, CGPoint(x: 0, y: 0))
        XCTAssertEqual(tr, CGPoint(x: 10, y: 0))
        XCTAssertEqual(br, CGPoint(x: 10, y: 10))
        XCTAssertEqual(bl, CGPoint(x: 0, y: 10))
    }

    func testCellQuadCenterCell() {
        let c = rectCorners()
        let (tl, _, br, _) = GridGeometry.cellQuad(row: 5, col: 5, rows: 10, cols: 10,
                                                   corners: c, in: displayRect)
        XCTAssertEqual(tl, CGPoint(x: 50, y: 50))
        XCTAssertEqual(br, CGPoint(x: 60, y: 60))
    }

    func testNormalizeAndDenormalizeRoundTrip() {
        let p = CGPoint(x: 25, y: 75)
        let normalized = GridGeometry.normalize(p, in: displayRect)
        XCTAssertEqual(normalized.x, 0.25, accuracy: 0.001)
        XCTAssertEqual(normalized.y, 0.75, accuracy: 0.001)
        let denorm = GridGeometry.denormalize(normalized, in: displayRect)
        XCTAssertEqual(denorm.x, p.x, accuracy: 0.001)
        XCTAssertEqual(denorm.y, p.y, accuracy: 0.001)
    }

    func testBilinearTrapezoid() {
        let c = GridCorners(
            topLeft: CGPoint(x: 0.25, y: 0),
            topRight: CGPoint(x: 0.75, y: 0),
            bottomLeft: CGPoint(x: 0, y: 1),
            bottomRight: CGPoint(x: 1, y: 1)
        )
        let center = GridGeometry.bilinear(u: 0.5, v: 0.5, corners: c, in: displayRect)
        XCTAssertEqual(center.x, 50, accuracy: 0.001)
        XCTAssertEqual(center.y, 50, accuracy: 0.001)
    }
}
