//
//  StatisticsView.swift
//  BeadInventory
//
//  统计和历史记录界面
//

import SwiftUI

struct StatisticsView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var selectedSegment = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 分段控件（顶部）
                BISegmented(
                    selection: $selectedSegment,
                    segments: [
                        (0, "总览"),
                        (1, "使用排行"),
                        (2, "项目记录")
                    ],
                    fillWidth: true
                )
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 8)

                Group {
                    switch selectedSegment {
                    case 0:
                        StatisticsOverviewView()
                    case 1:
                        UsageStatisticsView()
                    default:
                        ProjectHistoryView()
                    }
                }
            }
            .background(Theme.ColorToken.Surface.background)
            .navigationTitle("统计")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    BrandPicker()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 10) {
                        Button {
                            // 占位：后续可接日期范围筛选
                        } label: {
                            Image(systemName: "calendar")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Theme.ColorToken.Text.secondary)
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(Theme.ColorToken.Surface.subtle))
                        }
                        Button {
                            // 占位：后续可接更多操作
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Theme.ColorToken.Text.secondary)
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(Theme.ColorToken.Surface.subtle))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 总览视图（环图 + 趋势 + 色相 + Top5）
struct StatisticsOverviewView: View {
    @EnvironmentObject var inventoryManager: InventoryManager

    private var brandId: UUID? { inventoryManager.currentBrandId }

    private var totalStock: Int {
        guard let brandId else { return 0 }
        return inventoryManager.totalStock(for: brandId)
    }

    private var totalUsed: Int {
        guard let brandId else { return 0 }
        return inventoryManager.totalUsed(for: brandId)
    }

    private var totalAvailable: Int {
        guard let brandId else { return 0 }
        return inventoryManager.totalAvailable(for: brandId)
    }

    private var usagePct: Double {
        guard totalStock > 0 else { return 0 }
        return Double(totalUsed) / Double(totalStock) * 100
    }

    /// 最近 14 天每日用量（基于已执行项目的 executedDate/completedDate/date）
    private var last14DayUsage: [(date: Date, value: Int)] {
        guard let brandId else { return [] }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        // 构造 14 天空槽
        var bins: [(date: Date, value: Int)] = (0..<14).reversed().map { offset in
            let d = cal.date(byAdding: .day, value: -offset, to: today) ?? today
            return (d, 0)
        }
        // 遍历项目，累计当日用量
        for project in inventoryManager.projects where !project.isPlanned {
            let useDate = project.completedDate ?? project.executedDate ?? project.date
            let day = cal.startOfDay(for: useDate)
            guard let idx = bins.firstIndex(where: { $0.date == day }) else { continue }
            // 累计当前品牌相关用量
            let qty = project.beadUsage.reduce(0) { sum, usage in
                if usage.brandId == brandId || (usage.brandId == nil && project.brandId == brandId) {
                    return sum + usage.quantity
                }
                return sum
            }
            bins[idx].value += qty
        }
        return bins
    }

    /// 色相分布（按当前品牌库存的 used 加权；若 used 全 0 则按 stock 加权）
    private var hueDistribution: [HueBucket] {
        guard let brandId else { return [] }
        let stocks = inventoryManager.brandStocks.filter { $0.brandId == brandId }
        var counts: [HueCategory: Int] = [:]
        var totalUsedAcc = 0
        var totalStockAcc = 0
        for stock in stocks {
            guard let color = inventoryManager.findColor(byCode: stock.mardCode) else { continue }
            let category = HueCategory.classify(hex: color.colorHex)
            let weight = stock.used > 0 ? stock.used : 0
            counts[category, default: 0] += weight
            totalUsedAcc += stock.used
            totalStockAcc += stock.stock
        }
        let total = totalUsedAcc > 0 ? totalUsedAcc : {
            // 退回到 stock
            for stock in stocks {
                guard let color = inventoryManager.findColor(byCode: stock.mardCode) else { continue }
                let category = HueCategory.classify(hex: color.colorHex)
                counts[category, default: 0] += stock.stock
            }
            return totalStockAcc
        }()
        guard total > 0 else { return [] }
        return HueCategory.allCases.compactMap { cat in
            let v = counts[cat] ?? 0
            guard v > 0 else { return nil }
            return HueBucket(category: cat, pct: Double(v) / Double(total))
        }.sorted { $0.pct > $1.pct }
    }

    /// Top 5 使用排行（按 used 倒序）
    private var top5: [(color: BeadColor, stock: BrandStock)] {
        guard let brandId else { return [] }
        let usedStocks = inventoryManager.brandStocks
            .filter { $0.brandId == brandId && $0.used > 0 }
            .sorted { $0.used > $1.used }
            .prefix(5)
        return usedStocks.compactMap { stock in
            guard let color = inventoryManager.findColor(byCode: stock.mardCode) else { return nil }
            return (color, stock)
        }
    }

    private var lowStockThreshold: Int {
        guard let brandId else { return 100 }
        return inventoryManager.getLowStockThreshold(for: brandId)
    }

