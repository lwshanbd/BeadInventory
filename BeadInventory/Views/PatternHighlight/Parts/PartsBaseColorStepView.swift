//
//  PartsBaseColorStepView.swift
//  BeadInventory
//
//  多零件模式 · 指认底色和任意色（第四屏；整条流程的屏序见 PartsSheetFlowView 的头注释）
//
//  ## 为什么这一屏必须存在
//
//  判色那一步会把每一类颜色配到图纸色号表里最近的那个色号上。问题是图上有两大片
//  **不是色号**的东西：
//
//    底色    零件外面、零件中间镂空的那一片，就是图纸的背景。每张图纸的底色都不一样
//            （这张是浅粉，别的可能是白、米、格纹）。
//    任意色  色号表里单独写了一行「任意色」的那种豆子。这张图纸上它有两千多颗。
//
//  这两样如果不先摘出去，就会被硬套到最近的色号上，而且是**混进已有的那一类里** ——
//  用户在核对页看到的是「这个色号里掺了一大堆不该有的格子」，跟真的混在一起，
//  整类改也不是、一格一格挑也不是。所以只能在判色之前就把它们指认掉。
//
//  ## 为什么不能自动认
//
//  底色还能猜（取零件区边上一圈的众数色，多数图纸猜得对，所以这一屏给了初值）。
//  任意色**猜不出来**：它在图上就是一种普通的淡紫豆子，跟别的豆子长得没有任何区别，
//  「它代表任意色」这件事只写在色号表那一行字里。与其赌，不如让用户点一下。
//
//  ## 交互
//
//  下面两行是两个槽，点一下选中要指认哪个，再点图上对应的颜色。取的是落点周围
//  一小片的众数色 —— 手指点不准，而豆子之间还有深色格线，正好点在线上会取到
//  一个图上根本不存在的颜色。
//
//  没有任意色的图纸直接跳过：那一行留空就是了。
//

import SwiftUI

struct PartsBaseColorStepView: View {
    let work: PartsWorkImage
    let roi: CGRect
    /// 一格多大（归一化）。取色时按半格取样。
    let calibration: PartsGridCalibration?
    @Binding var emptyHex: String?
    @Binding var anyColorHex: String?
    let onContinue: () -> Void

    private enum Slot { case empty, anyColor }

    @State private var armed: Slot = .anyColor
    /// 上一次点图没取到颜色时要说的那句话。nil = 一切正常。
    @State private var note: String?
    @State private var image: UIImage?
    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var lastPan: CGSize = .zero
    @State private var pinchScreenPoint: CGPoint = .zero
    @State private var pinchContentAnchor: CGPoint?
    @State private var canvasSize: CGSize = .zero

    private var displayRect: CGRect {
        PartsRegionStepView.aspectFitRect(
            imageSize: image?.size ?? CGSize(width: 1, height: 1), in: canvasSize
        )
    }

    private var transform: PartsCanvasTransform {
        PartsCanvasTransform(region: roi, display: displayRect,
                             size: canvasSize, zoom: zoom, pan: pan)
    }

    var body: some View {
        VStack(spacing: 0) {
            canvas
            footer
        }
        .navigationTitle("底色和任意色")
        .navigationBarTitleDisplayMode(.inline)
        // 工作图也算进 id：低清兜底版换成高清版之后要重裁，否则取色取的是糊图
        .task(id: "\(work.image.size)") { await load() }
    }

    // MARK: - 画布

    private var canvas: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Theme.ColorToken.Surface.subtle

