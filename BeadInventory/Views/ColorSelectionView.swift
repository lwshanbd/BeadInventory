//
//  ColorSelectionView.swift
//  BeadInventory
//
//  颜色选择视图 - 用于自定义选择品牌颜色
//

import SwiftUI

struct ColorSelectionView: View {
    /// 列表怎么铺：品牌管理那边选一批颜色建品牌，认名字比认色块更要紧，用一行一个的老样子；
    /// 拼图模式核对/改色号，图上格子挨得密，用户要的是一眼扫过去比色块，改成网格更省地方。
    enum Layout {
        case list
        case grid
    }

    @Binding var selectedColors: Set<String>
    var colorSystem: ColorSystem = .mard
    /// 优先列在最上面的一组颜色。多零件模式核对颜色时传进来的是
    /// **上一步 AI 读图纸色号表得出的、这张图确实用到的那十几个色号**。
    ///
    /// 判色一定会判错，而用户要改成的那个正确色号，几乎一定就在图纸自己的色号表里 ——
    /// 让他从这十几个里挑，而不是在四百多个色号里翻着找。
    /// 空数组时列表跟平常完全一样。
    var suggestedColors: [BeadColor] = []
    /// 打开时定位到哪个色号所在的系列。上面那组里没有要找的色号时
    /// （AI 连色号表都读漏了），从当前色号的邻居开始翻最省事。
    var focusColor: BeadColor? = nil
    var layout: Layout = .list
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss

    // 色系列表和标准前缀从 ColorSystem 获取
    var colorSeries: [String] { colorSystem.colorSeries }
    var standardPrefixes: [String] { colorSystem.standardPrefixes }

    @State private var selectedSeries: String

    init(selectedColors: Binding<Set<String>>,
         colorSystem: ColorSystem = .mard,
         suggestedColors: [BeadColor] = [],
         focusColor: BeadColor? = nil,
         layout: Layout = .list) {
        self._selectedColors = selectedColors
        self.colorSystem = colorSystem
        self.suggestedColors = suggestedColors
        self.focusColor = focusColor
        self.layout = layout
        let initial = focusColor.map { Self.series(for: $0, in: colorSystem) } ?? colorSystem.defaultSeries
        self._selectedSeries = State(initialValue: initial)
    }

    /// 上面那组实际画出来的几行：去重，并且只留在当前体系里有码的
    /// （查不到码的画出来是一行没有色号的空壳）。
    private var suggestions: [BeadColor] {
        var seen = Set<String>()
        return suggestedColors.filter { color in
            guard color.hasCode(for: colorSystem) else { return false }
            return seen.insert(color.mardCode).inserted
        }
    }

    /// 一个颜色属于系列选择器里的哪一系。纯函数（只看色号本身），
    /// 逻辑跟 `colorsInSeries` 的过滤保持一致，所以能在 init 里就算出来。
    private static func series(for color: BeadColor, in system: ColorSystem) -> String {
        if color.mardCode.hasPrefix("#") { return "#" }
        let code = color.displayCode(for: system)
        if code.hasPrefix("ZG") { return "ZG" }
        for prefix in system.standardPrefixes where prefix != "ZG" {
            if code.hasPrefix(prefix) { return prefix }
        }
        return "其他"
    }

    /// 当前色号体系下的颜色总数
    var totalColorsForSystem: Int {
        inventoryManager.beadColors.filter { $0.hasCode(for: colorSystem) }.count
    }

    var colorsInSeries: [BeadColor] {
        // 自定义色号使用 allBeadColors
        let sourceColors = selectedSeries == "#" ? inventoryManager.allBeadColors : inventoryManager.beadColors

        return sourceColors.filter { color in
            // 只显示属于当前色号体系的颜色
            guard color.hasCode(for: colorSystem) else { return false }

            // 使用当前体系的色号进行系列匹配
            let code = color.displayCode(for: colorSystem)

            if selectedSeries == "#" {
                // 自定义色号始终用 mardCode 判断（自定义色号 mardCode 以 # 开头）
                return color.mardCode.hasPrefix("#")
            } else if selectedSeries == "其他" {
                // "其他"系列：不属于任何标准色系的颜色（排除自定义色号）
                if color.mardCode.hasPrefix("#") { return false }
                return !standardPrefixes.contains { prefix in
                    if prefix == "ZG" {
                        return code.hasPrefix("ZG")
                    } else {
                        return code.hasPrefix(prefix) && !code.hasPrefix("ZG")
                    }
                }
            } else if selectedSeries == "ZG" {
                return code.hasPrefix("ZG")
            } else {
                if code.hasPrefix("ZG") { return false }
                if color.mardCode.hasPrefix("#") { return false }  // 排除自定义色号
                return code.hasPrefix(selectedSeries)
            }
        }.sorted { $0.displayCode(for: colorSystem).localizedStandardCompare($1.displayCode(for: colorSystem)) == .orderedAscending }
    }

    // 当前色系的选中数量
    var selectedInSeriesCount: Int {
        colorsInSeries.filter { selectedColors.contains($0.mardCode) }.count
    }

    // 当前色系是否全选
    var isAllSelectedInSeries: Bool {
        !colorsInSeries.isEmpty && selectedInSeriesCount == colorsInSeries.count
    }

