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

    /// 整张图纸的低清版，只给第一屏「圈零件区」用 —— 那屏本来就只要看个大概。
    @State private var overview: UIImage?
    /// 零件区的高清版。圈完区之后现裁，后面所有步骤（找零件 / 量格子 / 判色 / 抠格子）都用它。
    ///
    /// 之前整条流程都跑在「整张图长边压到 2000px」上：图纸是竖长条，2000 全给了高度，
    /// 宽度只剩八百多，零件区又只占其中一半，一格豆子最后只有十来个像素 —— 肉眼可见的糊。
    /// 同样的内存预算，全花在真正要看的那块上，一格能到三十来个像素。
    @State private var work: PartsWorkImage?
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
                } else if let overview {
                    PartsRegionStepView(
                        image: overview,
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
                // 高清工作图还没裁好时给一个明确的「正在准备」——
                // 早先这里是 `if let work { ... }`，work 为 nil 就整页空白，
                // 用户看到的是一块什么都没有的黑屏，不知道是在转还是坏了。
                Group {
                    if let work {
                        switch step {
                        case .list:
                            PartsListStepView(
                                work: work,
                                roi: roi,
                                parts: $parts,
                                onContinue: { path = [.list, .cellSize] }
                            )
                        case .cellSize:
                            PartsCellSizeStepView(
                                work: work,
                                parts: $parts,
                                calibration: $calibration,
                                onContinue: { runClassification() }
                            )
                        case .review:
                            PartsColorReviewStepView(
                                work: work,
                                parts: $parts,
                                colorSystem: project.colorSystem,
                                onFinish: { save() }
                            )
                            .environmentObject(inventoryManager)
                        }
                    } else {
                        ProgressView("正在准备图纸…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Theme.ColorToken.Surface.background)
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
        let low = data.flatMap { ImageDownsampler.downsampleToUIImage($0, maxPixelSize: Self.overviewMaxPixel) }
        guard !Task.isCancelled else { return }

        self.overview = low
        // 先用低清版兜底，保证后面每一屏立刻有图可用。
        // 高清版是「更好」，不是「必需」—— 早先把它做成必需，一旦裁失败或者还没裁完，
        // 用户面对的就是一个永远转不完的 spinner，没有任何出路。
        if let low { self.work = .whole(low) }
        if let saved {
            self.roi = saved.roi
            self.parts = saved.parts
            self.palette = saved.palette
            self.calibration = saved.calibration
            self.anyColorCode = saved.anyColorCode
        }
        self.didLoadOnce = true

        // 拆过零件就直接回到清单 —— 用户上次已经圈好区了，不该再让他重圈一遍。
        if let saved, !saved.parts.isEmpty, low != nil {
            self.path = [.list]
        }
        // 高清版在后台换上去，换好之后界面自己刷新，用户不用等
        await prepareWorkImage()
    }

    /// 整张图纸的低清版长边上限。这一版只给「圈零件区」看轮廓，1600 足够，
    /// 也把首屏的解码代价压到最低。
    private static let overviewMaxPixel = 1600

    /// 零件区高清版的长边上限。3600 是「一格三十来个像素」和「内存别失控」之间的折中：
    /// 解码整图时会有一次约 20 MB 的瞬时峰值，裁完只留零件区那块（约一半），
    /// 且只在多零件模式开着的时候常驻。
    private static let workMaxPixel = 3600

    /// 已经裁到高清版的那块区域。用来判断「要不要重裁」，
    /// 不能拿 `work.region` 判 —— 低清兜底版的 region 是整张图，会被误认成没裁过。
    @State private var highResRegion: CGRect?
    @State private var upgradingWorkImage = false

    /// 从原图裁出零件区的高清版，换掉低清兜底版。
    /// 失败就什么都不做 —— 低清版还在，流程照样往下走，只是图糊一点。
    private func prepareWorkImage() async {
        guard highResRegion != roi, !upgradingWorkImage else { return }
        upgradingWorkImage = true
        defer { upgradingWorkImage = false }

        let id = project.id
        let loader = inventoryManager.imageLoader
        guard let data = await loader?.thumbnail(for: id) else { return }
        let region = roi
        let built = await Task.detached(priority: .userInitiated) { () -> PartsWorkImage? in
            // autoreleasepool：整图那份大 CGImage 用完立刻还回去，只留裁出来的那块
            autoreleasepool {
                guard let full = ImageDownsampler.downsampleToUIImage(data, maxPixelSize: Self.workMaxPixel),
                      let cropped = PartsThumbnailMaker.crop(.whole(full), normalized: region) else { return nil }
                return PartsWorkImage(image: cropped, region: region)
            }
        }.value
        guard let built else {
            AppLogger.shared.warning("PartsSheet", "work_image_upgrade_failed", metadata: [
                "projectId": id.uuidString
            ])
            return
        }
        self.work = built
        self.highResRegion = region
    }

    // MARK: - 拆零件

    /// 找零件只有这一个入口，也没有任何可调的旋钮 —— 阈值是算法的事，不是用户要理解的东西。
    /// 结果不对，用户在清单页直接改图上的框（删 / 补 / 合并 / 拆开）；
    /// 要是连零件区都圈错了，返回上一屏挪一下框再点一次就是重来。
    private func runDetection() {
        let currentROI = roi
        busy = "正在找零件…"

        Task {
            await prepareWorkImage()
            guard let source = work else {
                busy = nil
                return
            }
            let detected = await Task.detached(priority: .userInitiated) {
                PartsDetector.detect(in: source, roi: currentROI, options: PartsDetectionOptions())
            }.value
            self.parts = detected.map { BeadPart(rowBand: $0.rowBand, bounds: $0.bounds) }
            // 换了零件区就等于换了一张图纸，之前量的格子和判的色全部作废
            self.calibration = nil
            self.busy = nil
            if self.path.isEmpty { self.path = [.list] }
        }
    }

    // MARK: - 逐格判色

    private func runClassification() {
        guard let work, let calibration else { return }
        let snapshot = parts
        let currentROI = roi
        let colorSystem = project.colorSystem
        let legend = project.beadUsage.map(\.colorCode)
        let colors = inventoryManager.beadColors
        busy = "正在看每格什么颜色…"

        Task.detached(priority: .userInitiated) {
            let result = PartsCellClassifier.classify(
                work: work,
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
        guard let work else { return }
        let sheet = BeadPartsSheet(
            roi: roi,
            workingImageSize: work.image.size,
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