    var body: some View {
        if brandId == nil {
            VStack(spacing: 16) {
                Image(systemName: "building.2")
                    .font(.system(size: 50))
                    .foregroundColor(.secondary.opacity(0.5))
                Text("请先创建品牌")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 18) {
                    // 1) 本月使用情况卡片（环图 + 数据）
                    monthlyUsageCard

                    // 2) 14 日用量趋势
                    last14DaySection

                    // 3) 色相分布
                    hueDistributionSection

                    // 4) Top5 排行
                    if !top5.isEmpty {
                        rankingSection
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
        }
    }

    // MARK: - 本月使用情况卡片

    private var monthlyUsageCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                RingChart(percent: usagePct, color: Theme.ColorToken.Morandi.sage)
                    .frame(width: 92, height: 92)

                VStack(alignment: .leading, spacing: 4) {
                    Text("本月使用情况")
                        .font(.caption2)
                        .foregroundStyle(Theme.ColorToken.Text.secondary)

                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text(String(format: "%.1f", usagePct))
                            .font(.system(size: 22, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.ColorToken.Text.primary)
                        Text("% · 用量")
                            .font(.caption)
                            .foregroundStyle(Theme.ColorToken.Text.secondary)
                    }

                    HStack(spacing: 6) {
                        BIChip("↑ 12 颗 / 周", color: Theme.ColorToken.Morandi.sage, size: .sm)
                        Text("vs 上周")
                            .font(.caption2)
                            .foregroundStyle(Theme.ColorToken.Text.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }

            Rectangle()
                .fill(Theme.ColorToken.Border.divider)
                .frame(height: 1)
                .padding(.vertical, 14)

            HStack(spacing: 0) {
                metricCell(label: "总库存", value: totalStock.formatted(.number.grouping(.automatic)))
                metricCell(label: "已使用", value: totalUsed.formatted(.number.grouping(.automatic)))
                metricCell(label: "剩余", value: totalAvailable.formatted(.number.grouping(.automatic)))
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Theme.ColorToken.Surface.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
        )
    }

    private func metricCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.ColorToken.Text.primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.ColorToken.Text.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 14 日用量趋势

    private var last14DaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("14 日用量趋势")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ColorToken.Text.primary)
                Spacer()
                Text("查看更多")
                    .font(.caption2)
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
            }

            BarChart14Day(data: last14DayUsage)
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Theme.ColorToken.Surface.elevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
                )
        }
    }

    // MARK: - 色相分布

    private var hueDistributionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("色相分布")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ColorToken.Text.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.ColorToken.Text.tertiary)
            }

            HueDistributionView(buckets: hueDistribution)
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Theme.ColorToken.Surface.elevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
                )
        }
    }

    // MARK: - Top 5 排行

    private var rankingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("使用排行 · TOP 5")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ColorToken.Text.primary)

            VStack(spacing: 10) {
                let maxUsed = top5.first?.stock.used ?? 1
                ForEach(Array(top5.enumerated()), id: \.element.color.id) { idx, item in
                    TopRankRow(
                        rank: idx + 1,
                        color: item.color,
                        stock: item.stock,
                        maxUsed: maxUsed,
                        isLowStock: item.stock.available < lowStockThreshold,
                        colorSystem: inventoryManager.currentColorSystem
                    )
                }
            }
        }
    }
}

// MARK: - 圆环图（私有）
private struct RingChart: View {
    let percent: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.ColorToken.Surface.strong, lineWidth: 9)
            Circle()
                .trim(from: 0, to: min(max(percent / 100, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut, value: percent)

            VStack(spacing: 0) {
                Text(String(format: "%.0f", percent))
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.ColorToken.Text.primary)
                Text("%")
                    .font(.caption2)
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
            }
        }
    }
}

// MARK: - 14 日柱状图（私有）
private struct BarChart14Day: View {
    let data: [(date: Date, value: Int)]

    private var maxValue: Int {
        max(data.map(\.value).max() ?? 1, 1)
    }

    private var peakIndex: Int? {
        guard let m = data.map(\.value).max(), m > 0 else { return nil }
        return data.firstIndex { $0.value == m }
    }

    var body: some View {
        VStack(spacing: 8) {
            // 柱体
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(data.enumerated()), id: \.offset) { idx, item in
                    bar(idx: idx, value: item.value)
                }
            }
            .frame(height: 110)

            // 底部分隔线
            Rectangle()
                .fill(Theme.ColorToken.Border.divider)
                .frame(height: 1)

            // 日期标签：起、中、末
            HStack {
                Text(dateLabel(at: 0))
                Spacer()
                Text(dateLabel(at: data.count / 2))
                Spacer()
                Text(dateLabel(at: data.count - 1))
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Theme.ColorToken.Text.tertiary)
        }
    }

    @ViewBuilder
    private func bar(idx: Int, value: Int) -> some View {
        let ratio = Double(value) / Double(maxValue)
        let isPeak = (idx == peakIndex)
        let opacity = isPeak ? 1.0 : (0.4 + ratio * 0.5)
        let fillColor = Theme.ColorToken.Morandi.latte.opacity(opacity)
        // 至少占 2pt 高，便于看见
        let h: CGFloat = max(2, CGFloat(ratio) * 100)

        VStack(spacing: 2) {
            if isPeak && value > 0 {
                Text("\(value)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.ColorToken.Morandi.latte)
            } else {
                Text(" ")
                    .font(.system(size: 9, design: .monospaced))
            }
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 4)
                .fill(fillColor)
                .frame(height: h)
        }
        .frame(maxWidth: .infinity)
    }

    private func dateLabel(at index: Int) -> String {
        guard data.indices.contains(index) else { return "" }
        let df = DateFormatter()
        df.dateFormat = "M/d"
        return df.string(from: data[index].date)
    }
}

// MARK: - 色相分类（私有）
private enum HueCategory: CaseIterable, Hashable {
    case warm    // 暖色（红/橙/黄）
    case cool    // 冷色（蓝/青）
    case neutral // 中性（灰/棕/绿调中性）
    case pink    // 粉嫩
    case purple  // 紫调

    var label: String {
        switch self {
        case .warm:    return "暖色"
        case .cool:    return "冷色"
        case .neutral: return "中性"
        case .pink:    return "粉嫩"
        case .purple:  return "紫调"
        }
    }

