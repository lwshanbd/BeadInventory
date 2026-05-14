//
//  ZoomablePatternCanvas.swift
//  BeadInventory
//
//  支持缩放/平移的图片 + 叠层容器。
//
//  交互（仿 iOS Photos）：
//   - 双指 pinch：缩放，限制在 [1.0, 8.0]
//   - 单指 drag：任何时候都可拖（不再要求先放大），拖完后 offset 被钳在
//     "图边不离开屏幕一半" 的范围内
//   - 双击：在 1.0 和 2.5 之间切换
//

import SwiftUI

struct ZoomablePatternCanvas<Overlay: View>: View {
    let image: UIImage
    @ViewBuilder var overlay: (CGRect) -> Overlay

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0   // pinch 开始时的 scale 快照
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero // drag 开始时的 offset 快照

    private let minScale: CGFloat = 1.0
    private let maxScale: CGFloat = 8.0

    var body: some View {
        GeometryReader { geo in
            let displayRect = aspectFitRect(imageSize: image.size, in: geo.size)
            ZStack {
                Color.black
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                    overlay(CGRect(origin: .zero, size: displayRect.size))
                        .frame(width: displayRect.width, height: displayRect.height)
                }
                .frame(width: displayRect.width, height: displayRect.height)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    SimultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                let next = lastScale * value
                                scale = max(minScale, min(maxScale, next))
                            }
                            .onEnded { _ in
                                lastScale = scale
                                clampOffset(displayRect: displayRect)
                                lastOffset = offset
                            },
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                offset = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                            }
                            .onEnded { _ in
                                clampOffset(displayRect: displayRect)
                                lastOffset = offset
                            }
                    )
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        if scale > 1.05 {
                            scale = 1.0
                            lastScale = 1.0
                            offset = .zero
                            lastOffset = .zero
                        } else {
                            scale = 2.5
                            lastScale = 2.5
                        }
                    }
                }
            }
            .clipped()
            .onChange(of: geo.size) { _, _ in
                // 容器尺寸变化（旋转屏等），重置
                scale = 1.0; lastScale = 1.0
                offset = .zero; lastOffset = .zero
            }
        }
    }

    /// 把 offset 钳在合理范围：放大倍数越高允许拖得越多。
    /// 公式：边长 × (scale - 1) / 2，多一点裕度避免硬贴边。
    private func clampOffset(displayRect: CGRect) {
        let maxX = max(0, displayRect.width  * (scale - 1) / 2)
        let maxY = max(0, displayRect.height * (scale - 1) / 2)
        var clamped = offset
        clamped.width = max(-maxX, min(maxX, clamped.width))
        clamped.height = max(-maxY, min(maxY, clamped.height))
        if clamped != offset {
            withAnimation(.easeOut(duration: 0.2)) {
                offset = clamped
            }
        }
    }

    private func aspectFitRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        let s = min(container.width / imageSize.width, container.height / imageSize.height)
        let w = imageSize.width * s
        let h = imageSize.height * s
        return CGRect(x: (container.width - w) / 2,
                      y: (container.height - h) / 2,
                      width: w, height: h)
    }
}
