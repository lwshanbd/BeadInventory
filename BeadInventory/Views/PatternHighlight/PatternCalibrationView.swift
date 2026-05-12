//
//  PatternCalibrationView.swift
//  BeadInventory
//
//  拼图模式 - 网格标定页（手动 + 自动检测预填）
//

import SwiftUI

struct PatternCalibrationView: View {
    let project: ProjectRecord

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var inventoryManager: InventoryManager

    @State private var corners: GridCorners = .initialQuad
    @State private var rows: Int = 29
    @State private var cols: Int = 29
    @State private var detectionRunning = false
    @State private var detectionConfidence: Double? = nil
    @State private var saving = false
    @State private var presentHighlight = false

    private var image: UIImage? {
        project.thumbnail.flatMap { UIImage(data: $0) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
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

                            ForEach(CornerLabel.allCases, id: \.self) { label in
                                CornerHandle(
                                    label: label,
                                    corners: $corners,
                                    displayRect: displayRect
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
                        }
                    }
                    .clipped()
                } else {
                    Text("项目无图片")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if let conf = detectionConfidence {
                    HStack {
                        Image(systemName: conf >= 0.7 ? "checkmark.circle.fill" :
                              conf >= 0.5 ? "info.circle.fill" : "exclamationmark.triangle.fill")
                        Text(conf >= 0.7 ? "网格识别成功，请检查是否对齐" :
                             conf >= 0.5 ? "请确认网格对齐，必要时手动微调" :
                             "未能可靠识别网格，请手动调整 4 个角和行列数")
                            .font(.footnote)
                        Spacer()
                    }
                    .padding(8)
                    .background(conf >= 0.7 ? Color.green.opacity(0.15) :
                                conf >= 0.5 ? Color.blue.opacity(0.15) :
                                Color.orange.opacity(0.15))
                }

                VStack(spacing: 12) {
                    HStack {
                        Stepper("行 \(rows)", value: $rows, in: 2...200)
                        Stepper("列 \(cols)", value: $cols, in: 2...200)
                    }
                    HStack(spacing: 12) {
                        Button {
                            runAutoDetect()
                        } label: {
                            Label(detectionRunning ? "检测中..." : "自动检测",
                                  systemImage: "wand.and.rays")
                        }
                        .disabled(detectionRunning || image == nil)

                        Spacer()

                        Button {
                            saveAndContinue()
                        } label: {
                            Label(saving ? "保存中..." : "完成", systemImage: "checkmark")
                                .frame(maxWidth: 140)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(saving || image == nil)
                    }
                }
                .padding()
                .background(.regularMaterial)
            }
            .navigationTitle("标定网格")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .task {
                if let existing = project.patternGrid {
                    corners = existing.corners
                    rows = existing.rows
                    cols = existing.cols
                } else {
                    runAutoDetect()
                }
            }
            .onChange(of: presentHighlight) { _, newValue in
                if newValue { dismiss() }
            }
        }
    }

    private func runAutoDetect() {
        guard let img = image else { return }
        detectionRunning = true
        Task {
            let result = await GridDetectionService.shared.detect(image: img)
            await MainActor.run {
                detectionRunning = false
                if let r = result {
                    corners = r.corners
                    rows = r.rows
                    cols = r.cols
                    detectionConfidence = r.confidence
                } else {
                    detectionConfidence = 0
                }
            }
        }
    }

    private func saveAndContinue() {
        guard let img = image else { return }
        saving = true
        let cornersCopy = corners
        let rowsCopy = rows
        let colsCopy = cols
        let projectId = project.id
        let colorSystem = project.colorSystem
        Task.detached(priority: .userInitiated) {
            let availableColors = await MainActor.run { inventoryManager.beadColors }
            let placeholderCells: [[String?]] = Array(
                repeating: Array(repeating: nil, count: colsCopy), count: rowsCopy
            )
            let placeholder = BeadPatternGrid(
                corners: cornersCopy, rows: rowsCopy, cols: colsCopy,
                cellColorCodes: placeholderCells,
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
                presentHighlight = true
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

extension GridCorners {
    /// 默认四角占图片 10%~90%
    static let initialQuad = GridCorners(
        topLeft: CGPoint(x: 0.1, y: 0.1),
        topRight: CGPoint(x: 0.9, y: 0.1),
        bottomLeft: CGPoint(x: 0.1, y: 0.9),
        bottomRight: CGPoint(x: 0.9, y: 0.9)
    )
}

enum CornerLabel: CaseIterable {
    case tl, tr, bl, br
}

private struct CornerHandle: View {
    let label: CornerLabel
    @Binding var corners: GridCorners
    let displayRect: CGRect

    var body: some View {
        let p = currentPoint
        Circle()
            .fill(Color.red.opacity(0.8))
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
        case .tl: corners.topLeft = norm
        case .tr: corners.topRight = norm
        case .bl: corners.bottomLeft = norm
        case .br: corners.bottomRight = norm
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
