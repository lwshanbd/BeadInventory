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
            VStack(spacing: 0) {
                BISecondaryNav(title: "低库存详情", dismissAction: { dismiss() })
                if !brandExists {
                    ContentUnavailableView {
                        Label("品牌不存在", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("该品牌可能已被删除或同步丢失")
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 18) {
                            BIGroupCard {
                                VStack(spacing: 0) {
                                    HStack {
                                        Text("低库存阈值")
                                            .foregroundColor(Theme.ColorToken.Text.secondary)
                                        Spacer()
                                        Text("\(lowStockThreshold)")
                                            .fontWeight(.medium)
                                            .foregroundColor(Theme.ColorToken.Text.primary)
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 13)
                                    Rectangle()
                                        .fill(Theme.ColorToken.Border.divider)
                                        .frame(height: 1)
                                        .padding(.leading, 14)
                                    HStack {
                                        Text("低库存色号数")
                                            .foregroundColor(Theme.ColorToken.Text.secondary)
                                        Spacer()
                                        Text("\(lowStockItems.count)")
                                            .fontWeight(.bold)
                                            .foregroundColor(Theme.ColorToken.Status.warning)
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 13)
                                }
                            }

                            if missingColorCount > 0 {
                                BIGroupCard {
                                    HStack(spacing: 8) {
                                        Image(systemName: "info.circle.fill")
                                            .foregroundColor(Theme.ColorToken.Status.info)
                                        Text("有 \(missingColorCount) 个色号无法匹配颜色数据，已显示原始色号")
                                            .font(.caption)
                                            .foregroundColor(Theme.ColorToken.Text.secondary)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 13)
                                }
                            }

                            if lowStockItems.isEmpty {
                                BIGroupCard {
                                    HStack {
                                        Spacer()
                                        VStack(spacing: 8) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 48))
                                                .foregroundColor(Theme.ColorToken.Status.success)
                                            Text("没有低库存颜色")
                                                .font(.headline)
                                                .foregroundColor(Theme.ColorToken.Text.secondary)
                                        }
                                        .padding(.vertical, 32)
                                        Spacer()
                                    }
                                }
                            } else {
                                BIGroupCard(title: "按可用库存从少到多排序") {
                                    ForEach(Array(lowStockItems.enumerated()), id: \.element.stock.id) { idx, item in
                                        VStack(spacing: 0) {
                                            LowStockRowView(
                                                color: item.color,
                                                stock: item.stock,
                                                lowStockThreshold: lowStockThreshold,
                                                colorSystem: inventoryManager.currentColorSystem
                                            )
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 10)
                                            if idx < lowStockItems.count - 1 {
                                                Rectangle()
                                                    .fill(Theme.ColorToken.Border.divider)
                                                    .frame(height: 1)
                                                    .padding(.leading, 60)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                    }
                }
            }
            .background(Theme.ColorToken.Surface.background)
            .navigationBarHidden(true)
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
                .fill(color?.color ?? Theme.ColorToken.Border.default)
                .frame(width: 40, height: 40)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
                )
                .overlay(alignment: .topTrailing) {
                    if isCustomColor {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundColor(Theme.ColorToken.Status.warning)
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
                            .background(Theme.ColorToken.Status.warning.opacity(0.2))
                            .foregroundColor(Theme.ColorToken.Status.warning)
                            .cornerRadius(Theme.Radius.sm)
                    }
                }

                // 仅自定义色号(# 开头)显示用户输入的名字;
                // 预设色号绝不显示编造的中文名（HANDOFF 铁律）
                if let c = color, c.mardCode.hasPrefix("#"), !c.colorName.isEmpty {
                    Text(c.colorName)
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
                    .foregroundColor(Theme.ColorToken.Status.error)

                Text("缺 \(max(0, lowStockThreshold - stock.available))")
                    .font(.caption)
                    .foregroundColor(Theme.ColorToken.Status.warning)
            }

            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(Theme.ColorToken.Status.warning)
                .font(.subheadline)
        }
        .padding(.vertical, 4)
    }
}
