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

    // MARK: - Persistence

    private let defaults: UserDefaults
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    private static let debounceMs: UInt64 = 250_000_000  // 250ms

    enum PrefsKey {
        static let activeSchemeID    = "theme.activeSchemeID"
        static let lightBgHex        = "theme.light.bgHex"
        static let lightBgElevHex    = "theme.light.bgElevHex"
        static let darkBgHex         = "theme.dark.bgHex"
        static let darkBgElevHex     = "theme.dark.bgElevHex"
        static let pendingDraftJSON  = "theme.pendingDraftJSON"
        static let builtinVersion    = "theme.builtinVersion"
    }

    // 测试入口
    static func test_make(defaults: UserDefaults) -> ThemeManager {
        ThemeManager(defaults: defaults)
    }

    private init(
        defaults: UserDefaults,
        activeSchemeID: UUID? = nil,
        resolvedLight: ColorPalette = .defaultLight,
        resolvedDark:  ColorPalette = .defaultDark
    ) {
        self.defaults = defaults
        self.activeSchemeID = activeSchemeID
        self.resolvedLight = resolvedLight
        self.resolvedDark = resolvedDark
    }

    convenience init(
        activeSchemeID: UUID? = nil,
        resolvedLight: ColorPalette = .defaultLight,
        resolvedDark:  ColorPalette = .defaultDark
    ) {
        self.init(
            defaults: .standard,
            activeSchemeID: activeSchemeID,
            resolvedLight: resolvedLight,
            resolvedDark: resolvedDark
        )
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
        schedulePersistResolved()
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
        schedulePersistResolved()
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
    func commitAsNewScheme(name: String, modelContext: ModelContext? = nil) throws -> AppColorScheme {
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
        if let ctx = modelContext {
            let sd = SDColorScheme(from: scheme)
            ctx.insert(sd)
            try ctx.save()
        }
        activeSchemeID = scheme.id
        draft = nil
        schedulePersistResolved()
        return scheme
    }

    func loadOverridesFromDefaults() {
        if let id = defaults.string(forKey: PrefsKey.activeSchemeID).flatMap(UUID.init) {
            activeSchemeID = id
        }
        resolvedLight = ColorPalette(
            bg: defaults.string(forKey: PrefsKey.lightBgHex) ?? ColorPalette.defaultLight.bg,
            bgElev: defaults.string(forKey: PrefsKey.lightBgElevHex) ?? ColorPalette.defaultLight.bgElev
        )
        resolvedDark = ColorPalette(
            bg: defaults.string(forKey: PrefsKey.darkBgHex) ?? ColorPalette.defaultDark.bg,
            bgElev: defaults.string(forKey: PrefsKey.darkBgElevHex) ?? ColorPalette.defaultDark.bgElev
        )
    }

    private func schedulePersistResolved() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ThemeManager.debounceMs)
            await MainActor.run { [weak self] in self?.flushPersistResolved() }
        }
    }

    private func flushPersistResolved() {
        defaults.set(activeSchemeID?.uuidString, forKey: PrefsKey.activeSchemeID)
        defaults.set(resolvedLight.bg,     forKey: PrefsKey.lightBgHex)
        defaults.set(resolvedLight.bgElev, forKey: PrefsKey.lightBgElevHex)
        defaults.set(resolvedDark.bg,      forKey: PrefsKey.darkBgHex)
        defaults.set(resolvedDark.bgElev,  forKey: PrefsKey.darkBgElevHex)
    }

    func flushPersistenceForTests() {
        debounceTask?.cancel()
        flushPersistResolved()
    }
}