    var color: Color {
        switch self {
        case .warm:    return Theme.ColorToken.Morandi.latte
        case .cool:    return Theme.ColorToken.Morandi.mist
        case .neutral: return Theme.ColorToken.Morandi.sage
        case .pink:    return Theme.ColorToken.Morandi.rose
        case .purple:  return Theme.ColorToken.Morandi.mauve
        }
    }

    /// 将 #RRGGBB 颜色映射到一个分类（HSB 模型）
    static func classify(hex: String) -> HueCategory {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count >= 6, let v = UInt32(s.prefix(6), radix: 16) else { return .neutral }
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255

        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC
        let saturation = maxC == 0 ? 0 : delta / maxC

        if saturation < 0.18 {
            return .neutral
        }

        var hue: Double = 0
        if delta > 0 {
            if maxC == r {
                hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == g {
                hue = (b - r) / delta + 2
            } else {
                hue = (r - g) / delta + 4
            }
            hue *= 60
            if hue < 0 { hue += 360 }
        }

        // 粉嫩：偏红/品红 + 高亮低饱和
        if (hue >= 320 || hue < 20) && saturation < 0.45 && maxC > 0.75 {
            return .pink
        }

        switch hue {
        case 0..<45, 330..<360: return .warm     // 红橙
        case 45..<70:           return .warm     // 黄
        case 70..<170:          return .neutral  // 绿调（视为中性）
        case 170..<260:         return .cool     // 青蓝
        case 260..<330:         return .purple   // 紫品
        default:                return .neutral
        }
    }
}

private struct HueBucket: Identifiable {
    let category: HueCategory
    let pct: Double
    var id: HueCategory { category }
}

// MARK: - 色相分布视图（私有）
private struct HueDistributionView: View {
    let buckets: [HueBucket]

    /// 展示用的回退数据（无数据时按设计稿固定比例）
    private var displayBuckets: [HueBucket] {
        if !buckets.isEmpty { return buckets }
        return [
            HueBucket(category: .warm,    pct: 0.42),
            HueBucket(category: .cool,    pct: 0.22),
            HueBucket(category: .neutral, pct: 0.18),
            HueBucket(category: .pink,    pct: 0.12),
            HueBucket(category: .purple,  pct: 0.06)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 堆叠条
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(displayBuckets) { bucket in
                        Rectangle()
                            .fill(bucket.category.color)
                            .frame(width: geo.size.width * CGFloat(bucket.pct), height: 22)
                    }
                }
            }
            .frame(height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Legend
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(displayBuckets) { bucket in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(bucket.category.color)
                            .frame(width: 10, height: 10)
                        Text(bucket.category.label)
                            .font(.caption2)
                            .foregroundStyle(Theme.ColorToken.Text.secondary)
                        Spacer(minLength: 4)
                        Text("\(Int((bucket.pct * 100).rounded()))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.ColorToken.Text.primary)
                    }
                }
            }
        }
    }
}

// MARK: - Top 5 排行卡片行（私有）
private struct TopRankRow: View {
    let rank: Int
    let color: BeadColor
    let stock: BrandStock
    let maxUsed: Int
    let isLowStock: Bool
    let colorSystem: ColorSystem

    private var progress: Double {
        guard maxUsed > 0 else { return 0 }
        return min(max(Double(stock.used) / Double(maxUsed), 0), 1)
    }

    private var isTopThree: Bool { rank <= 3 }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                // 排名圆
                ZStack {
                    Circle()
                        .fill(isTopThree
                              ? Theme.ColorToken.Morandi.latte
                              : Theme.ColorToken.Surface.strong)
                        .frame(width: 22, height: 22)
                    Text("\(rank)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(isTopThree ? Color.white : Theme.ColorToken.Text.secondary)
                }

                BeadView(color: color.color, size: 26)

                Text(color.displayCode(for: colorSystem))
                    .font(.system(size: 14, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.ColorToken.Text.primary)

                if isLowStock {
                    BIChip("低库存", color: Theme.ColorToken.Morandi.rose, size: .sm)
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(stock.used)")
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.ColorToken.Text.primary)
                    Text("已用")
                        .font(.caption2)
                        .foregroundStyle(Theme.ColorToken.Text.tertiary)
                }
            }

            // 细进度条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.ColorToken.Surface.strong)
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.ColorToken.Morandi.latte)
                        .frame(width: geo.size.width * progress, height: 4)
                }
            }
            .frame(height: 4)
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
    }
}

