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
    @State private var showingEditSheet = false
    @State private var sortOption: SortOption = .code

    enum SortOption: String, CaseIterable {
        case code = "色号"
        case stock = "库存"
        case used = "已用"
        case name = "名称"
    }

    var filteredColors: [BeadColor] {
        let colors = inventoryManager.searchColors(searchText)
        switch sortOption {
        case .code:
            return colors.sorted { $0.mardCode < $1.mardCode }
        case .stock:
            return colors.sorted { $0.available > $1.available }
        case .used:
            return colors.sorted { $0.used > $1.used }
        case .name:
            return colors.sorted { $0.colorName < $1.colorName }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部统计卡片
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
                                withAnimation { sortOption = option }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 8)

                // 颜色列表
                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 12) {
                        ForEach(filteredColors) { color in
                            ColorCardView(color: color, sortOption: sortOption)
                            .onTapGesture {
                                selectedColor = color
                                showingEditSheet = true
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 20)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("豆子库存")
            .searchable(text: $searchText, prompt: "搜索色号或名称")
            .sheet(isPresented: $showingEditSheet) {
                if let color = selectedColor {
                    EditStockSheet(color: color)
                }
            }
        }
    }
}

// MARK: - 统计头部
struct StatsHeaderView: View {
    @EnvironmentObject var inventoryManager: InventoryManager

    var body: some View {
        HStack(spacing: 12) {
            StatCard(
                title: "总库存",
                value: formatNumber(inventoryManager.totalAvailable),
                icon: "cube.fill",
                color: .blue
            )
            StatCard(
                title: "已使用",
                value: formatNumber(inventoryManager.totalUsed),
                icon: "checkmark.circle.fill",
                color: .green
            )
            StatCard(
                title: "低库存",
                value: "\(inventoryManager.lowStockColors.count)",
                icon: "exclamationmark.triangle.fill",
                color: .orange
            )
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
    var sortOption: InventoryView.SortOption = .code

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

            // MARD 色号
            Text(color.mardCode)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)

            // 根据排序方式显示不同数值
            if sortOption == .used {
                // 按用量排序时显示用量
                HStack(spacing: 4) {
                    Text("用量:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(color.used)")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundColor(color.used > 0 ? .orange : .secondary)
                }
            } else {
                // 其他排序显示剩余量
                HStack(spacing: 4) {
                    Text("\(color.available)")
                        .font(.caption2)
                        .foregroundColor(color.available < 100 ? .red : .secondary)

                    if color.used > 0 {
                        Text("(-\(color.used))")
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

// MARK: - 编辑库存弹窗
struct EditStockSheet: View {
    let color: BeadColor
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss

    @State private var stockAmount: String = ""
    @State private var adjustAmount: String = ""
    @State private var isAdding = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
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
                    InfoBlock(title: "总库存", value: "\(color.stock)")
                    InfoBlock(title: "已使用", value: "\(color.used)")
                    InfoBlock(title: "可用", value: "\(color.available)", highlight: color.available < 100)
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
                        TextField("新库存数量", text: $stockAmount)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)

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
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(16)

                Spacer()
            }
            .padding()
            .navigationTitle("编辑库存")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .onAppear {
            stockAmount = "\(color.stock)"
        }
    }

    func applyAdjustment() {
        guard let amount = Int(adjustAmount), amount > 0 else { return }
        if isAdding {
            inventoryManager.addStock(for: color.id, amount: amount)
        } else {
            inventoryManager.useBeads(for: color.id, amount: amount)
        }
        adjustAmount = ""
        dismiss()
    }

    func setStock() {
        guard let newStock = Int(stockAmount), newStock >= 0 else { return }
        inventoryManager.updateStock(for: color.id, newStock: newStock)
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
