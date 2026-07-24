//
//  ColorModeView.swift
//  BeadInventory
//
//  色彩模式主页面 (Task 14 skeleton)
//

import SwiftUI
import SwiftData

struct ColorModeView: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \SDColorScheme.createdAt) private var allSchemes: [SDColorScheme]

    @State private var previewSchemeOverride: SwiftUI.ColorScheme?    // 🌞⇄🌜
    @State private var pendingPreset: AppColorScheme?
    @State private var showingSaveDialog = false
    @State private var showingLeaveDialog = false
    @State private var newName: String = ""
    @State private var operationError: ThemeOperationError?

    /// 用户发起的色彩主题写操作错误，承载本地化标题 + 详情。
    private struct ThemeOperationError: Identifiable {
        let id = UUID()
        let titleKey: LocalizedStringKey
        let message: String
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                currentSchemeLabel
                swatchRow
                Divider()
                presetsSection
                Divider()
                mySchemesSection
            }
            .padding(Theme.Spacing.lg)
        }
        .navigationTitle(Text("color_mode.title"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) { resetToDefault() } label: {
                    Text("color_mode.button.reset")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    previewSchemeOverride = (previewSchemeOverride == .dark) ? .light : .dark
                } label: {
                    Image(systemName: previewSchemeOverride == .dark ? "moon.fill" : "sun.max.fill")
                }
            }
        }
        .preferredColorScheme(previewSchemeOverride)
        .background(Theme.ColorToken.Surface.background.ignoresSafeArea())
        .onAppear {
            // 已有 draft（启动恢复未保存改动后）不要重新 snapshot，否则原始可回滚状态丢失。
            if themeManager.draft == nil {
                themeManager.beginDraft()
            }
        }
        .navigationBarBackButtonHidden(themeManager.isDirty)
        .toolbar {
            if themeManager.isDirty {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingLeaveDialog = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("common.back")
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            Text("color_mode.dialog.leave_title"),
            isPresented: $showingLeaveDialog,
            titleVisibility: .visible
        ) {
            Button("color_mode.button.save_as_new") {
                showingLeaveDialog = false
                newName = ""
                showingSaveDialog = true
            }
            Button("color_mode.button.discard", role: .destructive) {
                themeManager.discardDraft()
                showingLeaveDialog = false
                dismiss()
            }
            Button("common.cancel", role: .cancel) { showingLeaveDialog = false }
        }
        .alert(
            operationError?.titleKey ?? "",
            isPresented: Binding(
                get: { operationError != nil },
                set: { if !$0 { operationError = nil } }
            ),
            presenting: operationError
        ) { _ in
            Button("common.ok", role: .cancel) { operationError = nil }
        } message: { err in
            Text(err.message)
        }
    }

    private var currentSchemeLabel: some View {
        let activeID = themeManager.activeSchemeID
        // 内建预设 name 存的是本地化 key（如 color_mode.preset.mist_coast），需解析；
        // 自定义主题只按原名显示——若也过 String(localized:)，用户起的名字恰好
        // 撞上某个本地化 key 时会被意外翻译掉。
        let activeScheme = activeID.flatMap { id in allSchemes.first { $0.id == id } }
        let activeName = activeScheme.map {
            $0.isBuiltin ? String(localized: String.LocalizationValue($0.name)) : $0.name
        } ?? ""
        return HStack {
            Text("color_mode.label.current_scheme")
                .foregroundStyle(Theme.ColorToken.Text.secondary)
            Spacer()
            Text(activeID == nil
                 ? String(localized: "color_mode.label.custom_unsaved")
                 : activeName)
                .foregroundStyle(Theme.ColorToken.Text.primary)
        }
    }

    private var swatchRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            swatchTile(slot: .lightBg,
                       label: String(localized: "color_mode.swatch.light_bg"),
                       hex: themeManager.resolvedLight.bg)
            swatchTile(slot: .lightElev,
                       label: String(localized: "color_mode.swatch.light_elev"),
                       hex: themeManager.resolvedLight.bgElev)
            swatchTile(slot: .darkBg,
                       label: String(localized: "color_mode.swatch.dark_bg"),
                       hex: themeManager.resolvedDark.bg)
            swatchTile(slot: .darkElev,
                       label: String(localized: "color_mode.swatch.dark_elev"),
                       hex: themeManager.resolvedDark.bgElev)
        }
    }

    @ViewBuilder
    private func swatchTile(slot: ThemeSlot, label: String, hex: String) -> some View {
        SwatchTile(
            label: label,
            hex: hex,
            onPick: { newHex in themeManager.updateSwatch(slot, hex: newHex) }
        )
    }
    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("color_mode.section.presets")
                .font(Theme.Typography.sectionHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: Theme.Spacing.md)],
                      spacing: Theme.Spacing.md) {
                ForEach(allSchemes.filter { $0.isBuiltin }) { sd in
                    PresetCard(scheme: sd, isActive: sd.id == themeManager.activeSchemeID) {
                        pendingPreset = sd.toStruct()
                    }
                }
            }
        }
        .confirmationDialog(
            Text("color_mode.preset.apply_target_prompt"),
            isPresented: Binding(get: { pendingPreset != nil },
                                 set: { if !$0 { pendingPreset = nil } }),
            titleVisibility: .visible
        ) {
            Button("color_mode.preset.apply_both") {
                if let s = pendingPreset { themeManager.apply(scheme: s, target: .both) }
                pendingPreset = nil
            }
            Button("color_mode.preset.apply_light_only") {
                if let s = pendingPreset { themeManager.apply(scheme: s, target: .lightOnly) }
                pendingPreset = nil
            }
            Button("color_mode.preset.apply_dark_only") {
                if let s = pendingPreset { themeManager.apply(scheme: s, target: .darkOnly) }
                pendingPreset = nil
            }
            Button("common.cancel", role: .cancel) { pendingPreset = nil }
        }
    }
    private var mySchemesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("color_mode.section.my_themes")
                .font(Theme.Typography.sectionHeader)

            Button {
                newName = ""
                showingSaveDialog = true
            } label: {
                Label("color_mode.button.save_as_new", systemImage: "plus.circle")
            }
            .buttonStyle(.bordered)
            .disabled(!themeManager.isDirty)

            let myThemes = allSchemes.filter { !$0.isBuiltin }
            if myThemes.isEmpty {
                Text("color_mode.empty.no_my_themes")
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(Theme.ColorToken.Text.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: Theme.Spacing.md)],
                          spacing: Theme.Spacing.md) {
                    ForEach(myThemes) { sd in
                        MyThemeCard(
                            scheme: sd,
                            isActive: sd.id == themeManager.activeSchemeID,
                            onApply: { themeManager.apply(scheme: sd.toStruct(), target: .both) },
                            onRename: { newName in
                                let oldName = sd.name
                                sd.name = newName
                                sd.updatedAt = Date()
                                do {
                                    try modelContext.save()
                                } catch {
                                    sd.name = oldName    // 显式回滚，避免 UI 与持久化不一致
                                    AppLogger.shared.error(
                                        "Theme",
                                        "rename_scheme_failed",
                                        metadata: ["schemeID": sd.id.uuidString, "error": "\(error)"]
                                    )
                                    operationError = ThemeOperationError(
                                        titleKey: "color_mode.error.rename_failed_title",
                                        message: error.localizedDescription
                                    )
                                }
                            },
                            onDelete: {
                                // save-first 顺序：先尝试 delete + save，成功后才动 ThemeManager。
                                let wasActive = (themeManager.activeSchemeID == sd.id)
                                modelContext.delete(sd)
                                do {
                                    try modelContext.save()
                                    if wasActive {
                                        themeManager.apply(scheme: defaultCreamLatteOrFallback(), target: .both)
                                    }
                                } catch {
                                    modelContext.rollback()
                                    AppLogger.shared.error(
                                        "Theme",
                                        "delete_scheme_failed",
                                        metadata: ["schemeID": sd.id.uuidString, "error": "\(error)"]
                                    )
                                    operationError = ThemeOperationError(
                                        titleKey: "color_mode.error.delete_failed_title",
                                        message: error.localizedDescription
                                    )
                                }
                            }
                        )
                    }
                }
            }
        }
        .alert("color_mode.dialog.save_title", isPresented: $showingSaveDialog) {
            TextField("color_mode.dialog.save_placeholder", text: $newName)
            Button("common.save") {
                let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                do {
                    _ = try themeManager.commitAsNewScheme(name: trimmed, modelContext: modelContext)
                    dismiss()
                } catch {
                    AppLogger.shared.error(
                        "Theme",
                        "commit_as_new_scheme_failed",
                        metadata: ["name": trimmed, "error": "\(error)"]
                    )
                    operationError = ThemeOperationError(
                        titleKey: "color_mode.error.save_failed_title",
                        message: error.localizedDescription
                    )
                }
            }
            Button("common.cancel", role: .cancel) {}
        }
    }

    private func defaultCreamLatteOrFallback() -> AppColorScheme {
        if let s = allSchemes.first(where: { $0.id == UUID(uuidString: "B1A5B100-0000-0000-0000-000000000001") }) {
            return s.toStruct()
        }
        return AppColorScheme(
            id: UUID(),
            name: "color_mode.preset.cream_latte",
            light: .defaultLight, dark: .defaultDark,
            isBuiltin: true,
            createdAt: Date(), updatedAt: Date()
        )
    }

    private func resetToDefault() {
        themeManager.apply(scheme: defaultCreamLatteOrFallback(), target: .both)
    }
}

