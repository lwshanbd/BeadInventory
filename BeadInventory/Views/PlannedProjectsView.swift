//
//  PlannedProjectsView.swift
//  BeadInventory
//
//  计划项目管理界面
//

import SwiftUI

struct PlannedProjectsView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var expandedProjects: Set<UUID> = []
    @State private var isSelectMode = false
    @State private var selectedProjects: Set<UUID> = []
    @State private var showMergeSheet = false
    @State private var projectToExecute: ProjectRecord?

    var plannedProjects: [ProjectRecord] {
        inventoryManager.plannedProjects()
    }

    var body: some View {
        NavigationStack {
            Group {
                if plannedProjects.isEmpty {
                    EmptyPlannedProjectsView()
                } else {
                    VStack(spacing: 0) {
                        // 合并确认按钮（与统计页面相同的方式）
                        if isSelectMode && selectedProjects.count >= 2 {
                            Button {
                                showMergeSheet = true
                            } label: {
                                HStack {
                                    Image(systemName: "arrow.triangle.merge")
                                    Text("合并 \(selectedProjects.count) 个计划")
                                }
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding()
                                .frame(maxWidth: .infinity)
                                .background(Color.accentColor)
                                .cornerRadius(10)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                        }

                        List {
                            ForEach(plannedProjects) { project in
                                let isParent = inventoryManager.isParentProject(project.id)
                                let isExpanded = expandedProjects.contains(project.id)

                                PlannedProjectRow(
                                    project: project,
                                    isParent: isParent,
                                    isExpanded: isExpanded,
                                    isSelectMode: isSelectMode,
                                    isSelected: selectedProjects.contains(project.id),
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
                                    },
                                    onExecute: {
                                        projectToExecute = project
                                    }
                                )
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        inventoryManager.deletePlannedProject(project.id)
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button {
                                        projectToExecute = project
                                    } label: {
                                        Label("执行", systemImage: "play.fill")
                                    }
                                    .tint(.green)
                                }

                                // 展开的子项目
                                if isParent && isExpanded {
                                    ForEach(inventoryManager.childProjects(of: project.id)) { child in
                                        PlannedChildProjectRow(project: child)
                                            .padding(.leading, 20)
                                    }
                                }
                            }
                        }
                        .listStyle(.insetGrouped)
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("计划项目")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !plannedProjects.isEmpty {
                        Button {
                            withAnimation {
                                isSelectMode.toggle()
                                if !isSelectMode {
                                    selectedProjects.removeAll()
                                }
                            }
                        } label: {
                            Text(isSelectMode ? "取消" : "合并")
                        }
                    }
                }
            }
            // 使用与统计页面相同的方式：传递 projectIds
            .sheet(isPresented: $showMergeSheet) {
                MergePlannedProjectsSheet(projectIds: Array(selectedProjects)) {
                    isSelectMode = false
                    selectedProjects.removeAll()
                }
                .environmentObject(inventoryManager)
            }
            .sheet(item: $projectToExecute) { project in
                ExecutePlannedProjectSheet(project: project)
                    .environmentObject(inventoryManager)
            }
        }
    }
}

// MARK: - 空状态视图
struct EmptyPlannedProjectsView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 60))
                .foregroundColor(.secondary.opacity(0.5))

            Text("暂无计划项目")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("扫描图纸后选择「创建计划」\n可在此处管理和执行")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 计划项目列表
struct PlannedProjectsListView: View {
    let projects: [ProjectRecord]
    @Binding var expandedProjects: Set<UUID>
    @Binding var isSelectMode: Bool
    @Binding var selectedProjects: Set<UUID>
    let onMerge: () -> Void
    let onExecute: (ProjectRecord) -> Void

    @EnvironmentObject var inventoryManager: InventoryManager

