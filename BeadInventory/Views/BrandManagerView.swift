//
//  BrandManagerView.swift
//  BeadInventory
//
//  品牌管理 二级页（Phase 1.9 重写）
//  flavor = Theme.ColorToken.Morandi.rose
//

import SwiftUI

struct BrandManagerView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) private var dismiss

    @State private var showingAddBrand = false
    @State private var showingMergeBrand = false
    @State private var brandToDelete: Brand?
    @State private var brandToEdit: Brand?
    @State private var editingName = ""
    @State private var navigateBrandId: BrandNavTarget?

    private let flavor = Theme.ColorToken.Morandi.rose

    private var sortedBrands: [Brand] {
        inventoryManager.brands.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                Theme.ColorToken.Surface.background
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    BISecondaryNav(title: "品牌管理") {
                        BINavIconButton(systemImage: "plus") {
                            showingAddBrand = true
                        }
                    }

                    if inventoryManager.brands.isEmpty {
                        emptyState
                    } else {
                        content
                    }
                }

                if !inventoryManager.brands.isEmpty {
                    fab
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(item: $navigateBrandId) { _ in
                BrandSettingsView()
                    .environmentObject(inventoryManager)
            }
            .sheet(isPresented: $showingAddBrand) { AddBrandView() }
            .sheet(isPresented: $showingMergeBrand) { MergeBrandSheet() }
            .alert("编辑品牌", isPresented: Binding(
                get: { brandToEdit != nil },
                set: { if !$0 { brandToEdit = nil } }
            )) {
                TextField("品牌名称", text: $editingName)
                Button("取消", role: .cancel) {
                    brandToEdit = nil
                    editingName = ""
                }
                Button("保存") {
                    if let brand = brandToEdit,
                       !editingName.trimmingCharacters(in: .whitespaces).isEmpty {
                        var updated = brand
                        updated.name = editingName.trimmingCharacters(in: .whitespaces)
                        inventoryManager.updateBrand(updated)
                    }
                    brandToEdit = nil
                    editingName = ""
                }
            } message: {
                Text("修改品牌名称")
            }
            .alert("删除品牌", isPresented: Binding(
                get: { brandToDelete != nil },
                set: { if !$0 { brandToDelete = nil } }
            )) {
                Button("取消", role: .cancel) { brandToDelete = nil }
                Button("删除", role: .destructive) {
                    if let brand = brandToDelete {
                        _ = inventoryManager.deleteBrand(brand.id)
                    }
                    brandToDelete = nil
                }
            } message: {
                Text("删除品牌将同时删除该品牌下的所有库存记录，此操作不可撤销。")
            }
        }
    }

    // MARK: - 内容
    private var content: some View {
        ScrollView {
            VStack(spacing: 0) {
                overviewHero
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
                    .padding(.bottom, 14)

                tipCard
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)

                BIGroupHeader(
                    title: "品牌列表",
                    hint: "\(inventoryManager.brands.count) 个"
                )

                VStack(spacing: 10) {
                    ForEach(sortedBrands) { brand in
                        BrandManagerCard(
                            brand: brand,
                            isCurrent: brand.id == inventoryManager.currentBrandId,
                            stockCount: stockCount(for: brand.id),
                            flavor: flavor,
                            onTap: {
                                inventoryManager.selectBrand(brand.id)
                                navigateBrandId = BrandNavTarget(id: brand.id)
                            },
                            onEdit: {
                                brandToEdit = brand
                                editingName = brand.name
                            },
                            onDelete: {
                                brandToDelete = brand
                            }
                        )
                    }
                }
                .padding(.horizontal, 18)

                if inventoryManager.brands.count >= 2 {
                    Button {
                        showingMergeBrand = true
                    } label: {
                        HStack(spacing: Theme.Spacing.sm) {
                            Image(systemName: "arrow.triangle.merge")
                            Text("合并品牌")
                                .font(Theme.Typography.cardTitle)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .foregroundStyle(.white)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.md)
                                .fill(flavor)
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                }

                Color.clear.frame(height: 120)
            }
            .padding(.top, 6)
        }
    }

    // MARK: - 总览 hero
    private var overviewHero: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("共有品牌")
                    .font(.system(size: 11))
                    .tracking(0.5)
                    .foregroundStyle(Theme.ColorToken.Text.secondary)

                HStack(alignment: .lastTextBaseline, spacing: 5) {
                    Text("\(inventoryManager.brands.count)")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(flavor)
                    Text("个")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                    if let current = inventoryManager.currentBrand {
                        Text("· 当前 \(current.name)")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.ColorToken.Text.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 8)

            BrandIconCluster(brands: Array(sortedBrands.prefix(4)), flavor: flavor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            LinearGradient(
                colors: [
                    flavor.opacity(0.10),
                    Theme.ColorToken.Morandi.latte.opacity(0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - 提示卡
    private var tipCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 13))
                .foregroundStyle(Theme.ColorToken.Morandi.honey)
            Text("长按品牌卡或左滑可编辑、删除")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.ColorToken.Text.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(flavor.opacity(0.08))
        )
    }

    // MARK: - Empty
    private var emptyState: some View {
        ScrollView {
            BIEmptyHero(
                icon: "square.grid.3x3",
                flavor: flavor,
                title: "还没有品牌",
                subtitle: "从下方按钮添加第一个品牌"
            ) {
                Button {
                    showingAddBrand = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("添加品牌")
                            .fontWeight(.semibold)
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(
                        Capsule().fill(flavor)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - FAB
    private var fab: some View {
        Button {
            showingAddBrand = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Theme.ColorToken.Fill.rose)
                )
                .shadow(color: Theme.ColorToken.Fill.rose.opacity(0.35), radius: 12, x: 0, y: 6)
                .shadow(color: Theme.ColorToken.Shadow.soft, radius: 3, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 18)
        .padding(.bottom, 30)
    }

    private func stockCount(for brandId: UUID) -> Int {
        inventoryManager.brandStocks.filter {
            $0.brandId == brandId && ($0.stock > 0 || $0.used > 0)
        }.count
    }
}

// MARK: - 品牌卡片

private struct BrandManagerCard: View {
    let brand: Brand
    let isCurrent: Bool
    let stockCount: Int
    let flavor: Color
    let onTap: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var initial: String {
        String(brand.name.prefix(1))
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // drag handle (visual cue; reorder via long-press context menu)
                VStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in
                        HStack(spacing: 2) {
                            Circle()
                                .fill(Theme.ColorToken.Text.tertiary)
                                .frame(width: 3, height: 3)
                            Circle()
                                .fill(Theme.ColorToken.Text.tertiary)
                                .frame(width: 3, height: 3)
                        }
                    }
                }
                .opacity(0.4)
                .frame(width: 16)

                // initial tile
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(flavor.opacity(0.18))
                        .frame(width: 44, height: 44)
                    Text(initial)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(flavor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(brand.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.ColorToken.Text.primary)
                            .lineLimit(1)

                        if isCurrent {
                            Text("当前")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(flavor))
                        }
                    }

                    HStack(spacing: 6) {
                        Text(brand.colorSystem.displayName)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Theme.ColorToken.Text.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(Theme.ColorToken.Surface.subtle)
                            )

                        Text("· \(stockCount) 色")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.ColorToken.Text.secondary)

                        Text("· \(brand.createdAt.formatted(date: .numeric, time: .omitted))")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.ColorToken.Text.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.Text.tertiary)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.ColorToken.Surface.elevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isCurrent ? flavor : Theme.ColorToken.Border.default,
                        lineWidth: 1
                    )
            )
            .overlay(alignment: .leading) {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(flavor)
                        .frame(width: 3)
                        .padding(.vertical, 8)
                        .padding(.leading, 0)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                onEdit()
            } label: {
                Label("编辑名称", systemImage: "pencil")
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("删除品牌", systemImage: "trash")
            }
        }
    }
}

