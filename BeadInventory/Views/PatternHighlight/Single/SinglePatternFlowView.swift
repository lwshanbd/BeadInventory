//
//  SinglePatternFlowView.swift
//  BeadInventory
//
//  单图纸模式（一张平面图纸）- 整条流程的容器
//
//  五屏，一屏一件事。顺序就是下面这个表，也就是 `Step` 的顺序 ——
//  屏号只写在这里，各屏自己的文件里不再写「第 ③ 屏」，免得插一屏就得挨个改注释：
//
//      裁图纸    把图纸上真正是格子的那一块框住（排除色号表、留白、水印）。这是根视图。
//      量格子    一格多大、格线在哪。行列数由它算出来，不用用户去数。
//      底色      在图上点一下哪一片是留白。判色前必须先把它摘出去。
//      核对颜色  每个色号有多少颗、分别是哪几格，用户逐条校对
//      照着拼    点一个色号，图上只亮它那些格子
//
//  ## 跟多零件模式是同一套东西，少了「零件」这一层
//
//  多零件模式（`PartsSheetFlowView`）是「一张图上排着几十个小零件」，所以它要多两屏：
//  找零件、摆拼豆板。单图纸没有零件这个概念 —— 整张图纸就是一整块，
//  所以内部干脆拿**一个覆盖整张裁切区的 `BeadPart`** 装它：
//  量格子、判色、核对颜色三屏于是跟多零件模式共用同一套代码和同一套操作习惯。
//
//  ## 上一版是什么样、为什么全换掉
//
//  上一版（`PatternCalibrationView`，已删）是**一屏干完所有事**：拖四个红角点框住网格、
//  手填行列数、按一次「开始标定」，然后一条几十秒的进度条跑完直接跳到高亮页。
//  三个问题，每一个都是用户实际卡住的地方：
//
//  - **要用户数格子。** 一张 60×80 的图纸，数一遍好几分钟，数错一格整张图全错，
//    而且错在哪儿他自己看不出来 —— 网格只是均匀地偏了一点点。
//  - **判色没有出口。** 认错的色号只能在高亮页发现，而那一页改不了任何东西，
//    唯一的选择是整张重来一遍。
//  - **一步存一次都没有。** 中途退出去 = 全部作废。
//
//  现在跟多零件模式一样：一步一屏、每步都存、判完色有一整屏专门用来改。
//

import SwiftUI

struct SinglePatternFlowView: View {
    let project: ProjectRecord

    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    /// 整张图纸那一版，给第一屏「裁图纸」用。
    @State private var overview: UIImage?
    /// 有字节但解不出图。跟「这个项目本来就没有图」是两回事，说法也不一样。
    @State private var imageUnreadable = false
    /// 裁切区的高清版。裁完之后现裁，后面所有步骤（量格子 / 判色 / 抠格子 / 高亮）都用它。
    @State private var work: PartsWorkImage?
    @State private var didLoadOnce = false

    @State private var path: [Step] = []

    /// 用户裁的那块（归一化）。首次进来给一个「中间大半张」的初值，比从头拖少几下。
    @State private var roi = CGRect(x: 0.06, y: 0.06, width: 0.88, height: 0.88)
    @State private var calibration: PartsGridCalibration?
    /// 整张图纸当成一块。行列 / 格子范围 / 每格什么颜色都在它身上。
    @State private var sheet = BeadPart(rowBand: 0, bounds: .zero)
    @State private var emptyHex: String?

    /// 老数据里的四角。上一版允许把网格拉成梯形（容忍轻微透视），新流程算出来的
    /// 永远是矩形 —— 但**老项目存的梯形必须原样留着**，否则用户一进来就发现
    /// 高亮的格子跟图上对不齐了。只在还没用新流程重对过（`calibration == nil`）时有效。
    @State private var legacyCorners: GridCorners?

    @State private var busy: String?

