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

    // MARK: - 这个色拼完了

    /// 存了勾的图纸，一来一回还是那些勾。丢了的话用户几个晚上的进度就没了。
    func testDoneColorsRoundTrip() throws {
        var grid = makeSampleGrid()
        grid.doneColors = ["M24": 3]

        let decoded = try JSONDecoder().decode(
            BeadPatternGrid.self, from: JSONEncoder().encode(grid))
        XCTAssertEqual(decoded, grid)
        XCTAssertEqual(decoded.doneColors?["M24"], 3)
    }

    /// 没有 `doneColors` 这个字段的老图纸照样解得出来 ——
    /// 解不出来的代价是整张图纸打不开，用户几天的活全没了。
    func testDecodesGridSavedBeforeDoneColors() throws {
        let json = """
        {
          "corners" : {
            "topLeft" : [ 0.1, 0.1 ],
            "topRight" : [ 0.9, 0.1 ],
            "bottomLeft" : [ 0.1, 0.9 ],
            "bottomRight" : [ 0.9, 0.9 ]
          },
          "rows" : 1,
          "cols" : 2,
          "cellColorCodes" : [ [ "M24", null ] ],
          "lastCalibratedAt" : 700000000,
          "sourceImageSize" : [ 1024, 1024 ],
          "colorSystem" : "MARD"
        }
        """
        let grid = try JSONDecoder().decode(BeadPatternGrid.self, from: Data(json.utf8))
        XCTAssertEqual(grid.cols, 2)
        XCTAssertNil(grid.doneColors)
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
