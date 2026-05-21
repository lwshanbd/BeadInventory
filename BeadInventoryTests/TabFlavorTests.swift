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
        let appBundle = Bundle(for: InventoryManager.self)
        for flavor in TabFlavor.allCases {
            let expectedAssetName: String
            switch flavor {
            case .inventory:  expectedAssetName = "Palette/Peach"
            case .scan:       expectedAssetName = "Palette/Coral"
            case .plan:       expectedAssetName = "Palette/Lavender"
            case .statistics: expectedAssetName = "Palette/Mint"
            case .more:       expectedAssetName = "Palette/Sky"
            }
            XCTAssertNotNil(
                UIColor(named: expectedAssetName, in: appBundle, compatibleWith: nil),
                "TabFlavor.\(flavor) expects asset: \(expectedAssetName)"
            )
        }
    }

    func test_environment_default_is_inventory() {
        let values = EnvironmentValues()
        XCTAssertEqual(values.tabFlavor, .inventory)
    }
}
