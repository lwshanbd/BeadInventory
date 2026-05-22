//
//  ShippingView.swift
//  BeadInventory
//
//  运输中（待到货的购买记录）—— 二级页骨架（SecondaryNav + ScrollView + GroupCard）。
//  入口图标色 = latte，本页 flavor 跟随。
//

import SwiftUI

// MARK: - 主页：运输中
struct ShippingView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var showingAddPurchase = false
    @State private var showingPasteSheet = false
    @State private var pasteError: String?
    @State private var showingPasteError = false
    @State private var selectedFilter: ShippingFilter = .all

    enum ShippingFilter: String, CaseIterable {
        case all, shipped, pending
        var label: String {
            switch self {
            case .all: return "全部"
            case .shipped: return "已发货"
            case .pending: return "待发货"
            }
        }
    }

    private var allRecords: [PurchaseRecord] {
        inventoryManager.purchaseRecords
    }

    private var filteredRecords: [PurchaseRecord] {
        // 当前数据模型没有显式 status；按"是否有 note" 简单作分类示意（保持现有数据流不动）。
        switch selectedFilter {
        case .all: return allRecords
        case .shipped, .pending: return allRecords
        }
    }

    private var totalBeads: Int {
        allRecords.reduce(0) { $0 + $1.totalBeads }
    }

    private var nearestEta: String? {
        guard let latest = allRecords.sorted(by: { $0.date > $1.date }).first else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: latest.date)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                BISecondaryNav(title: "运输中") {
                    BINavIconButton(systemImage: "doc.on.clipboard") {
                        showingPasteSheet = true
                    }
                    BINavIconButton(systemImage: "plus") {
                        showingAddPurchase = true
                    }
                }

                if allRecords.isEmpty {
                    ScrollView {
                        BIEmptyHero(
                            icon: "shippingbox",
                            flavor: Theme.ColorToken.Morandi.latte,
                            title: "还没有运输中的订单",
                            subtitle: "下单后记一笔，到货时自动加到库存里。"
                        ) {
                            HStack(spacing: 10) {
                                Button {
                                    showingAddPurchase = true
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "plus")
                                        Text("添加购买记录")
                                    }
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(
                                        Theme.ColorToken.Morandi.latte,
                                        in: RoundedRectangle(cornerRadius: Theme.Radius.md)
                                    )
                                }
                                .buttonStyle(.plain)

                                Button {
                                    showingPasteSheet = true
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "sparkles")
                                        Text("从剪贴板粘贴")
                                    }
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.ColorToken.Morandi.latte)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(
                                        Theme.ColorToken.Morandi.latte.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: Theme.Radius.md)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 14) {
                            overviewHero
                            filterChipRow
                            recordList
                            pasteHintCard
                        }
                        .padding(.bottom, 100)
                    }
                }
            }
            .background(Theme.ColorToken.Surface.background)

            if !allRecords.isEmpty {
                fab
            }
        }
        .navigationBarHidden(true)
        .environment(\.tabFlavor, .inventory)
        .sheet(isPresented: $showingAddPurchase) {
            AddPurchaseRecordView()
                .environmentObject(inventoryManager)
        }
        .sheet(isPresented: $showingPasteSheet) {
            PasteReplenishSheet()
                .environmentObject(inventoryManager)
        }
        .alert("粘贴失败", isPresented: $showingPasteError) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(pasteError ?? "未知错误")
        }
    }

    // MARK: - Overview hero
    private var overviewHero: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("待到货")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.88))
                HStack(alignment: .lastTextBaseline, spacing: 5) {
                    Text("\(allRecords.count)")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("单 · 共 \(totalBeads) 颗")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.9))
                }
                if let eta = nearestEta {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 10, weight: .semibold))
                        Text("最近到货 · \(eta)")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color.white.opacity(0.18))
                    )
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 60, height: 60)
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(.white)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Theme.ColorToken.Morandi.latte, Theme.ColorToken.Morandi.honey],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .shadow(color: Theme.ColorToken.Morandi.latte.opacity(0.25), radius: 12, x: 0, y: 4)
        .padding(.horizontal, 18)
        .padding(.top, 8)
    }

    // MARK: - Filter chips
    private var filterChipRow: some View {
        HStack(spacing: 6) {
            ForEach(ShippingFilter.allCases, id: \.self) { filter in
                Button {
                    selectedFilter = filter
                } label: {
                    BIChip(
                        "\(filter.label) · \(allRecords.count)",
                        active: selectedFilter == filter,
                        color: Theme.ColorToken.Morandi.latte,
                        size: .sm
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            BIChip(label: "新→旧", active: false, color: nil, size: .sm) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
            }
        }
        .padding(.horizontal, 18)
    }

    // MARK: - Record list
    private var recordList: some View {
        VStack(spacing: 10) {
            ForEach(filteredRecords) { record in
                NavigationLink {
                    PurchaseRecordDetailView(record: record)
                } label: {
                    ShippingCard(record: record)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
    }

    // MARK: - Paste hint card
    private var pasteHintCard: some View {
        Button {
            showingPasteSheet = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.Morandi.honey)
                VStack(alignment: .leading, spacing: 2) {
                    Text("从剪贴板粘贴订单")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ColorToken.Text.primary)
                    Text("识别补豆建议 CSV，一键生成运输单")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.Text.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.ColorToken.Surface.subtle)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        Theme.ColorToken.Border.default,
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
        .padding(.top, 4)
    }

    // MARK: - FAB
    private var fab: some View {
        Button {
            showingAddPurchase = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Theme.ColorToken.Morandi.latte)
                )
                .shadow(color: Theme.ColorToken.Morandi.latte.opacity(0.4), radius: 14, x: 0, y: 6)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 18)
        .padding(.bottom, 30)
    }
}

// MARK: - 运输卡（设计稿 ShippingCard）
struct ShippingCard: View {
    let record: PurchaseRecord
    @EnvironmentObject var inventoryManager: InventoryManager

    private var brand: Brand? {
        inventoryManager.brands.first(where: { $0.id == record.brandId })
    }

    private var brandName: String {
        brand?.name ?? String(localized: "未知品牌")
    }

    private var brandColorSystem: ColorSystem {
        brand?.colorSystem ?? .mard
    }

    // 当前数据模型没有 status；按"创建是否近 3 天"做轻量近似 (>3天=已发货)
    private var isShipped: Bool {
        Date().timeIntervalSince(record.date) > 60 * 60 * 24 * 3
    }

    private var statusLabel: String { isShipped ? "已发货" : "待发货" }
    private var subStatus: String {
        if isShipped {
            return "运输中 · 即将到达"
        } else {
            return "已下单 · 等待商家发货"
        }
    }

    private var etaText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        let est = record.date.addingTimeInterval(60 * 60 * 24 * 6)
        return "预计 \(formatter.string(from: est))"
    }

    private var totalAmount: Int {
        // 估算金额（兜底显示，业务实际未维护单价）
        max(1, record.totalBeads / 100 * 2 / 10)
    }

    private var previewColors: [Color] {
        record.items.prefix(6).map { item in
            inventoryManager.findColor(byCode: item.colorCode)?.color ?? Color.gray
        }
    }

    private var extraColorCount: Int {
        max(0, record.items.count - 6)
    }

    var body: some View {
        VStack(spacing: 12) {
            // 顶行：tile + 品牌 + Badge + chevron
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            isShipped
                                ? Theme.ColorToken.Morandi.latte.opacity(0.18)
                                : Theme.ColorToken.Text.tertiary.opacity(0.18)
                        )
                        .frame(width: 38, height: 38)
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(
                            isShipped
                                ? Theme.ColorToken.Morandi.latte
                                : Theme.ColorToken.Text.secondary
                        )
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(record.name.isEmpty ? brandName : record.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.ColorToken.Text.primary)
                            .lineLimit(1)
                        BIBadge(
                            statusLabel,
                            style: isShipped ? .accent : .neutral
                        )
                    }
                    Text("\(brandName) · \(subStatus)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.Text.tertiary)
            }

            // 数据条
            HStack(spacing: 0) {
                ShipStatCol(label: "色号", value: "\(record.colorCount)", suffix: "种")
                ShipDivider()
                ShipStatCol(label: "豆粒", value: formatNumber(record.totalBeads), suffix: "颗")
                ShipDivider()
                ShipStatCol(label: "金额", value: "\(totalAmount)", suffix: "元")
            }
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.ColorToken.Surface.subtle)
            )

            // 色块预览 + ETA pill
            HStack(spacing: 10) {
                HStack(spacing: 0) {
                    ForEach(Array(previewColors.enumerated()), id: \.offset) { idx, c in
                        BeadView(color: c, size: 22, ring: Theme.ColorToken.Surface.elevated)
                            .padding(.leading, idx == 0 ? 0 : -8)
                            .zIndex(Double(6 - idx))
                    }
                    if extraColorCount > 0 {
                        Text("+\(extraColorCount)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.ColorToken.Text.tertiary)
                            .padding(.leading, 6)
                    }
                }
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 11, weight: .semibold))
                    Text(etaText)
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(
                    isShipped ? Theme.ColorToken.Morandi.latte : Theme.ColorToken.Text.secondary
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(
                        isShipped
                            ? Theme.ColorToken.Morandi.latte.opacity(0.12)
                            : Theme.ColorToken.Surface.subtle
                    )
                )
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.ColorToken.Surface.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
        )
    }

    private func formatNumber(_ num: Int) -> String {
        if num >= 10000 {
            return String(format: "%.1fW", Double(num) / 10000)
        } else if num >= 1000 {
            return String(format: "%.1fK", Double(num) / 1000)
        }
        return "\(num)"
    }
}