// MARK: - 使用排行视图（完整列表）
struct UsageStatisticsView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var showLowStockOnly = false

    var displayItems: [(color: BeadColor, stock: BrandStock)] {
        guard let brandId = inventoryManager.currentBrandId else { return [] }

        if showLowStockOnly {
            let lowStocks = inventoryManager.lowStockColors(for: brandId)
            return lowStocks.compactMap { stock in
                if let color = inventoryManager.findColor(byCode: stock.mardCode) {
                    return (color, stock)
                }
                return nil
            }.sorted { $0.stock.available < $1.stock.available }
        } else {
            let usedStocks = inventoryManager.brandStocks.filter { $0.brandId == brandId && $0.used > 0 }
            return usedStocks.compactMap { stock in
                if let color = inventoryManager.findColor(byCode: stock.mardCode) {
                    return (color, stock)
                }
                return nil
            }.sorted { $0.stock.used > $1.stock.used }
        }
    }

    private var maxUsed: Int {
        max(displayItems.map { $0.stock.used }.max() ?? 1, 1)
    }

    private var lowStockThreshold: Int {
        guard let brandId = inventoryManager.currentBrandId else { return 100 }
        return inventoryManager.getLowStockThreshold(for: brandId)
    }

    var body: some View {
        if inventoryManager.currentBrandId == nil {
            VStack(spacing: 16) {
                Image(systemName: "building.2")
                    .font(.system(size: 50))
                    .foregroundColor(.secondary.opacity(0.5))
                Text("请先创建品牌")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 14) {
                    // 筛选 chip 行
                    HStack(spacing: 8) {
                        Button {
                            withAnimation { showLowStockOnly = false }
                        } label: {
                            BIChip("全部", active: !showLowStockOnly, color: Theme.ColorToken.Morandi.sage, size: .sm)
                        }
                        .buttonStyle(.plain)

                        Button {
                            withAnimation { showLowStockOnly = true }
                        } label: {
                            BIChip("仅低库存", active: showLowStockOnly, color: Theme.ColorToken.Morandi.rose, size: .sm)
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Text("共 \(displayItems.count) 项")
                            .font(.caption2)
                            .foregroundStyle(Theme.ColorToken.Text.tertiary)
                    }

                    if !displayItems.isEmpty {
                        VStack(spacing: 10) {
                            ForEach(Array(displayItems.prefix(50).enumerated()), id: \.element.color.id) { index, item in
                                TopRankRow(
                                    rank: index + 1,
                                    color: item.color,
                                    stock: item.stock,
                                    maxUsed: maxUsed,
                                    isLowStock: item.stock.available < lowStockThreshold,
                                    colorSystem: inventoryManager.currentColorSystem
                                )
                            }
                        }
                    } else {
                        EmptyStateView(
                            icon: showLowStockOnly ? "checkmark.circle" : "chart.bar",
                            title: showLowStockOnly ? "没有低库存颜色" : "尚无使用数据",
                            description: showLowStockOnly ? "目前没有低库存的颜色，挺好" : "开始扣减或拼图后，统计就会出现在这里"
                        )
                        .frame(height: 200)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
        }
    }
}

// MARK: - 项目历史视图
struct ProjectHistoryView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var showArchived = false
    @State private var expandedProjects: Set<UUID> = []
    @State private var isSelectMode = false
    @State private var selectedProjects: Set<UUID> = []
    @State private var showMergeSheet = false
    @State private var showDeleteParentAlert = false
    @State private var projectToDelete: ProjectRecord?
    @State private var showRevertConfirmSheet = false
    @State private var revertResultMessage = ""
    @State private var showRevertResultAlert = false
    @State private var restoreStock = true  // 是否恢复库存
    @State private var singleRevertProject: ProjectRecord?  // 单项退回的项目
    @State private var pendingProjectDeletion: ProjectRecord?  // 待二次确认的项目删除（叶子项目 / 子项目）

    private var selectedBrandId: UUID? {
        inventoryManager.currentBrandId
    }

    // 只显示顶级项目（排除计划项目，只显示已执行的）
    var displayedProjects: [ProjectRecord] {
        guard let selectedBrandId else { return [] }
        let topLevel = inventoryManager.topLevelProjects()

        // 筛选出已执行的项目或有已执行子项目的父项目
        let executed = topLevel.filter { project in
            if inventoryManager.isParentProject(project.id) {
                // 父项目：只有当它有当前品牌的已执行子项目时才显示
                return hasMatchingExecutedChildren(of: project.id, brandId: selectedBrandId)
            } else {
                // 独立项目：必须是已执行且关联当前品牌
                return !project.isPlanned && projectMatchesBrand(project, brandId: selectedBrandId)
            }
        }

        if showArchived {
            return executed
        } else {
            return executed.filter { !$0.isArchived }
        }
    }

    var archivedCount: Int {
        // 只统计已执行项目中的归档数量
        guard let selectedBrandId else { return 0 }
        return inventoryManager.topLevelProjects().filter { project in
            guard project.isArchived else { return false }
            if inventoryManager.isParentProject(project.id) {
                return hasMatchingExecutedChildren(of: project.id, brandId: selectedBrandId)
            }
            return !project.isPlanned && projectMatchesBrand(project, brandId: selectedBrandId)
        }.count
    }

    // 已执行的项目（非计划项目，包括子项目）
    var executedProjects: [ProjectRecord] {
        guard let selectedBrandId else { return [] }
        return inventoryManager.projects.filter {
            !$0.isPlanned && projectMatchesBrand($0, brandId: selectedBrandId)
        }
    }

    private func projectMatchesBrand(_ project: ProjectRecord, brandId: UUID) -> Bool {
        project.brandId == brandId || project.beadUsage.contains { $0.brandId == brandId }
    }

    private func matchingExecutedChildren(of parentId: UUID, brandId: UUID) -> [ProjectRecord] {
        inventoryManager.executedChildProjects(of: parentId).filter {
            projectMatchesBrand($0, brandId: brandId)
        }
    }

    private func hasMatchingExecutedChildren(of parentId: UUID, brandId: UUID) -> Bool {
        !matchingExecutedChildren(of: parentId, brandId: brandId).isEmpty
    }

    var body: some View {
        Group {
            if executedProjects.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 50))
                        .foregroundColor(.secondary.opacity(0.5))

                    Text("暂无项目记录")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    Text("扫描图纸并执行扣减后会自动记录")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxHeight: .infinity)
            } else {
            VStack(spacing: 0) {
                // 工具栏
                HStack {
                    if isSelectMode {
                        // 编辑模式：显示全选/取消全选按钮
                        Button {
                            withAnimation {
                                if selectedProjects.count == displayedProjects.count {
                                    // 已全选，取消全选
                                    selectedProjects.removeAll()
                                } else {
                                    // 全选所有显示的项目
                                    selectedProjects = Set(displayedProjects.map { $0.id })
                                }
                            }
                        } label: {
                            Text(selectedProjects.count == displayedProjects.count ? "取消全选" : "全选")
                                .font(.subheadline)
                        }
                    } else {
                        // 非编辑模式：显示归档按钮
                        if archivedCount > 0 || showArchived {
                            Button {
                                withAnimation { showArchived.toggle() }
                            } label: {
                                HStack {
                                    Image(systemName: showArchived ? "archivebox.fill" : "archivebox")
                                    Text(showArchived ? "隐藏归档" : "显示归档(\(archivedCount))")
                                }
                                .font(.subheadline)
                            }
                        }
                    }

                    Spacer()

                    Button {
                        withAnimation {
                            if isSelectMode {
                                isSelectMode = false
                                selectedProjects.removeAll()
                            } else {
                                isSelectMode = true
                            }
                        }
                    } label: {
                        Text(isSelectMode ? "取消" : "多选")
                            .font(.subheadline)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                // 多选模式底部工具栏
                if isSelectMode && !selectedProjects.isEmpty {
                    HStack(spacing: 12) {
                        // 合并按钮（需要至少2个项目）
                        Button {
                            showMergeSheet = true
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "arrow.triangle.merge")
                                    .font(.title3)
                                Text("合并")
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(selectedProjects.count >= 2 ? Color.accentColor : Theme.ColorToken.Border.default)
                            .foregroundColor(selectedProjects.count >= 2 ? .white : .secondary)
                            .cornerRadius(Theme.Radius.md)
                        }
                        .disabled(selectedProjects.count < 2)

                        // 复制到计划按钮
                        Button {
                            for projectId in selectedProjects {
                                _ = inventoryManager.duplicateProjectAsPlan(projectId)
                            }
                            isSelectMode = false
                            selectedProjects.removeAll()
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "doc.on.doc")
                                    .font(.title3)
                                Text("复制到计划")
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Theme.ColorToken.Status.info)
                            .foregroundColor(.white)
                            .cornerRadius(Theme.Radius.md)
                        }

                        // 退回按钮（中性可逆动作，使用 info 蓝而非 warning 黄）
                        Button {
                            showRevertConfirmSheet = true
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.title3)
                                Text("退回计划")
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Theme.ColorToken.Status.info)
                            .foregroundColor(.white)
                            .cornerRadius(Theme.Radius.md)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)

                    // 选中数量提示
                    Text("已选择 \(selectedProjects.count) 个项目")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 4)
                }

                List {
                    ForEach(displayedProjects) { project in
                        let isParent = inventoryManager.isParentProject(project.id)
                        let isExpanded = expandedProjects.contains(project.id)

                        // 项目行
                        ProjectRowWithHierarchy(
                            project: project,
                            isParent: isParent,
                            isExpanded: isExpanded,
                            isSelectMode: isSelectMode,
                            isSelected: selectedProjects.contains(project.id),
                            isChild: false,
                            brandFilterId: selectedBrandId,
                            onToggleExpand: {
                                withAnimation {
                                    if isExpanded {
                                        expandedProjects.remove(project.id)
                                    } else {
                                        expandedProjects.insert(project.id)
                                    }
                                }
                            },
                            onToggleSelect: {
                                if selectedProjects.contains(project.id) {
                                    selectedProjects.remove(project.id)
                                } else {
                                    selectedProjects.insert(project.id)
                                }
                            }
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                if isParent {
                                    projectToDelete = project
                                    showDeleteParentAlert = true
                                } else {
                                    pendingProjectDeletion = project
                                }
                            } label: {
                                Label("删除", systemImage: "trash")
                            }

                            // 复制到计划
                            Button {
                                _ = inventoryManager.duplicateProjectAsPlan(project.id)
                            } label: {
                                Label("复制到计划", systemImage: "doc.on.doc")
                            }
                            .tint(Theme.ColorToken.Status.info)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            // 归档/取消归档
                            if project.isArchived {
                                Button {
                                    if isParent {
                                        inventoryManager.unarchiveProjectWithChildren(id: project.id)
                                    } else {
                                        inventoryManager.unarchiveProject(id: project.id)
                                    }
                                } label: {
                                    Label("取消归档", systemImage: "tray.and.arrow.up")
                                }
                                .tint(Theme.ColorToken.Status.success)
                            } else {
                                Button {
                                    if isParent {
                                        inventoryManager.archiveProjectWithChildren(id: project.id)
                                    } else {
                                        inventoryManager.archiveProject(id: project.id)
                                    }
                                } label: {
                                    Label("归档", systemImage: "archivebox")
                                }
                                .tint(Theme.ColorToken.Status.warning)
                            }
                        }
                        // 长按菜单
                        .contextMenu {
                            // 退回计划（仅非父项目可用）
                            if !isParent {
                                Button {
                                    singleRevertProject = project
                                    showRevertConfirmSheet = true
                                } label: {
                                    Label("退回计划", systemImage: "arrow.uturn.backward")
                                }
                            } else {
                                Text("合并项目需先拆分才能退回")
                                    .foregroundColor(.secondary)
                            }

                            Button {
                                _ = inventoryManager.duplicateProjectAsPlan(project.id)
                            } label: {
                                Label("复制到计划", systemImage: "doc.on.doc")
                            }

                            Divider()

                            // 归档/取消归档
                            if project.isArchived {
                                Button {
                                    if isParent {
                                        inventoryManager.unarchiveProjectWithChildren(id: project.id)
                                    } else {
                                        inventoryManager.unarchiveProject(id: project.id)
                                    }
                                } label: {
                                    Label("取消归档", systemImage: "tray.and.arrow.up")
                                }
                            } else {
                                Button {
                                    if isParent {
                                        inventoryManager.archiveProjectWithChildren(id: project.id)
                                    } else {
                                        inventoryManager.archiveProject(id: project.id)
                                    }
                                } label: {
                                    Label("归档", systemImage: "archivebox")
                                }
                            }

                            Divider()

                            // 删除
                            Button(role: .destructive) {
                                if isParent {
                                    projectToDelete = project
                                    showDeleteParentAlert = true
                                } else {
                                    pendingProjectDeletion = project
                                }
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }

                        // 子项目
                        if isParent && isExpanded {
                            let children: [ProjectRecord] = {
                                guard let selectedBrandId else { return [] }
                                return matchingExecutedChildren(of: project.id, brandId: selectedBrandId)
                            }()
                            ForEach(children) { child in
                                ProjectRowWithHierarchy(
                                    project: child,
                                    isParent: false,
                                    isExpanded: false,
                                    isSelectMode: false,
                                    isSelected: false,
                                    isChild: true,
                                    brandFilterId: selectedBrandId,
                                    onToggleExpand: {},
                                    onToggleSelect: {}
                                )
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        pendingProjectDeletion = child
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }

                                    // 复制到计划
                                    Button {
                                        _ = inventoryManager.duplicateProjectAsPlan(child.id)
                                    } label: {
                                        Label("复制到计划", systemImage: "doc.on.doc")
                                    }
                                    .tint(Theme.ColorToken.Status.info)
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button {
                                        inventoryManager.detachProject(child.id)
                                    } label: {
                                        Label("独立", systemImage: "arrow.up.forward.square")
                                    }
                                    .tint(Theme.ColorToken.Status.success)
                                }
                                // 子项目长按菜单
                                .contextMenu {
                                    Button {
                                        singleRevertProject = child
                                        showRevertConfirmSheet = true
                                    } label: {
                                        Label("退回计划", systemImage: "arrow.uturn.backward")
                                    }

                                    Button {
                                        _ = inventoryManager.duplicateProjectAsPlan(child.id)
                                    } label: {
                                        Label("复制到计划", systemImage: "doc.on.doc")
                                    }

                                    Divider()

                                    Button {
                                        inventoryManager.detachProject(child.id)
                                    } label: {
                                        Label("独立为单独项目", systemImage: "arrow.up.forward.square")
                                    }

                                    Divider()

                                    Button(role: .destructive) {
                                        pendingProjectDeletion = child
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            }
        }
        // 合并项目弹窗
        .sheet(isPresented: $showMergeSheet) {
            MergeProjectsSheet(projectIds: Array(selectedProjects)) {
                isSelectMode = false
                selectedProjects.removeAll()
            }
            .environmentObject(inventoryManager)
        }
        // 删除父项目确认
        .alert("删除父项目", isPresented: $showDeleteParentAlert) {
            Button("取消", role: .cancel) { }
            Button("删除全部", role: .destructive) {
                if let project = projectToDelete {
                    inventoryManager.deleteParentProjectCascade(id: project.id)
                }
            }
            Button("仅删除父项目") {
                if let project = projectToDelete {
                    inventoryManager.deleteParentProjectDetach(id: project.id)
                }
            }
        } message: {
            Text("该项目包含子项目，请选择处理方式：\n• 删除全部：同时删除所有子项目\n• 仅删除父项目：子项目变为独立项目")
        }
        // 叶子/子项目删除二次确认
        .alert("删除项目", isPresented: Binding(
            get: { pendingProjectDeletion != nil },
            set: { if !$0 { pendingProjectDeletion = nil } }
        )) {
            Button("取消", role: .cancel) { pendingProjectDeletion = nil }
            Button("删除", role: .destructive) {
                if let project = pendingProjectDeletion {
                    inventoryManager.deleteProject(id: project.id)
                }
                pendingProjectDeletion = nil
            }
        } message: {
            Text("删除「\(pendingProjectDeletion?.name ?? "")」？该操作不可撤销。")
        }
        // 退回计划确认（使用 sheet 以便添加选项）
        .sheet(isPresented: $showRevertConfirmSheet, onDismiss: {
            singleRevertProject = nil  // 清理单项退回状态
        }) {
            RevertToPlanSheet(
                projectCount: singleRevertProject != nil ? 1 : selectedProjects.count,
                projectName: singleRevertProject?.name,
                restoreStock: $restoreStock,
                onConfirm: {
                    showRevertConfirmSheet = false
                    if let project = singleRevertProject {
                        revertSingleProject(project)
                    } else {
                        revertSelectedProjectsToPlan()
                    }
                },
                onCancel: {
                    showRevertConfirmSheet = false
                }
            )
            .presentationDetents([.height(350)])
        }
        // 退回结果提示
        .alert("退回完成", isPresented: $showRevertResultAlert) {
            Button("确定") { }
        } message: {
            Text(revertResultMessage)
        }
    }

    // 单项退回
    private func revertSingleProject(_ project: ProjectRecord) {
        let brandId = project.brandId

        var success = false
        if restoreStock && brandId != nil {
            let beadUsages = project.beadUsage.map { ($0.colorCode, $0.quantity) }
            success = inventoryManager.revertPlanExecute(projectId: project.id, brandId: brandId!, beadUsages: beadUsages)
        } else {
            if let index = inventoryManager.projects.firstIndex(where: { $0.id == project.id }) {
                inventoryManager.projects[index].isPlanned = true
                inventoryManager.projects[index].brandId = nil
                inventoryManager.projects[index].executedDate = nil
                inventoryManager.projects[index].beadUsage = inventoryManager.projects[index].beadUsage.map { usage in
                    BeadUsage(id: usage.id, colorCode: usage.colorCode, brandId: nil,
                              quantity: usage.quantity, isDeducted: false)
                }
                inventoryManager.saveData()
                success = true
            }
        }

        let stockNote = restoreStock ? "（库存已恢复）" : "（库存未变动）"
        if success {
            revertResultMessage = "「\(project.name)」已退回为计划状态\(stockNote)"
        } else {
            revertResultMessage = "退回失败，请重试"
        }
        showRevertResultAlert = true
    }

    // 退回选中项目为计划
    private func revertSelectedProjectsToPlan() {
        var successCount = 0
        var failCount = 0

        for projectId in selectedProjects {
            guard let project = inventoryManager.projects.first(where: { $0.id == projectId }) else {
                failCount += 1
                continue
            }

            // 跳过父项目（合并后的项目需要先拆分）
            if inventoryManager.isParentProject(projectId) {
                failCount += 1
                continue
            }

            // 获取项目关联的品牌
            let brandId = project.brandId

            if restoreStock && brandId != nil {
                // 需要恢复库存：使用原有的退回方法
                let beadUsages = project.beadUsage.map { ($0.colorCode, $0.quantity) }
                if inventoryManager.revertPlanExecute(projectId: projectId, brandId: brandId!, beadUsages: beadUsages) {
                    successCount += 1
                } else {
                    failCount += 1
                }
            } else {
                // 不恢复库存：直接修改项目状态
                if let index = inventoryManager.projects.firstIndex(where: { $0.id == projectId }) {
                    inventoryManager.projects[index].isPlanned = true
                    inventoryManager.projects[index].brandId = nil
                    inventoryManager.projects[index].executedDate = nil
                    inventoryManager.projects[index].beadUsage = inventoryManager.projects[index].beadUsage.map { usage in
                        BeadUsage(id: usage.id, colorCode: usage.colorCode, brandId: nil,
                                  quantity: usage.quantity, isDeducted: false)
                    }
                    successCount += 1
                } else {
                    failCount += 1
                }
            }
        }

        inventoryManager.saveData()

        // 生成结果消息
        let stockNote = restoreStock ? "（库存已恢复）" : "（库存未变动）"
        if failCount == 0 {
            revertResultMessage = "成功退回 \(successCount) 个项目为计划状态\(stockNote)"
        } else {
            revertResultMessage = "成功退回 \(successCount) 个项目\(stockNote)\n\(failCount) 个项目退回失败（可能是合并项目，需要先拆分）"
        }

        // 清理选择状态
        isSelectMode = false
        selectedProjects.removeAll()

        // 显示结果
        showRevertResultAlert = true
    }
}

