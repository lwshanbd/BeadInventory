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
    @State private var isBackingUp = false
    @State private var isSuppressed = false
    @State private var backupMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                suppressionBanner
                messageBanner
                if backups.isEmpty {
                    emptyView
                } else {
                    backupListView
                }
            }
            .navigationTitle("备份与恢复")
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
                            Label("立即备份", systemImage: "arrow.clockwise.icloud")
                        }
                    }
                    .disabled(isBackingUp)
                }
            }
            .onAppear {
                loadBackups()
                isSuppressed = BackupManager.shared.isAutomaticBackupSuppressed
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
                    Text("这将用 \(backup.formattedDate) 的备份替换当前所有数据。此操作不可撤销。")
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
            .alert("恢复失败", isPresented: $showingError) {
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

    // MARK: - 顶部横幅
    //
    // 抽成独立属性而不是内联进 body：SwiftUI 的 body 里堆条件分支会让 Swift 类型检查器
    // 指数级退化（SourceKit 实测报 "unable to type-check this expression in reasonable
    // time"）。本仓库 ScanView 甚至为此专门有个 `.pipe` helper。

    /// 被抑制时必须让用户看得见 —— 否则"这周怎么没备份"无从得知，
    /// 而解除办法（点一次"立即备份"）就在同一屏上。
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

    /// 手动备份。成功后解除抑制并刷新列表。
    private func performManualBackup() async {
        isBackingUp = true
        backupMessage = nil
        let ok = await BackupManager.shared.performArchiveBackup(
            inventoryManager: inventoryManager, isManual: true
        )
        isBackingUp = false
        isSuppressed = BackupManager.shared.isAutomaticBackupSuppressed
        backupMessage = ok ? "备份完成" : "备份失败，请检查存储空间后重试"
        loadBackups()
    }

    private func loadBackups() {
        backups = BackupManager.shared.getBackupList()
    }

    private func performRestore() {
        guard let backup = selectedBackup else { return }

        isRestoring = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            do {
                try BackupManager.shared.restoreBackup(from: backup, to: inventoryManager)
                isRestoring = false
                showingSuccess = true
            } catch {
                isRestoring = false
                restoreError = error.localizedDescription
                showingError = true
            }
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
