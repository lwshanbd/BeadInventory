//
//  ContentView.swift
//  BeadInventory
//
//  主界面 - TabView导航
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var selectedTab = 0
    @State private var showingAddInventory = false

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
                ScanView()
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

            // 右侧浮动加号按钮
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
        .sheet(isPresented: $showingAddInventory) {
            AddInventoryView()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(InventoryManager())
}
