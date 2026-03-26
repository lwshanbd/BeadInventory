//
//  AddBrandView.swift
//  BeadInventory
//
//  添加品牌视图 - 支持选择颜色模式和基础库存
//

import SwiftUI

struct AddBrandView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss

    @State private var brandName = ""
    @State private var selectedColorSystem: ColorSystem = .mard
    @State private var defaultStock = 1000
    @State private var selectedPreset: ColorPreset = .all
    @State private var customSelectedColors: Set<String> = []
    @State private var showingColorSelection = false

    // 导入库存
    @State private var showingImportStock = false
    @State private var importedStockItems: [StockImportItem] = []
    @State private var useImportedStock = false

    var allColorCount: Int {
        inventoryManager.beadColors.filter { $0.hasCode(for: selectedColorSystem) }.count
    }

    var selectedColorsCount: Int {
        if selectedPreset.isCustom {
            return customSelectedColors.count
        }
        return selectedPreset.count
    }

    var canCreate: Bool {
        let trimmedName = brandName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return false }

        if selectedPreset.isCustom {
            return !customSelectedColors.isEmpty
        }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                // 品牌信息
                Section {
                    TextField("品牌名称", text: $brandName)
                } header: {
                    Text("品牌信息")
                } footer: {
                    Text("例如：品牌名称或供应商名称")
                }

                // 色号体系
                Section {
                    Picker("色号体系", selection: $selectedColorSystem) {
                        Text(ColorSystem.mard.displayName).tag(ColorSystem.mard)
                        Text(ColorSystem.kaka.displayName).tag(ColorSystem.kaka)
                    }
                } header: {
                    Text("色号体系")
                } footer: {
                    Text("选择该品牌使用的色号编码体系，创建后不可更改。选择后全局将以该体系的色号显示。")
                }

                // 基础库存
                Section {
                    // 选择库存来源
                    Picker("库存来源", selection: $useImportedStock) {
                        Text("统一数量").tag(false)
                        Text("从 CSV 导入").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                    if useImportedStock {
                        // 导入模式
                        if importedStockItems.isEmpty {
                            Button {
                                showingImportStock = true
                            } label: {
                                HStack {
                                    Image(systemName: "doc.text")
                                    Text("选择 CSV 文件")
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        } else {
                            // 显示已导入的数据
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("已导入 \(importedStockItems.count) 种颜色")
                                        .font(.subheadline)
                                    Text("共 \(importedStockItems.reduce(0) { $0 + $1.quantity }) 颗")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("重新选择") {
                                    showingImportStock = true
                                }
                                .font(.caption)
                            }
                        }
                    } else {
                        // 统一数量模式
                        HStack {
                            Text("每色库存")
                            Spacer()
                            TextField("1000", value: $defaultStock, format: .number)
                                .keyboardType(.asciiCapableNumberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                            Text("颗")
                                .foregroundColor(.secondary)
                        }

                        // 快捷设置
                        HStack(spacing: 12) {
                            ForEach([500, 1000, 2000, 5000], id: \.self) { amount in
                                Button {
                                    defaultStock = amount
                                } label: {
                                    Text("\(amount)")
                                        .font(.caption)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(defaultStock == amount ? Color.accentColor : Color(.systemGray5))
                                        .foregroundColor(defaultStock == amount ? .white : .primary)
                                        .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("基础库存")
                } footer: {
                    if useImportedStock {
                        Text("仅导入 CSV 中的颜色，其他颜色将被隐藏")
                    } else {
                        Text("创建品牌时每种颜色的初始库存数量")
                    }
                }

                // 颜色模式（仅在统一数量模式下显示）
                if !useImportedStock {
                    Section {
                        // 非 MARD 体系只显示"全部颜色"和"自定义"，预设色号包基于 MARD 不适用
                        ForEach(ColorPreset.allCases.filter { preset in
                            selectedColorSystem == .mard || preset.isAll || preset.isCustom
                        }) { preset in
                            Button {
                                selectedPreset = preset
                                if preset.isCustom && customSelectedColors.isEmpty {
                                    customSelectedColors = Set(inventoryManager.beadColors.map { $0.mardCode })
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(preset.displayName)
                                            .foregroundColor(.primary)
                                        Text(preset.isAll ? "包含所有\(allColorCount)种颜色" : preset.description)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    if preset.isCustom {
                                        if selectedPreset.isCustom {
                                            Text("\(customSelectedColors.count) 色")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    } else {
                                        Text("\(preset.isAll ? allColorCount : preset.count) 色")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }

                                    if selectedPreset == preset {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                            }
                        }

                        // 自定义模式时显示选择按钮
                        if selectedPreset.isCustom {
                            Button {
                                showingColorSelection = true
                            } label: {
                                HStack {
                                    Image(systemName: "square.grid.3x3")
                                    Text("选择颜色")
                                    Spacer()
                                    Text("\(customSelectedColors.count) / \(inventoryManager.beadColors.count)")
                                        .foregroundColor(.secondary)
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("颜色模式")
                    } footer: {
                        Text("未选中的颜色将被隐藏，可在品牌设置中恢复")
                    }
                }
            }
            .navigationTitle("添加品牌")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        createBrand()
                    }
                    .disabled(!canCreate)
                }
            }
            .onChange(of: selectedColorSystem) { _, newSystem in
                // 切换到非 MARD 体系时，重置为"全部颜色"（预设色号包仅适用于 MARD）
                if newSystem != .mard && !selectedPreset.isAll && !selectedPreset.isCustom {
                    selectedPreset = .all
                }
            }
            .sheet(isPresented: $showingColorSelection) {
                ColorSelectionView(selectedColors: $customSelectedColors, colorSystem: selectedColorSystem)
            }
            .sheet(isPresented: $showingImportStock) {
                ImportStockView(mode: .forNewBrand) { items in
                    importedStockItems = items
                }
            }
        }
    }

    private func createBrand() {
        let trimmedName = brandName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        // 根据是否使用 CSV 导入来决定颜色和库存
        let selectedColors: Set<String>?
        let initialStock: Int

        if useImportedStock && !importedStockItems.isEmpty {
            // CSV 导入模式：只有导入的颜色可见，其他颜色隐藏且库存为 0
            selectedColors = Set(importedStockItems.map { $0.colorCode })
            initialStock = 0  // 初始化为 0，之后通过 importStock 设置实际数量
        } else {
            // 统一数量模式：按颜色预设选择
            if selectedPreset.isCustom {
                selectedColors = customSelectedColors
            } else if selectedPreset.isAll {
                selectedColors = nil // nil 表示全选所有291色
            } else {
                selectedColors = selectedPreset.colorCodes // 使用预设的色号集合
            }
            initialStock = defaultStock
        }

        let brand = inventoryManager.addBrand(
            name: trimmedName,
            colorSystem: selectedColorSystem,
            defaultStock: initialStock,
            selectedColors: selectedColors
        )

        // 如果使用 CSV 导入，设置导入的库存数量
        if useImportedStock && !importedStockItems.isEmpty {
            let items = importedStockItems.map { ($0.colorCode, $0.quantity) }
            inventoryManager.importStock(brandId: brand.id, items: items)
        }

        dismiss()
    }
}

#Preview {
    AddBrandView()
        .environmentObject(InventoryManager())
}
