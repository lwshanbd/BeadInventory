//
//  ZoomablePatternCanvas.swift
//  BeadInventory
//
//  支持缩放/平移的图片 + 叠层容器
//

import SwiftUI

struct ZoomablePatternCanvas<Overlay: View>: View {
    let image: UIImage
    @ViewBuilder var overlay: (CGRect) -> Overlay

    @State private var scale: CGFloat = 1.0
    @GestureState private var pinchDelta: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @GestureState private var dragDelta: CGSize = .zero

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
                .scaleEffect(scale * pinchDelta)
                .offset(x: offset.width + dragDelta.width, y: offset.height + dragDelta.height)
                .gesture(
                    MagnificationGesture()
                        .updating($pinchDelta) { v, s, _ in s = v }
                        .onEnded { v in
                            scale = max(0.5, min(8, scale * v))
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .updating($dragDelta) { v, s, _ in
                            if scale > 1.05 { s = v.translation }
                        }
                        .onEnded { v in
                            if scale > 1.05 {
                                offset.width += v.translation.width
                                offset.height += v.translation.height
                            }
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if scale > 1.05 {
                            scale = 1.0
                            offset = .zero
                        } else {
                            scale = 2.5
                        }
                    }
                }
            }
            .clipped()
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
