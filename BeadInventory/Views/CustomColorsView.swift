//
//  CustomColorsView.swift
//  BeadInventory
//
//  自定义色号管理 —— 二级页骨架（SecondaryNav + ScrollView + GroupCard）。
//  入口图标色 = mauve，本页 flavor 跟随；自定义色号在列表中用 honey 立边表示。
//

import SwiftUI

struct CustomColorsView: View {
    @EnvironmentObject var inventoryManager: InventoryManager

    @State private var showingAddSheet = false
    @State private var editingColor: CustomColor?
    @State private var searchText = ""
    @State private var showingSearch = false

    private let flavor = Theme.ColorToken.Morandi.mauve

    private var filteredColors: [CustomColor] {
        if searchText.isEmpty { return inventoryManager.customColors }
        let q = searchText.uppercased()
        return inventoryManager.customColors.filter {
            $0.colorCode.uppercased().contains(q) ||
            $0.colorName.uppercased().contains(q) ||
            $0.colorHex.uppercased().contains(q)
        }
    }

    private var totalStock: Int {
        var sum = 0
        for color in inventoryManager.customColors {
            for stock in inventoryManager.brandStocks where stock.mardCode == color.mardCode && !stock.isHidden {
                sum += stock.stock
            }
        }
        return sum
    }

    /// 启用过自定义色号的品牌数（任意自定义色号在该品牌下未隐藏）
    private var crossBrandCount: Int {
        let customCodes = Set(inventoryManager.customColors.map { $0.mardCode })
        var brandSet: Set<UUID> = []
        for stock in inventoryManager.brandStocks where customCodes.contains(stock.mardCode) && !stock.isHidden {
            brandSet.insert(stock.brandId)
        }
        return brandSet.count
    }