// MARK: - 退回计划确认弹窗
struct RevertToPlanSheet: View {
    let projectCount: Int
    let projectName: String?  // 单项退回时显示项目名称
    @Binding var restoreStock: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var titleText: String {
        if let name = projectName {
            return "退回「\(name)」为计划"
        }
        return "退回 \(projectCount) 个项目为计划"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // 图标
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 50))
                    .foregroundColor(Theme.ColorToken.Status.warning)

                // 标题
                Text(titleText)
                    .font(.headline)

                // 选项
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: $restoreStock) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("恢复库存")
                                .font(.body)
                            Text(restoreStock ? "已扣减的库存将加回" : "库存保持不变")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                    .background(Theme.ColorToken.Surface.subtle)
                    .cornerRadius(Theme.Radius.md)
                }
                .padding(.horizontal)

                // 提示
                Text("💡 如果这些项目是从旧版备份导入的计划，建议关闭「恢复库存」")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Spacer()

                // 按钮
                HStack(spacing: 16) {
                    Button {
                        onCancel()
                    } label: {
                        Text("取消")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Theme.ColorToken.Surface.subtle)
                            .foregroundColor(.primary)
                            .cornerRadius(Theme.Radius.md)
                    }

                    Button {
                        onConfirm()
                    } label: {
                        Text("确认退回")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Theme.ColorToken.Status.warning)
                            .foregroundColor(.white)
                            .cornerRadius(Theme.Radius.md)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .navigationTitle("退回为计划")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - 带层级的项目行
