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
                .concentricBackground(Theme.ColorToken.Fill.latte)
                .foregroundColor(.white)
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
                .concentricBackground(Theme.ColorToken.Morandi.latte.opacity(0.1))
                .foregroundColor(Theme.ColorToken.Morandi.latte)
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

private extension View {
    /// 品牌胶囊常常摆在页面左上角，紧挨着屏幕的大圆角（iPhone Duo 上尤其明显）。
    /// 写死的 16pt 圆角跟屏幕那条弧对不上，看着像被硬塞进角里。iOS 26 起改成跟所在
    /// 容器同心：靠近屏幕角时跟着它弯，离得远就退回 16pt。
    @ViewBuilder
    func concentricBackground(_ style: some ShapeStyle) -> some View {
        if #available(iOS 26.0, *) {
            background(style, in: ConcentricRectangle(
                corners: .concentric(minimum: .fixed(Theme.Radius.lg)),
                isUniform: true
            ))
        } else {
            background(style, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
        }
    }
}