private struct ShipStatCol: View {
    let label: String
    let value: String
    let suffix: String
    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
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
}

private struct ShipDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.ColorToken.Border.divider)
            .frame(width: 1)
            .padding(.vertical, 4)
    }
}

// MARK: - 粘贴补豆建议弹窗
struct PasteReplenishSheet: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss
    @State private var selectedBrandId: UUID?
    @State private var recordName = ""
    @State private var parsedItems: [(colorCode: String, grams: Int)] = []
    @State private var parseError: String?
    @State private var hasParsed = false

    var totalGrams: Int {
        parsedItems.reduce(0) { $0 + $1.grams }
    }

    var totalBeads: Int {
        parsedItems.reduce(0) { $0 + $1.grams * 100 }  // 1g = 100颗
    }

    /// 生成默认名称（基于日期）
    var defaultName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日补豆"
        return formatter.string(from: Date())
    }

    var canSave: Bool {
        selectedBrandId != nil && !parsedItems.isEmpty
    }

    var selectedBrand: Brand? {
        guard let id = selectedBrandId else { return nil }
        return inventoryManager.brands.first { $0.id == id }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !hasParsed {
                    // 粘贴前的提示
                    VStack(spacing: 20) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 60))
                            .foregroundColor(Theme.ColorToken.Morandi.latte)

                        Text("粘贴补豆建议")
                            .font(.title2)
                            .fontWeight(.bold)

                        Text("请先在「补豆建议」页面复制 CSV，\n然后点击下方按钮粘贴")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)

                        Text("CSV 格式：色号,克数")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Theme.ColorToken.Surface.subtle)
                            .cornerRadius(Theme.Radius.sm)

                        Button {
                            parseClipboard()
                        } label: {
                            HStack {
                                Image(systemName: "doc.on.clipboard.fill")
                                Text("从剪贴板粘贴")
                            }
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 14)
                            .background(Theme.ColorToken.Morandi.latte)
                            .cornerRadius(Theme.Radius.lg)
                        }

                        if let error = parseError {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(Theme.ColorToken.Status.error)
                                .padding(.top, 8)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    // 解析成功后的预览
                    ScrollView {
                        VStack(spacing: 16) {
                            // 品牌选择
                            VStack(alignment: .leading, spacing: 8) {
                                Text("选择品牌")
                                    .font(.headline)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 10) {
                                        ForEach(inventoryManager.brands) { brand in
                                            Button {
                                                selectedBrandId = brand.id
                                            } label: {
                                                Text(brand.name)
                                                    .font(.subheadline)
                                                    .padding(.horizontal, 16)
                                                    .padding(.vertical, 10)
                                                    .background(selectedBrandId == brand.id ? Theme.ColorToken.Morandi.latte : Theme.ColorToken.Surface.subtle)
                                                    .foregroundColor(selectedBrandId == brand.id ? .white : Theme.ColorToken.Text.primary)
                                                    .cornerRadius(Theme.Radius.lg)
                                            }
                                        }
                                    }
                                }
                            }
                            .padding()
                            .background(Theme.ColorToken.Surface.elevated)
                            .cornerRadius(Theme.Radius.md)
                            .padding(.horizontal)

                            // 记录名称
                            HStack {
                                Text("名称")
                                    .foregroundColor(.secondary)
                                TextField("默认：\(defaultName)", text: $recordName)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Theme.ColorToken.Surface.subtle)
                                    .cornerRadius(Theme.Radius.sm)
                            }
                            .padding(.horizontal)

                            // 汇总信息
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("共 \(parsedItems.count) 色")
                                        .font(.headline)
                                    Text("\(totalGrams)g（\(totalBeads) 颗）")
                                        .font(.subheadline)
                                        .foregroundColor(Theme.ColorToken.Status.success)
                                }
                                Spacer()
                                Button("重新粘贴") {
                                    hasParsed = false
                                    parsedItems = []
                                    parseError = nil
                                }
                                .font(.subheadline)
                                .foregroundColor(Theme.ColorToken.Morandi.latte)
                            }
                            .padding()
                            .background(Theme.ColorToken.Status.success.opacity(0.1))
                            .cornerRadius(Theme.Radius.md)
                            .padding(.horizontal)

                            // 颜色列表预览
                            VStack(alignment: .leading, spacing: 8) {
                                Text("补豆明细")
                                    .font(.headline)
                                    .padding(.horizontal)

                                ForEach(parsedItems, id: \.colorCode) { item in
                                    PasteItemRow(
                                        colorCode: item.colorCode,
                                        grams: item.grams,
                                        colorSystem: selectedBrand?.colorSystem ?? .mard
                                    )
                                }
                                .padding(.horizontal)
                            }
                        }
                        .padding(.vertical)
                    }

                    // 底部保存按钮
                    VStack(spacing: 0) {
                        Divider()
                        Button {
                            saveRecord()
                        } label: {
                            Text("保存到运输中")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(canSave ? Theme.ColorToken.Morandi.latte : Theme.ColorToken.Text.tertiary)
                                .cornerRadius(Theme.Radius.md)
                        }
                        .disabled(!canSave)
                        .padding()
                    }
                    .background(Theme.ColorToken.Surface.elevated)
                }
            }
            .background(Theme.ColorToken.Surface.background)
            .navigationTitle("粘贴补豆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .foregroundColor(Theme.ColorToken.Morandi.latte)
                }
            }
        }
    }

    func parseClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            parseError = "剪贴板为空"
            return
        }

        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard lines.count > 1 else {
            parseError = "数据格式错误：至少需要标题行和一行数据"
            return
        }

        // 跳过标题行
        var items: [(colorCode: String, grams: Int)] = []
        for line in lines.dropFirst() {
            let parts = line.components(separatedBy: ",")
            guard parts.count >= 2 else { continue }
            let colorCode = parts[0].trimmingCharacters(in: .whitespaces)
            guard let grams = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            if grams > 0 {
                items.append((colorCode, grams))
            }
        }

        if items.isEmpty {
            parseError = "未找到有效数据"
            return
        }

        parsedItems = items
        hasParsed = true
        parseError = nil

        // 默认选中第一个品牌
        if selectedBrandId == nil, let firstBrand = inventoryManager.brands.first {
            selectedBrandId = firstBrand.id
        }
    }

    func saveRecord() {
        guard let brandId = selectedBrandId else { return }

        // PurchaseItem.colorCode 约定为 mardCode（confirmPurchaseRecord / inTransitQuantity 都按此匹配）。
        // 用户粘贴的可能是非 MARD 体系的色号，这里按品牌色号体系翻译为 mardCode 后再保存。
        let colorSystem = selectedBrand?.colorSystem ?? .mard
        let items = parsedItems.map { item -> PurchaseItem in
            let resolvedMardCode: String
            if colorSystem == .mard {
                resolvedMardCode = item.colorCode
            } else if let match = inventoryManager.findColor(byCode: item.colorCode, preferSystem: colorSystem) {
                resolvedMardCode = match.mardCode
            } else {
                // 无法在品牌色号体系中识别，保留原始输入（落入库存匹配失败的一致兜底）
                resolvedMardCode = item.colorCode
            }
            return PurchaseItem(colorCode: resolvedMardCode, quantity: item.grams * 100)  // 克数转颗数
        }

        let finalName = recordName.trimmingCharacters(in: .whitespaces).isEmpty ? defaultName : recordName

        inventoryManager.addPurchaseRecord(
            name: finalName,
            brandId: brandId,
            items: items,
            note: "从补豆建议粘贴"
        )

        dismiss()
    }
}