// MARK: - Brand icon cluster

private struct BrandIconCluster: View {
    let brands: [Brand]
    let flavor: Color

    var body: some View {
        HStack(spacing: -10) {
            ForEach(Array(brands.enumerated()), id: \.element.id) { idx, brand in
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(tone(for: idx).opacity(0.30))
                        .frame(width: 30, height: 30)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Theme.ColorToken.Surface.elevated, lineWidth: 2)
                        )
                    Text(String(brand.name.prefix(1)))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(tone(for: idx))
                }
                .zIndex(Double(brands.count - idx))
            }
        }
    }

    private func tone(for idx: Int) -> Color {
        // 主色 rose；其余从 latte/honey 中取，保证同屏 Morandi 色 ≤ 2 主导
        // idx0 用 flavor，其余统一用 latte（仍属于 hero 用色域）
        return idx == 0 ? flavor : Theme.ColorToken.Morandi.latte
    }
}

// MARK: - 合并品牌 Sheet
struct MergeBrandSheet: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss

    @State private var sourceBrandId: UUID?
    @State private var targetBrandId: UUID?
    @State private var showingConfirmation = false

    private var sortedBrands: [Brand] {
        inventoryManager.brands.sorted(by: { $0.sortOrder < $1.sortOrder })
    }

    private var sourceBrand: Brand? {
        guard let id = sourceBrandId else { return nil }
        return inventoryManager.brands.first { $0.id == id }
    }

    private var targetBrand: Brand? {
        guard let id = targetBrandId else { return nil }
        return inventoryManager.brands.first { $0.id == id }
    }

    /// 源品牌的库存记录数（非隐藏且有库存的色号数）
    private var sourceStockCount: Int {
        guard let id = sourceBrandId else { return 0 }
        return inventoryManager.brandStocks.filter {
            $0.brandId == id && ($0.stock > 0 || $0.used > 0)
        }.count
    }

    /// 受影响的项目数
    private var affectedProjectCount: Int {
        guard let id = sourceBrandId else { return 0 }
        return inventoryManager.projects.filter { $0.brandId == id }.count
    }

    /// 受影响的购买记录数
    private var affectedPurchaseCount: Int {
        guard let id = sourceBrandId else { return 0 }
        return inventoryManager.purchaseRecords.filter { $0.brandId == id }.count
    }

    private var canMerge: Bool {
        guard let src = sourceBrandId, let tgt = targetBrandId else { return false }
        return src != tgt
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("源品牌（将被合并删除）", selection: $sourceBrandId) {
                        Text("请选择").tag(nil as UUID?)
                        ForEach(sortedBrands) { brand in
                            Text(brand.name).tag(brand.id as UUID?)
                        }
                    }

                    Picker("目标品牌（保留）", selection: $targetBrandId) {
                        Text("请选择").tag(nil as UUID?)
                        ForEach(sortedBrands.filter { $0.id != sourceBrandId }) { brand in
                            Text(brand.name).tag(brand.id as UUID?)
                        }
                    }
                } header: {
                    Text("选择品牌")
                } footer: {
                    Text("源品牌的所有数据将转移到目标品牌，源品牌随后被删除。")
                }

                if canMerge {
                    Section("合并预览") {
                        LabeledContent("库存色号数") {
                            Text("\(sourceStockCount) 个")
                        }
                        LabeledContent("关联项目") {
                            Text("\(affectedProjectCount) 个")
                        }
                        LabeledContent("购买记录") {
                            Text("\(affectedPurchaseCount) 个")
                        }
                    }
                }

                if canMerge {
                    Section {
                        Button(role: .destructive) {
                            showingConfirmation = true
                        } label: {
                            HStack {
                                Spacer()
                                Text("执行合并")
                                    .fontWeight(.semibold)
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle("合并品牌")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onChange(of: sourceBrandId) {
                if sourceBrandId != nil && sourceBrandId == targetBrandId {
                    targetBrandId = nil
                }
            }
            .alert("确认合并", isPresented: $showingConfirmation) {
                Button("取消", role: .cancel) {}
                Button("合并", role: .destructive) {
                    if let src = sourceBrandId, let tgt = targetBrandId {
                        inventoryManager.mergeBrands(sourceBrandId: src, targetBrandId: tgt)
                    }
                    dismiss()
                }
            } message: {
                if let src = sourceBrand, let tgt = targetBrand {
                    Text("将「\(src.name)」合并到「\(tgt.name)」，源品牌的库存、项目和购买记录将全部转移到目标品牌，此操作不可撤销。")
                }
            }
        }
    }
}

// MARK: - Nav target wrapper
fileprivate struct BrandNavTarget: Identifiable, Hashable {
    let id: UUID
}

#Preview {
    BrandManagerView()
        .environmentObject(InventoryManager())
}
