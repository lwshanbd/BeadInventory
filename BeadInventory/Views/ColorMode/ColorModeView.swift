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

    private var swatchRow: some View { Text("[swatch row - Task 15]") }
    private var presetsSection: some View { Text("[presets - Task 16]") }
    private var mySchemesSection: some View { Text("[my schemes - Task 17]") }

    private func resetToDefault() { /* Task 18 */ }
}
