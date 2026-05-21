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
    @State private var showingMergeBrand = false

    var body: some View {
        NavigationStack {
            List {
                if inventoryManager.brands.isEmpty {
                    Section {
                        EmptyStateView(
                            icon: "tag.slash",
                            title: "还没有品牌",
                            description: "点击右上角添加你的第一个品牌"
                        )
                        .padding(.vertical, 16)
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
                            .tint(Theme.ColorToken.Status.warning)
                        }
                    }

                    Button {
                        showingAddBrand = true
                    } label: {
                        Label("添加品牌", systemImage: "plus.circle")
                    }

                    if inventoryManager.brands.count >= 2 {
                        Button {
                            showingMergeBrand = true
                        } label: {
                            Label("合并品牌", systemImage: "arrow.triangle.merge")
                        }
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
            .sheet(isPresented: $showingMergeBrand) {
                MergeBrandSheet()
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

// MARK: - 合并品牌 Sheet
struct MergeBrandSheet: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss

    @State private var sourceBrandId: UUID?
    @State private var targetBrandId: UUID?
    @State private var showingConfirmation = false

    private var sortedBrands: [Brand] {
        inventoryManager.brands.sorted(by: { $0.sortOrder < $1.sortOrder })
    }

    private var sourceBrand: Brand? {
        guard let id = sourceBrandId else { return nil }
        return inventoryManager.brands.first { $0.id == id }
    }

    private var targetBrand: Brand? {
        guard let id = targetBrandId else { return nil }
        return inventoryManager.brands.first { $0.id == id }
    }

    /// 源品牌的库存记录数（非隐藏且有库存的色号数）
    private var sourceStockCount: Int {
        guard let id = sourceBrandId else { return 0 }
        return inventoryManager.brandStocks.filter {
            $0.brandId == id && ($0.stock > 0 || $0.used > 0)
        }.count
    }

    /// 受影响的项目数
    private var affectedProjectCount: Int {
        guard let id = sourceBrandId else { return 0 }
        return inventoryManager.projects.filter { $0.brandId == id }.count
    }

    /// 受影响的购买记录数
    private var affectedPurchaseCount: Int {
        guard let id = sourceBrandId else { return 0 }
        return inventoryManager.purchaseRecords.filter { $0.brandId == id }.count
    }

    private var canMerge: Bool {
        guard let src = sourceBrandId, let tgt = targetBrandId else { return false }
        return src != tgt
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("源品牌（将被合并删除）", selection: $sourceBrandId) {
                        Text("请选择").tag(nil as UUID?)
                        ForEach(sortedBrands) { brand in
                            Text(brand.name).tag(brand.id as UUID?)
                        }
                    }

                    Picker("目标品牌（保留）", selection: $targetBrandId) {
                        Text("请选择").tag(nil as UUID?)
                        ForEach(sortedBrands.filter { $0.id != sourceBrandId }) { brand in
                            Text(brand.name).tag(brand.id as UUID?)
                        }
                    }
                } header: {
                    Text("选择品牌")
                } footer: {
                    Text("源品牌的所有数据将转移到目标品牌，源品牌随后被删除。")
                }

                if canMerge {
                    Section("合并预览") {
                        LabeledContent("库存色号数") {
                            Text("\(sourceStockCount) 个")
                        }
                        LabeledContent("关联项目") {
                            Text("\(affectedProjectCount) 个")
                        }
                        LabeledContent("购买记录") {
                            Text("\(affectedPurchaseCount) 个")
                        }
                    }
                }

                if canMerge {
                    Section {
                        Button(role: .destructive) {
                            showingConfirmation = true
                        } label: {
                            HStack {
                                Spacer()
                                Text("执行合并")
                                    .fontWeight(.semibold)
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle("合并品牌")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onChange(of: sourceBrandId) {
                // 如果选择的源品牌和目标品牌相同，清除目标选择
                if sourceBrandId != nil && sourceBrandId == targetBrandId {
                    targetBrandId = nil
                }
            }
            .alert("确认合并", isPresented: $showingConfirmation) {
                Button("取消", role: .cancel) {}
                Button("合并", role: .destructive) {
                    if let src = sourceBrandId, let tgt = targetBrandId {
                        inventoryManager.mergeBrands(sourceBrandId: src, targetBrandId: tgt)
                    }
                    dismiss()
                }
            } message: {
                if let src = sourceBrand, let tgt = targetBrand {
                    Text("将「\(src.name)」合并到「\(tgt.name)」，源品牌的库存、项目和购买记录将全部转移到目标品牌，此操作不可撤销。")
                }
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