    var body: some View {
        VStack(spacing: 0) {
            // 合并确认按钮
            if isSelectMode && selectedProjects.count >= 2 {
                Button {
                    onMerge()
                } label: {
                    HStack {
                        Image(systemName: "arrow.triangle.merge")
                        Text("合并 \(selectedProjects.count) 个计划")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.accentColor)
                    .cornerRadius(10)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            List {
                ForEach(projects) { project in
                    let isParent = inventoryManager.isParentProject(project.id)
                    let isExpanded = expandedProjects.contains(project.id)

                    PlannedProjectRow(
                        project: project,
                        isParent: isParent,
                        isExpanded: isExpanded,
                        isSelectMode: isSelectMode,
                        isSelected: selectedProjects.contains(project.id),
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
                        },
                        onExecute: {
                            onExecute(project)
                        }
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            inventoryManager.deletePlannedProject(project.id)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            onExecute(project)
                        } label: {
                            Label("执行", systemImage: "play.fill")
                        }
                        .tint(.green)
                    }

                    // 子项目
                    if isParent && isExpanded {
                        let children = inventoryManager.childProjects(of: project.id)
                        ForEach(children) { child in
                            PlannedChildProjectRow(project: child)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        inventoryManager.deletePlannedProject(child.id)
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button {
                                        inventoryManager.detachProject(child.id)
                                    } label: {
                                        Label("独立", systemImage: "arrow.up.forward.square")
                                    }
                                    .tint(.blue)
                                }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }
}

// MARK: - 计划项目行
struct PlannedProjectRow: View {
    let project: ProjectRecord
    let isParent: Bool
    let isExpanded: Bool
    let isSelectMode: Bool
    let isSelected: Bool
    let onToggleExpand: () -> Void
    let onToggleSelect: () -> Void
    let onExecute: () -> Void

    @EnvironmentObject var inventoryManager: InventoryManager

    var colorCount: Int {
        if isParent {
            return inventoryManager.aggregatedColorCount(for: project.id)
        }
        return project.beadUsage.count
    }

    var totalBeads: Int {
        if isParent {
            return inventoryManager.aggregatedTotalBeads(for: project.id)
        }
        return project.totalBeads
    }

    var childCount: Int {
        inventoryManager.childProjects(of: project.id).count
    }

    // 从 thumbnail Data 创建 UIImage
    var thumbnailImage: UIImage? {
        guard let data = project.thumbnail else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        HStack(spacing: 8) {
            // 选择模式复选框
            if isSelectMode {
                Button {
                    onToggleSelect()
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(isSelected ? .accentColor : .secondary)
                        .font(.title2)
                }
                .buttonStyle(.plain)
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
                    .frame(width: 50, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
            }

            // 项目内容
            NavigationLink(destination: PlannedProjectDetailView(project: project)) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        // 计划标识
                        Image(systemName: "calendar.badge.clock")
                            .font(.caption)
                            .foregroundColor(.orange)

                        if isParent {
                            Image(systemName: "folder.fill")
                                .font(.caption)
                                .foregroundColor(.accentColor)
                        }

                        Text(project.name)
                            .font(.headline)

                        Spacer()

                        Text(project.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack {
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

                    // 颜色预览
                    if !isParent {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(project.beadUsage.prefix(8)) { usage in
                                    Text(usage.colorCode)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.orange.opacity(0.1))
                                        .cornerRadius(4)
                                }
                                if project.beadUsage.count > 8 {
                                    Text("+\(project.beadUsage.count - 8)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            // 执行按钮（非选择模式下显示）
            if !isSelectMode {
                Button {
                    onExecute()
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundColor(.green)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 子项目行
struct PlannedChildProjectRow: View {
    let project: ProjectRecord

    // 从 thumbnail Data 创建 UIImage
    var thumbnailImage: UIImage? {
        guard let data = project.thumbnail else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.clear)
                .frame(width: 20)

            // 缩略图（如果有）
            if let image = thumbnailImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
            }

            NavigationLink(destination: PlannedProjectDetailView(project: project)) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(project.name)
                            .font(.subheadline)
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
                }
            }
        }
        .padding(.leading, 12)
    }
}

// MARK: - 执行计划弹窗
struct ExecutePlannedProjectSheet: View {
    let project: ProjectRecord
    var onExecuted: (() -> Void)? = nil
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss
    @State private var selectedBrandId: UUID?
    @State private var showConfirmation = false

    var selectedBrand: Brand? {
        guard let id = selectedBrandId else { return nil }
        return inventoryManager.brands.first { $0.id == id }
    }

    var isParent: Bool {
        inventoryManager.isParentProject(project.id)
    }

    var totalBeads: Int {
        if isParent {
            return inventoryManager.aggregatedTotalBeads(for: project.id)
        }
        return project.totalBeads
    }

    var colorCount: Int {
        if isParent {
            return inventoryManager.aggregatedColorCount(for: project.id)
        }
        return project.beadUsage.count
    }

    /// 获取当前项目的所有 beadUsage（父项目则聚合子项目）
    var allBeadUsages: [BeadUsage] {
        if isParent {
            return inventoryManager.aggregatedBeadUsage(for: project.id)
        }
        return project.beadUsage
    }

    /// 检查扣除后库存会变为负数的颜色
    var insufficientStockItems: [(colorCode: String, currentStock: Int, deductAmount: Int)] {
        guard let brandId = selectedBrandId else { return [] }
        var result: [(colorCode: String, currentStock: Int, deductAmount: Int)] = []
        for usage in allBeadUsages {
            let stock = inventoryManager.getStock(brandId: brandId, mardCode: usage.colorCode)
            let currentStock = stock?.stock ?? 0
            if currentStock < usage.quantity {
                result.append((colorCode: usage.colorCode, currentStock: currentStock, deductAmount: usage.quantity))
            }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("项目信息") {
                    HStack {
                        Text("项目名称")
                        Spacer()
                        Text(project.name)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("颜色数量")
                        Spacer()
                        Text("\(colorCount) 种")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("豆子总数")
                        Spacer()
                        Text("\(totalBeads) 颗")
                            .foregroundColor(.secondary)
                    }

                    if isParent {
                        HStack {
                            Text("子项目")
                            Spacer()
                            Text("\(inventoryManager.childProjects(of: project.id).count) 个")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section("选择扣减品牌") {
                    if inventoryManager.brands.isEmpty {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("请先创建品牌")
                                .foregroundColor(.secondary)
                        }
                    } else {
                        ForEach(inventoryManager.brands) { brand in
                            Button {
                                selectedBrandId = brand.id
                            } label: {
                                HStack {
                                    Text(brand.name)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    if selectedBrandId == brand.id {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                            }
                        }
                    }
                }

                Section {
                    Button {
                        showConfirmation = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("执行扣减")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(selectedBrandId == nil)
                }
            }
            .navigationTitle("执行计划")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .alert("确认执行", isPresented: $showConfirmation) {
                Button("取消", role: .cancel) { }
                Button("确认", role: insufficientStockItems.isEmpty ? .none : .destructive) {
                    if let brandId = selectedBrandId {
                        inventoryManager.executePlannedProject(project.id, withBrand: brandId)
                        dismiss()
                        onExecuted?()
                    }
                }
            } message: {
                if let brand = selectedBrand {
                    if insufficientStockItems.isEmpty {
                        Text("将从「\(brand.name)」品牌库存中扣减 \(totalBeads) 颗豆子（\(colorCount) 种颜色）。")
                    } else {
                        Text("将从「\(brand.name)」品牌库存中扣减 \(totalBeads) 颗豆子（\(colorCount) 种颜色）。\n\n⚠️ 以下 \(insufficientStockItems.count) 种颜色扣除后库存将为负数：\n\(insufficientStockItems.map { "\($0.colorCode): \($0.currentStock) - \($0.deductAmount) = \($0.currentStock - $0.deductAmount)" }.joined(separator: "\n"))")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            // 默认选择当前品牌
            selectedBrandId = inventoryManager.currentBrandId
        }
    }
}

// MARK: - 合并计划项目弹窗
struct MergePlannedProjectsSheet: View {
    let projectIds: [UUID]  // 与统计页面相同：传递 UUID 数组
    let onComplete: () -> Void

    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss
    @State private var newName = ""
    @State private var showMergeError = false

    // 从 inventoryManager 查找项目（与统计页面相同的方式）
    var projects: [ProjectRecord] {
        projectIds.compactMap { id in
            inventoryManager.projects.first { $0.id == id }
        }
    }

    // 检查是否只有一个父项目（此时不需要输入新名称）
    var singleParentMerge: (isSimple: Bool, parentName: String?) {
        let parentProjects = projects.filter { inventoryManager.isParentProject($0.id) }
        if parentProjects.count == 1 && projects.count > 1 {
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
                    Section("新计划名称") {
                        TextField("输入名称", text: $newName)
                    }
                }

                Section(singleParentMerge.isSimple ? "将添加以下计划" : "将合并以下计划") {
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
            .navigationTitle(singleParentMerge.isSimple ? "添加到计划" : "合并计划")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("确认") {
                        let name = newName.isEmpty ? "合并计划 \(Date().formatted(date: .numeric, time: .omitted))" : newName
                        if inventoryManager.mergeProjects(projectIds, newName: name) != nil {
                            dismiss()
                            onComplete()
                        } else {
                            showMergeError = true
                        }
                    }
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

// MARK: - 计划项目详情视图
struct PlannedProjectDetailView: View {
    let project: ProjectRecord
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss
    @State private var showExecuteSheet = false
    @State private var showStockCheckSheet = false
    @State private var showEditSheet = false
    @State private var sortByQuantity = true
    @State private var showChildrenSection = true

    // 获取当前项目的最新状态
    var currentProject: ProjectRecord? {
        inventoryManager.projects.first { $0.id == project.id }
    }

    var isParentProject: Bool {
        inventoryManager.isParentProject(project.id)
    }

    var childProjects: [ProjectRecord] {
        inventoryManager.childProjects(of: project.id)
    }

    var displayUsage: [BeadUsage] {
        if isParentProject {
            return inventoryManager.aggregatedBeadUsage(for: project.id)
        }
        return currentProject?.beadUsage ?? project.beadUsage
    }

    var sortedUsage: [BeadUsage] {
        if sortByQuantity {
            return displayUsage.sorted { $0.quantity > $1.quantity }
        } else {
            return displayUsage.sorted { $0.colorCode < $1.colorCode }
        }
    }

    var colorCount: Int {
        if isParentProject {
            return inventoryManager.aggregatedColorCount(for: project.id)
        }
        return currentProject?.beadUsage.count ?? project.beadUsage.count
    }

    var totalBeads: Int {
        if isParentProject {
            return inventoryManager.aggregatedTotalBeads(for: project.id)
        }
        return currentProject?.totalBeads ?? project.totalBeads
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                statusBannerView
                infoCardView
                actionButtonsView
                childProjectsView
                sortHeaderView
                usageListView
            }
            .padding(.vertical)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(currentProject?.name ?? project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showExecuteSheet) { executeSheet }
        .sheet(isPresented: $showStockCheckSheet) { stockCheckSheet }
        .sheet(isPresented: $showEditSheet) { editSheet }
        .onChange(of: currentProject?.isPlanned) { _, isPlanned in
            if isPlanned == false { dismiss() }
        }
        .onChange(of: currentProject) { _, newProject in
            if newProject == nil { dismiss() }
        }
    }

    // MARK: - 子视图

    private var statusBannerView: some View {
        HStack {
            Image(systemName: "calendar.badge.clock")
                .foregroundColor(.orange)
            Text("计划中 - 尚未扣减库存")
                .font(.subheadline)
                .foregroundColor(.orange)
            Spacer()
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(10)
        .padding(.horizontal)
    }

    private var infoCardView: some View {
        PlannedProjectInfoCard(
            project: currentProject ?? project,
            isParent: isParentProject,
            colorCount: colorCount,
            totalBeads: totalBeads,
            childCount: childProjects.count
        )
    }

    private var actionButtonsView: some View {
        HStack(spacing: 12) {
            stockCheckButton
            executeButton
        }
        .padding(.horizontal)
    }

    private var stockCheckButton: some View {
        Button {
            showStockCheckSheet = true
        } label: {
            HStack {
                Image(systemName: "checklist")
                Text("库存确认")
            }
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.blue)
            .cornerRadius(12)
        }
    }

    private var executeButton: some View {
        Button {
            showExecuteSheet = true
        } label: {
            HStack {
                Image(systemName: "play.fill")
                Text("执行扣减")
            }
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.green)
            .cornerRadius(12)
        }
    }

    @ViewBuilder
    private var childProjectsView: some View {
        if isParentProject && !childProjects.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    withAnimation { showChildrenSection.toggle() }
                } label: {
                    HStack {
                        Text("子项目 (\(childProjects.count))")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: showChildrenSection ? "chevron.up" : "chevron.down")
                            .foregroundColor(.secondary)
                    }
                }

                if showChildrenSection {
                    ForEach(childProjects) { child in
                        PlannedChildProjectRowWithActions(
                            project: child,
                            onDelete: { inventoryManager.deletePlannedProject(child.id) },
                            onDetach: { inventoryManager.detachProject(child.id) }
                        )
                    }
                }
            }
            .padding()
            .background(Color(.systemBackground))
            .cornerRadius(12)
            .padding(.horizontal)
        }
    }

    private var sortHeaderView: some View {
        HStack {
            Text(isParentProject ? "汇总颜色用量" : "颜色用量")
                .font(.headline)
            Spacer()
            sortMenu
        }
        .padding(.horizontal)
    }

    private var sortMenu: some View {
        Menu {
            Button {
                sortByQuantity = true
            } label: {
                Label("按用量排序", systemImage: sortByQuantity ? "checkmark" : "")
            }
            Button {
                sortByQuantity = false
            } label: {
                Label("按色号排序", systemImage: sortByQuantity ? "" : "checkmark")
            }
        } label: {
            HStack(spacing: 4) {
                Text(sortByQuantity ? "按用量" : "按色号")
                    .font(.subheadline)
                Image(systemName: "arrow.up.arrow.down")
                    .font(.caption)
            }
            .foregroundColor(.accentColor)
        }
    }

    private var usageListView: some View {
        LazyVStack(spacing: 8) {
            ForEach(sortedUsage) { usage in
                PlannedBeadUsageRow(usage: usage)
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if !isParentProject {
                Button {
                    showEditSheet = true
                } label: {
                    Text("编辑")
                }
            }
        }
    }

    // MARK: - Sheets

    private var executeSheet: some View {
        ExecutePlannedProjectSheet(project: currentProject ?? project) {
            dismiss()
        }
        .environmentObject(inventoryManager)
    }

    private var stockCheckSheet: some View {
        StockCheckSheet(project: currentProject ?? project)
            .environmentObject(inventoryManager)
    }

    @ViewBuilder
    private var editSheet: some View {
        if let proj = currentProject, !isParentProject {
            EditPlannedProjectSheet(project: proj)
                .environmentObject(inventoryManager)
        }
    }
}

// MARK: - 计划项目信息卡片
struct PlannedProjectInfoCard: View {
    let project: ProjectRecord
    let isParent: Bool
    let colorCount: Int
    let totalBeads: Int
    let childCount: Int

    // 从 thumbnail Data 创建 UIImage
    var thumbnailImage: UIImage? {
        guard let data = project.thumbnail else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        VStack(spacing: 16) {
            // 缩略图（如果有）
            if let image = thumbnailImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
            }

            HStack {
                Label(project.date.formatted(date: .long, time: .omitted), systemImage: "calendar")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()

                Label("计划中", systemImage: "clock.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(6)
            }

            Divider()

            HStack(spacing: 20) {
                if isParent {
                    VStack(spacing: 4) {
                        Text("\(childCount)")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.blue)
                        Text("子项目")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                VStack(spacing: 4) {
                    Text("\(colorCount)")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.purple)
                    Text(isParent ? "总颜色" : "颜色数")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                VStack(spacing: 4) {
                    Text("\(totalBeads)")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.orange)
                    Text("待扣减")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }
}

// MARK: - 计划用量行
struct PlannedBeadUsageRow: View {
    let usage: BeadUsage
    @EnvironmentObject var inventoryManager: InventoryManager

    var beadColor: BeadColor? {
        inventoryManager.beadColors.first { $0.mardCode == usage.colorCode }
    }

    var displayColor: Color {
        beadColor?.color ?? .gray
    }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(displayColor)
                .frame(width: 44, height: 44)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(usage.colorCode)
                    .font(.system(.headline, design: .monospaced))
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("\(usage.quantity)")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)

                Text("颗")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // 待扣减标识
            Image(systemName: "clock.arrow.circlepath")
                .foregroundColor(.orange)
                .font(.title3)
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(10)
    }
}

// MARK: - 带操作的子项目行（用于详情页）
struct PlannedChildProjectRowWithActions: View {
    let project: ProjectRecord
    let onDelete: () -> Void
    let onDetach: () -> Void

    @State private var showActionSheet = false

    var body: some View {
        HStack {
            NavigationLink(destination: PlannedProjectDetailView(project: project)) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name)
                        .font(.subheadline)
                        .foregroundColor(.primary)

                    HStack {
                        Label("\(project.beadUsage.count) 色", systemImage: "paintpalette")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Label("\(project.totalBeads) 颗", systemImage: "circle.grid.3x3.fill")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                    }
                }
            }

            // 操作按钮
            Menu {
                Button {
                    onDetach()
                } label: {
                    Label("独立为顶级项目", systemImage: "arrow.up.forward.square")
                }

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("删除子项目", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 库存检查弹窗
struct StockCheckSheet: View {
    let project: ProjectRecord
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss

    var isParentProject: Bool {
        inventoryManager.isParentProject(project.id)
    }

    // 获取汇总的颜色用量（父项目或普通项目）
    var requiredUsage: [BeadUsage] {
        if isParentProject {
            return inventoryManager.aggregatedBeadUsage(for: project.id)
        }
        return project.beadUsage
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // 说明文字
                    HStack {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                        Text("检查各品牌库存是否满足此计划需求")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding()
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(10)
                    .padding(.horizontal)

                    // 各品牌库存检查结果
                    if inventoryManager.brands.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.largeTitle)
                                .foregroundColor(.orange)
                            Text("暂无品牌")
                                .font(.headline)
                            Text("请先创建品牌以检查库存")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else {
                        ForEach(inventoryManager.brands) { brand in
                            BrandStockCheckCard(
                                brand: brand,
                                requiredUsage: requiredUsage
                            )
                        }
                    }
                }
                .padding(.vertical)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("库存确认")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - 品牌库存检查卡片
struct BrandStockCheckCard: View {
    let brand: Brand
    let requiredUsage: [BeadUsage]
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var isExpanded = false

    // 计算库存不足的颜色
    var insufficientColors: [(colorCode: String, required: Int, available: Int, shortage: Int)] {
        var result: [(colorCode: String, required: Int, available: Int, shortage: Int)] = []

        for usage in requiredUsage {
            // 根据 colorCode (MARD) 找到对应的库存
            if let stock = inventoryManager.getStock(brandId: brand.id, mardCode: usage.colorCode) {
                if stock.available < usage.quantity {
                    result.append((
                        colorCode: usage.colorCode,
                        required: usage.quantity,
                        available: stock.available,
                        shortage: usage.quantity - stock.available
                    ))
                }
            } else {
                // 找不到库存记录，视为库存为 0
                result.append((
                    colorCode: usage.colorCode,
                    required: usage.quantity,
                    available: 0,
                    shortage: usage.quantity
                ))
            }
        }

        return result.sorted { $0.shortage > $1.shortage }
    }

    var isSufficient: Bool {
        insufficientColors.isEmpty
    }

    var totalShortage: Int {
        insufficientColors.reduce(0) { $0 + $1.shortage }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 品牌标题和状态
            Button {
                withAnimation { isExpanded.toggle() }
            } label: {
                HStack {
                    // 品牌名称
                    Text(brand.name)
                        .font(.headline)
                        .foregroundColor(.primary)

                    Spacer()

                    // 状态标签
                    if isSufficient {
                        Label("库存充足", systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundColor(.green)
                    } else {
                        Label("缺少 \(insufficientColors.count) 色", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundColor(.red)
                    }

                    // 展开指示器（仅当有不足时显示）
                    if !isSufficient {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            // 汇总信息
            if !isSufficient {
                HStack {
                    Label("共缺少 \(totalShortage) 颗", systemImage: "minus.circle")
                        .font(.caption)
                        .foregroundColor(.orange)

                    Spacer()

                    if !isExpanded {
                        Text("点击展开详情")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // 展开的详细列表
            if isExpanded && !isSufficient {
                Divider()

                VStack(spacing: 8) {
                    ForEach(insufficientColors, id: \.colorCode) { item in
                        InsufficientColorRow(
                            colorCode: item.colorCode,
                            required: item.required,
                            available: item.available,
                            shortage: item.shortage
                        )
                    }
                }
            }
        }
        .padding()
        .background(isSufficient ? Color.green.opacity(0.05) : Color.red.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSufficient ? Color.green.opacity(0.3) : Color.red.opacity(0.3), lineWidth: 1)
        )
        .cornerRadius(12)
        .padding(.horizontal)
    }
}

// MARK: - 库存不足颜色行
struct InsufficientColorRow: View {
    let colorCode: String
    let required: Int
    let available: Int
    let shortage: Int
    @EnvironmentObject var inventoryManager: InventoryManager

    var beadColor: BeadColor? {
        inventoryManager.beadColors.first { $0.mardCode == colorCode }
    }

    var displayColor: Color {
        beadColor?.color ?? .gray
    }

    var body: some View {
        HStack(spacing: 10) {
            // 颜色预览
            RoundedRectangle(cornerRadius: 4)
                .fill(displayColor)
                .frame(width: 28, height: 28)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )

            // 色号
            Text(colorCode)
                .font(.system(.subheadline, design: .monospaced))
                .fontWeight(.medium)

            Spacer()

            // 库存信息
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Text("需要")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(required)")
                        .font(.caption)
                        .fontWeight(.medium)
                }

                HStack(spacing: 4) {
                    Text("现有")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(available)")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            // 缺少量
            Text("-\(shortage)")
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundColor(.red)
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color(.systemBackground))
        .cornerRadius(6)
    }
}

// MARK: - 编辑计划项目弹窗
struct EditPlannedProjectSheet: View {
    let project: ProjectRecord
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss

    @State private var projectName: String = ""
    @State private var beadUsages: [EditableBeadUsage] = []
    @State private var showAddColorSheet = false
    @State private var editingUsageId: UUID?

    // 可编辑的用量结构
    struct EditableBeadUsage: Identifiable {
        let id: UUID
        var colorCode: String
        var quantity: Int

        init(from usage: BeadUsage) {
            self.id = usage.id
            self.colorCode = usage.colorCode
            self.quantity = usage.quantity
        }
    }

    var hasChanges: Bool {
        if projectName != project.name { return true }
        if beadUsages.count != project.beadUsage.count { return true }
        for (index, usage) in beadUsages.enumerated() {
            if index >= project.beadUsage.count { return true }
            let original = project.beadUsage[index]
            if usage.colorCode != original.colorCode || usage.quantity != original.quantity {
                return true
            }
        }
        return false
    }

    var body: some View {
        NavigationStack {
            List {
                // 名称编辑
                Section("项目名称") {
                    TextField("输入名称", text: $projectName)
                }

                // 颜色用量编辑
                Section {
                    ForEach($beadUsages) { $usage in
                        EditableUsageRow(
                            usage: $usage,
                            onDelete: {
                                beadUsages.removeAll { $0.id == usage.id }
                            }
                        )
                    }
                    .onDelete { indexSet in
                        beadUsages.remove(atOffsets: indexSet)
                    }

                    // 添加颜色按钮
                    Button {
                        showAddColorSheet = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.green)
                            Text("添加颜色")
                        }
                    }
                } header: {
                    HStack {
                        Text("颜色用量")
                        Spacer()
                        Text("\(beadUsages.count) 色 · \(beadUsages.reduce(0) { $0 + $1.quantity }) 颗")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("编辑计划")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        saveChanges()
                        dismiss()
                    }
                    .disabled(!hasChanges || projectName.isEmpty || beadUsages.isEmpty)
                    .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showAddColorSheet) {
                AddColorToProjectSheet { colorCode, quantity in
                    // 检查是否已存在
                    if let index = beadUsages.firstIndex(where: { $0.colorCode == colorCode }) {
                        beadUsages[index].quantity += quantity
                    } else {
                        beadUsages.append(EditableBeadUsage(from: BeadUsage(
                            colorCode: colorCode,
                            brandId: nil,
                            quantity: quantity,
                            isDeducted: false
                        )))
                    }
                }
                .environmentObject(inventoryManager)
            }
        }
        .onAppear {
            projectName = project.name
            beadUsages = project.beadUsage.map { EditableBeadUsage(from: $0) }
        }
        .presentationDetents([.large])
    }

    private func saveChanges() {
        let newUsages = beadUsages.map { usage in
            BeadUsage(
                id: usage.id,
                colorCode: usage.colorCode,
                brandId: nil,
                quantity: usage.quantity,
                isDeducted: false
            )
        }
        inventoryManager.updatePlannedProject(project.id, newName: projectName, newBeadUsage: newUsages)
    }
}

// MARK: - 可编辑用量行
struct EditableUsageRow: View {
    @Binding var usage: EditPlannedProjectSheet.EditableBeadUsage
    let onDelete: () -> Void
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var quantityText: String = ""
    @FocusState private var isQuantityFocused: Bool

    var beadColor: BeadColor? {
        inventoryManager.beadColors.first { $0.mardCode == usage.colorCode }
    }

    var displayColor: Color {
        beadColor?.color ?? .gray
    }

    var body: some View {
        HStack(spacing: 12) {
            // 颜色预览
            RoundedRectangle(cornerRadius: 6)
                .fill(displayColor)
                .frame(width: 36, height: 36)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )

            // 色号
            Text(usage.colorCode)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)

            Spacer()

            // 数量输入
            HStack(spacing: 8) {
                Button {
                    if usage.quantity > 1 {
                        usage.quantity -= 1
                        quantityText = "\(usage.quantity)"
                    }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title2)
                        .foregroundColor(usage.quantity > 1 ? .orange : .gray)
                }
                .buttonStyle(.plain)
                .disabled(usage.quantity <= 1)

                TextField("数量", text: $quantityText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .frame(width: 60)
                    .padding(.vertical, 6)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                    .focused($isQuantityFocused)
                    .onChange(of: quantityText) { _, newValue in
                        if let value = Int(newValue), value > 0 {
                            usage.quantity = value
                        }
                    }
                    .onChange(of: isQuantityFocused) { _, focused in
                        if !focused {
                            // 失去焦点时验证并恢复
                            if let value = Int(quantityText), value > 0 {
                                usage.quantity = value
                            }
                            quantityText = "\(usage.quantity)"
                        }
                    }

                Button {
                    usage.quantity += 1
                    quantityText = "\(usage.quantity)"
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundColor(.green)
                }
                .buttonStyle(.plain)
            }

            // 删除按钮
            Button {
                onDelete()
            } label: {
                Image(systemName: "trash.circle.fill")
                    .font(.title2)
                    .foregroundColor(.red.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .onAppear {
            quantityText = "\(usage.quantity)"
        }
    }
}

// MARK: - 添加颜色到项目弹窗
struct AddColorToProjectSheet: View {
    let onAdd: (String, Int) -> Void
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var inventoryManager: InventoryManager

    @State private var searchText = ""
    @State private var selectedColorCode: String?
    @State private var quantity: Int = 1
    @State private var quantityText: String = "1"
    @FocusState private var isSearchFocused: Bool

    var filteredColors: [BeadColor] {
        if searchText.isEmpty {
            return Array(inventoryManager.beadColors.prefix(50))
        }
        let search = searchText.uppercased()
        return inventoryManager.beadColors.filter { color in
            color.mardCode.uppercased().contains(search) ||
            color.colorName.uppercased().contains(search) ||
            color.cocoCode.uppercased().contains(search) ||
            color.manmanCode.uppercased().contains(search)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 搜索框
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("搜索色号或颜色名称", text: $searchText)
                        .focused($isSearchFocused)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(10)
                .background(Color(.systemGray6))
                .cornerRadius(10)
                .padding()

                // 已选择的颜色和数量
                if let colorCode = selectedColorCode,
                   let color = inventoryManager.beadColors.first(where: { $0.mardCode == colorCode }) {
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(color.color)
                                .frame(width: 50, height: 50)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                )

                            VStack(alignment: .leading) {
                                Text(color.mardCode)
                                    .font(.headline)
                                Text(color.colorName)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            // 数量选择
                            HStack(spacing: 8) {
                                Button {
                                    if quantity > 1 {
                                        quantity -= 1
                                        quantityText = "\(quantity)"
                                    }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.title2)
                                        .foregroundColor(quantity > 1 ? .orange : .gray)
                                }
                                .disabled(quantity <= 1)

                                TextField("数量", text: $quantityText)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 60)
                                    .padding(.vertical, 6)
                                    .background(Color(.systemGray6))
                                    .cornerRadius(8)
                                    .onChange(of: quantityText) { _, newValue in
                                        if let value = Int(newValue), value > 0 {
                                            quantity = value
                                        }
                                    }

                                Button {
                                    quantity += 1
                                    quantityText = "\(quantity)"
                                } label: {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.title2)
                                        .foregroundColor(.green)
                                }
                            }
                        }
                        .padding()
                        .background(Color(.systemBackground))
                        .cornerRadius(12)
                        .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                    }
                    .padding(.horizontal)
                }

                // 颜色列表
                List {
                    ForEach(filteredColors) { color in
                        Button {
                            selectedColorCode = color.mardCode
                        } label: {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(color.color)
                                    .frame(width: 32, height: 32)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                    )

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(color.mardCode)
                                        .font(.system(.subheadline, design: .monospaced))
                                        .fontWeight(.medium)
                                        .foregroundColor(.primary)
                                    Text(color.colorName)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                if selectedColorCode == color.mardCode {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("添加颜色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("添加") {
                        if let colorCode = selectedColorCode {
                            onAdd(colorCode, quantity)
                            dismiss()
                        }
                    }
                    .disabled(selectedColorCode == nil)
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
        .onAppear {
            isSearchFocused = true
        }
    }
}

#Preview {
    PlannedProjectsView()
        .environmentObject(InventoryManager())
}