struct ProjectRowWithHierarchy: View {
    let project: ProjectRecord
    let isParent: Bool
    let isExpanded: Bool
    let isSelectMode: Bool
    let isSelected: Bool
    let isChild: Bool
    let brandFilterId: UUID?
    let onToggleExpand: () -> Void
    let onToggleSelect: () -> Void

    @EnvironmentObject var inventoryManager: InventoryManager

    var brandName: String? {
        guard let brandId = project.brandId else { return nil }
        return inventoryManager.brands.first { $0.id == brandId }?.name
    }

    var colorCount: Int {
        if isParent {
            return filteredExecutedChildProjects
                .flatMap { filteredBeadUsage(for: $0) }
                .map(\.colorCode)
                .reduce(into: Set<String>()) { $0.insert($1) }
                .count
        }
        return filteredBeadUsage(for: project).count
    }

    var totalBeads: Int {
        if isParent {
            return filteredExecutedChildProjects
                .reduce(0) { total, child in
                    total + filteredBeadUsage(for: child).reduce(0) { $0 + $1.quantity }
                }
        }
        return filteredBeadUsage(for: project).reduce(0) { $0 + $1.quantity }
    }

    var childCount: Int {
        filteredExecutedChildProjects.count
    }

    private var filteredExecutedChildProjects: [ProjectRecord] {
        let children = inventoryManager.executedChildProjects(of: project.id)
        guard let brandFilterId else { return children }
        return children.filter { projectMatchesBrand($0, brandId: brandFilterId) }
    }