    /// 这次会话真的改过东西（后面几屏都是通过 binding 直接改这里的 @State，
    /// 容器这边看不见「改了什么」，所以交出去的 binding 都包一层 `tracked`）。
    @State private var dirty = false
    /// 库里那份读不出来 → **禁止覆写**，直到用户明说要重做。
    @State private var overwriteBlocked = false
    /// 工作图换过几次源。补完原图会 +1，让「裁切范围没变就不用重裁」那条判断知道
    /// 底下的图其实换了。
    @State private var sourceGeneration = 0

    enum Step: Hashable { case grid, baseColor, review, highlight }

    /// 现在要跟用户说的那一句话。收成一个值，「同时只有一句话」就成了类型层面的事实
    /// （理由同 `PartsSheetFlowView.Prompt`：两个 alert 同时置起时 SwiftUI 只显示一个，
    /// 被吞掉的那个会让某个按钮既没反应也没有说法）。
    private enum Prompt: Identifiable {
        case saveFailed
        case loadFailed
        /// 改了裁切范围，已经判好的颜色要重来。
        case confirmRecrop
        /// 判色时图根本没抠出来。
        case classifyFailed

        var id: String {
            switch self {
            case .saveFailed: return "save"
            case .loadFailed: return "load"
            case .confirmRecrop: return "recrop"
            case .classifyFailed: return "classify"
            }
        }
    }

    @State private var prompt: Prompt?

