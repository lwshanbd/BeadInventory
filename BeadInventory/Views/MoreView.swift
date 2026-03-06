//
//  MoreView.swift
//  BeadInventory
//
//  更多功能页面
//

import SwiftUI

struct MoreView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @EnvironmentObject var cloudSyncStatusManager: CloudSyncStatusManager

    var body: some View {
        NavigationStack {
            List {
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
                                        .background(Color.orange)
                                        .cornerRadius(10)
                                }
                            }
                        } icon: {
                            Image(systemName: "shippingbox.fill")
                                .foregroundColor(.orange)
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
                                .foregroundColor(.green)
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
                                .foregroundColor(.orange)
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
                                .foregroundColor(.purple)
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
                                .foregroundColor(.pink)
                        }
                    }
                }

                Section("数据与同步") {
                    cloudSyncStatusView
                    if cloudSyncStatusManager.shouldAllowManualRefresh {
                        Button {
                            cloudSyncStatusManager.refreshAccountStatus(force: true)
                        } label: {
                            Label("刷新 iCloud 状态", systemImage: "arrow.clockwise")
                        }
                        .disabled(cloudSyncStatusManager.isCheckingAccount)
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
                                .foregroundColor(.cyan)
                        }
                    }

                    NavigationLink {
                        DiagnosticsToolsView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("诊断与帮助")
                                Text("日志导出、扫描帮助与使用说明")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "stethoscope")
                                .foregroundColor(.indigo)
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
                                .foregroundColor(.blue)
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
                                .foregroundColor(.gray)
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
                                .foregroundColor(.accentColor)
                        }
                    }
                }
            }
            .navigationTitle("更多")
            .onAppear {
                cloudSyncStatusManager.refreshAccountStatus()
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
                            .foregroundColor(.blue)
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
                            .foregroundColor(.green)
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
    @State private var showingScanHelp = false
    @State private var showingDiagnosticsShareSheet = false
    @State private var diagnosticsExportURL: URL?
    @State private var isExportingDiagnostics = false
    @State private var isClearingDiagnostics = false
    @State private var showingClearDiagnosticsAlert = false
    @State private var diagnosticsNoticeMessage = ""
    @State private var showingDiagnosticsNotice = false

    var body: some View {
        List {
            Section("帮助") {
                Button {
                    showingScanHelp = true
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("AI扫描帮助")
                            Text("查看扫描识别使用说明")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: "questionmark.circle.fill")
                            .foregroundColor(.orange)
                    }
                }
                .foregroundColor(.primary)

                NavigationLink {
                    HelpView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("使用帮助")
                            Text("功能介绍与使用技巧")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: "book.fill")
                            .foregroundColor(.teal)
                    }
                }
            }

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
                                .foregroundColor(.red)
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
        .navigationTitle("诊断与帮助")
        .sheet(isPresented: $showingScanHelp) {
            ScanHelpSheet(onDismiss: {
                showingScanHelp = false
            })
        }
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
