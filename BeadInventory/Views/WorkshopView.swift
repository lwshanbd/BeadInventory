//
//  WorkshopView.swift
//  BeadInventory
//
//  工作台 Tab —— 设计稿 4-Tab 架构：把「识别图纸」（ScanView）和「我的计划」（PlannedProjectsView）
//  合并到同一个 Tab 内，用顶部 sub-tabs 切换。运输入口暂留在「更多」。
//

import SwiftUI
import UIKit

struct WorkshopView: View {
    @Binding var externalImage: UIImage?
    @AppStorage("workshopSubTab") private var subTabRaw: String = SubTab.scan.rawValue

    enum SubTab: String, CaseIterable, Hashable {
        case scan = "scan"
        case plan = "plan"

        var label: String {
            switch self {
            case .scan: return "识别图纸"
            case .plan: return "我的计划"
            }
        }
    }

    private var subTab: Binding<SubTab> {
        Binding(
            get: { SubTab(rawValue: subTabRaw) ?? .scan },
            set: { subTabRaw = $0.rawValue }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部 sub-tab 切换条
            HStack {
                BISegmented(
                    selection: subTab,
                    segments: SubTab.allCases.map { ($0, $0.label) },
                    fillWidth: false
                )
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .background(Theme.ColorToken.Surface.background)

            // 内容
            // 注意：不要用 `switch subTab.wrappedValue` 直接选视图 ——
            // 那样切到 plan 再切回 scan 时 ScanView 会被销毁重建，
            // selectedImage / recognizedItems 等 @State 全部丢失。
            // 用 ZStack + opacity 让两个子视图都常驻，仅切换可见性。
            ZStack {
                ScanView(externalImage: $externalImage)
                    .opacity(subTab.wrappedValue == .scan ? 1 : 0)
                    .allowsHitTesting(subTab.wrappedValue == .scan)
                    .accessibilityHidden(subTab.wrappedValue != .scan)
                PlannedProjectsView()
                    .opacity(subTab.wrappedValue == .plan ? 1 : 0)
                    .allowsHitTesting(subTab.wrappedValue == .plan)
                    .accessibilityHidden(subTab.wrappedValue != .plan)
            }
        }
        .background(Theme.ColorToken.Surface.background)
    }
}
