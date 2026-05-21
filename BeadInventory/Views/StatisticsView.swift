//
//  StatisticsView.swift
//  BeadInventory
//
//  统计和历史记录界面
//

import SwiftUI

struct StatisticsView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var selectedSegment = 1

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

    var lowStockThreshold: Int {
        guard let brandId = inventoryManager.currentBrandId else { return 100 }
        return inventoryManager.getLowStockThreshold(for: brandId)
    }

    var isLowStock: Bool { stock.available < lowStockThreshold }

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
            BIColorSwatch(hex: color.colorHex, size: 32)

            // 色号和进度条
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(color.displayCode(for: inventoryManager.currentColorSystem))
                        .font(.system(.subheadline, design: .monospaced))
                        .fontWeight(.medium)

                    Spacer()

                    Text("已用 \(stock.used)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("剩余 \(stock.available)")
                        .font(.caption)
                        .foregroundColor(isLowStock ? .red : .green)
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
                            .background(selectedProjects.count >= 2 ? Color.accentColor : Color.gray.opacity(0.3))
                            .foregroundColor(selectedProjects.count >= 2 ? .white : .secondary)
                            .cornerRadius(10)
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
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }

                        // 退回按钮
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
                            .background(Color.orange)
                            .foregroundColor(.white)
                            .cornerRadius(10)
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
                                    inventoryManager.deleteProject(id: project.id)
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
                            .tint(.blue)
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
                                .tint(.green)
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
                                .tint(.orange)
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
                                    inventoryManager.deleteProject(id: project.id)
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
                                        inventoryManager.deleteProject(id: child.id)
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }

                                    // 复制到计划
                                    Button {
                                        _ = inventoryManager.duplicateProjectAsPlan(child.id)
                                    } label: {
                                        Label("复制到计划", systemImage: "doc.on.doc")
                                    }
                                    .tint(.blue)
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button {
                                        inventoryManager.detachProject(child.id)
                                    } label: {
                                        Label("独立", systemImage: "arrow.up.forward.square")
                                    }
                                    .tint(.green)
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
                                        inventoryManager.deleteProject(id: child.id)
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
                    .foregroundColor(.orange)

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
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
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
                            .background(Color(.systemGray5))
                            .foregroundColor(.primary)
                            .cornerRadius(10)
                    }

                    Button {
                        onConfirm()
                    } label: {
                        Text("确认退回")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.orange)
                            .foregroundColor(.white)
                            .cornerRadius(10)
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
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
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

                        if isParent {
                            Text("\(childCount) 个子项目")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.1))
                                .foregroundColor(.blue)
                                .cornerRadius(4)
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
                                        .cornerRadius(4)
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
                                .foregroundColor(.blue)
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
