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
    @State private var defaultStock = 1000
    @State private var selectedPreset: ColorPreset = .all
    @State private var customSelectedColors: Set<String> = []
    @State private var showingColorSelection = false

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

                // 基础库存
                Section {
                    HStack {
                        Text("每色库存")
                        Spacer()
                        TextField("1000", value: $defaultStock, format: .number)
                            .keyboardType(.numberPad)
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
                } header: {
                    Text("基础库存")
                } footer: {
                    Text("创建品牌时每种颜色的初始库存数量")
                }

                // 颜色模式
                Section {
                    ForEach(ColorPreset.allCases) { preset in
                        Button {
                            selectedPreset = preset
                            if preset.isCustom && customSelectedColors.isEmpty {
                                // 自定义模式默认选中全部 291 色
                                customSelectedColors = Set(inventoryManager.beadColors.map { $0.mardCode })
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(preset.rawValue)
                                        .foregroundColor(.primary)
                                    Text(preset.description)
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
                                    Text("\(preset.count) 色")
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
            .sheet(isPresented: $showingColorSelection) {
                ColorSelectionView(selectedColors: $customSelectedColors)
            }
        }
    }

    private func createBrand() {
        let trimmedName = brandName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        let selectedColors: Set<String>?
        if selectedPreset.isCustom {
            selectedColors = customSelectedColors
        } else if selectedPreset.isAll {
            selectedColors = nil // nil 表示全选所有291色
        } else {
            selectedColors = selectedPreset.colorCodes // 使用预设的色号集合
        }

        inventoryManager.addBrand(
            name: trimmedName,
            defaultStock: defaultStock,
            selectedColors: selectedColors
        )

        dismiss()
    }
}

#Preview {
    AddBrandView()
        .environmentObject(InventoryManager())
}
