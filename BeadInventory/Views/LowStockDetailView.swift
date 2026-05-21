//
//  LowStockDetailView.swift
//  BeadInventory
//
//  低库存详情页
//

import SwiftUI

struct LowStockDetailView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) private var dismiss
    let brandId: UUID

    var brandExists: Bool {
        inventoryManager.brands.contains { $0.id == brandId }
    }

    var lowStockThreshold: Int {
        inventoryManager.getLowStockThreshold(for: brandId)
    }

    var lowStockItems: [(color: BeadColor?, stock: BrandStock)] {
        let stocks = inventoryManager.lowStockColors(for: brandId)
        return stocks.map { stock in
            let color = inventoryManager.findColor(byCode: stock.mardCode)
            return (color, stock)
        }.sorted {
            $0.stock.available < $1.stock.available
        }
    }

    var missingColorCount: Int {
        lowStockItems.filter { $0.color == nil }.count
    }

    var body: some View {
        NavigationStack {
            Group {
                if !brandExists {
                    ContentUnavailableView {
                        Label("品牌不存在", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("该品牌可能已被删除或同步丢失")
                    }
                } else {
                    List {
                        Section {
                            HStack {
                                Text("低库存阈值")
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(lowStockThreshold)")
                                    .fontWeight(.medium)
                            }
                            HStack {
                                Text("低库存色号数")
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(lowStockItems.count)")
                                    .fontWeight(.bold)
                                    .foregroundColor(.orange)
                            }
                        }

                        if missingColorCount > 0 {
                            Section {
                                HStack(spacing: 8) {
                                    Image(systemName: "info.circle.fill")
                                        .foregroundColor(.blue)
                                    Text("有 \(missingColorCount) 个色号无法匹配颜色数据，已显示原始色号")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                            }
                        }

                        if lowStockItems.isEmpty {
                            Section {
                                HStack {
                                    Spacer()
                                    VStack(spacing: 8) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 48))
                                            .foregroundColor(.green)
                                        Text("没有低库存颜色")
                                            .font(.headline)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.vertical, 32)
                                    Spacer()
                                }
                            }
                        } else {
                            Section(header: Text("按可用库存从少到多排序")) {
                                ForEach(lowStockItems, id: \.stock.id) { item in
                                    LowStockRowView(
                                        color: item.color,
                                        stock: item.stock,
                                        lowStockThreshold: lowStockThreshold,
                                        colorSystem: inventoryManager.currentColorSystem
                                    )
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("低库存详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - 低库存行视图
struct LowStockRowView: View {
    let color: BeadColor?
    let stock: BrandStock
    var lowStockThreshold: Int = 100
    var colorSystem: ColorSystem = .mard

    var displayCode: String {
        color?.displayCode(for: colorSystem) ?? stock.mardCode
    }

    var isCustomColor: Bool {
        stock.mardCode.hasPrefix("#")
    }

    var body: some View {
        HStack(spacing: 12) {
            // 颜色块
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(color?.color ?? Color.gray.opacity(0.3))
                .frame(width: 40, height: 40)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
                .overlay(alignment: .topTrailing) {
                    if isCustomColor {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.orange)
                            .padding(2)
                    }
                }

            // 色号和名称
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(displayCode)
                        .font(.system(.headline, design: .monospaced))
                    if isCustomColor {
                        Text("自定义")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .foregroundColor(.orange)
                            .cornerRadius(Theme.Radius.sm)
                    }
                }

                if let colorName = color?.colorName, !colorName.isEmpty {
                    Text(colorName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // 库存信息
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(stock.available)")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(.red)

                Text("缺 \(max(0, lowStockThreshold - stock.available))")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.subheadline)
        }
        .padding(.vertical, 4)
    }
}
