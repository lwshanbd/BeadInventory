//
//  AboutView.swift
//  BeadInventory
//
//  关于啃豆小仓 —— 二级页骨架（SecondaryNav + ScrollView + GroupCard）。
//  本页主调色 = Morandi.latte（内部硬编码，不读 @Environment(\.tabFlavor)）。
//

import SwiftUI
import StoreKit
import UIKit

struct AboutView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var showingDataPolicy = false

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) · \(build)"
    }

    var body: some View {
        VStack(spacing: 0) {
            BISecondaryNav(title: "关于")
            ScrollView {
                VStack(spacing: 0) {
                    appIconHero
                    madeForYJCard
                    appDataGroup
                    creditsGroup
                    originalityCard
                    legalLinksGroup
                    icpFooter
                }
                .padding(.bottom, 24)
            }
        }
        .background(Theme.ColorToken.Surface.background)
        .navigationBarHidden(true)
        .sheet(isPresented: $showingDataPolicy) { DataUsagePolicyView() }
    }

    // MARK: - Hero

    private var appIconHero: some View {
        VStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Theme.ColorToken.Morandi.latte, Theme.ColorToken.Morandi.honey],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 110, height: 110)
                    .shadow(color: Theme.ColorToken.Morandi.latte.opacity(0.3), radius: 10, x: 0, y: 6)
                    .overlay {
                        BeadView(color: .white, size: 64)
                            .opacity(0.95)
                    }
                Circle()
                    .fill(Theme.ColorToken.Morandi.rose)
                    .frame(width: 30, height: 30)
                    .overlay(
                        Circle().strokeBorder(Theme.ColorToken.Surface.background, lineWidth: 4)
                    )
                    .offset(x: 6, y: 6)
            }
            .padding(.bottom, 2)

            Wordmark(size: 28)

            Text(appVersion)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.Text.tertiary)
                .tracking(0.5)
        }
        .padding(.top, 14)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Made for YJ

    private var madeForYJCard: some View {
        ZStack(alignment: .topTrailing) {
            // 装饰圆
            Circle()
                .fill(Theme.ColorToken.Morandi.rose.opacity(0.08))
                .frame(width: 100, height: 100)
                .offset(x: 20, y: -20)
                .clipped()

            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Theme.ColorToken.Morandi.rose.opacity(0.18))
                        .frame(width: 52, height: 52)
                    Image(systemName: "heart.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.ColorToken.Morandi.rose)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("MADE WITH LOVE FOR")
                        .font(.system(size: 11))
                        .tracking(1.2)
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                    Text("YJ")
                        .font(.custom("Georgia-BoldItalic", size: 30))
                        .foregroundStyle(Theme.ColorToken.Morandi.rose)
                        .tracking(0.5)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Theme.ColorToken.Surface.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 18)
        .padding(.bottom, 6)
    }

    // MARK: - 应用数据

    private var appDataGroup: some View {
        VStack(spacing: 0) {
            BIGroupHeader(title: "应用数据")
            BIGroupCard {
                HStack(spacing: 0) {
                    aboutStatCol(icon: "paintpalette.fill", label: "颜色", value: "\(inventoryManager.beadColors.count)")
                    aboutStatColDivider
                    aboutStatCol(icon: "square.grid.3x3.square", label: "品牌", value: "\(inventoryManager.brands.count)")
                    aboutStatColDivider
                    aboutStatCol(icon: "rectangle.stack", label: "项目", value: "\(inventoryManager.projects.count)")
                }
                .padding(.vertical, 14)
            }
        }
    }

    private func aboutStatCol(icon: String, label: String, value: String) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.ColorToken.Morandi.latte.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.Morandi.latte)
            }
            Text(value)
                .font(.system(size: 20, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.ColorToken.Text.primary)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.ColorToken.Text.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var aboutStatColDivider: some View {
        Rectangle()
            .fill(Theme.ColorToken.Border.divider)
            .frame(width: 1, height: 56)
    }

    // MARK: - 制作团队 / 致谢

    private var creditsGroup: some View {
        VStack(spacing: 0) {
            BIGroupHeader(title: "制作团队")
            BIGroupCard {
                BIListRow(
                    icon: "sparkle",
                    iconColor: Theme.ColorToken.Morandi.latte,
                    title: "BD",
                    subtitle: "开发者 · 独立设计 & 开发",
                    trailing: .meta("2026 →")
                )
                BIListRow(
                    icon: "pawprint.fill",
                    iconColor: Theme.ColorToken.Morandi.honey,
                    title: "啃宝 & Timea",
                    subtitle: "感谢两位猫猫的陪伴",
                    trailing: .meta("致谢"),
                    isLast: true
                )
            }
        }
    }

    // MARK: - 支持原创

    private var originalityCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.ColorToken.Morandi.honey)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("支持原创 · 拒绝抄袭")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.ColorToken.Text.primary)
                Text("啃豆小仓与每一份拼豆图纸都凝聚着创作者的心血。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                    .lineSpacing(2)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(
                    LinearGradient(
                        colors: [
                            Theme.ColorToken.Morandi.honey.opacity(0.20),
                            Theme.ColorToken.Surface.subtle
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
        )
        .padding(.horizontal, 18)
        .padding(.top, 18)
    }

    // MARK: - 法律链接

    private var legalLinksGroup: some View {
        VStack(spacing: 0) {
            BIGroupCard {
                BIListRow(
                    icon: "star",
                    iconColor: Theme.ColorToken.Morandi.mist,
                    title: "评分 & 反馈",
                    subtitle: "给个评分，帮我改进",
                    action: { requestAppReview() }
                )
                BIListRow(
                    icon: "lock.doc",
                    iconColor: Theme.ColorToken.Morandi.mist,
                    title: "数据使用声明",
                    action: { showingDataPolicy = true }
                )
                BIListRow(
                    icon: "book",
                    iconColor: Theme.ColorToken.Morandi.mist,
                    title: "隐私协议",
                    action: { openExternalURL("https://lwshanbd.github.io/BeadInventory/privacy.html") }
                )
                BIListRow(
                    icon: "book.closed",
                    iconColor: Theme.ColorToken.Morandi.mist,
                    title: "服务条款",
                    isLast: true,
                    action: { openExternalURL("https://lwshanbd.github.io/BeadInventory/terms.html") }
                )
            }
            .padding(.top, 18)
        }
    }

    private func requestAppReview() {
        // SKStoreReviewController 在 iOS 18+ 推荐用 RequestReviewAction（@Environment(\.requestReview)），
        // 但这里通过 windowScene 直接触发以避免在 helper 内引入环境读取。
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) {
            SKStoreReviewController.requestReview(in: scene)
        }
    }

    private func openExternalURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - ICP

    private var icpFooter: some View {
        VStack(spacing: 4) {
            Text("鲁ICP备2026003850号-1A")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.Text.tertiary)
                .tracking(0.4)
            Text("感谢使用啃豆小仓")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ColorToken.Text.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }
}

#Preview {
    NavigationStack {
        AboutView()
            .environmentObject(InventoryManager())
    }
}
