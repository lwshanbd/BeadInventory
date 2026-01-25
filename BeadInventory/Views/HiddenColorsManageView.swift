//
//  HiddenColorsManageView.swift
//  BeadInventory
//
//  隐藏色号管理视图
//

import SwiftUI

struct HiddenColorsManageView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var searchText = ""
    @State private var selectedColors: Set<String> = []
    @State private var isSelectMode = false
    @State private var showUnhideAlert = false
    @State private var defaultUnhideStock = "1000"

    var hiddenStocks: [BrandStock] {
        guard let brandId = inventoryManager.currentBrandId else { return [] }
        let hidden = inventoryManager.hiddenColors(for: brandId)
        if searchText.isEmpty {
            return hidden.sorted { $0.mardCode < $1.mardCode }
        }
        return hidden.filter { $0.mardCode.uppercased().contains(searchText.uppercased()) }
            .sorted { $0.mardCode < $1.mardCode }
    }

    var body: some View {
        List {
            if hiddenStocks.isEmpty {
                Section {
                    VStack(spacing: 16) {
                        Image(systemName: "eye.fill")
                            .font(.system(size: 50))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("没有隐藏的色号")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("在库存详情页面可以隐藏不需要的色号")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
            } else {
                // 恢复库存设置
                Section {
                    HStack {
                        Text("恢复时库存数量")
                        Spacer()
                        TextField("1000", text: $defaultUnhideStock)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                } footer: {
                    Text("取消隐藏时，色号将恢复为此库存数量")
                }

                // 隐藏色号列表
                Section {
                    ForEach(hiddenStocks, id: \.id) { stock in
                        HiddenColorRow(
                            stock: stock,
                            isSelectMode: isSelectMode,
                            isSelected: selectedColors.contains(stock.mardCode),
                            onToggleSelect: {
                                if selectedColors.contains(stock.mardCode) {
                                    selectedColors.remove(stock.mardCode)
                                } else {
                                    selectedColors.insert(stock.mardCode)
                                }
                            }
                        )
                        .swipeActions(edge: .trailing) {
                            Button {
                                unhideColor(stock.mardCode)
                            } label: {
                                Label("取消隐藏", systemImage: "eye")
                            }
                            .tint(.green)
                        }
                    }
                } header: {
                    Text("已隐藏的色号 (\(hiddenStocks.count))")
                }
            }
        }
        .searchable(text: $searchText, prompt: "搜索色号")
        .navigationTitle("隐藏色号管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !hiddenStocks.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSelectMode ? "完成" : "选择") {
                        isSelectMode.toggle()
                        if !isSelectMode {
                            selectedColors.removeAll()
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelectMode && !selectedColors.isEmpty {
                Button {
                    showUnhideAlert = true
                } label: {
                    HStack {
                        Image(systemName: "eye")
                        Text("取消隐藏 \(selectedColors.count) 个色号")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.green)
                    .cornerRadius(12)
                }
                .padding()
            }
        }
        .alert("取消隐藏", isPresented: $showUnhideAlert) {
            Button("取消", role: .cancel) { }
            Button("确认") {
                unhideSelectedColors()
            }
        } message: {
            Text("将取消隐藏 \(selectedColors.count) 个色号，库存将恢复为 \(defaultUnhideStock) 颗")
        }
    }

    private func unhideColor(_ mardCode: String) {
        guard let brandId = inventoryManager.currentBrandId else { return }
        let stock = Int(defaultUnhideStock) ?? 1000
        inventoryManager.unhideColor(brandId: brandId, mardCode: mardCode, defaultStock: stock)
    }

    private func unhideSelectedColors() {
        guard let brandId = inventoryManager.currentBrandId else { return }
        let stock = Int(defaultUnhideStock) ?? 1000
        inventoryManager.unhideColors(brandId: brandId, mardCodes: Array(selectedColors), defaultStock: stock)
        selectedColors.removeAll()
        isSelectMode = false
    }
}

// MARK: - 隐藏色号行视图
struct HiddenColorRow: View {
    let stock: BrandStock
    let isSelectMode: Bool
    let isSelected: Bool
    let onToggleSelect: () -> Void

    @EnvironmentObject var inventoryManager: InventoryManager

    var color: BeadColor? {
        inventoryManager.findColor(byCode: stock.mardCode)
    }

    var body: some View {
        HStack(spacing: 12) {
            if isSelectMode {
                Button {
                    onToggleSelect()
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(isSelected ? .accentColor : .secondary)
                        .font(.title2)
                }
                .buttonStyle(.plain)
            }

            // 颜色块
            if let color = color {
                RoundedRectangle(cornerRadius: 6)
                    .fill(color.color)
                    .frame(width: 40, height: 40)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 40, height: 40)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(stock.mardCode)
                    .font(.system(.headline, design: .monospaced))

                if let color = color {
                    Text(color.colorName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Image(systemName: "eye.slash.fill")
                .foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelectMode {
                onToggleSelect()
            }
        }
    }
}

#Preview {
    NavigationStack {
        HiddenColorsManageView()
            .environmentObject(InventoryManager())
    }
}
