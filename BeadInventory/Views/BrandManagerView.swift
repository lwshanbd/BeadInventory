//
//  BrandManagerView.swift
//  BeadInventory
//
//  品牌管理界面
//

import SwiftUI

struct BrandManagerView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss
    @State private var showingAddBrand = false
    @State private var brandToDelete: Brand?
    @State private var brandToEdit: Brand?
    @State private var editingName = ""

    var body: some View {
        NavigationStack {
            List {
                if inventoryManager.brands.isEmpty {
                    Section {
                        VStack(spacing: 16) {
                            Image(systemName: "building.2")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)
                            Text("还没有品牌")
                                .font(.headline)
                            Text("点击下方按钮创建第一个品牌")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                    }
                }

                Section {
                    ForEach(inventoryManager.brands.sorted(by: { $0.sortOrder < $1.sortOrder })) { brand in
                        BrandRow(
                            brand: brand,
                            isSelected: brand.id == inventoryManager.currentBrandId,
                            onSelect: {
                                inventoryManager.selectBrand(brand.id)
                            }
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                brandToDelete = brand
                            } label: {
                                Label("删除", systemImage: "trash")
                            }

                            Button {
                                brandToEdit = brand
                                editingName = brand.name
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            .tint(.orange)
                        }
                    }

                    Button {
                        showingAddBrand = true
                    } label: {
                        Label("添加品牌", systemImage: "plus.circle")
                    }
                } header: {
                    if !inventoryManager.brands.isEmpty {
                        Text("品牌列表")
                    }
                }
            }
            .navigationTitle("品牌管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showingAddBrand) {
                AddBrandView()
            }
            .alert("编辑品牌", isPresented: Binding(
                get: { brandToEdit != nil },
                set: { if !$0 { brandToEdit = nil } }
            )) {
                TextField("品牌名称", text: $editingName)
                Button("取消", role: .cancel) {
                    brandToEdit = nil
                    editingName = ""
                }
                Button("保存") {
                    if let brand = brandToEdit, !editingName.trimmingCharacters(in: .whitespaces).isEmpty {
                        var updatedBrand = brand
                        updatedBrand.name = editingName.trimmingCharacters(in: .whitespaces)
                        inventoryManager.updateBrand(updatedBrand)
                    }
                    brandToEdit = nil
                    editingName = ""
                }
            } message: {
                Text("修改品牌名称")
            }
            .alert("删除品牌", isPresented: Binding(
                get: { brandToDelete != nil },
                set: { if !$0 { brandToDelete = nil } }
            )) {
                Button("取消", role: .cancel) { brandToDelete = nil }
                Button("删除", role: .destructive) {
                    if let brand = brandToDelete {
                        _ = inventoryManager.deleteBrand(brand.id)
                    }
                    brandToDelete = nil
                }
            } message: {
                Text("删除品牌将同时删除该品牌下的所有库存记录，此操作不可撤销。")
            }
        }
    }
}

struct BrandRow: View {
    let brand: Brand
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(brand.name)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text("创建于 \(brand.createdAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                        .font(.title3)
                }
            }
        }
    }
}

#Preview {
    BrandManagerView()
        .environmentObject(InventoryManager())
}