// MARK: - 粘贴项行
struct PasteItemRow: View {
    let colorCode: String
    let grams: Int
    var colorSystem: ColorSystem = .mard
    @EnvironmentObject var inventoryManager: InventoryManager

    var beadColor: BeadColor? {
        inventoryManager.findColor(byCode: colorCode, preferSystem: colorSystem)
            ?? inventoryManager.findColor(byCode: colorCode)
    }

    var displayColor: Color {
        beadColor?.color ?? .gray
    }

    var displayCodeText: String {
        beadColor?.displayCode(for: colorSystem) ?? colorCode
    }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(displayColor)
                .frame(width: 36, height: 36)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
                )

            Text(displayCodeText)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)

            Spacer()

            Text("\(grams)g")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("+\(grams * 100)")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(Theme.ColorToken.Status.success)
        }
        .padding(10)
        .background(Theme.ColorToken.Surface.elevated)
        .cornerRadius(Theme.Radius.md)
    }
}

// MARK: - 购买记录详情
struct PurchaseRecordDetailView: View {
    let record: PurchaseRecord
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss
    @State private var showingConfirmation = false
    @State private var showingDeleteConfirmation = false
    @State private var showingEditSheet = false
    @State private var showingMoreMenu = false

    // 获取最新的记录数据
    var currentRecord: PurchaseRecord {
        inventoryManager.purchaseRecords.first(where: { $0.id == record.id }) ?? record
    }

