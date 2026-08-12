//
//  HistoryView.swift
//  BeadInventory
//
//  历史记录 —— 二级页骨架（SecondaryNav + ScrollView + GroupCard）。
//  本页主调色 = Morandi.honey（内部硬编码，不读 @Environment(\.tabFlavor)）。
//

import SwiftUI

// MARK: - 操作类型 → 设计稿 flavor / icon 映射

/// 历史记录行视觉分类。设计稿要求 morandi 色而非系统色。
private enum HistoryOpFlavor {
    case deduct      // 扣减 → mauve, minus.circle
    case add         // 入库 / 添加 → sage, plus.circle
    case delete      // 删除 → rose, trash
    case edit        // 修改 → mist, pencil
    case hide        // 隐藏 → text-tertiary, eye.slash
    case execute     // 执行 → honey, checkmark.circle

    var color: Color {
        switch self {
        case .deduct:  return Theme.ColorToken.Morandi.mauve
        case .add:     return Theme.ColorToken.Morandi.sage
        case .delete:  return Theme.ColorToken.Morandi.rose
        case .edit:    return Theme.ColorToken.Morandi.mist
        case .hide:    return Theme.ColorToken.Text.tertiary
        case .execute: return Theme.ColorToken.Morandi.honey
        }
    }

    var icon: String {
        switch self {
        case .deduct:  return "minus.circle"
        case .add:     return "plus.circle"
        case .delete:  return "trash"
        case .edit:    return "pencil"
        case .hide:    return "eye.slash"
        case .execute: return "checkmark.circle"
        }
    }

    var filterLabel: String {
        switch self {
        case .add:     return String(localized: "入库")
        case .deduct:  return String(localized: "扣减")
        case .edit:    return String(localized: "编辑")
        case .delete:  return String(localized: "删除")
        case .execute: return String(localized: "执行")
        case .hide:    return String(localized: "隐藏")
        }
    }
}

private extension HistoryOperationType {
    var flavor: HistoryOpFlavor {
        switch self {
        case .brandAdd, .stockAdd, .projectAdd, .planAdd:
            return .add
        case .stockDeduct:
            return .deduct
        case .stockReset, .brandUpdate, .stockUpdate, .projectUpdate, .planUpdate, .projectArchive, .projectUnarchive, .projectMerge:
            return .edit
        case .brandDelete, .projectDelete, .planDelete:
            return .delete
        case .planExecute:
            return .execute
        }
    }
}

// MARK: - 顶部分段筛选

private enum HistoryFilter: Equatable, Hashable {
    case all
    case flavor(HistoryOpFlavor)

    var label: String {
        switch self {
        case .all: return String(localized: "全部")
        case .flavor(let f): return f.filterLabel
        }
    }

    static var displayed: [HistoryFilter] {
        [.all, .flavor(.add), .flavor(.deduct), .flavor(.edit), .flavor(.delete)]
    }

    func matches(_ op: HistoryOperationType) -> Bool {
        switch self {
        case .all: return true
        case .flavor(let f):
            // 把 .execute / .hide 之类的也归入「编辑」之外的弱视觉行为不显式过滤
            return op.flavor == f
        }
    }
}

// MARK: - HistoryView

struct HistoryView: View {
    @ObservedObject private var historyManager = HistoryManager.shared

    @State private var showingClearAlert = false
    @StateObject private var sel = SelectionContext<UUID>()
    @State private var showBatchRevertAlert = false
    @State private var revertSuccessAt: Date = .distantPast
    @State private var filter: HistoryFilter = .all
    @State private var showingRevertError = false
    @State private var revertErrorMessage = ""

    private let honey = Theme.ColorToken.Morandi.honey

    /// 所有可撤回的记录 id，用于「全选」时跳过不可撤回项。
    private var revertableRecordIds: [UUID] {
        filteredGroupedRecords
            .flatMap { $0.1 }
            .filter { historyManager.canRevert($0) }
            .map { $0.id }
    }

    /// 按当前 filter 过滤后的分组结果。
    private var filteredGroupedRecords: [(String, [HistoryRecord])] {
        let groups = historyManager.groupedRecords
        guard filter != .all else { return groups }
        return groups.compactMap { (key, records) -> (String, [HistoryRecord])? in
            let kept = records.filter { filter.matches($0.operationType) }
            return kept.isEmpty ? nil : (key, kept)
        }
    }

    private var revertableCount: Int {
        historyManager.records.filter { historyManager.canRevert($0) }.count
    }

