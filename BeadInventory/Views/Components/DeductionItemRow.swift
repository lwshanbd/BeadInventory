//
//  DeductionItemRow.swift
//  BeadInventory
//
//  共享扣减颜色行组件：品牌切换 + 相似色入口 + 库存状态
//

import SwiftUI

struct DeductionItemRow: View {
    let item: DeductionItem
    let beadColor: BeadColor?
    let matchingBrands: [Brand]
    let similarColors: [SimilarColor]
    let colorSystem: ColorSystem
    let lowStockThreshold: Int
    let brandName: String

    var onBrandChanged: (UUID) -> Void
    var onResetBrand: () -> Void
    var onSubstitute: (String, String) -> Void

    @State private var showingSimilarColorSheet = false

    private var stockAfter: Int {
        item.availableStock - item.quantity
    }

    private var isLowStock: Bool {
        !item.isInsufficient && stockAfter < lowStockThreshold
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                colorPreview

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(item.colorCode)
                            .font(.system(.body, design: .monospaced))
                            .fontWeight(.medium)
                        if item.originalMardCode != nil {
                            Text("(原 \(item.originalColorCode ?? ""))")
                                .font(.caption2)
                                .foregroundColor(Theme.ColorToken.Status.warning)
                        }
                    }

                    HStack(spacing: 4) {
                        Text("库存 \(item.availableStock)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("→")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("\(stockAfter)")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(item.isInsufficient ? .red : (isLowStock ? .orange : .green))
                        if item.isInsufficient {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundColor(Theme.ColorToken.Status.error)
                        } else if isLowStock {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundColor(Theme.ColorToken.Status.warning)
                        }
                    }
                }

                Spacer()

                Text("×\(item.quantity)")
                    .font(.headline)
                    .foregroundColor(.accentColor)

                brandMenu
            }

            if item.isManualOverride {
                HStack {
                    Spacer()
                    Text("已覆盖")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Button(action: onResetBrand) {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .font(.caption2)
                            .foregroundColor(.accentColor)
                    }
                }
            }

            if item.isInsufficient && !similarColors.isEmpty {
                inlineSimilarSuggestion
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(item.isInsufficient ? Theme.ColorToken.Status.error.opacity(0.1) : Theme.ColorToken.Surface.subtle)
        .cornerRadius(Theme.Radius.md)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(item.isInsufficient ? Theme.ColorToken.Status.error.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .contextMenu {
            Button {
                showingSimilarColorSheet = true
            } label: {
                Label("查找相似色", systemImage: "magnifyingglass")
            }
        }
        .sheet(isPresented: $showingSimilarColorSheet) {
            SimilarColorSheet(
                originalColor: beadColor,
                originalColorCode: item.colorCode,
                similarColors: similarColors,
                colorSystem: colorSystem,
                onSelect: { similar in
                    onSubstitute(
                        similar.beadColor.mardCode,
                        similar.beadColor.displayCode(for: colorSystem)
                    )
                }
            )
        }
    }

    @ViewBuilder
    private var colorPreview: some View {
        if let beadColor {
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(beadColor.color)
                .frame(width: 36, height: 36)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
                )
        } else {
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(Theme.ColorToken.Border.default)
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: "questionmark")
                        .foregroundColor(Theme.ColorToken.Text.secondary)
                )
        }
    }

    private var brandMenu: some View {
        Menu {
            ForEach(matchingBrands) { brand in
                Button {
                    onBrandChanged(brand.id)
                } label: {
                    HStack {
                        Text(brand.name)
                        if brand.id == item.brandId {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(brandName)
                    .font(.caption)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(item.isManualOverride ? Theme.ColorToken.Status.warning.opacity(0.15) : Color.accentColor.opacity(0.1))
            .foregroundColor(item.isManualOverride ? .orange : .accentColor)
            .cornerRadius(Theme.Radius.md)
        }
    }

    private var inlineSimilarSuggestion: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "lightbulb.fill")
                    .font(.caption2)
                    .foregroundColor(Theme.ColorToken.Status.warning)
                Text("相似色可用：")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            ForEach(similarColors.prefix(3), id: \.beadColor.id) { similar in
                Button {
                    onSubstitute(
                        similar.beadColor.mardCode,
                        similar.beadColor.displayCode(for: colorSystem)
                    )
                } label: {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .fill(similar.beadColor.color)
                            .frame(width: 16, height: 16)
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                    .stroke(Theme.ColorToken.Border.default, lineWidth: 0.5)
                            )
                        Text(similar.beadColor.displayCode(for: colorSystem))
                            .font(.caption2)
                            .fontWeight(.medium)
                        Text("(库存\(similar.availableStock))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("使用")
                            .font(.caption2)
                            .foregroundColor(.accentColor)
                    }
                }
                .buttonStyle(.plain)
            }

            if similarColors.count > 3 {
                Button {
                    showingSimilarColorSheet = true
                } label: {
                    Text("查看更多...")
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                }
            }
        }
        .padding(8)
        .background(Theme.ColorToken.Status.warning.opacity(0.08))
        .cornerRadius(Theme.Radius.sm)
    }
}
