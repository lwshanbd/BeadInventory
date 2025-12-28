//
//  AddInventoryView.swift
//  BeadInventory
//
//  增加库存界面
//

import SwiftUI

struct AddInventoryView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss

    // 色系列表
    let colorSeries = ["A", "B", "C", "D", "E", "F", "G", "H", "M", "P", "Q", "R", "T", "Y", "ZG"]

    @State private var selectedSeries = "A"
    @State private var selectedColors: Set<UUID> = []
    @State private var quantities: [UUID: Double] = [:]  // 数量（单位：千颗）

    var colorsInSeries: [BeadColor] {
        inventoryManager.beadColors.filter { color in
            if selectedSeries == "ZG" {
                return color.mardCode.hasPrefix("ZG")
            } else {
                // 确保不匹配 ZG 系列
                let code = color.mardCode
                if code.hasPrefix("ZG") { return false }
                return code.hasPrefix(selectedSeries)
            }
        }.sorted { $0.mardCode.localizedStandardCompare($1.mardCode) == .orderedAscending }
    }

    var totalToAdd: Int {
        var total = 0
        for colorId in selectedColors {
            let qty = quantities[colorId] ?? 1.0
            total += Int(qty * 1000)
        }
        return total
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
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
                            ColorAddRow(
                                color: color,
                                isSelected: selectedColors.contains(color.id),
                                quantity: Binding(
                                    get: { quantities[color.id] ?? 1.0 },
                                    set: { quantities[color.id] = $0 }
                                ),
                                onToggle: {
                                    toggleSelection(color.id)
                                }
                            )
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 100)
                }

                // 底部确认栏
                if !selectedColors.isEmpty {
                    ConfirmBar(
                        selectedCount: selectedColors.count,
                        totalToAdd: totalToAdd,
                        onConfirm: confirmAddStock
                    )
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("增加库存")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("全选") {
                        selectAllInSeries()
                    }
                }
            }
        }
    }

    func toggleSelection(_ colorId: UUID) {
        if selectedColors.contains(colorId) {
            selectedColors.remove(colorId)
        } else {
            selectedColors.insert(colorId)
            // 默认数量为1（即1000颗）
            if quantities[colorId] == nil {
                quantities[colorId] = 1.0
            }
        }
    }

    func selectAllInSeries() {
        for color in colorsInSeries {
            selectedColors.insert(color.id)
            if quantities[color.id] == nil {
                quantities[color.id] = 1.0
            }
        }
    }

    func confirmAddStock() {
        for colorId in selectedColors {
            let qty = quantities[colorId] ?? 1.0
            let amount = Int(qty * 1000)
            inventoryManager.addStock(for: colorId, amount: amount)
        }
        dismiss()
    }
}

// MARK: - 色系选择器
struct SeriesSelector: View {
    let series: [String]
    @Binding var selectedSeries: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(series, id: \.self) { s in
                    Button {
                        withAnimation { selectedSeries = s }
                    } label: {
                        Text(s)
                            .font(.system(.subheadline, design: .rounded))
                            .fontWeight(.medium)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(selectedSeries == s ? Color.accentColor : Color(.systemGray5))
                            .foregroundColor(selectedSeries == s ? .white : .primary)
                            .cornerRadius(20)
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}

// MARK: - 颜色添加行
struct ColorAddRow: View {
    let color: BeadColor
    let isSelected: Bool
    @Binding var quantity: Double
    let onToggle: () -> Void

    @State private var isEditing = false
    @State private var editText = ""

    var body: some View {
        HStack(spacing: 12) {
            // 选择按钮
            Button(action: onToggle) {
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
            }

            // 颜色预览
            RoundedRectangle(cornerRadius: 6)
                .fill(color.color)
                .frame(width: 40, height: 40)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )

            // 色号
            Text(color.mardCode)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)

            Spacer()

            // 数量控制（仅在选中时显示）
            if isSelected {
                QuantityControl(
                    quantity: $quantity,
                    isEditing: $isEditing,
                    editText: $editText
                )
            }
        }
        .padding(12)
        .background(Color(.systemBackground))
        .cornerRadius(12)
    }
}

// MARK: - 数量控制器
struct QuantityControl: View {
    @Binding var quantity: Double
    @Binding var isEditing: Bool
    @Binding var editText: String

    var displayText: String {
        if quantity == Double(Int(quantity)) {
            return "\(Int(quantity))"
        } else {
            return String(format: "%.1f", quantity)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            // 减少按钮
            Button {
                if quantity > 0.5 {
                    quantity -= 1
                    if quantity < 0.5 { quantity = 0.5 }
                }
            } label: {
                Image(systemName: "minus")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.gray.opacity(0.6))
                    .cornerRadius(14)
            }

            // 数量显示/输入
            if isEditing {
                TextField("", text: $editText)
                    .font(.system(.body, design: .monospaced))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .frame(width: 60)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                    .onSubmit {
                        finishEditing()
                    }
            } else {
                Button {
                    editText = displayText
                    isEditing = true
                } label: {
                    HStack(spacing: 2) {
                        Text(displayText)
                            .font(.system(.body, design: .monospaced))
                            .fontWeight(.medium)
                        Text("×1000")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                }
                .foregroundColor(.primary)
            }

            // 增加按钮
            Button {
                quantity += 1
            } label: {
                Image(systemName: "plus")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor)
                    .cornerRadius(14)
            }
        }
        .onChange(of: isEditing) { _, newValue in
            if !newValue {
                finishEditing()
            }
        }
    }

    func finishEditing() {
        if let value = Double(editText), value > 0 {
            quantity = value
        }
        isEditing = false
    }
}

// MARK: - 确认栏
struct ConfirmBar: View {
    let selectedCount: Int
    let totalToAdd: Int
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("已选择 \(selectedCount) 色")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("共 +\(formatNumber(totalToAdd)) 颗")
                        .font(.headline)
                        .foregroundColor(.accentColor)
                }

                Spacer()

                Button(action: onConfirm) {
                    Text("确认添加")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.accentColor)
                        .cornerRadius(24)
                }
            }
            .padding()
            .background(Color(.systemBackground))
        }
    }

    func formatNumber(_ num: Int) -> String {
        if num >= 10000 {
            return String(format: "%.1fW", Double(num) / 10000)
        } else if num >= 1000 {
            return String(format: "%.1fK", Double(num) / 1000)
        }
        return "\(num)"
    }
}

#Preview {
    AddInventoryView()
        .environmentObject(InventoryManager())
}