    var brand: Brand? {
        inventoryManager.brands.first(where: { $0.id == currentRecord.brandId })
    }

    var brandName: String {
        brand?.name ?? String(localized: "未知品牌")
    }

    var brandColorSystem: ColorSystem {
        brand?.colorSystem ?? .mard
    }

    private var orderDateText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter.string(from: currentRecord.date)
    }

    private var isShipped: Bool {
        Date().timeIntervalSince(currentRecord.date) > 60 * 60 * 24 * 3
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                BISecondaryNav(title: "购买详情") {
                    BINavIconButton(systemImage: "square.and.pencil") {
                        showingEditSheet = true
                    }
                    BINavIconButton(systemImage: "ellipsis") {
                        showingMoreMenu = true
                    }
                }

                ScrollView {
                    VStack(spacing: 16) {
                        statusHero
                        timelineCard
                        colorListCard
                        if let note = currentRecord.note, !note.isEmpty {
                            noteCard(note)
                        }
                        Color.clear.frame(height: 110)
                    }
                    .padding(.top, 8)
                }
            }
            .background(Theme.ColorToken.Surface.background)

            stickyBottomCTA
        }
        .navigationBarHidden(true)
        .environment(\.tabFlavor, .inventory)
        .sheet(isPresented: $showingEditSheet) {
            EditPurchaseRecordSheet(record: currentRecord)
                .environmentObject(inventoryManager)
        }
        .confirmationDialog("更多操作", isPresented: $showingMoreMenu, titleVisibility: .visible) {
            Button("编辑记录") { showingEditSheet = true }
            Button("删除记录", role: .destructive) { showingDeleteConfirmation = true }
            Button("取消", role: .cancel) { }
        }
        .alert("确认到货", isPresented: $showingConfirmation) {
            Button("取消", role: .cancel) { }
            Button("确认") {
                inventoryManager.confirmPurchaseRecord(id: record.id)
                dismiss()
            }
        } message: {
            Text("将把 \(currentRecord.colorCount) 种颜色共 \(currentRecord.totalBeads) 颗豆子添加到「\(brandName)」的库存中。")
        }
        .alert("删除记录", isPresented: $showingDeleteConfirmation) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) {
                inventoryManager.deletePurchaseRecord(id: record.id)
                dismiss()
            }
        } message: {
            Text("确定要删除这条购买记录吗？此操作不可撤销。")
        }
    }

    // MARK: Sub-views

    private var statusHero: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Theme.ColorToken.Morandi.latte, Theme.ColorToken.Morandi.honey],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 50, height: 50)
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(currentRecord.name.isEmpty ? brandName : currentRecord.name)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.ColorToken.Text.primary)
                        .lineLimit(1)
                    Text("\(brandName) · 下单 · \(orderDateText)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                }
                Spacer(minLength: 4)
                BIBadge(isShipped ? "运输中" : "待发货", style: .accent)
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(currentRecord.totalBeads)")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.ColorToken.Morandi.latte)
                    Text("颗")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ColorToken.Text.tertiary)
                }
                Rectangle()
                    .fill(Theme.ColorToken.Border.divider)
                    .frame(width: 1, height: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(currentRecord.colorCount)")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.ColorToken.Text.primary)
                    Text("色")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ColorToken.Text.tertiary)
                }
                Spacer(minLength: 0)
            }
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
        .padding(.horizontal, 18)
    }

    private var timelineCard: some View {
        VStack(spacing: 0) {
            BIGroupHeader(title: "物流进度", hint: isShipped ? "运输中" : "待发货")
            BIGroupCard {
                ShipTimeline(orderDate: currentRecord.date, isShipped: isShipped)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
            }
        }
    }

    private var colorListCard: some View {
        VStack(spacing: 0) {
            BIGroupHeader(
                title: "包含色号",
                hint: "\(currentRecord.colorCount) 种 · \(currentRecord.totalBeads) 颗"
            )
            BIGroupCard {
                VStack(spacing: 0) {
                    ForEach(Array(currentRecord.items.enumerated()), id: \.element.id) { idx, item in
                        DetailColorRow(
                            item: item,
                            colorSystem: brandColorSystem,
                            isLast: idx == currentRecord.items.count - 1
                        )
                    }
                }
            }
        }
    }

    private func noteCard(_ note: String) -> some View {
        VStack(spacing: 0) {
            BIGroupHeader(title: "备注")
            BIGroupCard {
                Text(note)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
        }
    }

    private var stickyBottomCTA: some View {
        HStack(spacing: 8) {
            Button {
                showingEditSheet = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.pencil")
                    Text("编辑")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ColorToken.Morandi.latte)
                .frame(height: 48)
                .padding(.horizontal, 18)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .fill(Theme.ColorToken.Morandi.latte.opacity(0.12))
                )
            }
            .buttonStyle(.plain)

            Button {
                showingConfirmation = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                    Text("标记为已到货 · 加入库存")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .fill(Theme.ColorToken.Morandi.latte)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 30)
        .background(
            LinearGradient(
                colors: [Theme.ColorToken.Surface.background.opacity(0), Theme.ColorToken.Surface.background],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }
}

// MARK: - 物流时间轴
private struct ShipTimeline: View {
    let orderDate: Date
    let isShipped: Bool

    private struct Step {
        let label: String
        let date: String
        let done: Bool
        let current: Bool
    }

    private var steps: [Step] {
        let fmt = DateFormatter()
        fmt.dateFormat = "M/d"
        let order = fmt.string(from: orderDate)
        let ship = fmt.string(from: orderDate.addingTimeInterval(60 * 60 * 24 * 1))
        let transit = fmt.string(from: orderDate.addingTimeInterval(60 * 60 * 24 * 2))
        let eta = fmt.string(from: orderDate.addingTimeInterval(60 * 60 * 24 * 6))
        return [
            Step(label: "已下单", date: order, done: true, current: !isShipped),
            Step(label: "商家发货", date: ship, done: isShipped, current: false),
            Step(label: "运输中", date: transit, done: isShipped, current: isShipped),
            Step(label: "签收", date: "预 \(eta)", done: false, current: false),
        ]
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { idx, step in
                stepView(step)
                if idx < steps.count - 1 {
                    Rectangle()
                        .fill(steps[idx + 1].done ? Theme.ColorToken.Morandi.latte : Theme.ColorToken.Border.default)
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
            }
        }
    }

    @ViewBuilder
    private func stepView(_ step: Step) -> some View {
        VStack(spacing: 4) {
            ZStack {
                if step.current {
                    Circle()
                        .strokeBorder(Theme.ColorToken.Morandi.latte.opacity(0.3), lineWidth: 3)
                        .frame(width: 24, height: 24)
                }
                Circle()
                    .fill(step.done ? Theme.ColorToken.Morandi.latte : Theme.ColorToken.Surface.strong)
                    .frame(width: 18, height: 18)
                if step.done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            Text(step.label)
                .font(.system(size: 10, weight: step.current ? .bold : .medium))
                .foregroundStyle(step.done ? Theme.ColorToken.Text.primary : Theme.ColorToken.Text.tertiary)
            Text(step.date)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.Text.tertiary)
        }
        .frame(width: 60)
    }
}

// MARK: - 详情页色号行
private struct DetailColorRow: View {
    let item: PurchaseItem
    let colorSystem: ColorSystem
    let isLast: Bool
    @EnvironmentObject var inventoryManager: InventoryManager

    private var beadColor: BeadColor? {
        inventoryManager.findColor(byCode: item.colorCode)
    }

    private var displayColor: Color {
        beadColor?.color ?? .gray
    }

    private var displayCodeText: String {
        beadColor?.displayCode(for: colorSystem) ?? item.colorCode
    }

    var body: some View {
        HStack(spacing: 12) {
            BeadView(color: displayColor, size: 28)
            HStack(spacing: 8) {
                Text(displayCodeText)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.ColorToken.Text.primary)
            }
            Spacer(minLength: 8)
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text("+")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ColorToken.Text.tertiary)
                Text("\(item.quantity)")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.ColorToken.Morandi.latte)
                Text("颗")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ColorToken.Text.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(Theme.ColorToken.Border.divider)
                    .frame(height: 1)
                    .padding(.leading, 54)
            }
        }
    }
}