private struct SwatchTile: View {
    let label: String
    let hex: String
    let onPick: (String) -> Void

    @State private var showingPicker = false

    var body: some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(Color(uiColor: UIColor(themeHex: hex)))
                .frame(height: 56)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
                )
                .contentShape(Rectangle())
                .onTapGesture { showingPicker = true }
            Text(label)
                .font(Theme.Typography.metadata)
                .foregroundStyle(Theme.ColorToken.Text.secondary)
            Text("#\(hex)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.Text.tertiary)
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showingPicker) {
            SwatchPickerSheet(initialHex: hex, onCommit: { newHex in
                onPick(newHex)
            })
            .presentationDetents([.medium])
        }
    }
}

private struct SwatchPickerSheet: View {
    let initialHex: String
    let onCommit: (String) -> Void

    @State private var color: Color

    init(initialHex: String, onCommit: @escaping (String) -> Void) {
        self.initialHex = initialHex
        self.onCommit = onCommit
        let ui = UIColor(themeHex: initialHex)
        _color = State(initialValue: Color(uiColor: ui))
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            ColorPicker("color_mode.picker.title", selection: $color, supportsOpacity: false)
                .padding()
            Spacer()
        }
        .onChange(of: color) { _, newColor in
            onCommit(newColor.toThemeHex())
        }
    }
}

