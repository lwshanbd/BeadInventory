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

    var body: some View {
        NavigationStack {
            Group {
                if backups.isEmpty {
                    emptyView
                } else {
                    backupListView
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
            }
            .onAppear {
                loadBackups()
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
            .background(Color(.systemGray5))
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
                .foregroundColor(.blue)
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