    private func projectMatchesBrand(_ project: ProjectRecord, brandId: UUID) -> Bool {
        project.brandId == brandId || project.beadUsage.contains { $0.brandId == brandId }
    }

    private func filteredBeadUsage(for project: ProjectRecord) -> [BeadUsage] {
        guard let brandFilterId else { return project.beadUsage }

        // Newer records store brandId per usage; older same-brand records only have project.brandId.
        return project.beadUsage.filter { usageMatchesBrand($0, projectBrandId: project.brandId, brandId: brandFilterId) }
    }

    private func usageMatchesBrand(_ usage: BeadUsage, projectBrandId: UUID?) -> Bool {
        guard let brandFilterId else { return true }
        return usageMatchesBrand(usage, projectBrandId: projectBrandId, brandId: brandFilterId)
    }

    private func usageMatchesBrand(_ usage: BeadUsage, projectBrandId: UUID?, brandId: UUID) -> Bool {
        usage.brandId == brandId || (usage.brandId == nil && projectBrandId == brandId)
    }

    // 从 finishedImage 或 thumbnail Data 创建 UIImage（优先使用成品图）
    var thumbnailImage: UIImage? {
        // 优先使用成品图，如果没有则使用原始缩略图
        if let finishedData = project.finishedImage {
            return UIImage(data: finishedData)
        }
        guard let data = project.thumbnail else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        HStack(spacing: 8) {
            // 选择模式复选框
            if isSelectMode && !isChild {
                Button {
                    onToggleSelect()
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(isSelected ? .accentColor : .secondary)
                        .font(.title2)
                }
                .buttonStyle(.plain)
            }

            // 子项目缩进
            if isChild {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 20)
            }

            // 展开/折叠按钮
            if isParent && !isSelectMode {
                Button {
                    onToggleExpand()
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 20)
                }
                .buttonStyle(.plain)
            }

