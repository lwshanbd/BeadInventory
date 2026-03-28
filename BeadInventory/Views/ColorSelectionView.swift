//
//  ColorSelectionView.swift
//  BeadInventory
//
//  颜色选择视图 - 用于自定义选择品牌颜色
//

import SwiftUI

struct ColorSelectionView: View {
    @Binding var selectedColors: Set<String>
    var colorSystem: ColorSystem = .mard
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss

    // 色系列表和标准前缀从 ColorSystem 获取
    var colorSeries: [String] { colorSystem.colorSeries }
    var standardPrefixes: [String] { colorSystem.standardPrefixes }

    @State private var selectedSeries: String

    init(selectedColors: Binding<Set<String>>, colorSystem: ColorSystem = .mard) {
        self._selectedColors = selectedColors
        self.colorSystem = colorSystem
        self._selectedSeries = State(initialValue: colorSystem.defaultSeries)
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部统计
                HStack {
                    Text("已选择")
                        .foregroundColor(.secondary)
                    Text("\(selectedColors.count)")
                        .fontWeight(.bold)
                        .foregroundColor(.accentColor)
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
                .background(Color(.systemGray6))

                // 色系选择器
                SeriesSelector(
                    series: colorSeries,
                    selectedSeries: $selectedSeries
                )
                .padding(.vertical, 8)

                // 颜色列表
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(colorsInSeries) { color in
                            ColorSelectRow(
                                color: color,
                                colorSystem: colorSystem,
                                isSelected: selectedColors.contains(color.mardCode),
                                onToggle: {
                                    toggleColor(color.mardCode)
                                }
                            )
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 20)
                }
            }
            .background(Color(.systemGroupedBackground))
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
                        .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: 2)
                        .frame(width: 28, height: 28)

                    if isSelected {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 20, height: 20)

                        Image(systemName: "checkmark")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                    }
                }

                // 颜色预览
                RoundedRectangle(cornerRadius: 6)
                    .fill(color.color)
                    .frame(width: 40, height: 40)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
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
                        .foregroundColor(.accentColor)
                        .font(.title3)
                }
            }
            .padding(12)
            .background(isSelected ? Color.accentColor.opacity(0.08) : Color(.systemBackground))
            .cornerRadius(12)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

#Preview {
    ColorSelectionView(selectedColors: .constant(Set(["A1", "A2", "A3"])))
        .environmentObject(InventoryManager())
}
