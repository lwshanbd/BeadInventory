//
//  HistoryView.swift
//  BeadInventory
//
//  历史记录视图 - 显示所有操作历史并支持撤回
//

import SwiftUI

struct HistoryView: View {
    @ObservedObject private var historyManager = HistoryManager.shared
    @State private var showingClearAlert = false

    var body: some View {
        Group {
            if historyManager.records.isEmpty {
                emptyStateView
            } else {
                historyListView
            }
        }
        .navigationTitle("历史记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !historyManager.records.isEmpty {
                    Button(role: .destructive) {
                        showingClearAlert = true
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .alert("清空历史记录", isPresented: $showingClearAlert) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                historyManager.clearAll()
            }
        } message: {
            Text("确定要清空所有历史记录吗？此操作不可撤回。")
        }
    }

    // MARK: - 空状态视图

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("暂无历史记录")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("操作记录将在这里显示")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - 历史列表视图

    private var historyListView: some View {
        List {
            ForEach(historyManager.groupedRecords, id: \.0) { group in
                Section(header: Text(group.0)) {
                    ForEach(group.1) { record in
                        HistoryRowView(record: record) {
                            revertRecord(record)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - 撤回操作

    private func revertRecord(_ record: HistoryRecord) {
        let success = historyManager.revert(record.id)
        if !success {
            // 可以显示一个错误提示
            print("撤回失败")
        }
    }
}

// MARK: - 历史记录行视图

struct HistoryRowView: View {
    let record: HistoryRecord
    let onRevert: () -> Void

    @State private var showingRevertAlert = false

    var body: some View {
        HStack(spacing: 12) {
            // 图标
            iconView

            // 内容
            VStack(alignment: .leading, spacing: 4) {
                Text(record.operationType.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(record.entityName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // 时间
            Text(record.formattedTime)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canRevert(record) {
                Button {
                    showingRevertAlert = true
                } label: {
                    Label("撤回", systemImage: "arrow.uturn.backward")
                }
                .tint(.orange)
            }
        }
        .alert("确认撤回", isPresented: $showingRevertAlert) {
            Button("取消", role: .cancel) {}
            Button("撤回", role: .destructive) {
                onRevert()
            }
        } message: {
            Text("确定要撤回「\(record.operationType.displayName): \(record.entityName)」吗？")
        }
    }

    // 图标视图
    private var iconView: some View {
        Image(systemName: record.operationType.iconName)
            .font(.title2)
            .foregroundColor(iconColor)
            .frame(width: 32, height: 32)
    }

    // 图标颜色
    private var iconColor: Color {
        switch record.operationType.iconColor {
        case "green": return .green
        case "blue": return .blue
        case "red": return .red
        case "orange": return .orange
        case "purple": return .purple
        case "indigo": return .indigo
        case "teal": return .teal
        default: return .primary
        }
    }

    // 判断是否可以撤回
    private func canRevert(_ record: HistoryRecord) -> Bool {
        switch record.operationType {
        case .stockReset, .projectMerge, .planExecute:
            // 这些操作不支持撤回
            return false
        default:
            return true
        }
    }
}

#Preview {
    NavigationStack {
        HistoryView()
    }
}
