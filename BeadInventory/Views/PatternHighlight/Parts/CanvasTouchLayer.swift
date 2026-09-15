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
//  这时单指那一拖已经开始了。第二根手指一落下，`OneFingerDragRecognizer` 就把自己
//  **取消**（`onOneFingerCancel`），由调用方把那几个点的挪动撤回去 —— 不然用户每次捏合，
//  网格都会被第一根手指顺手带歪一点。
//
//  单指那一套不用 `UIPanGestureRecognizer`：它要手指走出十来点才开始，
//  而推格线常常就是「往右挪小半格」—— 一格在屏幕上也就十几点，那一下根本拖不动。
//  `OneFingerDragRecognizer` 走出 4 点就开始，位移从落指点算，开始之后网格不落后手指。
//  门槛不设成 1 点：真机上点一下手指常常滑一两点，那样一碰就把网格推走了。
//

import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

struct CanvasTouchLayer: UIViewRepresentable {
    /// 单指开始拖。参数是**落指**的位置（不是识别出来那一刻的位置），用来判断按在了什么上面。
    var onOneFingerBegan: (CGPoint) -> Void
    /// 相对落指点的位移（手指走多远就是多远）
    var onOneFingerChanged: (CGSize) -> Void
    var onOneFingerEnded: () -> Void
    /// 第二根手指到了（或系统取消了触摸），这一拖作废
    var onOneFingerCancel: () -> Void
    /// 双指开始。参数是两指中点。
    var onTwoFingerBegan: (CGPoint) -> Void
    /// 两指中点 + 从这一次双指开始到现在的缩放倍数
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
        weak var pinch: UIPinchGestureRecognizer?
        weak var two: UIPanGestureRecognizer?
        private var oneActive = false
        private var twoActive = false
        /// 这一次双指累计缩放了多少。按增量乘：捏合识别器中途断了重新认出来时
        /// `pinch.scale` 会从 1 重新算，直接拿它当总倍数画面会弹回去。
        private var scale: CGFloat = 1
        /// 上一次回调时 `pinch.scale` 是多少。nil = 捏合这一段还没开始。
        private var lastPinchScale: CGFloat?

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
            let live: UIGestureRecognizer? = twoLive ? two : (pinchLive ? pinch : nil)

            // 只剩一根手指时识别器还活着，但 `location(in:)` 就成了那根手指的位置，
            // 拿它当中点画面会一下跳出去几十点。所以这时就当这一次双指结束了；
            // 第二根手指再落下，重新取锚点开始下一次。
            guard let live, live.numberOfTouches >= 2 else {
                if twoActive {
                    twoActive = false
                    parent.onTwoFingerEnded()
                }
                return
            }
            let center = live.location(in: view)

            if !twoActive {
                twoActive = true
                scale = 1
                lastPinchScale = nil
                parent.onTwoFingerBegan(center)
            }
            if pinchLive, let pinch {
                if let last = lastPinchScale, last > 0 { scale *= pinch.scale / last }
                lastPinchScale = pinch.scale
            } else {
                lastPinchScale = nil
            }
            parent.onTwoFingerChanged(center, scale)
        }

        /// 只跟自己这几个一起认。对所有识别器都放行的话，从屏幕左边缘右滑返回时
        /// 单指这个也跟着认出来，网格被一路拖走，松手还会存下来。
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            other.view === g.view
        }
    }
}

/// 单指拖动，走出 `startDistance` 就开始。拖动中又落下一根手指 → `.cancelled`；
/// 还没开始就落下第二根、或者落指时画布上已经有别的手指（捏合中抬起一根又放回）→ `.failed`。
final class OneFingerDragRecognizer: UIGestureRecognizer {
    /// 落指的位置
    private(set) var start: CGPoint = .zero
    /// 手指现在相对落指点走了多少
    private(set) var offset: CGSize = .zero
    private var touch: UITouch?
    private static let startDistance: CGFloat = 4

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        let onCanvas = view.flatMap { event.touches(for: $0)?.count } ?? touches.count
        guard touch == nil, touches.count == 1, onCanvas == 1, let first = touches.first else {
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
        super.touchesMoved(touches, with: event)
        guard let touch, touches.contains(touch) else { return }
        let p = touch.location(in: view)
        offset = CGSize(width: p.x - start.x, height: p.y - start.y)
        switch state {
        case .possible:
            if hypot(offset.width, offset.height) >= Self.startDistance { state = .began }
        case .began, .changed:
            state = .changed
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard let touch, touches.contains(touch) else { return }
        switch state {
        case .began, .changed: state = .ended
        case .possible: state = .failed
        default: break
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        guard let touch, touches.contains(touch) else { return }
        switch state {
        case .began, .changed: state = .cancelled
        case .possible: state = .failed
        default: break
        }
    }

    override func reset() {
        super.reset()
        touch = nil
        offset = .zero
    }
}
