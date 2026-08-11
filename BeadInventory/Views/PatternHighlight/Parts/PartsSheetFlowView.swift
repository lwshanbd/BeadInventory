//
//  PartsSheetFlowView.swift
//  BeadInventory
//
//  多零件模式（立体图纸）- 整条流程的容器
//
//  三屏，一屏一件事，每屏底部都有明确的「下一步」：
//
//      ① 圈零件区   把中间那一大块框住（排除顶部色号表 / 底部装配图）
//      ② 零件清单   自动拆出来的零件，能删、能合并、能改名、能调灵敏度重拆
//      ③ 图纸调色板 这张图用了哪几种颜色，各代表什么色号 / 任意色 / 空
//
//  第 2 步（量格子大小 → 逐格识别 → 校色）接在 ③ 之后，届时从这里再往下推一屏。
//
//  刻意不复用 `PatternCalibrationView`：那一页是为「整张图一个大网格」设计的，
//  两套心智模型挤一屏用户会不知道该点哪个。
//

import SwiftUI

struct PartsSheetFlowView: View {
    let project: ProjectRecord

    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) private var dismiss

    /// 降采样后的整张图纸。所有分析和显示都基于它 ——
    /// 原图动辄十几 MB，整个流程里不留全分辨率副本。
    @State private var image: UIImage?
    @State private var didLoadOnce = false

    @State private var path: [Step] = []

    /// 零件区（归一化）。首次进来给一个「中间大半张」的初值，比从 0.1~0.9 开始少拖几下。
    @State private var roi = CGRect(x: 0.05, y: 0.18, width: 0.90, height: 0.52)
    @State private var parts: [BeadPart] = []
    @State private var palette: [PartsPaletteEntry] = []
    @State private var calibration: PartsGridCalibration?
    @State private var anyColorCode: String?

    /// 拆分灵敏度（0~1）。拆多了 / 拆少了，用户在清单页拉这根滑杆重拆。
    @State private var sensitivity: Double = 0.5
    @State private var busy: String?

    enum Step: Hashable { case list, palette }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !didLoadOnce {
                    ProgressView("加载图纸…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let image {
                    PartsRegionStepView(
                        image: image,
                        roi: $roi,
                        onContinue: { runDetection(resetSensitivity: true) }
                    )
                } else {
                    ContentUnavailableView(
                        "项目还没有图纸",
                        systemImage: "photo.badge.exclamationmark",
                        description: Text("先在项目详情里加一张图纸，再回来用多零件模式。")
                    )
                }
            }
            .navigationTitle("多零件模式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .list:
                    if let image {
                        PartsListStepView(
                            image: image,
                            roi: roi,
                            parts: $parts,
                            sensitivity: $sensitivity,
                            onRedetect: { runDetection(resetSensitivity: false) },
                            onContinue: { buildPalette() }
                        )
                    }
                case .palette:
                    PartsPaletteStepView(
                        palette: $palette,
                        colorSystem: project.colorSystem,
                        partCount: parts.count,
                        onFinish: { save() }
                    )
                    .environmentObject(inventoryManager)
                }
            }
            .overlay {
                if let busy {
                    ZStack {
                        Color.black.opacity(0.25).ignoresSafeArea()
                        ProgressView(busy)
                            .padding(Theme.Spacing.lg)
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                    }
                    .transition(.opacity)
                }
            }
        }
        .task { await load() }
    }

    // MARK: - 载入

    private func load() async {
        let id = project.id
        let loader = inventoryManager.imageLoader
        let data = await loader?.thumbnail(for: id)
        let saved = await loader?.partsSheet(for: id)
        // 原图不整张解码 —— 2000px 对拆零件和取色都绰绰有余（一格还剩 10 px 上下），
        // 而全分辨率解码是 jetsam 的老路。
        let downsampled = data.flatMap { ImageDownsampler.downsampleToUIImage($0, maxPixelSize: 2000) }
        guard !Task.isCancelled else { return }

        self.image = downsampled
        if let saved {
            self.roi = saved.roi
            self.parts = saved.parts
            self.palette = saved.palette
            self.calibration = saved.calibration
            self.anyColorCode = saved.anyColorCode
        }
        self.didLoadOnce = true

        // 拆过零件就直接回到清单 —— 用户上次已经圈好区了，不该再让他重圈一遍。
        if let saved, !saved.parts.isEmpty, downsampled != nil {
            self.path = [.list]
        }
    }

    // MARK: - 拆零件

    private func runDetection(resetSensitivity: Bool) {
        guard let image else { return }
        if resetSensitivity { sensitivity = 0.5 }
        let options = PartsDetectionOptions.fromSensitivity(sensitivity)
        let currentROI = roi
        busy = "正在拆零件…"

        Task.detached(priority: .userInitiated) {
            let detected = PartsDetector.detect(in: image, roi: currentROI, options: options)
            let newParts = detected.map { BeadPart(rowBand: $0.rowBand, bounds: $0.bounds) }
            await MainActor.run {
                self.parts = newParts
                self.busy = nil
                if self.path.isEmpty { self.path = [.list] }
            }
        }
    }

    // MARK: - 调色板

    private func buildPalette() {
        guard let image else { return }
        let currentROI = roi
        let bounds = parts.map(\.bounds)
        let colorSystem = project.colorSystem
        let legend = project.beadUsage.map(\.colorCode)
        let colors = inventoryManager.beadColors
        let existing = palette
        busy = "正在读取图纸配色…"

        Task.detached(priority: .userInitiated) {
            guard let bitmap = PartsBitmap.make(from: image, roi: currentROI, maxPixels: 1_600_000) else {
                await MainActor.run { self.busy = nil }
                return
            }
            var built = PartsPaletteExtractor.buildInitialPalette(
                bitmap: bitmap,
                partBounds: bounds,
                colorSystem: colorSystem,
                legendCodes: legend,
                availableColors: colors
            )
            // 用户上次已经认领过的颜色要对回去 —— 重跑一次不该把人工结论冲掉。
            //
            // 按颜色距离对而不是按 hex 字符串对：零件框动一下，聚类中心就可能挪到
            // 相邻的量化桶里，hex 一变人工结论就全丢了。ΔE ≤ 6 是「同一种颜色的抖动」
            // 量级，比调色板自身 12 的合并阈值小一半，不会张冠李戴。
            built = built.map { entry in
                guard let entryLab = GridCellSampler.lab(forHex: entry.hex) else { return entry }
                let prev = existing.min { a, b in
                    let da = GridCellSampler.lab(forHex: a.hex).map { GridCellSampler.deltaE($0, entryLab) } ?? .infinity
                    let db = GridCellSampler.lab(forHex: b.hex).map { GridCellSampler.deltaE($0, entryLab) } ?? .infinity
                    return da < db
                }
                guard let prev,
                      let prevLab = GridCellSampler.lab(forHex: prev.hex),
                      GridCellSampler.deltaE(prevLab, entryLab) <= 6 else { return entry }
                var merged = entry
                merged.role = prev.role
                merged.matchDeltaE = prev.matchDeltaE
                return merged
            }
            await MainActor.run {
                self.palette = built
                self.busy = nil
                self.path = [.list, .palette]
            }
        }
    }

    // MARK: - 保存

    private func save() {
        guard let image else { return }
        let sheet = BeadPartsSheet(
            roi: roi,
            workingImageSize: image.size,
            colorSystem: project.colorSystem,
            parts: parts,
            palette: palette,
            calibration: calibration,
            anyColorCode: anyColorCode
        )
        inventoryManager.updateProjectPartsSheet(project.id, sheet: sheet)
        dismiss()
    }
}
