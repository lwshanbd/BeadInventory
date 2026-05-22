//
//  BrandPicker.swift
//  BeadInventory
//
//  品牌选择器组件
//

import SwiftUI

struct BrandPicker: View {
    /// 可选：仅显示匹配该色号体系的品牌。nil 时显示所有品牌。
    var colorSystemFilter: ColorSystem? = nil
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var showingBrandManager = false

    /// 过滤后的品牌列表
    private var filteredBrands: [Brand] {
        let sorted = inventoryManager.brands.sorted(by: { $0.sortOrder < $1.sortOrder })
        if let filter = colorSystemFilter {
            return sorted.filter { $0.colorSystem == filter }
        }
        return sorted
    }

    var body: some View {
        if filteredBrands.isEmpty {
            // 没有匹配品牌时显示创建按钮
            Button {
                showingBrandManager = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                    Text("创建品牌")
                        .font(.headline)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Theme.ColorToken.Morandi.latte)
                .foregroundColor(.white)
                .cornerRadius(Theme.Radius.lg)
            }
            .sheet(isPresented: $showingBrandManager) {
                BrandManagerView()
            }
        } else {
            // 有品牌时显示选择器
            Menu {
                ForEach(filteredBrands) { brand in
                    Button {
                        inventoryManager.selectBrand(brand.id)
                    } label: {
                        HStack {
                            Text(brand.name)
                            if brand.id == inventoryManager.currentBrandId {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                Divider()

                Button {
                    showingBrandManager = true
                } label: {
                    Label("管理品牌", systemImage: "gear")
                }
            } label: {
                HStack(spacing: 8) {
                    Text(inventoryManager.currentBrand?.name ?? "选择品牌")
                        .font(.headline)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Theme.ColorToken.Morandi.latte.opacity(0.1))
                .foregroundColor(Theme.ColorToken.Morandi.latte)
                .cornerRadius(Theme.Radius.lg)
            }
            .sheet(isPresented: $showingBrandManager) {
                BrandManagerView()
            }
        }
    }
}

#Preview {
    BrandPicker()
        .environmentObject(InventoryManager())
}