                if let image, canvasSize.width > 0, roi.width > 0 {
                    let box = transform.screenRect(roi)
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)
                }

                gestureCatcher
            }
            .onAppear { canvasSize = geo.size }
            .onChange(of: geo.size) { _, new in canvasSize = new }
        }
        .clipped()
    }

    private var gestureCatcher: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                SimultaneousGesture(
                    SimultaneousGesture(
                        SpatialTapGesture().onEnded { value in
                            pick(at: value.location)
                        },
                        DragGesture(minimumDistance: 4)
                            .onChanged { value in
                                pan = clampPan(CGSize(width: lastPan.width + value.translation.width,
                                                      height: lastPan.height + value.translation.height))
                            }
                            .onEnded { _ in lastPan = pan }
                    ),
                    MagnifyGesture()
                        .onChanged { value in
                            if pinchContentAnchor == nil {
                                pinchScreenPoint = value.startLocation
                                pinchContentAnchor = unzoomed(value.startLocation)
                            }
                            guard let anchor = pinchContentAnchor else { return }
                            zoom = max(1, min(12, lastZoom * value.magnification))
                            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                            pan = clampPan(CGSize(
                                width: pinchScreenPoint.x - center.x - (anchor.x - center.x) * zoom,
                                height: pinchScreenPoint.y - center.y - (anchor.y - center.y) * zoom
                            ))
                        }
                        .onEnded { _ in
                            lastZoom = zoom
                            lastPan = pan
                            pinchContentAnchor = nil
                        }
                )
            )
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(spacing: Theme.Spacing.md) {
            slotRow(
                slot: .empty,
                title: String(localized: "底色（空白）"),
                hint: String(localized: "零件外面那一片，不用放豆子"),
                hex: emptyHex
            )
            slotRow(
                slot: .anyColor,
                title: String(localized: "任意色"),
                hint: anyColorHex == nil
                    ? String(localized: "色号表里写「任意色」的那种豆子，没有就不用点")
                    : String(localized: "用什么颜色的豆子拼都行"),
                hex: anyColorHex
            )

            if let note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(Theme.ColorToken.Status.error)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(armed == .empty
                     ? "现在点图上的**底色**"
                     : "现在点图上的**任意色**豆子")
                    .font(.footnote)
                    .foregroundStyle(Theme.ColorToken.Morandi.honey)
            }

            Button(action: onContinue) {
                Label("开始判色", systemImage: "eyedropper")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.regularMaterial)
    }

    private func slotRow(slot: Slot, title: String, hint: String, hex: String?) -> some View {
        Button {
            armed = slot
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hex.map { Color(hex: $0) } ?? Theme.ColorToken.Surface.subtle)
                    .frame(width: 34, height: 34)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
                    )
                    .overlay {
                        if hex == nil {
                            Image(systemName: "questionmark")
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(Theme.ColorToken.Text.tertiary)
                        }
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(Theme.ColorToken.Text.primary)
                    Text(hint)
                        .font(.caption)
                        .foregroundColor(Theme.ColorToken.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: Theme.Spacing.sm)

                if hex != nil, slot == .anyColor {
                    Button("清掉") { anyColorHex = nil }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundColor(Theme.ColorToken.Status.error)
                }
            }
            .contentShape(Rectangle())
            .padding(Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .fill(armed == slot ? Theme.ColorToken.Morandi.honey.opacity(0.15) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .stroke(armed == slot ? Theme.ColorToken.Morandi.honey : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 逻辑

    private func load() async {
        let source = work
        let region = roi
        let cropped = await Task.detached(priority: .userInitiated) {
            PartsThumbnailMaker.crop(source, normalized: region)
        }.value
        image = cropped
        // 底色先猜一个填进去 —— 多数图纸猜得对，用户点个头就行，
        // 真正非点不可的只有任意色。
        if emptyHex == nil {
            let guessed = await Task.detached(priority: .userInitiated) {
                PartsCellClassifier.autoEmptyHex(work: source, roi: region)
            }.value
            if emptyHex == nil { emptyHex = guessed }
        }
    }

    private func pick(at screenPoint: CGPoint) {
        guard image != nil, canvasSize.width > 0, roi.width > 0 else { return }
        let normalized = transform.normalized(screenPoint)
        guard CGRect(x: 0, y: 0, width: 1, height: 1).contains(normalized) else { return }
        let source = work
        let patch = samplePatch()
        Task {
            let hex = await Task.detached(priority: .userInitiated) {
                PartsCellClassifier.sampleHex(work: source, at: normalized, patch: patch)
            }.value
            guard let hex else {
                // 屏幕上正写着「现在点图上的任意色豆子」，用户照做了。
                // 静默 return 的话他只会一直点，什么都不发生。
                note = String(localized: "这里取不到颜色，换个地方点点看。要是哪儿都取不到，退回零件清单那屏，用上面的提示条补一张原图就清楚了。")
                return
            }
            note = nil
            switch armed {
            case .empty: emptyHex = hex
            case .anyColor: anyColorHex = hex
            }
        }
    }

    /// 取样方块的边长（归一化，相对整张图纸）。
    ///
    /// 半格起步（整格会把周围的格线也圈进来），但**必须够 `PartsBitmap` 的 8×8 像素下限**：
    /// 走压缩图兜底时一格才十来个像素，半格 ≈ 5px，取色于是必然失败 ——
    /// 用户点一下毫无反应，反复点还是毫无反应。所以这里按工作图的真实分辨率把取样区撑到够，
    /// 撑到超出图纸也没关系，`sampleHex` 会跟图纸边界求交，实际取到多少算多少。
    private func samplePatch() -> Double {
        let half = calibration.map { max($0.cellWidth, $0.cellHeight) / 2 } ?? 0.004
        let size = work.image.size
        guard size.width > 0, size.height > 0,
              work.region.width > 0, work.region.height > 0 else { return half }
        // 归一化长度 1 在这张工作图上分别是多少像素（横竖不一样，图纸不是正方形）
        let pixelsPerUnitX = Double(size.width) / Double(work.region.width)
        let pixelsPerUnitY = Double(size.height) / Double(work.region.height)
        return max(half, Self.minSamplePixels / min(pixelsPerUnitX, pixelsPerUnitY))
    }

    /// 取样方块的像素下限。`PartsBitmap.make` 低于 8×8 直接返回 nil，留一点余量。
    private static let minSamplePixels: Double = 10

    private func unzoomed(_ point: CGPoint) -> CGPoint {
        guard zoom > 0 else { return point }
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        return CGPoint(x: center.x + (point.x - pan.width - center.x) / zoom,
                       y: center.y + (point.y - pan.height - center.y) / zoom)
    }

    private func clampPan(_ offset: CGSize) -> CGSize {
        let limitX = max(0, (zoom - 1) * canvasSize.width / 2)
        let limitY = max(0, (zoom - 1) * canvasSize.height / 2)
        return CGSize(width: min(max(offset.width, -limitX), limitX),
                      height: min(max(offset.height, -limitY), limitY))
    }
}
