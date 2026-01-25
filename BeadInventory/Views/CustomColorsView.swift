//
//  CustomColorsView.swift
//  BeadInventory
//
//  自定义色号管理视图
//

import SwiftUI

struct CustomColorsView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var showingAddSheet = false
    @State private var editingColor: CustomColor?
    @State private var showingDeleteAlert = false
    @State private var colorToDelete: CustomColor?
    @State private var searchText = ""

    var filteredColors: [CustomColor] {
        if searchText.isEmpty {
            return inventoryManager.customColors
        }
        let query = searchText.uppercased()
        return inventoryManager.customColors.filter { color in
            color.colorCode.uppercased().contains(query) ||
            color.colorName.uppercased().contains(query) ||
            color.colorHex.uppercased().contains(query)
        }
    }

    var body: some View {
        List {
            if inventoryManager.customColors.isEmpty {
                emptyStateView
            } else {
                ForEach(filteredColors) { color in
                    colorRow(color)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                colorToDelete = color
                                showingDeleteAlert = true
                            } label: {
                                Label("删除", systemImage: "trash")
                            }

                            Button {
                                editingColor = color
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            .tint(.orange)
                        }
                }
            }
        }
        .searchable(text: $searchText, prompt: "搜索颜色")
        .navigationTitle("自定义色号")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            CustomColorEditView(editingColor: nil)
        }
        .sheet(item: $editingColor) { color in
            CustomColorEditView(editingColor: color)
        }
        .alert("确认删除", isPresented: $showingDeleteAlert) {
            Button("取消", role: .cancel) {
                colorToDelete = nil
            }
            Button("删除", role: .destructive) {
                if let color = colorToDelete {
                    _ = inventoryManager.deleteCustomColor(id: color.id)
                }
                colorToDelete = nil
            }
        } message: {
            if let color = colorToDelete {
                Text("确定要删除自定义色号「\(color.colorCode)」吗？\n删除后将无法恢复，且该颜色在所有品牌中的库存记录也将被删除。")
            }
        }
    }

    private var emptyStateView: some View {
        Section {
            VStack(spacing: 16) {
                Image(systemName: "paintpalette")
                    .font(.system(size: 50))
                    .foregroundColor(.secondary)

                Text("还没有自定义色号")
                    .font(.headline)
                    .foregroundColor(.secondary)

                Text("点击右上角 + 添加你自己的颜色")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Button {
                    showingAddSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .fontWeight(.semibold)
                        Text("添加自定义色号")
                    }
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
        .listRowBackground(Color.clear)
    }

    private func colorRow(_ color: CustomColor) -> some View {
        HStack(spacing: 12) {
            // 颜色圆点
            Circle()
                .fill(color.color)
                .frame(width: 44, height: 44)
                .overlay(
                    Circle()
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )

            // 颜色信息
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(color.colorCode)
                        .font(.headline)

                    if !color.colorName.isEmpty {
                        Text("·")
                            .foregroundColor(.secondary)
                        Text(color.colorName)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                Text("#\(color.colorHex.uppercased())")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospaced()
            }

            Spacer()

            // 库存信息
            stockInfoView(for: color)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            editingColor = color
        }
    }

    @ViewBuilder
    private func stockInfoView(for color: CustomColor) -> some View {
        if let brandId = inventoryManager.currentBrandId,
           let stock = inventoryManager.getStock(brandId: brandId, mardCode: color.mardCode) {
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(stock.available)")
                    .font(.headline)
                    .foregroundColor(stock.available < 100 ? .red : .primary)
                Text("可用")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

#Preview {
    NavigationStack {
        CustomColorsView()
            .environmentObject(InventoryManager())
    }
}
