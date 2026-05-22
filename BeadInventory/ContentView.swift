//
//  ContentView.swift
//  BeadInventory
//
//  主界面 - TabView导航
//

import SwiftUI
import CloudKit

struct ContentView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @EnvironmentObject var sharedImageManager: SharedImageManager
    @EnvironmentObject var cloudSyncStatusManager: CloudSyncStatusManager
    @ObservedObject private var announcementManager = AnnouncementManager.shared
    @Binding var shouldOpenScan: Bool
    @State private var selectedTab = 0
    @State private var showingAddInventory = false
    @State private var showingLocalFallbackConfirmation = false
    @State private var showingDisableCloudSyncConfirmation = false
    @State private var showingDisableCloudSyncDoneAlert = false
    /// 库存页是否处于多选态，由 InventoryView 通过 PreferenceKey 上报。
    /// 多选态下需要隐藏 FAB，避免与底部 MultiSelectActionBar（含"隐藏"按钮）重叠。
    @State private var inventoryInSelectMode = false

    /// 从 Share Extension 传入的图片
    @State private var externalImage: UIImage?

    init(shouldOpenScan: Binding<Bool> = .constant(false)) {
        self._shouldOpenScan = shouldOpenScan
    }

    var body: some View {
        let currentFlavor = TabFlavor(rawValue: selectedTab) ?? .inventory
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                // 库存管理
                InventoryView()
                    .environment(\.tabFlavor, .inventory)
                    .tabItem {
                        Label("库存", systemImage: "square.grid.3x3.fill")
                    }
                    .tag(0)

                // 工作台（扫描 + 计划合并到同一个 Tab）
                WorkshopView(externalImage: $externalImage)
                    .environment(\.tabFlavor, .workshop)
                    .tabItem {
                        Label("工作台", systemImage: "wand.and.stars")
                    }
                    .tag(1)

                // 统计
                StatisticsView()
                    .environment(\.tabFlavor, .statistics)
                    .tabItem {
                        Label("统计", systemImage: "chart.bar.fill")
                    }
                    .tag(2)

                // 更多（包含色号转换和设置）
                MoreView()
                    .environment(\.tabFlavor, .more)
                    .tabItem {
                        Label("更多", systemImage: "ellipsis.circle.fill")
                    }
                    .tag(3)
            }
            .tint(currentFlavor.color)
            .onPreferenceChange(SelectModeActivePreferenceKey.self) { active in
                withAnimation(.easeInOut(duration: 0.2)) {
                    inventoryInSelectMode = active
                }
            }

            // 右侧浮动加号按钮（仅在库存页显示；多选态下隐藏，避免与底部"隐藏"操作条重叠）
            if selectedTab == 0 && !inventoryInSelectMode {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button { showingAddInventory = true } label: {
                            Image(systemName: "plus")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 60, height: 60)
                                .background(TabFlavor.inventory.color, in: Circle())
                                .shadow(color: TabFlavor.inventory.color.opacity(0.4), radius: 8, x: 0, y: 4)
                        }
                        .padding(.trailing, 20)
                        .padding(.bottom, 80)
                    }
                }
            }

            if !inventoryManager.hasCompletedInitialLoad {
                ZStack {
                    Theme.ColorToken.Surface.background
                        .opacity(0.96)
                        .ignoresSafeArea()

                    VStack(spacing: 16) {
                        if let errorMessage = inventoryManager.initialLoadErrorMessage {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(Theme.ColorToken.Status.warning)

                            Text(String(localized: "数据加载失败"))
                                .font(.headline)

                            Text(errorMessage)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)

                            Text(iCloudHintForLoadingError())
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 8)

                            VStack(spacing: 10) {
                                Button(String(localized: "重试")) {
                                    inventoryManager.retryInitialLoad(reason: "contentView.retryButton")
                                }
                                .buttonStyle(.borderedProminent)

                                Button(String(localized: "以本地模式继续")) {
                                    showingLocalFallbackConfirmation = true
                                }
                                .buttonStyle(.bordered)

                                Button(String(localized: "关闭 iCloud 同步（需重启）")) {
                                    showingDisableCloudSyncConfirmation = true
                                }
                                .font(.footnote)
                                .foregroundColor(.secondary)
                            }
                        } else {
                            ProgressView()
                                .progressViewStyle(.circular)

                            Text(String(localized: "正在加载数据..."))
                                .font(.headline)

                            Text(String(localized: "首次启动或 iCloud 同步中可能需要几秒钟。"))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(24)
                }
                .transition(.opacity)
                .alert(
                    String(localized: "以本地模式继续？"),
                    isPresented: $showingLocalFallbackConfirmation
                ) {
                    Button(String(localized: "继续浏览（不保存修改）")) {
                        inventoryManager.continueInLocalFallbackMode(reason: "contentView.localFallbackButton")
                    }
                    Button(String(localized: "取消"), role: .cancel) {}
                } message: {
                    Text(String(localized: "将解除等待屏蔽，可浏览当前可见的数据。为避免覆盖 iCloud 上未读取到的数据，本次会话不会保存任何修改；下次启动或 iCloud 恢复后会自动重试加载。"))
                }
                .alert(
                    String(localized: "关闭 iCloud 同步？"),
                    isPresented: $showingDisableCloudSyncConfirmation
                ) {
                    Button(String(localized: "关闭并重启 App"), role: .destructive) {
                        CloudSyncPreferences.userOptedOut = true
                        showingDisableCloudSyncDoneAlert = true
                    }
                    Button(String(localized: "取消"), role: .cancel) {}
                } message: {
                    Text(String(localized: "App 将仅使用本地存储，所有修改不会再同步到 iCloud。iCloud 上原有的数据不会被删除，可在「更多 → 数据与同步」中重新启用同步。需要关闭并重新打开 App 生效。"))
                }
                .alert(
                    String(localized: "已关闭 iCloud 同步"),
                    isPresented: $showingDisableCloudSyncDoneAlert
                ) {
                    Button(String(localized: "我知道了"), role: .cancel) {}
                } message: {
                    Text(String(localized: "请上滑关闭 App 并重新打开，本地模式即可生效。"))
                }
            }
        }
        .sheet(isPresented: $showingAddInventory) {
            AddInventoryView()
        }
        // 远程公告弹窗
        .alert(
            announcementManager.currentAnnouncement?.title ?? "",
            isPresented: Binding(
                get: { announcementManager.currentAnnouncement != nil },
                set: { if !$0 { announcementManager.dismiss() } }
            )
        ) {
            Button("我知道了") {
                announcementManager.dismiss()
            }
        } message: {
            Text(announcementManager.currentAnnouncement?.message ?? "")
        }
        // 监听 URL Scheme 触发的扫描请求
        .onChange(of: shouldOpenScan) { _, newValue in
            if newValue {
                // 获取共享图片
                if let image = sharedImageManager.consumePendingImage() {
                    externalImage = image
                }
                // 切换到扫描 Tab
                selectedTab = 1
                // 重置标志
                shouldOpenScan = false
            }
        }
        // 监听共享图片管理器的状态
        .onChange(of: sharedImageManager.hasPendingImage) { _, hasPending in
            if hasPending {
                // 有新的共享图片，切换到扫描页
                if let image = sharedImageManager.consumePendingImage() {
                    externalImage = image
                }
                selectedTab = 1
            }
        }
        // App 进入前台时检查是否有待处理的图片
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            sharedImageManager.checkForPendingImage()
        }
        // App 变为活跃状态时也检查（处理从 Share Extension 返回的情况）
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            sharedImageManager.checkForPendingImage()
        }
        // 视图首次出现时检查（处理冷启动）
        .onAppear {
            // 延迟一点检查，确保视图已准备好
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                sharedImageManager.checkForPendingImage()
            }
        }
    }

    /// 在持久层加载失败时，根据 iCloud 账号状态给出更具体的提示。
    /// 注意：iCloud 配额已满通常不会让 ModelContainer 初始化失败，
    /// 因此这里只能提示常见的账号/服务问题，配额的最终判断仍需用户查看 iCloud 设置。
    private func iCloudHintForLoadingError() -> String {
        let generalHint = String(localized: "若 iCloud 空间已满或同步异常，可前往「设置 → Apple ID → iCloud」检查空间，或选择以本地模式继续。")
        switch cloudSyncStatusManager.mode {
        case .localFallback:
            return String(localized: "已自动回退为本地存储，云端数据将无法读取，本地数据可继续使用。")
        case .iCloudEnabled:
            switch cloudSyncStatusManager.accountStatus {
            case .noAccount:
                return String(localized: "未登录 iCloud，可能无法读取此前同步到云端的数据。")
            case .restricted:
                return String(localized: "iCloud 权限受限，无法完成同步。")
            case .temporarilyUnavailable:
                return String(localized: "iCloud 暂时不可用，请稍后重试。")
            case .available, .couldNotDetermine, .none:
                return generalHint
            @unknown default:
                return generalHint
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(InventoryManager())
        .environmentObject(SharedImageManager.shared)
        .environmentObject(CloudSyncStatusManager(mode: .iCloudEnabled))
}
