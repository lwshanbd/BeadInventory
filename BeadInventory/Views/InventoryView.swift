//
//  InventoryView.swift
//  BeadInventory
//
//  库存管理主界面
//

import SwiftUI

struct InventoryView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var searchText = ""
    @State private var selectedColor: BeadColor?
    @State private var showingBrandSettings = false
    @State private var sortOption: SortOption = .code
    @State private var sortAscending: Bool = true
    @AppStorage("inventoryViewMode") private var viewMode: ViewMode = .list
    @AppStorage("inventoryGroupByPrefix") private var groupByPrefix: Bool = false
    @State private var collapsedGroups: Set<String> = []

    enum ViewMode: String {
        case list = "list"
        case grid = "grid"
    }

    enum SortOption: String, CaseIterable {
        case code = "色号"
        case stock = "库存"
        case used = "已用"
        case name = "名称"
    }

    // 获取当前品牌的库存字典（排除隐藏的色号）
    var stockDict: [String: BrandStock] {
        guard let brandId = inventoryManager.currentBrandId else { return [:] }
        let stocks = inventoryManager.brandStocks.filter { $0.brandId == brandId && !$0.isHidden }
        return Dictionary(uniqueKeysWithValues: stocks.map { ($0.mardCode, $0) })
    }

    // 获取当前品牌的低库存阈值
    var lowStockThreshold: Int {
        guard let brandId = inventoryManager.currentBrandId else { return 100 }
        return inventoryManager.getLowStockThreshold(for: brandId)
    }

    var filteredColors: [BeadColor] {
        let colors = inventoryManager.searchColors(searchText)
        // 过滤掉隐藏的色号（只显示在 stockDict 中存在的颜色）
        let visibleColors = colors.filter { stockDict[$0.mardCode] != nil }

        // 自定义色号始终排在最后的辅助函数
        func customColorLast(_ c1: BeadColor, _ c2: BeadColor, by compare: (BeadColor, BeadColor) -> Bool) -> Bool {
            let c1IsCustom = c1.mardCode.hasPrefix("#")
            let c2IsCustom = c2.mardCode.hasPrefix("#")
            if c1IsCustom && !c2IsCustom { return false }  // c1 自定义，排后面
            if !c1IsCustom && c2IsCustom { return true }   // c2 自定义，c1 排前面
            return compare(c1, c2)  // 都是或都不是自定义，按原规则排序
        }

        let sorted: [BeadColor]
        switch sortOption {
        case .code:
            sorted = visibleColors.sorted { customColorLast($0, $1) {
                $0.mardCode.localizedStandardCompare($1.mardCode) == .orderedAscending
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

    // 按首字母分组的颜色
    var groupedColors: [(prefix: String, colors: [BeadColor])] {
        var groups: [String: [BeadColor]] = [:]
        for color in filteredColors {
            // 自定义色号（以 # 开头）单独分组为 "#"
            let prefix: String
            if color.mardCode.hasPrefix("#") {
                prefix = "#"
            } else {
                prefix = String(color.mardCode.prefix(1)).uppercased()
            }
            if groups[prefix] != nil {
                groups[prefix]?.append(color)
            } else {
                groups[prefix] = [color]
            }
        }
        // 按首字母排序，"#"（自定义色号）放在最后
        return groups.sorted { lhs, rhs in
            if lhs.key == "#" { return false }
            if rhs.key == "#" { return true }
            return lhs.key < rhs.key
        }.map { ($0.key, $0.value) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 品牌选择器
                HStack {
                    BrandPicker()

                    if inventoryManager.currentBrandId != nil {
                        Button {
                            showingBrandSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 18))
                                .foregroundColor(.accentColor)
                                .padding(8)
                                .background(Color.accentColor.opacity(0.1))
                                .cornerRadius(8)
                        }
                    }

                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 8)

                // 顶部统计卡片
                if inventoryManager.currentBrandId != nil {
                    StatsHeaderView()
                        .padding(.horizontal)
                        .padding(.top, 8)

                    // 排序选项
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(SortOption.allCases, id: \.self) { option in
                                SortChip(
                                    title: option.rawValue,
                                    isSelected: sortOption == option
                                ) {
                                    withAnimation {
                                        if sortOption == option {
                                            // 点击已选中的选项时切换排序方向
                                            sortAscending.toggle()
                                        } else {
                                            sortOption = option
                                            sortAscending = true
                                        }
                                    }
                                }
                            }

                            // 排序方向按钮
                            Button {
                                withAnimation { sortAscending.toggle() }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                                    Text(sortAscending ? "升序" : "降序")
                                }
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.2))
                                .foregroundColor(.accentColor)
                                .cornerRadius(16)
                            }

                            // 分组按钮
                            Button {
                                withAnimation {
                                    groupByPrefix.toggle()
                                    if !groupByPrefix {
                                        collapsedGroups.removeAll()
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: groupByPrefix ? "folder.fill" : "folder")
                                    Text("分组")
                                }
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(groupByPrefix ? Color.orange : Color.gray.opacity(0.2))
                                .foregroundColor(groupByPrefix ? .white : .primary)
                                .cornerRadius(16)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .padding(.bottom, 8)

                    // 颜色列表
                    if viewMode == .grid {
                        // 网格模式
                        ScrollView {
                            if groupByPrefix {
                                // 分组网格模式
                                LazyVStack(spacing: 16) {
                                    ForEach(groupedColors, id: \.prefix) { group in
                                        VStack(spacing: 8) {
                                            // 分组标题
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

                                            // 分组内容
                                            if !collapsedGroups.contains(group.prefix) {
                                                LazyVGrid(columns: [
                                                    GridItem(.flexible()),
                                                    GridItem(.flexible()),
                                                    GridItem(.flexible())
                                                ], spacing: 12) {
                                                    ForEach(group.colors) { color in
                                                        ColorCardView(
                                                            color: color,
                                                            stock: stockDict[color.mardCode],
                                                            sortOption: sortOption,
                                                            lowStockThreshold: lowStockThreshold
                                                        )
                                                        .onTapGesture {
                                                            selectedColor = color
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
                                // 普通网格模式
                                LazyVGrid(columns: [
                                    GridItem(.flexible()),
                                    GridItem(.flexible()),
                                    GridItem(.flexible())
                                ], spacing: 12) {
                                    ForEach(filteredColors) { color in
                                        ColorCardView(
                                            color: color,
                                            stock: stockDict[color.mardCode],
                                            sortOption: sortOption,
                                            lowStockThreshold: lowStockThreshold
                                        )
                                        .onTapGesture {
                                            selectedColor = color
                                        }
                                    }
                                }
                                .padding(.horizontal)
                                .padding(.bottom, 20)
                            }
                        }
                    } else {
                        // 列表模式
                        if groupByPrefix {
                            // 分组模式
                            List {
                                ForEach(groupedColors, id: \.prefix) { group in
                                    Section {
                                        if !collapsedGroups.contains(group.prefix) {
                                            ForEach(group.colors) { color in
                                                ColorRowView(
                                                    color: color,
                                                    stock: stockDict[color.mardCode],
                                                    sortOption: sortOption,
                                                    lowStockThreshold: lowStockThreshold
                                                )
                                                .contentShape(Rectangle())
                                                .onTapGesture {
                                                    selectedColor = color
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
                            // 普通列表模式
                            List {
                                ForEach(filteredColors) { color in
                                    ColorRowView(
                                        color: color,
                                        stock: stockDict[color.mardCode],
                                        sortOption: sortOption,
                                        lowStockThreshold: lowStockThreshold
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectedColor = color
                                    }
                                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                }
                            }
                            .listStyle(.plain)
                        }
                    }
                } else {
                    // 没有品牌时的提示
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "building.2")
                            .font(.system(size: 64))
                            .foregroundColor(.secondary)
                        Text("请先创建品牌")
                            .font(.title2)
                            .fontWeight(.medium)
                        Text("点击上方按钮创建您的第一个品牌")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("啃豆小仓")
            .searchable(text: $searchText, prompt: "搜索色号或名称")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation {
                            viewMode = viewMode == .list ? .grid : .list
                        }
                    } label: {
                        Image(systemName: viewMode == .list ? "square.grid.3x3" : "list.bullet")
                    }
                }
            }
            .sheet(item: $selectedColor) { color in
                EditStockSheet(color: color, stock: stockDict[color.mardCode])
            }
            .sheet(isPresented: $showingBrandSettings) {
                BrandSettingsView()
            }
        }
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
                // 分组标识
                Text(prefix)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(colorForPrefix(prefix))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(prefix) 系列")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text("\(count) 个颜色")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // 折叠/展开图标
                Image(systemName: isCollapsed ? "chevron.down.circle" : "chevron.up.circle")
                    .font(.title3)
                    .foregroundColor(.accentColor)
            }
            .padding(12)
            .background(Color(.systemBackground))
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
        }
        .buttonStyle(.plain)
    }

    // 根据前缀返回不同颜色
    func colorForPrefix(_ prefix: String) -> Color {
        switch prefix {
        case "A": return .red
        case "B": return .orange
        case "C": return .yellow
        case "D": return .green
        case "E": return .mint
        case "F": return .teal
        case "G": return .cyan
        case "H": return .blue
        case "M": return .indigo
        case "P": return .purple
        case "Q": return .pink
        case "R": return .red.opacity(0.7)
        case "T": return .brown
        case "Y": return .orange.opacity(0.7)
        case "ZG": return .gray
        case "#": return .orange
        default: return .gray
        }
    }
}

// MARK: - 统计头部
struct StatsHeaderView: View {
    @EnvironmentObject var inventoryManager: InventoryManager

    var body: some View {
        if let brandId = inventoryManager.currentBrandId {
            HStack(spacing: 12) {
                StatCard(
                    title: "总库存",
                    value: formatNumber(inventoryManager.totalAvailable(for: brandId)),
                    icon: "cube.fill",
                    color: .blue
                )
                StatCard(
                    title: "已使用",
                    value: formatNumber(inventoryManager.totalUsed(for: brandId)),
                    icon: "checkmark.circle.fill",
                    color: .green
                )
                StatCard(
                    title: "低库存",
                    value: "\(inventoryManager.lowStockColors(for: brandId).count)",
                    icon: "exclamationmark.triangle.fill",
                    color: .orange
                )
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

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .font(.caption)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.systemBackground))
        .cornerRadius(12)
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
                .background(isSelected ? Color.accentColor.opacity(0.2) : Color(.systemGray6))
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .cornerRadius(16)
        }
    }
}

// MARK: - 颜色卡片
struct ColorCardView: View {
    let color: BeadColor
    let stock: BrandStock?
    var sortOption: InventoryView.SortOption = .code
    var lowStockThreshold: Int = 100

    var available: Int { stock?.available ?? 0 }
    var used: Int { stock?.used ?? 0 }
    var isLowStock: Bool { available < lowStockThreshold }

    // 显示色号：自定义色号保留 # 前缀
    var displayCode: String {
        color.mardCode
    }

    var isCustomColor: Bool {
        color.mardCode.hasPrefix("#")
    }

    var body: some View {
        VStack(spacing: 8) {
            // 颜色块
            RoundedRectangle(cornerRadius: 8)
                .fill(color.color)
                .frame(height: 50)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
                .overlay(alignment: .topTrailing) {
                    if isCustomColor {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                            .padding(4)
                    }
                }

            // 色号
            Text(displayCode)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)

            // 根据排序方式显示不同数值
            if sortOption == .used {
                // 按用量排序时显示用量
                HStack(spacing: 4) {
                    Text("用量:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(used)")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundColor(used > 0 ? .orange : .secondary)
                }
            } else {
                // 其他排序显示剩余量
                HStack(spacing: 4) {
                    Text("\(available)")
                        .font(.caption2)
                        .foregroundColor(isLowStock ? .red : .secondary)

                    if used > 0 {
                        Text("(-\(used))")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
            }
        }
        .padding(8)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
    }
}

// MARK: - 颜色行视图（列表模式）
struct ColorRowView: View {
    let color: BeadColor
    let stock: BrandStock?
    var sortOption: InventoryView.SortOption = .code
    var lowStockThreshold: Int = 100

    var available: Int { stock?.available ?? 0 }
    var used: Int { stock?.used ?? 0 }
    var totalStock: Int { stock?.stock ?? 0 }

    var isLowStock: Bool { available < lowStockThreshold }

    // 显示色号：自定义色号保留 # 前缀
    var displayCode: String {
        color.mardCode
    }

    var isCustomColor: Bool {
        color.mardCode.hasPrefix("#")
    }

    var body: some View {
        HStack(spacing: 12) {
            // 颜色块
            RoundedRectangle(cornerRadius: 8)
                .fill(color.color)
                .frame(width: 44, height: 44)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
                .overlay(alignment: .topTrailing) {
                    if isCustomColor {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.orange)
                            .padding(2)
                    }
                }

            // 色号和名称
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(displayCode)
                        .font(.system(.headline, design: .monospaced))
                    if isCustomColor {
                        Text("自定义")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .foregroundColor(.orange)
                            .cornerRadius(4)
                    }
                }

                Text(color.colorName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // 库存信息
            VStack(alignment: .trailing, spacing: 4) {
                if sortOption == .used {
                    // 按用量排序时显示用量
                    Text("\(used)")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(used > 0 ? .orange : .secondary)
                    Text("已用")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    // 其他排序显示剩余量
                    Text("\(available)")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(isLowStock ? .red : .primary)
                    if used > 0 {
                        Text("-\(used)")
                            .font(.caption)
                            .foregroundColor(.orange)
                    } else {
                        Text("可用")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // 低库存标识
            if isLowStock {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.subheadline)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color(.systemBackground))
        .cornerRadius(10)
    }
}

// MARK: - 编辑库存弹窗
struct EditStockSheet: View {
    let color: BeadColor
    let stock: BrandStock?
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss

    @State private var stockAmount: String = ""
    @State private var usedAmount: String = ""
    @State private var adjustAmount: String = ""
    @State private var isAdding = true
    @State private var showingHideAlert = false
    @FocusState private var isInputFocused: Bool

    var currentStock: Int { stock?.stock ?? 0 }
    var currentUsed: Int { stock?.used ?? 0 }
    var currentAvailable: Int { stock?.available ?? 0 }
    var lowStockThreshold: Int {
        guard let brandId = inventoryManager.currentBrandId else { return 100 }
        return inventoryManager.getLowStockThreshold(for: brandId)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(spacing: 24) {
                // 品牌名称
                if let brandName = inventoryManager.currentBrand?.name {
                    Text("品牌: \(brandName)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                // 颜色预览
                VStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(color.color)
                        .frame(height: 100)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )

                    // MARD 色号
                    Text(color.mardCode)
                        .font(.title2)
                        .fontWeight(.bold)
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(16)

                // 当前库存信息
                HStack(spacing: 20) {
                    InfoBlock(title: "总库存", value: "\(currentStock)")
                    InfoBlock(title: "已使用", value: "\(currentUsed)")
                    InfoBlock(title: "可用", value: "\(currentAvailable)", highlight: currentAvailable < lowStockThreshold)
                }

                // 调整库存
                VStack(alignment: .leading, spacing: 12) {
                    Text("调整库存")
                        .font(.headline)

                    HStack {
                        Picker("操作", selection: $isAdding) {
                            Text("增加").tag(true)
                            Text("减少").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 120)

                        TextField("数量", text: $adjustAmount)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                            .focused($isInputFocused)

                        Button {
                            applyAdjustment()
                        } label: {
                            Text("确定")
                                .fontWeight(.medium)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.accentColor)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(16)

                // 直接设置库存
                VStack(alignment: .leading, spacing: 12) {
                    Text("直接设置")
                        .font(.headline)

                    HStack {
                        Text("库存")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(width: 50, alignment: .leading)
                        TextField("数量", text: $stockAmount)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                            .focused($isInputFocused)
                        Button {
                            setStock()
                        } label: {
                            Text("设置")
                                .fontWeight(.medium)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.orange)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                    }

                    HStack {
                        Text("已用")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(width: 50, alignment: .leading)
                        TextField("数量", text: $usedAmount)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                            .focused($isInputFocused)
                        Button {
                            setUsed()
                        } label: {
                            Text("设置")
                                .fontWeight(.medium)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.green)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(16)

                // 隐藏色号
                VStack(alignment: .leading, spacing: 12) {
                    Text("色号管理")
                        .font(.headline)

                    Button {
                        showingHideAlert = true
                    } label: {
                        HStack {
                            Image(systemName: "eye.slash")
                            Text("隐藏此色号")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .foregroundColor(.orange)
                    }

                    Text("隐藏后该色号不会出现在库存列表中，库存将被清零。可在品牌设置中恢复。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(16)
            }
            .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("编辑库存")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .keyboard) {
                    HStack {
                        Spacer()
                        Button("收起键盘") {
                            isInputFocused = false
                        }
                    }
                }
            }
        }
        .presentationDetents([.large])
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
            Text("确定要隐藏 \(color.mardCode) 吗？\n\n库存将被清零，该色号不会出现在库存列表和低库存提醒中。可在品牌设置 > 隐藏色号管理中恢复。")
        }
    }

    func applyAdjustment() {
        guard let amount = Int(adjustAmount), amount > 0,
              let brandId = inventoryManager.currentBrandId else { return }
        if isAdding {
            inventoryManager.addStock(brandId: brandId, mardCode: color.mardCode, amount: amount)
        } else {
            // 减少库存 = 增加 used
            if let index = inventoryManager.brandStocks.firstIndex(where: {
                $0.brandId == brandId && $0.mardCode == color.mardCode
            }) {
                inventoryManager.brandStocks[index].used += amount
                inventoryManager.saveData()
            }
        }
        adjustAmount = ""
        dismiss()
    }

    func setStock() {
        guard let newStock = Int(stockAmount), newStock >= 0,
              let brandId = inventoryManager.currentBrandId else { return }
        inventoryManager.updateStock(brandId: brandId, mardCode: color.mardCode, newStock: newStock)
        dismiss()
    }

    func setUsed() {
        guard let newUsed = Int(usedAmount), newUsed >= 0,
              let brandId = inventoryManager.currentBrandId else { return }
        if let index = inventoryManager.brandStocks.firstIndex(where: {
            $0.brandId == brandId && $0.mardCode == color.mardCode
        }) {
            inventoryManager.brandStocks[index].used = newUsed
            inventoryManager.saveData()
        }
        dismiss()
    }

    func hideCurrentColor() {
        guard let brandId = inventoryManager.currentBrandId else { return }
        inventoryManager.hideColor(brandId: brandId, mardCode: color.mardCode)
        dismiss()
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