// MARK: - 购买项行（保留兼容，作为预览/复用）
struct PurchaseItemRow: View {
    let item: PurchaseItem
    var colorSystem: ColorSystem = .mard
    @EnvironmentObject var inventoryManager: InventoryManager

    var beadColor: BeadColor? {
        inventoryManager.findColor(byCode: item.colorCode)
    }

    var displayColor: Color {
        beadColor?.color ?? .gray
    }

    var displayCodeText: String {
        beadColor?.displayCode(for: colorSystem) ?? item.colorCode
    }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(displayColor)
                .frame(width: 36, height: 36)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
                )

            Text(displayCodeText)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)

            Spacer()

            Text("+\(item.quantity)")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(Theme.ColorToken.Status.success)
        }
        .padding(10)
        .background(Theme.ColorToken.Surface.elevated)
        .cornerRadius(Theme.Radius.md)
    }
}

// MARK: - 添加购买记录
struct AddPurchaseRecordView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss

    @State private var recordName = ""
    @State private var selectedBrandId: UUID?
    @State private var note = ""
    @State private var selectedColors: Set<UUID> = []
    @State private var quantities: [UUID: Double] = [:]
    @State private var selectedSeries = "A"

    /// 所选品牌的色号体系
    var selectedColorSystem: ColorSystem {
        guard let brandId = selectedBrandId,
              let brand = inventoryManager.brands.first(where: { $0.id == brandId }) else {
            return inventoryManager.currentColorSystem
        }
        return brand.colorSystem
    }

    var colorsInSeries: [BeadColor] {
        let sourceColors = selectedSeries == "#" ? inventoryManager.allBeadColors : inventoryManager.beadColors
        let system = selectedColorSystem
        let prefixes = system.standardPrefixes

        return sourceColors.filter { color in
            // 非 MARD 体系下仅显示有对应色号的颜色
            if system != .mard && !color.hasCode(for: system) {
                return false
            }

            let code = color.displayCode(for: system)

            if selectedSeries == "#" {
                return code.hasPrefix("#")
            } else if selectedSeries == "其他" {
                if code.hasPrefix("#") { return false }
                return !prefixes.contains { prefix in
                    if prefix == "ZG" {
                        return code.hasPrefix("ZG")
                    } else {
                        return code.hasPrefix(prefix) && !code.hasPrefix("ZG")
                    }
                }
            } else if selectedSeries == "ZG" {
                return code.hasPrefix("ZG")
            } else {
                if code.hasPrefix("ZG") { return false }
                return code.hasPrefix(selectedSeries)
            }
        }.sorted { $0.displayCode(for: system).localizedStandardCompare($1.displayCode(for: system)) == .orderedAscending }
    }

    var totalToAdd: Int {
        var total = 0
        for colorId in selectedColors {
            let qty = quantities[colorId] ?? 1.0
            total += Int(qty * 1000)
        }
        return total
    }

    var canSave: Bool {
        selectedBrandId != nil && !selectedColors.isEmpty
    }

    /// 生成默认名称（基于日期）
    var defaultName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日订单"
        return formatter.string(from: Date())
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 基本信息
                VStack(spacing: 12) {
                    // 记录名称（可选）
                    TextField("名称（可选，默认：\(defaultName)）", text: $recordName)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Theme.ColorToken.Surface.subtle)
                        .cornerRadius(Theme.Radius.sm)

                    // 品牌选择
                    HStack {
                        Text("入库品牌:")
                            .foregroundColor(.secondary)
                        Spacer()
                        Picker("品牌", selection: $selectedBrandId) {
                            Text("请选择").tag(nil as UUID?)
                            ForEach(inventoryManager.brands) { brand in
                                Text(brand.name).tag(brand.id as UUID?)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(Theme.ColorToken.Morandi.latte)
                    }

                    // 备注
                    TextField("备注（可选）", text: $note)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Theme.ColorToken.Surface.subtle)
                        .cornerRadius(Theme.Radius.sm)
                }
                .padding()
                .background(Theme.ColorToken.Surface.elevated)

                // 色系选择器
                SeriesSelector(
                    series: selectedColorSystem.colorSeries,
                    selectedSeries: $selectedSeries
                )
                .padding(.vertical, 8)

                // 颜色列表
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(colorsInSeries) { color in
                            ColorAddRow(
                                color: color,
                                isSelected: selectedColors.contains(color.id),
                                quantity: Binding(
                                    get: { quantities[color.id] ?? 1.0 },
                                    set: { quantities[color.id] = $0 }
                                ),
                                onToggle: {
                                    toggleSelection(color.id)
                                },
                                colorSystem: selectedColorSystem
                            )
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 100)
                }
                .scrollDismissesKeyboard(.immediately)
                .onChange(of: selectedBrandId) { _, _ in
                    // 切换品牌时重置系列选择
                    selectedSeries = selectedColorSystem.defaultSeries
                    selectedColors.removeAll()
                    quantities.removeAll()
                }

                // 底部确认栏
                if !selectedColors.isEmpty {
                    VStack(spacing: 0) {
                        Divider()

                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("已选择 \(selectedColors.count) 色")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Text("共 +\(formatNumber(totalToAdd)) 颗")
                                    .font(.headline)
                                    .foregroundColor(Theme.ColorToken.Status.success)
                            }

                            Spacer()

                            Button(action: savePurchaseRecord) {
                                Text("保存记录")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 12)
                                    .background(canSave ? Theme.ColorToken.Morandi.latte : Theme.ColorToken.Text.tertiary)
                                    .cornerRadius(Theme.Radius.lg)
                            }
                            .disabled(!canSave)
                        }
                        .padding()
                        .background(Theme.ColorToken.Surface.elevated)
                    }
                }
            }
            .background(Theme.ColorToken.Surface.background)
            .navigationTitle("添加购买记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .foregroundColor(Theme.ColorToken.Morandi.latte)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            selectAllInSeries()
                        } label: {
                            Label("全选本色系", systemImage: "checkmark.circle")
                        }

                        Button {
                            selectedColors.removeAll()
                            quantities.removeAll()
                        } label: {
                            Label("全部取消", systemImage: "circle")
                        }
                    } label: {
                        Text("快速选择")
                            .foregroundColor(Theme.ColorToken.Morandi.latte)
                    }
                }
            }
        }
    }

    func toggleSelection(_ colorId: UUID) {
        if selectedColors.contains(colorId) {
            selectedColors.remove(colorId)
            quantities.removeValue(forKey: colorId)
        } else {
            selectedColors.insert(colorId)
            if quantities[colorId] == nil {
                quantities[colorId] = 1.0
            }
        }
    }

    func selectAllInSeries() {
        for color in colorsInSeries {
            selectedColors.insert(color.id)
            if quantities[color.id] == nil {
                quantities[color.id] = 1.0
            }
        }
    }

    func savePurchaseRecord() {
        guard let brandId = selectedBrandId else { return }

        var items: [PurchaseItem] = []
        for colorId in selectedColors {
            guard let color = inventoryManager.allBeadColors.first(where: { $0.id == colorId }) else { continue }
            let qty = quantities[colorId] ?? 1.0
            let amount = Int(qty * 1000)
            items.append(PurchaseItem(colorCode: color.mardCode, quantity: amount))
        }

        // 如果名称为空，使用默认名称
        let finalName = recordName.trimmingCharacters(in: .whitespaces).isEmpty ? defaultName : recordName

        inventoryManager.addPurchaseRecord(
            name: finalName,
            brandId: brandId,
            items: items,
            note: note.isEmpty ? nil : note
        )

        dismiss()
    }

    func formatNumber(_ num: Int) -> String {
        if num >= 10000 {
            return String(format: "%.1fW", Double(num) / 10000)
        } else if num >= 1000 {
            return String(format: "%.1fK", Double(num) / 1000)
        }
        return "\(num)"
    }
}

