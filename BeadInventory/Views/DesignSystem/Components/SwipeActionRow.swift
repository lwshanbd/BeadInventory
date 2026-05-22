//
//  SwipeActionRow.swift
//  BeadInventory
//
//  自定义左滑揭示按钮组件。
//
//  动机：SwiftUI 内置的 .swipeActions(edge:) 只能挂在 List 上。本项目里大多数
//  列表是 ScrollView + LazyVStack（避免 "List 嵌在 ScrollView 中" 要手算高度的
//  反模式），所以无法直接使用。
//
//  手势策略（关于竖滚被吃的折中）：
//  - 想"绝对干净"地交给外层 ScrollView 处理竖滚，理想做法是用
//    UIPanGestureRecognizer + UIGestureRecognizerDelegate.gestureRecognizerShouldBegin
//    按初始 velocity 方向决定是否 begin。
//  - 但这要求 pan 挂在 SwiftUI 内容的 UIKit 祖先节点上 —— .background / .overlay
//    都是兄弟节点拿不到触摸；唯一可行的是 UIHostingController 包内容，而
//    per-row UIHostingController 在 LazyVStack 里 sizing 完全崩盘（试过，
//    所有行高度坍成一道横线）。
//  - 折中：用 SwiftUI DragGesture，把 minimumDistance 拉到 28pt（明显大于
//    UIScrollView 的 ~10pt pan 阈值，让 ScrollView 在竖向手势上先一步认领），
//    并加横向 dominance 检查（|dx| > |dy| × 1.8）。极端边角情况下竖滚可能仍
//    会被短暂吃住，但不会破坏布局，比 UIHostingController 路线安全得多。
//
//  视觉：
//  - 按钮区单独 clipShape 出独立圆角矩形（左右都圆），不和 content 共享外层
//    clip——否则单按钮场景下按钮左缘贴在行中间会是直角。
//  - 揭示后再次 tap 内容会自动收起。
//  - 通过 .accessibilityAction(named:) 暴露给 VoiceOver。
//

import SwiftUI

/// 单个左滑按钮的描述。
struct SwipeActionItem {
    let label: LocalizedStringKey
    let systemImage: String
    let tint: Color
    let role: ButtonRole?
    let handler: () -> Void

    init(
        _ label: LocalizedStringKey,
        systemImage: String,
        tint: Color,
        role: ButtonRole? = nil,
        handler: @escaping () -> Void
    ) {
        self.label = label
        self.systemImage = systemImage
        self.tint = tint
        self.role = role
        self.handler = handler
    }
}

struct SwipeActionRow<Content: View>: View {
    private let actions: [SwipeActionItem]
    private let cornerRadius: CGFloat
    private let content: Content

