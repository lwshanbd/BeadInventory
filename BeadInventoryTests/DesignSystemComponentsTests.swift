//
//  DesignSystemComponentsTests.swift
//  BeadInventoryTests
//
//  设计系统组件回归测试 —— BIBadge / BIColorSwatch / BIRow 构造期检查。
//

import XCTest
import SwiftUI
@testable import BeadInventory

final class DesignSystemComponentsTests: XCTestCase {
    func test_badge_renders_each_style() throws {
        _ = BIBadge("ok",   style: .success)
        _ = BIBadge("warn", style: .warning)
        _ = BIBadge("err",  style: .error)
        _ = BIBadge("info", style: .info)
        _ = BIBadge("acc",  style: .accent)
        _ = BIBadge("",     style: .neutral)
    }

    func test_color_swatch_handles_invalid_hex() throws {
        _ = BIColorSwatch(hex: "not-a-hex", code: "?")
    }

    func test_row_with_all_slots() throws {
        _ = BIRow(title: "a", subtitle: "b") {
            Image(systemName: "star")
        } trailing: {
            BIBadge("ok", style: .success)
        }
    }

    func test_buttons_compile() {
        _ = BIPrimaryButton("a") {}
        _ = BISecondaryButton("b") {}
        _ = BIDestructiveButton("c") {}
    }

    func test_stat_card_compiles() {
        _ = BIStatCard(icon: "star", title: "T", value: "9")
    }
}
