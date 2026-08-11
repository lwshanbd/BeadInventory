//
//  PartsCellSizeStepView.swift
//  BeadInventory
//
//  多零件模式 · 第 ③ 屏 - 量一格有多大
//
//  这一屏只回答一个问题：**一格有多大**。有了它，每个零件就能切成整数行列，
//  「这个色号有多少颗、分别是哪几格」才有意义。
//
//  验收标准是眼睛：网格线必须落在豆子和豆子的缝上。所以这屏的主体是一个零件的
//  大图 + 铺在上面的网格线，对没对齐一眼就知道，不需要用户去理解任何数值。
//
//  进来时算法先猜一个（`PartsPitchEstimator`），多数情况下用户只是点头确认。
//  不对就在图上拖一个框套住任意一格，网格立刻按这个大小重铺。
//

import SwiftUI

struct PartsCellSizeStepView: View {
    let image: UIImage
    let parts: [BeadPart]
    @Binding var calibration: PartsGridCalibration?
    let onContinue: () -> Void

    /// 当前正在看哪个零件（按面积从大到小排）。大零件格线多，最容易看出没对齐。
    @State private var sampleIndex = 0
    @State private var sampleImage: UIImage?
    /// 样板零件在画布上对应的那块图（归一化，相对整张图）—— 画网格线时要把
    /// 贴合结果换算回画布坐标，得知道画布画的到底是哪一块。
    @State private var sampleRegion: CGRect = .zero
    @State private var fitted: PartsPitchEstimator.FittedGrid?
    @State private var draftRect: CGRect?
    @State private var estimating = true

    /// 按面积从大到小；只留大的那些当样板，小零件放大了也看不出对没对齐。
    private var samples: [BeadPart] {
        parts.sorted { $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height }
            .prefix(12).map { $0 }
    }

    private var sample: BeadPart? {
        guard !samples.isEmpty else { return nil }
        return samples[min(sampleIndex, samples.count - 1)]
    }

    private var sampleGrid: (rows: Int, cols: Int)? {
        guard let fitted else { return nil }
        return (fitted.rows, fitted.cols)
    }

