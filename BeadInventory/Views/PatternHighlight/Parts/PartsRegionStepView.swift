//
//  PartsRegionStepView.swift
//  BeadInventory
//
//  多零件模式 · 第 ① 屏 - 圈出零件区
//
//  立体图纸通常是「顶部色号表 + 中间一堆零件 + 底部装配示意图」三段。
//  只有中间那段是 App 要处理的，另外两段既不该被拆成零件，也不该参与配色统计。
//  与其让算法去猜哪段是哪段，不如让用户拖一个框 —— 一次操作，零歧义。
//

import SwiftUI

struct PartsRegionStepView: View {
    let image: UIImage
    @Binding var roi: CGRect
    let onContinue: () -> Void

    // 放大查看细节用。手势结构对齐 PatternCalibrationView：
    // 角点和框体的单指拖优先级更高，只有在它们的热区之外、且已经放大时才平移画布。
    @State private var viewScale: CGFloat = 1.0
    @State private var lastViewScale: CGFloat = 1.0
    @State private var viewOffset: CGSize = .zero
    @State private var lastViewOffset: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            canvas
            footer
        }
    }

    private var canvas: some View {
        GeometryReader { geo in
            let display = Self.aspectFitRect(imageSize: image.size, in: geo.size)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.05)

                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)

                RegionDimOverlay(roi: roi, displayRect: display)
                    .allowsHitTesting(false)

                RegionBodyDragHandle(roi: $roi, displayRect: display)

                RegionCornerHandle(corner: .topLeft, roi: $roi, displayRect: display)
                RegionCornerHandle(corner: .bottomRight, roi: $roi, displayRect: display)
            }
            .scaleEffect(viewScale, anchor: .center)
            .offset(viewOffset)
            .gesture(
                SimultaneousGesture(
                    MagnificationGesture()
                        .onChanged { viewScale = max(1.0, min(5.0, lastViewScale * $0)) }
                        .onEnded { _ in lastViewScale = viewScale },
                    DragGesture(minimumDistance: 10)
                        .onChanged { value in
                            guard viewScale > 1.05 else { return }
                            viewOffset = CGSize(
                                width: lastViewOffset.width + value.translation.width,
                                height: lastViewOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in lastViewOffset = viewOffset }
                )
            )
        }
        .clipped()
    }

    private var footer: some View {
        VStack(spacing: Theme.Spacing.md) {
            Text("把中间那一片零件框住。顶上的色号表、底下的装配图留在框外。")
                .font(.footnote)
                .foregroundStyle(Theme.ColorToken.Text.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onContinue) {
                Label("自动拆零件", systemImage: "square.on.square.dashed")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.regularMaterial)
    }

    static func aspectFitRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let s = min(container.width / imageSize.width, container.height / imageSize.height)
        let w = imageSize.width * s
        let h = imageSize.height * s
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }
}

// MARK: - 框外压暗

/// 用四块半透明矩形围出「框外」，而不是 mask/blendMode —— 四个矩形在任何
/// 渲染路径下的表现都一样，也不会跟外层的 scaleEffect 打架。
private struct RegionDimOverlay: View {
    let roi: CGRect
    let displayRect: CGRect

    var body: some View {
        let r = CGRect(
            x: displayRect.minX + roi.minX * displayRect.width,
            y: displayRect.minY + roi.minY * displayRect.height,
            width: roi.width * displayRect.width,
            height: roi.height * displayRect.height
        )
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                let dim = Color.black.opacity(0.45)
                context.fill(Path(CGRect(x: displayRect.minX, y: displayRect.minY,
                                         width: displayRect.width, height: r.minY - displayRect.minY)),
                             with: .color(dim))
                context.fill(Path(CGRect(x: displayRect.minX, y: r.maxY,
                                         width: displayRect.width, height: displayRect.maxY - r.maxY)),
                             with: .color(dim))
                context.fill(Path(CGRect(x: displayRect.minX, y: r.minY,
                                         width: r.minX - displayRect.minX, height: r.height)),
                             with: .color(dim))
                context.fill(Path(CGRect(x: r.maxX, y: r.minY,
                                         width: displayRect.maxX - r.maxX, height: r.height)),
                             with: .color(dim))
                context.stroke(Path(r), with: .color(.white), lineWidth: 1.5)
            }
        }
    }
}

// MARK: - 手势

private enum RegionCorner { case topLeft, bottomRight }

/// 角点：28pt 红点 + 64pt 透明热区（HIG 最小点击目标）
private struct RegionCornerHandle: View {
    let corner: RegionCorner
    @Binding var roi: CGRect
    let displayRect: CGRect

    /// 框的最小边长（归一化）。再小的框拆不出东西，也容易误拖成一个点。
    private let minSide: CGFloat = 0.04

    var body: some View {
        let p = position
        ZStack {
            Circle().fill(Color.white.opacity(0.001)).frame(width: 64, height: 64)
            Circle()
                .fill(Theme.ColorToken.Status.error.opacity(0.85))
                .frame(width: 28, height: 28)
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
        }
        .contentShape(Circle().scale(2))
        .position(x: p.x, y: p.y)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let clamped = CGPoint(
                        x: max(displayRect.minX, min(displayRect.maxX, value.location.x)),
                        y: max(displayRect.minY, min(displayRect.maxY, value.location.y))
                    )
                    let n = CGPoint(
                        x: (clamped.x - displayRect.minX) / max(displayRect.width, 1),
                        y: (clamped.y - displayRect.minY) / max(displayRect.height, 1)
                    )
                    switch corner {
                    case .topLeft:
                        let maxX = roi.maxX - minSide
                        let maxY = roi.maxY - minSide
                        let nx = min(n.x, maxX), ny = min(n.y, maxY)
                        roi = CGRect(x: nx, y: ny, width: roi.maxX - nx, height: roi.maxY - ny)
                    case .bottomRight:
                        let nx = max(n.x, roi.minX + minSide)
                        let ny = max(n.y, roi.minY + minSide)
                        roi = CGRect(x: roi.minX, y: roi.minY, width: nx - roi.minX, height: ny - roi.minY)
                    }
                }
        )
    }

    private var position: CGPoint {
        let n = corner == .topLeft ? CGPoint(x: roi.minX, y: roi.minY) : CGPoint(x: roi.maxX, y: roi.maxY)
        return CGPoint(x: displayRect.minX + n.x * displayRect.width,
                       y: displayRect.minY + n.y * displayRect.height)
    }
}

/// 框内单指拖 = 整体挪框（不变形），用于「大小对了但位置偏了」的常见情况。
private struct RegionBodyDragHandle: View {
    @Binding var roi: CGRect
    let displayRect: CGRect

    @State private var dragStart: CGRect?

    var body: some View {
        let r = CGRect(
            x: displayRect.minX + roi.minX * displayRect.width,
            y: displayRect.minY + roi.minY * displayRect.height,
            width: roi.width * displayRect.width,
            height: roi.height * displayRect.height
        )
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: max(r.width, 1), height: max(r.height, 1))
            .position(x: r.midX, y: r.midY)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { value in
                        if dragStart == nil { dragStart = roi }
                        guard let start = dragStart else { return }
                        let dx = value.translation.width / max(displayRect.width, 1)
                        let dy = value.translation.height / max(displayRect.height, 1)
                        let clampedDx = max(-start.minX, min(1 - start.maxX, dx))
                        let clampedDy = max(-start.minY, min(1 - start.maxY, dy))
                        roi = start.offsetBy(dx: clampedDx, dy: clampedDy)
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }
}
