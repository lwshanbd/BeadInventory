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
                // 品牌选择器
                HStack {
                    BrandPicker()
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 8)

                // 分段选择器
                Picker("", selection: $selectedSegment) {
                    Text("使用统计").tag(0)
                    Text("项目记录").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()

                if selectedSegment == 0 {
                    UsageStatisticsView()
                } else {
                    ProjectHistoryView()
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("统计")
        }
    }
}

// MARK: - 使用统计视图
struct UsageStatisticsView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var showLowStockOnly = false

    var stockDict: [String: BrandStock] {
        guard let brandId = inventoryManager.currentBrandId else { return [:] }
        let stocks = inventoryManager.brandStocks.filter { $0.brandId == brandId }
        return Dictionary(uniqueKeysWithValues: stocks.map { ($0.mardCode, $0) })
    }

    var displayItems: [(color: BeadColor, stock: BrandStock)] {
        guard let brandId = inventoryManager.currentBrandId else { return [] }

        if showLowStockOnly {
            let lowStocks = inventoryManager.lowStockColors(for: brandId)
            return lowStocks.compactMap { stock in
                if let color = inventoryManager.beadColors.first(where: { $0.mardCode == stock.mardCode }) {
                    return (color, stock)
                }
                return nil
            }.sorted { $0.stock.available < $1.stock.available }
        } else {
            let usedStocks = inventoryManager.brandStocks.filter { $0.brandId == brandId && $0.used > 0 }
            return usedStocks.compactMap { stock in
                if let color = inventoryManager.beadColors.first(where: { $0.mardCode == stock.mardCode }) {
                    return (color, stock)
                }
                return nil
            }.sorted { $0.stock.used > $1.stock.used }
        }
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
                VStack(spacing: 20) {
                    // 总览卡片
                    OverviewCard()

                    // 筛选开关
                    Toggle("仅显示低库存", isOn: $showLowStockOnly)
                        .padding()
                        .background(Color(.systemBackground))
                        .cornerRadius(12)
                        .padding(.horizontal)

                    // 使用排行
                    if !displayItems.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(showLowStockOnly ? "低库存颜色" : "使用排行")
                                .font(.headline)
                                .padding(.horizontal)

                            ForEach(Array(displayItems.prefix(20).enumerated()), id: \.element.color.id) { index, item in
                                UsageRankRow(rank: index + 1, color: item.color, stock: item.stock)
                            }
                        }
                    } else {
                        VStack(spacing: 16) {
                            Image(systemName: showLowStockOnly ? "checkmark.circle" : "chart.bar.xaxis")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary.opacity(0.5))

                            Text(showLowStockOnly ? "没有低库存颜色" : "暂无使用记录")
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }
                        .frame(height: 200)
                    }
                }
                .padding(.vertical)
            }
        }
    }
}

// MARK: - 总览卡片
struct OverviewCard: View {
    @EnvironmentObject var inventoryManager: InventoryManager

    var totalStock: Int {
        guard let brandId = inventoryManager.currentBrandId else { return 0 }
        return inventoryManager.totalStock(for: brandId)
    }

    var totalUsed: Int {
        guard let brandId = inventoryManager.currentBrandId else { return 0 }
        return inventoryManager.totalUsed(for: brandId)
    }

    var totalAvailable: Int {
        guard let brandId = inventoryManager.currentBrandId else { return 0 }
        return inventoryManager.totalAvailable(for: brandId)
    }

    var usagePercentage: Double {
        guard totalStock > 0 else { return 0 }
        return Double(totalUsed) / Double(totalStock) * 100
    }

    var body: some View {
        VStack(spacing: 20) {
            // 圆环进度
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 12)

                Circle()
                    .trim(from: 0, to: min(usagePercentage / 100, 1))
                    .stroke(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 12, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut, value: usagePercentage)

                VStack(spacing: 4) {
                    Text(String(format: "%.1f%%", usagePercentage))
                        .font(.title)
                        .fontWeight(.bold)

                    Text("已使用")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 120, height: 120)

            // 详细数据
            HStack(spacing: 30) {
                StatItem(
                    title: "总库存",
                    value: "\(totalStock)",
                    color: .blue
                )
                StatItem(
                    title: "已使用",
                    value: "\(totalUsed)",
                    color: .orange
                )
                StatItem(
                    title: "剩余",
                    value: "\(totalAvailable)",
                    color: .green
                )
            }
        }
        .padding(24)
        .background(Color(.systemBackground))
        .cornerRadius(20)
        .padding(.horizontal)
    }
}