    private var recentSevenDayCount: Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        return historyManager.records.filter { $0.timestamp >= cutoff }.count
    }

    // MARK: - body

    var body: some View {
        VStack(spacing: 0) {
            navBar
            Group {
                if historyManager.records.isEmpty {
                    emptyState
                } else {
                    contentScroll
                }
            }
        }
        .background(Theme.ColorToken.Surface.background)
        .navigationBarHidden(true)
        .safeAreaInset(edge: .bottom) {
            if sel.isActive {
                multiSelectActionBar
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
        .haptic(.success, trigger: revertSuccessAt)
        .alert("撤回结果", isPresented: $showingRevertError) {
            Button("我知道了", role: .cancel) {}
        } message: {
            Text(revertErrorMessage)
        }
    }

    // MARK: - 顶部 nav

    private var navBar: some View {
        BISecondaryNav(title: sel.isActive ? String(localized: "已选 \(sel.count) 条") : String(localized: "历史记录")) {
            if sel.isActive {
                Button {
                    if sel.count == revertableRecordIds.count {
                        sel.clear()
                    } else {
                        sel.selectAll(revertableRecordIds)
                    }
                } label: {
                    Text(sel.count == revertableRecordIds.count ? "取消全选" : "全选")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(honey)
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation { sel.exit() }
                } label: {
                    Text("完成")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(honey)
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.plain)
            } else if !historyManager.records.isEmpty {
                BINavIconButton(systemImage: "trash") {
                    showingClearAlert = true
                }
                Button {
                    withAnimation { sel.enter() }
                } label: {
                    Text("选择")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(honey)
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 内容

    private var contentScroll: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: []) {
                summaryCard
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
                    .padding(.bottom, 12)

                filterChips
                    .padding(.horizontal, 18)
                    .padding(.bottom, 4)

                ForEach(filteredGroupedRecords, id: \.0) { group in
                    BIGroupHeader(title: group.0, hint: String(localized: "\(group.1.count) 条"))
                    BIGroupCard {
                        ForEach(Array(group.1.enumerated()), id: \.element.id) { idx, record in
                            HistoryRowCell(
                                record: record,
                                isLast: idx == group.1.count - 1,
                                isSelectMode: sel.isActive,
                                isSelected: sel.contains(record.id),
                                canRevert: historyManager.canRevert(record),
                                revertDisabledReason: historyManager.revertDisabledReason(record),
                                onTap: {
                                    if sel.isActive {
                                        if historyManager.canRevert(record) {
                                            sel.toggle(record.id)
                                        }
                                    }
                                },
                                onLongPress: {
                                    if !sel.isActive, historyManager.canRevert(record) {
                                        withAnimation { sel.enter(initial: record.id) }
                                    }
                                },
                                onRevert: { revertRecord(record) }
                            )
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
            .padding(.bottom, 32)
        }
    }

    // MARK: - 总览卡

    private var summaryCard: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(honey.opacity(0.18))
                    .frame(width: 38, height: 38)
                Image(systemName: "clock")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(honey)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("近 7 天")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(recentSevenDayCount)")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.ColorToken.Text.primary)
                    Text("条操作 · 可撤回 \(revertableCount) 条")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                }
            }

            Spacer(minLength: 4)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.ColorToken.Surface.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
        )
    }

    // MARK: - 筛选 chip 行

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(HistoryFilter.displayed.enumerated()), id: \.offset) { _, f in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { filter = f }
                    } label: {
                        BIChip(f.label, active: filter == f, color: honey, size: .sm)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 底部多选操作条

    private var multiSelectActionBar: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("将撤回")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(sel.count)")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundStyle(honey)
                    Text("条记录")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                }
            }

            Spacer(minLength: 4)

            Button {
                withAnimation { sel.exit() }
            } label: {
                Text("取消")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.ColorToken.Surface.subtle, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)

            Button {
                showBatchRevertAlert = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.backward")
                    Text("撤回选中")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    (sel.count == 0 ? Theme.ColorToken.Text.tertiary : honey),
                    in: RoundedRectangle(cornerRadius: 12)
                )
            }
            .buttonStyle(.plain)
            .disabled(sel.count == 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .background(
            Theme.ColorToken.Surface.elevated
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Theme.ColorToken.Border.divider)
                        .frame(height: 1)
                }
        )
    }

    // MARK: - 空状态

    private var emptyState: some View {
        BIEmptyHero(
            icon: "clock.arrow.circlepath",
            flavor: honey,
            title: String(localized: "暂无历史记录"),
            subtitle: String(localized: "操作记录将在这里显示，并可在 7 天内撤回。")
        ) {
            // no CTA
        }
    }

    // MARK: - 撤回

    private func revertRecord(_ record: HistoryRecord) {
        switch historyManager.revert(record.id) {
        case .success:
            revertSuccessAt = Date()
        case .partial(let warning):
            // 主体撤回成功了，缺的那部分如实说 —— 不能报「撤回失败」，
            // 那会让用户再点一次，而项目已经回来了（见 RevertOutcome.partial）。
            revertSuccessAt = Date()
            revertErrorMessage = warning
            showingRevertError = true
        case .snapshotLoadFailed:
            // 可重试的瞬时失败：明确区分于「永久不可恢复」，引导用户重试。
            revertErrorMessage = "快照加载失败，请稍后重试"
            showingRevertError = true
        case .failed:
            revertErrorMessage = "撤回失败，记录可能已不可恢复"
            showingRevertError = true
        }
    }

    /// 批量撤回：按记录时间倒序逐条撤回。
    /// 区分成功/失败：仅当至少一条成功时触发 success 触感；如有失败则弹 alert 列出统计。
    private func batchRevertSelected() {
        let toRevert = historyManager.records
            .filter { sel.contains($0.id) && historyManager.canRevert($0) }
            .sorted { $0.timestamp > $1.timestamp }
        var successCount = 0
        var failureCount = 0
        /// 撤回成功、但有东西没能一起还原的条数（目前只有多零件进度）。
        var partialCount = 0
        for record in toRevert {
            switch historyManager.revert(record.id) {
            case .success:
                successCount += 1
            case .partial:
                // partial 也是撤回成功（记录已消费、项目已回来），只是有东西没跟上。
                // 逐条弹窗没有意义，但**也不能就这么算了**：记录已经被消费掉，
                // 用户再也没有第二次机会知道这几条缺了什么。攒起来最后一起说。
                successCount += 1
                partialCount += 1
            case .failed, .snapshotLoadFailed:
                failureCount += 1
            }
        }
        if successCount > 0 {
            revertSuccessAt = Date()
        }
        if failureCount > 0 || partialCount > 0 {
            var parts: [String] = []
            if failureCount > 0 { parts.append(String(localized: "失败 \(failureCount) 条")) }
            if partialCount > 0 {
                parts.append(String(localized: "\(partialCount) 条的多零件进度没能一起还原"))
            }
            let detail = parts.joined(separator: "，")
            revertErrorMessage = successCount > 0
                ? String(localized: "成功撤回 \(successCount) 条，其中 \(detail)")
                : String(localized: "全部 \(failureCount) 条撤回均失败")
            showingRevertError = true
        }
        withAnimation { sel.exit() }
    }
}

