//
//  PartsPaletteStepView.swift
//  BeadInventory
//
//  多零件模式 · 第 ③ 屏 - 图纸调色板
//
//  这一屏在回答一个问题：**这张图纸上的每一种颜色，分别代表什么。**
//
//  三选一：
//    · 某个色号  —— 正常的豆子
//    · 任意色    —— 图例里写「任意色」的那块，有豆子但用什么色由用户自己定
//    · 空        —— 不是豆子（零件中间的镂空、框里蹭进来的背景）
//
//  「任意色」和「空」在图上都是浅色一片，算法分不清 —— 这正是这一屏存在的理由：
//  与其让它去猜、猜错了再让用户一格一格改，不如在这里问一次，一次定死一片。
//

import SwiftUI

struct PartsPaletteStepView: View {
    @Binding var palette: [PartsPaletteEntry]
    let colorSystem: ColorSystem
    let partCount: Int
    let onFinish: () -> Void

    @EnvironmentObject var inventoryManager: InventoryManager

    /// 正在给哪一条挑色号。`showingPicker` 单独一个 Bool —— 用
    /// `pickingEntryID != nil` 当 presented 绑定的话，sheet 收起时 setter 会先把
    /// id 清成 nil，`onDismiss` 里就不知道该把色号写回哪一条了。
    @State private var pickingEntryID: UUID?
    @State private var showingPicker = false
    @State private var pickedCodes: Set<String> = []

    /// 自动匹配的 Lab 距离超过这个就打问号提醒用户看一眼。
    /// 25 = 「同色族深浅变化」的量级，再大基本就是匹到别的色系去了。
    private let suspiciousDeltaE: Double = 25

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach($palette) { $entry in
                        PaletteRow(
                            entry: $entry,
                            colorSystem: colorSystem,
                            suspiciousDeltaE: suspiciousDeltaE,
                            colorName: colorName(for: entry),
                            onPickCode: { beginPicking(entry) }
                        )
                    }
                } header: {
                    Text("图纸上找到 \(palette.count) 种颜色")
                } footer: {
                    Text("按占比从多到少排。带 ⚠︎ 的是自动匹得不太准的，重点看这几条。\n零件中间的镂空要标成「空」，图例里写「任意色」的那种浅色标成「任意色」。")
                }
            }
            .listStyle(.insetGrouped)

            footer
        }
        .navigationTitle("图纸配色")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingPicker, onDismiss: commitPickedCode) {
            ColorSelectionView(selectedColors: $pickedCodes, colorSystem: colorSystem)
                .environmentObject(inventoryManager)
        }
    }

    private var footer: some View {
        VStack(spacing: Theme.Spacing.sm) {
            summaryLine

            Button(action: onFinish) {
                Label("保存这 \(partCount) 个零件", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Text("下一步（量格子大小、逐格识别）还在做，先把零件和配色存下来。")
                .font(.caption2)
                .foregroundStyle(Theme.ColorToken.Text.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var summaryLine: some View {
        let codeCount = palette.filter { if case .code = $0.role { return true } else { return false } }.count
        let anyCount = palette.filter { $0.role == .anyColor }.count
        let emptyCount = palette.filter { $0.role == .empty }.count
        Text("\(codeCount) 种色号 · \(anyCount) 种任意色 · \(emptyCount) 种空")
            .font(.footnote)
            .foregroundStyle(Theme.ColorToken.Text.secondary)
    }

    private func colorName(for entry: PartsPaletteEntry) -> String? {
        guard case .code(let code) = entry.role else { return nil }
        let name = inventoryManager.findColor(byCode: code, preferSystem: colorSystem)?.colorName
        return (name?.isEmpty ?? true) ? nil : name
    }

    private func beginPicking(_ entry: PartsPaletteEntry) {
        if case .code(let code) = entry.role {
            pickedCodes = [code]
        } else {
            pickedCodes = []
        }
        pickingEntryID = entry.id
        showingPicker = true
    }

    /// 色号选择页是多选的，这里只取一个。用户多选时取字典序第一个 ——
    /// 一种图纸颜色只可能对应一个色号，与其弹错误不如直接落一个再让用户改。
    private func commitPickedCode() {
        defer {
            pickedCodes = []
            pickingEntryID = nil
        }
        guard let id = pickingEntryID,
              let index = palette.firstIndex(where: { $0.id == id }),
              let code = pickedCodes.sorted().first else { return }
        palette[index].role = .code(code)
        palette[index].matchDeltaE = nil   // 人工指定过，不再显示「自动匹配可疑」
    }
}

// MARK: - 一行

private struct PaletteRow: View {
    @Binding var entry: PartsPaletteEntry
    let colorSystem: ColorSystem
    let suspiciousDeltaE: Double
    let colorName: String?
    let onPickCode: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.md) {
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .fill(Color(hex: entry.hex))
                    .frame(width: 40, height: 40)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                            .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(roleTitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(Theme.ColorToken.Text.primary)
                    Text(String(format: "占 %.1f%%", entry.pixelShare * 100))
                        .font(.caption2)
                        .foregroundColor(Theme.ColorToken.Text.tertiary)
                }

                Spacer(minLength: 0)

                if isSuspicious {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.ColorToken.Status.warning)
                        .accessibilityLabel("自动匹配可能不准，请确认")
                }
            }

            Picker("", selection: roleKind) {
                Text("色号").tag(RoleKind.code)
                Text("任意色").tag(RoleKind.anyColor)
                Text("空").tag(RoleKind.empty)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if case .code = entry.role {
                Button(action: onPickCode) {
                    HStack {
                        Text(codeLabel)
                            .font(.footnote)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                    }
                    .foregroundColor(Theme.ColorToken.Text.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    private enum RoleKind: Hashable { case code, anyColor, empty }

    private var roleKind: Binding<RoleKind> {
        Binding(
            get: {
                switch entry.role {
                case .code: return .code
                case .anyColor: return .anyColor
                case .empty: return .empty
                }
            },
            set: { kind in
                switch kind {
                case .code:
                    // 从「空 / 任意色」切回色号时没有已知色号，先留占位，
                    // 下面那行按钮会引导用户去选。
                    if case .code = entry.role {} else { entry.role = .code("") }
                case .anyColor:
                    entry.role = .anyColor
                case .empty:
                    entry.role = .empty
                }
            }
        )
    }

    private var roleTitle: String {
        switch entry.role {
        case .code(let code):
            if code.isEmpty { return String(localized: "还没选色号") }
            if let colorName { return "\(code) · \(colorName)" }
            return code
        case .anyColor: return String(localized: "任意色")
        case .empty: return String(localized: "空（没有豆子）")
        }
    }

    private var codeLabel: String {
        if case .code(let code) = entry.role, !code.isEmpty {
            return String(localized: "换一个色号（现在是 \(code)）")
        }
        return String(localized: "选一个色号")
    }

    private var isSuspicious: Bool {
        guard case .code = entry.role, let de = entry.matchDeltaE else { return false }
        return de > suspiciousDeltaE
    }
}
