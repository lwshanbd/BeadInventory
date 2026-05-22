//
//  SwipeActionRow.swift
//  BeadInventory
//
//  自定义左滑揭示按钮组件。
//
//  动机：SwiftUI 内置的 .swipeActions(edge:) 只能挂在 List 上。本项目里大多数
//  列表是 ScrollView + LazyVStack（避免 "List 嵌在 ScrollView 中" 要手算高度的
//  反模式），所以无法直接使用。该组件用 DragGesture 复刻同等交互，可放在任何
//  容器里。
//
//  关键点：
//  - 仅在横向位移占主导（|dx| > |dy|）时认领手势，避免吞掉外层 ScrollView 的
//    竖向滚动。simultaneousGesture 让父级 ScrollView 始终能收到事件。
//  - 揭示后再次 tap 内容会自动收起。
//  - 通过 .accessibilityAction(named:) 暴露给 VoiceOver，无障碍可达。
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
    /// 横向位移过此阈值才认领手势，避免误触
    private let activationThreshold: CGFloat = 8
    private var revealedWidth: CGFloat { actionWidth * CGFloat(actions.count) }

    @State private var offset: CGFloat = 0
    @State private var dragStartOffset: CGFloat = 0
    @State private var gestureActive: Bool = false

    var body: some View {
        ZStack(alignment: .trailing) {
            buttonsLayer
            contentLayer
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
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
        // 收起状态下隐藏按钮（也禁用其点击）：避免按钮被覆盖时仍可被 hit-test
        .opacity(offset < 0 ? 1 : 0)
        .allowsHitTesting(offset < 0)
    }

    private var contentLayer: some View {
        content
            .offset(x: offset)
            .overlay {
                // 已揭示时，覆盖一层透明视图吞掉内容上的点击，统一转为「先收起」
                if offset < 0 {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { snapClosed() }
                }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: activationThreshold)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                if !gestureActive {
                    // 还没接管：只有横向位移占主导才认领，否则让外层 ScrollView 滚
                    guard abs(dx) > abs(dy) else { return }
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
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
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
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
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
