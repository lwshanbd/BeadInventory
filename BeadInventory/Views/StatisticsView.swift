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
                        (0, "项目"),
                        (1, "用量")
                    ],
                    fillWidth: true
                )
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 8)

                Group {
                    switch selectedSegment {
                    case 0:
                        ProjectHistoryView()
                    default:
                        StatisticsOverviewView()
                    }
                }
            }
            .background(Theme.ColorToken.Surface.background)
            .navigationTitle("记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    BrandPicker()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        CalendarView()
                    } label: {
                        Image(systemName: "calendar")
                    }
                    .accessibilityLabel("成品日历")
                }
            }
        }
    }
}

// MARK: - 总览视图（按月/年用量 + 排行 + 库存总览 + 色相）
struct StatisticsOverviewView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var period: UsagePeriod = .containing(Date(), kind: .month)

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

    private var lowStockThreshold: Int {
        guard let brandId else { return 100 }
        return inventoryManager.getLowStockThreshold(for: brandId)
    }

    var body: some View {
        if let brandId {
            // body 级快照：totalStock/totalUsed/totalAvailable 每次访问都是一次 brandStocks
            // 全量 filter+reduce；usageSummary 扫一遍项目。各算一次再传下去。
            let stock = totalStock
            let used = totalUsed
            let available = totalAvailable
            let pct = stock > 0 ? Double(used) / Double(stock) * 100 : 0
            let summary = inventoryManager.usageSummary(for: period, brandId: brandId)
            let earliest = inventoryManager.earliestUsageDate(brandId: brandId)
            ScrollView {
                VStack(spacing: 18) {
                    UsagePeriodPicker(period: $period, earliest: earliest)

                    periodSummaryCard(summary)

                    trendSection(summary)

                    rankingSection(summary: summary, brandId: brandId)

                    inventoryOverviewCard(totalStock: stock, totalUsed: used, totalAvailable: available, usagePct: pct)

                    hueDistributionSection
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
        } else {
            VStack(spacing: 16) {
                Image(systemName: "building.2")
                    .font(.system(size: 50))
                    .foregroundColor(.secondary.opacity(0.5))
                Text("请先创建品牌")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var isCurrentPeriod: Bool {
        period == .containing(Date(), kind: period.kind)
    }

    private var periodHeading: String {
        switch (period.kind, isCurrentPeriod) {
        case (.month, true): return String(localized: "本月用量")
        case (.year, true): return String(localized: "今年用量")
        default: return String(localized: "\(period.title)用量")
        }
    }

    // MARK: - 时间段用量卡片

    private func periodSummaryCard(_ summary: UsagePeriodSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(periodHeading)
                .font(.caption)
                .foregroundStyle(Theme.ColorToken.Text.secondary)

            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(summary.total.formatted(.number.grouping(.automatic)))
                    .font(.system(size: 30, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.ColorToken.Text.primary)
                Text("颗")
                    .font(.subheadline)
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                Spacer(minLength: 8)
                comparisonChip(summary)
            }

            Text("\(summary.projectCount) 个项目 · \(summary.ranking.count) 种颜色")
                .font(.caption)
                .foregroundStyle(Theme.ColorToken.Text.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    @ViewBuilder
    private func comparisonChip(_ summary: UsagePeriodSummary) -> some View {
        if summary.total > 0 || summary.previousTotal > 0 {
            let delta = summary.total - summary.previousTotal
            let unit = period.kind == .month ? String(localized: "比上月") : String(localized: "比去年")
            let text: String = {
                if delta == 0 { return period.kind == .month ? String(localized: "与上月持平") : String(localized: "与去年持平") }
                let sign = delta > 0 ? "+" : "−"
                return "\(unit) \(sign)\(abs(delta).formatted(.number.grouping(.automatic)))"
            }()
            BIChip(text, color: delta > 0 ? Theme.ColorToken.Morandi.latte : Theme.ColorToken.Morandi.sage, size: .sm)
        }
    }

    // MARK: - 趋势

    private func trendSection(_ summary: UsagePeriodSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(period.kind == .month ? "每日用量" : "每月用量")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ColorToken.Text.primary)

            UsageBarChart(data: summary.bins, kind: period.kind)
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

    // MARK: - 时间段排行 TOP 5

    private func rankingSection(summary: UsagePeriodSummary, brandId: UUID) -> some View {
        let items = Array(summary.ranking.prefix(5))
        let maxQty = max(items.first?.quantity ?? 1, 1)
        let threshold = lowStockThreshold
        let stockByCode = Dictionary(
            inventoryManager.brandStocks.filter { $0.brandId == brandId }.map { ($0.mardCode, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("用量排行 · TOP 5")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ColorToken.Text.primary)
                Spacer()
                if summary.ranking.count > items.count {
                    NavigationLink {
                        PeriodUsageRankingView(period: period)
                    } label: {
                        HStack(spacing: 2) {
                            Text("全部")
                            Image(systemName: "chevron.right")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                    }
                }
            }

            if items.isEmpty {
                Text("暂无用量")
                    .font(.subheadline)
                    .foregroundStyle(Theme.ColorToken.Text.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Theme.ColorToken.Surface.elevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
                    )
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        TopRankRow(
                            rank: idx + 1,
                            color: item.color,
                            value: item.quantity,
                            maxValue: maxQty,
                            valueCaption: "颗",
                            isLowStock: (stockByCode[item.color.mardCode]?.available ?? .max) < threshold,
                            colorSystem: inventoryManager.currentColorSystem
                        )
                    }
                }
            }
        }
    }

    // MARK: - 库存总览卡片（累计，不随时间段变）

    private func inventoryOverviewCard(totalStock: Int, totalUsed: Int, totalAvailable: Int, usagePct: Double) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                RingChart(percent: usagePct, color: Theme.ColorToken.Morandi.sage)
                    .frame(width: 92, height: 92)

                VStack(alignment: .leading, spacing: 4) {
                    Text("库存总览")
                        .font(.caption2)
                        .foregroundStyle(Theme.ColorToken.Text.secondary)

                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text(String(format: "%.1f", usagePct))
                            .font(.system(size: 22, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.ColorToken.Text.primary)
                        Text("% 已使用")
                            .font(.caption)
                            .foregroundStyle(Theme.ColorToken.Text.secondary)
                    }

                    NavigationLink {
                        UsageStatisticsView()
                            .background(Theme.ColorToken.Surface.background)
                            .navigationTitle("累计使用排行")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        HStack(spacing: 2) {
                            Text("累计使用排行")
                            Image(systemName: "chevron.right")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
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
                metricCell(label: "累计已使用", value: totalUsed.formatted(.number.grouping(.automatic)))
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
}

// MARK: - ===== 按月 / 按年用量 =====
// MARK: - 时间段

enum UsagePeriodKind: Hashable {
    case month
    case year

    var component: Calendar.Component { self == .month ? .month : .year }
}

/// 一个自然月或一个自然年。`start` 永远是该段第一天 0 点。
struct UsagePeriod: Equatable {
    let kind: UsagePeriodKind
    let start: Date

    static func containing(_ date: Date, kind: UsagePeriodKind, calendar: Calendar = .current) -> UsagePeriod {
        let comps: Set<Calendar.Component> = kind == .month ? [.year, .month] : [.year]
        let start = calendar.date(from: calendar.dateComponents(comps, from: date)) ?? calendar.startOfDay(for: date)
        return UsagePeriod(kind: kind, start: start)
    }

    func shifted(by value: Int, calendar: Calendar = .current) -> UsagePeriod {
        let s = calendar.date(byAdding: kind.component, value: value, to: start) ?? start
        return UsagePeriod(kind: kind, start: s)
    }

    func end(calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: kind.component, value: 1, to: start) ?? start
    }

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        date >= start && date < end(calendar: calendar)
    }

    /// 柱状图每根柱子的起点：月 → 每天，年 → 每月。
    func binStarts(calendar: Calendar = .current) -> [Date] {
        let unit: Calendar.Component = kind == .month ? .day : .month
        let count = calendar.range(of: unit, in: kind.component, for: start)?.count ?? 0
        return (0..<count).compactMap { calendar.date(byAdding: unit, value: $0, to: start) }
    }

    func binIndex(of date: Date, calendar: Calendar = .current) -> Int? {
        guard contains(date, calendar: calendar) else { return nil }
        let unit: Calendar.Component = kind == .month ? .day : .month
        return calendar.component(unit, from: date) - 1
    }

    /// 「2026年10月」/「2026年」
    var title: String {
        kind == .month
            ? start.formatted(.dateTime.year().month())
            : start.formatted(.dateTime.year())
    }
}

// MARK: - 汇总

struct UsagePeriodSummary {
    struct RankItem: Identifiable {
        let color: BeadColor
        let quantity: Int
        var id: String { color.mardCode }
    }

    let total: Int
    let previousTotal: Int
    let projectCount: Int
    let bins: [(date: Date, value: Int)]
    let ranking: [RankItem]
}

extension InventoryManager {
    /// 某品牌在某个时间段里扣掉了多少豆子。
    ///
    /// 只算已执行项目里真的扣成了的那几行（`isDeducted`），日期取扣库存那天
    /// （`executedDate`，直接录入的已执行项目没有它，用创建日期）。
    /// 在库存页手动改「已使用」的那部分没有可靠日期（历史只留最近 100 条），算不进来。
    /// 父项目自己的 beadUsage 是空的，用量都在子项目上，不会重复计。
    func usageSummary(for period: UsagePeriod, brandId: UUID) -> UsagePeriodSummary {
        let cal = Calendar.current
        let previous = period.shifted(by: -1)
        let binStarts = period.binStarts()
        var bins = binStarts.map { (date: $0, value: 0) }
        var total = 0
        var previousTotal = 0
        var projectIds: Set<UUID> = []
        var byCode: [String: (color: BeadColor, quantity: Int)] = [:]

        for project in projects where !project.isPlanned {
            let useDate = project.executedDate ?? project.date
            let inPeriod = period.contains(useDate, calendar: cal)
            let inPrevious = !inPeriod && previous.contains(useDate, calendar: cal)
            guard inPeriod || inPrevious else { continue }

            var qty = 0
            for usage in project.beadUsage where usage.isDeducted && usage.quantity > 0 {
                guard usage.brandId == brandId || (usage.brandId == nil && project.brandId == brandId) else { continue }
                qty += usage.quantity
                // 跟扣库存走同一个查找（deductFromStock 用的就是它），排行里的色号才对得上库存那一行
                if inPeriod, let color = findColor(byCode: usage.colorCode) {
                    byCode[color.mardCode, default: (color, 0)].quantity += usage.quantity
                }
            }
            guard qty > 0 else { continue }

            if inPeriod {
                total += qty
                projectIds.insert(project.id)
                if let idx = period.binIndex(of: useDate, calendar: cal), bins.indices.contains(idx) {
                    bins[idx].value += qty
                }
            } else {
                previousTotal += qty
            }
        }

        let ranking = byCode.values
            .sorted { $0.quantity != $1.quantity ? $0.quantity > $1.quantity : $0.color.mardCode < $1.color.mardCode }
            .map { UsagePeriodSummary.RankItem(color: $0.color, quantity: $0.quantity) }

        return UsagePeriodSummary(
            total: total,
            previousTotal: previousTotal,
            projectCount: projectIds.count,
            bins: bins,
            ranking: ranking
        )
    }

    /// 最早一次扣库存的日期，用来限制往前翻到哪里。
    func earliestUsageDate(brandId: UUID) -> Date? {
        projects
            .filter { project in
                !project.isPlanned && project.beadUsage.contains { usage in
                    usage.isDeducted && (usage.brandId == brandId || (usage.brandId == nil && project.brandId == brandId))
                }
            }
            .map { $0.executedDate ?? $0.date }
            .min()
    }
}

// MARK: - 时间段切换条

struct UsagePeriodPicker: View {
    @Binding var period: UsagePeriod
    /// 最早能翻到的那一段；nil = 没有任何用量，不能往前翻
    let earliest: Date?

    private var current: UsagePeriod { .containing(Date(), kind: period.kind) }

    private var canGoBack: Bool {
        guard let earliest else { return false }
        return period.start > UsagePeriod.containing(earliest, kind: period.kind).start
    }

    private var canGoForward: Bool { period.start < current.start }

    private var kindBinding: Binding<UsagePeriodKind> {
        Binding(
            get: { period.kind },
            set: { newKind in
                guard newKind != period.kind else { return }
                // 切换月/年时停在原来那段所在的年份（或该年的当月 / 一月）
                if newKind == .year {
                    period = .containing(period.start, kind: .year)
                } else {
                    let now = Date()
                    let sameYear = Calendar.current.isDate(now, equalTo: period.start, toGranularity: .year)
                    period = .containing(sameYear ? now : period.start, kind: .month)
                }
            }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            BISegmented(
                selection: kindBinding,
                segments: [(.month, String(localized: "月")), (.year, String(localized: "年"))]
            )
            .frame(width: 110)

            Spacer(minLength: 0)

            Button {
                period = period.shifted(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
                    // 外层 foregroundStyle 会盖掉系统的禁用变灰，这里自己压暗
                    .opacity(canGoBack ? 1 : 0.3)
            }
            .disabled(!canGoBack)
            .accessibilityLabel(period.kind == .month ? "上个月" : "上一年")

            Text(period.title)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.ColorToken.Text.primary)
                .frame(minWidth: 96)

            Button {
                period = period.shifted(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
                    // 外层 foregroundStyle 会盖掉系统的禁用变灰，这里自己压暗
                    .opacity(canGoForward ? 1 : 0.3)
            }
            .disabled(!canGoForward)
            .accessibilityLabel(period.kind == .month ? "下个月" : "下一年")
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Theme.ColorToken.Text.secondary)
    }
}

// MARK: - 趋势柱状图

struct UsageBarChart: View {
    let data: [(date: Date, value: Int)]
    let kind: UsagePeriodKind

    private var maxValue: Int {
        max(data.map(\.value).max() ?? 1, 1)
    }

    private var peakIndex: Int? {
        guard let m = data.map(\.value).max(), m > 0 else { return nil }
        return data.firstIndex { $0.value == m }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: kind == .month ? 3 : 6) {
                ForEach(Array(data.enumerated()), id: \.offset) { idx, item in
                    bar(idx: idx, value: item.value)
                }
            }
            .frame(height: 110)

            Rectangle()
                .fill(Theme.ColorToken.Border.divider)
                .frame(height: 1)

            HStack {
                Text(label(at: 0))
                Spacer()
                Text(label(at: data.count / 2))
                Spacer()
                Text(label(at: data.count - 1))
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
        let h: CGFloat = max(2, CGFloat(ratio) * 100)

        VStack(spacing: 2) {
            // 峰值数字可能比柱子宽，放在 overlay 里不撑开这一列
            Text(" ")
                .font(.system(size: 9, design: .monospaced))
                .frame(maxWidth: .infinity)
                .overlay {
                    if isPeak && value > 0 {
                        Text("\(value)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Theme.ColorToken.Morandi.latte)
                            .fixedSize()
                    }
                }
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: kind == .month ? 2 : 4)
                .fill(Theme.ColorToken.Morandi.latte.opacity(opacity))
                .frame(height: h)
        }
        .frame(maxWidth: .infinity)
    }

    private func label(at index: Int) -> String {
        guard data.indices.contains(index) else { return "" }
        let date = data[index].date
        return kind == .month
            ? date.formatted(.dateTime.month(.defaultDigits).day())
            : date.formatted(.dateTime.month(.abbreviated))
    }
}

// MARK: - 时间段排行（完整列表）

struct PeriodUsageRankingView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    let period: UsagePeriod

    var body: some View {
        if let brandId = inventoryManager.currentBrandId {
            let items = inventoryManager.usageSummary(for: period, brandId: brandId).ranking
            let maxQty = max(items.first?.quantity ?? 1, 1)
            let threshold = inventoryManager.getLowStockThreshold(for: brandId)
            let stockByCode = Dictionary(
                inventoryManager.brandStocks.filter { $0.brandId == brandId }.map { ($0.mardCode, $0) },
                uniquingKeysWith: { a, _ in a }
            )
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        TopRankRow(
                            rank: idx + 1,
                            color: item.color,
                            value: item.quantity,
                            maxValue: maxQty,
                            valueCaption: "颗",
                            isLowStock: (stockByCode[item.color.mardCode]?.available ?? .max) < threshold,
                            colorSystem: inventoryManager.currentColorSystem
                        )
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .background(Theme.ColorToken.Surface.background)
            .navigationTitle(Text("\(period.title) 用量排行"))
            .navigationBarTitleDisplayMode(.inline)
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

// MARK: - 排行卡片行
struct TopRankRow: View {
    let rank: Int
    let color: BeadColor
    /// 右侧显示的数：时间段排行是该段用量，累计排行是 stock.used
    let value: Int
    let maxValue: Int
    let valueCaption: LocalizedStringKey
    let isLowStock: Bool
    let colorSystem: ColorSystem

    private var progress: Double {
        guard maxValue > 0 else { return 0 }
        return min(max(Double(value) / Double(maxValue), 0), 1)
    }

    private var isTopThree: Bool { rank <= 3 }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                // 排名圆
                ZStack {
                    Circle()
                        .fill(isTopThree
                              ? Theme.ColorToken.Fill.latte
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
                    Text("\(value)")
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.ColorToken.Text.primary)
                    Text(valueCaption)
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
            // body 级快照（跟 InventoryView.body 同范式）：displayItems 是全量 filter+sort 的
            // computed property，不 let 住的话本 body 里 count/isEmpty/ForEach 各触发一次，
            // maxUsed 又在 ForEach **每行**重算一次（每行一次完整 filter+sort，50 行 ≈ 53 次）。
            let items = displayItems
            let maxUsedSnapshot = max(items.map { $0.stock.used }.max() ?? 1, 1)
            let threshold = lowStockThreshold
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

                        Text("共 \(items.count) 项")
                            .font(.caption2)
                            .foregroundStyle(Theme.ColorToken.Text.tertiary)
                    }

                    if !items.isEmpty {
                        VStack(spacing: 10) {
                            ForEach(Array(items.prefix(50).enumerated()), id: \.element.color.id) { index, item in
                                TopRankRow(
                                    rank: index + 1,
                                    color: item.color,
                                    value: item.stock.used,
                                    maxValue: maxUsedSnapshot,
                                    valueCaption: "已用",
                                    isLowStock: item.stock.available < threshold,
                                    colorSystem: inventoryManager.currentColorSystem
                                )
                            }
                        }
                    } else {
                        EmptyStateView(
                            icon: showLowStockOnly ? "checkmark.circle" : "chart.bar",
                            title: showLowStockOnly ? "没有低库存颜色" : "尚无使用数据",
                            description: showLowStockOnly ? "当前所有颜色库存充足" : "开始扣减或拼图后，统计就会出现在这里"
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
        // body 级快照：displayedProjects / archivedCount 都是 O(项目数²) 的 computed property
        //（每个 parent 再全表 filter 子项目），不 let 住的话一次 body 里会被求值 2-4 次。
        let projectsToShow = displayedProjects
        let archivedProjectCount = archivedCount
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
                                if selectedProjects.count == projectsToShow.count {
                                    // 已全选，取消全选
                                    selectedProjects.removeAll()
                                } else {
                                    // 全选所有显示的项目
                                    selectedProjects = Set(projectsToShow.map { $0.id })
                                }
                            }
                        } label: {
                            Text(selectedProjects.count == projectsToShow.count ? "取消全选" : "全选")
                                .font(.subheadline)
                        }
                    } else {
                        // 非编辑模式：显示归档按钮
                        if archivedProjectCount > 0 || showArchived {
                            Button {
                                withAnimation { showArchived.toggle() }
                            } label: {
                                HStack {
                                    Image(systemName: showArchived ? "archivebox.fill" : "archivebox")
                                    Text(showArchived ? "隐藏归档" : "显示归档(\(archivedProjectCount))")
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
                            .background(selectedProjects.count >= 2 ? Theme.ColorToken.Fill.latte : Theme.ColorToken.Border.default)
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
                            .background(Theme.ColorToken.Fill.info)
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
                            .background(Theme.ColorToken.Fill.info)
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
                    ForEach(projectsToShow) { project in
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
                                        Label("独立为顶级项目", systemImage: "arrow.up.forward.square")
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
                .listStyle(.plain)
                .background(Theme.ColorToken.Surface.background)
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
                Text("如果这些项目是从旧版备份导入的计划，建议关闭「恢复库存」")
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
                            .background(Theme.ColorToken.Fill.warning)
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

    /// childCount / colorCount / totalBeads 三个数字一次遍历算齐。
    /// 原来是三个独立 computed property，body 里各访问一次 → 每行 3 次
    /// `executedChildProjects`（全表 O(项目数) filter）；列表 N 行就是 3N 次全表扫描。
    private var hierarchyStats: (childCount: Int, colorCount: Int, totalBeads: Int) {
        if isParent {
            let children = filteredExecutedChildProjects
            var colorCodes = Set<String>()
            var beads = 0
            for child in children {
                for usage in filteredBeadUsage(for: child) {
                    colorCodes.insert(usage.colorCode)
                    beads += usage.quantity
                }
            }
            return (children.count, colorCodes.count, beads)
        }
        let usages = filteredBeadUsage(for: project)
        return (0, usages.count, usages.reduce(0) { $0 + $1.quantity })
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

    // 异步加载图片：优先用成品图，否则回退到缩略图。
    @State private var loadedImage: UIImage?

    var body: some View {
        // body 级快照：三个统计数字一次算齐，避免每个数字各触发一次全表子项目扫描
        let stats = hierarchyStats
        HStack(spacing: 8) {
            // 选择模式复选框
            if isSelectMode && !isChild {
                Button {
                    onToggleSelect()
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(isSelected ? Theme.ColorToken.Morandi.latte : Theme.ColorToken.Text.secondary)
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
            if let image = loadedImage {
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
                                .foregroundColor(Theme.ColorToken.Morandi.latte)
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
                                // 装饰：品牌徽章使用 Morandi mauve 作为视觉标识，不是语义状态
                                .background(Theme.ColorToken.Morandi.mauve.opacity(0.1))
                                .foregroundColor(Theme.ColorToken.Morandi.mauve)
                                .cornerRadius(Theme.Radius.sm)
                        }

                        if isParent {
                            Text("\(stats.childCount) 个子项目")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.ColorToken.Status.info.opacity(0.1))
                                .foregroundColor(Theme.ColorToken.Status.info)
                                .cornerRadius(Theme.Radius.sm)
                        }

                        Label("\(stats.colorCount) 色", systemImage: "paintpalette")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Spacer()

                        Label("\(stats.totalBeads) 颗", systemImage: "circle.grid.3x3.fill")
                            .font(.caption)
                            .foregroundColor(Theme.ColorToken.Morandi.latte)
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
                                        .background(Theme.ColorToken.Morandi.latte.opacity(0.1))
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
        .task(id: "\(project.id.uuidString)-\(inventoryManager.projectBlobsRevision)") {
            // 优先用成品图，没成品图回落到图纸 —— **全部走降级路径**。
            // 这一行只有 40-50pt，早先取原字节 `UIImage(data:)` 是全分辨率解码：
            // 统计页可见的几个 row 各留一份全尺寸位图（round-2 双审两侧命中）。
            let id = project.id
            guard let loader = inventoryManager.imageLoader else { return }
            var image: UIImage?
            let finished = await loader.downsampledFinishedImage(for: id, maxPixelSize: 200)
            if let finishedImage = finished.image {
                image = finishedImage
            } else if !finished.bytesFound {
                // 没有成品图 → 图纸：优先列表小图（~50-100KB JPEG），缺了再现场降级原图
                if let displayData = await loader.displayThumbnail(for: id) {
                    image = UIImage(data: displayData)
                } else {
                    image = await loader.downsampledRawThumbnail(for: id)
                }
            }
            guard !Task.isCancelled, id == project.id else { return }
            self.loadedImage = image
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
                                        .foregroundColor(Theme.ColorToken.Morandi.latte)
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
