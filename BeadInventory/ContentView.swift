//
//  ContentView.swift
//  BeadInventory
//
//  主界面 - TabView导航
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @EnvironmentObject var sharedImageManager: SharedImageManager
    @ObservedObject private var announcementManager = AnnouncementManager.shared
    @Binding var shouldOpenScan: Bool
    @State private var selectedTab = 0
    @State private var showingAddInventory = false

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
}

#Preview {
    ContentView()
        .environmentObject(InventoryManager())
        .environmentObject(SharedImageManager.shared)
}
