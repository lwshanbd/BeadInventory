//
//  PartsReadingOrderTests.swift
//  BeadInventoryTests
//
//  零件清单的编号顺序排得顺不顺，用户在屏幕上一眼看得见，这里不管。
//  这里只钉两条错了用户看不出来的：
//  - 排序是拿下标去取零件的，漏一个、重一个，清单就少一块或多一块，扣减跟着错，不报错。
//  - 编号被后面几步用上之后，补一个框不许把别的零件挪位置：板子上的「零件 7」会悄悄变成别的号。
//

import XCTest
@testable import BeadInventory

final class PartsReadingOrderTests: XCTestCase {

    func testEveryPartAppearsExactlyOnce() {
        let cases: [[CGRect]] = [
            [],
            [CGRect(x: 0, y: 0, width: 10, height: 10)],
            // 一个高零件旁边叠着一摞小零件
            [CGRect(x: 0, y: 0, width: 20, height: 100), CGRect(x: 30, y: 0, width: 20, height: 20),
             CGRect(x: 30, y: 30, width: 20, height: 20), CGRect(x: 30, y: 60, width: 20, height: 20)],
            // 左右两栏，中间一条宽竖缝
            [CGRect(x: 0, y: 0, width: 20, height: 20), CGRect(x: 25, y: 0, width: 20, height: 20),
             CGRect(x: 0, y: 30, width: 20, height: 20), CGRect(x: 200, y: 5, width: 20, height: 10),
             CGRect(x: 225, y: 5, width: 20, height: 10), CGRect(x: 200, y: 50, width: 20, height: 10)],
            // 画大了、竖着跨两行的框
            [CGRect(x: 0, y: 0, width: 20, height: 20), CGRect(x: 30, y: 0, width: 20, height: 70),
             CGRect(x: 0, y: 50, width: 20, height: 20), CGRect(x: 60, y: 50, width: 20, height: 20)],
            // 宽或高为 0 的框
            [CGRect(x: 0, y: 0, width: 0, height: 10), CGRect(x: 5, y: 0, width: 10, height: 0),
             CGRect(x: 20, y: 0, width: 10, height: 10)],
        ]
        for rects in cases {
            let flat = PartsDetector.readingRows(rects).flatMap { $0 }
            XCTAssertEqual(flat.sorted(), Array(rects.indices), "\(rects)")
        }
    }

    func testInsertingKeepsExistingOrderOnceNumberingInUse() {
        // 故意给一个跟按位置排不一样的老顺序：右边那块排在最前
        let right = BeadPart(rowBand: 0, bounds: CGRect(x: 0.6, y: 0.1, width: 0.1, height: 0.1), gridConfirmed: true)
        let left = BeadPart(rowBand: 0, bounds: CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1))
        let lower = BeadPart(rowBand: 1, bounds: CGRect(x: 0.1, y: 0.5, width: 0.1, height: 0.1))
        let added = BeadPart(rowBand: 0, bounds: CGRect(x: 0.3, y: 0.1, width: 0.1, height: 0.1))

        let result = PartsListStepView.ordered([right, left, lower, added], inserting: [added.id])
        XCTAssertEqual(result.map(\.id), [right.id, left.id, added.id, lower.id])

        // 编号还没用上时照常整页按位置排
        var untouched = right
        untouched.gridConfirmed = nil
        let fresh = PartsListStepView.ordered([untouched, left, lower, added], inserting: [added.id])
        XCTAssertEqual(fresh.map(\.id), [left.id, added.id, right.id, lower.id])
    }
}
