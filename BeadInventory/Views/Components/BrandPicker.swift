//
//  BrandPicker.swift
//  BeadInventory
//
//  品牌选择器组件
//

import SwiftUI

struct BrandPicker: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var showingBrandManager = false

    var body: some View {
        if inventoryManager.brands.isEmpty {
            // 没有品牌时显示创建按钮
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
                .background(Color.accentColor)
                .foregroundColor(.white)
                .cornerRadius(20)
            }
            .sheet(isPresented: $showingBrandManager) {
                BrandManagerView()
            }
        } else {
            // 有品牌时显示选择器
            Menu {
                ForEach(inventoryManager.brands.sorted(by: { $0.sortOrder < $1.sortOrder })) { brand in
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
                .background(Color.accentColor.opacity(0.1))
                .foregroundColor(.accentColor)
                .cornerRadius(20)
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
