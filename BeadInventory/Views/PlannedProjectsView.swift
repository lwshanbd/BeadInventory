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
        .frame(maxHeight: .infinity)
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

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.clear)
                .frame(width: 20)

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
                Button("确认") {
                    if let brandId = selectedBrandId {
                        inventoryManager.executePlannedProject(project.id, withBrand: brandId)
                        dismiss()
                    }
                }
            } message: {
                if let brand = selectedBrand {
                    Text("将从「\(brand.name)」品牌库存中扣减 \(totalBeads) 颗豆子（\(colorCount) 种颜色）。此操作不可撤销。")
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
    @State private var showExecuteSheet = false
    @State private var sortByQuantity = true
    @State private var showChildrenSection = true

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
        return project.beadUsage
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
        return project.beadUsage.count
    }

    var totalBeads: Int {
        if isParentProject {
            return inventoryManager.aggregatedTotalBeads(for: project.id)
        }
        return project.totalBeads
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 计划状态提示
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

                // 项目信息卡片
                PlannedProjectInfoCard(
                    project: project,
                    isParent: isParentProject,
                    colorCount: colorCount,
                    totalBeads: totalBeads,
                    childCount: childProjects.count
                )

                // 执行按钮
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
                .padding(.horizontal)

                // 子项目列表
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
                                    onDelete: {
                                        inventoryManager.deletePlannedProject(child.id)
                                    },
                                    onDetach: {
                                        inventoryManager.detachProject(child.id)
                                    }
                                )
                            }
                        }
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal)
                }

                // 排序选择
                HStack {
                    Text(isParentProject ? "汇总颜色用量" : "颜色用量")
                        .font(.headline)

                    Spacer()

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
                .padding(.horizontal)

                // 颜色用量列表
                LazyVStack(spacing: 8) {
                    ForEach(sortedUsage) { usage in
                        PlannedBeadUsageRow(usage: usage)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showExecuteSheet) {
            ExecutePlannedProjectSheet(project: project)
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

    var body: some View {
        VStack(spacing: 16) {
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

#Preview {
    PlannedProjectsView()
        .environmentObject(InventoryManager())
}
