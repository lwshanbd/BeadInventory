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

    // MARK: - ProjectRecord 集成测试

    func testProjectRecordEncodesPatternGrid() throws {
        let grid = makeSampleGrid()
        let project = ProjectRecord(
            name: "测试项目",
            beadUsage: [],
            colorSystem: .mard,
            patternGrid: grid
        )

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(ProjectRecord.self, from: data)

        XCTAssertEqual(decoded.patternGrid, grid)
    }

    func testProjectRecordDecodesOldDataWithoutPatternGrid() throws {
        // 模拟旧数据：不含 patternGrid 字段的 JSON
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "name": "旧项目",
            "date": 700000000,
            "beadUsage": [],
            "totalBeads": 0,
            "isArchived": false,
            "isPlanned": false,
            "colorSystem": "MARD"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ProjectRecord.self, from: json)
        XCTAssertNil(decoded.patternGrid)
    }

    // MARK: - SwiftData 转换测试

    func testSDProjectRecordRoundTrip() throws {
        let grid = makeSampleGrid()
        let project = ProjectRecord(
            name: "SD 测试",
            beadUsage: [],
            colorSystem: .mard,
            patternGrid: grid
        )

        let sd = SDProjectRecord(from: project)
        XCTAssertNotNil(sd.patternGridData, "patternGridData 应被编码")

        let restored = sd.toStruct()
        XCTAssertEqual(restored.patternGrid, grid, "round-trip 应保持网格不变")
    }

    func testSDProjectRecordWithNilPatternGrid() {
        let project = ProjectRecord(name: "无网格项目")
        let sd = SDProjectRecord(from: project)
        XCTAssertNil(sd.patternGridData)
        XCTAssertNil(sd.toStruct().patternGrid)
    }
}
