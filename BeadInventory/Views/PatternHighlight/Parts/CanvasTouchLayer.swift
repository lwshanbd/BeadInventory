//
//  CanvasTouchLayer.swift
//  BeadInventory
//
//  「量格子」画布的手势层：单指拖动一套，双指（捏合 + 平移）一套。
//
//  为什么不用 SwiftUI 的 DragGesture + MagnifyGesture：
//  单指拖动要拿去挪网格了，平移图片只能交给双指。而 `MagnifyGesture` 在 iOS 17 上
//  只给得出「起点」和「放大倍数」，拿不到两根手指**现在**在哪 —— 双指平移做不出来。
//  `UIPinchGestureRecognizer.location(in:)` 直接就是两指中点。
//
//  还有一件 SwiftUI 那边管不了的事：第一根手指落下、拖了几个点之后第二根才到，
//  这时单指那一拖已经开始了。这里第二根手指一到就把单指那一拖**取消**
//  （`onOneFingerCancel`），由调用方把那几个点的挪动撤回去 —— 不然用户每次捏合，
//  网格都会被第一根手指顺手带歪一点。
//
//  单指那一套不用 `UIPanGestureRecognizer`：它要手指走出十来点才开始，
//  而推格线常常就是「往右挪小半格」—— 一格在屏幕上也就十几点，那一下根本拖不动。
//  `OneFingerDragRecognizer` 走出 1 点就开始。
//

import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

struct CanvasTouchLayer: UIViewRepresentable {
    /// 单指开始拖。参数是**落指**的位置（不是识别出来那一刻的位置），用来判断按在了什么上面。
    var onOneFingerBegan: (CGPoint) -> Void
    /// 相对落指点的位移（含系统起拖阈值那一段，手指走多远就是多远）
    var onOneFingerChanged: (CGSize) -> Void
    var onOneFingerEnded: () -> Void
    /// 第二根手指到了，这一拖作废
    var onOneFingerCancel: () -> Void
    /// 双指开始。参数是两指中点。
    var onTwoFingerBegan: (CGPoint) -> Void
    /// 两指中点 + 从开始到现在的缩放倍数
    var onTwoFingerChanged: (CGPoint, CGFloat) -> Void
    var onTwoFingerEnded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let c = context.coordinator

        let one = OneFingerDragRecognizer(target: c, action: #selector(Coordinator.handleOne(_:)))
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.handleTwo(_:)))
        let two = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.handleTwo(_:)))
        two.minimumNumberOfTouches = 2
        two.maximumNumberOfTouches = 2

        for r in [one, pinch, two] {
            r.delegate = c
            view.addGestureRecognizer(r)
        }
        c.one = one
        c.pinch = pinch
        c.two = two
        c.parent = self
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: CanvasTouchLayer?
        weak var one: OneFingerDragRecognizer?
        weak var pinch: UIPinchGestureRecognizer?
        weak var two: UIPanGestureRecognizer?
        private var oneActive = false
        private var twoActive = false
        /// 这一次双指里，之前几段捏合已经累计的倍数。捏合中途可能断了又重新认出来，
        /// 每次重新认出来 `pinch.scale` 都从 1 开始 —— 不接着乘的话画面会一下弹回去。
        private var scaleBase: CGFloat = 1
        private var scale: CGFloat = 1
        private var pinchWasLive = false

        @objc func handleOne(_ r: OneFingerDragRecognizer) {
            guard let parent else { return }
            switch r.state {
            case .began:
                oneActive = true
                parent.onOneFingerBegan(r.start)
                parent.onOneFingerChanged(r.offset)
            case .changed:
                guard oneActive else { return }
                parent.onOneFingerChanged(r.offset)
            case .ended:
                guard oneActive else { return }
                oneActive = false
                parent.onOneFingerEnded()
            case .cancelled, .failed:
                guard oneActive else { return }
                oneActive = false
                parent.onOneFingerCancel()
            default:
                break
            }
        }

        @objc func handleTwo(_ r: UIGestureRecognizer) {
            guard let view = r.view, let parent else { return }
            let pinchLive = pinch.map { $0.state == .began || $0.state == .changed } ?? false
            let twoLive = two.map { $0.state == .began || $0.state == .changed } ?? false
            // 取还在跟踪的那一个的中点：已经结束的那个报的是它停下时的位置
            let live: UIGestureRecognizer? = twoLive ? two : (pinchLive ? pinch : nil)
            let center = (live ?? r).location(in: view)

            if pinchLive || twoLive {
                if !twoActive {
                    twoActive = true
                    scaleBase = 1
                    scale = 1
                    pinchWasLive = false
                    // 单指那一拖作废。先同步通知调用方撤回，再切一下 isEnabled 让识别器
                    // 真的停下（它随后发来的 .cancelled 被 `oneActive` 挡掉，不会撤第二次）。
                    // 顺序不能反：调用方算双指的锚点要基于撤回之后的画面。
                    if oneActive, let one {
                        oneActive = false
                        parent.onOneFingerCancel()
                        one.isEnabled = false
                        one.isEnabled = true
                    }
                    parent.onTwoFingerBegan(center)
                }
                if pinchLive, let pinch {
                    if !pinchWasLive { scaleBase = scale }
                    scale = scaleBase * pinch.scale
                }
                pinchWasLive = pinchLive
                parent.onTwoFingerChanged(center, scale)
            } else if twoActive {
                twoActive = false
                parent.onTwoFingerEnded()
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

/// 单指拖动，走出 1 点就开始。拖动中又落下一根手指 → `.cancelled`；
/// 还没开始就落下第二根 → `.failed`（交给双指那一套）。
final class OneFingerDragRecognizer: UIGestureRecognizer {
    /// 落指的位置
    private(set) var start: CGPoint = .zero
    /// 手指现在相对落指点走了多少
    private(set) var offset: CGSize = .zero
    private var touch: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touch == nil, touches.count == 1, let first = touches.first else {
            // 第二根手指
            switch state {
            case .began, .changed: state = .cancelled
            case .possible: state = .failed
            default: break
            }
            return
        }
        touch = first
        start = first.location(in: view)
        offset = .zero
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        let p = touch.location(in: view)
        offset = CGSize(width: p.x - start.x, height: p.y - start.y)
        switch state {
        case .possible:
            if hypot(offset.width, offset.height) >= 1 { state = .began }
        case .began, .changed:
            state = .changed
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        switch state {
        case .began, .changed: state = .ended
        case .possible: state = .failed
        default: break
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        switch state {
        case .began, .changed: state = .cancelled
        default: state = .failed
        }
    }

    override func reset() {
        super.reset()
        touch = nil
        offset = .zero
    }
}
