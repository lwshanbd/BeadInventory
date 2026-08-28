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
    /// 镜像 CloudSyncPreferences.userOptedOut，用于驱动 Toggle 显示。
    @State private var cloudSyncDisabled: Bool = CloudSyncPreferences.userOptedOut
    /// 当前偏好与 App 启动时的值不一致，说明需要重启 App 才能让 ModelContainer 切换。
    private var hasPendingCloudSyncChange: Bool {
        cloudSyncDisabled != CloudSyncPreferences.bootValue
    }

    /// 从 Info.plist 读 CFBundleShortVersionString（与 AboutView 同源）。
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var totalBeadsCount: Int {
        inventoryManager.brandStocks.reduce(0) { $0 + max($1.stock, 0) }
    }

    private var completedProjectsCount: Int {
        inventoryManager.projects.filter { !$0.isPlanned && !$0.isArchived }.count
    }

    private var shippingCount: Int {
        inventoryManager.purchaseRecords.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    heroCard
                        .padding(.top, 8)
                        .padding(.bottom, 16)

                    // Group 1 — 工作台（无标题）
                    groupCard(title: nil) {
                        NavigationLink {
                            ShippingView()
                        } label: {
                            MoreCardRow(
                                icon: "shippingbox.fill",
                                iconColor: Theme.ColorToken.Morandi.latte,
                                title: "运输中 · 待到货",
                                subtitle: "查看待到货的购买记录",
                                trailing: shippingCount > 0 ? .badge("\(shippingCount)") : .chevron
                            )
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            CalendarView()
                        } label: {
                            MoreCardRow(
                                icon: "calendar",
                                iconColor: Theme.ColorToken.Morandi.sage,
                                title: "成品日历",
                                subtitle: "按日期查看完成的作品",
                                trailing: .chevron,
                                isLast: true
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.bottom, 18)

                    // Group 2 — 色号工具
                    groupCard(title: "色号工具") {
                        NavigationLink {
                            ColorConverterView()
                        } label: {
                            MoreCardRow(
                                icon: "paintpalette",
                                iconColor: Theme.ColorToken.Morandi.mauve,
                                title: "色号转换",
                                subtitle: "不同品牌间的色号对照",
                                trailing: .chevron
                            )
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            CustomColorsView()
                        } label: {
                            MoreCardRow(
                                icon: "eyedropper.halffull",
                                iconColor: Theme.ColorToken.Morandi.mauve,
                                title: "自定义色号",
                                subtitle: "添加和管理自定义色号",
                                trailing: .chevron
                            )
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            HistoryView()
                        } label: {
                            MoreCardRow(
                                icon: "sparkles",
                                iconColor: Theme.ColorToken.Morandi.honey,
                                title: "历史记录",
                                subtitle: "查看操作记录，支持撤回",
                                trailing: .new
                            )
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            ProjectorConnectView()
                        } label: {
                            MoreCardRow(
                                icon: "videoprojector",
                                iconColor: Theme.ColorToken.Morandi.mauve,
                                title: "投影仪",
                                subtitle: "将拼图画面投送到投影仪",
                                trailing: .chevron,
                                isLast: true
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.bottom, 18)

                    // Group 2.5 — 外观
                    groupCard(title: String(localized: "color_mode.entry.group_title")) {
                        NavigationLink {
                            ColorModeView()
                        } label: {
                            MoreCardRow(
                                icon: "circle.lefthalf.filled",
                                iconColor: Theme.ColorToken.Morandi.mauve,
                                title: String(localized: "color_mode.title"),
                                subtitle: String(localized: "color_mode.entry.subtitle"),
                                trailing: .chevron,
                                isLast: true
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.bottom, 18)

                    // Group 3 — 数据 & 同步
                    groupCard(title: "数据 & 同步") {
                        cloudStatusRow

                        if cloudSyncStatusManager.shouldAllowManualRefresh {
                            Button {
                                cloudSyncStatusManager.refreshAccountStatus(force: true)
                            } label: {
                                MoreCardRow(
                                    icon: "arrow.clockwise",
                                    iconColor: Theme.ColorToken.Morandi.mist,
                                    title: "刷新 iCloud 状态",
                                    subtitle: cloudSyncStatusManager.isCheckingAccount ? "正在检查…" : "重新检查 iCloud 账户",
                                    trailing: .chevron
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(cloudSyncStatusManager.isCheckingAccount)
                        }

                        cloudSyncToggleRow

                        NavigationLink {
                            DataToolsView()
                        } label: {
                            MoreCardRow(
                                icon: "square.and.arrow.up.on.square",
                                iconColor: Theme.ColorToken.Morandi.mist,
                                title: "数据中心",
                                subtitle: "导入导出与备份恢复",
                                trailing: .chevron
                            )
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            DiagnosticsToolsView()
                        } label: {
                            MoreCardRow(
                                icon: "stethoscope",
                                iconColor: Theme.ColorToken.Morandi.mist,
                                title: "诊断工具",
                                subtitle: "日志导出与排查",
                                trailing: .chevron,
                                isLast: true
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.bottom, 18)

                    // Group 4 — 识别 & 帮助
                    groupCard(title: "识别 & 帮助") {
                        NavigationLink {
                            SettingsView()
                        } label: {
                            MoreCardRow(
                                icon: "sparkles",
                                iconColor: Theme.ColorToken.Morandi.mauve,
                                title: "AI 图像识别",
                                subtitle: "识别、库存等配置",
                                trailing: .chevron
                            )
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            BrandSettingsView()
                        } label: {
                            MoreCardRow(
                                icon: "tag.fill",
                                iconColor: Theme.ColorToken.Morandi.rose,
                                title: "品牌管理",
                                subtitle: "添加、编辑品牌信息",
                                trailing: .chevron
                            )
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            HelpCenterView()
                        } label: {
                            MoreCardRow(
                                icon: "book.fill",
                                iconColor: Theme.ColorToken.Morandi.mist,
                                title: String(localized: "help.center.entry.title"),
                                subtitle: String(localized: "help.center.entry.subtitle"),
                                trailing: .chevron
                            )
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            AboutView()
                        } label: {
                            MoreCardRow(
                                icon: "info.circle.fill",
                                iconColor: Theme.ColorToken.Morandi.latte,
                                title: "关于",
                                subtitle: "版本信息",
                                trailing: .chevron,
                                isLast: true
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.bottom, 18)

                    footerView
                        .padding(.top, 4)
                        .padding(.bottom, 24)
                }
            }
            .background(Theme.ColorToken.Surface.background.ignoresSafeArea())
            .scrollContentBackground(.hidden)
            .navigationTitle("更多")
            .navigationBarTitleDisplayMode(.inline)
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

    // MARK: - Hero card

    private var heroCard: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Theme.ColorToken.Morandi.latte,
                                Theme.ColorToken.Morandi.honey
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 52, height: 52)
                BeadView(color: .white, size: 30)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("我的数据")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.ColorToken.Text.primary)
                Text("已记录 \(totalBeadsCount) 颗 · 完成 \(completedProjectsCount) 件作品")
                    .font(.caption2)
                    .foregroundColor(Theme.ColorToken.Text.secondary)
            }

            Spacer(minLength: 8)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.ColorToken.Surface.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
        )
        .padding(.horizontal, 18)
    }

    // MARK: - Group card helper

    @ViewBuilder
    private func groupCard<Content: View>(
        title: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.ColorToken.Text.primary)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 4)
            }
            VStack(spacing: 0) {
                content()
            }
            .background(Theme.ColorToken.Surface.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
            )
            .padding(.horizontal, 18)
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack(spacing: 6) {
            BeadView(color: Theme.ColorToken.Morandi.latte, size: 12)
            Text("啃豆小仓 v\(appVersion)")
                .font(.caption2)
                .foregroundColor(Theme.ColorToken.Text.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - iCloud rows

    private var cloudStatusRow: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(cloudSyncStatusManager.statusColor.opacity(0.15))
                    .frame(width: 34, height: 34)
                Image(systemName: cloudSyncStatusManager.statusIconName)
                    .font(.system(size: 18))
                    .foregroundColor(cloudSyncStatusManager.statusColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(cloudSyncStatusManager.primaryStatusText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Theme.ColorToken.Text.primary)

                    if cloudSyncStatusManager.isCheckingAccount {
                        ProgressView().scaleEffect(0.8)
                    }
                }

                Text(cloudSyncStatusManager.secondaryStatusText)
                    .font(.caption2)
                    .foregroundColor(Theme.ColorToken.Text.secondary)

                Text("提示：iCloud 同步不是实时的，跨设备同步通常需要几秒到几分钟。")
                    .font(.caption2)
                    .foregroundColor(Theme.ColorToken.Text.tertiary)

                if let checkedAt = cloudSyncStatusManager.lastCheckedAt {
                    Text("上次检查：\(checkedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundColor(Theme.ColorToken.Text.tertiary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.ColorToken.Border.divider)
                .frame(height: 1)
                .padding(.leading, 60)
        }
    }

    private var cloudSyncToggleRow: some View {
        let binding = Binding<Bool>(
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
        )

        let subtitle: String = {
            if hasPendingCloudSyncChange {
                return String(localized: "已修改，关闭并重新打开 App 后生效。")
            } else if cloudSyncDisabled {
                return String(localized: "当前仅使用本地存储，iCloud 上原有的数据未删除。")
            } else {
                return String(localized: "关闭后 App 将不再读写 iCloud，仅使用本地存储。")
            }
        }()

        return MoreCardRow(
            icon: "icloud",
            iconColor: Theme.ColorToken.Morandi.mist,
            title: String(localized: "启用 iCloud 同步"),
            subtitle: subtitle,
            subtitleColor: hasPendingCloudSyncChange ? Theme.ColorToken.Status.warning : nil,
            trailing: .toggle(binding)
        )
    }
}

// MARK: - Row component

private enum MoreCardRowTrailing {
    case chevron
    case badge(String)
    case toggle(Binding<Bool>)
    case meta(String)
    case new
    case none
}

private struct MoreCardRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String?
    var subtitleColor: Color? = nil
    var trailing: MoreCardRowTrailing = .chevron
    var isLast: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(iconColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(Theme.ColorToken.Text.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(subtitleColor ?? Theme.ColorToken.Text.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            trailingView
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(Theme.ColorToken.Border.divider)
                    .frame(height: 1)
                    .padding(.leading, 60)
            }
        }
    }

    @ViewBuilder
    private var trailingView: some View {
        switch trailing {
        case .chevron:
            Image(systemName: "chevron.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.ColorToken.Text.tertiary)
        case .badge(let text):
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundColor(Theme.ColorToken.Text.onAccent)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(Theme.ColorToken.Status.warning)
                )
        case .toggle(let binding):
            Toggle("", isOn: binding)
                .labelsHidden()
                .tint(Theme.ColorToken.Morandi.sage)
        case .meta(let text):
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundColor(Theme.ColorToken.Status.success)
        case .new:
            Text("NEW")
                .font(.caption2.weight(.bold))
                .foregroundColor(Theme.ColorToken.Text.onAccent)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(Theme.ColorToken.Morandi.honey)
                )
        case .none:
            EmptyView()
        }
    }
}

struct DataToolsView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var showingImportFullData = false
    @State private var showingBackupRestore = false
    @State private var showingExportSheet = false

    var body: some View {
        VStack(spacing: 0) {
            BISecondaryNav(title: "数据与备份")
            ScrollView {
                VStack(spacing: 18) {
                    BIGroupCard(title: "导入导出") {
                        BIListRow(
                            icon: "square.and.arrow.up.fill",
                            iconColor: Theme.ColorToken.Morandi.mist,
                            title: "导出库存数据",
                            subtitle: "导出为 CSV 或 JSON 文件",
                            trailing: .chevron,
                            action: { showingExportSheet = true }
                        )
                        BIListRow(
                            icon: "arrow.down.doc.fill",
                            iconColor: Theme.ColorToken.Morandi.sage,
                            title: "导入历史数据",
                            subtitle: "从备份文件恢复全部数据",
                            trailing: .chevron,
                            isLast: true,
                            action: { showingImportFullData = true }
                        )
                    }

                    BIGroupCard(title: "备份恢复", footer: "涉及全量数据修改时，建议先导出库存数据留存。") {
                        BIListRow(
                            icon: "arrow.clockwise.icloud.fill",
                            iconColor: Theme.ColorToken.Morandi.mauve,
                            title: "恢复备份",
                            subtitle: "从自动备份恢复数据",
                            trailing: .chevron,
                            isLast: true,
                            action: { showingBackupRestore = true }
                        )
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .background(Theme.ColorToken.Surface.background)
        .navigationBarHidden(true)
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
        VStack(spacing: 0) {
            BISecondaryNav(title: "诊断工具")
            ScrollView {
                VStack(spacing: 18) {
                    BIGroupCard(title: "诊断日志") {
                        BIListRow(
                            icon: "doc.text.magnifyingglass",
                            iconColor: Theme.ColorToken.Morandi.mauve,
                            title: "导出诊断日志",
                            subtitle: isExportingDiagnostics ? "正在导出…" : "仅在排查问题时导出给开发者",
                            trailing: .chevron,
                            action: {
                                guard !isExportingDiagnostics && !isClearingDiagnostics else { return }
                                exportDiagnosticsLogs()
                            }
                        )
                        BIListRow(
                            icon: "trash.circle.fill",
                            iconColor: Theme.ColorToken.Status.error,
                            title: "清空诊断日志",
                            subtitle: isClearingDiagnostics ? "正在清空…" : "只清空本机日志，不影响库存数据",
                            trailing: .chevron,
                            isLast: true,
                            action: {
                                guard !isExportingDiagnostics && !isClearingDiagnostics else { return }
                                showingClearDiagnosticsAlert = true
                            }
                        )
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .background(Theme.ColorToken.Surface.background)
        .navigationBarHidden(true)
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
