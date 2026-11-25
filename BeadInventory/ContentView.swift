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
    @ObservedObject private var localModelRemovalMigrator = LocalModelRemovalMigrator.shared
    @Binding var shouldOpenScan: Bool
    @State private var selectedTab = 0
    /// 系统给的横向尺寸档。标签栏那层被改成了窄屏（见 body 里 TabView 的注释），
    /// 各页要拿回原来的档，iPad 上该怎么排还怎么排。
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// 工作台停在「拼图」还是「识别」（见 `WorkshopView`）。外部唤起扫描时要切到识别。
    @AppStorage("workshopPage") private var workshopPage: String = ""
    @State private var showingAddInventory = false
    @State private var showingLocalFallbackConfirmation = false
    @State private var showingDisableCloudSyncConfirmation = false
    @State private var showingDisableCloudSyncDoneAlert = false
    @State private var showingRestoreFromBackupConfirmation = false
    @State private var showingBackupRestore = false
    /// 已确认从备份恢复，等空库放行加载完再弹恢复页。没加载完就恢复，
    /// 旧 JSON 备份会静默写不进去，随后空库加载又把内存清掉。
    @State private var pendingBackupRestore = false
    /// 同步暂停中查到 iCloud 账号其实可用：提示一次重开 App，本次启动只提示一次。
    @State private var showingRelaunchForICloudAlert = false
    @State private var hasShownRelaunchForICloudAlert = false
    /// 库存页是否处于多选态，由 InventoryView 通过 PreferenceKey 上报。
    /// 多选态下需要隐藏 FAB，避免与底部 MultiSelectActionBar（含"隐藏"按钮）重叠。
    @State private var inventoryInSelectMode = false
    /// 开屏指导看过没有。新老用户都弹一次，弹出条件见 `shouldShowOnboarding`。
    @AppStorage("onboardingShown") private var onboardingShown = false

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
                    .environment(\.horizontalSizeClass, horizontalSizeClass)
                    .tabItem {
                        Label("库存", systemImage: "square.grid.3x3.fill")
                    }
                    .tag(TabFlavor.inventory.rawValue)

                // 计划：还没扣减的项目
                PlannedProjectsView()
                    .environment(\.tabFlavor, .plan)
                    .environment(\.horizontalSizeClass, horizontalSizeClass)
                    .tabItem {
                        Label("计划", systemImage: "list.bullet.clipboard.fill")
                    }
                    .tag(TabFlavor.plan.rawValue)

                // 工作台：识别图纸、拼图模式
                WorkshopView(externalImage: $externalImage)
                    .environment(\.tabFlavor, .workshop)
                    .environment(\.horizontalSizeClass, horizontalSizeClass)
                    .tabItem {
                        Label("工作台", systemImage: "wand.and.stars")
                    }
                    .tag(TabFlavor.workshop.rawValue)

                // 记录：扣减过的项目 + 用量统计
                StatisticsView()
                    .environment(\.tabFlavor, .records)
                    .environment(\.horizontalSizeClass, horizontalSizeClass)
                    .tabItem {
                        Label("记录", systemImage: "book.closed.fill")
                    }
                    .tag(TabFlavor.records.rawValue)

                // 更多（包含色号转换和设置）
                MoreView()
                    .environment(\.tabFlavor, .more)
                    .environment(\.horizontalSizeClass, horizontalSizeClass)
                    .tabItem {
                        Label("更多", systemImage: "ellipsis.circle.fill")
                    }
                    .tag(TabFlavor.more.rawValue)
            }
            .tint(currentFlavor.color)
            // iPad 上标签栏跟手机一样放在底部。iPadOS 18 起系统默认把它挪到顶上，做成一个悬浮的胶囊，
            // 正好盖住工作台顶上的「拼图 | 识别」，用户点不到（用户反馈过）。
            // 标签栏按窄屏排就回到底部；各页在上面重新拿回系统给的档，不受影响。
            .environment(\.horizontalSizeClass, .compact)
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
                                .background(TabFlavor.inventory.fill, in: Circle())
                                .shadow(color: TabFlavor.inventory.fill.opacity(0.4), radius: 8, x: 0, y: 4)
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
                            // 内存库：磁盘上的库这次没打开，只有重启能解决。
                            // 重试读的还是这个空的内存库；问题也跟 iCloud 无关，关同步会永久关掉，所以都不给。
                            let isTemporaryStore = cloudSyncStatusManager.isUsingTemporaryStore
                            // 退出 iCloud 后系统清掉了本机的同步库：数据在 iCloud 上，重新登录才回得来。
                            // 「重试」读的还是空库，「关闭 iCloud 同步」也不对症，都不给。
                            let isClearedAfterICloudSignOut = !isTemporaryStore
                                && inventoryManager.initialLoadFoundUnexpectedEmptyStore
                                && isICloudSignedOut

                            Image(systemName: isClearedAfterICloudSignOut ? "icloud.slash.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(Theme.ColorToken.Status.warning)

                            Text(isClearedAfterICloudSignOut
                                 ? String(localized: "未登录 iCloud")
                                 : String(localized: "数据加载失败"))
                                .font(.headline)

                            if isClearedAfterICloudSignOut {
                                Text(String(localized: "本机的同步数据已被系统清除，iCloud 上的数据仍然保留。请在系统设置中登录 iCloud，然后重新打开 App，数据会自动同步回来。"))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            } else if isTemporaryStore {
                                Text(String(localized: "数据库暂时无法打开，当前为临时模式，改动不会保存。请重启应用再试。"))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            } else {
                                Text(errorMessage)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)

                                Text(iCloudHintForLoadingError())
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 8)
                            }

                            VStack(spacing: 10) {
                                if isClearedAfterICloudSignOut {
                                    Button(String(localized: "从备份恢复")) {
                                        showingRestoreFromBackupConfirmation = true
                                    }
                                    .buttonStyle(.borderedProminent)
                                } else if !isTemporaryStore {
                                    Button(String(localized: "重试")) {
                                        inventoryManager.retryInitialLoad(reason: "contentView.retryButton")
                                    }
                                    .buttonStyle(.borderedProminent)
                                }

                                Button(String(localized: "以本地模式继续")) {
                                    showingLocalFallbackConfirmation = true
                                }
                                .buttonStyle(.bordered)

                                if !isTemporaryStore && !isClearedAfterICloudSignOut {
                                    Button(String(localized: "关闭 iCloud 同步（需重启）")) {
                                        showingDisableCloudSyncConfirmation = true
                                    }
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                }
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
                    String(localized: "从备份恢复？"),
                    isPresented: $showingRestoreFromBackupConfirmation
                ) {
                    Button(String(localized: "选择备份")) {
                        pendingBackupRestore = true
                        inventoryManager.acceptEmptyStoreForBackupRestore()
                    }
                    Button(String(localized: "取消"), role: .cancel) {}
                } message: {
                    // App 没有去重：备份恢复插进来的是新记录，之后登录原账号，云端的旧记录也会同步回来。
                    Text(String(localized: "恢复后，这台设备将使用备份中的数据。如果之后再登录原来的 iCloud 账号，云端的数据也会同步回来，可能出现重复的品牌和项目。"))
                }
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
        // 挂在外层：确认恢复后空库会放行，加载遮罩随之消失，挂在遮罩上的 sheet 会跟着被收掉。
        .sheet(isPresented: $showingBackupRestore) {
            BackupRestoreView()
        }
        .onChange(of: inventoryManager.hasCompletedInitialLoad) { _, completed in
            guard pendingBackupRestore, completed, inventoryManager.initialLoadErrorMessage == nil else { return }
            pendingBackupRestore = false
            showingBackupRestore = true
        }
        // 关了 iCloud 云盘的用户第一次启动会被误判成没登录、暂停同步，界面可能是空的。
        // 只写在设置页里用户看不到，会以为数据丢了开始重录，下次启动云端数据回来就叠成两份。
        .onChange(of: cloudSyncStatusManager.accountStatus) { _, status in
            guard cloudSyncStatusManager.mode == .pausedNoICloud,
                  status == .available,
                  !hasShownRelaunchForICloudAlert else { return }
            hasShownRelaunchForICloudAlert = true
            showingRelaunchForICloudAlert = true
        }
        .alert(
            String(localized: "需要重新打开 App"),
            isPresented: $showingRelaunchForICloudAlert
        ) {
            Button(String(localized: "我知道了"), role: .cancel) {}
        } message: {
            Text(String(localized: "已检测到 iCloud 账号，但本次启动时未能确认，同步暂未开启。请上滑关闭 App 并重新打开，iCloud 中的数据会同步回来。"))
        }
        .fullScreenCover(isPresented: Binding(
            get: { shouldShowOnboarding },
            set: { if !$0 { onboardingShown = true } }
        )) {
            OnboardingView { onboardingShown = true }
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
        // 本地模型识别下线的一次性告知：识别方式变了（图片开始上云），以及清掉了多少残留
        .alert(
            localModelRemovalMigrator.pendingNotice?.title ?? "",
            isPresented: Binding(
                get: { localModelRemovalMigrator.pendingNotice != nil },
                set: { if !$0 { localModelRemovalMigrator.acknowledgeNotice() } }
            )
        ) {
            Button("我知道了") {
                localModelRemovalMigrator.acknowledgeNotice()
            }
        } message: {
            Text(localModelRemovalMigrator.pendingNotice?.message ?? "")
        }
        // 监听 URL Scheme 触发的扫描请求
        .onChange(of: shouldOpenScan) { _, newValue in
            if newValue {
                // 获取共享图片
                if let image = sharedImageManager.consumePendingImage() {
                    externalImage = image
                }
                // 切换到工作台（扫描）
                selectedTab = TabFlavor.workshop.rawValue
                workshopPage = WorkshopView.Page.scan.rawValue
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
                selectedTab = TabFlavor.workshop.rawValue
                workshopPage = WorkshopView.Page.scan.rawValue
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

    /// 什么时候弹开屏指导：
    /// - 加载完且没出错，免得盖住「正在加载」和加载失败的提示；
    /// - 不在「以本地模式继续」里。那时改了也不保存，指导却让人去建品牌、填库存；
    ///   等真正加载成功、退出回退模式后再弹；
    /// - 公告和「本地模型下线」这类一次性提示先弹完。它们跟开屏指导挂在同一个视图上，
    ///   同时弹会被挤掉，而下线提示的迁移标记已经写了，挤掉就再也看不到。
    private var shouldShowOnboarding: Bool {
        !onboardingShown
            && inventoryManager.hasCompletedInitialLoad
            && inventoryManager.initialLoadErrorMessage == nil
            && !inventoryManager.isUsingLocalFallbackMode
            && announcementManager.currentAnnouncement == nil
            && localModelRemovalMigrator.pendingNotice == nil
    }

    /// 设备当前没登录 iCloud：启动时就没登录（同步已暂停），或者开着同步但账号查下来是没登录。
    /// 暂停模式也要看账号：关了 iCloud 云盘的用户会被误判成没登录而暂停，账号其实可用。
    /// 这时候说「未登录」是错的，给「从备份恢复」更糟：之后云端数据同步回来会跟备份叠成两份。
    private var isICloudSignedOut: Bool {
        switch cloudSyncStatusManager.mode {
        case .pausedNoICloud:
            return cloudSyncStatusManager.accountStatus != .available
        case .iCloudEnabled:
            return cloudSyncStatusManager.accountStatus == .noAccount
        case .localFallback:
            return false
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
        case .pausedNoICloud:
            if cloudSyncStatusManager.accountStatus == .available {
                return String(localized: "已检测到 iCloud 账号，请关闭并重新打开 App，iCloud 中的数据会同步回来。")
            }
            return String(localized: "未登录 iCloud，同步已暂停。登录 iCloud 后重新打开 App 即可恢复同步。")
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
