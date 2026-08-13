//
//  ColorConverterView.swift
//  BeadInventory
//
//  色号转换 —— 二级页骨架（SecondaryNav + ScrollView + GroupCard）。
//  本页主调色 = Morandi.mauve（内部硬编码，不读 @Environment(\.tabFlavor)）。
//  铁律: 绝不为色号造中文名 —— 只显示 code + HEX + bead。
//

import SwiftUI

struct ColorConverterView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var searchText = ""
    @State private var onlyWithStock = false
    @State private var selectedColor: BeadColor?

    /// 当前品牌库存映射(mardCode → BrandStock)。"仅有库存" 筛选 + 详情面板读这里,
    /// 不读 BeadColor.stock/used/available(那是预设默认色,与当前品牌实际库存无关)。
    private var currentBrandStockDict: [String: BrandStock] {
        guard let brandId = inventoryManager.currentBrandId else { return [:] }
        let stocks = inventoryManager.brandStocks.filter { $0.brandId == brandId && !$0.isHidden }
        return Dictionary(uniqueKeysWithValues: stocks.map { ($0.mardCode, $0) })
    }

    private var searchResults: [BeadColor] {
        let results = inventoryManager.searchColors(searchText)
        if onlyWithStock {
            let dict = currentBrandStockDict
            return results.filter { (dict[$0.mardCode]?.available ?? 0) > 0 }
        }
        return results
    }

    /// 跨品牌覆盖数：在所有命中结果里,有多少个品牌字段至少有一个非空。
    private var brandsCovered: Int {
        var hasMARD = false, hasCOCO = false, hasManman = false
        var hasPanpan = false, hasMixiaowo = false, hasKaka = false
        for color in searchResults {
            if !color.mardCode.isEmpty { hasMARD = true }
            if !color.cocoCode.isEmpty { hasCOCO = true }
            if !color.manmanCode.isEmpty { hasManman = true }
            if !color.panpanCode.isEmpty { hasPanpan = true }
            if !color.mixiaowoCode.isEmpty { hasMixiaowo = true }
            if !color.kakaCode.isEmpty { hasKaka = true }
        }
        return [hasMARD, hasCOCO, hasManman, hasPanpan, hasMixiaowo, hasKaka].filter { $0 }.count
    }

    private var lowStockThreshold: Int {
        guard let brandId = inventoryManager.currentBrandId else { return 100 }
        return inventoryManager.getLowStockThreshold(for: brandId)
    }

    private let suggestionSeeds: [BeadColor] = [
        BeadColor(colorHex: "F4EAD9", mardCode: "A01"),
        BeadColor(colorHex: "C9928E", mardCode: "B12"),
        BeadColor(colorHex: "9FB089", mardCode: "D02"),
        BeadColor(colorHex: "C8966E", mardCode: "F05"),
        BeadColor(colorHex: "94A8B6", mardCode: "C04"),
        BeadColor(colorHex: "B196AE", mardCode: "E03"),
        BeadColor(colorHex: "F0DA88", mardCode: "A03"),
        BeadColor(colorHex: "7A5A3E", mardCode: "F01")
    ]

    var body: some View {
        VStack(spacing: 0) {
            BISecondaryNav(title: "色号转换")
            ScrollView {
                VStack(spacing: 14) {
                    searchField
                    if searchText.isEmpty {
                        emptyHero
                        suggestionsBlock
                    } else if searchResults.isEmpty {
                        BIEmptyHero(
                            icon: "magnifyingglass",
                            flavor: Theme.ColorToken.Morandi.mauve,
                            title: "未找到匹配的色号",
                            subtitle: "换个色号试试,支持 6 大色号体系"
                        )
                    } else {
                        resultsHeader
                        ForEach(searchResults) { color in
                            ConvCard(color: color, lowStockThreshold: lowStockThreshold)
                                .padding(.horizontal, 18)
                                .onTapGesture { selectedColor = color }
                        }
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
        }
        .background(Theme.ColorToken.Surface.background)
        .navigationBarHidden(true)
        .sheet(item: $selectedColor) { color in
            ColorDetailSheet(
                color: color,
                brandStock: currentBrandStockDict[color.mardCode],
                lowStockThreshold: lowStockThreshold
            )
        }
    }

    // MARK: - 搜索

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.ColorToken.Text.secondary)
            TextField("搜索任意品牌色号 · A01 / M-001 …", text: $searchText)
                .font(.system(size: 15, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.Text.primary)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
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
            Text("⌘K")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.Text.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
                )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
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

    // MARK: - 空态

    private var emptyHero: some View {
        BIEmptyHero(
            icon: "paintpalette",
            flavor: Theme.ColorToken.Morandi.mauve,
            title: "输入色号查询转换",
            subtitle: "支持 MARD · COCO · 漫漫 · 盼盼 · 咪小窝 · 卡卡 6 大色号体系"
        )
    }

    private var suggestionsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("试试搜这些")
                .font(.system(size: 12))
                .foregroundStyle(Theme.ColorToken.Text.secondary)
                .padding(.leading, 22)
            FlowSuggestions(seeds: suggestionSeeds) { seed in
                searchText = seed.mardCode
            }
            .padding(.horizontal, 18)
        }
    }

    // MARK: - 结果头

    private var resultsHeader: some View {
        HStack(spacing: 6) {
            Text("找到")
                .font(.system(size: 12))
                .foregroundStyle(Theme.ColorToken.Text.secondary)
            Text("\(searchResults.count)")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.Morandi.mauve)
            Text("个匹配 · 跨")
                .font(.system(size: 12))
                .foregroundStyle(Theme.ColorToken.Text.secondary)
            Text("\(brandsCovered)")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.Morandi.mauve)
            Text("个品牌")
                .font(.system(size: 12))
                .foregroundStyle(Theme.ColorToken.Text.secondary)
            Spacer()
            Button {
                onlyWithStock.toggle()
            } label: {
                BIChip("仅有库存", active: onlyWithStock, color: Theme.ColorToken.Morandi.mauve, size: .sm)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
    }
}

