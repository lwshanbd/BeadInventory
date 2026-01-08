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
    @State private var searchText = ""

    var filteredColors: [BeadColor] {
        if searchText.isEmpty {
            return inventoryManager.beadColors.sorted { $0.mardCode.localizedStandardCompare($1.mardCode) == .orderedAscending }
        }
        return inventoryManager.searchColors(searchText).sorted { $0.mardCode.localizedStandardCompare($1.mardCode) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部统计和快速选择
                HStack {
                    Text("已选 \(selectedColors.count) / \(inventoryManager.beadColors.count) 色")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Spacer()

                    Menu {
                        Button {
                            selectAll()
                        } label: {
                            Label("全选", systemImage: "checkmark.circle.fill")
                        }

                        Button {
                            selectedColors.removeAll()
                        } label: {
                            Label("全不选", systemImage: "circle")
                        }

                        Divider()

                        ForEach(ColorPreset.allCases.filter { !$0.isCustom && !$0.isAll }) { preset in
                            Button {
                                selectPreset(preset)
                            } label: {
                                Label("\(preset.rawValue) (\(preset.count)色)", systemImage: "square.grid.2x2")
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
                .padding(.horizontal)
                .padding(.vertical, 12)
                .background(Color(.systemGroupedBackground))

                // 颜色网格
                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 12) {
                        ForEach(filteredColors) { color in
                            SelectableColorCard(
                                color: color,
                                isSelected: selectedColors.contains(color.mardCode),
                                onToggle: { toggleColor(color.mardCode) }
                            )
                        }
                    }
                    .padding()
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("选择颜色")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索色号或名称")
            .toolbar {
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

    private func selectPreset(_ preset: ColorPreset) {
        if let colors = preset.colorCodes {
            selectedColors = colors
        } else {
            // 如果是全选模式，选中所有颜色
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

// MARK: - 可选择的颜色卡片
struct SelectableColorCard: View {
    let color: BeadColor
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                // 颜色块
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.color)
                    .frame(height: 50)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: isSelected ? 2 : 1)
                    )

                // 选中标记
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                        .background(Circle().fill(.white))
                        .offset(x: 4, y: -4)
                }
            }

            // 色号
            Text(color.mardCode)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)

            // 颜色名称
            Text(color.colorName)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
        .onTapGesture {
            onToggle()
        }
    }
}

#Preview {
    ColorSelectionView(selectedColors: .constant(Set(["A1", "A2", "A3"])))
        .environmentObject(InventoryManager())
}
