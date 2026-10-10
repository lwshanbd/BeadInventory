//
//  TabFlavorTests.swift
//  BeadInventoryTests
//
//  TabFlavor 环境值回归测试 —— rawValue 映射 + allCases 完整性 + Palette 资产存在性。
//  5 个 Tab：库存 / 计划 / 工作台 / 记录 / 更多。
//

import XCTest
import SwiftUI
@testable import BeadInventory

final class TabFlavorTests: XCTestCase {

    func test_rawValues_match_tab_indices() {
        XCTAssertEqual(TabFlavor.inventory.rawValue, 0)
        XCTAssertEqual(TabFlavor.plan.rawValue, 1)
        XCTAssertEqual(TabFlavor.workshop.rawValue, 2)
        XCTAssertEqual(TabFlavor.records.rawValue, 3)
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
            case .inventory:  expectedAssetName = "Palette/Peach"     // latte
            case .plan:       expectedAssetName = "Palette/Lavender"  // mauve，跟工作台同色
            case .workshop:   expectedAssetName = "Palette/Lavender"  // mauve (工作台主色)
            case .records:    expectedAssetName = "Palette/Mint"      // sage
            case .more:       expectedAssetName = "Palette/Sky"       // mist
            }
            XCTAssertNotNil(
                UIColor(named: expectedAssetName, in: appBundle, compatibleWith: nil),
                "TabFlavor.\(flavor) expects asset: \(expectedAssetName)"
            )
        }
    }

    func test_workshop_color_is_lavender_not_coral() {
        // 防止后续误把 .workshop 改回 scan(Coral)。设计稿明确工作台主色 = mauve(Lavender)。
        let appBundle = Bundle(for: InventoryManager.self)
        XCTAssertNotNil(UIColor(named: "Palette/Lavender", in: appBundle, compatibleWith: nil))
    }

    func test_environment_default_is_inventory() {
        let values = EnvironmentValues()
        XCTAssertEqual(values.tabFlavor, .inventory)
    }
}