// MARK: - 编辑购买记录
struct EditPurchaseRecordSheet: View {
    let record: PurchaseRecord
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss

    @State private var recordName: String = ""
    @State private var selectedBrandId: UUID?
    @State private var note: String = ""
    @State private var items: [EditableItem] = []
    @State private var showingAddColor = false

    struct EditableItem: Identifiable {
        let id = UUID()
        var colorCode: String
        var quantity: Int  // 颗数
    }

    var totalBeads: Int {
        items.reduce(0) { $0 + $1.quantity }
    }

    var hasChanges: Bool {
        let nameChanged = recordName != record.name
        let brandChanged = selectedBrandId != record.brandId
        let noteChanged = note != (record.note ?? "")
        let itemsChanged = items.count != record.items.count ||
            !items.enumerated().allSatisfy { index, item in
                index < record.items.count &&
                item.colorCode == record.items[index].colorCode &&
                item.quantity == record.items[index].quantity
            }
        return nameChanged || brandChanged || noteChanged || itemsChanged
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 16) {
                        // 基本信息
                        VStack(spacing: 12) {
                            HStack {
                                Text("名称")
                                    .foregroundColor(.secondary)
                                TextField("记录名称", text: $recordName)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Theme.ColorToken.Surface.subtle)
                                    .cornerRadius(Theme.Radius.sm)
                            }

                            HStack {
                                Text("品牌")
                                    .foregroundColor(.secondary)
                                Spacer()
                                Picker("品牌", selection: $selectedBrandId) {
                                    ForEach(inventoryManager.brands) { brand in
                                        Text(brand.name).tag(brand.id as UUID?)
                                    }
                                }
                                .pickerStyle(.menu)
                                .tint(Theme.ColorToken.Morandi.latte)
                            }

                            HStack {
                                Text("备注")
                                    .foregroundColor(.secondary)
                                TextField("备注（可选）", text: $note)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Theme.ColorToken.Surface.subtle)
                                    .cornerRadius(Theme.Radius.sm)
                            }
                        }
                        .padding()
                        .background(Theme.ColorToken.Surface.elevated)
                        .cornerRadius(Theme.Radius.md)
                        .padding(.horizontal)

                        // 汇总信息
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("共 \(items.count) 色")
                                    .font(.headline)
                                Text("+\(totalBeads) 颗")
                                    .font(.subheadline)
                                    .foregroundColor(Theme.ColorToken.Status.success)
                            }
                            Spacer()
                            Button {
                                showingAddColor = true
                            } label: {
                                HStack {
                                    Image(systemName: "plus.circle.fill")
                                    Text("添加颜色")
                                }
                                .font(.subheadline)
                                .foregroundColor(Theme.ColorToken.Morandi.latte)
                            }
                        }
                        .padding()
                        .background(Theme.ColorToken.Surface.elevated)
                        .cornerRadius(Theme.Radius.md)
                        .padding(.horizontal)

                        // 颜色列表
                        VStack(alignment: .leading, spacing: 8) {
                            Text("购买明细")
                                .font(.headline)
                                .padding(.horizontal)

                            if items.isEmpty {
                                Text("暂无颜色")
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                            } else {
                                let editingColorSystem = selectedBrandId
                                    .flatMap { id in inventoryManager.brands.first { $0.id == id } }?.colorSystem ?? .mard
                                ForEach($items) { $item in
                                    EditableItemRow(
                                        item: $item,
                                        onDelete: {
                                            items.removeAll { $0.id == item.id }
                                        },
                                        colorSystem: editingColorSystem
                                    )
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                    .padding(.vertical)
                }

                // 底部保存按钮
                VStack(spacing: 0) {
                    Divider()
                    Button {
                        saveChanges()
                    } label: {
                        Text("保存修改")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(hasChanges && !items.isEmpty ? Theme.ColorToken.Morandi.latte : Theme.ColorToken.Text.tertiary)
                            .cornerRadius(Theme.Radius.md)
                    }
                    .disabled(!hasChanges || items.isEmpty)
                    .padding()
                }
                .background(Theme.ColorToken.Surface.elevated)
            }
            .background(Theme.ColorToken.Surface.background)
            .navigationTitle("编辑记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .foregroundColor(Theme.ColorToken.Morandi.latte)
                }
            }
            .onAppear {
                recordName = record.name
                selectedBrandId = record.brandId
                note = record.note ?? ""
                items = record.items.map { EditableItem(colorCode: $0.colorCode, quantity: $0.quantity) }
            }
            .sheet(isPresented: $showingAddColor) {
                AddColorToRecordSheet(brandId: selectedBrandId ?? record.brandId) { colorCode, quantity in
                    // 检查是否已存在该颜色
                    if let existingIndex = items.firstIndex(where: { $0.colorCode == colorCode }) {
                        items[existingIndex].quantity += quantity
                    } else {
                        items.append(EditableItem(colorCode: colorCode, quantity: quantity))
                    }
                }
                .environmentObject(inventoryManager)
            }
        }
    }

    func saveChanges() {
        let purchaseItems = items.map { PurchaseItem(colorCode: $0.colorCode, quantity: $0.quantity) }
        inventoryManager.updatePurchaseRecord(
            id: record.id,
            name: recordName,
            brandId: selectedBrandId,
            items: purchaseItems,
            note: note.isEmpty ? nil : note
        )
        dismiss()
    }
}

