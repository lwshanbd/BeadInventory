//
//  InventoryView.swift
//  BeadInventory
//
//  库存管理主界面
//

import SwiftUI
import TipKit

struct LowStockSheetItem: Identifiable {
    let id: UUID
    let brandId: UUID

    init(brandId: UUID) {
        self.id = brandId
        self.brandId = brandId
    }
}

struct InventoryView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.tabFlavor) private var flavor
    @State private var searchText = ""
    @State private var selectedColor: BeadColor?
    @State private var showingBrandSettings = false
    @State private var lowStockDetailItem: LowStockSheetItem?
    @State private var sortOption: SortOption = .code
    @State private var sortAscending: Bool = true
    @AppStorage("inventoryViewMode") private var viewMode: ViewMode = .list
    @AppStorage("inventoryGroupByPrefix") private var groupByPrefix: Bool = false
    @State private var collapsedGroups: Set<String> = []
    @StateObject private var sel = SelectionContext<UUID>()
    @State private var showBatchHideAlert = false
    @State private var lastSuccessAt: Date = .distantPast

    enum ViewMode: String {
        case list = "list"
        case grid = "grid"
    }

    enum SortOption: String, CaseIterable {
        case code = "色号"
        case stock = "库存"
        case used = "已用"
        case name = "名称"

        var localizedName: String {
            switch self {
            case .code: return String(localized: "色号")
            case .stock: return String(localized: "库存")
            case .used: return String(localized: "已用")
            case .name: return String(localized: "名称")
            }
        }
    }

    // 当前品牌的可见库存快照。
    // 在 body 顶部构造一次后通过 let 共享给所有派生数据（filtered / grouped / cells / 各 ForEach）。
    // 不要改成 computed property —— ForEach 每行访问会重新执行整段构造，
    // 在 brandStocks 较大时阻塞主线程。
    //
    // 也不要把实例存进 @State 跨帧复用：snapshot 是 per-body-frame 的只读视图。
    fileprivate struct InventorySnapshot {
        let brandId: UUID?
        let lowStockThreshold: Int
        let stockDict: [String: BrandStock]   // 仅未隐藏的色号
        let totalAvailable: Int
        let totalUsed: Int
        let lowStockCount: Int
        let totalColorCount: Int              // 含隐藏（用于 hero "x/y 色"）

        /// 已记录（未隐藏）色号数 —— 由 stockDict 派生以保证不变量永远成立。
        var recordedColorCount: Int { stockDict.count }

        init(brandStocks: [BrandStock], brandId: UUID?, lowStockThreshold: Int) {
            self.brandId = brandId
            self.lowStockThreshold = lowStockThreshold
            guard let brandId = brandId else {
                self.stockDict = [:]
                self.totalAvailable = 0
                self.totalUsed = 0
                self.lowStockCount = 0
                self.totalColorCount = 0
                return
            }
            var dict: [String: BrandStock] = [:]
            var totalAvailable = 0
            var totalUsed = 0
            var lowCount = 0
            var entryCount = 0
            for s in brandStocks where s.brandId == brandId {
                entryCount += 1
                if s.isHidden { continue }
                dict[s.mardCode] = s
                totalAvailable += s.available
                totalUsed += s.used
                if s.available < lowStockThreshold { lowCount += 1 }
            }
            self.stockDict = dict
            self.totalAvailable = totalAvailable
            self.totalUsed = totalUsed
            self.lowStockCount = lowCount
            self.totalColorCount = entryCount
        }
    }

    private func makeSnapshot() -> InventorySnapshot {
        let brandId = inventoryManager.currentBrandId
        let threshold = brandId.map { inventoryManager.getLowStockThreshold(for: $0) } ?? 100
        return InventorySnapshot(
            brandStocks: inventoryManager.brandStocks,
            brandId: brandId,
            lowStockThreshold: threshold
        )
    }

    private func makeFilteredColors(stockDict: [String: BrandStock]) -> [BeadColor] {
        let colors = inventoryManager.searchColors(searchText)
        let visibleColors = colors.filter { stockDict[$0.mardCode] != nil }

        // 自定义色号始终排在最后
        func customColorLast(_ c1: BeadColor, _ c2: BeadColor, by compare: (BeadColor, BeadColor) -> Bool) -> Bool {
            let c1IsCustom = c1.mardCode.hasPrefix("#")
            let c2IsCustom = c2.mardCode.hasPrefix("#")
            if c1IsCustom && !c2IsCustom { return false }
            if !c1IsCustom && c2IsCustom { return true }
            return compare(c1, c2)
        }

        let colorSystem = inventoryManager.currentColorSystem
        let sorted: [BeadColor]
        switch sortOption {
        case .code:
            sorted = visibleColors.sorted { customColorLast($0, $1) {
                $0.displayCode(for: colorSystem).localizedStandardCompare($1.displayCode(for: colorSystem)) == .orderedAscending
            }}
        case .stock:
            sorted = visibleColors.sorted { customColorLast($0, $1) {
                (stockDict[$0.mardCode]?.available ?? 0) < (stockDict[$1.mardCode]?.available ?? 0)
            }}
        case .used:
            sorted = visibleColors.sorted { customColorLast($0, $1) {
                (stockDict[$0.mardCode]?.used ?? 0) < (stockDict[$1.mardCode]?.used ?? 0)
            }}
        case .name:
            sorted = visibleColors.sorted { customColorLast($0, $1) {
                $0.colorName < $1.colorName
            }}
        }
        return sortAscending ? sorted : sorted.reversed()
    }

    private func makeGroupedColors(filtered: [BeadColor]) -> [(prefix: String, colors: [BeadColor])] {
        let colorSystem = inventoryManager.currentColorSystem
        var groups: [String: [BeadColor]] = [:]
        for color in filtered {
            let code = color.displayCode(for: colorSystem)
            let prefix: String
            if code.hasPrefix("#") {
                prefix = "#"
            } else {
                prefix = String(code.prefix(1)).uppercased()
            }
            groups[prefix, default: []].append(color)
        }
        return groups.sorted { lhs, rhs in
            if lhs.key == "#" { return false }
            if rhs.key == "#" { return true }
            return lhs.key < rhs.key
        }.map { ($0.key, $0.value) }
    }

    private func makeStatBarCells(snapshot: InventorySnapshot) -> [BIStatBar.Cell] {
        let denom = max(snapshot.totalAvailable + snapshot.totalUsed, 1)
        let pct = Int(round(Double(snapshot.totalUsed) / Double(denom) * 100))
        return [
            .init(label: String(localized: "总库存"), value: formatLocale(snapshot.totalAvailable), sub: String(localized: "颗")),
            .init(label: String(localized: "已使用"), value: formatLocale(snapshot.totalUsed), sub: "\(pct)%"),
            .init(label: String(localized: "低库存"), value: "\(snapshot.lowStockCount)", sub: String(localized: "种"), warn: true)
        ]
    }

    private func statBarProgress(snapshot: InventorySnapshot) -> Double {
        let denom = Double(snapshot.totalAvailable + snapshot.totalUsed)
        return denom > 0 ? Double(snapshot.totalUsed) / denom : 0
    }

    private func formatLocale(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // MARK: - Hero 区域

    @ViewBuilder
    private func heroSection(snapshot: InventorySnapshot, hasVisibleColors: Bool) -> some View {
        VStack(spacing: 10) {
            // Top row：品牌 pill + 右侧图标按钮
            HStack(spacing: 8) {
                BrandPicker()
                Spacer()
                if snapshot.brandId != nil && hasVisibleColors {
                    Button {
                        withAnimation { sel.enter() }
                    } label: {
                        Image(systemName: "checklist")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.ColorToken.Text.secondary)
                            .frame(width: 34, height: 34)
                            .background(
                                RoundedRectangle(cornerRadius: 11)
                                    .fill(Theme.ColorToken.Surface.elevated)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 11)
                                    .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
                            )
                    }
                }
                if snapshot.brandId != nil {
                    Button {
                        showingBrandSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.ColorToken.Text.secondary)
                            .frame(width: 34, height: 34)
                            .background(
                                RoundedRectangle(cornerRadius: 11)
                                    .fill(Theme.ColorToken.Surface.elevated)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 11)
                                    .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
                            )
                    }
                }
            }

            // Hero row：Wordmark + 右侧统计
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Wordmark(size: 32, beadColor: flavor.color)
                    Text("今天给小豆豆们点个名 ✦")
                        .font(.caption2)
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                }
                Spacer()
                if snapshot.brandId != nil {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("已记录")
                            .font(.caption2)
                            .foregroundStyle(Theme.ColorToken.Text.tertiary)
                        Text("\(snapshot.recordedColorCount)/\(snapshot.totalColorCount) 色")
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.ColorToken.Text.primary)
                    }
                }
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 14)
        .padding(.horizontal, 18)
        .background(
            LinearGradient(
                colors: [
                    Theme.ColorToken.Surface.subtle,
                    Theme.ColorToken.Surface.background
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.ColorToken.Border.divider)
                .frame(height: 1)
        }
    }

    // MARK: - 工具栏（搜索 + 排序 + 分组 + 视图切换）

    @ViewBuilder
    private var toolbarSection: some View {
        VStack(spacing: 10) {
            // 搜索框
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.Text.tertiary)
                TextField("搜索色号或名称", text: $searchText)
                    .font(.subheadline)
                    .textInputAutocapitalization(.never)
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
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.ColorToken.Surface.subtle)
            )

            // 排序 pill + 分组 chip + spacer + 视图切换
            HStack(spacing: 10) {
                Menu {
                    ForEach(SortOption.allCases, id: \.self) { option in
                        Button {
                            if sortOption == option {
                                sortAscending.toggle()
                            } else {
                                sortOption = option
                                sortAscending = true
                            }
                        } label: {
                            HStack {
                                Text(option.localizedName)
                                if sortOption == option {
                                    Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                                }
                            }
                        }
                    }
                    Divider()
                    Button {
                        sortAscending.toggle()
                    } label: {
                        Label(sortAscending ? "切换为降序" : "切换为升序",
                              systemImage: sortAscending ? "arrow.down" : "arrow.up")
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.ColorToken.Text.secondary)
                        Text(sortOption.localizedName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ColorToken.Text.primary)
                        Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.ColorToken.Morandi.latte)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(Theme.ColorToken.Surface.elevated)
                    )
                    .overlay(
                        Capsule().strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
                    )
                }

                Button {
                    withAnimation {
                        groupByPrefix.toggle()
                        if !groupByPrefix {
                            collapsedGroups.removeAll()
                        }
                    }
                } label: {
                    BIChip("分组", active: groupByPrefix, color: flavor.color)
                }
                .buttonStyle(.plain)

                Spacer()

                BISegmented(
                    selection: $viewMode,
                    segments: [
                        (.list, "☰"),
                        (.grid, "▦")
                    ],
                    fillWidth: false
                )
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    var body: some View {
        // 一次 body 渲染期间，所有派生数据共用同一份计算结果。
        let snapshot = makeSnapshot()
        let filtered = makeFilteredColors(stockDict: snapshot.stockDict)
        let grouped = makeGroupedColors(filtered: filtered)
        let cells = makeStatBarCells(snapshot: snapshot)
        let progress = statBarProgress(snapshot: snapshot)

        return NavigationStack {
            VStack(spacing: 0) {
                heroSection(snapshot: snapshot, hasVisibleColors: !filtered.isEmpty)

                if let brandId = snapshot.brandId {
                    BIStatBar(
                        cells: cells,
                        progress: progress,
                        progressColor: Theme.ColorToken.Morandi.latte,
                        progressLabel: nil
                    )
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        lowStockDetailItem = LowStockSheetItem(brandId: brandId)
                    }

                    toolbarSection
                        .padding(.top, 12)

                    if viewMode == .grid {
                        ScrollView {
                            if groupByPrefix {
                                LazyVStack(spacing: 16) {
                                    ForEach(grouped, id: \.prefix) { group in
                                        VStack(spacing: 8) {
                                            GridGroupHeaderView(
                                                prefix: group.prefix,
                                                count: group.colors.count,
                                                isCollapsed: collapsedGroups.contains(group.prefix),
                                                onToggle: {
                                                    withAnimation {
                                                        if collapsedGroups.contains(group.prefix) {
                                                            collapsedGroups.remove(group.prefix)
                                                        } else {
                                                            collapsedGroups.insert(group.prefix)
                                                        }
                                                    }
                                                }
                                            )
                                            .padding(.horizontal)

                                            if !collapsedGroups.contains(group.prefix) {
                                                LazyVGrid(columns: [
                                                    GridItem(.flexible()),
                                                    GridItem(.flexible()),
                                                    GridItem(.flexible())
                                                ], spacing: 12) {
                                                    ForEach(group.colors) { color in
                                                        BISelectableCell(
                                                            isActive: sel.isActive,
                                                            isSelected: sel.contains(color.id),
                                                            onLongPress: { withAnimation { sel.enter(initial: color.id) } },
                                                            onTapInSelectMode: { sel.toggle(color.id) },
                                                            onTapInactive: { selectedColor = color },
                                                            checkmarkPlacement: .topLeading
                                                        ) {
                                                            ColorCardView(
                                                                color: color,
                                                                stock: snapshot.stockDict[color.mardCode],
                                                                sortOption: sortOption,
                                                                lowStockThreshold: snapshot.lowStockThreshold,
                                                                colorSystem: inventoryManager.currentColorSystem
                                                            )
                                                        }
                                                    }
                                                }
                                                .padding(.horizontal)
                                            }
                                        }
                                    }
                                }
                                .padding(.bottom, 20)
                            } else {
                                LazyVGrid(columns: [
                                    GridItem(.flexible()),
                                    GridItem(.flexible()),
                                    GridItem(.flexible())
                                ], spacing: 12) {
                                    ForEach(filtered) { color in
                                        BISelectableCell(
                                            isActive: sel.isActive,
                                            isSelected: sel.contains(color.id),
                                            onLongPress: { withAnimation { sel.enter(initial: color.id) } },
                                            onTapInSelectMode: { sel.toggle(color.id) },
                                            onTapInactive: { selectedColor = color },
                                            checkmarkPlacement: .topLeading
                                        ) {
                                            ColorCardView(
                                                color: color,
                                                stock: snapshot.stockDict[color.mardCode],
                                                sortOption: sortOption,
                                                lowStockThreshold: snapshot.lowStockThreshold,
                                                colorSystem: inventoryManager.currentColorSystem
                                            )
                                        }
                                    }
                                }
                                .padding(.horizontal)
                                .padding(.bottom, 20)
                            }
                        }
                    } else {
                        if groupByPrefix {
                            List {
                                ForEach(grouped, id: \.prefix) { group in
                                    Section {
                                        if !collapsedGroups.contains(group.prefix) {
                                            ForEach(group.colors) { color in
                                                BISelectableCell(
                                                    isActive: sel.isActive,
                                                    isSelected: sel.contains(color.id),
                                                    onLongPress: { withAnimation { sel.enter(initial: color.id) } },
                                                    onTapInSelectMode: { sel.toggle(color.id) },
                                                    onTapInactive: { selectedColor = color }
                                                ) {
                                                    ColorRowView(
                                                        color: color,
                                                        stock: snapshot.stockDict[color.mardCode],
                                                        sortOption: sortOption,
                                                        lowStockThreshold: snapshot.lowStockThreshold,
                                                        colorSystem: inventoryManager.currentColorSystem
                                                    )
                                                }
                                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                            }
                                        }
                                    } header: {
                                        GroupHeaderView(
                                            prefix: group.prefix,
                                            count: group.colors.count,
                                            isCollapsed: collapsedGroups.contains(group.prefix),
                                            onToggle: {
                                                withAnimation {
                                                    if collapsedGroups.contains(group.prefix) {
                                                        collapsedGroups.remove(group.prefix)
                                                    } else {
                                                        collapsedGroups.insert(group.prefix)
                                                    }
                                                }
                                            }
                                        )
                                    }
                                }
                            }
                            .listStyle(.plain)
                        } else {
                            List {
                                ForEach(filtered) { color in
                                    BISelectableCell(
                                        isActive: sel.isActive,
                                        isSelected: sel.contains(color.id),
                                        onLongPress: { withAnimation { sel.enter(initial: color.id) } },
                                        onTapInSelectMode: { sel.toggle(color.id) },
                                        onTapInactive: { selectedColor = color }
                                    ) {
                                        ColorRowView(
                                            color: color,
                                            stock: snapshot.stockDict[color.mardCode],
                                            sortOption: sortOption,
                                            lowStockThreshold: snapshot.lowStockThreshold,
                                            colorSystem: inventoryManager.currentColorSystem
                                        )
                                    }
                                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                }
                            }
                            .listStyle(.plain)
                        }
                    }
                } else {
                    EmptyStateView(
                        icon: "square.grid.3x3",
                        title: "请先创建品牌",
                        description: "到「品牌管理」中添加品牌后再开始记录库存"
                    )
                }
            }
            .background(Theme.ColorToken.Surface.background)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if sel.isActive {
                        Button {
                            withAnimation { sel.exit() }
                        } label: {
                            Text("取消")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if sel.isActive {
                        HStack(spacing: 12) {
                            Button {
                                if sel.count == filtered.count {
                                    sel.clear()
                                } else {
                                    sel.selectAll(filtered.map { $0.id })
                                }
                            } label: {
                                Text(sel.count == filtered.count ? "取消全选" : "全选")
                            }
                            Button {
                                withAnimation { sel.exit() }
                            } label: {
                                Text("完成").fontWeight(.semibold)
                            }
                        }
                    } else {
                        EmptyView()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if sel.isActive {
                    MultiSelectActionBar(count: sel.count) {
                        Button(role: .destructive) {
                            showBatchHideAlert = true
                        } label: {
                            Label("隐藏", systemImage: "eye.slash")
                                .font(.headline)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Theme.ColorToken.Status.error.opacity(sel.count == 0 ? 0.3 : 0.15), in: Capsule())
                        }
                        .disabled(sel.count == 0)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .alert("隐藏选中的色号？", isPresented: $showBatchHideAlert) {
                Button("取消", role: .cancel) {}
                Button("隐藏 \(sel.count) 个", role: .destructive) {
                    batchHideSelected(filtered: filtered)
                }
            } message: {
                Text("隐藏后可在品牌设置中恢复")
            }
            .sheet(item: $selectedColor) { color in
                EditStockSheet(color: color, stock: snapshot.stockDict[color.mardCode])
            }
            .sheet(isPresented: $showingBrandSettings) {
                NavigationStack {
                    BrandSettingsView()
                }
            }
            .sheet(item: $lowStockDetailItem) { item in
                LowStockDetailView(brandId: item.brandId)
                    .environmentObject(inventoryManager)
            }
            .haptic(.success, trigger: lastSuccessAt)
            .preference(key: SelectModeActivePreferenceKey.self, value: sel.isActive)
        }
    }

    /// 批量隐藏选中的色号（按当前品牌）。
    /// 由 body 把当前 filtered 列表传进来，避免再次触发派生数据重算。
    private func batchHideSelected(filtered: [BeadColor]) {
        guard let brandId = inventoryManager.currentBrandId else { return }
        let idToCode: [UUID: String] = Dictionary(
            uniqueKeysWithValues: filtered.map { ($0.id, $0.mardCode) }
        )
        for id in sel.selected {
            if let mardCode = idToCode[id] {
                inventoryManager.hideColor(brandId: brandId, mardCode: mardCode)
            }
        }
        lastSuccessAt = Date()
        withAnimation { sel.exit() }
    }
}

// MARK: - 分组标题视图（列表模式）
struct GroupHeaderView: View {
    let prefix: String
    let count: Int
    let isCollapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack {
                Text(prefix)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)

                Text("系列")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Text("(\(count))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()

                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 分组标题视图（网格模式）
struct GridGroupHeaderView: View {
    let prefix: String
    let count: Int
    let isCollapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack {
                Text(prefix)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)

                Text("系列")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Text("(\(count))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()

                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 统计头部
struct StatsHeaderView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    var onLowStockTap: () -> Void

    var body: some View {
        if let brandId = inventoryManager.currentBrandId {
            HStack(spacing: 12) {
                BIStatCard(
                    icon: "cube.fill",
                    title: "总库存",
                    value: formatNumber(inventoryManager.totalAvailable(for: brandId)),
                    accent: nil // 跟随 tab 风味色
                )
                BIStatCard(
                    icon: "checkmark.circle.fill",
                    title: "已使用",
                    value: formatNumber(inventoryManager.totalUsed(for: brandId)),
                    accent: Theme.ColorToken.Decorative.mint
                )
                BIStatCard(
                    icon: "exclamationmark.triangle.fill",
                    title: "低库存",
                    value: "\(inventoryManager.lowStockColors(for: brandId).count)",
                    accent: Theme.ColorToken.Status.warning
                )
                .onTapGesture {
                    onLowStockTap()
                }
            }
        }
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

// MARK: - 排序选项
struct SortChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Theme.ColorToken.Morandi.latte.opacity(0.2) : Theme.ColorToken.Surface.subtle)
                .foregroundColor(isSelected ? Theme.ColorToken.Morandi.latte : Theme.ColorToken.Text.secondary)
                .cornerRadius(Theme.Radius.lg)
        }
    }
}

// MARK: - 颜色卡片
struct ColorCardView: View {
    let color: BeadColor
    let stock: BrandStock?
    var sortOption: InventoryView.SortOption = .code
    var lowStockThreshold: Int = 100
    var colorSystem: ColorSystem = .mard

    var available: Int { stock?.available ?? 0 }
    var used: Int { stock?.used ?? 0 }
    var isLowStock: Bool { available < lowStockThreshold }

    // 显示色号：根据品牌色号体系显示
    var displayCode: String {
        color.displayCode(for: colorSystem)
    }

    var isCustomColor: Bool {
        color.mardCode.hasPrefix("#")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 颜色块：填色 + 高光 + 内阴影
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(color.color)
                    .frame(height: 56)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(
                                RadialGradient(
                                    colors: [Color.white.opacity(0.55), .clear],
                                    center: UnitPoint(x: 0.32, y: 0.28),
                                    startRadius: 0,
                                    endRadius: 50
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)

                // 低库存红点（左上）
                if isLowStock {
                    Circle()
                        .fill(Theme.ColorToken.Status.error)
                        .frame(width: 8, height: 8)
                        .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isCustomColor {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.ColorToken.Morandi.honey)
                        .padding(6)
                }
            }

            // 色号
            Text(displayCode)
                .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.Text.primary)

            // 主数值 + 小 delta（无色名）
            if sortOption == .used {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(used)")
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .foregroundStyle(used > 0 ? Theme.ColorToken.Morandi.latte : Theme.ColorToken.Text.primary)
                    Text("已用")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.ColorToken.Text.tertiary)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(available)")
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .foregroundStyle(isLowStock ? Theme.ColorToken.Status.error : Theme.ColorToken.Text.primary)
                    if used > 0 {
                        Text("-\(used)")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(Theme.ColorToken.Text.tertiary)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.ColorToken.Surface.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
        )
    }
}

// MARK: - 颜色行视图（列表模式）
struct ColorRowView: View {
    let color: BeadColor
    let stock: BrandStock?
    var sortOption: InventoryView.SortOption = .code
    var lowStockThreshold: Int = 100
    var colorSystem: ColorSystem = .mard

    var available: Int { stock?.available ?? 0 }
    var used: Int { stock?.used ?? 0 }
    var totalStock: Int { stock?.stock ?? 0 }

    var isLowStock: Bool { available < lowStockThreshold }

    // 显示色号：根据品牌色号体系显示
    var displayCode: String {
        color.displayCode(for: colorSystem)
    }

    var isCustomColor: Bool {
        color.mardCode.hasPrefix("#")
    }

    /// 库存剩余进度（available / (available+used)），用于细进度条
    private var remainingRatio: Double {
        let denom = Double(available + used)
        guard denom > 0 else { return 0 }
        return Double(available) / denom
    }

    private var remainingPct: Int {
        let denom = available + used
        guard denom > 0 else { return 0 }
        return Int(Double(available) / Double(denom) * 100)
    }

    var body: some View {
        HStack(spacing: 12) {
            // 1) 拼豆视图（自定义色用 honey 描边环）
            BeadView(
                color: color.color,
                size: 40,
                ring: isCustomColor ? Theme.ColorToken.Morandi.honey : nil
            )

            // 2) 色号（+自定义名）
            VStack(alignment: .leading, spacing: 2) {
                Text(displayCode)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.ColorToken.Text.primary)
                if isCustomColor {
                    Text(color.colorName)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 3) 中段：细进度条 + 剩 N%
            VStack(spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Theme.ColorToken.Surface.strong)
                            .frame(height: 4)
                        Capsule()
                            .fill(isLowStock ? Theme.ColorToken.Morandi.rose : Theme.ColorToken.Morandi.latte)
                            .frame(width: geo.size.width * CGFloat(min(max(remainingRatio, 0), 1)), height: 4)
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 4)
                HStack {
                    Text("剩")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.ColorToken.Text.tertiary)
                    Spacer(minLength: 0)
                    Text("\(remainingPct)%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                }
            }
            .frame(width: 60)

            // 4) 右侧数值 + delta / 充足
            VStack(alignment: .trailing, spacing: 2) {
                if sortOption == .used {
                    Text("\(used)")
                        .font(.system(size: 19, weight: .semibold).monospacedDigit())
                        .foregroundStyle(used > 0 ? Theme.ColorToken.Morandi.latte : Theme.ColorToken.Text.primary)
                    Text("已用")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.ColorToken.Text.tertiary)
                } else {
                    Text("\(available)")
                        .font(.system(size: 19, weight: .semibold).monospacedDigit())
                        .foregroundStyle(isLowStock ? Theme.ColorToken.Status.error : Theme.ColorToken.Text.primary)
                    if used > 0 {
                        Text("-\(used)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.ColorToken.Status.warning)
                    } else {
                        Text("充足")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.ColorToken.Text.tertiary)
                    }
                }
            }
            .frame(minWidth: 60, alignment: .trailing)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
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

// MARK: - 编辑库存弹窗
/// 编辑色号 sheet —— 对齐设计稿 EditStockScreen：
///   半屏 sheet → drag handle → 头部(BeadView + 色号 + 低库存 badge + 副标题 + ✕)
///   → 3 数字 mini-stat 卡 → 进度条 → 调整/设置 segmented
///   → 调整模式：[− | 数字 | +] + 快捷 chips + hint；设置模式：总库存 / 已使用 行
///   → 隐藏此色号 warning row → "保存调整" latte 主 CTA
struct EditStockSheet: View {
    let color: BeadColor
    let stock: BrandStock?
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss

    enum EditMode: Hashable { case adjust, set }

    @State private var mode: EditMode = .adjust
    @State private var adjustDelta: Int = 50           // 调整模式的有符号增量
    @State private var stockAmount: String = ""
    @State private var usedAmount: String = ""
    @State private var showingHideAlert = false
    @State private var lastSuccessAt: Date = .distantPast
    @FocusState private var isInputFocused: Bool

    var currentStock: Int { stock?.stock ?? 0 }
    var currentUsed: Int { stock?.used ?? 0 }
    var currentAvailable: Int { stock?.available ?? 0 }
    var lowStockThreshold: Int {
        guard let brandId = inventoryManager.currentBrandId else { return 100 }
        return inventoryManager.getLowStockThreshold(for: brandId)
    }
    var isLowStock: Bool { currentAvailable < lowStockThreshold }
    var isCustomColor: Bool { color.mardCode.hasPrefix("#") }

    /// 调整后预览剩余
    var previewRemaining: Int {
        max(0, currentAvailable + adjustDelta)
    }

    /// 用量百分比
    var usagePct: Double {
        guard currentStock > 0 else { return 0 }
        return min(1.0, Double(currentUsed) / Double(currentStock))
    }

    var subtitle: String {
        let brand = inventoryManager.currentBrand?.name ?? ""
        let system = inventoryManager.currentColorSystem == .mard ? "MARD" : "卡卡"
        if isCustomColor {
            return "\(color.colorName) · \(brand)"
        }
        return "\(brand) · \(system)"
    }

    var body: some View {
        VStack(spacing: 14) {
            // drag handle
            Capsule()
                .fill(Theme.ColorToken.Border.default)
                .frame(width: 40, height: 4)
                .padding(.top, 6)

            headerRow

            threeStatsCard

            // 进度条（用量）
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.ColorToken.Surface.strong)
                        .frame(height: 6)
                    Capsule()
                        .fill(isLowStock ? Theme.ColorToken.Morandi.rose : Theme.ColorToken.Morandi.latte)
                        .frame(width: geo.size.width * CGFloat(usagePct), height: 6)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 6)

            // 模式切换
            HStack {
                BISegmented(
                    selection: $mode,
                    segments: [(.adjust, "调整 ±"), (.set, "直接设置")],
                    fillWidth: false
                )
                Spacer()
            }

            // 内容区
            Group {
                switch mode {
                case .adjust: adjustModeBlock
                case .set:    setModeBlock
                }
            }

            // 隐藏此色号
            Button {
                showingHideAlert = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 14, weight: .semibold))
                    Text("隐藏此色号")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ColorToken.Text.tertiary)
                }
                .foregroundStyle(Theme.ColorToken.Status.warning)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Theme.ColorToken.Surface.subtle)
                )
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            // 主 CTA
            Button {
                commit()
            } label: {
                Text(mode == .adjust ? "保存调整" : "保存设置")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Theme.ColorToken.Morandi.latte)
                    )
                    .shadow(color: Theme.ColorToken.Morandi.latte.opacity(0.25), radius: 8, x: 0, y: 4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 30)
        .background(Theme.ColorToken.Surface.background)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .haptic(.success, trigger: lastSuccessAt)
        .onAppear {
            stockAmount = "\(currentStock)"
            usedAmount = "\(currentUsed)"
        }
        .alert("隐藏色号", isPresented: $showingHideAlert) {
            Button("取消", role: .cancel) { }
            Button("隐藏", role: .destructive) {
                hideCurrentColor()
            }
        } message: {
            Text("确定要隐藏 \(color.displayCode(for: inventoryManager.currentColorSystem)) 吗？\n\n库存将被清零，该色号不会出现在库存列表和低库存提醒中。可在品牌设置 > 隐藏色号管理中恢复。")
        }
        .toolbar {
            ToolbarItem(placement: .keyboard) {
                HStack {
                    Spacer()
                    Button("收起键盘") { isInputFocused = false }
                }
            }
        }
    }

    // MARK: - Sub views

    private var headerRow: some View {
        HStack(spacing: 14) {
            BeadView(
                color: color.color,
                size: 56,
                ring: isCustomColor ? Theme.ColorToken.Morandi.honey : nil
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(color.displayCode(for: inventoryManager.currentColorSystem))
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.ColorToken.Text.primary)
                    if isLowStock {
                        BIChip("低库存", active: true, color: Theme.ColorToken.Morandi.rose, size: .sm)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                    .frame(width: 30, height: 30)
                    .background(
                        Circle().fill(Theme.ColorToken.Surface.subtle)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var threeStatsCard: some View {
        HStack(spacing: 0) {
            miniStat(label: "总库存", value: "\(currentStock)", warn: false)
            miniStatDivider
            miniStat(label: "已使用", value: "\(currentUsed)", warn: false)
            miniStatDivider
            miniStat(label: "剩余", value: "\(currentAvailable)", warn: isLowStock)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 0)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Theme.ColorToken.Surface.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
        )
    }

    private func miniStat(label: String, value: String, warn: Bool) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 20, weight: .semibold).monospacedDigit())
                .foregroundStyle(warn ? Theme.ColorToken.Status.error : Theme.ColorToken.Text.primary)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.ColorToken.Text.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var miniStatDivider: some View {
        Rectangle()
            .fill(Theme.ColorToken.Border.divider)
            .frame(width: 1, height: 28)
    }

    // 调整模式：[− | 大数字 + 颗 | +]   快捷 chips   "调整后剩余将变为 X 颗"
    private var adjustModeBlock: some View {
        VStack(spacing: 10) {
            // ± 大输入条
            HStack(spacing: 10) {
                Button { decrementDelta() } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.ColorToken.Text.primary)
                        .frame(width: 50, height: 50)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Theme.ColorToken.Surface.subtle)
                        )
                }
                .buttonStyle(.plain)

                VStack(spacing: 0) {
                    Text(formattedDelta)
                        .font(.system(size: 28, weight: .semibold).monospacedDigit())
                        .foregroundStyle(deltaColor)
                    Text("颗")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.ColorToken.Text.tertiary)
                }
                .frame(maxWidth: .infinity)

                Button { incrementDelta() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.ColorToken.Morandi.latte)
                        .frame(width: 50, height: 50)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Theme.ColorToken.Morandi.latte.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Theme.ColorToken.Surface.elevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
            )

            // 快捷 chips
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                ForEach([10, 50, 100, 500], id: \.self) { n in
                    Button { setDeltaAbsolute(n) } label: {
                        Text("\(n)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.ColorToken.Text.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(Theme.ColorToken.Surface.subtle)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            // 预览 hint
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ColorToken.Morandi.honey)
                Text("调整后剩余将变为")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                Text("\(previewRemaining) 颗")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.ColorToken.Text.primary)
                Spacer()
            }
        }
    }

    // 直接设置：总库存 / 已使用 两行
    private var setModeBlock: some View {
        VStack(spacing: 10) {
            setRow(label: "总库存", text: $stockAmount)
            setRow(label: "已使用", text: $usedAmount)
        }
    }

    private func setRow(label: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Theme.ColorToken.Text.secondary)
                .frame(width: 60, alignment: .leading)
            TextField("", text: text)
                .keyboardType(.asciiCapableNumberPad)
                .font(.system(size: 18, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.ColorToken.Text.primary)
                .focused($isInputFocused)
            Spacer()
            Image(systemName: "pencil")
                .font(.system(size: 13))
                .foregroundStyle(Theme.ColorToken.Text.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.ColorToken.Surface.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
        )
    }

    private var formattedDelta: String {
        adjustDelta > 0 ? "+\(adjustDelta)" : "\(adjustDelta)"
    }

    private var deltaColor: Color {
        if adjustDelta > 0 { return Theme.ColorToken.Morandi.latte }
        if adjustDelta < 0 { return Theme.ColorToken.Status.error }
        return Theme.ColorToken.Text.primary
    }

    private func incrementDelta() { adjustDelta += 1 }
    private func decrementDelta() { adjustDelta -= 1 }
    private func setDeltaAbsolute(_ n: Int) {
        // 保持符号；如果当前为 0，默认 +
        adjustDelta = adjustDelta >= 0 ? n : -n
    }

    /// 先收起键盘、再修改数据、最后延迟 dismiss
    private func dismissAfterDataChange() {
        isInputFocused = false
        DispatchQueue.main.async {
            dismiss()
        }
    }

    private func commit() {
        switch mode {
        case .adjust: applyAdjustment()
        case .set:    applySetBoth()
        }
    }

    private func applyAdjustment() {
        guard adjustDelta != 0,
              let brandId = inventoryManager.currentBrandId else { return }
        let amount = abs(adjustDelta)
        if adjustDelta > 0 {
            inventoryManager.addStock(brandId: brandId, mardCode: color.mardCode, amount: amount)
        } else {
            // 走 inventoryManager.useStock 正确写入 used + 记录 stockDeduct 历史。
            // 不直接改 brandStocks[index].used 以避免绕过 HistoryManager（CLAUDE.md 约定）。
            inventoryManager.useStock(brandId: brandId, mardCode: color.mardCode, amount: amount)
        }
        adjustDelta = 0
        lastSuccessAt = Date()
        dismissAfterDataChange()
    }

    private func applySetBoth() {
        guard let brandId = inventoryManager.currentBrandId else { return }
        var changed = false
        if let newStock = Int(stockAmount), newStock >= 0, newStock != currentStock {
            inventoryManager.updateStock(brandId: brandId, mardCode: color.mardCode, newStock: newStock)
            changed = true
        }
        if let newUsed = Int(usedAmount), newUsed >= 0, newUsed != currentUsed {
            // 走 inventoryManager.updateUsed 记录 stockDeduct/stockUpdate 历史,
            // 不直接改 brandStocks[index].used 以避免绕过 HistoryManager(CLAUDE.md 约定)。
            if inventoryManager.updateUsed(brandId: brandId, mardCode: color.mardCode, newUsed: newUsed) {
                changed = true
            }
        }
        if changed { lastSuccessAt = Date() }
        dismissAfterDataChange()
    }

    func hideCurrentColor() {
        guard let brandId = inventoryManager.currentBrandId else { return }
        inventoryManager.hideColor(brandId: brandId, mardCode: color.mardCode)
        dismissAfterDataChange()
    }
}

struct InfoBlock: View {
    let title: String
    let value: String
    var highlight: Bool = false

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(highlight ? .red : .primary)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    InventoryView()
        .environmentObject(InventoryManager())
}
