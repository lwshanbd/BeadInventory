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

    var currentSystem: ColorSystem { inventoryManager.currentColorSystem }

    @State private var selectedSeries = "A"
    @State private var selectedColors: Set<UUID> = []
    @State private var quantities: [UUID: Double] = [:]  // 数量（单位：千颗）
    @State private var showingImportStock = false

    var colorsInSeries: [BeadColor] {
        // 自定义色号使用 allBeadColors
        let sourceColors = selectedSeries == "#" ? inventoryManager.allBeadColors : inventoryManager.beadColors
        let system = currentSystem
        let prefixes = system.standardPrefixes

        return sourceColors.filter { color in
            // 非 MARD 体系下仅显示有对应色号的颜色
            if system != .mard && !color.hasCode(for: system) {
                return false
            }

            let code = color.displayCode(for: system)

            if selectedSeries == "#" {
                return code.hasPrefix("#")
            } else if selectedSeries == "其他" {
                if code.hasPrefix("#") { return false }
                return !prefixes.contains { prefix in
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
        }.sorted { $0.displayCode(for: system).localizedStandardCompare($1.displayCode(for: system)) == .orderedAscending }
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
                // 显示当前品牌
                if let brandName = inventoryManager.currentBrand?.name {
                    HStack {
                        Text("为品牌")
                            .foregroundColor(.secondary)
                        Text(brandName)
                            .fontWeight(.bold)
                            .foregroundColor(.accentColor)
                        Text("增加库存")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .font(.subheadline)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))
                }

                // 色系选择器
                SeriesSelector(
                    series: currentSystem.colorSeries,
                    selectedSeries: $selectedSeries
                )
                .padding(.vertical, 8)

                // 颜色列表
                ScrollView {
                    VStack(spacing: 8) {
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
                .scrollDismissesKeyboard(.immediately)
                .onTapGesture {
                    // 点击空白区域收起键盘
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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
                    Menu {
                        Button {
                            selectAllInSeries()
                        } label: {
                            Label("全选本色系", systemImage: "checkmark.circle")
                        }

                        Button {
                            selectAllColors()
                        } label: {
                            Label("全选所有 (\(inventoryManager.allBeadColors.count)色)", systemImage: "checkmark.circle.fill")
                        }

                        Button {
                            selectedColors.removeAll()
                        } label: {
                            Label("全部取消", systemImage: "circle")
                        }

                        Divider()

                        Section("预设颜色包") {
                            ForEach(ColorPreset.allCases.filter { !$0.isCustom && !$0.isAll }) { preset in
                                Button {
                                    selectPreset(preset)
                                } label: {
                                    Label("选中 \(preset.count) 色", systemImage: "checkmark.square.fill")
                                }
                            }
                        }

                        Divider()

                        Button {
                            showingImportStock = true
                        } label: {
                            Label("从 CSV 导入", systemImage: "doc.text")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("快速选择")
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                    }
                }
            }
            .sheet(isPresented: $showingImportStock) {
                if let brandId = inventoryManager.currentBrandId {
                    ImportStockView(mode: .forExistingBrand(brandId))
                }
            }
            .onAppear {
                selectedSeries = currentSystem.defaultSeries
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

    func selectAllColors() {
        for color in inventoryManager.allBeadColors {
            selectedColors.insert(color.id)
            if quantities[color.id] == nil {
                quantities[color.id] = 1.0
            }
        }
    }

    func selectPreset(_ preset: ColorPreset) {
        // 先清空选择
        selectedColors.removeAll()

        // 获取预设的色号集合
        guard let presetCodes = preset.colorCodes else { return }

        // 选中预设中的颜色
        for color in inventoryManager.beadColors {
            if presetCodes.contains(color.mardCode) {
                selectedColors.insert(color.id)
                if quantities[color.id] == nil {
                    quantities[color.id] = 1.0
                }
            }
        }
    }

    func confirmAddStock() {
        guard let brandId = inventoryManager.currentBrandId else { return }
        for colorId in selectedColors {
            guard let color = inventoryManager.allBeadColors.first(where: { $0.id == colorId }) else { continue }
            let qty = quantities[colorId] ?? 1.0
            let amount = Int(qty * 1000)
            inventoryManager.addStock(brandId: brandId, mardCode: color.mardCode, amount: amount)
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
    var colorSystem: ColorSystem? = nil
    @EnvironmentObject var inventoryManager: InventoryManager

    private var displaySystem: ColorSystem {
        colorSystem ?? inventoryManager.currentColorSystem
    }

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
            Text(color.displayCode(for: displaySystem))
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)

            Spacer()

            // 数量控制（仅在选中时显示）
            if isSelected {
                QuantityControl(quantity: $quantity)
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
    @State private var editText: String = ""
    @FocusState private var isFocused: Bool

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
                    editText = displayText
                }
            } label: {
                Image(systemName: "minus")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(quantity > 0.5 ? Color.gray.opacity(0.6) : Color.gray.opacity(0.3))
                    .cornerRadius(14)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(quantity <= 0.5)

            // 数量输入框
            TextField("", text: $editText)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
                .font(.system(size: 16, weight: .regular, design: .monospaced))
                .frame(width: 60, height: 32)
                .background(Color(.systemGray6))
                .cornerRadius(8)
                .focused($isFocused)
                .onChange(of: editText) { _, newValue in
                    // 过滤只允许数字和小数点
                    let filtered = newValue.filter { $0.isNumber || $0 == "." }
                    if filtered != newValue {
                        editText = filtered
                    }
                    if let value = Double(filtered), value > 0 {
                        quantity = value
                    }
                }

            // 增加按钮
            Button {
                if quantity == Double(Int(quantity)) {
                    quantity += 1
                } else {
                    quantity = ceil(quantity)
                }
                editText = displayText
            } label: {
                Image(systemName: "plus")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor)
                    .cornerRadius(14)
            }
            .buttonStyle(PlainButtonStyle())

            // 单位标签
            Text("×1000")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .onAppear {
            editText = displayText
        }
        .onChange(of: quantity) { _, newValue in
            // 只有在非编辑状态下才更新文本，避免干扰用户输入
            if !isFocused {
                editText = displayText
            }
        }
        .onChange(of: isFocused) { _, focused in
            // 失去焦点时，验证并格式化输入
            if !focused {
                if let value = Double(editText), value > 0 {
                    quantity = max(0.5, value)
                }
                editText = displayText
            }
        }
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