// MARK: - 可编辑项行
struct EditableItemRow: View {
    @Binding var item: EditPurchaseRecordSheet.EditableItem
    let onDelete: () -> Void
    var colorSystem: ColorSystem = .mard
    @EnvironmentObject var inventoryManager: InventoryManager

    var beadColor: BeadColor? {
        inventoryManager.findColor(byCode: item.colorCode)
    }

    var displayColor: Color {
        beadColor?.color ?? .gray
    }

    var displayCodeText: String {
        beadColor?.displayCode(for: colorSystem) ?? item.colorCode
    }

    var grams: Int {
        item.quantity / 100  // 100颗 = 1g
    }

    var body: some View {
        HStack(spacing: 12) {
            // 颜色预览
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(displayColor)
                .frame(width: 36, height: 36)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
                )

            // 色号（按品牌色号体系显示）
            Text(displayCodeText)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)

            Spacer()

            // 数量调整
            HStack(spacing: 8) {
                Button {
                    if item.quantity > 1000 {
                        item.quantity -= 1000
                    }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundColor(item.quantity > 1000 ? Theme.ColorToken.Morandi.latte : Theme.ColorToken.Text.tertiary)
                        .font(.title3)
                }
                .disabled(item.quantity <= 1000)

                VStack(spacing: 0) {
                    Text("\(item.quantity)")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(Theme.ColorToken.Status.success)
                    Text("\(grams)g")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(minWidth: 50)

                Button {
                    item.quantity += 1000
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(Theme.ColorToken.Morandi.latte)
                        .font(.title3)
                }
            }

            // 删除按钮
            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .foregroundColor(Theme.ColorToken.Status.error)
                    .font(.subheadline)
            }
            .padding(.leading, 8)
        }
        .padding(10)
        .background(Theme.ColorToken.Surface.elevated)
        .cornerRadius(Theme.Radius.md)
    }
}

