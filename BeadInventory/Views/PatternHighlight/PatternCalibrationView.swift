//
//  PatternCalibrationView.swift
//  BeadInventory
//
//  拼图模式 - 网格标定页（默认 2 角矩形模式 + 放大镜 + ROI 自动检测）
//

import SwiftUI

struct PatternCalibrationView: View {
    let project: ProjectRecord
    var onComplete: (() -> Void)? = nil   // 由 parent 控制导航到高亮页

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var inventoryManager: InventoryManager

    @State private var corners: GridCorners = .initialQuad
    @State private var rows: Int = 29
    @State private var cols: Int = 29
    @State private var rectMode: Bool = true             // 默认矩形（2 角）模式
    @State private var detectionRunning = false
    @State private var detectionConfidence: Double? = nil
    @State private var saving = false

    /// 当前正在拖动的角点（用于显示放大镜）。nil = 没在拖。
    @State private var draggingCorner: CornerLabel? = nil
    /// 拖动点在 displayRect 内的屏幕坐标
    @State private var draggingScreenPoint: CGPoint = .zero

    private var image: UIImage? {
        project.thumbnail.flatMap { UIImage(data: $0) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                imageCanvas
                confidenceBanner
                toolbar
            }
            .navigationTitle("标定网格")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Toggle(isOn: $rectMode) {
                        Text(rectMode ? "矩形" : "四边形")
                            .font(.footnote)
                    }
                    .toggleStyle(.button)
                }
            }
            .task {
                if let existing = project.patternGrid {
                    corners = existing.corners
                    rows = existing.rows
                    cols = existing.cols
                } else {
                    runAutoDetect(restrictToCurrentROI: false)
                }
            }
            .onChange(of: rectMode) { _, newValue in
                if newValue { snapCornersToRect() }
            }
        }
    }

    // MARK: - Image canvas

    @ViewBuilder
    private var imageCanvas: some View {
        if let img = image {
            GeometryReader { geo in
                let displayRect = aspectFitRect(imageSize: img.size, in: geo.size)
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.05)
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)

                    CalibrationGridOverlay(
                        corners: corners,
                        rows: rows, cols: cols,
                        displayRect: displayRect
                    )

                    ForEach(visibleHandles(), id: \.self) { label in
                        CornerHandle(
                            label: label,
                            corners: $corners,
                            displayRect: displayRect,
                            rectMode: rectMode,
                            draggingCorner: $draggingCorner,
                            draggingScreenPoint: $draggingScreenPoint
                        )
                    }

                    if detectionRunning {
                        Color.black.opacity(0.3)
                        ProgressView("自动检测中...")
                            .padding()
                            .background(.regularMaterial)
                            .cornerRadius(8)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    }

                    if let label = draggingCorner {
                        LoupeView(
                            image: img,
                            imageCenter: imagePoint(for: label, displayRect: displayRect, image: img)
                        )
                        .position(loupePosition(for: draggingScreenPoint, in: geo.size))
                        .allowsHitTesting(false)
                    }
                }
            }
            .clipped()
        } else {
            Text("项目无图片")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var confidenceBanner: some View {
        if let conf = detectionConfidence {
            HStack {
                Image(systemName: conf >= 0.7 ? "checkmark.circle.fill" :
                      conf >= 0.5 ? "info.circle.fill" : "exclamationmark.triangle.fill")
                Text(conf >= 0.7 ? "网格识别成功，请检查是否对齐" :
                     conf >= 0.5 ? "请确认网格对齐，必要时手动微调" :
                     "未能可靠识别。先把矩形对到图纸边缘，再点「区域内检测」")
                    .font(.footnote)
                Spacer()
            }
            .padding(8)
            .background(conf >= 0.7 ? Color.green.opacity(0.15) :
                        conf >= 0.5 ? Color.blue.opacity(0.15) :
                        Color.orange.opacity(0.15))
        }
    }

    private var toolbar: some View {
        VStack(spacing: 12) {
            // 行列数（用户可直接修改；后续 "对齐网格" 会用这两个值）
            HStack(spacing: 16) {
                stepperCell(title: "行", value: $rows)
                stepperCell(title: "列", value: $cols)
            }

            // 检测按钮 + 提示
            VStack(spacing: 6) {
                HStack(spacing: 12) {
                    Button {
                        runAutoDetect(restrictToCurrentROI: false)
                    } label: {
                        Label("全自动检测", systemImage: "wand.and.rays")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(detectionRunning || image == nil)
                    .buttonStyle(.bordered)

                    Button {
                        runSnapToROI()
                    } label: {
                        Label("对齐网格", systemImage: "viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(detectionRunning || image == nil)
                    .buttonStyle(.bordered)
                }
                Text("不准时：调好行列数 → 拖矩形覆盖网格 → 点「对齐网格」")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button {
                saveAndContinue()
            } label: {
                Label(saving ? "保存中..." : "完成", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(saving || image == nil)
        }
        .padding()
        .background(.regularMaterial)
    }

    // MARK: - Logic

    private func visibleHandles() -> [CornerLabel] {
        rectMode ? [.tl, .br] : CornerLabel.allCases
    }

    /// 把 4 角对齐成矩形（取 TL 和 BR 决定的轴对齐矩形）
    private func snapCornersToRect() {
        let tlx = min(corners.topLeft.x, corners.bottomLeft.x, corners.topRight.x, corners.bottomRight.x)
        let tly = min(corners.topLeft.y, corners.topRight.y, corners.bottomLeft.y, corners.bottomRight.y)
        let brx = max(corners.topLeft.x, corners.bottomLeft.x, corners.topRight.x, corners.bottomRight.x)
        let bry = max(corners.topLeft.y, corners.topRight.y, corners.bottomLeft.y, corners.bottomRight.y)
        corners = GridCorners(
            topLeft: CGPoint(x: tlx, y: tly),
            topRight: CGPoint(x: brx, y: tly),
            bottomLeft: CGPoint(x: tlx, y: bry),
            bottomRight: CGPoint(x: brx, y: bry)
        )
    }

    /// 显眼的行/列输入单元（点击按钮 + 数字 + +/-）
    @ViewBuilder
    private func stepperCell(title: String, value: Binding<Int>) -> some View {
        HStack(spacing: 8) {
            Text("\(title)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                if value.wrappedValue > 2 { value.wrappedValue -= 1 }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            Text("\(value.wrappedValue)")
                .font(.title3.monospacedDigit().bold())
                .frame(minWidth: 36)
            Button {
                if value.wrappedValue < 300 { value.wrappedValue += 1 }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }

    /// 按用户的 ROI + 当前 rows/cols 校准 corners（保留用户的 stepper 值不变）
    private func runSnapToROI() {
        guard let img = image else { return }
        detectionRunning = true
        let currentCorners = corners
        Task {
            let result = await GridDetectionService.shared.detect(
                image: img,
                roi: roiRect(from: currentCorners, imageSize: img.size)
            )
            await MainActor.run {
                detectionRunning = false
                if let r = result {
                    // 只更新 corners，rows/cols 保留用户输入
                    corners = r.corners
                    if rectMode { snapCornersToRect() }
                    detectionConfidence = r.confidence
                } else {
                    detectionConfidence = 0
                }
            }
        }
    }

    private func runAutoDetect(restrictToCurrentROI: Bool) {
        guard let img = image else { return }
        detectionRunning = true
        let currentCorners = corners
        let useROI = restrictToCurrentROI
        Task {
            let result: GridDetectionResult?
            if useROI {
                result = await GridDetectionService.shared.detect(
                    image: img,
                    roi: roiRect(from: currentCorners, imageSize: img.size)
                )
            } else {
                result = await GridDetectionService.shared.detect(image: img)
            }
            await MainActor.run {
                detectionRunning = false
                if let r = result {
                    if useROI {
                        // 用户已确定 ROI，保留用户的 corners，只更新行列数
                        rows = r.rows
                        cols = r.cols
                    } else {
                        corners = r.corners
                        rows = r.rows
                        cols = r.cols
                    }
                    if rectMode { snapCornersToRect() }
                    detectionConfidence = r.confidence
                } else {
                    detectionConfidence = 0
                }
            }
        }
    }

    private func roiRect(from corners: GridCorners, imageSize: CGSize) -> CGRect {
        let tlx = min(corners.topLeft.x, corners.bottomLeft.x)
        let tly = min(corners.topLeft.y, corners.topRight.y)
        let brx = max(corners.topRight.x, corners.bottomRight.x)
        let bry = max(corners.bottomLeft.y, corners.bottomRight.y)
        return CGRect(x: tlx * imageSize.width,
                      y: tly * imageSize.height,
                      width: (brx - tlx) * imageSize.width,
                      height: (bry - tly) * imageSize.height)
    }

    private func saveAndContinue() {
        guard let img = image else { return }
        saving = true
        let cornersCopy = rectMode ? rectangleCorners(from: corners) : corners
        let rowsCopy = rows
        let colsCopy = cols
        let projectId = project.id
        let colorSystem = project.colorSystem
        Task.detached(priority: .userInitiated) {
            let availableColors = await MainActor.run { inventoryManager.beadColors }
            let placeholder = BeadPatternGrid(
                corners: cornersCopy, rows: rowsCopy, cols: colsCopy,
                cellColorCodes: Array(repeating: Array(repeating: nil, count: colsCopy), count: rowsCopy),
                lastCalibratedAt: Date(),
                sourceImageSize: img.size,
                colorSystem: colorSystem
            )
            let cells = GridCellSampler.shared.sample(
                image: img, grid: placeholder, availableColors: availableColors
            )
            let grid = BeadPatternGrid(
                corners: cornersCopy, rows: rowsCopy, cols: colsCopy,
                cellColorCodes: cells,
                lastCalibratedAt: Date(),
                sourceImageSize: img.size,
                colorSystem: colorSystem
            )
            await MainActor.run {
                inventoryManager.updateProjectPatternGrid(projectId, grid: grid)
                saving = false
                dismiss()
                // 给 dismiss 留点时间，再让 parent 触发 highlight
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    onComplete?()
                }
            }
        }
    }

    private func rectangleCorners(from c: GridCorners) -> GridCorners {
        let tlx = min(c.topLeft.x, c.bottomRight.x)
        let tly = min(c.topLeft.y, c.bottomRight.y)
        let brx = max(c.topLeft.x, c.bottomRight.x)
        let bry = max(c.topLeft.y, c.bottomRight.y)
        return GridCorners(
            topLeft: CGPoint(x: tlx, y: tly),
            topRight: CGPoint(x: brx, y: tly),
            bottomLeft: CGPoint(x: tlx, y: bry),
            bottomRight: CGPoint(x: brx, y: bry)
        )
    }

    private func aspectFitRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        let s = min(container.width / imageSize.width, container.height / imageSize.height)
        let w = imageSize.width * s
        let h = imageSize.height * s
        return CGRect(x: (container.width - w) / 2,
                      y: (container.height - h) / 2,
                      width: w, height: h)
    }

    /// 给定角点 label 和 displayRect，返回该角点在源图像素坐标系的位置
    private func imagePoint(for label: CornerLabel, displayRect: CGRect, image: UIImage) -> CGPoint {
        let norm: CGPoint
        switch label {
        case .tl: norm = corners.topLeft
        case .tr: norm = corners.topRight
        case .bl: norm = corners.bottomLeft
        case .br: norm = corners.bottomRight
        }
        return CGPoint(x: norm.x * image.size.width, y: norm.y * image.size.height)
    }

    /// 放大镜位置：默认在触点正上方 100pt，越界时移到下方
    private func loupePosition(for touch: CGPoint, in container: CGSize) -> CGPoint {
        let preferredY = touch.y - 110
        if preferredY > 60 { return CGPoint(x: touch.x, y: preferredY) }
        return CGPoint(x: touch.x, y: touch.y + 110)
    }
}

extension GridCorners {
    /// 默认四角占图片 10%~90%
    static let initialQuad = GridCorners(
        topLeft: CGPoint(x: 0.1, y: 0.1),
        topRight: CGPoint(x: 0.9, y: 0.1),
        bottomLeft: CGPoint(x: 0.1, y: 0.9),
        bottomRight: CGPoint(x: 0.9, y: 0.9)
    )
}

enum CornerLabel: CaseIterable, Hashable {
    case tl, tr, bl, br
}

private struct CornerHandle: View {
    let label: CornerLabel
    @Binding var corners: GridCorners
    let displayRect: CGRect
    let rectMode: Bool
    @Binding var draggingCorner: CornerLabel?
    @Binding var draggingScreenPoint: CGPoint

    var body: some View {
        let p = currentPoint
        Circle()
            .fill(Color.red.opacity(0.85))
            .frame(width: 28, height: 28)
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
            .position(x: p.x, y: p.y)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let clamped = CGPoint(
                            x: max(displayRect.minX, min(displayRect.maxX, value.location.x)),
                            y: max(displayRect.minY, min(displayRect.maxY, value.location.y))
                        )
                        update(to: GridGeometry.normalize(clamped, in: displayRect))
                        draggingCorner = label
                        draggingScreenPoint = clamped
                    }
                    .onEnded { _ in
                        draggingCorner = nil
                    }
            )
    }

    private var currentPoint: CGPoint {
        let norm: CGPoint = {
            switch label {
            case .tl: return corners.topLeft
            case .tr: return corners.topRight
            case .bl: return corners.bottomLeft
            case .br: return corners.bottomRight
            }
        }()
        return GridGeometry.denormalize(norm, in: displayRect)
    }

    private func update(to norm: CGPoint) {
        switch label {
        case .tl:
            corners.topLeft = norm
            if rectMode {
                corners.topRight.y = norm.y
                corners.bottomLeft.x = norm.x
            }
        case .tr:
            corners.topRight = norm
            if rectMode {
                corners.topLeft.y = norm.y
                corners.bottomRight.x = norm.x
            }
        case .bl:
            corners.bottomLeft = norm
            if rectMode {
                corners.topLeft.x = norm.x
                corners.bottomRight.y = norm.y
            }
        case .br:
            corners.bottomRight = norm
            if rectMode {
                corners.bottomLeft.y = norm.y
                corners.topRight.x = norm.x
            }
        }
    }
}

private struct CalibrationGridOverlay: View {
    let corners: GridCorners
    let rows: Int
    let cols: Int
    let displayRect: CGRect

    var body: some View {
        Canvas { context, _ in
            for c in 0...cols {
                let u = CGFloat(c) / CGFloat(cols)
                let p1 = GridGeometry.bilinear(u: u, v: 0, corners: corners, in: displayRect)
                let p2 = GridGeometry.bilinear(u: u, v: 1, corners: corners, in: displayRect)
                var path = Path()
                path.move(to: p1)
                path.addLine(to: p2)
                context.stroke(path, with: .color(.cyan.opacity(0.7)), lineWidth: 0.7)
            }
            for r in 0...rows {
                let v = CGFloat(r) / CGFloat(rows)
                let p1 = GridGeometry.bilinear(u: 0, v: v, corners: corners, in: displayRect)
                let p2 = GridGeometry.bilinear(u: 1, v: v, corners: corners, in: displayRect)
                var path = Path()
                path.move(to: p1)
                path.addLine(to: p2)
                context.stroke(path, with: .color(.cyan.opacity(0.7)), lineWidth: 0.7)
            }
        }
    }
}

/// 放大镜：圆形窗口显示拖动点附近的原图像素，3 倍放大，避免被手指遮挡。
private struct LoupeView: View {
    let image: UIImage
    let imageCenter: CGPoint    // 原图像素坐标系

    private let loupeSize: CGFloat = 120
    private let zoom: CGFloat = 1.6

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: image.size.width * zoom,
                   height: image.size.height * zoom)
            .offset(x: loupeSize / 2 - imageCenter.x * zoom,
                    y: loupeSize / 2 - imageCenter.y * zoom)
            .frame(width: loupeSize, height: loupeSize, alignment: .topLeading)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white, lineWidth: 3))
            .overlay(crosshair)
            .shadow(color: .black.opacity(0.4), radius: 6)
    }

    private var crosshair: some View {
        ZStack {
            Rectangle().fill(Color.red).frame(width: 16, height: 1.5)
            Rectangle().fill(Color.red).frame(width: 1.5, height: 16)
        }
    }
}
