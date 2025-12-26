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

    var displayColors: [BeadColor] {
        let colors = showLowStockOnly
            ? inventoryManager.lowStockColors
            : inventoryManager.beadColors.filter { $0.used > 0 }
        return colors.sorted { $0.used > $1.used }
    }

    var body: some View {
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
                if !displayColors.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(showLowStockOnly ? "低库存颜色" : "使用排行")
                            .font(.headline)
                            .padding(.horizontal)

                        ForEach(Array(displayColors.prefix(20).enumerated()), id: \.element.id) { index, color in
                            UsageRankRow(rank: index + 1, color: color)
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

// MARK: - 总览卡片
struct OverviewCard: View {
    @EnvironmentObject var inventoryManager: InventoryManager

    var usagePercentage: Double {
        guard inventoryManager.totalStock > 0 else { return 0 }
        return Double(inventoryManager.totalUsed) / Double(inventoryManager.totalStock) * 100
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
                    value: "\(inventoryManager.totalStock)",
                    color: .blue
                )
                StatItem(
                    title: "已使用",
                    value: "\(inventoryManager.totalUsed)",
                    color: .orange
                )
                StatItem(
                    title: "剩余",
                    value: "\(inventoryManager.totalAvailable)",
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
    @EnvironmentObject var inventoryManager: InventoryManager

    var maxUsed: Int {
        inventoryManager.beadColors.map { $0.used }.max() ?? 1
    }

    var progress: Double {
        guard maxUsed > 0 else { return 0 }
        return Double(color.used) / Double(maxUsed)
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

                    Text("已用 \(color.used)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("剩余 \(color.available)")
                        .font(.caption)
                        .foregroundColor(color.available < 100 ? .red : .green)
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
            List {
                ForEach(inventoryManager.projects) { project in
                    ProjectRow(project: project)
                }
                .onDelete(perform: inventoryManager.deleteProject)
            }
            .listStyle(.insetGrouped)
        }
    }
}

struct ProjectRow: View {
    let project: ProjectRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(project.name)
                    .font(.headline)

                Spacer()

                Text(project.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
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
