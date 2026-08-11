//
//  PartsSheetFlowView.swift
//  BeadInventory
//
//  多零件模式（立体图纸）- 整条流程的容器
//
//  两屏，一屏一件事：
//
//      ① 圈零件区   把中间那一大块框住（排除顶部色号表 / 底部成品图）
//      ② 零件清单   找出来的零件，能删、能合并、能拆开、能补、能改名
//
//  ## 这里曾经有第三屏「图纸调色板」，已经删掉
//
//  那一屏按像素占比列出图上的十几种颜色（「H7 占 10.6%」）让用户认领色号。
//  它是错的：拼豆用户是一颗一颗放豆子的，「占 10.6%」对他没有任何意义，
//  他要知道的是「这个色号有多少颗、分别是哪几格」。而那一屏统计的是**像素**，
//  当时连「格子」这个概念都还不存在 —— 网格还没对齐。
//
//  正确的顺序是：量出一格多大 → 每个零件切成 rows × cols → 每格判一个色号 →
//  按色号把格子摆出来让用户校对。色号认领这件事属于那一屏，不该提前到这里。
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

    @State private var busy: String?

    enum Step: Hashable { case list, cellSize, review }

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
                        onContinue: { runDetection() }
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
                            onContinue: { path = [.list, .cellSize] }
                        )
                    }
                case .cellSize:
                    if let image {
                        PartsCellSizeStepView(
                            image: image,
                            parts: parts,
                            calibration: $calibration,
                            onContinue: { runClassification() }
                        )
                    }
                case .review:
                    if let image {
                        PartsColorReviewStepView(
                            image: image,
                            parts: $parts,
                            colorSystem: project.colorSystem,
                            onFinish: { save() }
                        )
                        .environmentObject(inventoryManager)
                    }
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

    /// 找零件只有这一个入口，也没有任何可调的旋钮 —— 阈值是算法的事，不是用户要理解的东西。
    /// 结果不对，用户在清单页直接改图上的框（删 / 补 / 合并 / 拆开）；
    /// 要是连零件区都圈错了，返回上一屏挪一下框再点一次就是重来。
    private func runDetection() {
        guard let image else { return }
        let options = PartsDetectionOptions()
        let currentROI = roi
        busy = "正在找零件…"

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

    // MARK: - 逐格判色

    private func runClassification() {
        guard let image, let calibration else { return }
        let snapshot = parts
        let currentROI = roi
        let colorSystem = project.colorSystem
        let legend = project.beadUsage.map(\.colorCode)
        let colors = inventoryManager.beadColors
        busy = "正在看每格什么颜色…"

        Task.detached(priority: .userInitiated) {
            let result = PartsCellClassifier.classify(
                image: image,
                parts: snapshot,
                roi: currentROI,
                calibration: calibration,
                colorSystem: colorSystem,
                legendCodes: legend,
                availableColors: colors,
                progress: { done, total in
                    Task { @MainActor in busy = "正在看每格什么颜色…（\(done)/\(total)）" }
                }
            )
            await MainActor.run {
                self.parts = result.parts
                self.palette = result.palette
                self.busy = nil
                self.path = [.list, .cellSize, .review]
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