private struct PresetCard: View {
    let scheme: SDColorScheme
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                HStack(spacing: 0) {
                    Color(uiColor: UIColor(themeHex: scheme.lightBgHex))
                    Color(uiColor: UIColor(themeHex: scheme.lightBgElevHex))
                    Color(uiColor: UIColor(themeHex: scheme.darkBgHex))
                    Color(uiColor: UIColor(themeHex: scheme.darkBgElevHex))
                }
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, Theme.ColorToken.Interactive.primaryFallback)
                        .font(.title2)
                }
            }
            .frame(height: 56)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
            )
            Text(LocalizedStringKey(scheme.name))
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.ColorToken.Text.primary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

private struct MyThemeCard: View {
    let scheme: SDColorScheme
    let isActive: Bool
    let onApply: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void

    @State private var showingRename = false
    @State private var renameDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Color(uiColor: UIColor(themeHex: scheme.lightBgHex))
                Color(uiColor: UIColor(themeHex: scheme.lightBgElevHex))
                Color(uiColor: UIColor(themeHex: scheme.darkBgHex))
                Color(uiColor: UIColor(themeHex: scheme.darkBgElevHex))
            }
            .frame(height: 56)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
            )

            HStack {
                Text(scheme.name)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.ColorToken.Text.primary)
                    .lineLimit(1)
                Spacer()
                Menu {
                    Button("color_mode.menu.apply", action: onApply)
                    Button("color_mode.menu.rename") {
                        renameDraft = scheme.name
                        showingRename = true
                    }
                    Button("color_mode.menu.delete", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                }
            }
        }
        .contextMenu {
            Button("color_mode.menu.apply", action: onApply)
            Button("color_mode.menu.rename") {
                renameDraft = scheme.name
                showingRename = true
            }
            Button("color_mode.menu.delete", role: .destructive, action: onDelete)
        }
        .alert("color_mode.dialog.rename_title", isPresented: $showingRename) {
            TextField("color_mode.dialog.rename_placeholder", text: $renameDraft)
            Button("common.save") {
                let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                onRename(trimmed)
            }
            Button("common.cancel", role: .cancel) {}
        }
    }
}

extension Color {
    /// 转 "RRGGBB" 大写 hex。先把 UIColor 显式转到 sRGB 色空间，
    /// 避免在 P3 wide-gamut 设备上 getRed 直接返回 P3 分量导致 hex round-trip 失真。
    func toThemeHex() -> String {
        let ui = UIColor(self)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let cg = ui.cgColor.converted(to: srgb, intent: .defaultIntent, options: nil) ?? ui.cgColor
        let comps = cg.components ?? [0, 0, 0, 1]
        let r = comps.count > 0 ? max(0, min(1, comps[0])) : 0
        let g = comps.count > 1 ? max(0, min(1, comps[1])) : 0
        let b = comps.count > 2 ? max(0, min(1, comps[2])) : 0
        return String(
            format: "%02X%02X%02X",
            Int((r * 255).rounded()),
            Int((g * 255).rounded()),
            Int((b * 255).rounded())
        )
    }
}