// MARK: - 单行 cell

private struct HistoryRowCell: View {
    let record: HistoryRecord
    let isLast: Bool
    let isSelectMode: Bool
    let isSelected: Bool
    let canRevert: Bool
    let revertDisabledReason: String?
    let onTap: () -> Void
    let onLongPress: () -> Void
    let onRevert: () -> Void

    @State private var showingRevertAlert = false
    @State private var showingDisabledAlert = false

    private let honey = Theme.ColorToken.Morandi.honey

    private var flavor: HistoryOpFlavor { record.operationType.flavor }

    var body: some View {
        HStack(spacing: 12) {
            if isSelectMode {
                checkbox
                    .frame(width: 22, height: 22)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }

            // 操作类型 icon
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(flavor.color.opacity(0.18))
                    .frame(width: 34, height: 34)
                Image(systemName: flavor.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(flavor.color)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(record.operationType.displayName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.ColorToken.Text.primary)
                        .lineLimit(1)
                    if !canRevert {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.ColorToken.Text.tertiary)
                    }
                }
                Text(record.entityName)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Text(record.formattedTime)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.Text.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            isSelected && isSelectMode
                ? honey.opacity(0.10)
                : Color.clear
        )
        .opacity(isSelectMode && !canRevert ? 0.45 : 1.0)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(Theme.ColorToken.Border.divider)
                    .frame(height: 1)
                    .padding(.leading, isSelectMode ? 78 : 60)
            }
        }
        .onTapGesture {
            if isSelectMode {
                onTap()
            } else if canRevert {
                showingRevertAlert = true
            } else if revertDisabledReason != nil {
                showingDisabledAlert = true
            }
        }
        .onLongPressGesture(minimumDuration: 0.4) {
            onLongPress()
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isSelectMode {
                if canRevert {
                    Button {
                        showingRevertAlert = true
                    } label: {
                        Label("撤回", systemImage: "arrow.uturn.backward")
                    }
                    .tint(honey)
                } else if revertDisabledReason != nil {
                    Button {
                        showingDisabledAlert = true
                    } label: {
                        Label("不可撤回", systemImage: "lock.fill")
                    }
                    .tint(Theme.ColorToken.Text.secondary)
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
            Text(revertDisabledReason ?? String(localized: "此操作不支持撤回"))
        }
    }

    private var checkbox: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? honey : Color.clear)
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.clear : Theme.ColorToken.Border.default,
                    lineWidth: 2
                )
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
    }

    private var revertConfirmMessage: String {
        switch record.operationType {
        case .planExecute:
            return String(localized: "确定要撤回执行「\(record.entityName)」吗？\n\n库存将恢复，项目将变回计划状态。")
        default:
            return String(localized: "确定要撤回「\(record.operationType.displayName): \(record.entityName)」吗？")
        }
    }
}

#Preview {
    NavigationStack {
        HistoryView()
    }
}