struct StatItem: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.headline)
                .fontWeight(.bold)
                .foregroundColor(color)

            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - 使用排行行
struct UsageRankRow: View {
    let rank: Int
    let color: BeadColor
    let stock: BrandStock
    @EnvironmentObject var inventoryManager: InventoryManager

    var maxUsed: Int {
        guard let brandId = inventoryManager.currentBrandId else { return 1 }
        return inventoryManager.brandStocks.filter { $0.brandId == brandId }.map { $0.used }.max() ?? 1
    }

    var progress: Double {
        guard maxUsed > 0 else { return 0 }
        return Double(stock.used) / Double(maxUsed)
    }

    var body: some View {
        HStack(spacing: 12) {
            // 排名
            Text("\(rank)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(rankColor)
                .cornerRadius(12)

            // 颜色块
            RoundedRectangle(cornerRadius: 6)
                .fill(color.color)
                .frame(width: 32, height: 32)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )

            // 色号和进度条
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(color.mardCode)
                        .font(.system(.subheadline, design: .monospaced))
                        .fontWeight(.medium)

                    Spacer()

                    Text("已用 \(stock.used)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("剩余 \(stock.available)")
                        .font(.caption)
                        .foregroundColor(stock.available < 100 ? .red : .green)
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 6)

                        RoundedRectangle(cornerRadius: 3)
                            .fill(
                                LinearGradient(
                                    colors: [color.color, color.color.opacity(0.6)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geometry.size.width * progress, height: 6)
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    var rankColor: Color {
        switch rank {
        case 1: return .yellow
        case 2: return .gray
        case 3: return .orange
        default: return .secondary
        }
    }
}

// MARK: - 项目历史视图
struct ProjectHistoryView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var showArchived = false

    var displayedProjects: [ProjectRecord] {
        if showArchived {
            return inventoryManager.projects
        } else {
            return inventoryManager.projects.filter { !$0.isArchived }
        }
    }

    var archivedCount: Int {
        inventoryManager.projects.filter { $0.isArchived }.count
    }

    var body: some View {
        if inventoryManager.projects.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "doc.text")
                    .font(.system(size: 50))
                    .foregroundColor(.secondary.opacity(0.5))

                Text("暂无项目记录")
                    .font(.headline)
                    .foregroundColor(.secondary)

                Text("扫描图纸后会自动记录")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                // 显示全部/隐藏归档按钮
                if archivedCount > 0 || showArchived {
                    Button {
                        withAnimation { showArchived.toggle() }
                    } label: {
                        HStack {
                            Image(systemName: showArchived ? "archivebox.fill" : "archivebox")
                            Text(showArchived ? "隐藏已归档 (\(archivedCount))" : "显示全部 (含 \(archivedCount) 个归档)")
                        }
                        .font(.subheadline)
                        .foregroundColor(.accentColor)
                        .padding(.vertical, 8)
                    }
                }

                List {
                    ForEach(displayedProjects) { project in
                        NavigationLink(destination: ProjectDetailView(project: project)) {
                            ProjectRow(project: project)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                inventoryManager.deleteProject(id: project.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if project.isArchived {
                                Button {
                                    inventoryManager.unarchiveProject(id: project.id)
                                } label: {
                                    Label("取消归档", systemImage: "tray.and.arrow.up")
                                }
                                .tint(.blue)
                            } else {
                                Button {
                                    inventoryManager.archiveProject(id: project.id)
                                } label: {
                                    Label("归档", systemImage: "archivebox")
                                }
                                .tint(.orange)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }
}

struct ProjectRow: View {
    let project: ProjectRecord
    @EnvironmentObject var inventoryManager: InventoryManager

    var brandName: String? {
        guard let brandId = project.brandId else { return nil }
        return inventoryManager.brands.first { $0.id == brandId }?.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(project.name)
                    .font(.headline)

                if project.isArchived {
                    Image(systemName: "archivebox.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
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
                        .background(Color.purple.opacity(0.1))
                        .foregroundColor(.purple)
                        .cornerRadius(4)
                }

                Label("\(project.beadUsage.count) 色", systemImage: "paintpalette")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Label("\(project.totalBeads) 颗", systemImage: "circle.grid.3x3.fill")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }

            // 颜色预览
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(project.beadUsage.prefix(10)) { usage in
                        Text(usage.colorCode)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.1))
                            .cornerRadius(4)
                    }

                    if project.beadUsage.count > 10 {
                        Text("+\(project.beadUsage.count - 10)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    StatisticsView()
        .environmentObject(InventoryManager())
}