    private func tracked<Value>(_ binding: Binding<Value>) -> Binding<Value> {
        Binding(get: { binding.wrappedValue },
                set: { dirty = true; binding.wrappedValue = $0 })
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !didLoadOnce {
                    ProgressView("加载图纸…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let overview {
                    PartsRegionStepView(
                        image: overview,
                        roi: tracked($roi),
                        onContinue: { startCalibration() },
                        projectId: project.id,
                        onSourceLoaded: { Task { await reloadFromSource() } },
                        hint: "拖动方框，把图纸上一格一格的那块框住。四周的色号表、留白不用框。",
                        actionTitle: "量格子",
                        actionIcon: "grid"
                    )
                } else if imageUnreadable {
                    ContentUnavailableView(
                        "这张图纸这次读不出来",
                        systemImage: "photo.badge.exclamationmark",
                        description: Text("图还在项目里，只是这次打不开。退出去再进来试一次；一直这样的话，去详情页重新选一张。")
                    )
                } else {
                    ContentUnavailableView(
                        "项目还没有图纸",
                        systemImage: "photo.badge.exclamationmark",
                        description: Text("先在项目详情里加一张图纸，再回来用单图纸模式。")
                    )
                }
            }
            .navigationTitle("单图纸模式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // 关掉就是关掉，不是丢掉 —— 每一步的结果都已经存过了（见 persist）。
                    Button("关闭") {
                        if persist() { dismiss() }
                    }
                }
            }
            .navigationDestination(for: Step.self) { step in
                // 高清工作图还没裁好时给一句明确的「正在准备」——
                // 空白一片的话用户不知道是在转还是坏了。
                Group {
                    if let work {
                        switch step {
                        case .grid:
                            SinglePatternGridStepView(
                                work: work,
                                roi: roi,
                                sheet: tracked($sheet),
                                calibration: tracked($calibration),
                                onContinue: {
                                    persist()
                                    path = [.grid, .baseColor]
                                }
                            )
                        case .baseColor:
                            PartsBaseColorStepView(
                                work: work,
                                roi: roi,
                                calibration: calibration,
                                emptyHex: tracked($emptyHex),
                                // 单图纸没有「任意色」这一档，所以这个 binding 永远不会被写。
                                anyColorHex: .constant(nil),
                                onContinue: { runClassification() },
                                showsAnyColor: false,
                                emptyHint: "图纸上没有豆子的那一片留白",
                                title: "底色"
                            )
                        case .review:
                            PartsColorReviewStepView(
                                work: work,
                                parts: sheetParts,
                                colorSystem: project.colorSystem,
                                legendCounts: legendCounts,
                                // 核对完一个色号就落盘。一张图纸几千格，
                                // 对到一半退出去不该白对（同多零件模式）。
                                onConfirmGroup: { persist() },
                                onFinish: {
                                    persist()
                                    path = [.grid, .baseColor, .review, .highlight]
                                },
                                allowsAnyColor: false,
                                finishTitle: { Text("开始拼 · 一共 \($0) 颗") },
                                finishIcon: "wand.and.rays"
                            )
                            .environmentObject(inventoryManager)
                        case .highlight:
                            highlightStep(work: work)
                        }
                    } else {
                        ProgressView("正在准备图纸…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Theme.ColorToken.Surface.background)
                    }
                }
            }
        }
        // **盖在整个 NavigationStack 上，不是盖在根视图上。** 判色是从「底色」那一屏
        // 按下去的，而那一屏是被 push 上来的 —— 转圈要是挂在根视图上，就整个被压在
        // 底下看不见：用户按完「开始判色」屏幕上什么都没发生，几十秒里他只能反复按。
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
        .task { await load() }
        // 切出去接个电话不该丢掉刚改的色号 —— 核对页的修改是直接落在 sheet 上的，
        // 不等到「完成」那一下。
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { persist() }
        }
        .alert(item: $prompt) { prompt in
            switch prompt {
            case .saveFailed:
                return Alert(
                    title: Text("这一步没存上"),
                    message: Text("刚做的这些还没写进项目里，现在关掉就没了。先别关，接着往下走每一步都会再存一次。"),
                    primaryButton: .cancel(Text("知道了")),
                    secondaryButton: .destructive(Text("仍然关闭")) { dismiss() }
                )
            case .loadFailed:
                return Alert(
                    title: Text("之前的进度这次打不开"),
                    message: Text("这个项目上次对好的网格和颜色这次读不出来。建议先退出去，过一会儿再进来试试；现在就重做的话，原来那份会被这次的结果盖掉。"),
                    primaryButton: .cancel(Text("先退出去")) { dismiss() },
                    secondaryButton: .destructive(Text("重新做一遍")) { overwriteBlocked = false }
                )
            case .confirmRecrop:
                return Alert(
                    title: Text("换了范围，颜色要重判一遍"),
                    message: Text("框住的范围变了，格子也就跟着变了。已经核对好的颜色会作废，要从量格子那一步重走。"),
                    primaryButton: .cancel(Text("取消")),
                    // 说了作废就真的作废。留着的话，用户要是没走完「判色」那一步就退出去，
                    // 存进库里的会是「新的格子范围 + 旧的那批颜色」—— 高亮出来整片错位，
                    // 而他刚刚才点头同意的是「重走一遍」。
                    secondaryButton: .destructive(Text("接着改")) {
                        sheet.cells = []
                        dirty = true
                        path = [.grid]
                    }
                )
            case .classifyFailed:
                return Alert(
                    title: Text("这块范围里取不到图"),
                    message: Text("一格颜色都没看出来，多半是框圈得太小或者位置不对。回第一屏把框重新拖一下再来一次。"),
                    dismissButton: .default(Text("回去改框")) { path = [] }
                )
            }
        }
    }

    /// 「照着拼」那一屏。网格是从当前状态现拼的 —— 用户在核对页刚改过的色号，
    /// 翻到这一屏就该是改过的样子。
    @ViewBuilder
    private func highlightStep(work: PartsWorkImage) -> some View {
        if let grid = currentGrid {
            SinglePatternHighlightStepView(
                project: project,
                work: work,
                grid: grid,
                onRecalibrate: { path = [] },
                onFinish: { save() }
            )
            .environmentObject(inventoryManager)
        } else {
            ContentUnavailableView(
                "这张图纸还没对好网格",
                systemImage: "square.grid.3x3.square",
                description: Text("回到前面几屏，把范围框好、把格子量好，再回来。")
            )
        }
    }

    // MARK: - 内部那一块「零件」

    /// 核对颜色那屏是跟多零件模式共用的，它吃的是一个零件数组。单图纸就是**一个**零件。
    private var sheetParts: Binding<[BeadPart]> {
        Binding(
            get: { [sheet] },
            set: { newValue in
                guard let first = newValue.first else { return }
                dirty = true
                sheet = first
            }
        )
    }

    /// 上一步 AI 读色号表得到的「每个色号多少颗」。核对颜色那屏拿它当参照。
    ///
    /// **key 要翻成当前体系的显示码**：`beadUsage.colorCode` 存的是 canonical mardCode，
    /// 而格子里存的是显示码，不翻的话卡卡 / COCO 图纸上两边一个都对不上，
    /// 「认出 X 颗 / 图纸写 Y 颗」的后半截一个字都不显示。
    /// 详细的坑（包括翻不对的那一种）见 `PartsSheetFlowView.legendCounts`。
    private var legendCounts: [String: Int] {
        project.beadUsage.reduce(into: [:]) { result, usage in
            let key = inventoryManager.findColor(byMardCode: usage.colorCode)?
                .displayCode(for: project.colorSystem) ?? usage.colorCode
            result[key, default: 0] += usage.quantity
        }
    }

    /// 当前状态拼成的网格。存盘和高亮页都用它 —— 一份状态一个出口，
    /// 免得「存下去的」和「画出来的」是两套算法。
    private var currentGrid: BeadPatternGrid? {
        guard sheet.rows > 0, sheet.cols > 0 else { return nil }
        let area = sheet.gridRect ?? sheet.bounds
        guard area.width > 0, area.height > 0 else { return nil }
        return BeadPatternGrid(
            corners: legacyCorners ?? Self.corners(of: area),
            rows: sheet.rows,
            cols: sheet.cols,
            cellColorCodes: codeMatrix,
            lastCalibratedAt: Date(),
            sourceImageSize: overview?.size ?? .zero,
            colorSystem: project.colorSystem,
            roi: roi,
            calibration: calibration,
            emptyHex: emptyHex
        )
    }

    /// `cells` → 存盘用的色号矩阵。空格写 nil（`BeadPatternGrid` 从第一版起就是这么约定的，
    /// 高亮、跟色号表对账、备份都按这个读）。
    private var codeMatrix: [[String?]] {
        guard sheet.rows > 0, sheet.cols > 0 else { return [] }
        var matrix = [[String?]](repeating: [String?](repeating: nil, count: sheet.cols), count: sheet.rows)
        for r in 0..<min(sheet.rows, sheet.cells.count) {
            for c in 0..<min(sheet.cols, sheet.cells[r].count) {
                if case .code(let code) = sheet.cells[r][c] { matrix[r][c] = code }
            }
        }
        return matrix
    }

    private static func corners(of rect: CGRect) -> GridCorners {
        GridCorners(
            topLeft: CGPoint(x: rect.minX, y: rect.minY),
            topRight: CGPoint(x: rect.maxX, y: rect.minY),
            bottomLeft: CGPoint(x: rect.minX, y: rect.maxY),
            bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        )
    }

    private static func boundingBox(of corners: GridCorners) -> CGRect {
        let xs = [corners.topLeft.x, corners.topRight.x, corners.bottomLeft.x, corners.bottomRight.x]
        let ys = [corners.topLeft.y, corners.topRight.y, corners.bottomLeft.y, corners.bottomRight.y]
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max(), maxX > minX, maxY > minY else {
            return CGRect(x: 0.06, y: 0.06, width: 0.88, height: 0.88)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - 载入

    private func load() async {
        let id = project.id
        let loader = inventoryManager.imageLoader
        // 有原图就用原图（上传时另存的全分辨率副本），没有就退回压缩图。
        // 读盘和解码都扔到后台：这个 View 是 @MainActor，几十 MB 的文件在主线程上解，
        // 就是打开这个模式时界面先僵一下。
        var data = await Task.detached(priority: .userInitiated) { PatternSourceStore.data(for: id) }.value
        if data == nil { data = await loader?.thumbnail(for: id) }
        let bytes = data
        let low = await Task.detached(priority: .userInitiated) {
            bytes.flatMap {
                ImageDownsampler.downsampleToUIImage($0, maxPixelSize: Self.decodeMaxPixel(for: $0, budget: Self.overviewPixelBudget))
            }
        }.value
        // `?? .unreadable` 而不是 `.missing`：loader 为 nil 意味着连 modelContext 都没有，
        // 那是「我根本没法读你的数据」。
        let loaded = await loader?.patternGridLoad(for: id) ?? .unreadable
        guard !Task.isCancelled else { return }

        self.overview = low
        self.imageUnreadable = (bytes != nil && low == nil)
        // 先拿整张图那一版兜底，保证后面每一屏立刻有图可用。高清版是「更好」，不是「必需」。
        if let low { self.work = .whole(low) }

        switch loaded {
        case .unreadable:
            self.overwriteBlocked = true
            self.prompt = .loadFailed
        case .missing:
            break
        case .loaded(let grid):
            let area = Self.boundingBox(of: grid.corners)
            self.roi = grid.roi ?? area
            self.calibration = grid.calibration
            self.emptyHex = grid.emptyHex
            // 老数据（还没用新流程重对过）才保留原来的四角，理由见 `legacyCorners`
            self.legacyCorners = grid.calibration == nil ? grid.corners : nil
            // 判断落点要用这个局部值，**不要写完 `sheet` 再读回来** ——
            // @State 同一轮写完读回来不保证拿到新值，那样落点会按上一次的数据算。
            let fills = Self.fills(from: grid)
            self.sheet = BeadPart(
                rowBand: 0,
                bounds: grid.roi ?? area,
                gridRect: area,
                rows: grid.rows,
                cols: grid.cols,
                cells: fills
            )

            // 上次做到哪儿，这次就从哪儿接着来。判过色的直接进「照着拼」——
            // 用户此刻是真拿着豆子在拼，每次进来还要把四屏重点一遍纯属白点。
            if low != nil {
                if fills.contains(where: { $0.contains(where: \.needsBead) }) {
                    self.path = [.grid, .baseColor, .review, .highlight]
                } else if grid.calibration != nil {
                    self.path = [.grid]
                }
            }
        }
        self.didLoadOnce = true

        // 高清版在后台换上去，换好之后界面自己刷新，用户不用等
        await prepareWorkImage()
    }

    /// 存下来的色号矩阵 → 内存里的格子。行列对不上就当没判过 ——
    /// 拿一个尺寸不符的矩阵往下走，只会让每一格的颜色整体错位。
    private static func fills(from grid: BeadPatternGrid) -> [[PartCellFill]] {
        guard grid.rows > 0, grid.cols > 0,
              grid.cellColorCodes.count == grid.rows,
              grid.cellColorCodes.allSatisfy({ $0.count == grid.cols }) else { return [] }
        return grid.cellColorCodes.map { row in
            row.map { code in
                guard let code, !code.isEmpty else { return PartCellFill.empty }
                return .code(code)
            }
        }
    }

    /// 整张图纸那一版的像素预算。**这一版会一直留在内存里**（第一屏随时要用），
    /// 给的是「够铺满画布」的量，不是原图。
    private static let overviewPixelBudget = 12_000_000

    /// 裁切区那一版的像素预算。**这一版决定用户能不能看清一颗豆子**：量格子、判色、
    /// 核对色号、放大高亮全靠它。所以给得很高 —— 常见的图纸和手机照片一个像素都不降。
    private static let workPixelBudget = 60_000_000

    private static func decodeMaxPixel(for data: Data, budget: Int) -> Int {
        guard let native = ImageDownsampler.pixelSize(of: data) else { return 3600 }
        let total = Double(native.width) * Double(native.height)
        let long = Double(max(native.width, native.height))
        guard total > Double(budget) else { return Int(long.rounded(.up)) }
        return max(1600, Int((long * (Double(budget) / total).squareRoot()).rounded()))
    }

    /// 已经裁到高清版的那块区域。不能拿 `work.region` 判 —— 兜底那版的 region 是整张图，
    /// 会被误认成已经裁过了。
    @State private var highResRegion: CGRect?
    /// 现在这份高清版是拿第几代源裁的。跟 `highResRegion` 一起比，缺一不可 ——
    /// 用户补了原图之后区域没变但源变了，只比区域会以为「已经是最新的了」。
    @State private var highResGeneration = -1
    /// 正在进行的那次高清升级。存着它是为了让别人**等得到**它。
    @State private var upgradeTask: Task<Void, Never>?

    /// 用户刚补了一张原图：整张那一版和裁切区那一版都要重出一次，
    /// 界面上立刻能看出变清楚了 —— 否则他选完图什么都没发生，只能怀疑是不是没选上。
    private func reloadFromSource() async {
        let id = project.id
        guard let data = await Task.detached(priority: .userInitiated, operation: {
            PatternSourceStore.data(for: id)
        }).value else { return }
        if let low = await Task.detached(priority: .userInitiated, operation: {
            ImageDownsampler.downsampleToUIImage(data, maxPixelSize: Self.decodeMaxPixel(for: data, budget: Self.overviewPixelBudget))
        }).value {
            overview = low
        }
        sourceGeneration += 1
        await prepareWorkImage()
    }

    /// 确保高清工作图是当前裁切区、当前这一代源的那一版；已经在升级就**等它做完**。
    private func prepareWorkImage() async {
        // 判断必须放在等待**之后**：等待期间那次升级会改 highResRegion / Generation。
        if let running = upgradeTask { await running.value }
        guard highResRegion != roi || highResGeneration != sourceGeneration else { return }
        let region = roi
        let generation = sourceGeneration
        let task = Task { await upgradeWorkImage(region: region, generation: generation) }
        upgradeTask = task
        await task.value
        if upgradeTask == task { upgradeTask = nil }
    }

    /// 从原图裁出裁切区那一版，换掉兜底的整图版。
    /// 失败就什么都不做 —— 兜底那版还在，流程照样往下走。
    private func upgradeWorkImage(region: CGRect, generation: Int) async {
        let id = project.id
        let loader = inventoryManager.imageLoader
        var source = await Task.detached(priority: .userInitiated) { PatternSourceStore.data(for: id) }.value
        if source == nil { source = await loader?.thumbnail(for: id) }
        guard let data = source else { return }
        let built = await Task.detached(priority: .userInitiated) { () -> PartsWorkImage? in
            autoreleasepool {
                let maxPixel = Self.decodeMaxPixel(for: data, budget: Self.workPixelBudget)
                guard let full = ImageDownsampler.downsampleToUIImage(data, maxPixelSize: maxPixel),
                      let cropped = PartsThumbnailMaker.crop(.whole(full), normalized: region) else { return nil }
                // **必须重画一份。** `CGImage.cropping(to:)` 不复制像素，它跟整图共享
                // data provider —— 只要裁剪结果活着，整图那份解码就一直躺在内存里
                // （6000 万像素 = 240 MB，会在整个会话期间常驻）。
                let format = UIGraphicsImageRendererFormat.default()
                format.scale = 1
                format.opaque = true
                let detached = UIGraphicsImageRenderer(size: cropped.size, format: format).image { _ in
                    cropped.draw(in: CGRect(origin: .zero, size: cropped.size))
                }
                return PartsWorkImage(image: detached, region: region)
            }
        }.value
        guard let built else {
            AppLogger.shared.warning("SinglePattern", "work_image_upgrade_failed", metadata: [
                "projectId": id.uuidString
            ])
            return
        }
        self.work = built
        self.highResRegion = region
        self.highResGeneration = generation
    }

    // MARK: - 往下走

    /// 「量格子」这个按钮按下去之后的事。
    ///
    /// 第一屏是从后面任何一屏一路返回就能到的地方。改了框就等于换了一张网格，
    /// 已经核对好的颜色跟着作废 —— 那是几十分钟的活，不能一声不响地洗掉。
    private func startCalibration() {
        if sheet.hasCells, sheet.bounds != roi {
            prompt = .confirmRecrop
            return
        }
        path = [.grid]
        Task { await prepareWorkImage() }
    }

    // MARK: - 逐格判色

    /// 判色跟多零件模式**走的是同一个函数**（`PartsCellClassifier`）：
    /// 每格取众数色 → 聚成十几类 → 一类整体配一个色号。整张图纸就是「一个零件」。
    ///
    /// 这里曾经在它上面加过一层逐格 OCR（图纸格子里多半印着「14」「28」这样的色号），
    /// 已经删掉：慢，而且用户要的不是「再多一个会出错的来源」——
    /// 判错了在核对页两下就能改，那才是这条流程的解法。
    private func runClassification() {
        guard let work, let calibration, calibration.isUsable else { return }
        let snapshot = sheet
        let area = sheet.gridRect ?? sheet.bounds
        let colorSystem = project.colorSystem
        let legend = project.beadUsage.map(\.colorCode)
        let colors = inventoryManager.beadColors
        let base = emptyHex
        busy = String(localized: "正在看每格什么颜色…")

        Task.detached(priority: .userInitiated) {
            let result = PartsCellClassifier.classify(
                work: work,
                parts: [snapshot],
                roi: area,
                calibration: calibration,
                colorSystem: colorSystem,
                legendCodes: legend,
                availableColors: colors,
                emptyHex: base,
                // 单图纸没有「任意色」这一档：它是立体图纸色号表里的一行字，
                // 平面图纸上不存在。
                anyColorHex: nil
            )
            await MainActor.run {
                self.busy = nil
                // 一格都没看到 = 图根本没抠出来（框太小 / 图坏了），
                // **不是**「这张图纸上没有豆子」。写回去的话核对页只会显示「一共 0 颗」，
                // 用户完全不知道该改哪儿。
                guard let judged = result.parts.first, result.unreadableParts == 0 else {
                    self.prompt = .classifyFailed
                    return
                }
                self.sheet = judged
                self.dirty = true
                guard self.persist() else { return }   // 存不上会自己弹「这一步没存上」
                self.path = [.grid, .baseColor, .review]
            }
        }
    }

    // MARK: - 保存

    /// 把当前进度写回项目。
    ///
    /// **每走完一步就存一次**，而不是等用户点「完成」。量格子、一个色号一个色号地核对，
    /// 这是个能横跨好几天的活；中途退出去（甚至只是被电话打断）就全部作废，没有人受得了。
    /// - Returns: 这次调用之后，内存里的东西是不是都已经在库里了。
    @discardableResult
    private func persist() -> Bool {
        guard dirty else { return true }
        // 进来的时候就没读出旧数据：那份字节还在库里，只是这次打不开。
        // 这时候写回去等于拿现在这份（多半是空的）把它永久盖掉。
        guard !overwriteBlocked else {
            AppLogger.shared.error("SinglePattern", "persist_blocked_unreadable", metadata: [
                "projectId": project.id.uuidString
            ])
            // 再问一次，别让「关闭」变成一个既不响应也不解释的按钮。
            prompt = .loadFailed
            return false
        }
        guard let grid = currentGrid else {
            // 还没量出网格（用户只拖了个框就退出去）。这不是错误，但也没有东西可存 ——
            // 写一份空网格进去只会让下次进来看见一张 0×0 的图纸。
            return true
        }
        guard inventoryManager.updateProjectPatternGrid(project.id, grid: grid) else {
            prompt = .saveFailed
            return false
        }
        dirty = false
        return true
    }

    private func save() {
        if persist() { dismiss() }
    }
}
