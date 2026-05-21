//
//  DeductionReviewView.swift
//  BeadInventory
//
//  扣减审核视图 —— 从原 DeductionReviewSheet 抽取，可由 navigationDestination push。
//  不含外层 NavigationStack 和"取消"toolbar，由调用方提供。
//

import SwiftUI

struct DeductionReviewView: View {
    @ObservedObject var resolver: DeductionResolver
    let colorSystem: ColorSystem
    let matchingBrands: [Brand]
    let inventoryManager: InventoryManager
    let similarityService: ColorSimilarityService
    var onConfirm: () -> Void

    @State private var showConfirmAlert = false

    private var confirmAlertMessage: String {
        let total = resolver.items.reduce(0) { $0 + $1.quantity }
        let count = resolver.items.count
        if resolver.insufficientItems.isEmpty && !resolver.hasManualOverrides {
            return "将扣减 \(total) 颗豆子，共 \(count) 种颜色。"
        }
        var msg = "将扣减 \(total) 颗豆子，共 \(count) 种颜色。"
        if resolver.hasManualOverrides {
            let overrides = resolver.manualOverrideItems.compactMap { item in
                if let brand = matchingBrands.first(where: { $0.id == item.brandId }) {
                    return "\(item.colorCode) → \(brand.name)"
                }
                return nil
            }
            msg += "\n\n跨品牌扣减：\n" + overrides.joined(separator: "\n")
        }
        if !resolver.insufficientItems.isEmpty {
            msg += "\n\n⚠️ \(resolver.insufficientItems.count) 种颜色库存不足"
        }
        return msg
    }

    @ViewBuilder
    private func deductionItemRowView(item: DeductionItem, resolver: DeductionResolver) -> some View {
        let beadColor = inventoryManager.findColor(byCode: item.mardCode)
        let brandName = matchingBrands.first(where: { $0.id == item.brandId })?.name ?? "未知"
        let threshold = matchingBrands.first(where: { $0.id == item.brandId })?.lowStockThreshold ?? 100
        let similarColors = similarityService.findSimilarColors(
            for: item.mardCode,
            brandId: item.brandId,
            allColors: inventoryManager.allBeadColors,
            brandStocks: inventoryManager.brandStocks
        )

        DeductionItemRow(
            item: item,
            beadColor: beadColor,
            matchingBrands: matchingBrands,
            similarColors: similarColors,
            colorSystem: colorSystem,
            lowStockThreshold: threshold,
            brandName: brandName,
            onBrandChanged: { newBrandId in
                resolver.overrideBrand(for: item.id, to: newBrandId)
            },
            onResetBrand: {
                resolver.resetToPrimary(for: item.id)
            },
            onSubstitute: { newMardCode, newColorCode in
                resolver.substituteColor(
                    itemId: item.id,
                    newMardCode: newMardCode,
                    newColorCode: newColorCode
                )
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("主品牌:")
                    .foregroundColor(.secondary)
                if let brand = matchingBrands.first(where: { $0.id == resolver.primaryBrandId }) {
                    Text(brand.name)
                        .fontWeight(.medium)
                }
                Spacer()
                Menu {
                    ForEach(matchingBrands) { brand in
                        Button {
                            resolver.setPrimaryBrand(brand.id)
                        } label: {
                            HStack {
                                Text(brand.name)
                                if brand.id == resolver.primaryBrandId {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("切换")
                            .font(.caption)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.1))
                    .foregroundColor(.accentColor)
                    .cornerRadius(Theme.Radius.md)
                }
            }
            .padding()

            Divider()

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(resolver.items) { item in
                        deductionItemRowView(item: item, resolver: resolver)
                    }
                }
                .padding()
            }

            Divider()

            VStack(spacing: 8) {
                HStack {
                    Text("\(resolver.items.count) 种颜色")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("·")
                        .foregroundColor(.secondary)
                    Text("\(resolver.items.reduce(0) { $0 + $1.quantity }) 颗")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if !resolver.insufficientItems.isEmpty {
                        Text("·")
                            .foregroundColor(.secondary)
                        Text("\(resolver.insufficientItems.count) 种不足")
                            .font(.caption)
                            .foregroundColor(Theme.ColorToken.Status.error)
                    }
                    Spacer()
                }

                Button {
                    showConfirmAlert = true
                } label: {
                    HStack {
                        Image(systemName: resolver.insufficientItems.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        Text("确认扣减")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(resolver.insufficientItems.isEmpty ? Theme.ColorToken.Status.success : Theme.ColorToken.Status.error)
                    .foregroundColor(.white)
                    .cornerRadius(Theme.Radius.md)
                }
            }
            .padding()
        }
        .navigationTitle("扣减审核")
        .navigationBarTitleDisplayMode(.inline)
        .alert("确认扣减", isPresented: $showConfirmAlert) {
            Button("取消", role: .cancel) { }
            Button("确认", role: resolver.insufficientItems.isEmpty ? .none : .destructive) {
                onConfirm()
            }
        } message: {
            Text(confirmAlertMessage)
        }
    }
}
