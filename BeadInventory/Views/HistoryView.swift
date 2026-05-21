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
    @StateObject private var sel = SelectionContext<UUID>()
    @State private var showBatchRevertAlert = false

    /// 所有可撤回的记录 id，用于「全选」时跳过不可撤回项。
    private var revertableRecordIds: [UUID] {
        historyManager.records
            .filter { historyManager.canRevert($0) }
            .map { $0.id }
    }

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
            ToolbarItem(placement: .topBarLeading) {
                if sel.isActive {
                    Button {
                        withAnimation { sel.exit() }
                    } label: {
                        Text("取消")
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if sel.isActive {
                    HStack(spacing: 12) {
                        Button {
                            if sel.count == revertableRecordIds.count {
                                sel.clear()
                            } else {
                                sel.selectAll(revertableRecordIds)
                            }
                        } label: {
                            Text(sel.count == revertableRecordIds.count ? "取消全选" : "全选")
                        }
                        Button {
                            withAnimation { sel.exit() }
                        } label: {
                            Text("完成").fontWeight(.semibold)
                        }
                    }
                } else if !historyManager.records.isEmpty {
                    HStack(spacing: 12) {
                        Button {
                            withAnimation { sel.enter() }
                        } label: {
                            Text("选择")
                        }
                        Button(role: .destructive) {
                            showingClearAlert = true
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if sel.isActive {
                MultiSelectActionBar(count: sel.count) {
                    Button(role: .destructive) {
                        showBatchRevertAlert = true
                    } label: {
                        Label("撤回选中", systemImage: "arrow.uturn.backward")
                            .font(.headline)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.orange.opacity(sel.count == 0 ? 0.3 : 0.15), in: Capsule())
                            .foregroundColor(.orange)
                    }
                    .disabled(sel.count == 0)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
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
        .alert("批量撤回选中的记录？", isPresented: $showBatchRevertAlert) {
            Button("取消", role: .cancel) {}
            Button("撤回 \(sel.count) 条", role: .destructive) {
                batchRevertSelected()
            }
        } message: {
            Text("将按时间倒序逐条撤回。不可撤回的记录会被跳过。")
        }
    }

    /// 批量撤回：按记录时间倒序逐条撤回。
    private func batchRevertSelected() {
        let toRevert = historyManager.records
            .filter { sel.contains($0.id) && historyManager.canRevert($0) }
            .sorted { $0.timestamp > $1.timestamp }
        for record in toRevert {
            _ = historyManager.revert(record.id)
        }
        withAnimation { sel.exit() }
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
                        BISelectableCell(
                            isActive: sel.isActive,
                            isSelected: sel.contains(record.id),
                            onLongPress: {
                                // 长按只允许选中可撤回的记录
                                if historyManager.canRevert(record) {
                                    withAnimation { sel.enter(initial: record.id) }
                                }
                            },
                            onTapInSelectMode: {
                                // 多选态下：不可撤回的记录禁止勾选
                                if historyManager.canRevert(record) {
                                    sel.toggle(record.id)
                                }
                            }
                        ) {
                            HistoryRowView(
                                record: record,
                                swipeDisabled: sel.isActive
                            ) {
                                revertRecord(record)
                            }
                        }
                        .opacity(sel.isActive && !historyManager.canRevert(record) ? 0.4 : 1.0)
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
    var swipeDisabled: Bool = false
    let onRevert: () -> Void

    @ObservedObject private var historyManager = HistoryManager.shared
    @State private var showingRevertAlert = false
    @State private var showingDisabledAlert = false

    var body: some View {
        HStack(spacing: 12) {
            // 图标
            iconView

            // 内容
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(record.operationType.displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    // 显示不可撤回标记
                    if !historyManager.canRevert(record) {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

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
            if !swipeDisabled {
                if historyManager.canRevert(record) {
                    Button {
                        showingRevertAlert = true
                    } label: {
                        Label("撤回", systemImage: "arrow.uturn.backward")
                    }
                    .tint(.orange)
                } else if historyManager.revertDisabledReason(record) != nil {
                    // 显示禁用原因的按钮
                    Button {
                        showingDisabledAlert = true
                    } label: {
                        Label("不可撤回", systemImage: "lock.fill")
                    }
                    .tint(.gray)
                }
            }
        }
        .alert("确认撤回", isPresented: $showingRevertAlert) {
            Button("取消", role: .cancel) {}
            Button("撤回", role: .destructive) {
                onRevert()
            }
        } message: {
            Text(revertConfirmMessage)
        }
        .alert("无法撤回", isPresented: $showingDisabledAlert) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(historyManager.revertDisabledReason(record) ?? "此操作不支持撤回")
        }
    }

    // 撤回确认消息
    private var revertConfirmMessage: String {
        switch record.operationType {
        case .planExecute:
            return "确定要撤回执行「\(record.entityName)」吗？\n\n库存将恢复，项目将变回计划状态。"
        default:
            return "确定要撤回「\(record.operationType.displayName): \(record.entityName)」吗？"
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
}

#Preview {
    NavigationStack {
        HistoryView()
    }
}
