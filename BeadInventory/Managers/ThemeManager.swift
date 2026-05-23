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
        schedulePersistResolved()   // <-- NEW
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
            do {
                try await Task.sleep(nanoseconds: ThemeManager.debounceMs)
            } catch {
                return   // 取消即放弃这次 flush —— 下一次 schedule 会重新计时
            }
            await MainActor.run { [weak self] in self?.flushPersistResolved() }
        }
    }

    private func flushPersistResolved() {
        if let id = activeSchemeID {
            defaults.set(id.uuidString, forKey: PrefsKey.activeSchemeID)
        } else {
            defaults.removeObject(forKey: PrefsKey.activeSchemeID)
        }
        defaults.set(resolvedLight.bg,     forKey: PrefsKey.lightBgHex)
        defaults.set(resolvedLight.bgElev, forKey: PrefsKey.lightBgElevHex)
        defaults.set(resolvedDark.bg,      forKey: PrefsKey.darkBgHex)
        defaults.set(resolvedDark.bgElev,  forKey: PrefsKey.darkBgElevHex)
        persistPendingDraft()
    }

    /// 同步落盘当前状态，绕过 debounce。App 进后台 / 被杀前应调用，避免丢失最后一次编辑。
    func flushPersistenceNow() {
        debounceTask?.cancel()
        flushPersistResolved()
    }

    /// 单测专用别名，保持向后兼容。
    func flushPersistenceForTests() {
        flushPersistenceNow()
    }

    // MARK: - Pending draft persistence

    private struct DraftPayload: Codable {
        let snapshotActiveSchemeID: UUID?
        let snapshotLight: ColorPalette
        let snapshotDark: ColorPalette
        let currentLight: ColorPalette
        let currentDark: ColorPalette
    }

    private func persistPendingDraft() {
        guard let d = draft, d.isDirty else {
            defaults.removeObject(forKey: PrefsKey.pendingDraftJSON)
            return
        }
        let payload = DraftPayload(
            snapshotActiveSchemeID: d.snapshotActiveSchemeID,
            snapshotLight: d.snapshotLight,
            snapshotDark: d.snapshotDark,
            currentLight: resolvedLight,
            currentDark: resolvedDark
        )
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: PrefsKey.pendingDraftJSON)
        }
    }

    func loadPendingDraftFromDefaults() {
        guard let data = defaults.data(forKey: PrefsKey.pendingDraftJSON),
              let payload = try? JSONDecoder().decode(DraftPayload.self, from: data) else {
            return
        }
        draft = ThemeDraft(
            snapshotActiveSchemeID: payload.snapshotActiveSchemeID,
            snapshotLight: payload.snapshotLight,
            snapshotDark: payload.snapshotDark,
            isDirty: true
        )
        resolvedLight = payload.currentLight
        resolvedDark  = payload.currentDark
        activeSchemeID = nil
    }

    // MARK: - Builtin presets bootstrap

    private struct BuiltinFile: Decodable {
        let version: Int
        let schemes: [BuiltinScheme]
    }
    private struct BuiltinScheme: Decodable {
        let id: UUID
        let name_key: String
        let light: BuiltinPalette
        let dark:  BuiltinPalette
    }
    private struct BuiltinPalette: Decodable {
        let bg: String
        let bg_elev: String
    }

    func bootstrapBuiltinPresets(modelContext: ModelContext) throws {
        guard let url = Bundle.main.url(forResource: "built_in_color_schemes", withExtension: "json") else {
            return
        }
        let data = try Data(contentsOf: url)
        try bootstrapBuiltinPresets(jsonData: data, modelContext: modelContext)
    }

    func bootstrapBuiltinPresets(jsonData: Data, modelContext: ModelContext) throws {
        let file = try JSONDecoder().decode(BuiltinFile.self, from: jsonData)
        let stored = defaults.integer(forKey: PrefsKey.builtinVersion)
        guard file.version > stored else { return }

        let now = Date()
        for s in file.schemes {
            let predicateID = s.id
            let descriptor = FetchDescriptor<SDColorScheme>(
                predicate: #Predicate { $0.id == predicateID }
            )
            let existing = try modelContext.fetch(descriptor).first

            if let existing {
                existing.name = s.name_key
                existing.lightBgHex     = s.light.bg.uppercased()
                existing.lightBgElevHex = s.light.bg_elev.uppercased()
                existing.darkBgHex      = s.dark.bg.uppercased()
                existing.darkBgElevHex  = s.dark.bg_elev.uppercased()
                existing.isBuiltin = true
                existing.updatedAt = now
            } else {
                modelContext.insert(SDColorScheme(
                    id: s.id,
                    name: s.name_key,
                    lightBgHex:     s.light.bg.uppercased(),
                    lightBgElevHex: s.light.bg_elev.uppercased(),
                    darkBgHex:      s.dark.bg.uppercased(),
                    darkBgElevHex:  s.dark.bg_elev.uppercased(),
                    isBuiltin: true,
                    createdAt: now,
                    updatedAt: now
                ))
            }
        }
        try modelContext.save()
        defaults.set(file.version, forKey: PrefsKey.builtinVersion)
    }
}