// MARK: - Conv Card

private struct ConvCard: View {
    let color: BeadColor
    var lowStockThreshold: Int

    private var hex: String { "#" + color.colorHex.uppercased() }

    var body: some View {
        VStack(spacing: 0) {
            // 源色头
            HStack(spacing: 14) {
                BeadView(color: color.color, size: 52)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(color.mardCode)
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.ColorToken.Text.primary)
                        BIChip("MARD", active: true, color: Theme.ColorToken.Morandi.mauve, size: .sm)
                    }
                    Text(hex)
                        .font(.system(size: 11, design: .monospaced))
                        .tracking(0.4)
                        .foregroundStyle(Theme.ColorToken.Text.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(
                LinearGradient(
                    colors: [color.color.opacity(0.18), Color.clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )

            // 跨品牌等价
            VStack(alignment: .leading, spacing: 8) {
                Text("跨品牌等价")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(Theme.ColorToken.Text.secondary)

                VStack(spacing: 6) {
                    brandRow(name: "MARD", code: color.mardCode)
                    brandRow(name: "COCO", code: color.cocoCode)
                    brandRow(name: "漫漫", code: color.manmanCode)
                    brandRow(name: "盼盼", code: color.panpanCode)
                    brandRow(name: "咪小窝", code: color.mixiaowoCode)
                    brandRow(name: "卡卡", code: color.kakaCode)
                }
            }
            .padding(14)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Theme.ColorToken.Border.divider)
                    .frame(height: 1)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Theme.ColorToken.Surface.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func brandRow(name: String, code: String) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Theme.ColorToken.Morandi.mauve)
                .frame(width: 6, height: 6)
            Text(name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ColorToken.Text.primary)
                .frame(minWidth: 60, alignment: .leading)
            Text(code.isEmpty ? "—" : code)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.Text.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Theme.ColorToken.Surface.elevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
                )
            Spacer()
            if code.isEmpty {
                BIChip("未收录", active: true, color: Theme.ColorToken.Morandi.rose, size: .sm)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.ColorToken.Surface.subtle)
        )
    }
}

// MARK: - Suggestion flow