    var body: some View {
        VStack(spacing: 0) {
            canvas
            footer
        }
        .navigationTitle("量格子")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: sampleIndex) { await loadSample() }
        .task { await estimateIfNeeded() }
    }

    // MARK: - 画布

    private var canvas: some View {
        GeometryReader { geo in
            let display = PartsRegionStepView.aspectFitRect(
                imageSize: sampleImage?.size ?? CGSize(width: 1, height: 1),
                in: geo.size
            )
            ZStack(alignment: .topLeading) {
                Theme.ColorToken.Surface.subtle

                if let sampleImage {
                    Image(uiImage: sampleImage)
                        .resizable()
                        // 像素画放大要用最近邻：插值会把格子边缘糊成渐变，
                        // 用户就没法判断网格线到底压没压在缝上。
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                }

                if let fitted, sampleRegion.width > 0, sampleRegion.height > 0 {
                    CellGridOverlay(grid: fitted, region: sampleRegion, displayRect: display)
                        .allowsHitTesting(false)
                }

                if let draftRect {
                    Rectangle()
                        .strokeBorder(Theme.ColorToken.Morandi.honey, lineWidth: 2)
                        .background(Rectangle().fill(Theme.ColorToken.Morandi.honey.opacity(0.25)))
                        .frame(width: max(draftRect.width, 1), height: max(draftRect.height, 1))
                        .position(x: draftRect.midX, y: draftRect.midY)
                        .allowsHitTesting(false)
                }

                if estimating {
                    ProgressView("正在量…")
                        .padding()
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { value in
                        draftRect = CGRect(corner: value.startLocation, to: value.location)
                            .intersection(display)
                    }
                    .onEnded { value in
                        let drawn = CGRect(corner: value.startLocation, to: value.location)
                            .intersection(display)
                        draftRect = nil
                        applyDrawnCell(drawn, displayRect: display)
                    }
            )
        }
        .clipped()
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(spacing: Theme.Spacing.md) {
            if let sample, let grid = sampleGrid {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(sample.displayName(order: sampleIndex))
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(Theme.ColorToken.Text.primary)
                    Text("\(grid.cols) × \(grid.rows) 格")
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(Theme.ColorToken.Morandi.mauve)
                    Spacer()
                    Button {
                        sampleIndex = (sampleIndex + 1) % max(samples.count, 1)
                    } label: {
                        Label("换一个看看", systemImage: "arrow.triangle.2.circlepath")
                            .font(.footnote)
                    }
                    .disabled(samples.count < 2)
                }
            }

            Text("网格线要正好落在豆子和豆子的缝上。没对齐的话，在图上拖一个框，正好套住一格。")
                .font(.footnote)
                .foregroundStyle(Theme.ColorToken.Text.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onContinue) {
                Label("对齐了，看每格什么颜色", systemImage: "eyedropper")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(calibration == nil || estimating)
        }
        .padding()
        .background(.regularMaterial)
    }

    // MARK: - 逻辑

    private func estimateIfNeeded() async {
        guard calibration == nil else {
            estimating = false
            return
        }
        let img = image
        let snapshot = parts
        let guessed = await Task.detached(priority: .userInitiated) {
            PartsPitchEstimator.estimate(image: img, parts: snapshot)
        }.value
        // 一个都没量出来时给一个保底值：按最大零件横向 12 格算。
        // 宁可给个明显不对的初值让用户去拖，也不要空着让他面对一张没有网格线的图。
        calibration = guessed ?? fallbackCalibration()
        estimating = false
        await refitSample()
    }

    private func fallbackCalibration() -> PartsGridCalibration? {
        guard let biggest = samples.first else { return nil }
        return PartsGridCalibration(
            cellWidth: Double(biggest.bounds.width) / 12,
            cellHeight: Double(biggest.bounds.height) / 12
        )
    }

    private func loadSample() async {
        guard let sample else { return }
        let img = image
        // 四周留一点余量，让用户看得见零件外沿那一圈是不是也被网格线切到了
        let padded = sample.bounds
            .insetBy(dx: -sample.bounds.width * 0.06, dy: -sample.bounds.height * 0.06)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let cropped = await Task.detached(priority: .userInitiated) {
            PartsThumbnailMaker.crop(img, normalized: padded)
        }.value
        sampleImage = cropped
        sampleRegion = padded
        await refitSample()
    }

    /// 把网格重新贴到当前这个样板零件上。格距一改就要重贴 —— 用户拖完框
    /// 立刻要看到线挪没挪对。
    private func refitSample() async {
        guard let sample, let calibration else { return }
        let img = image
        fitted = await Task.detached(priority: .userInitiated) {
            PartsPitchEstimator.fitGrid(image: img, part: sample, calibration: calibration)
        }.value
    }

    /// 用户拖出来的那个框 = 一格。换算回整张图的归一化尺寸就是新的格距。
    ///
    /// 注意用的是**框的尺寸**，不是位置 —— 格子边界由零件 bbox 均分得出，
    /// 用户在哪一格上拖都一样，不必去找第一格。
    private func applyDrawnCell(_ drawn: CGRect, displayRect: CGRect) {
        guard displayRect.width > 0, displayRect.height > 0,
              sampleRegion.width > 0, sampleRegion.height > 0 else { return }
        guard drawn.width >= 6, drawn.height >= 6 else { return }

        let w = Double(drawn.width / displayRect.width) * Double(sampleRegion.width)
        let h = Double(drawn.height / displayRect.height) * Double(sampleRegion.height)
        guard w > 0, h > 0 else { return }
        calibration = PartsGridCalibration(cellWidth: w, cellHeight: h)
        Task { await refitSample() }
    }
}

// MARK: - 网格线

private struct CellGridOverlay: View {
    /// 贴合后的网格（归一化，相对整张图）
    let grid: PartsPitchEstimator.FittedGrid
    /// 画布上画的是整张图的哪一块（归一化）
    let region: CGRect
    /// 那块图在屏幕上占的位置
    let displayRect: CGRect

    var body: some View {
        Canvas { context, _ in
            guard grid.rows > 0, grid.cols > 0,
                  region.width > 0, region.height > 0,
                  displayRect.width > 0 else { return }

            func screenX(_ normalized: CGFloat) -> CGFloat {
                displayRect.minX + (normalized - region.minX) / region.width * displayRect.width
            }
            func screenY(_ normalized: CGFloat) -> CGFloat {
                displayRect.minY + (normalized - region.minY) / region.height * displayRect.height
            }

            let cw = grid.rect.width / CGFloat(grid.cols)
            let ch = grid.rect.height / CGFloat(grid.rows)
            let top = screenY(grid.rect.minY), bottom = screenY(grid.rect.maxY)
            let left = screenX(grid.rect.minX), right = screenX(grid.rect.maxX)

            for c in 0...grid.cols {
                var path = Path()
                let x = screenX(grid.rect.minX + CGFloat(c) * cw)
                path.move(to: CGPoint(x: x, y: top))
                path.addLine(to: CGPoint(x: x, y: bottom))
                context.stroke(path, with: .color(.cyan.opacity(0.85)), lineWidth: 1)
            }
            for r in 0...grid.rows {
                var path = Path()
                let y = screenY(grid.rect.minY + CGFloat(r) * ch)
                path.move(to: CGPoint(x: left, y: y))
                path.addLine(to: CGPoint(x: right, y: y))
                context.stroke(path, with: .color(.cyan.opacity(0.85)), lineWidth: 1)
            }
        }
    }
}
