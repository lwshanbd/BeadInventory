//
//  ThemeTests.swift
//  BeadInventoryTests
//
//  设计系统 token 回归测试 —— Asset Catalog 资产存在性 + SwiftUI API 编译期检查 + 尺度单调性。
//

import XCTest
import UIKit
import SwiftUI
@testable import BeadInventory

final class ThemeTests: XCTestCase {

    // The asset catalog lives in the main app bundle, not the test bundle.
    // Bundle(for: InventoryManager.self) resolves to BeadInventory.app which contains Assets.car.
    private var appBundle: Bundle { Bundle(for: InventoryManager.self) }

    func test_all_palette_assets_exist_in_bundle() {
        let names = [
            "Palette/Peach", "Palette/Coral", "Palette/Lavender",
            "Palette/Mint", "Palette/Sky", "Palette/Lemon", "Palette/Rose",
            "Palette/Neutral50", "Palette/Neutral100", "Palette/Neutral200",
            "Palette/Neutral400", "Palette/Neutral600", "Palette/Neutral900",
        ]
        for name in names {
            XCTAssertNotNil(UIColor(named: name, in: appBundle, compatibleWith: nil),
                            "Palette asset missing: \(name)")
        }
    }

    func test_all_semantic_assets_exist_in_bundle() {
        let names = ["Semantic/Success", "Semantic/Warning", "Semantic/Error", "Semantic/Info"]
        for name in names {
            XCTAssertNotNil(UIColor(named: name, in: appBundle, compatibleWith: nil),
                            "Semantic asset missing: \(name)")
        }
    }

    func test_swiftui_color_tokens_compile() {
        // Compile-time sanity check that the public Color tokens exist.
        // (UIColor(named:) tests above cover asset existence; this just ensures the Swift API surface didn't regress.)
        let tokens: [Color] = [
            Theme.ColorToken.Status.success,
            Theme.ColorToken.Status.warning,
            Theme.ColorToken.Status.error,
            Theme.ColorToken.Status.info,
            Theme.ColorToken.Surface.background,
            Theme.ColorToken.Surface.elevated,
            Theme.ColorToken.Surface.subtle,
            Theme.ColorToken.Text.primary,
            Theme.ColorToken.Text.secondary,
            Theme.ColorToken.Text.tertiary,
            Theme.ColorToken.Text.onAccent,
            Theme.ColorToken.Border.default,
            Theme.ColorToken.Border.divider,
            Theme.ColorToken.Interactive.destructive,
        ]
        XCTAssertEqual(tokens.count, 14)
    }

    func test_spacing_scale_monotonic() {
        XCTAssertLessThan(Theme.Spacing.xs, Theme.Spacing.sm)
        XCTAssertLessThan(Theme.Spacing.sm, Theme.Spacing.md)
        XCTAssertLessThan(Theme.Spacing.md, Theme.Spacing.lg)
        XCTAssertLessThan(Theme.Spacing.lg, Theme.Spacing.xl)
        XCTAssertLessThan(Theme.Spacing.xl, Theme.Spacing.xxl)
    }

    func test_radius_scale_monotonic() {
        XCTAssertLessThan(Theme.Radius.sm, Theme.Radius.md)
        XCTAssertLessThan(Theme.Radius.md, Theme.Radius.lg)
        XCTAssertLessThan(Theme.Radius.lg, Theme.Radius.pill)
    }
}
