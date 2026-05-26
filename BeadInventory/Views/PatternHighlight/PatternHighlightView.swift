//
//  PatternHighlightView.swift
//  BeadInventory
//
//  拼图模式主视图 - 图 + 高亮叠层 + 调色板 + 辅助线
//

import SwiftUI

struct PatternHighlightView: View {
    let project: ProjectRecord

    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) private var dismiss

    @State private var highlightedCodes: Set<String> = []
    @State private var guideMode: GuideMode = .off
    @State private var showingRecalibrate = false
    @State private var showingDiffSheet = false
    @State private var dismissedBanner = false

    // thumbnail / patternGrid 改成按需异步加载（v2.0.x 之后 ProjectRecord 不再持有它们）。
    @State private var loadedImage: UIImage?
    @State private var loadedGrid: BeadPatternGrid?
    /// 取图任务是否已经跑完一轮 —— 用于区分「正在加载」与「确定没有」。
    @State private var didLoadOnce: Bool = false

    private var currentProject: ProjectRecord {
        inventoryManager.projects.first { $0.id == project.id } ?? project
    }

    /// 在 cellColorCodes 出现但不在 beadUsage 的色号 + 出现次数。
    /// 典型场景：MARD 的 H2 用作空白格识别，但用户没把 H2 写进图例。
    private var extraCodes: [(code: String, count: Int)] {
        guard let grid = loadedGrid else { return [] }
        let legend = Set(currentProject.beadUsage.map { $0.colorCode })
        var counts: [String: Int] = [:]
        for row in grid.cellColorCodes {
            for cell in row {
                if let c = cell, !legend.contains(c) {
                    counts[c, default: 0] += 1
                }
            }
        }
        return counts.map { (code: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let grid = loadedGrid {
                    let mismatches = GridValidator.mismatches(grid: grid, beadUsage: currentProject.beadUsage)
                    if !mismatches.isEmpty && !dismissedBanner {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.ColorToken.Status.warning)
                            Text("网格与图例有 \(mismatches.count) 处差异")
                                .font(.footnote)
                            Spacer()
                            Button("详情") { showingDiffSheet = true }
                                .font(.footnote)
                            Button { dismissedBanner = true } label: {
                                Image(systemName: "xmark")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.ColorToken.Text.secondary)
                        }
                        .padding(8)
                        .background(Theme.ColorToken.Status.warning.opacity(0.15))
                    }
                }

                if !didLoadOnce {
                    ProgressView("加载中…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let img = loadedImage, let grid = loadedGrid {
                    ZoomablePatternCanvas(image: img) { rect in
                        PatternHighlightOverlay(
                            grid: grid,
                            highlightedCodes: highlightedCodes,
                            guideMode: guideMode,
                            displayRect: rect
                        )
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "questionmark.square.dashed")
                            .font(.system(size: 60))
                            .foregroundStyle(Theme.ColorToken.Text.secondary)
                        Text(loadedImage == nil ? "项目无图片" : "未标定网格")
                            .foregroundStyle(Theme.ColorToken.Text.secondary)
                        if loadedImage != nil && loadedGrid == nil {
                            Button("开始标定") {
                                showingRecalibrate = true
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                ColorPaletteBar(
                    beadUsage: currentProject.beadUsage,
                    extraCodes: extraCodes,
                    colorSystem: currentProject.colorSystem,
                    highlightedCodes: $highlightedCodes,
                    availableColors: inventoryManager.beadColors
                )
            }
            .navigationTitle(project.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section("辅助线") {
                            ForEach(GuideMode.allCases, id: \.self) { m in
                                Button {
                                    guideMode = m
                                } label: {
                                    if guideMode == m {
                                        Label(m.label, systemImage: "checkmark")
                                    } else {
                                        Text(m.label)
                                    }
                                }
                            }
                        }
                        Divider()
                        Button {
                            highlightedCodes.removeAll()
                        } label: {
                            Label("清除高亮", systemImage: "eye.slash")
                        }
                        Button {
                            showingRecalibrate = true
                        } label: {
                            Label("重新标定", systemImage: "square.grid.3x3.square")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showingRecalibrate) {
                PatternCalibrationView(project: currentProject)
                    .environmentObject(inventoryManager)
            }
            .sheet(isPresented: $showingDiffSheet) {
                if let grid = loadedGrid {
                    ValidationDiffSheet(
                        diffs: GridValidator.mismatches(grid: grid, beadUsage: currentProject.beadUsage),
                        onAdoptGridForCode: { code, gridCount in
                            inventoryManager.updatePlannedProjectUsage(currentProject.id, colorCode: code, newQuantity: gridCount)
                        }
                    )
                }
            }
            .task(id: "\(project.id.uuidString)-\(inventoryManager.projectBlobsRevision)") {
                let id = project.id
                let thumbData = inventoryManager.fetchProjectThumbnailData(for: id)
                let grid = inventoryManager.fetchProjectPatternGrid(for: id)
                guard !Task.isCancelled, id == project.id else { return }
                self.loadedImage = thumbData.flatMap { UIImage(data: $0) }
                self.loadedGrid = grid
                self.didLoadOnce = true
            }
        }
    }
}