    private let gridColumns = [GridItem(.adaptive(minimum: 72, maximum: 90), spacing: 10)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部统计
                HStack {
                    Text("已选择")
                        .foregroundColor(.secondary)
                    Text("\(selectedColors.count)")
                        .fontWeight(.bold)
                        .foregroundColor(Theme.ColorToken.Morandi.latte)
                    Text("/ \(totalColorsForSystem) 色")
                        .foregroundColor(.secondary)
                    Spacer()

                    // 快速选择菜单
                    Menu {
                        Button {
                            selectAll()
                        } label: {
                            Label("全选所有 (\(totalColorsForSystem)色)", systemImage: "checkmark.circle.fill")
                        }

                        Button {
                            selectedColors.removeAll()
                        } label: {
                            Label("全部取消", systemImage: "circle")
                        }

                        Divider()

                        // 预设颜色一键选中
                        Section("预设颜色包") {
                            ForEach(ColorPreset.allCases.filter { !$0.isCustom && !$0.isAll }) { preset in
                                Button {
                                    selectPreset(preset)
                                } label: {
                                    Label("选中 \(preset.count) 色", systemImage: "checkmark.square.fill")
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                            Text("快速选择")
                        }
                        .font(.subheadline)
                    }
                }
                .font(.subheadline)
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(Theme.ColorToken.Surface.subtle)

                // 色系选择器
                SeriesSelector(
                    series: colorSeries,
                    selectedSeries: $selectedSeries
                )
                .padding(.vertical, 8)

                // 颜色列表
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // 这张图纸自己用到的那几个色号排在最前面。判色判错时要改成的
                        // 那一个基本都在这里 —— 不管现在切到哪个系列都一直留着，
                        // 用户翻到别的系列时也不用滚回来找。
                        if !suggestions.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles")
                                    .font(.caption)
                                Text("AI 识别的颜色")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text("这张图纸用到的 \(suggestions.count) 色")
                                    .font(.caption)
                                Spacer()
                            }
                            .foregroundColor(Theme.ColorToken.Text.secondary)

                            colorGroup(suggestions)

                            Divider()
                        }

                        // 上面列过的不再重复一遍
                        let shown = Set(suggestions.map(\.mardCode))
                        colorGroup(colorsInSeries.filter { !shown.contains($0.mardCode) })
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 20)
                }
            }
            .background(Theme.ColorToken.Surface.background)
            .navigationTitle("选择颜色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(isAllSelectedInSeries ? "取消本系" : "全选本系") {
                        if isAllSelectedInSeries {
                            deselectAllInSeries()
                        } else {
                            selectAllInSeries()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func selectAll() {
        for color in inventoryManager.beadColors where color.hasCode(for: colorSystem) {
            selectedColors.insert(color.mardCode)
        }
    }

    private func selectAllInSeries() {
        for color in colorsInSeries {
            selectedColors.insert(color.mardCode)
        }
    }

    private func deselectAllInSeries() {
        for color in colorsInSeries {
            selectedColors.remove(color.mardCode)
        }
    }

    private func selectPreset(_ preset: ColorPreset) {
        if let colors = preset.colorCodes {
            selectedColors = colors
        } else {
            selectAll()
        }
    }

    private func toggleColor(_ mardCode: String) {
        if selectedColors.contains(mardCode) {
            selectedColors.remove(mardCode)
        } else {
            selectedColors.insert(mardCode)
        }
    }

    @ViewBuilder
    private func colorGroup(_ colors: [BeadColor]) -> some View {
        switch layout {
        case .list:
            VStack(spacing: 8) {
                ForEach(colors) { color in
                    ColorSelectRow(
                        color: color,
                        colorSystem: colorSystem,
                        isSelected: selectedColors.contains(color.mardCode),
                        onToggle: { toggleColor(color.mardCode) }
                    )
                }
            }
        case .grid:
            LazyVGrid(columns: gridColumns, spacing: 10) {
                ForEach(colors) { color in
                    ColorSelectCell(
                        color: color,
                        colorSystem: colorSystem,
                        isSelected: selectedColors.contains(color.mardCode),
                        onToggle: { toggleColor(color.mardCode) }
                    )
                }
            }
        }
    }
}

// MARK: - 颜色选择行

struct ColorSelectRow: View {
    let color: BeadColor
    var colorSystem: ColorSystem = .mard
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                // 选择按钮
                ZStack {
                    Circle()
                        .stroke(isSelected ? Theme.ColorToken.Morandi.latte : Theme.ColorToken.Border.default, lineWidth: 2)
                        .frame(width: 28, height: 28)

                    if isSelected {
                        Circle()
                            .fill(Theme.ColorToken.Morandi.latte)
                            .frame(width: 20, height: 20)

                        Image(systemName: "checkmark")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                    }
                }

                // 颜色预览
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(color.color)
                    .frame(width: 40, height: 40)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
                    )

                // 色号和名称
                VStack(alignment: .leading, spacing: 2) {
                    Text(color.displayCode(for: colorSystem))
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)
                        .foregroundColor(.primary)

                    Text(color.colorName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // 选中标记
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Theme.ColorToken.Morandi.latte)
                        .font(.title3)
                }
            }
            .padding(12)
            .background(isSelected ? Theme.ColorToken.Morandi.latte.opacity(0.08) : Theme.ColorToken.Surface.elevated)
            .cornerRadius(Theme.Radius.md)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - 颜色选择格

struct ColorSelectCell: View {
    let color: BeadColor
    var colorSystem: ColorSystem = .mard
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .fill(color.color)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                            .stroke(
                                isSelected ? Theme.ColorToken.Morandi.latte : Theme.ColorToken.Border.default,
                                lineWidth: isSelected ? 3 : 1
                            )
                    )
                    .overlay(alignment: .topTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Theme.ColorToken.Morandi.latte)
                                .padding(3)
                        }
                    }

                Text(color.displayCode(for: colorSystem))
                    .font(.caption2.monospacedDigit())
                    .fontWeight(.medium)
                    .foregroundColor(isSelected ? Theme.ColorToken.Morandi.latte : Theme.ColorToken.Text.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ColorSelectionView(selectedColors: .constant(Set(["A1", "A2", "A3"])))
        .environmentObject(InventoryManager())
}
