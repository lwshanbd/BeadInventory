//
//  MoreView.swift
//  BeadInventory
//
//  更多功能页面
//

import SwiftUI
import TipKit

struct MoreView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @EnvironmentObject var cloudSyncStatusManager: CloudSyncStatusManager
    /// 镜像 CloudSyncPreferences.userOptedOut，用于驱动 Toggle 显示。
    @State private var cloudSyncDisabled: Bool = CloudSyncPreferences.userOptedOut
    /// 当前偏好与 App 启动时的值不一致，说明需要重启 App 才能让 ModelContainer 切换。
    private var hasPendingCloudSyncChange: Bool {
        cloudSyncDisabled != CloudSyncPreferences.bootValue
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        HelpCenterView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("help.center.entry.title")
                                Text("help.center.entry.subtitle")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "book.fill")
                                .foregroundColor(Theme.ColorToken.Decorative.sky)
                        }
                    }

                    TipView(BackupTip())
                }

                Section("工作台") {
                    NavigationLink {
                        ShippingView()
                    } label: {
                        Label {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("运输中")
                                    Text("待到货的购买记录")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if !inventoryManager.purchaseRecords.isEmpty {
                                    Text("\(inventoryManager.purchaseRecords.count)")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(Theme.ColorToken.Status.warning)
                                        .cornerRadius(Theme.Radius.md)
                                }
                            }
                        } icon: {
                            Image(systemName: "shippingbox.fill")
                                .foregroundColor(Theme.ColorToken.Decorative.lavender)
                        }
                    }
                    NavigationLink {
                        CalendarView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("成品日历")
                                Text("按日期查看完成的作品")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "calendar.badge.checkmark")
                                .foregroundColor(Theme.ColorToken.Decorative.lavender)
                        }
                    }
                    NavigationLink {
                        HistoryView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("历史记录")
                                Text("查看操作记录，支持撤回")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundColor(Theme.ColorToken.Decorative.lavender)
                        }
                    }
                }

                Section("色号工具") {
                    NavigationLink {
                        ColorConverterView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("色号转换")
                                Text("不同品牌间的色号对照")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "paintpalette.fill")
                                .foregroundColor(Theme.ColorToken.Decorative.mint)
                        }
                    }

                    NavigationLink {
                        CustomColorsView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("自定义色号")
                                Text("添加和管理自己的色号")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "eyedropper.halffull")
                                .foregroundColor(Theme.ColorToken.Decorative.mint)
                        }
                    }
                }

                Section("数据与同步") {
                    cloudSyncStatusView
                    if cloudSyncStatusManager.shouldAllowManualRefresh {
                        Button {
                            cloudSyncStatusManager.refreshAccountStatus(force: true)
                        } label: {
                            Label {
                                Text("刷新 iCloud 状态")
                            } icon: {
                                Image(systemName: "arrow.clockwise")
                                    .foregroundColor(Theme.ColorToken.Decorative.lemon)
                            }
                        }
                        .disabled(cloudSyncStatusManager.isCheckingAccount)
                    }

                    Toggle(isOn: Binding(
                        get: { !cloudSyncDisabled },
                        set: { newValue in
                            let newOptedOut = !newValue
                            guard newOptedOut != CloudSyncPreferences.userOptedOut else { return }
                            CloudSyncPreferences.userOptedOut = newOptedOut
                            cloudSyncDisabled = newOptedOut
                            AppLogger.shared.info(
                                "App",
                                "cloud_sync_preference_toggled",
                                metadata: ["userOptedOut": newOptedOut]
                            )
                        }
                    )) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(localized: "启用 iCloud 同步"))
                                if hasPendingCloudSyncChange {
                                    Text(String(localized: "已修改，关闭并重新打开 App 后生效。"))
                                        .font(.caption)
                                        .foregroundColor(Theme.ColorToken.Status.warning)
                                } else if cloudSyncDisabled {
                                    Text(String(localized: "当前仅使用本地存储，iCloud 上原有的数据未删除。"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                } else {
                                    Text(String(localized: "关闭后 App 将不再读写 iCloud，仅使用本地存储。"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: "icloud")
                                .foregroundColor(Theme.ColorToken.Decorative.lemon)
                        }
                    }

                    NavigationLink {
                        DataToolsView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("数据与备份")
                                Text("导入导出与备份恢复")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "externaldrive.badge.icloud")
                                .foregroundColor(Theme.ColorToken.Decorative.lemon)
                        }
                    }

                    NavigationLink {
                        DiagnosticsToolsView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("诊断工具")
                                Text("日志导出与排查")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "stethoscope")
                                .foregroundColor(Theme.ColorToken.Decorative.lemon)
                        }
                    }
                }

                Section("设置与关于") {
                    NavigationLink {
                        BrandSettingsView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("品牌管理")
                                Text("添加、编辑品牌信息")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "tag.fill")
                                .foregroundColor(Theme.ColorToken.Text.secondary)
                        }
                    }

                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("设置")
                                Text("AI识别、库存等配置")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "gearshape.fill")
                                .foregroundColor(Theme.ColorToken.Text.secondary)
                        }
                    }

                    NavigationLink {
                        AboutView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("关于")
                                Text("版本信息")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(Theme.ColorToken.Text.secondary)
                        }
                    }
                }
            }
            .navigationTitle("更多")
            .onAppear {
                cloudSyncStatusManager.refreshAccountStatus()
                // 用户可能在 ContentView 错误界面通过"关闭 iCloud 同步"按钮翻动了
                // CloudSyncPreferences.userOptedOut，TabView 中常驻的本视图需要重新拉取最新值。
                let latest = CloudSyncPreferences.userOptedOut
                if cloudSyncDisabled != latest {
                    cloudSyncDisabled = latest
                }
            }
        }
    }

    private var cloudSyncStatusView: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: cloudSyncStatusManager.statusIconName)
                .foregroundColor(cloudSyncStatusManager.statusColor)
                .font(.title3)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(cloudSyncStatusManager.primaryStatusText)
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    if cloudSyncStatusManager.isCheckingAccount {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }

                Text(cloudSyncStatusManager.secondaryStatusText)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("提示：iCloud 同步不是实时的，跨设备同步通常需要几秒到几分钟，请稍等一会再查看。")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                if let checkedAt = cloudSyncStatusManager.lastCheckedAt {
                    Text("上次检查：\(checkedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

}

struct DataToolsView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var showingImportFullData = false
    @State private var showingBackupRestore = false
    @State private var showingExportSheet = false

    var body: some View {
        List {
            Section("导入导出") {
                Button {
                    showingExportSheet = true
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("导出库存数据")
                            Text("导出为 CSV 或 JSON 文件")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: "square.and.arrow.up.fill")
                            .foregroundColor(Theme.ColorToken.Status.info)
                    }
                }
                .foregroundColor(.primary)

                Button {
                    showingImportFullData = true
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("导入历史数据")
                            Text("从备份文件恢复全部数据")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: "arrow.down.doc.fill")
                            .foregroundColor(Theme.ColorToken.Status.success)
                    }
                }
                .foregroundColor(.primary)
            }

            Section {
                Button {
                    showingBackupRestore = true
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("恢复备份")
                            Text("从自动备份恢复数据")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: "arrow.clockwise.icloud.fill")
                            .foregroundColor(.cyan)
                    }
                }
                .foregroundColor(.primary)
            } header: {
                Text("备份恢复")
            } footer: {
                Text("涉及全量数据修改时，建议先导出库存数据留存。")
            }
        }
        .navigationTitle("数据与备份")
        .sheet(isPresented: $showingImportFullData) {
            ImportFullDataView()
        }
        .sheet(isPresented: $showingBackupRestore) {
            BackupRestoreView()
        }
        .sheet(isPresented: $showingExportSheet) {
            ExportDataSheet(inventoryManager: inventoryManager)
        }
    }
}

