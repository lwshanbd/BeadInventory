//
//  BeadInventoryTests.swift
//  BeadInventoryTests
//
//  Smoke test - 验证 BeadInventoryTests target 已正确接入构建系统。
//  实际测试用例由后续 Task 4-6 添加。
//

import XCTest
@testable import BeadInventory

final class BeadInventoryTests: XCTestCase {
    func testTargetWiredUp() {
        XCTAssertTrue(true, "tests target 已建好，可以加用例")
    }
}
