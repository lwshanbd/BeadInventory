//
//  PlannedProjectsView.swift
//  BeadInventory
//
//  计划项目管理界面
//

import SwiftUI
import TipKit
import PhotosUI

struct PlannedProjectsView: View {
    enum ActiveSheet: Identifiable {
        case merge
        case multiStockCheck
        case replenishSuggestion
        case directPurchase
        case execute(ProjectRecord)

        var id: String {
            switch self {
            case .merge: return "merge"
            case .multiStockCheck: return "multiStockCheck"
            case .replenishSuggestion: return "replenishSuggestion"
            case .directPurchase: return "directPurchase"
            case .execute(let project): return "execute-\(project.id)"
            }
        }
    }

    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var expandedProjects: Set<UUID> = []
    @State private var isSelectMode = false
    @State private var selectedProjects: Set<UUID> = []
    @State private var activeSheet: ActiveSheet?
    @State private var searchText = ""

    var plannedProjects: [ProjectRecord] {
        inventoryManager.plannedProjects()
    }

    var filteredProjects: [ProjectRecord] {
        if searchText.isEmpty {
            return plannedProjects
        }
        return plannedProjects.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if plannedProjects.isEmpty {
                    EmptyPlannedProjectsView()
                } else {
                    VStack(spacing: 0) {
                        List {
                            if plannedProjects.count >= 2 {
                                TipView(PlanMergeTip())
                            }
                            TipView(ReplenishTip())
                            // 多选操作按钮区域（放在 List 内部，随列表滚动）
                            if isSelectMode && !selectedProjects.isEmpty {
                                Section {
                                    VStack(spacing: 8) {
                                        HStack(spacing: 8) {
                                            // 库存确认按钮
                                            Button {
                                                activeSheet = .multiStockCheck
                                            } label: {
                                                HStack(spacing: 4) {
                                                    Image(systemName: "checklist")
                                                    Text("库存确认")
                                                }
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundColor(.white)
                                                .padding(.vertical, 12)
                                                .frame(maxWidth: .infinity)
                                                .background(Color.blue)
                                                .cornerRadius(10)
                                            }
                                            .buttonStyle(.borderless)

                                            // 补豆建议按钮
                                            Button {
                                                activeSheet = .replenishSuggestion
                                            } label: {
                                                HStack(spacing: 4) {
                                                    Image(systemName: "cart.badge.plus")
                                                    Text("补豆建议")
                                                }
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundColor(.white)
                                                .padding(.vertical, 12)
                                                .frame(maxWidth: .infinity)
                                                .background(Color.orange)
                                                .cornerRadius(10)
                                            }
                                            .buttonStyle(.borderless)
                                        }

                                        HStack(spacing: 8) {
                                            // 直接补豆按钮
                                            Button {
                                                activeSheet = .directPurchase
                                            } label: {
                                                HStack(spacing: 4) {
                                                    Image(systemName: "bag.badge.plus")
                                                    Text("直接补豆")
                                                }
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundColor(.white)
                                                .padding(.vertical, 12)
                                                .frame(maxWidth: .infinity)
                                                .background(Color.green)
                                                .cornerRadius(10)
                                            }
                                            .buttonStyle(.borderless)

                                            // 合并按钮（需要选中 2 个及以上）
                                            Button {
                                                activeSheet = .merge
                                            } label: {
                                                HStack(spacing: 4) {
                                                    Image(systemName: "arrow.triangle.merge")
                                                    Text("合并")
                                                }
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundColor(.white)
                                                .padding(.vertical, 12)
                                                .frame(maxWidth: .infinity)
                                                .background(selectedProjects.count >= 2 ? Color.accentColor : Color.gray)
                                                .cornerRadius(10)
                                            }
                                            .buttonStyle(.borderless)
                                            .disabled(selectedProjects.count < 2)
                                        }
                                    }
                                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                }
                            }

                            ForEach(filteredProjects) { project in
                                let isParent = inventoryManager.isParentProject(project.id)
                                let isExpanded = expandedProjects.contains(project.id)

                                PlannedProjectRow(
                                    project: project,
                                    isParent: isParent,
                                    isExpanded: isExpanded,
                                    isSelectMode: isSelectMode,
                                    isSelected: selectedProjects.contains(project.id),
                                    showSearchCheckbox: !searchText.isEmpty && !isSelectMode,
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
                                        // 搜索时点击复选框自动进入多选模式
                                        if !isSelectMode && !searchText.isEmpty {
                                            withAnimation { isSelectMode = true }
                                        }
                                        if selectedProjects.contains(project.id) {
                                            selectedProjects.remove(project.id)
                                        } else {
                                            selectedProjects.insert(project.id)
                                        }
                                    },
                                    onExecute: {
                                        activeSheet = .execute(project)
                                    }
                                )
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        inventoryManager.deletePlannedProject(project.id)
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }

                                    Button {
                                        _ = inventoryManager.duplicatePlannedProject(project.id)
                                    } label: {
                                        Label("复制", systemImage: "doc.on.doc")
                                    }
                                    .tint(.blue)
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button {
                                        activeSheet = .execute(project)
                                    } label: {
                                        Label("执行", systemImage: "play.fill")
                                    }
                                    .tint(.green)
                                }

                                // 展开的子项目
                                if isParent && isExpanded {
                                    ForEach(inventoryManager.plannedChildProjects(of: project.id)) { child in
                                        PlannedChildProjectRow(project: child)
                                            .padding(.leading, 20)
                                    }
                                }
                            }
                        }
                        .listStyle(.insetGrouped)
                        .scrollDismissesKeyboard(.immediately)
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("计划项目")
            .searchable(text: $searchText, prompt: "搜索计划名称")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if isSelectMode {
                        Button {
                            if selectedProjects.count == filteredProjects.count {
                                selectedProjects.removeAll()
                            } else {
                                selectedProjects = Set(filteredProjects.map { $0.id })
                            }
                        } label: {
                            Text(selectedProjects.count == filteredProjects.count ? "取消全选" : "全选")
                        }
                    }
                }
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
                            Text(isSelectMode ? "取消" : "多选")
                        }
                    }
                }
            }
            // 使用与统计页面相同的方式：传递 projectIds
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .merge:
                    MergePlannedProjectsSheet(projectIds: Array(selectedProjects)) {
                        isSelectMode = false
                        selectedProjects.removeAll()
                    }
                    .environmentObject(inventoryManager)
                case .multiStockCheck:
                    MultiProjectStockCheckSheet(projectIds: Array(selectedProjects))
                        .environmentObject(inventoryManager)
                case .replenishSuggestion:
                    ReplenishSuggestionSheet(projectIds: Array(selectedProjects))
                        .environmentObject(inventoryManager)
                case .directPurchase:
                    DirectPurchaseSheet(projectIds: Array(selectedProjects))
                        .environmentObject(inventoryManager)
                case .execute(let project):
                    ExecutePlannedProjectSheet(project: project)
                        .environmentObject(inventoryManager)
                }
            }
        }
    }
}