struct DiagnosticsToolsView: View {
    @State private var showingDiagnosticsShareSheet = false
    @State private var diagnosticsExportURL: URL?
    @State private var isExportingDiagnostics = false
    @State private var isClearingDiagnostics = false
    @State private var showingClearDiagnosticsAlert = false
    @State private var diagnosticsNoticeMessage = ""
    @State private var showingDiagnosticsNotice = false

    var body: some View {
        List {
            Section("诊断日志") {
                Button {
                    exportDiagnosticsLogs()
                } label: {
                    HStack {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("导出诊断日志")
                                Text("仅在排查问题时导出给开发者")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "doc.text.magnifyingglass")
                                .foregroundColor(.indigo)
                        }
                        Spacer()
                        if isExportingDiagnostics {
                            ProgressView()
                        }
                    }
                }
                .foregroundColor(.primary)
                .disabled(isExportingDiagnostics || isClearingDiagnostics)

                Button(role: .destructive) {
                    showingClearDiagnosticsAlert = true
                } label: {
                    HStack {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("清空诊断日志")
                                Text("只清空本机日志，不影响库存数据")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "trash.circle.fill")
                                .foregroundColor(Theme.ColorToken.Status.error)
                        }
                        Spacer()
                        if isClearingDiagnostics {
                            ProgressView()
                        }
                    }
                }
                .disabled(isExportingDiagnostics || isClearingDiagnostics)
            }
        }
        .navigationTitle("诊断工具")
        .sheet(isPresented: $showingDiagnosticsShareSheet, onDismiss: {
            diagnosticsExportURL = nil
        }) {
            if let diagnosticsExportURL {
                ShareSheet(items: [diagnosticsExportURL])
            }
        }
        .alert("清空诊断日志", isPresented: $showingClearDiagnosticsAlert) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                clearDiagnosticsLogs()
            }
        } message: {
            Text("仅会删除当前设备上的诊断日志文件，不会影响库存、项目或云同步数据。")
        }
        .alert("诊断日志", isPresented: $showingDiagnosticsNotice) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(diagnosticsNoticeMessage)
        }
    }

    private func exportDiagnosticsLogs() {
        isExportingDiagnostics = true
        AppLogger.shared.exportDiagnostics { result in
            isExportingDiagnostics = false
            switch result {
            case .success(let url):
                diagnosticsExportURL = url
                showingDiagnosticsShareSheet = true
            case .failure(let error):
                diagnosticsNoticeMessage = "导出失败：\(error.localizedDescription)"
                showingDiagnosticsNotice = true
            }
        }
    }

    private func clearDiagnosticsLogs() {
        isClearingDiagnostics = true
        AppLogger.shared.clearLogs {
            isClearingDiagnostics = false
            diagnosticsNoticeMessage = "诊断日志已清空。"
            showingDiagnosticsNotice = true
        }
    }
}

#Preview {
    MoreView()
        .environmentObject(InventoryManager())
        .environmentObject(CloudSyncStatusManager(mode: .iCloudEnabled))
}
