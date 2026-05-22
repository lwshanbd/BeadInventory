//
//  BrandSettingsView.swift
//  BeadInventory
//
//  品牌设置 —— 二级页（SecondaryNav + ScrollView + GroupCard）。
//  入口图标色 = rose，本页 flavor 跟随。
//

import SwiftUI

struct BrandSettingsView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss

    @State private var showingResetAlert = false
    @State private var showingResetUsageAlert = false
    @State private var showingDeleteBrandAlert = false
    @State private var showingImportStock = false
    @State private var defaultStock: String = "1000"
    @State private var lowStockThreshold: Int = 100
    @State private var editedName: String = ""

    var brand: Brand? {
        inventoryManager.currentBrand
    }

    var brandStockCount: Int {
        guard let brandId = inventoryManager.currentBrandId else { return 0 }
        return inventoryManager.brandStocks.filter { $0.brandId == brandId }.count
    }

    private var hiddenCount: Int {
        guard let brandId = inventoryManager.currentBrandId else { return 0 }
        return inventoryManager.hiddenColorCount(for: brandId)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                BISecondaryNav(title: "品牌设置") {
                    BINavIconButton(systemImage: "ellipsis", action: {})
                }

                if let brand = brand {
                    ScrollView {
                        VStack(spacing: 0) {
                            brandHero(brand: brand)
                                .padding(.horizontal, 18)
                                .padding(.top, 4)
                                .padding(.bottom, 4)

                            BIGroupHeader(title: "品牌信息")
                            BIGroupCard {
                                nameRow(brand: brand)
                                divider
                                colorSystemRow(brand: brand)
                                divider
                                colorCountRow
                            }

                            BIGroupHeader(title: "库存提醒")
                            BIGroupCard(footer: "低于阈值时，色号会在库存列表中以红色标识。") {
                                lowStockRow(brand: brand)
                            }

                            BIGroupHeader(title: "库存操作")
                            BIGroupCard(footer: "导入库存会累加到现有库存。") {
                                BIListRow(
                                    icon: "square.and.arrow.down",
                                    iconColor: Theme.ColorToken.Morandi.rose,
                                    title: "导入库存",
                                    subtitle: "从 CSV / 剪贴板累加",
                                    trailing: .chevron
                                ) {
                                    showingImportStock = true
                                }
                                NavigationLink {
                                    HiddenColorsManageView()
                                } label: {
                                    BIListRow(
                                        icon: "eye.slash",
                                        iconColor: Theme.ColorToken.Morandi.rose,
                                        title: "隐藏色号管理",
                                        subtitle: "隐藏的色号不会出现在库存列表",
                                        trailing: hiddenCount > 0 ? .meta("\(hiddenCount) 个") : .chevron,
                                        isLast: true
                                    )
                                }
                                .buttonStyle(.plain)
                            }

                            BIGroupHeader(title: "危险区", hint: "不可撤销")
                            BIGroupCard {
                                BIDangerRow(
                                    icon: "arrow.counterclockwise",
                                    title: "重置所有库存",
                                    subtitle: "将所有色号库存设为 \(defaultStock) 颗，使用记录清零"
                                ) {
                                    showingResetAlert = true
                                }
                                BIDangerRow(
                                    icon: "xmark.circle",
                                    title: "清除使用记录",
                                    subtitle: "库存数量不变，使用记录清零"
                                ) {
                                    showingResetUsageAlert = true
                                }
                                BIDangerRow(
                                    icon: "trash",
                                    title: "删除此品牌",
                                    subtitle: "同时删除该品牌下的全部库存数据",
                                    isLast: true
                                ) {
                                    showingDeleteBrandAlert = true
                                }
                            }
                        }
                        .padding(.bottom, 32)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .alert("重置库存", isPresented: $showingResetAlert) {
                        Button("取消", role: .cancel) { }
                        Button("重置", role: .destructive) {
                            let stock = Int(defaultStock) ?? 1000
                            inventoryManager.resetAllStock(to: stock)
                        }
                    } message: {
                        Text("将「\(brand.name)」所有颜色的库存重置为 \(defaultStock) 颗，使用记录也将清零。此操作不可撤销。")
                    }
                    .alert("清除使用记录", isPresented: $showingResetUsageAlert) {
                        Button("取消", role: .cancel) { }
                        Button("清除", role: .destructive) {
                            inventoryManager.resetUsage()
                        }
                    } message: {
                        Text("将清除「\(brand.name)」所有颜色的使用记录，库存数量不变。此操作不可撤销。")
                    }
                    .alert("删除品牌", isPresented: $showingDeleteBrandAlert) {
                        Button("取消", role: .cancel) { }
                        Button("删除", role: .destructive) {
                            _ = inventoryManager.deleteBrand(brand.id)
                            dismiss()
                        }
                    } message: {
                        Text("确定要删除「\(brand.name)」吗？该品牌下的所有库存数据将被永久删除。")
                    }
                    .sheet(isPresented: $showingImportStock) {
                        ImportStockView(mode: .forExistingBrand(brand.id), colorSystem: brand.colorSystem)
                    }
                    .onAppear {
                        lowStockThreshold = brand.lowStockThreshold
                        editedName = brand.name
                    }
                } else {
                    BIEmptyHero(
                        icon: "building.2",
                        flavor: Theme.ColorToken.Morandi.rose,
                        title: "请先选择品牌",
                        subtitle: "切换或添加一个品牌后再进入设置"
                    )
                }
            }
            .background(Theme.ColorToken.Surface.background)
            .navigationBarHidden(true)
        }
        .environment(\.tabFlavor, .more)
    }

    // MARK: - Brand Hero

    private func brandHero(brand: Brand) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Theme.ColorToken.Morandi.rose,
                                Theme.ColorToken.Morandi.latte
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 60, height: 60)
                    .shadow(color: Theme.ColorToken.Morandi.rose.opacity(0.25), radius: 6, x: 0, y: 4)
                Text(String(brand.name.prefix(1)))
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(brand.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.Text.primary)
                    .lineLimit(1)
                Text("\(brand.colorSystem.displayName) · \(brandStockCount) 色 · \(brand.createdAt.formatted(date: .abbreviated, time: .omitted)) 创建")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.ColorToken.Surface.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
        )
    }

    // MARK: - Rows

    private var divider: some View {
        Rectangle()
            .fill(Theme.ColorToken.Border.divider)
            .frame(height: 1)
            .padding(.leading, 14)
    }

    private func nameRow(brand: Brand) -> some View {
        HStack(spacing: 12) {
            Text("品牌名称")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.ColorToken.Text.primary)
                .frame(width: 84, alignment: .leading)

            TextField("品牌名称", text: $editedName)
                .font(.system(size: 14))
                .foregroundStyle(Theme.ColorToken.Text.primary)
                .multilineTextAlignment(.trailing)
                .submitLabel(.done)
                .onSubmit { commitName(brand: brand) }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.ColorToken.Surface.subtle)
                )

            if editedName != brand.name && !editedName.isEmpty {
                Button {
                    commitName(brand: brand)
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.ColorToken.Morandi.rose)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func commitName(brand: Brand) {
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != brand.name else { return }
        inventoryManager.updateBrand(brand.id, name: trimmed)
    }

    private func colorSystemRow(brand: Brand) -> some View {
        HStack(spacing: 12) {
            Text("色号体系")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.ColorToken.Text.primary)
                .frame(width: 84, alignment: .leading)

            Spacer(minLength: 8)

            // 只读展示：不允许在设置页强改已用品牌的色号体系
            Text(brand.colorSystem.displayName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ColorToken.Text.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(Theme.ColorToken.Surface.subtle)
                )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var colorCountRow: some View {
        HStack(spacing: 12) {
            Text("已有色号")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.ColorToken.Text.primary)
                .frame(width: 84, alignment: .leading)

            Spacer(minLength: 8)

            Text("\(brandStockCount) 色")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.Text.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func lowStockRow(brand: Brand) -> some View {
        HStack(spacing: 12) {
            Text("低库存阈值")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.ColorToken.Text.primary)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Button {
                    let next = max(0, lowStockThreshold - 50)
                    lowStockThreshold = next
                    inventoryManager.updateBrandLowStockThreshold(brand.id, threshold: next)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Theme.ColorToken.Surface.subtle)
                        )
                }
                .buttonStyle(.plain)

                Text("\(lowStockThreshold)")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.ColorToken.Text.primary)
                    .frame(minWidth: 48)
                    .multilineTextAlignment(.center)

                Button {
                    let next = lowStockThreshold + 50
                    lowStockThreshold = next
                    inventoryManager.updateBrandLowStockThreshold(brand.id, threshold: next)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Theme.ColorToken.Surface.subtle)
                        )
                }
                .buttonStyle(.plain)

                Text("颗")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ColorToken.Text.tertiary)
                    .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }
}

#Preview {
    BrandSettingsView()
        .environmentObject(InventoryManager())
}
