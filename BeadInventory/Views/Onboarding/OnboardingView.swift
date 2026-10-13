//
//  OnboardingView.swift
//  BeadInventory
//
//  开屏指导：第一次打开时翻几页截图，讲清楚建品牌 → 识别 → 拼图 → 补库存这条主线。
//
//  截图都是在模拟器里真实走一遍流程拍的，图纸是自己画的「立体小屋」，没有版权问题
//  （`tools/draw_onboarding_pattern.py` 能重新生成）。界面改版后截图会过时，
//  换图时整条流程重新走一遍再拍，别只换其中一张。截图裁掉了顶部状态栏。
//
//  新老用户都弹一次：初始加载完、没出错、且没看过。想再看可以去「帮助中心」。
//

import SwiftUI

struct OnboardingPage {
    enum Kind {
        /// 第一页：App 图标 + 欢迎语
        case cover
        /// 截图 + 一句标题 + 一段说明
        case screenshot(imageName: String, message: LocalizedStringKey)
    }

    let kind: Kind
    let title: LocalizedStringKey

    static func screenshot(_ imageName: String, title: LocalizedStringKey, message: LocalizedStringKey) -> OnboardingPage {
        OnboardingPage(kind: .screenshot(imageName: imageName, message: message), title: title)
    }
}

enum OnboardingContent {
    static let pages: [OnboardingPage] = [
        OnboardingPage(kind: .cover, title: "欢迎来到啃豆小仓 2.0"),
        .screenshot(
            "OnboardingBrand",
            title: "先添加品牌",
            message: "每个品牌的库存分开记。选好色号体系，再给每种颜色填一个初始数量。"
        ),
        .screenshot(
            "OnboardingCrop",
            title: "识别图纸",
            message: "在「工作台 → 识别」里选一张图纸，裁切时只保留色号和数量那一块，AI 会读出每种颜色要用多少颗。"
        ),
        .screenshot(
            "OnboardingResult",
            title: "核对识别结果",
            message: "识别不一定全对。左滑任意一行可以修改、更换品牌或删除，核对好再存为计划或扣减库存。"
        ),
        .screenshot(
            "OnboardingParts",
            title: "进入拼图模式",
            message: "识别完点「开始拼」。立体图纸选「多零件模式」，每个零件会被单独找出来。"
        ),
        .screenshot(
            "OnboardingBoard",
            title: "按颜色一种一种拼",
            message: "点一个色号，板上只亮这种颜色的位置。全部拼好后点「拼完了」。"
        ),
        .screenshot(
            "OnboardingProjector",
            title: "投影到拼豆板上",
            message: "有投影仪的话，在拼豆板页连接投影仪。四个角对准豆板后，当前色号的格子会直接亮在板子上。"
        ),
        .screenshot(
            "OnboardingRestock",
            title: "补充库存",
            message: "买了新豆子，在「库存」页点右下角的加号，选色号、填数量。缺哪些豆子可以在「计划」页查看补豆建议。"
        )
    ]
}

struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var currentPage = 0

    private let pages = OnboardingContent.pages
    private var isLastPage: Bool { currentPage == pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    onFinish()
                } label: {
                    Text("跳过")
                        .font(.body)
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                        .padding(.horizontal, Theme.Spacing.xl)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .opacity(isLastPage ? 0 : 1)
                .disabled(isLastPage)
            }
            .padding(.top, Theme.Spacing.sm)

            TabView(selection: $currentPage) {
                ForEach(pages.indices, id: \.self) { index in
                    OnboardingPageView(page: pages[index])
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            pageDots
                .padding(.bottom, Theme.Spacing.lg)

            Button {
                if isLastPage {
                    onFinish()
                } else {
                    withAnimation { currentPage += 1 }
                }
            } label: {
                Text(isLastPage ? "开始使用" : "继续")
                    .font(.headline)
                    .foregroundStyle(Theme.ColorToken.Text.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.lg)
                    .background(Theme.ColorToken.Fill.latte, in: Capsule())
            }
            .padding(.horizontal, Theme.Spacing.xxl)
            .padding(.bottom, Theme.Spacing.lg)
        }
        .background(Theme.ColorToken.Surface.background.ignoresSafeArea())
    }

    private var pageDots: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ForEach(pages.indices, id: \.self) { index in
                Capsule()
                    .fill(index == currentPage
                          ? Theme.ColorToken.Fill.latte
                          : Theme.ColorToken.Border.default)
                    .frame(width: index == currentPage ? 18 : 7, height: 7)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: currentPage)
    }
}

private struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        switch page.kind {
        case .cover:
            cover
        case .screenshot(let imageName, let message):
            screenshot(imageName: imageName, message: message)
        }
    }

    private var cover: some View {
        VStack(spacing: Theme.Spacing.xxl) {
            Spacer()
            Image("AppIconImage")
                .resizable()
                .scaledToFit()
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
            Text(page.title)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Theme.ColorToken.Text.primary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.xxl)
            Spacer()
            Spacer()
        }
    }

    private func screenshot(imageName: String, message: LocalizedStringKey) -> some View {
        VStack(spacing: Theme.Spacing.xl) {
            Image(imageName)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                .frame(maxHeight: .infinity)

            VStack(spacing: Theme.Spacing.sm) {
                Text(page.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.ColorToken.Text.primary)
                Text(message)
                    .font(.body)
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Theme.Spacing.xxl)
        }
        .padding(.top, Theme.Spacing.sm)
        .padding(.bottom, Theme.Spacing.xxl)
    }
}

#Preview {
    OnboardingView(onFinish: {})
}