    init(
        actions: [SwipeActionItem],
        cornerRadius: CGFloat = 14,
        @ViewBuilder content: () -> Content
    ) {
        self.actions = actions
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    /// 每个按钮的宽度，参考 iOS 原生 swipeActions
    private let actionWidth: CGFloat = 76
    /// DragGesture 启动门槛，明显大于 UIScrollView 内部 pan 的触发阈值（~10pt）。
    private let dragMinimumDistance: CGFloat = 28
    /// 横向认领的强度要求：必须明显大于竖向位移（1.8×）才接管。
    private let horizontalDominanceRatio: CGFloat = 1.8
    private var revealedWidth: CGFloat { actionWidth * CGFloat(actions.count) }

    @State private var offset: CGFloat = 0
    @State private var dragStartOffset: CGFloat = 0
    @State private var gestureActive: Bool = false

    var body: some View {
        ZStack(alignment: .trailing) {
            buttonsLayer
            contentLayer
        }
        // 注意：这里不再统一 clipShape ——
        // - content 的圆角由调用方在内容的 background 上自己画 RoundedRectangle 提供；
        // - buttons 区域单独 clip，避免单按钮场景下「左缘贴在行中间」是直角。
        .simultaneousGesture(dragGesture)
        .modifier(SwipeAccessibilityActionsModifier(actions: actions))
    }

    private var buttonsLayer: some View {
        HStack(spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                Button(role: action.role) {
                    action.handler()
                    snapClosed()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: action.systemImage)
                            .font(.system(size: 18, weight: .semibold))
                        Text(action.label)
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(width: actionWidth)
                    .frame(maxHeight: .infinity)
                    .background(action.tint)
                }
                .buttonStyle(.plain)
            }
        }
        // 单独 clip 出独立圆角，左右都圆。揭示宽度 = revealedWidth，
        // 整个按钮组作为一个 pill 浮在 content 旁边。
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        // 收起状态下隐藏按钮（也禁用其点击）：避免按钮被覆盖时仍可被 hit-test
        .opacity(offset < 0 ? 1 : 0)
        .allowsHitTesting(offset < 0)
    }

    private var contentLayer: some View {
        content
            .offset(x: offset)
            .overlay {
                // 揭示状态下要让 buttonsLayer 能收到点击。
                //
                // 坑：SwiftUI 的 .offset() 只影响渲染，不影响 hit-test 区域 ——
                // content 在 layout 里依然占满整行宽度。如果直接用 Color.clear
                // 全覆盖 overlay，用户点按钮位置命中的是 content 上这层 overlay
                // 触发 snapClosed()、按钮的 handler 根本不会跑。
                //
                // 解决：把 overlay 拆成左右两段。左段 (rowWidth - revealedWidth)
                // 接管「点 content 区收起」，右段 (revealedWidth) 禁用 hit-testing
                // 让点击穿透到 ZStack 后面的 buttonsLayer。
                if offset < 0 {
                    HStack(spacing: 0) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { snapClosed() }
                        Color.clear
                            .frame(width: revealedWidth)
                            .allowsHitTesting(false)
                    }
                }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: dragMinimumDistance)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                // 防 latching：SwiftUI DragGesture 没有 .onCancelled/.onInterrupted。
                // 父 TabView 抢手势、contextMenu 长按竞争退出、LazyVStack 行重排、dialog
                // 打断等场景下 onEnded 可能不发，gestureActive 卡在 true。表现：下一次
                // 拖动 if !gestureActive 跳过、任意方向直接平移行，整个 dominance 检查作废。
                //
                // 修法：只要这次 onChanged 时行还没动过（offset 等于 dragStartOffset），
                // 就强制重新走 dominance 检查 —— 即便上一次 gestureActive 残留 true，
                // 也要在新 drag 的开头自我证明一遍方向。
                let atRest = offset == dragStartOffset
                if !gestureActive || atRest {
                    guard abs(dx) > abs(dy) * horizontalDominanceRatio else {
                        gestureActive = false
                        return
                    }
                    gestureActive = true
                }
                let candidate = dragStartOffset + dx
                // 仅允许向左揭示；轻微 over-drag 给视觉反馈，但 clip 在 1.15 倍
                offset = min(0, max(-revealedWidth * 1.15, candidate))
            }
            .onEnded { _ in
                let wasActive = gestureActive
                gestureActive = false
                guard wasActive else { return }
                withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) {
                    offset = offset < -revealedWidth / 2 ? -revealedWidth : 0
                    dragStartOffset = offset
                }
            }
    }

    private func snapClosed() {
        // 必须先重置 gestureActive：onChanged 把它设 true 后，按按钮 → 直接走 snapClosed
        // 而不经过 onEnded，残留的 true 会让下一次 drag 跳过开头的横向占主导判断，
        // 任意方向的拖都直接平移行。
        gestureActive = false
        withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) {
            offset = 0
            dragStartOffset = 0
        }
    }
}

/// 把 actions 列表批量挂成 .accessibilityAction(named:)，让 VoiceOver 可达。
private struct SwipeAccessibilityActionsModifier: ViewModifier {
    let actions: [SwipeActionItem]
    func body(content: Content) -> some View {
        actions.reduce(AnyView(content)) { acc, action in
            AnyView(acc.accessibilityAction(named: Text(action.label)) {
                action.handler()
            })
        }
    }
}
