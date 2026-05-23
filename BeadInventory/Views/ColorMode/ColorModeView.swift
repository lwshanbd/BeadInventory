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
        .onAppear { themeManager.beginDraft() }
    }

    private var currentSchemeLabel: some View {
        let activeID = themeManager.activeSchemeID
        let activeName = activeID.flatMap { id in allSchemes.first { $0.id == id }?.name } ?? ""
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
    private var mySchemesSection: some View { Text("[my schemes - Task 17]") }

    private func resetToDefault() { /* Task 18 */ }
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

extension Color {
    func toThemeHex() -> String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        let ri = Int((r * 255).rounded())
        let gi = Int((g * 255).rounded())
        let bi = Int((b * 255).rounded())
        return String(format: "%02X%02X%02X", ri, gi, bi)
    }
}
