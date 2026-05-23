//
//  ThemeManager.swift
//  BeadInventory
//
//  色彩模式核心：@Observable 单例 + Environment 注入。
//  Theme.ColorToken.Surface 通过 .shared 读色值；视图通过 @Environment(ThemeManager.self) 订阅。
//

import Foundation
import SwiftUI
import SwiftData  // for ModelContext in Task 9 (commitAsNewScheme), Task 12 (bootstrap), Task 20 (sync)
import Combine   // for debounce in Task 9

enum ApplyTarget {
    case both, lightOnly, darkOnly
}

enum ThemeSlot {
    case lightBg, lightElev, darkBg, darkElev
}

struct ThemeDraft {
    let snapshotActiveSchemeID: UUID?
    let snapshotLight: ColorPalette
    let snapshotDark:  ColorPalette
    var isDirty: Bool
}

@Observable
final class ThemeManager {

    static let shared = ThemeManager()

    private(set) var activeSchemeID: UUID?
    private(set) var resolvedLight: ColorPalette
    private(set) var resolvedDark:  ColorPalette
    private(set) var draft: ThemeDraft?

    var isDirty: Bool { draft?.isDirty ?? false }

    init(
        activeSchemeID: UUID? = nil,
        resolvedLight: ColorPalette = .defaultLight,
        resolvedDark:  ColorPalette = .defaultDark
    ) {
        self.activeSchemeID = activeSchemeID
        self.resolvedLight = resolvedLight
        self.resolvedDark = resolvedDark
    }

    // MARK: - 给 Theme.ColorToken 用的 UIColor 工厂
    //
    // 闭包内部读 self.resolvedLight/Dark；@Observable 在 View body 评估期间
    // 读取 .shared.resolvedLight 时建立依赖订阅，色值变化触发整树 re-evaluate body，
    // 产生新的 Color(uiColor:) 实例。闭包本身只在系统 trait 变化时被 iOS 调用一次。

    var dynamicBg: UIColor {
        UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark
                ? self.resolvedDark.bg
                : self.resolvedLight.bg
            return UIColor(themeHex: hex)
        }
    }

    var dynamicBgElev: UIColor {
        UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark
                ? self.resolvedDark.bgElev
                : self.resolvedLight.bgElev
            return UIColor(themeHex: hex)
        }
    }

    // MARK: - Apply

    func apply(scheme: AppColorScheme, target: ApplyTarget) {
        switch target {
        case .both:
            resolvedLight = scheme.light
            resolvedDark  = scheme.dark
            activeSchemeID = scheme.id
        case .lightOnly:
            resolvedLight = scheme.light
            activeSchemeID = nil
        case .darkOnly:
            resolvedDark = scheme.dark
            activeSchemeID = nil
        }
        if let draftValue = draft {
            draft = ThemeDraft(
                snapshotActiveSchemeID: draftValue.snapshotActiveSchemeID,
                snapshotLight: draftValue.snapshotLight,
                snapshotDark:  draftValue.snapshotDark,
                isDirty: target != .both
            )
        }
    }

    // MARK: - Swatch 编辑

    func updateSwatch(_ slot: ThemeSlot, hex: String) {
        let normalized = normalizeHex(hex)
        switch slot {
        case .lightBg:    resolvedLight.bg     = normalized
        case .lightElev:  resolvedLight.bgElev = normalized
        case .darkBg:     resolvedDark.bg      = normalized
        case .darkElev:   resolvedDark.bgElev  = normalized
        }
        activeSchemeID = nil
        if var d = draft {
            d.isDirty = true
            draft = d
        }
    }

    private func normalizeHex(_ raw: String) -> String {
        let trimmed = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        return trimmed.uppercased()
    }

    // MARK: - Draft lifecycle

    func beginDraft() {
        draft = ThemeDraft(
            snapshotActiveSchemeID: activeSchemeID,
            snapshotLight: resolvedLight,
            snapshotDark:  resolvedDark,
            isDirty: false
        )
    }

    func discardDraft() {
        guard let d = draft else { return }
        resolvedLight = d.snapshotLight
        resolvedDark  = d.snapshotDark
        activeSchemeID = d.snapshotActiveSchemeID
        draft = nil
    }

    @discardableResult
    func commitAsNewScheme(name: String) throws -> AppColorScheme {
        let now = Date()
        let scheme = AppColorScheme(
            id: UUID(),
            name: name,
            light: resolvedLight,
            dark:  resolvedDark,
            isBuiltin: false,
            createdAt: now,
            updatedAt: now
        )
        activeSchemeID = scheme.id
        draft = nil
        // 写入 SwiftData 在 Task 9 的 persistence 中完成
        return scheme
    }
}
