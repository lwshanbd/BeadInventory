//
//  SelectionContextTests.swift
//  BeadInventoryTests
//
//  SelectionContext 生命周期 / 选中集合行为单元测试。
//

import XCTest
@testable import BeadInventory

@MainActor
final class SelectionContextTests: XCTestCase {

    func test_enter_exit_lifecycle() {
        let ctx = SelectionContext<Int>()
        XCTAssertFalse(ctx.isActive)
        ctx.enter(initial: 7)
        XCTAssertTrue(ctx.isActive)
        XCTAssertTrue(ctx.contains(7))
        ctx.exit()
        XCTAssertFalse(ctx.isActive)
        XCTAssertEqual(ctx.count, 0)
    }

    func test_toggle_adds_then_removes() {
        let ctx = SelectionContext<Int>()
        ctx.enter()
        ctx.toggle(1)
        ctx.toggle(2)
        ctx.toggle(1)
        XCTAssertEqual(ctx.selected, [2])
    }

    func test_enter_without_initial_keeps_selection_empty() {
        let ctx = SelectionContext<Int>()
        ctx.enter()
        XCTAssertTrue(ctx.isActive)
        XCTAssertEqual(ctx.count, 0)
    }
}
