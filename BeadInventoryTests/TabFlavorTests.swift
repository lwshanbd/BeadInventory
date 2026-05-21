//
//  TabFlavorTests.swift
//  BeadInventoryTests
//
//  TabFlavor 环境值回归测试 —— rawValue 映射 + allCases 完整性 + Palette 资产存在性。
//

import XCTest
import SwiftUI
@testable import BeadInventory

final class TabFlavorTests: XCTestCase {

    func test_rawValues_match_tab_indices() {
        XCTAssertEqual(TabFlavor.inventory.rawValue, 0)
        XCTAssertEqual(TabFlavor.scan.rawValue, 1)
        XCTAssertEqual(TabFlavor.plan.rawValue, 2)
        XCTAssertEqual(TabFlavor.statistics.rawValue, 3)
        XCTAssertEqual(TabFlavor.more.rawValue, 4)
    }

    func test_all_cases_count() {
        XCTAssertEqual(TabFlavor.allCases.count, 5)
    }

    func test_each_flavor_references_existing_palette_asset() {
        // 复用 Task 1 的 Bundle pattern: 通过主 App 模块中的类拿到资源 bundle
        let appBundle = Bundle(for: InventoryManager.self)
        let expectedAssets: [(TabFlavor, String)] = [
            (.inventory, "Palette/Peach"),
            (.scan, "Palette/Coral"),
            (.plan, "Palette/Lavender"),
            (.statistics, "Palette/Mint"),
            (.more, "Palette/Sky"),
        ]
        for (_, name) in expectedAssets {
            XCTAssertNotNil(
                UIColor(named: name, in: appBundle, compatibleWith: nil),
                "TabFlavor expects palette asset: \(name)"
            )
        }
    }
}