    var body: some View {
        VStack(spacing: 0) {
            BISecondaryNav(title: "自定义色号") {
                BINavIconButton(systemImage: showingSearch ? "xmark" : "magnifyingglass") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showingSearch.toggle()
                        if !showingSearch { searchText = "" }
                    }
                }
            }

            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(spacing: 12) {
                        infoPill
                        if showingSearch { searchField }
                        if !inventoryManager.customColors.isEmpty {
                            summaryCard
                        }
                        if inventoryManager.customColors.isEmpty {
                            emptyHero
                        } else if filteredColors.isEmpty {
                            noMatchHint
                        } else {
                            colorsList
                        }
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 110)
                }

                fabButton
                    .padding(.trailing, 18)
                    .padding(.bottom, 26)
            }
        }
        .background(Theme.ColorToken.Surface.background)
        .navigationBarHidden(true)
        .sheet(isPresented: $showingAddSheet) {
            CustomColorEditView(editingColor: nil)
        }
        .sheet(item: $editingColor) { color in
            CustomColorEditView(editingColor: color)
        }
    }

    // MARK: - Info pill

    private var infoPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(flavor)
            (Text("自定义色号仅在 ")
                + Text("MARD").bold().foregroundColor(Theme.ColorToken.Text.primary)
                + Text(" 体系下显示，切到卡卡时会隐藏。"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.ColorToken.Text.secondary)
                .lineSpacing(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(flavor.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(flavor.opacity(0.30), lineWidth: 1)
        )
        .padding(.horizontal, 18)
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ColorToken.Text.tertiary)
            TextField("搜索色号 / 名称 / HEX", text: $searchText)
                .font(.system(size: 14))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled(true)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.ColorToken.Text.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.ColorToken.Surface.subtle)
        )
        .padding(.horizontal, 18)
    }

    // MARK: - Summary

    private var summaryCard: some View {
        HStack(spacing: 0) {
            summaryCol(value: "\(inventoryManager.customColors.count)", suffix: "个", label: "自定义色")
            summaryDivider
            summaryCol(value: "\(totalStock)", suffix: "颗", label: "总库存")
            summaryDivider
            summaryCol(value: "\(crossBrandCount)", suffix: "家", label: "跨品牌")
        }
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.ColorToken.Surface.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
        )
        .padding(.horizontal, 18)
    }

    private func summaryCol(value: String, suffix: String, label: String) -> some View {
        VStack(spacing: 2) {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.ColorToken.Text.primary)
                Text(suffix)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ColorToken.Text.tertiary)
            }
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ColorToken.Text.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var summaryDivider: some View {
        Rectangle()
            .fill(Theme.ColorToken.Border.divider)
            .frame(width: 1)
            .padding(.vertical, 4)
    }

    // MARK: - List

    private var colorsList: some View {
        VStack(spacing: 8) {
            ForEach(filteredColors) { color in
                CustomColorCard(
                    color: color,
                    stockSummary: stockSummary(for: color)
                ) {
                    editingColor = color
                }
            }
        }
        .padding(.horizontal, 18)
    }

    fileprivate struct StockSummary {
        let totalStock: Int
        let enabledBrands: Int
        let isLow: Bool
    }

    private func stockSummary(for color: CustomColor) -> StockSummary {
        var totalStock = 0
        var enabledBrands = 0
        for stock in inventoryManager.brandStocks where stock.mardCode == color.mardCode {
            if !stock.isHidden {
                totalStock += stock.stock
                enabledBrands += 1
            }
        }
        // 低库存判定参考当前品牌阈值（默认 100）
        let threshold = inventoryManager.brands
            .first { $0.id == inventoryManager.currentBrandId }?
            .lowStockThreshold ?? 100
        return StockSummary(
            totalStock: totalStock,
            enabledBrands: enabledBrands,
            isLow: enabledBrands > 0 && totalStock < threshold
        )
    }

    // MARK: - No match

    private var noMatchHint: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundStyle(Theme.ColorToken.Text.tertiary)
            Text("没有匹配的自定义色号")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ColorToken.Text.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Empty hero

    private var emptyHero: some View {
        BIEmptyHero(
            icon: "paintpalette",
            flavor: flavor,
            title: "还没有自定义色号",
            subtitle: "点击右下角加号，添加你自己调出的颜色\n它只会在 MARD 体系下显示"
        ) {
            Button {
                showingAddSheet = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                    Text("添加自定义色号")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(
                    Capsule().fill(flavor)
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - FAB

    private var fabButton: some View {
        Button {
            showingAddSheet = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(flavor)
                )
                .shadow(color: flavor.opacity(0.35), radius: 12, x: 0, y: 6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - CustomColorCard

private struct CustomColorCard: View {
    let color: CustomColor
    let stockSummary: CustomColorsView.StockSummary
    let onTap: () -> Void

    private let honey = Theme.ColorToken.Morandi.honey

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                BeadView(color: color.color, size: 44, ring: honey)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(color.mardCode)
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.ColorToken.Text.primary)
                        customBadge
                    }

                    if !color.colorName.isEmpty {
                        Text(color.colorName)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ColorToken.Text.secondary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 4) {
                        Text("#\(color.colorHex.uppercased())")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(Theme.ColorToken.Text.tertiary)
                            .tracking(0.5)
                        Text("·")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.ColorToken.Text.tertiary)
                        Text("\(stockSummary.enabledBrands) 品牌")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.ColorToken.Text.tertiary)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(stockSummary.totalStock)")
                        .font(.system(size: 17, weight: .bold, design: .monospaced))
                        .foregroundStyle(stockSummary.isLow ? Theme.ColorToken.Status.error : Theme.ColorToken.Text.primary)
                    Text("库存")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.ColorToken.Text.tertiary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.Text.tertiary)
            }
            .padding(.vertical, 12)
            .padding(.leading, 14)
            .padding(.trailing, 14)
            .background(
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.ColorToken.Surface.elevated)
                    // 左侧 honey 立边
                    Rectangle()
                        .fill(honey)
                        .frame(width: 3)
                        .clipShape(
                            RoundedCornerShape(radius: 14, corners: [.topLeft, .bottomLeft])
                        )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var customBadge: some View {
        Text("自定义")
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(honey)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(
                Capsule().fill(honey.opacity(0.15))
            )
            .overlay(
                Capsule().strokeBorder(honey.opacity(0.30), lineWidth: 0.5)
            )
    }
}

// MARK: - Corner radius shape helper

private struct RoundedCornerShape: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

#Preview {
    NavigationStack {
        CustomColorsView()
            .environmentObject(InventoryManager())
    }
}
