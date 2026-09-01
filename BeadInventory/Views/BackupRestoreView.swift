//
//  BackupRestoreView.swift
//  BeadInventory
//
//  备份恢复视图 - 查看和恢复自动备份
//

import SwiftUI

struct BackupRestoreView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) private var dismiss

    @State private var backups: [BackupManager.BackupInfo] = []
    @State private var selectedBackup: BackupManager.BackupInfo?
    @State private var showingRestoreConfirm = false
    @State private var showingDeleteConfirm = false
    @State private var backupToDelete: BackupManager.BackupInfo?
    @State private var isRestoring = false
    @State private var restoreError: String?
    @State private var showingError = false
    @State private var showingSuccess = false
    /// 抛错时 store 是否已被改动 —— 决定弹窗说「恢复失败」还是「恢复中断」。
    @State private var restoreDidMutateStore = false
    @State private var isBackingUp = false
    @State private var isSuppressed = false
    @State private var backupMessage: String?
    @State private var restoreResidual: RestoreJournalEntry?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                restoreResidualBanner
                suppressionBanner
                messageBanner
                Group {
                    if backups.isEmpty {
                        emptyView
                    } else {
                        backupListView
                    }
                }
            }
            .navigationTitle("恢复备份")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
                // 手动备份入口。
                //
                // 它不只是"方便" —— 自动备份被中断后会**抑制当周**，而被抑制时它压根
                // 不运行，所以无法靠自己成功来解除。手动成功是唯一的主动解除路径
                //（另一条是跨周自然失效）。没有这个入口，用户遇到中断就只能干等一周。
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await performManualBackup() }
                    } label: {
                        if isBackingUp {
                            ProgressView()
                        } else {
                            // 导航栏里 Label 只会画图标，一个孤零零的云图标看不出是干什么的，
                            // 这里直接用文字，跟左边的「关闭」对齐。
                            Text("立即备份")
                        }
                    }
                    .disabled(isBackingUp || isRestoring)
                }
            }
            .onAppear {
                loadBackups()
                isSuppressed = BackupManager.shared.isAutomaticBackupSuppressed
                restoreResidual = RestoreJournal.residual()
            }
            .confirmationDialog(
                "确定要恢复这个备份吗？",
                isPresented: $showingRestoreConfirm,
                titleVisibility: .visible
            ) {
                Button("恢复备份", role: .destructive) {
                    performRestore()
                }
                Button("取消", role: .cancel) {}
            } message: {
                if let backup = selectedBackup {
                    // 网格标定这句**只对旧格式成立**。新的归档格式已经把 patternGrid
                    // 收进去了，对它照旧提示会把用户吓得不敢恢复一份其实完整的备份。
                    switch backup.format {
                    case .archiveV1:
                        Text("这将用 \(backup.formattedDate) 的备份替换当前所有数据。此操作不可撤销。")
                    case .legacyJSON:
                        Text("这将用 \(backup.formattedDate) 的备份替换当前所有数据。此操作不可撤销。\n这是旧格式备份，不含拼图模式的网格标定，恢复后这部分需要重新标定。")
                    }
                }
            }
            .confirmationDialog(
                "确定要删除这个备份吗？",
                isPresented: $showingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let backup = backupToDelete {
                        deleteBackup(backup)
                    }
                }
                Button("取消", role: .cancel) {}
            }
            // 标题按"库有没有被改过"分开。两者对用户的含义完全不同：
            // 「恢复失败」= 数据没被动，可以放心重试；
            // 「恢复中断」= 库现在可能是半恢复的，必须重跑。
            .alert(restoreFailureTitle, isPresented: $showingError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(restoreError ?? "未知错误")
            }
            .alert("恢复成功", isPresented: $showingSuccess) {
                Button("确定") {
                    dismiss()
                }
            } message: {
                Text("数据已成功恢复")
            }
        }
    }

    // MARK: - 空状态视图

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.clockwise.icloud")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("暂无备份")
                .font(.title2)
                .fontWeight(.medium)

            Text("App 会在每周首次打开时自动备份数据")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    // MARK: - 备份列表视图

    private var backupListView: some View {
        List {
            Section {
                ForEach(backups) { backup in
                    BackupRow(backup: backup)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedBackup = backup
                            showingRestoreConfirm = true
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                backupToDelete = backup
                                showingDeleteConfirm = true
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            } header: {
                Text("点击备份进行恢复")
            } footer: {
                Text("自动保留最近 8 周的备份。向左滑动可删除备份。")
            }
        }
        .overlay {
            if isRestoring {
                restoringOverlay
            }
        }
    }

    // MARK: - 恢复中遮罩

    private var restoringOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                Text("正在恢复...")
                    .font(.headline)
                    .foregroundColor(.white)
            }
            .padding(30)
            .background(Theme.ColorToken.Surface.subtle)
            .cornerRadius(Theme.Radius.lg)
        }
    }

    // MARK: - 方法

    private func loadBackups() {
        backups = BackupManager.shared.getBackupList()
    }

    private func performRestore() {
        guard let backup = selectedBackup else { return }

        isRestoring = true
        Task {
            do {
                try await BackupManager.shared.restoreBackup(from: backup, to: inventoryManager)
                isRestoring = false
                // 日志已被 `RestoreJournal.finish()` 删掉，这里同步刷新 @State，
                // 否则刚成功恢复完，屏幕顶上还挂着红色的"上次恢复未完成"。
                restoreResidual = RestoreJournal.residual()
                showingSuccess = true
            } catch {
                isRestoring = false
                presentRestoreFailure(error)
            }
        }
    }

    /// 失败弹窗标题。**不要内联成三元表达式** —— 放进 `.alert(...)` 的修饰符链里会让
    /// Swift 类型检查器超时。
    private var restoreFailureTitle: String {
        restoreDidMutateStore
            ? String(localized: "恢复中断")
            : String(localized: "恢复失败")
    }

    /// 统一的恢复失败呈现。
    ///
    /// 用 `"\(error)"` 而非 `localizedDescription` —— 这些错误只符合
    /// `CustomStringConvertible`，后者会产出 "…error 3." 之类的系统乱码。
    private func presentRestoreFailure(_ error: Error) {
        // 兜底看**日志残留**而不是假定"库没被动过"。`retryResidualRestore` 只在库已经
        // 半恢复时才可能被点到，而它第一步 `validate()` 抛的是 `ValidationError` ——
        // 兜成 false 的话标题会变成「恢复失败」，按本文件自己的口径那等于告诉用户
        // "数据没被动、可以放心重试"，与事实相反。
        restoreDidMutateStore = (error as? BackupArchiveReader.RestoreError)?.didMutateStore
            ?? (RestoreJournal.residual() != nil)
        restoreError = "\(error)"
        restoreResidual = RestoreJournal.residual()
        showingError = true
    }

    /// 重跑中断的恢复。归档还在盘上，重跑是幂等的。
    private func retryResidualRestore(_ residual: RestoreJournalEntry) {
        let url = URL(fileURLWithPath: residual.archivePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            restoreError = String(localized: "找不到该备份，可能已被删除。请从下方列表选择其它备份恢复。")
            showingError = true
            return
        }
        isRestoring = true
        Task {
            do {
                // 校验要读遍并哈希全部图片，必须离开主 actor；只有 apply 留在主线程。
                // 这条路径尤其不能卡主线程 —— 它是给**已知半恢复**的库做修复的，
                // 在这里被看门狗杀掉只会再制造一次中断记录，把用户留在原地。
                let report = try await Task.detached(priority: .userInitiated) {
                    try BackupArchiveReader.validate(archiveAt: url)
                }.value
                try BackupArchiveReader.apply(report, to: inventoryManager)
                isRestoring = false
                restoreResidual = RestoreJournal.residual()   // 成功后应为 nil
                showingSuccess = true
            } catch {
                isRestoring = false
                presentRestoreFailure(error)
            }
        }
    }

    /// 手动备份。成功后解除抑制并刷新列表。
    private func performManualBackup() async {
        isBackingUp = true
        backupMessage = nil
        let ok = await BackupManager.shared.performArchiveBackup(
            inventoryManager: inventoryManager, isManual: true
        )
        isBackingUp = false
        isSuppressed = BackupManager.shared.isAutomaticBackupSuppressed
        backupMessage = ok
            ? String(localized: "备份完成")
            : String(localized: "备份失败，请检查存储空间后重试")
        loadBackups()
    }

    // MARK: - 顶部横幅
    //
    // 抽成独立属性而不是内联进 body：body 里堆条件分支会让 Swift 类型检查器指数级退化。

    /// 上一次恢复中断的持久提示。
    ///
    /// 这是**数据可能已经半损坏**的告知，比抑制提示严重一个等级：metadata 已被替换、
    /// 图片只恢复了一部分。归档还在盘上且重跑幂等，所以直接给一个重试动作。
    @ViewBuilder
    private var restoreResidualBanner: some View {
        if let residual = restoreResidual {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("上次恢复未完成，当前数据可能不完整")
                            .font(.footnote.weight(.semibold))
                        Text((residual.archivePath as NSString).lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                Button("重新恢复") {
                    retryResidualRestore(residual)
                }
                .font(.footnote.weight(.semibold))
                .disabled(isRestoring)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.12))
        }
    }

    /// 被抑制时必须让用户看得见 —— 否则"这周怎么没备份"无从得知，
    /// 而解除办法（点一次「立即备份」）就在同一屏上。
    @ViewBuilder
    private var suppressionBanner: some View {
        if isSuppressed {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("上次自动备份被中断，本周已暂停自动备份。手动备份成功后会自动恢复。")
                    .font(.footnote)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color.orange.opacity(0.12))
        }
    }

    @ViewBuilder
    private var messageBanner: some View {
        if let backupMessage {
            Text(backupMessage)
                .font(.footnote)
                .padding(8)
        }
    }

    private func deleteBackup(_ backup: BackupManager.BackupInfo) {
        if BackupManager.shared.deleteBackup(backup) {
            loadBackups()
        }
    }
}

// MARK: - 备份行视图

struct BackupRow: View {
    let backup: BackupManager.BackupInfo

    var body: some View {
        HStack(spacing: 12) {
            // 图标
            Image(systemName: "doc.zipper")
                .font(.title2)
                .foregroundColor(Theme.ColorToken.Status.info)
                .frame(width: 40)

            // 信息
            VStack(alignment: .leading, spacing: 4) {
                Text(backup.formattedDate)
                    .font(.headline)

                HStack(spacing: 12) {
                    if let stats = backup.stats {
                        Label("\(stats.brandsCount) 品牌", systemImage: "tag")
                        Label("\(stats.projectsCount) 项目", systemImage: "folder")
                    }
                    Text(backup.formattedSize)
                        .foregroundColor(.secondary)
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    BackupRestoreView()
        .environmentObject(InventoryManager())
}