            // 缩略图（如果有）
            if let image = thumbnailImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: isChild ? 40 : 50, height: isChild ? 40 : 50)
                    .clipShape(RoundedRectangle(cornerRadius: isChild ? 6 : 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: isChild ? 6 : 8)
                            .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
                    )
            }

            // 项目内容
            NavigationLink(destination: ProjectDetailView(project: project)) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        if isParent {
                            Image(systemName: "folder.fill")
                                .font(.caption)
                                .foregroundColor(.accentColor)
                        }

                        Text(project.name)
                            .font(.headline)

                        if project.isArchived {
                            Image(systemName: "archivebox.fill")
                                .font(.caption)
                                .foregroundColor(Theme.ColorToken.Status.warning)
                        }

                        Spacer()

                        Text(project.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        if let brandName = brandName {
                            Text(brandName)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                // 装饰：品牌徽章使用紫色作为视觉标识，不是语义状态
                                .background(Color.purple.opacity(0.1))
                                .foregroundColor(.purple)
                                .cornerRadius(Theme.Radius.sm)
                        }

                        if isParent {
                            Text("\(childCount) 个子项目")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.ColorToken.Status.info.opacity(0.1))
                                .foregroundColor(Theme.ColorToken.Status.info)
                                .cornerRadius(Theme.Radius.sm)
                        }

                        Label("\(colorCount) 色", systemImage: "paintpalette")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Spacer()

                        Label("\(totalBeads) 颗", systemImage: "circle.grid.3x3.fill")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                    }

                    // 颜色预览（仅子项目和独立项目显示）
                    if !isParent {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                let visibleUsage = filteredBeadUsage(for: project)
                                ForEach(visibleUsage.prefix(10)) { usage in
                                    let displayCode = inventoryManager.findColor(byCode: usage.colorCode)?
                                        .displayCode(for: project.colorSystem) ?? usage.colorCode
                                    Text(displayCode)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.1))
                                        .cornerRadius(Theme.Radius.sm)
                                }

                                if visibleUsage.count > 10 {
                                    Text("+\(visibleUsage.count - 10)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - 合并项目弹窗
struct MergeProjectsSheet: View {
    let projectIds: [UUID]
    let onComplete: () -> Void

    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss
    @State private var newName = ""
    @State private var showMergeError = false

    // 检查是否只有一个父项目（此时不需要输入新名称）
    var singleParentMerge: (isSimple: Bool, parentName: String?) {
        let validProjects = projectIds.compactMap { id in
            inventoryManager.projects.first { $0.id == id && $0.parentId == nil }
        }
        let parentProjects = validProjects.filter { inventoryManager.isParentProject($0.id) }
        if parentProjects.count == 1 {
            return (true, parentProjects.first?.name)
        }
        return (false, nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                if singleParentMerge.isSimple {
                    Section {
                        HStack {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(Theme.ColorToken.Status.info)
                            Text("将添加到「\(singleParentMerge.parentName ?? "")」")
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    Section("新父项目名称") {
                        TextField("输入名称", text: $newName)
                    }
                }

                Section(singleParentMerge.isSimple ? "将添加以下项目" : "将合并以下项目") {
                    ForEach(projectIds, id: \.self) { id in
                        if let project = inventoryManager.projects.first(where: { $0.id == id }) {
                            HStack {
                                if inventoryManager.isParentProject(project.id) {
                                    Image(systemName: "folder.fill")
                                        .foregroundColor(.accentColor)
                                        .font(.caption)
                                }
                                Text(project.name)
                                Spacer()
                                Text("\(project.totalBeads) 颗")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(singleParentMerge.isSimple ? "添加到项目" : "合并项目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("确认") {
                        let name = newName.isEmpty ? "合并项目 \(Date().formatted(date: .numeric, time: .omitted))" : newName
                        if inventoryManager.mergeProjects(projectIds, newName: name) != nil {
                            dismiss()
                            onComplete()
                        } else {
                            showMergeError = true
                        }
                    }
                    .disabled(projectIds.count < 2)
                }
            }
            .alert("无法合并", isPresented: $showMergeError) {
                Button("知道了", role: .cancel) { }
            } message: {
                Text("计划项目与已执行项目不能混合合并。请确保选择的项目都是计划中或都是已执行的。")
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview {
    StatisticsView()
        .environmentObject(InventoryManager())
}