private struct FlowSuggestions: View {
    let seeds: [BeadColor]
    let onTap: (BeadColor) -> Void

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 88), spacing: 8)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(seeds) { seed in
                Button {
                    onTap(seed)
                } label: {
                    HStack(spacing: 6) {
                        BeadView(color: seed.color, size: 20)
                        Text(seed.mardCode)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.ColorToken.Text.primary)
                    }
                    .padding(.leading, 5)
                    .padding(.trailing, 11)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(Theme.ColorToken.Surface.elevated)
                    )
                    .overlay(
                        Capsule().strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Detail sheet

struct ColorDetailSheet: View {
    let color: BeadColor
    /// 当前品牌该色号的库存（由外层传入）。读 BrandStock 而非 BeadColor 的静态字段。
    var brandStock: BrandStock?
    var lowStockThreshold: Int = 100
    @Environment(\.dismiss) private var dismiss

    private var currentStock: Int { brandStock?.stock ?? 0 }
    private var currentUsed: Int { brandStock?.used ?? 0 }
    private var currentAvailable: Int { brandStock?.available ?? 0 }
    private var isLowStock: Bool { currentAvailable < lowStockThreshold }
    private var isCustomColor: Bool { color.mardCode.hasPrefix("#") }
    private var hex: String { "#" + color.colorHex.uppercased() }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Theme.ColorToken.Border.default)
                .frame(width: 40, height: 4)
                .padding(.top, 6)
                .padding(.bottom, 14)

            ScrollView {
                VStack(spacing: 14) {
                    // 头部
                    HStack(spacing: 14) {
                        BeadView(
                            color: color.color,
                            size: 56,
                            ring: isCustomColor ? Theme.ColorToken.Morandi.honey : nil
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            Text(color.mardCode)
                                .font(.system(size: 20, weight: .bold, design: .monospaced))
                                .foregroundStyle(Theme.ColorToken.Text.primary)
                            Text(hex)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.ColorToken.Text.tertiary)
                            // 自定义色号才显示用户取的名字
                            if isCustomColor && !color.colorName.isEmpty {
                                Text(color.colorName)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                                    .padding(.top, 2)
                            }
                        }
                        Spacer()
                        Button {
                            UIPasteboard.general.string = hex
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.ColorToken.Morandi.mauve)
                                .frame(width: 36, height: 36)
                                .background(
                                    RoundedRectangle(cornerRadius: 11)
                                        .fill(Theme.ColorToken.Morandi.mauve.opacity(0.12))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 22)

                    // 跨品牌对照
                    BIGroupCard(title: "跨品牌等价") {
                        codeRow(brand: "MARD", code: color.mardCode, isLast: false)
                        codeRow(brand: "COCO", code: color.cocoCode, isLast: false)
                        codeRow(brand: "漫漫", code: color.manmanCode, isLast: false)
                        codeRow(brand: "盼盼", code: color.panpanCode, isLast: false)
                        codeRow(brand: "咪小窝", code: color.mixiaowoCode, isLast: false)
                        codeRow(brand: "卡卡", code: color.kakaCode, isLast: true)
                    }

                    // 库存（基于当前品牌的 BrandStock，不是 BeadColor 的静态默认值）
                    BIGroupCard(title: "库存信息") {
                        infoRow(label: "总库存", value: "\(currentStock)", color: .primary, isLast: false)
                        infoRow(label: "已使用", value: "\(currentUsed)", color: .warning, isLast: false)
                        infoRow(label: "可用数量", value: "\(currentAvailable)", color: isLowStock ? .error : .primary, isLast: true)
                    }
                }
                .padding(.bottom, 30)
            }
        }
        .background(Theme.ColorToken.Surface.background)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }

    private enum ValueColor { case primary, warning, error }

    private func codeRow(brand: String, code: String, isLast: Bool) -> some View {
        HStack(spacing: 10) {
            Text(brand)
                .font(.system(size: 13))
                .foregroundStyle(Theme.ColorToken.Text.secondary)
                .frame(minWidth: 60, alignment: .leading)
            Spacer()
            if code.isEmpty {
                Text("—")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.ColorToken.Text.tertiary)
            } else {
                Text(code)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.ColorToken.Text.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Theme.ColorToken.Surface.subtle)
                    )
                Button {
                    UIPasteboard.general.string = code
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.ColorToken.Morandi.mauve)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(Theme.ColorToken.Border.divider)
                    .frame(height: 1)
                    .padding(.leading, 70)
            }
        }
    }

    private func infoRow(label: String, value: String, color: ValueColor, isLast: Bool) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(Theme.ColorToken.Text.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(valueColor(color))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(Theme.ColorToken.Border.divider)
                    .frame(height: 1)
                    .padding(.leading, 14)
            }
        }
    }

    private func valueColor(_ c: ValueColor) -> Color {
        switch c {
        case .primary: return Theme.ColorToken.Text.primary
        case .warning: return Theme.ColorToken.Status.warning
        case .error: return Theme.ColorToken.Status.error
        }
    }
}

#Preview {
    NavigationStack {
        ColorConverterView()
            .environmentObject(InventoryManager())
    }
}
