import XCTest
import SwiftUI
@testable import BeadInventory

final class ThemeTests: XCTestCase {

    func test_status_tokens_are_resolvable() {
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
            Theme.ColorToken.Border.default,
            Theme.ColorToken.Border.divider,
        ]
        XCTAssertEqual(tokens.count, 12, "全部 token 都应被引用")
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
