//
//  ColorSelectionView.swift
//  BeadInventory
//
//  颜色选择视图 - 用于自定义选择品牌颜色
//

import SwiftUI

struct ColorSelectionView: View {
    @Binding var selectedColors: Set<String>
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss

    // 色系列表
    let colorSeries = ["A", "B", "C", "D", "E", "F", "G", "H", "M", "P", "Q", "R", "T", "Y", "ZG", "其他"]
    let standardPrefixes = ["A", "B", "C", "D", "E", "F", "G", "H", "M", "P", "Q", "R", "T", "Y", "ZG"]

    @State private var selectedSeries = "A"

    var colorsInSeries: [BeadColor] {
        inventoryManager.beadColors.filter { color in
            let code = color.mardCode

            if selectedSeries == "其他" {
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
                return code.hasPrefix(selectedSeries)
            }
        }.sorted { $0.mardCode.localizedStandardCompare($1.mardCode) == .orderedAscending }
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
                    Text("/ \(inventoryManager.beadColors.count) 色")
                        .foregroundColor(.secondary)
                    Spacer()

                    // 快速选择菜单
                    Menu {
                        Button {
                            selectAll()
                        } label: {
                            Label("全选所有 (\(inventoryManager.beadColors.count)色)", systemImage: "checkmark.circle.fill")
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
        for color in inventoryManager.beadColors {
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
                    Text(color.mardCode)
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