// MARK: - 添加颜色到记录
struct AddColorToRecordSheet: View {
    let brandId: UUID
    let onAdd: (String, Int) -> Void

    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss

    @State private var selectedSeries = "A"
    @State private var selectedColorId: UUID?
    @State private var quantity: Double = 1.0  // 千颗

    /// 该记录品牌的色号体系
    var brandColorSystem: ColorSystem {
        inventoryManager.brands.first(where: { $0.id == brandId })?.colorSystem ?? .mard
    }

    var colorsInSeries: [BeadColor] {
        let sourceColors = selectedSeries == "#" ? inventoryManager.allBeadColors : inventoryManager.beadColors
        let system = brandColorSystem
        let prefixes = system.standardPrefixes

        return sourceColors.filter { color in
            // 非 MARD 体系下仅显示有对应色号的颜色
            if system != .mard && !color.hasCode(for: system) {
                return false
            }

            let code = color.displayCode(for: system)

            if selectedSeries == "#" {
                return code.hasPrefix("#")
            } else if selectedSeries == "其他" {
                if code.hasPrefix("#") { return false }
                return !prefixes.contains { prefix in
                    if prefix == "ZG" {
                        return code.hasPrefix("ZG")
                    } else {
                        return code.hasPrefix(prefix) && !code.hasPrefix("ZG")
                    }
                }
            } else if selectedSeries == "ZG" {
                return code.hasPrefix("ZG")
            } else {
                if code.hasPrefix("ZG") { return false }
                return code.hasPrefix(selectedSeries)
            }
        }.sorted { $0.displayCode(for: system).localizedStandardCompare($1.displayCode(for: system)) == .orderedAscending }
    }

    var selectedColor: BeadColor? {
        guard let id = selectedColorId else { return nil }
        return inventoryManager.allBeadColors.first { $0.id == id }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 色系选择器
                SeriesSelector(
                    series: brandColorSystem.colorSeries,
                    selectedSeries: $selectedSeries
                )
                .padding(.vertical, 8)

                // 颜色列表
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(colorsInSeries) { color in
                            Button {
                                selectedColorId = color.id
                            } label: {
                                HStack(spacing: 12) {
                                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                        .fill(color.color)
                                        .frame(width: 36, height: 36)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                                .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
                                        )

                                    Text(color.displayCode(for: brandColorSystem))
                                        .font(.system(.body, design: .monospaced))
                                        .fontWeight(.medium)
                                        .foregroundColor(.primary)

                                    Spacer()

                                    if selectedColorId == color.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(Theme.ColorToken.Morandi.latte)
                                    }
                                }
                                .padding(10)
                                .background(selectedColorId == color.id ? Theme.ColorToken.Morandi.latte.opacity(0.1) : Theme.ColorToken.Surface.elevated)
                                .cornerRadius(Theme.Radius.md)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 100)
                }

                // 底部确认栏
                if selectedColor != nil {
                    VStack(spacing: 0) {
                        Divider()

                        VStack(spacing: 12) {
                            // 已选颜色
                            HStack {
                                if let color = selectedColor {
                                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                        .fill(color.color)
                                        .frame(width: 24, height: 24)
                                    Text(color.displayCode(for: brandColorSystem))
                                        .font(.headline)
                                }
                                Spacer()
                            }

                            // 数量选择
                            HStack {
                                Text("数量（千颗）")
                                    .foregroundColor(.secondary)
                                Spacer()

                                HStack(spacing: 12) {
                                    Button {
                                        if quantity > 1 {
                                            quantity -= 1
                                        }
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .font(.title2)
                                            .foregroundColor(quantity > 1 ? Theme.ColorToken.Morandi.latte : Theme.ColorToken.Text.tertiary)
                                    }
                                    .disabled(quantity <= 1)

                                    Text("\(Int(quantity))")
                                        .font(.title3)
                                        .fontWeight(.semibold)
                                        .frame(minWidth: 40)

                                    Button {
                                        quantity += 1
                                    } label: {
                                        Image(systemName: "plus.circle.fill")
                                            .font(.title2)
                                            .foregroundColor(Theme.ColorToken.Morandi.latte)
                                    }
                                }
                            }

                            Button {
                                if let color = selectedColor {
                                    onAdd(color.mardCode, Int(quantity * 1000))
                                    dismiss()
                                }
                            } label: {
                                Text("添加 \(Int(quantity * 1000)) 颗")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Theme.ColorToken.Morandi.latte)
                                    .cornerRadius(Theme.Radius.md)
                            }
                        }
                        .padding()
                        .background(Theme.ColorToken.Surface.elevated)
                    }
                }
            }
            .background(Theme.ColorToken.Surface.background)
            .navigationTitle("添加颜色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .foregroundColor(Theme.ColorToken.Morandi.latte)
                }
            }
            .onAppear {
                selectedSeries = brandColorSystem.defaultSeries
            }
        }
    }
}

#Preview {
    NavigationStack {
        ShippingView()
            .environmentObject(InventoryManager())
    }
}