// MARK: - 空状态视图
struct EmptyPlannedProjectsView: View {
    var body: some View {
        EmptyStateView(
            icon: "calendar.badge.clock",
            title: "暂无计划项目",
            description: "扫描图纸后选择「创建计划」\n可在此处管理和执行"
        )
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
                        showSearchCheckbox: false,
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

                        Button {
                            _ = inventoryManager.duplicatePlannedProject(project.id)
                        } label: {
                            Label("复制", systemImage: "doc.on.doc")
                        }
                        .tint(.blue)
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
                        let children = inventoryManager.plannedChildProjects(of: project.id)
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
    let showSearchCheckbox: Bool
    let onToggleExpand: () -> Void
    let onToggleSelect: () -> Void
    let onExecute: () -> Void

    @EnvironmentObject var inventoryManager: InventoryManager

    var colorCount: Int {
        if isParent {
            return inventoryManager.plannedAggregatedColorCount(for: project.id)
        }
        return project.beadUsage.count
    }

    var totalBeads: Int {
        if isParent {
            return inventoryManager.plannedAggregatedTotalBeads(for: project.id)
        }
        return project.totalBeads
    }

    var childCount: Int {
        inventoryManager.plannedChildProjects(of: project.id).count
    }

    // 从 thumbnail Data 创建 UIImage
    var thumbnailImage: UIImage? {
        guard let data = project.thumbnail else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        if isSelectMode {
            // 选择模式：整行使用 onTapGesture，避免 Button 在搜索键盘弹出时被吞掉点击
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .font(.title2)
                    .frame(width: 44, height: 44)

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

                projectContentView
            }
            .contentShape(Rectangle())
            .onTapGesture { onToggleSelect() }
        } else {
            // 非选择模式：NavigationLink + 按钮
            HStack(spacing: 8) {
                // 搜索时显示复选框，点击后自动进入多选模式
                if showSearchCheckbox {
                    Button {
                        onToggleSelect()
                    } label: {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(isSelected ? .accentColor : .secondary)
                            .font(.title3)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if isParent {
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

                NavigationLink(destination: PlannedProjectDetailView(project: project)) {
                    projectContentView
                }

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

    // 提取项目内容视图
    private var projectContentView: some View {
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
                    .foregroundColor(.primary)

                // 色号体系徽章
                BIBadge(
                    project.colorSystem.displayName,
                    style: .custom(
                        background: project.colorSystem == .kaka ? Color.purple.opacity(0.15) : Color.blue.opacity(0.15),
                        foreground: project.colorSystem == .kaka ? .purple : .blue
                    )
                )

                Spacer()

                Text(project.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                if isParent {
                    BIBadge("\(childCount) 个子项目", style: .info)
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
                            let displayCode = inventoryManager.findColor(byCode: usage.colorCode)?
                                .displayCode(for: project.colorSystem) ?? usage.colorCode
                            BIBadge(displayCode, style: .neutral)
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

                        // 色号体系徽章
                        BIBadge(
                            project.colorSystem.displayName,
                            style: .custom(
                                background: project.colorSystem == .kaka ? Color.purple.opacity(0.15) : Color.blue.opacity(0.15),
                                foreground: project.colorSystem == .kaka ? .purple : .blue
                            )
                        )

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
    @State private var resolver: DeductionResolver?
    private let similarityService = ColorSimilarityService()

    var matchingBrands: [Brand] {
        inventoryManager.brands
            .filter { $0.colorSystem == project.colorSystem }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var selectedBrand: Brand? {
        guard let id = selectedBrandId else { return nil }
        return inventoryManager.brands.first { $0.id == id }
    }

    var isParent: Bool {
        inventoryManager.isParentProject(project.id)
    }

    var totalBeads: Int {
        if isParent {
            return inventoryManager.plannedAggregatedTotalBeads(for: project.id)
        }
        return project.totalBeads
    }

    var colorCount: Int {
        if isParent {
            return inventoryManager.plannedAggregatedColorCount(for: project.id)
        }
        return project.beadUsage.count
    }

    var allBeadUsages: [BeadUsage] {
        if isParent {
            return inventoryManager.plannedAggregatedBeadUsage(for: project.id)
        }
        return project.beadUsage
    }

    private var executeConfirmMessage: String {
        guard let brand = selectedBrand else { return "" }
        var msg = "将从「\(brand.name)」品牌库存中扣减 \(totalBeads) 颗豆子（\(colorCount) 种颜色）。"
        if let resolver = resolver {
            if resolver.hasManualOverrides {
                let overrides = resolver.manualOverrideItems.compactMap { item in
                    if let b = matchingBrands.first(where: { $0.id == item.brandId }) {
                        return "\(item.colorCode) → \(b.name)"
                    }
                    return nil
                }
                msg += "\n\n跨品牌扣减：\n" + overrides.joined(separator: "\n")
            }
            if !resolver.insufficientItems.isEmpty {
                msg += "\n\n⚠️ \(resolver.insufficientItems.count) 种颜色扣除后库存将为负数"
            }
        }
        return msg
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
                            Text("\(inventoryManager.plannedChildProjects(of: project.id).count) 个")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section("选择扣减品牌") {
                    if matchingBrands.isEmpty {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("暂无\(project.colorSystem.displayName)体系的品牌，请先创建")
                                .foregroundColor(.secondary)
                        }
                    } else {
                        ForEach(matchingBrands) { brand in
                            Button {
                                selectedBrandId = brand.id
                                initializeOrUpdateResolver(brandId: brand.id)
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

                if let resolver = resolver, selectedBrandId != nil, !isParent {
                    ResolverDeductionSection(
                        resolver: resolver,
                        matchingBrands: matchingBrands,
                        colorSystem: project.colorSystem,
                        inventoryManager: inventoryManager,
                        similarityService: similarityService
                    )
                }

                Section {
                    Button {
                        showConfirmation = true
                    } label: {
                        HStack {
                            Spacer()
                            if let resolver = resolver, !resolver.insufficientItems.isEmpty {
                                Image(systemName: "exclamationmark.triangle.fill")
                            }
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
                Button("确认", role: (resolver?.insufficientItems.isEmpty ?? true) ? .none : .destructive) {
                    if let resolver = resolver {
                        inventoryManager.executePlannedProjectWithResolver(project.id, resolver: resolver)
                        dismiss()
                        onExecuted?()
                    }
                }
            } message: {
                Text(executeConfirmMessage)
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            if let currentId = inventoryManager.currentBrandId,
               matchingBrands.contains(where: { $0.id == currentId }) {
                selectedBrandId = currentId
            } else {
                selectedBrandId = matchingBrands.first?.id
            }
            if let brandId = selectedBrandId {
                initializeOrUpdateResolver(brandId: brandId)
            }
        }
    }

    private func initializeOrUpdateResolver(brandId: UUID) {
        if let existing = resolver {
            existing.setPrimaryBrand(brandId)
        } else {
            let newResolver = DeductionResolver(inventoryManager: inventoryManager)
            newResolver.initializeFromBeadUsages(
                allBeadUsages,
                primaryBrandId: brandId,
                colorSystem: project.colorSystem
            )
            resolver = newResolver
        }
    }
}

// MARK: - Resolver 扣减详情 Section（使用 @ObservedObject 正确订阅变更）
private struct ResolverDeductionSection: View {
    @ObservedObject var resolver: DeductionResolver
    let matchingBrands: [Brand]
    let colorSystem: ColorSystem
    let inventoryManager: InventoryManager
    let similarityService: ColorSimilarityService

    var body: some View {
        Section("扣减详情") {
            ForEach(resolver.items) { item in
                let beadColor = inventoryManager.findColor(byCode: item.mardCode)
                let brandName = matchingBrands.first(where: { $0.id == item.brandId })?.name ?? "未知"
                let threshold = matchingBrands.first(where: { $0.id == item.brandId })?.lowStockThreshold ?? 100
                let similarColors = similarityService.findSimilarColors(
                    for: item.mardCode,
                    brandId: item.brandId,
                    allColors: inventoryManager.allBeadColors,
                    brandStocks: inventoryManager.brandStocks
                )

                DeductionItemRow(
                    item: item,
                    beadColor: beadColor,
                    matchingBrands: matchingBrands,
                    similarColors: similarColors,
                    colorSystem: colorSystem,
                    lowStockThreshold: threshold,
                    brandName: brandName,
                    onBrandChanged: { newBrandId in
                        resolver.overrideBrand(for: item.id, to: newBrandId)
                    },
                    onResetBrand: {
                        resolver.resetToPrimary(for: item.id)
                    },
                    onSubstitute: { newMardCode, newColorCode in
                        resolver.substituteColor(
                            itemId: item.id,
                            newMardCode: newMardCode,
                            newColorCode: newColorCode
                        )
                    }
                )
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
            }
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
    @State private var showThumbnailEditor = false
    @State private var sortByQuantity = true
    @State private var showChildrenSection = true
    @State private var showPatternCalibration = false
    @State private var showPatternHighlight = false

    // 获取当前项目的最新状态
    var currentProject: ProjectRecord? {
        inventoryManager.projects.first { $0.id == project.id }
    }

    var isParentProject: Bool {
        inventoryManager.isParentProject(project.id)
    }

    var childProjects: [ProjectRecord] {
        inventoryManager.plannedChildProjects(of: project.id)
    }

    var displayUsage: [BeadUsage] {
        if isParentProject {
            return inventoryManager.plannedAggregatedBeadUsage(for: project.id)
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
            return inventoryManager.plannedAggregatedColorCount(for: project.id)
        }
        return currentProject?.beadUsage.count ?? project.beadUsage.count
    }

    var totalBeads: Int {
        if isParentProject {
            return inventoryManager.plannedAggregatedTotalBeads(for: project.id)
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
        .sheet(isPresented: $showThumbnailEditor) { thumbnailEditorSheet }
        .sheet(isPresented: $showPatternCalibration) {
            PatternCalibrationView(
                project: currentProject ?? project,
                onComplete: {
                    showPatternHighlight = true
                }
            )
            .environmentObject(inventoryManager)
        }
        .fullScreenCover(isPresented: $showPatternHighlight) {
            if let p = inventoryManager.projects.first(where: { $0.id == project.id }) {
                PatternHighlightView(project: p)
                    .environmentObject(inventoryManager)
            }
        }
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
            childCount: childProjects.count,
            onEditThumbnail: { showThumbnailEditor = true }
        )
    }

    private var actionButtonsView: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                stockCheckButton
                executeButton
            }
            patternHighlightButton
        }
        .padding(.horizontal)
    }

    private var patternHighlightButton: some View {
        Button {
            let p = currentProject ?? project
            if p.patternGrid != nil {
                showPatternHighlight = true
            } else {
                showPatternCalibration = true
            }
        } label: {
            HStack {
                Image(systemName: "square.grid.3x3.square")
                Text("拼图模式")
            }
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding()
            .background((currentProject ?? project).thumbnail == nil ? Color.gray : Color.purple)
            .cornerRadius(12)
        }
        .disabled((currentProject ?? project).thumbnail == nil)
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
                PlannedBeadUsageRow(usage: usage, colorSystem: (currentProject ?? project).colorSystem)
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    if let _ = inventoryManager.duplicatePlannedProject(project.id) {
                        dismiss()
                    }
                } label: {
                    Label("复制计划", systemImage: "doc.on.doc")
                }

                if !isParentProject {
                    Button {
                        showEditSheet = true
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
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

    private var thumbnailEditorSheet: some View {
        ProjectImageEditorSheet(
            projectId: project.id,
            title: "项目封面",
            currentImage: (currentProject ?? project).thumbnail.flatMap { UIImage(data: $0) },
            onSave: { imageData in
                inventoryManager.updateProjectThumbnail(project.id, thumbnail: imageData)
            }
        )
        .environmentObject(inventoryManager)
    }
}

// MARK: - 计划项目信息卡片
struct PlannedProjectInfoCard: View {
    let project: ProjectRecord
    let isParent: Bool
    let colorCount: Int
    let totalBeads: Int
    let childCount: Int
    var onEditThumbnail: (() -> Void)? = nil

    // 从 thumbnail Data 创建 UIImage
    var thumbnailImage: UIImage? {
        guard let data = project.thumbnail else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        VStack(spacing: 16) {
            // 缩略图区域
            ZStack(alignment: .topTrailing) {
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
                } else if onEditThumbnail != nil {
                    // 无图片时的占位符
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.1))
                        .frame(height: 100)
                        .overlay(
                            VStack(spacing: 8) {
                                Image(systemName: "photo.badge.plus")
                                    .font(.title2)
                                    .foregroundColor(.secondary)
                                Text("添加封面")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        )
                        .onTapGesture {
                            onEditThumbnail?()
                        }
                }

                // 编辑按钮
                if onEditThumbnail != nil && thumbnailImage != nil {
                    Button {
                        onEditThumbnail?()
                    } label: {
                        Image(systemName: "pencil.circle.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                            .background(Circle().fill(Color.accentColor))
                    }
                    .padding(8)
                }
            }

            HStack {
                Label(project.date.formatted(date: .long, time: .omitted), systemImage: "calendar")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()

                HStack(spacing: 6) {
                    // 色号体系徽章
                    Text(project.colorSystem.displayName)
                        .font(.caption)
                        .foregroundColor(project.colorSystem == .kaka ? .purple : .blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(project.colorSystem == .kaka ? Color.purple.opacity(0.1) : Color.blue.opacity(0.1))
                        .cornerRadius(6)

                    Label("计划中", systemImage: "clock.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(6)
                }
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
    var colorSystem: ColorSystem = .mard
    @EnvironmentObject var inventoryManager: InventoryManager

    var beadColor: BeadColor? {
        inventoryManager.findColor(byCode: usage.colorCode)
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
                let displayCode = beadColor?.displayCode(for: colorSystem) ?? usage.colorCode
                Text(displayCode)
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

    // 仅本色系的品牌
    var matchingBrands: [Brand] {
        inventoryManager.brands.filter { $0.colorSystem == project.colorSystem }
    }

    // 获取汇总的颜色用量（父项目或普通项目）
    var requiredUsage: [BeadUsage] {
        if isParentProject {
            return inventoryManager.plannedAggregatedBeadUsage(for: project.id)
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
                    if matchingBrands.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.largeTitle)
                                .foregroundColor(.orange)
                            Text("暂无\(project.colorSystem.displayName)体系的品牌")
                                .font(.headline)
                            Text("请先创建品牌以检查库存")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else {
                        // 全部品牌汇总检查
                        AllBrandsStockCheckCard(requiredUsage: requiredUsage, brands: matchingBrands, colorSystem: project.colorSystem)

                        // 分隔线
                        HStack {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.3))
                                .frame(height: 1)
                            Text("各品牌单独库存")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Rectangle()
                                .fill(Color.secondary.opacity(0.3))
                                .frame(height: 1)
                        }
                        .padding(.horizontal)

                        ForEach(matchingBrands) { brand in
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

// MARK: - 全部品牌汇总库存检查卡片
struct AllBrandsStockCheckCard: View {
    let requiredUsage: [BeadUsage]
    let brands: [Brand]
    var colorSystem: ColorSystem = .mard
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var isExpanded = false

    // 计算所有品牌库存总和后仍不足的颜色
    var insufficientColors: [(colorCode: String, required: Int, totalAvailable: Int, shortage: Int)] {
        var result: [(colorCode: String, required: Int, totalAvailable: Int, shortage: Int)] = []

        for usage in requiredUsage {
            // 将色号转换为 mardCode 以正确查询库存
            let mardCode = inventoryManager.findColor(byCode: usage.colorCode)?.mardCode ?? usage.colorCode
            // 计算所有品牌该颜色的库存总和
            var totalAvailable = 0
            for brand in brands {
                if let stock = inventoryManager.getStock(brandId: brand.id, mardCode: mardCode) {
                    totalAvailable += stock.available
                }
            }

            if totalAvailable < usage.quantity {
                result.append((
                    colorCode: usage.colorCode,
                    required: usage.quantity,
                    totalAvailable: totalAvailable,
                    shortage: usage.quantity - totalAvailable
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
            // 标题和状态
            Button {
                withAnimation { isExpanded.toggle() }
            } label: {
                HStack {
                    // 图标和标题
                    Image(systemName: "square.stack.3d.up.fill")
                        .foregroundColor(.purple)
                    Text("全部品牌汇总")
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

            // 说明文字
            Text("综合所有品牌库存后的检查结果")
                .font(.caption)
                .foregroundColor(.secondary)

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
                        AllBrandsInsufficientColorRow(
                            colorCode: item.colorCode,
                            required: item.required,
                            totalAvailable: item.totalAvailable,
                            shortage: item.shortage,
                            colorSystem: colorSystem
                        )
                    }
                }
            }
        }
        .padding()
        .background(isSufficient ? Color.green.opacity(0.08) : Color.red.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSufficient ? Color.green.opacity(0.4) : Color.red.opacity(0.4), lineWidth: 2)
        )
        .cornerRadius(12)
        .padding(.horizontal)
    }
}

// MARK: - 全部品牌汇总不足颜色行
struct AllBrandsInsufficientColorRow: View {
    let colorCode: String  // 内部 mardCode
    let required: Int
    let totalAvailable: Int
    let shortage: Int
    var colorSystem: ColorSystem = .mard
    @EnvironmentObject var inventoryManager: InventoryManager

    var beadColor: BeadColor? {
        inventoryManager.findColor(byCode: colorCode)
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
            Text(beadColor?.displayCode(for: colorSystem) ?? colorCode)
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
                    Text("总计")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(totalAvailable)")
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

// MARK: - 品牌库存检查卡片
struct BrandStockCheckCard: View {
    let brand: Brand
    let requiredUsage: [BeadUsage]
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var isExpanded = false

    // 低库存阈值
    var lowStockThreshold: Int {
        brand.lowStockThreshold
    }

    // 计算库存不足的颜色（扣减后为负数）
    var insufficientColors: [(colorCode: String, required: Int, available: Int, shortage: Int)] {
        var result: [(colorCode: String, required: Int, available: Int, shortage: Int)] = []

        for usage in requiredUsage {
            // 将色号转换为 mardCode 以正确查询库存
            let mardCode = inventoryManager.findColor(byCode: usage.colorCode)?.mardCode ?? usage.colorCode
            if let stock = inventoryManager.getStock(brandId: brand.id, mardCode: mardCode) {
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

    // 计算低库存预警的颜色（扣减后不为负但低于阈值）
    var lowStockColors: [(colorCode: String, required: Int, available: Int, afterDeduct: Int)] {
        var result: [(colorCode: String, required: Int, available: Int, afterDeduct: Int)] = []

        for usage in requiredUsage {
            let mardCode = inventoryManager.findColor(byCode: usage.colorCode)?.mardCode ?? usage.colorCode
            if let stock = inventoryManager.getStock(brandId: brand.id, mardCode: mardCode) {
                let afterDeduct = stock.available - usage.quantity
                // 扣减后不为负（不在 insufficientColors 中），但低于低库存阈值
                if afterDeduct >= 0 && afterDeduct < lowStockThreshold {
                    result.append((
                        colorCode: usage.colorCode,
                        required: usage.quantity,
                        available: stock.available,
                        afterDeduct: afterDeduct
                    ))
                }
            }
        }

        return result.sorted { $0.afterDeduct < $1.afterDeduct }
    }

    var isSufficient: Bool {
        insufficientColors.isEmpty
    }

    var hasLowStock: Bool {
        !lowStockColors.isEmpty
    }

    var totalShortage: Int {
        insufficientColors.reduce(0) { $0 + $1.shortage }
    }

    // 整体状态：绿色（充足）、黄色（有低库存预警）、红色（有不足）
    var statusColor: Color {
        if !isSufficient {
            return .red
        } else if hasLowStock {
            return .orange
        } else {
            return .green
        }
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
                    if !isSufficient {
                        Label("缺少 \(insufficientColors.count) 色", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundColor(.red)
                    } else if hasLowStock {
                        Label("低库存 \(lowStockColors.count) 色", systemImage: "exclamationmark.circle.fill")
                            .font(.subheadline)
                            .foregroundColor(.orange)
                    } else {
                        Label("库存充足", systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundColor(.green)
                    }

                    // 展开指示器（有不足或低库存时显示）
                    if !isSufficient || hasLowStock {
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
                        .foregroundColor(.red)

                    if hasLowStock {
                        Label("低库存 \(lowStockColors.count) 色", systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }

                    Spacer()

                    if !isExpanded {
                        Text("点击展开详情")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } else if hasLowStock {
                HStack {
                    Label("\(lowStockColors.count) 种颜色扣减后低于 \(lowStockThreshold)", systemImage: "exclamationmark.circle")
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
            if isExpanded && (!isSufficient || hasLowStock) {
                Divider()

                VStack(spacing: 8) {
                    // 先显示库存不足的（红色）
                    ForEach(insufficientColors, id: \.colorCode) { item in
                        InsufficientColorRow(
                            colorCode: item.colorCode,
                            required: item.required,
                            available: item.available,
                            shortage: item.shortage,
                            colorSystem: brand.colorSystem
                        )
                    }

                    // 再显示低库存预警的（黄色）
                    ForEach(lowStockColors, id: \.colorCode) { item in
                        LowStockColorRow(
                            colorCode: item.colorCode,
                            required: item.required,
                            available: item.available,
                            afterDeduct: item.afterDeduct,
                            threshold: lowStockThreshold,
                            colorSystem: brand.colorSystem
                        )
                    }
                }
            }
        }
        .padding()
        .background(statusColor.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(statusColor.opacity(0.3), lineWidth: 1)
        )
        .cornerRadius(12)
        .padding(.horizontal)
    }
}

// MARK: - 库存不足颜色行（红色）
struct InsufficientColorRow: View {
    let colorCode: String  // 内部 mardCode
    let required: Int
    let available: Int
    let shortage: Int
    var colorSystem: ColorSystem = .mard
    @EnvironmentObject var inventoryManager: InventoryManager

    var beadColor: BeadColor? {
        inventoryManager.findColor(byCode: colorCode)
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
            Text(beadColor?.displayCode(for: colorSystem) ?? colorCode)
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
        .background(Color.red.opacity(0.05))
        .cornerRadius(6)
    }
}

// MARK: - 低库存预警颜色行（黄色）
struct LowStockColorRow: View {
    let colorCode: String  // 内部 mardCode
    let required: Int
    let available: Int
    let afterDeduct: Int
    let threshold: Int
    var colorSystem: ColorSystem = .mard
    @EnvironmentObject var inventoryManager: InventoryManager

    var beadColor: BeadColor? {
        inventoryManager.findColor(byCode: colorCode)
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
            Text(beadColor?.displayCode(for: colorSystem) ?? colorCode)
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
                        .foregroundColor(.primary)
                }
            }

            // 扣减后剩余
            VStack(alignment: .trailing, spacing: 0) {
                Text("→\(afterDeduct)")
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundColor(.orange)
                Text("<\(threshold)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(width: 50, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.orange.opacity(0.05))
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
                            },
                            colorSystem: project.colorSystem
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
                AddColorToProjectSheet(onAdd: { colorCode, quantity in
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
                }, colorSystem: project.colorSystem)
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
    var colorSystem: ColorSystem = .mard
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var quantityText: String = ""
    @FocusState private var isQuantityFocused: Bool

    var beadColor: BeadColor? {
        inventoryManager.findColor(byCode: usage.colorCode)
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
            Text(beadColor?.displayCode(for: colorSystem) ?? usage.colorCode)
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
                    .keyboardType(.asciiCapableNumberPad)
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
    var colorSystem: ColorSystem = .mard
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var inventoryManager: InventoryManager

    @State private var searchText = ""
    @State private var selectedColorCode: String?
    @State private var quantity: Int = 1
    @State private var quantityText: String = "1"
    @FocusState private var isSearchFocused: Bool

    var filteredColors: [BeadColor] {
        let base = colorSystem == .kaka
            ? inventoryManager.allBeadColors.filter { $0.hasCode(for: .kaka) }
            : inventoryManager.allBeadColors
        if searchText.isEmpty {
            return Array(base.prefix(50))
        }
        let search = searchText.uppercased()
        return base.filter { color in
            color.mardCode.uppercased().contains(search) ||
            color.colorName.uppercased().contains(search) ||
            color.cocoCode.uppercased().contains(search) ||
            color.manmanCode.uppercased().contains(search) ||
            color.displayCode(for: colorSystem).uppercased().contains(search)
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
                   let color = inventoryManager.findColor(byCode: colorCode) {
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
                                Text(color.displayCode(for: colorSystem))
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
                                    .keyboardType(.asciiCapableNumberPad)
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
                                    Text(color.displayCode(for: colorSystem))
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

// MARK: - 多项目库存检查弹窗
struct MultiProjectStockCheckSheet: View {
    let projectIds: [UUID]
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss

    // 获取选中的项目列表
    var selectedProjects: [ProjectRecord] {
        projectIds.compactMap { id in
            inventoryManager.projects.first { $0.id == id }
        }
    }

    // 收集选中项目涉及的色系，过滤匹配品牌
    var involvedColorSystems: Set<ColorSystem> {
        Set(selectedProjects.map { $0.colorSystem })
    }

    var matchingBrands: [Brand] {
        inventoryManager.brands.filter { involvedColorSystems.contains($0.colorSystem) }
    }

    // 汇总所有选中项目的颜色用量
    var aggregatedUsage: [BeadUsage] {
        var usageDict: [String: Int] = [:]

        for project in selectedProjects {
            // 如果是父项目，使用汇总的用量
            let usage: [BeadUsage]
            if inventoryManager.isParentProject(project.id) {
                usage = inventoryManager.plannedAggregatedBeadUsage(for: project.id)
            } else {
                usage = project.beadUsage
            }

            for item in usage {
                usageDict[item.colorCode, default: 0] += item.quantity
            }
        }

        return usageDict.map { BeadUsage(colorCode: $0.key, quantity: $0.value) }
            .sorted { $0.quantity > $1.quantity }
    }

    // 统计信息
    var totalColors: Int {
        aggregatedUsage.count
    }

    var totalBeads: Int {
        aggregatedUsage.reduce(0) { $0 + $1.quantity }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // 选中项目信息
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(.blue)
                            Text("已选 \(selectedProjects.count) 个计划，共 \(totalColors) 色 \(totalBeads) 颗")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Spacer()
                        }

                        // 显示选中的项目名称
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(selectedProjects) { project in
                                    Text(project.name)
                                        .font(.caption)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color.accentColor.opacity(0.1))
                                        .foregroundColor(.accentColor)
                                        .cornerRadius(12)
                                }
                            }
                        }
                    }
                    .padding()
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(10)
                    .padding(.horizontal)

                    // 各品牌库存检查结果
                    if matchingBrands.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.largeTitle)
                                .foregroundColor(.orange)
                            Text("暂无匹配色系的品牌")
                                .font(.headline)
                            Text("请先创建品牌以检查库存")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else {
                        // 全部品牌汇总检查
                        let primaryColorSystem = selectedProjects.first?.colorSystem ?? .mard
                        AllBrandsStockCheckCard(requiredUsage: aggregatedUsage, brands: matchingBrands, colorSystem: primaryColorSystem)

                        // 分隔线
                        HStack {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.3))
                                .frame(height: 1)
                            Text("各品牌单独库存")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Rectangle()
                                .fill(Color.secondary.opacity(0.3))
                                .frame(height: 1)
                        }
                        .padding(.horizontal)

                        ForEach(matchingBrands) { brand in
                            BrandStockCheckCard(
                                brand: brand,
                                requiredUsage: aggregatedUsage
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

// MARK: - 补豆步进单位选项（克）
private let replenishUnitOptions = [5, 10, 20, 50]

// MARK: - 补豆建议弹窗
struct ReplenishSuggestionSheet: View {
    let projectIds: [UUID]
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss
    @State private var selectedBrandId: UUID?
    @State private var showCopySuccess = false
    @State private var showExportSuccess = false
    @State private var freeShippingThreshold: Int = 500  // 包邮额度（克）
    @State private var replenishQuantities: [String: Int] = [:]  // 每个色号的补豆克数
    @State private var selectedColorSystemFilter: ColorSystem = .mard  // 色系筛选
    @State private var unitGrams: Int = 10  // 步进单位克数（+/- 按钮步长，默认10g）

    // 获取选中的项目列表
    var selectedProjects: [ProjectRecord] {
        projectIds.compactMap { id in
            inventoryManager.projects.first { $0.id == id }
        }
    }

    // 选中项目涉及的色系（且有对应品牌的）
    var availableColorSystems: [ColorSystem] {
        let projectSystems = Set(selectedProjects.map { $0.colorSystem })
        let brandSystems = Set(inventoryManager.brands.map { $0.colorSystem })
        return ColorSystem.allCases.filter { projectSystems.contains($0) && brandSystems.contains($0) }
    }

    // 根据选中的色系筛选品牌
    var matchingBrands: [Brand] {
        inventoryManager.brands.filter { $0.colorSystem == selectedColorSystemFilter }
    }

    // 汇总所有选中项目的颜色用量
    var aggregatedUsage: [String: Int] {
        var usageDict: [String: Int] = [:]
        for project in selectedProjects {
            let usage: [BeadUsage]
            if inventoryManager.isParentProject(project.id) {
                usage = inventoryManager.plannedAggregatedBeadUsage(for: project.id)
            } else {
                usage = project.beadUsage
            }
            for item in usage {
                usageDict[item.colorCode, default: 0] += item.quantity
            }
        }
        return usageDict
    }

    // 选中品牌
    var selectedBrand: Brand? {
        guard let id = selectedBrandId else { return nil }
        return inventoryManager.brands.first { $0.id == id }
    }

    // 选中品牌的色号体系
    var selectedColorSystem: ColorSystem {
        selectedBrand?.colorSystem ?? .mard
    }

    // 低库存阈值
    var lowStockThreshold: Int {
        selectedBrand?.lowStockThreshold ?? 100
    }

    // 将内部 mardCode 转换为当前品牌的显示色号
    func displayCode(for mardCode: String) -> String {
        inventoryManager.findColor(byCode: mardCode)?.displayCode(for: selectedColorSystem) ?? mardCode
    }

    // 获取某个色号在选中品牌的运输中数量
    func inTransitQuantity(for colorCode: String, brandId: UUID) -> Int {
        var total = 0
        for record in inventoryManager.purchaseRecords {
            if record.brandId == brandId {
                for item in record.items {
                    if item.colorCode == colorCode {
                        total += item.quantity
                    }
                }
            }
        }
        return total
    }

    // 计算补豆建议数据
    var replenishData: ReplenishData {
        guard let brand = selectedBrand, unitGrams > 0 else {
            return ReplenishData(negativeStock: [], lowStock: [], highUsage: [], processedCodes: [])
        }

        var negativeStock: [ReplenishColorInfo] = []
        var lowStock: [ReplenishColorInfo] = []
        var processedCodes: Set<String> = []

        for (colorCode, usage) in aggregatedUsage {
            // 将色号转换为 mardCode（BeadUsage 中可能存储了非 MARD 色号）
            let resolvedColor = inventoryManager.findColor(byCode: colorCode)
            let mardCode = resolvedColor?.mardCode ?? colorCode

            // 跳过在当前品牌色系中没有对应编码的颜色
            if let resolvedColor, !resolvedColor.hasCode(for: brand.colorSystem) {
                continue
            }

            let currentStock = inventoryManager.getStock(brandId: brand.id, mardCode: mardCode)?.available ?? 0
            let inTransit = inTransitQuantity(for: mardCode, brandId: brand.id)
            let effectiveStock = currentStock + inTransit
            let afterDeduct = effectiveStock - usage

            if afterDeduct < 0 {
                let deficit = lowStockThreshold - afterDeduct
                let deficitGrams = (deficit + 99) / 100
                let defaultAmount = ((deficitGrams + unitGrams - 1) / unitGrams) * unitGrams
                negativeStock.append(ReplenishColorInfo(
                    colorCode: mardCode,
                    currentStock: currentStock,
                    inTransit: inTransit,
                    usage: usage,
                    afterDeduct: afterDeduct,
                    defaultAmount: defaultAmount
                ))
                processedCodes.insert(mardCode)
            } else if afterDeduct < lowStockThreshold {
                let deficit = lowStockThreshold - afterDeduct
                let deficitGrams = (deficit + 99) / 100
                let defaultAmount = ((deficitGrams + unitGrams - 1) / unitGrams) * unitGrams
                lowStock.append(ReplenishColorInfo(
                    colorCode: mardCode,
                    currentStock: currentStock,
                    inTransit: inTransit,
                    usage: usage,
                    afterDeduct: afterDeduct,
                    defaultAmount: defaultAmount
                ))
                processedCodes.insert(mardCode)
            }
        }

        negativeStock.sort { $0.afterDeduct < $1.afterDeduct }
        lowStock.sort { $0.afterDeduct < $1.afterDeduct }

        return ReplenishData(
            negativeStock: negativeStock,
            lowStock: lowStock,
            highUsage: highUsageColors,
            processedCodes: processedCodes
        )
    }

    // 基于全部历史用量 + 选中计划用量计算用量较大的色号（过滤仅保留当前品牌色系可用的色号）
    var highUsageColors: [HighUsageColorInfo] {
        var totalUsageDict: [String: Int] = [:]
        for project in inventoryManager.projects {
            guard !project.isPlanned else { continue }
            for usage in project.beadUsage {
                // 统一转换为 mardCode
                let mardCode = inventoryManager.findColor(byCode: usage.colorCode)?.mardCode ?? usage.colorCode
                totalUsageDict[mardCode, default: 0] += usage.quantity
            }
        }
        for (colorCode, quantity) in aggregatedUsage {
            let mardCode = inventoryManager.findColor(byCode: colorCode)?.mardCode ?? colorCode
            totalUsageDict[mardCode, default: 0] += quantity
        }
        // 过滤：仅保留在当前品牌色系中有对应编码的颜色
        let cs = selectedColorSystem
        let filtered = totalUsageDict.filter { (mardCode, _) in
            guard let color = inventoryManager.findColor(byCode: mardCode) else { return true }
            return color.hasCode(for: cs)
        }
        let sortedUsage = filtered.sorted { $0.value > $1.value }
        return sortedUsage.prefix(20).map { HighUsageColorInfo(colorCode: $0.key, totalUsage: $0.value) }
    }

    // 已选补豆总量（以克计）
    var totalSelectedQuantity: Int {
        replenishQuantities.values.reduce(0, +)
    }

    // 还差多少包邮（以克计）
    var remainingForFreeShipping: Int {
        max(0, freeShippingThreshold - totalSelectedQuantity)
    }

    // 生成 CSV 文本（quantity 已为克数），使用品牌色号体系的显示色号
    var csvText: String {
        var lines: [String] = ["色号,克数"]
        for (mardCode, quantity) in replenishQuantities.sorted(by: { $0.key < $1.key }) {
            if quantity > 0 {
                let code = displayCode(for: mardCode)
                lines.append("\(code),\(quantity)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // 初始化默认补豆数量
    func initializeDefaultQuantities() {
        var quantities: [String: Int] = [:]
        for item in replenishData.negativeStock {
            quantities[item.colorCode] = item.defaultAmount
        }
        for item in replenishData.lowStock {
            quantities[item.colorCode] = item.defaultAmount
        }
        for item in replenishData.highUsage {
            if quantities[item.colorCode] == nil {
                quantities[item.colorCode] = 0
            }
        }
        replenishQuantities = quantities
    }

    // 导出到运输中
    func exportToShipping() {
        guard let brandId = selectedBrandId else { return }

        // 生成默认名称
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日补豆"
        let recordName = formatter.string(from: Date())

        // 构建购买项列表（quantity 已为克数，1g = 100 颗）
        var items: [PurchaseItem] = []
        for (colorCode, quantity) in replenishQuantities.sorted(by: { $0.key < $1.key }) {
            if quantity > 0 {
                items.append(PurchaseItem(colorCode: colorCode, quantity: quantity * 100))
            }
        }

        guard !items.isEmpty else { return }

        // 添加到运输中
        inventoryManager.addPurchaseRecord(
            name: recordName,
            brandId: brandId,
            items: items,
            note: "从补豆建议导出"
        )

        // 显示成功提示
        showExportSuccess = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showExportSuccess = false
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // 色系 & 品牌选择
                    VStack(alignment: .leading, spacing: 12) {
                        // 色系切换器
                        if availableColorSystems.count > 1 {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("色号体系")
                                    .font(.headline)
                                Picker("色号体系", selection: $selectedColorSystemFilter) {
                                    ForEach(availableColorSystems, id: \.self) { system in
                                        Text(system.displayName).tag(system)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .onChange(of: selectedColorSystemFilter) { _, _ in
                                    // 切换色系时，自动选中该色系的第一个品牌
                                    if let firstBrand = matchingBrands.first {
                                        selectedBrandId = firstBrand.id
                                    } else {
                                        selectedBrandId = nil
                                    }
                                    initializeDefaultQuantities()
                                }
                            }
                        }

                        // 品牌选择
                        Text("选择品牌")
                            .font(.headline)
                        if matchingBrands.isEmpty {
                            Text("暂无该色系的品牌，请先创建品牌")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(matchingBrands) { brand in
                                        Button {
                                            selectedBrandId = brand.id
                                            initializeDefaultQuantities()
                                        } label: {
                                            Text(brand.name)
                                                .font(.subheadline)
                                                .padding(.horizontal, 16)
                                                .padding(.vertical, 10)
                                                .background(selectedBrandId == brand.id ? Color.accentColor : Color.gray.opacity(0.2))
                                                .foregroundColor(selectedBrandId == brand.id ? .white : .primary)
                                                .cornerRadius(20)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal)

                    if selectedBrand != nil {
                        // 步进单位 & 包邮额度
                        VStack(spacing: 12) {
                            // 步进单位选择（控制 +/- 按钮步长）
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("步进单位")
                                        .font(.subheadline)
                                    Text("+/- 按钮每次增减的克数")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Picker("步进单位", selection: $unitGrams) {
                                    ForEach(replenishUnitOptions, id: \.self) { g in
                                        Text("\(g)g").tag(g)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 200)
                                .onChange(of: unitGrams) { _, _ in
                                    initializeDefaultQuantities()
                                }
                            }

                            Divider()

                            // 包邮额度输入（克）
                            HStack {
                                Text("包邮额度")
                                    .font(.subheadline)
                                Spacer()
                                HStack(spacing: 4) {
                                    TextField("", value: $freeShippingThreshold, format: .number)
                                        .keyboardType(.asciiCapableNumberPad)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 70)
                                        .multilineTextAlignment(.center)
                                        .onChange(of: freeShippingThreshold) { _, newValue in
                                            if newValue < 0 { freeShippingThreshold = 0 }
                                        }
                                    Text("g")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding()
                        .background(Color(.systemBackground))
                        .cornerRadius(12)
                        .padding(.horizontal)

                        // 状态栏
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("已选补豆")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("\(totalSelectedQuantity)g")
                                    .font(.headline)
                                    .foregroundColor(.accentColor)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("还差包邮")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(remainingForFreeShipping > 0 ? "\(remainingForFreeShipping)g" : "已达标 ✓")
                                    .font(.headline)
                                    .foregroundColor(remainingForFreeShipping > 0 ? .orange : .green)
                            }
                        }
                        .padding()
                        .background(remainingForFreeShipping > 0 ? Color.orange.opacity(0.1) : Color.green.opacity(0.1))
                        .cornerRadius(12)
                        .padding(.horizontal)

                        // 选中项目信息
                        HStack {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(.blue)
                            Text("已选 \(selectedProjects.count) 个计划，低库存阈值: \(lowStockThreshold)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding()
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(10)
                        .padding(.horizontal)

                        // 负库存区域
                        if !replenishData.negativeStock.isEmpty {
                            ReplenishSectionView(
                                title: "库存不足（需补豆）",
                                subtitle: "扣减后库存为负",
                                color: .red,
                                items: replenishData.negativeStock,
                                processedCodes: replenishData.processedCodes,
                                quantities: $replenishQuantities,
                                showWarning: false,
                                colorSystem: selectedColorSystem,
                                unitGrams: unitGrams
                            )
                        }

                        // 低库存区域
                        if !replenishData.lowStock.isEmpty {
                            ReplenishSectionView(
                                title: "低库存预警（建议补豆）",
                                subtitle: "扣减后库存低于\(lowStockThreshold)",
                                color: .orange,
                                items: replenishData.lowStock,
                                processedCodes: replenishData.processedCodes,
                                quantities: $replenishQuantities,
                                showWarning: false,
                                colorSystem: selectedColorSystem,
                                unitGrams: unitGrams
                            )
                        }

                        // 用量大区域
                        if !replenishData.highUsage.isEmpty {
                            HighUsageSectionView(
                                title: "用量较大（供参考）",
                                subtitle: "历史用量+选中计划，排名前20",
                                items: replenishData.highUsage,
                                processedCodes: replenishData.processedCodes,
                                quantities: $replenishQuantities,
                                colorSystem: selectedColorSystem,
                                unitGrams: unitGrams
                            )
                        }

                        // 空状态
                        if replenishData.negativeStock.isEmpty &&
                           replenishData.lowStock.isEmpty &&
                           replenishData.highUsage.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.largeTitle)
                                    .foregroundColor(.green)
                                Text("无需补豆")
                                    .font(.headline)
                                Text("所选计划未使用任何颜色")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                        }

                        // 操作按钮
                        if totalSelectedQuantity > 0 {
                            VStack(spacing: 12) {
                                // 导出到运输中
                                Button {
                                    exportToShipping()
                                } label: {
                                    HStack {
                                        Image(systemName: showExportSuccess ? "checkmark" : "shippingbox.fill")
                                        Text(showExportSuccess ? "已添加到运输中" : "导出到运输中（\(totalSelectedQuantity)g）")
                                    }
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .padding()
                                    .frame(maxWidth: .infinity)
                                    .background(showExportSuccess ? Color.green : Color.orange)
                                    .cornerRadius(12)
                                }

                                // 复制补豆计划
                                Button {
                                    UIPasteboard.general.string = csvText
                                    showCopySuccess = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                        showCopySuccess = false
                                    }
                                } label: {
                                    HStack {
                                        Image(systemName: showCopySuccess ? "checkmark" : "doc.on.doc")
                                        Text(showCopySuccess ? "已复制" : "复制补豆计划")
                                    }
                                    .font(.subheadline)
                                    .foregroundColor(.accentColor)
                                }
                            }
                            .padding(.horizontal)
                            .padding(.top, 8)
                        }
                    } else if !inventoryManager.brands.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "hand.tap")
                                .font(.largeTitle)
                                .foregroundColor(.secondary)
                            Text("请先选择品牌")
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                    }
                }
                .padding(.vertical)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("补豆建议")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .onAppear {
            // 默认色系：优先使用选中项目的色系，其次使用当前品牌的色系
            let projectSystems = Set(selectedProjects.map { $0.colorSystem })
            if let currentSystem = inventoryManager.currentBrand?.colorSystem, projectSystems.contains(currentSystem) {
                selectedColorSystemFilter = currentSystem
            } else if let firstSystem = projectSystems.first {
                selectedColorSystemFilter = firstSystem
            }
            // 自动选中第一个匹配品牌
            if selectedBrandId == nil, let firstBrand = matchingBrands.first {
                selectedBrandId = firstBrand.id
            }
            initializeDefaultQuantities()
        }
    }
}

// MARK: - 直接补豆弹窗（不比对库存，直接汇总计划用量）
struct DirectPurchaseSheet: View {
    let projectIds: [UUID]
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss
    @State private var showCopySuccess = false
    @State private var hasExported = false  // 防止重复导出
    @State private var showEmptyExportWarning = false  // 空导出提示
    @State private var selectedBrandId: UUID?
    @State private var selectedColorSystemFilter: ColorSystem = .mard
    @State private var purchaseQuantities: [String: Int] = [:]  // mardCode -> 补豆克数
    @State private var freeShippingThreshold: Int = 500  // 包邮额度（克）
    @State private var unitGrams: Int = 10  // 步进单位克数（+/- 按钮步长，默认10g）

    // 获取选中的项目列表
    var selectedProjects: [ProjectRecord] {
        projectIds.compactMap { id in
            inventoryManager.projects.first { $0.id == id }
        }
    }

    // 选中项目涉及的色系（且有对应品牌的）
    var availableColorSystems: [ColorSystem] {
        let projectSystems = Set(selectedProjects.map { $0.colorSystem })
        let brandSystems = Set(inventoryManager.brands.map { $0.colorSystem })
        return ColorSystem.allCases.filter { projectSystems.contains($0) && brandSystems.contains($0) }
    }

    // 根据选中的色系筛选品牌
    var matchingBrands: [Brand] {
        inventoryManager.brands.filter { $0.colorSystem == selectedColorSystemFilter }
    }

    // 选中品牌
    var selectedBrand: Brand? {
        guard let id = selectedBrandId else { return nil }
        return inventoryManager.brands.first { $0.id == id }
    }

    // 选中品牌的色号体系
    var selectedColorSystem: ColorSystem {
        selectedBrand?.colorSystem ?? selectedColorSystemFilter
    }

    // 汇总所有选中项目的颜色用量（不比对库存）
    var aggregatedUsage: [(mardCode: String, quantity: Int)] {
        var usageDict: [String: Int] = [:]
        for project in selectedProjects {
            let usage: [BeadUsage]
            if inventoryManager.isParentProject(project.id) {
                usage = inventoryManager.plannedAggregatedBeadUsage(for: project.id)
            } else {
                usage = project.beadUsage
            }
            for item in usage {
                let resolvedColor = inventoryManager.findColor(byCode: item.colorCode)
                let mardCode = resolvedColor?.mardCode ?? item.colorCode
                usageDict[mardCode, default: 0] += item.quantity
            }
        }
        // 按用量从大到小排序
        return usageDict.map { (mardCode: $0.key, quantity: $0.value) }
            .sorted { $0.quantity > $1.quantity }
    }

    // 过滤后的用量（仅保留当前品牌色系可用的色号，未识别色号排除）
    var filteredUsage: [(mardCode: String, quantity: Int)] {
        guard selectedBrand != nil else { return aggregatedUsage }
        let cs = selectedColorSystem
        return aggregatedUsage.filter { item in
            guard let color = inventoryManager.findColor(byCode: item.mardCode) else { return false }
            return color.hasCode(for: cs)
        }
    }

    // 将内部 mardCode 转换为当前品牌的显示色号
    func displayCode(for mardCode: String) -> String {
        inventoryManager.findColor(byCode: mardCode)?.displayCode(for: selectedColorSystem) ?? mardCode
    }

    // 总颜色数
    var totalColors: Int {
        filteredUsage.count
    }

    // 总颗数
    var totalBeads: Int {
        filteredUsage.reduce(0) { $0 + $1.quantity }
    }

    // 已选补豆总量（以克计）
    var totalSelectedQuantity: Int {
        purchaseQuantities.values.reduce(0, +)
    }

    // 还差多少包邮（以克计）
    var remainingForFreeShipping: Int {
        max(0, freeShippingThreshold - totalSelectedQuantity)
    }

    // 初始化默认补豆克数（每个色号按用量换算为克，对齐到步进单位）
    func initializeDefaultQuantities() {
        guard unitGrams > 0 else { return }
        var quantities: [String: Int] = [:]
        for item in filteredUsage {
            let rawGrams = (item.quantity + 99) / 100
            let roundedGrams = ((rawGrams + unitGrams - 1) / unitGrams) * unitGrams
            quantities[item.mardCode] = max(unitGrams, roundedGrams)
        }
        purchaseQuantities = quantities
    }

    // 按 filteredUsage 排序的有效购买项（与 UI 排序一致）
    var orderedPurchaseItems: [(mardCode: String, quantity: Int)] {
        filteredUsage.compactMap { item in
            let qty = purchaseQuantities[item.mardCode] ?? 0
            return qty > 0 ? (mardCode: item.mardCode, quantity: qty) : nil
        }
    }

    // 生成 CSV 文本（quantity 已为克数），按 UI 排序，使用品牌色号体系的显示色号
    var csvText: String {
        var lines: [String] = ["色号,克数"]
        for item in orderedPurchaseItems {
            let code = displayCode(for: item.mardCode)
            lines.append("\(code),\(item.quantity)")
        }
        return lines.joined(separator: "\n")
    }

    // 导出到运输中
    func exportToShipping() {
        guard let brandId = selectedBrandId else { return }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日补豆"
        let recordName = formatter.string(from: Date())

        // 仅导出当前品牌色系有效的色号，按 UI 排序（quantity 已为克数，1g = 100 颗）
        let items: [PurchaseItem] = orderedPurchaseItems.map { item in
            PurchaseItem(colorCode: item.mardCode, quantity: item.quantity * 100)
        }

        guard !items.isEmpty else {
            showEmptyExportWarning = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                showEmptyExportWarning = false
            }
            return
        }

        inventoryManager.addPurchaseRecord(
            name: recordName,
            brandId: brandId,
            items: items,
            note: "从直接补豆导出"
        )

        hasExported = true
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // 说明信息
                    HStack {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.green)
                        Text("已选 \(selectedProjects.count) 个计划，共 \(totalColors) 色 \(totalBeads) 颗")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(10)
                    .padding(.horizontal)

                    // 色系 & 品牌选择
                    VStack(alignment: .leading, spacing: 12) {
                        if availableColorSystems.count > 1 {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("色号体系")
                                    .font(.headline)
                                Picker("色号体系", selection: $selectedColorSystemFilter) {
                                    ForEach(availableColorSystems, id: \.self) { system in
                                        Text(system.displayName).tag(system)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .onChange(of: selectedColorSystemFilter) { _, _ in
                                    if let firstBrand = matchingBrands.first {
                                        selectedBrandId = firstBrand.id
                                    } else {
                                        selectedBrandId = nil
                                    }
                                    hasExported = false
                                    initializeDefaultQuantities()
                                }
                            }
                        }

                        Text("选择品牌")
                            .font(.headline)
                        if matchingBrands.isEmpty {
                            Text("暂无该色系的品牌，请先创建品牌")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(matchingBrands) { brand in
                                        Button {
                                            selectedBrandId = brand.id
                                            hasExported = false
                                            initializeDefaultQuantities()
                                        } label: {
                                            Text(brand.name)
                                                .font(.subheadline)
                                                .padding(.horizontal, 16)
                                                .padding(.vertical, 10)
                                                .background(selectedBrandId == brand.id ? Color.green : Color.gray.opacity(0.2))
                                                .foregroundColor(selectedBrandId == brand.id ? .white : .primary)
                                                .cornerRadius(20)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal)

                    if selectedBrand != nil {
                        // 步进单位 & 包邮额度
                        VStack(spacing: 12) {
                            // 步进单位选择（控制 +/- 按钮步长）
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("步进单位")
                                        .font(.subheadline)
                                    Text("+/- 按钮每次增减的克数")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Picker("步进单位", selection: $unitGrams) {
                                    ForEach(replenishUnitOptions, id: \.self) { g in
                                        Text("\(g)g").tag(g)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 200)
                                .onChange(of: unitGrams) { _, _ in
                                    initializeDefaultQuantities()
                                }
                            }

                            Divider()

                            // 包邮额度（克）
                            HStack {
                                Text("包邮额度")
                                    .font(.subheadline)
                                Spacer()
                                HStack(spacing: 4) {
                                    TextField("", value: $freeShippingThreshold, format: .number)
                                        .keyboardType(.asciiCapableNumberPad)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 70)
                                        .multilineTextAlignment(.center)
                                        .onChange(of: freeShippingThreshold) { _, newValue in
                                            if newValue < 0 { freeShippingThreshold = 0 }
                                        }
                                    Text("g")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding()
                        .background(Color(.systemBackground))
                        .cornerRadius(12)
                        .padding(.horizontal)

                        // 状态栏
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("已选补豆")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("\(totalSelectedQuantity)g")
                                    .font(.headline)
                                    .foregroundColor(.green)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("还差包邮")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(remainingForFreeShipping > 0 ? "\(remainingForFreeShipping)g" : "已达标 ✓")
                                    .font(.headline)
                                    .foregroundColor(remainingForFreeShipping > 0 ? .orange : .green)
                            }
                        }
                        .padding()
                        .background(remainingForFreeShipping > 0 ? Color.orange.opacity(0.1) : Color.green.opacity(0.1))
                        .cornerRadius(12)
                        .padding(.horizontal)

                        // 用量列表
                        if filteredUsage.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "tray")
                                    .font(.largeTitle)
                                    .foregroundColor(.secondary)
                                Text("无可用色号")
                                    .font(.headline)
                                Text("所选计划未使用该色系的颜色")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    HStack {
                                        Circle().fill(Color.green).frame(width: 10, height: 10)
                                        Text("计划用量汇总")
                                            .font(.headline)
                                    }
                                    Spacer()
                                    Text("\(filteredUsage.count) 色")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }

                                Divider()

                                ForEach(filteredUsage, id: \.mardCode) { item in
                                    DirectPurchaseColorRow(
                                        colorCode: item.mardCode,
                                        neededQuantity: item.quantity,
                                        quantity: Binding(
                                            get: { purchaseQuantities[item.mardCode] ?? 0 },
                                            set: { purchaseQuantities[item.mardCode] = $0 }
                                        ),
                                        colorSystem: selectedColorSystem,
                                        unitGrams: unitGrams
                                    )
                                }
                            }
                            .padding()
                            .background(Color.green.opacity(0.05))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.green.opacity(0.3), lineWidth: 1))
                            .cornerRadius(12)
                            .padding(.horizontal)
                        }

                        // 空导出提示
                        if showEmptyExportWarning {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("所有色号补豆数量为 0，无法导出")
                                    .font(.subheadline)
                                    .foregroundColor(.orange)
                            }
                            .padding()
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(10)
                            .padding(.horizontal)
                        }

                        // 操作按钮
                        VStack(spacing: 12) {
                            Button {
                                exportToShipping()
                            } label: {
                                HStack {
                                    Image(systemName: hasExported ? "checkmark" : "shippingbox.fill")
                                    Text(hasExported ? "已添加到运输中" : "导出到运输中（\(totalSelectedQuantity)g）")
                                }
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding()
                                .frame(maxWidth: .infinity)
                                .background(hasExported ? Color.green : Color.green.opacity(0.8))
                                .cornerRadius(12)
                            }
                            .disabled(hasExported)

                            Button {
                                UIPasteboard.general.string = csvText
                                showCopySuccess = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    showCopySuccess = false
                                }
                            } label: {
                                HStack {
                                    Image(systemName: showCopySuccess ? "checkmark" : "doc.on.doc")
                                    Text(showCopySuccess ? "已复制" : "复制补豆计划")
                                }
                                .font(.subheadline)
                                .foregroundColor(.green)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                    } else if !inventoryManager.brands.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "hand.tap")
                                .font(.largeTitle)
                                .foregroundColor(.secondary)
                            Text("请先选择品牌")
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                    }
                }
                .padding(.vertical)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("直接补豆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .onAppear {
            let projectSystems = Set(selectedProjects.map { $0.colorSystem })
            if let currentSystem = inventoryManager.currentBrand?.colorSystem, projectSystems.contains(currentSystem) {
                selectedColorSystemFilter = currentSystem
            } else if let firstSystem = projectSystems.first {
                selectedColorSystemFilter = firstSystem
            }
            if selectedBrandId == nil, let firstBrand = matchingBrands.first {
                selectedBrandId = firstBrand.id
            }
            initializeDefaultQuantities()
        }
    }
}

// MARK: - 直接补豆色号行
struct DirectPurchaseColorRow: View {
    let colorCode: String  // 内部 mardCode
    let neededQuantity: Int  // 计划需要的颗数
    @Binding var quantity: Int  // 补豆数量（以克计）
    var colorSystem: ColorSystem = .mard
    var unitGrams: Int = 10
    @EnvironmentObject var inventoryManager: InventoryManager

    var beadColor: BeadColor? {
        inventoryManager.findColor(byCode: colorCode)
    }

    var displayColor: Color {
        beadColor?.color ?? .gray
    }

    var displayCodeText: String {
        beadColor?.displayCode(for: colorSystem) ?? colorCode
    }

    var body: some View {
        HStack(spacing: 8) {
            // 颜色预览
            RoundedRectangle(cornerRadius: 4)
                .fill(displayColor)
                .frame(width: 28, height: 28)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3), lineWidth: 1))

            // 色号 + 需要颗数
            VStack(alignment: .leading, spacing: 2) {
                Text(displayCodeText)
                    .font(.system(.subheadline, design: .monospaced))
                    .fontWeight(.medium)
                Text("需 \(neededQuantity) 颗")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // 数量调节器
            HStack(spacing: 4) {
                Button {
                    quantity = max(0, quantity - unitGrams)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                        .foregroundColor(quantity > 0 ? .green : .gray)
                }
                .disabled(quantity <= 0)

                TextField("", value: $quantity, format: .number)
                    .keyboardType(.asciiCapableNumberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 50)
                    .multilineTextAlignment(.center)
                    .font(.subheadline.monospacedDigit())
                    .onChange(of: quantity) { _, newValue in
                        if newValue < 0 { quantity = 0 }
                    }

                Text("g")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button {
                    quantity += unitGrams
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundColor(.green)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color(.systemBackground))
        .cornerRadius(8)
    }
}

// MARK: - 补豆数据
struct ReplenishData {
    let negativeStock: [ReplenishColorInfo]
    let lowStock: [ReplenishColorInfo]
    let highUsage: [HighUsageColorInfo]
    let processedCodes: Set<String>
}

struct ReplenishColorInfo {
    let colorCode: String
    let currentStock: Int
    let inTransit: Int
    let usage: Int
    let afterDeduct: Int
    let defaultAmount: Int  // 以克计
}

struct HighUsageColorInfo {
    let colorCode: String
    let totalUsage: Int
}

// MARK: - 补豆建议区域视图（负库存/低库存）
struct ReplenishSectionView: View {
    let title: String
    let subtitle: String
    let color: Color
    let items: [ReplenishColorInfo]
    let processedCodes: Set<String>
    @Binding var quantities: [String: Int]
    let showWarning: Bool
    var colorSystem: ColorSystem = .mard
    var unitGrams: Int = 10
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation { isExpanded.toggle() }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Circle().fill(color).frame(width: 10, height: 10)
                            Text(title).font(.headline).foregroundColor(.primary)
                        }
                        Text(subtitle).font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Text("\(items.count) 色").font(.subheadline).foregroundColor(.secondary)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                ForEach(items, id: \.colorCode) { item in
                    ReplenishColorRow(
                        colorCode: item.colorCode,
                        detail: item.afterDeduct < 0 ? "缺 \(abs(item.afterDeduct)) 颗" : "余 \(item.afterDeduct) 颗",
                        color: color,
                        quantity: Binding(
                            get: { quantities[item.colorCode] ?? 0 },
                            set: { quantities[item.colorCode] = $0 }
                        ),
                        showWarning: false,
                        colorSystem: colorSystem,
                        unitGrams: unitGrams
                    )
                }
            }
        }
        .padding()
        .background(color.opacity(0.05))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.3), lineWidth: 1))
        .cornerRadius(12)
        .padding(.horizontal)
    }
}

// MARK: - 用量较大区域视图
struct HighUsageSectionView: View {
    let title: String
    let subtitle: String
    let items: [HighUsageColorInfo]
    let processedCodes: Set<String>
    @Binding var quantities: [String: Int]
    var colorSystem: ColorSystem = .mard
    var unitGrams: Int = 10
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation { isExpanded.toggle() }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Circle().fill(Color.green).frame(width: 10, height: 10)
                            Text(title).font(.headline).foregroundColor(.primary)
                        }
                        Text(subtitle).font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Text("\(items.count) 色").font(.subheadline).foregroundColor(.secondary)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                ForEach(items, id: \.colorCode) { item in
                    let isAlreadyListed = processedCodes.contains(item.colorCode)
                    ReplenishColorRow(
                        colorCode: item.colorCode,
                        detail: "总用量 \(item.totalUsage)",
                        color: .green,
                        quantity: Binding(
                            get: { quantities[item.colorCode] ?? 0 },
                            set: { quantities[item.colorCode] = $0 }
                        ),
                        showWarning: isAlreadyListed,
                        colorSystem: colorSystem,
                        unitGrams: unitGrams
                    )
                }
            }
        }
        .padding()
        .background(Color.green.opacity(0.05))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.green.opacity(0.3), lineWidth: 1))
        .cornerRadius(12)
        .padding(.horizontal)
    }
}

// MARK: - 补豆色号行
struct ReplenishColorRow: View {
    let colorCode: String  // 内部 mardCode
    let detail: String
    let color: Color
    @Binding var quantity: Int
    let showWarning: Bool
    var colorSystem: ColorSystem = .mard
    var unitGrams: Int = 10
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var showWarningTip = false

    var beadColor: BeadColor? {
        inventoryManager.findColor(byCode: colorCode)
    }

    var displayColor: Color {
        beadColor?.color ?? .gray
    }

    /// 根据品牌色号体系显示对应的色号
    var displayCodeText: String {
        beadColor?.displayCode(for: colorSystem) ?? colorCode
    }

    var body: some View {
        HStack(spacing: 8) {
            // 颜色预览
            RoundedRectangle(cornerRadius: 4)
                .fill(displayColor)
                .frame(width: 28, height: 28)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3), lineWidth: 1))

            // 色号
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(displayCodeText)
                        .font(.system(.subheadline, design: .monospaced))
                        .fontWeight(.medium)
                    if showWarning {
                        Button {
                            showWarningTip = true
                        } label: {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                        .popover(isPresented: $showWarningTip) {
                            Text("此色号已在上方「库存不足」或「低库存预警」中列出，已有建议补豆量")
                                .font(.subheadline)
                                .frame(width: 200)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding()
                                .presentationCompactAdaptation(.popover)
                        }
                    }
                }
                Text(detail)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // 数量调节器
            HStack(spacing: 4) {
                Button {
                    quantity = max(0, quantity - unitGrams)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                        .foregroundColor(quantity > 0 ? color : .gray)
                }
                .disabled(quantity <= 0)

                TextField("", value: $quantity, format: .number)
                    .keyboardType(.asciiCapableNumberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 50)
                    .multilineTextAlignment(.center)
                    .font(.subheadline.monospacedDigit())
                    .onChange(of: quantity) { _, newValue in
                        if newValue < 0 { quantity = 0 }
                    }

                Text("g")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button {
                    quantity += unitGrams
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundColor(color)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color(.systemBackground))
        .cornerRadius(8)
    }
}

#Preview {
    PlannedProjectsView()
        .environmentObject(InventoryManager())
}
