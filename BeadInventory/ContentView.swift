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

    /// 从 Share Extension 传入的图片
    @State private var externalImage: UIImage?

    init(shouldOpenScan: Binding<Bool> = .constant(false)) {
        self._shouldOpenScan = shouldOpenScan
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                // 库存管理
                InventoryView()
                    .tabItem {
                        Label("库存", systemImage: "square.grid.3x3.fill")
                    }
                    .tag(0)

                // 图纸导入
                ScanView(externalImage: $externalImage)
                    .tabItem {
                        Label("扫描", systemImage: "doc.text.viewfinder")
                    }
                    .tag(1)

                // 计划项目
                PlannedProjectsView()
                    .tabItem {
                        Label("计划", systemImage: "calendar.badge.clock")
                    }
                    .tag(2)

                // 统计
                StatisticsView()
                    .tabItem {
                        Label("统计", systemImage: "chart.bar.fill")
                    }
                    .tag(3)

                // 更多（包含色号转换和设置）
                MoreView()
                    .tabItem {
                        Label("更多", systemImage: "ellipsis.circle.fill")
                    }
                    .tag(4)
            }
            .tint(Color("AccentColor"))

            // 右侧浮动加号按钮（仅在库存页显示）
            if selectedTab == 0 {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        showingAddInventory = true
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 60, height: 60)
                                .shadow(color: Color.accentColor.opacity(0.4), radius: 8, x: 0, y: 4)

                            Image(systemName: "plus")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 80)
                }
            }
            }

            if !inventoryManager.hasCompletedInitialLoad {
                ZStack {
                    Color(.systemBackground)
                        .opacity(0.96)
                        .ignoresSafeArea()

                    VStack(spacing: 16) {
                        if let errorMessage = inventoryManager.initialLoadErrorMessage {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(.orange)

                            Text("数据加载失败")
                                .font(.headline)

                            Text(errorMessage)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)

                            if let hint = iCloudHintForLoadingError() {
                                Text(hint)
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 8)
                            }

                            VStack(spacing: 10) {
                                Button("重试") {
                                    inventoryManager.retryInitialLoad(reason: "contentView.retryButton")
                                }
                                .buttonStyle(.borderedProminent)

                                Button("以本地模式继续") {
                                    showingLocalFallbackConfirmation = true
                                }
                                .buttonStyle(.bordered)
                            }
                        } else {
                            ProgressView()
                                .progressViewStyle(.circular)

                            Text("正在加载数据...")
                                .font(.headline)

                            Text("首次启动或 iCloud 同步中可能需要几秒钟。")
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
                    Button(String(localized: "以本地模式继续"), role: .destructive) {
                        inventoryManager.continueInLocalFallbackMode(reason: "contentView.localFallbackButton")
                    }
                    Button(String(localized: "取消"), role: .cancel) {}
                } message: {
                    Text("将跳过本次 iCloud 同步并以当前内存中的数据继续使用。下次启动或 iCloud 恢复后，云端数据会自动合并回来。")
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
    private func iCloudHintForLoadingError() -> String? {
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
            case .available:
                return String(localized: "若 iCloud 空间已满或同步异常，可前往「设置 → Apple ID → iCloud」检查空间，或选择以本地模式继续。")
            case .couldNotDetermine, .none:
                return nil
            @unknown default:
                return nil
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
