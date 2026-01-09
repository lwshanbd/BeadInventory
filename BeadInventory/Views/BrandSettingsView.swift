//
//  BrandSettingsView.swift
//  BeadInventory
//
//  品牌设置视图 - 针对当前选中品牌的设置
//

import SwiftUI

struct BrandSettingsView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss

    @State private var showingResetAlert = false
    @State private var showingResetUsageAlert = false
    @State private var showingDeleteBrandAlert = false
    @State private var defaultStock = "1000"
    @State private var isEditingName = false
    @State private var editedName = ""
    @State private var showingImportStock = false
    @State private var lowStockThreshold = "100"

    var brand: Brand? {
        inventoryManager.currentBrand
    }

    var brandStockCount: Int {
        guard let brandId = inventoryManager.currentBrandId else { return 0 }
        return inventoryManager.brandStocks.filter { $0.brandId == brandId }.count
    }

    var body: some View {
        NavigationStack {
            if let brand = brand {
                List {
                    // 品牌信息
                    Section {
                        if isEditingName {
                            HStack {
                                TextField("品牌名称", text: $editedName)
                                    .textFieldStyle(.roundedBorder)

                                Button("保存") {
                                    if !editedName.isEmpty {
                                        inventoryManager.updateBrand(brand.id, name: editedName)
                                    }
                                    isEditingName = false
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        } else {
                            HStack {
                                Text("品牌名称")
                                Spacer()
                                Text(brand.name)
                                    .foregroundColor(.secondary)
                                Button {
                                    editedName = brand.name
                                    isEditingName = true
                                } label: {
                                    Image(systemName: "pencil")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }

                        HStack {
                            Text("已有库存颜色")
                            Spacer()
                            Text("\(brandStockCount) 色")
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            Text("创建时间")
                            Spacer()
                            Text(brand.createdAt.formatted(date: .abbreviated, time: .omitted))
                                .foregroundColor(.secondary)
                        }
                    } header: {
                        Text("品牌信息")
                    }

                    // 低库存设置
                    Section {
                        HStack {
                            Text("低库存阈值")
                            Spacer()
                            TextField("100", text: $lowStockThreshold)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                                .onChange(of: lowStockThreshold) { _, newValue in
                                    if let threshold = Int(newValue), threshold >= 0 {
                                        inventoryManager.updateBrandLowStockThreshold(brand.id, threshold: threshold)
                                    }
                                }
                            Text("颗")
                                .foregroundColor(.secondary)
                        }
                    } header: {
                        Text("库存提醒")
                    } footer: {
                        Text("当库存低于此阈值时，会在库存列表中以红色标识提醒。")
                    }

                    // 库存操作
                    Section {
                        Button {
                            showingImportStock = true
                        } label: {
                            HStack {
                                Image(systemName: "square.and.arrow.down")
                                Text("导入库存")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        HStack {
                            Text("重置库存数量")
                            Spacer()
                            TextField("1000", text: $defaultStock)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                        }

                        Button {
                            showingResetAlert = true
                        } label: {
                            HStack {
                                Image(systemName: "arrow.counterclockwise")
                                Text("重置所有库存")
                            }
                            .foregroundColor(.orange)
                        }

                        Button {
                            showingResetUsageAlert = true
                        } label: {
                            HStack {
                                Image(systemName: "xmark.circle")
                                Text("清除使用记录")
                            }
                            .foregroundColor(.red)
                        }
                    } header: {
                        Text("库存操作")
                    } footer: {
                        Text("导入库存会累加到现有库存。重置库存会将所有颜色的库存设为指定数量并清零使用记录。")
                    }

                    // 色号管理
                    Section {
                        NavigationLink {
                            HiddenColorsManageView()
                        } label: {
                            HStack {
                                Image(systemName: "eye.slash")
                                Text("隐藏色号管理")
                                Spacer()
                                if let brandId = inventoryManager.currentBrandId {
                                    let count = inventoryManager.hiddenColorCount(for: brandId)
                                    if count > 0 {
                                        Text("\(count) 个")
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("色号管理")
                    } footer: {
                        Text("隐藏不需要的色号，它们不会出现在库存列表和低库存提醒中。")
                    }

                    // 危险操作
                    Section {
                        Button {
                            showingDeleteBrandAlert = true
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text("删除此品牌")
                            }
                            .foregroundColor(.red)
                        }
                    } header: {
                        Text("危险操作")
                    } footer: {
                        Text("删除品牌将同时删除该品牌下的所有库存数据，此操作不可撤销。")
                    }
                }
                .navigationTitle("\(brand.name) 设置")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { dismiss() }
                    }
                }
                .alert("重置库存", isPresented: $showingResetAlert) {
                    Button("取消", role: .cancel) { }
                    Button("重置", role: .destructive) {
                        let stock = Int(defaultStock) ?? 1000
                        inventoryManager.resetAllStock(to: stock)
                    }
                } message: {
                    Text("将「\(brand.name)」所有颜色的库存重置为 \(defaultStock) 颗，使用记录也将清零。此操作不可撤销。")
                }
                .alert("清除使用记录", isPresented: $showingResetUsageAlert) {
                    Button("取消", role: .cancel) { }
                    Button("清除", role: .destructive) {
                        inventoryManager.resetUsage()
                    }
                } message: {
                    Text("将清除「\(brand.name)」所有颜色的使用记录，库存数量不变。此操作不可撤销。")
                }
                .alert("删除品牌", isPresented: $showingDeleteBrandAlert) {
                    Button("取消", role: .cancel) { }
                    Button("删除", role: .destructive) {
                        _ = inventoryManager.deleteBrand(brand.id)
                        dismiss()
                    }
                } message: {
                    Text("确定要删除「\(brand.name)」吗？该品牌下的所有库存数据将被永久删除。")
                }
                .sheet(isPresented: $showingImportStock) {
                    ImportStockView(mode: .forExistingBrand(brand.id))
                }
                .onAppear {
                    lowStockThreshold = "\(brand.lowStockThreshold)"
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "building.2")
                        .font(.system(size: 50))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("请先选择品牌")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .navigationTitle("品牌设置")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { dismiss() }
                    }
                }
            }
        }
    }
}

#Preview {
    BrandSettingsView()
        .environmentObject(InventoryManager())
}
