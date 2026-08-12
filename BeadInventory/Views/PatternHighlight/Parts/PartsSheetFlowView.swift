//
//  PartsSheetFlowView.swift
//  BeadInventory
//
//  多零件模式（立体图纸）- 整条流程的容器
//
//  六屏，一屏一件事。顺序就是下面这个表，也就是 `Step` 的顺序 ——
//  屏号只写在这里，各屏自己的文件里不再写「第 ③ 屏」，免得插一屏就得挨个改注释：
//
//      圈零件区     把中间那一大块框住（排除顶部色号表 / 底部成品图）。这是根视图。
//      零件清单     找出来的零件，能删、能合并、能拆开、能补、能改名
//      量格子       定下全图共用的那一张网格：格子多大、格线在哪
//      底色和任意色 在图上指认这两样「不是色号」的颜色，判色前必须先摘出去
//      核对颜色     每个色号有多少颗、分别是哪几格，用户逐条校对
//      拼豆板       零件分别摆在第几块板的第几格
//
//  ## 这里曾经有一屏「图纸调色板」（排在零件清单后面），已经删掉
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
    @Environment(\.scenePhase) private var scenePhase

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
    /// 用户在图上指认的底色和任意色（`RRGGBB`）。判色前必须知道这两样，
    /// 否则它们会被硬套到最近的色号上（见 PartsBaseColorStepView 的头注释）。
    @State private var emptyHex: String?
    @State private var anyColorHex: String?

    /// 零件摆在拼豆板上的位置。最后一屏的产物。
    @State private var boards: [PartsBoard] = []

    @State private var busy: String?

    /// 这次会话真的改过东西。
    ///
    /// 后面几屏都是通过 binding 直接改这里的 @State，容器这边看不见「改了什么」，
    /// 所以交出去的 binding 都包一层 `tracked` 来标记。早先是拿 `parts.isEmpty`
    /// 当代理判断「有没有东西要存」—— 用户在清单页把零件全删光恰好也是空，
    /// 那次删除于是静默地存不进去，下次进来零件原封不动全回来了。
    @State private var dirty = false
    /// 库里那份读不出来 → **禁止覆写**，直到用户明说要重做。
    ///
    /// 刻意跟 `prompt` 分开：它是「能不能写」的开关，不是一句提示。早先它同时充当
    /// alert 的 `isPresented`，于是「重新做一遍」那个按钮体是空的 `{}` —— 解锁靠的是
    /// 关闭 alert 的副作用，一旦弹窗改成别的形式它就真成了空按钮。
    @State private var overwriteBlocked = false
    /// 现在这批零件是按哪块零件区找出来的。用来判断「用户是不是只是退回来看看」。
    @State private var detectedROI: CGRect?
    /// 工作图换过几次源。补完原图会 +1，让「零件区没变就不用重找」那条判断知道
    /// 底下的图其实换了 —— 否则用户刚补完原图想重新识别，会被直接送去零件清单。
    @State private var sourceGeneration = 0
    /// 这批零件是在第几代工作图上找出来的。
    @State private var detectedGeneration = 0

    enum Step: Hashable { case list, cellSize, baseColor, review, board }

    /// 现在要跟用户说的那一句话。
    ///
    /// 四个弹窗平铺在同一个 view 上时，`runClassification` 能在同一轮里置起两个，
    /// SwiftUI 只 present 一个、另一个的标志停在 true 却没有界面 —— 要是被吞的是
    /// 「没存上」，`关闭` 和 `完成` 都会因为它停在 true 而**没反应也没有任何解释**。
    /// 收成一个值之后，「同时只有一句话」变成类型层面的事实。
    private enum Prompt: Identifiable {
        /// 存不进去。手上这些东西只活在内存里，得拦住他别关。
        case saveFailed
        /// 库里有东西但打不开。接着做等于拿新的盖掉旧的，要他自己点头。
        case loadFailed
        /// 重新找零件会洗掉已有的成果。
        case confirmRedetect
        /// 判色时有零件的框里取不到图。出路是回零件清单改那几个框。
        case classifyNote(String)
        /// 这块范围里一个零件都没找到。出路是**留在这一屏**把框挪一挪，
        /// 所以刻意不跟上面那条共用 —— 标题和按钮都不一样，混用会出现
        /// 「标题说有零件没看成、正文说一个也没找到」，而且默认按钮会把人送进一个空清单。
        case detectFoundNothing

        var id: String {
            switch self {
            case .saveFailed: return "save"
            case .loadFailed: return "load"
            case .confirmRedetect: return "redetect"
            case .classifyNote(let text): return "note:\(text)"
            case .detectFoundNothing: return "empty"
            }
        }
    }

    @State private var prompt: Prompt?

    /// 把一个交给子屏的 binding 包成「改了就记一笔」。
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
                        onContinue: { startDetection() },
                        projectId: project.id,
                        onSourceLoaded: { Task { await reloadFromSource() } }
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
                    // 关掉就是关掉，不是丢掉 —— 每一步的结果都已经存过了（见 persist）。
                    // 唯一的例外是这次真的没存进去：那就先别关，alert 会告诉他为什么。
                    Button("关闭") {
                        if persist() { dismiss() }
                    }
                }
            }
            .navigationDestination(for: Step.self) { step in
                // 高清工作图还没裁好时给一个明确的「正在准备」——
                // 早先这里是 `if let work { ... }`，work 为 nil 就整页空白，
                // 用户看到的是一块什么都没有的黑屏，不知道是在转还是坏了。
                Group {
                    // 拼豆板那屏只用格子数据，不用图 —— 图裁失败也不该把它挡在外面。
                    if step == .board {
                        PartsBoardStepView(
                            parts: parts,
                            boards: tracked($boards),
                            colorSystem: project.colorSystem,
                            onFinish: { save() }
                        )
                        .environmentObject(inventoryManager)
                    } else if let work {
                        switch step {
                        case .list:
                            PartsListStepView(
                                work: work,
                                roi: roi,
                                parts: tracked($parts),
                                onContinue: {
                                    persist()
                                    path = [.list, .cellSize]
                                },
                                projectId: project.id,
                                onSourceLoaded: { Task { await reloadFromSource() } }
                            )
                        case .cellSize:
                            PartsCellSizeStepView(
                                work: work,
                                parts: tracked($parts),
                                calibration: tracked($calibration),
                                onContinue: {
                                    persist()
                                    path = [.list, .cellSize, .baseColor]
                                }
                            )
                        case .baseColor:
                            PartsBaseColorStepView(
                                work: work,
                                roi: roi,
                                calibration: calibration,
                                emptyHex: tracked($emptyHex),
                                anyColorHex: tracked($anyColorHex),
                                onContinue: { runClassification() }
                            )
                        case .review:
                            PartsColorReviewStepView(
                                work: work,
                                parts: tracked($parts),
                                colorSystem: project.colorSystem,
                                legendCounts: legendCounts,
                                onFinish: {
                                    persist()
                                    path = [.list, .cellSize, .baseColor, .review, .board]
                                }
                            )
                            .environmentObject(inventoryManager)
                        case .board:
                            EmptyView()   // 上面已经拦掉了
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
        // 切出去接个电话不该丢掉刚改的色号 —— 核对页的修改是直接落在 parts 上的，
        // 不等到「完成」那一下。
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { persist() }
        }
        // 一个弹窗口子，四种话轮流用它。见 Prompt 的注释。
        .alert(item: $prompt) { prompt in
            switch prompt {
            // 存不上必须让他看见。五十几个零件框、几万格色号、拼豆板摆位，
            // 存不进去就只活在内存里，而屏幕上看起来跟存好了一模一样。
            case .saveFailed:
                return Alert(
                    title: Text("这一步没存上"),
                    message: Text("刚做的这些还没写进项目里，现在关掉就没了。先别关，接着往下走每一步都会再存一次。"),
                    primaryButton: .cancel(Text("知道了")),
                    secondaryButton: .destructive(Text("仍然关闭")) { dismiss() }
                )
            // 有进度但打不开：接着做等于拿新结果盖掉旧的那份，得他自己点头。
            case .loadFailed:
                return Alert(
                    title: Text("之前的进度这次打不开"),
                    message: Text("这个项目上次做的零件数据这次读不出来。建议先退出去，过一会儿再进来试试；现在就重做的话，原来那份会被这次的结果盖掉。"),
                    primaryButton: .cancel(Text("先退出去")) { dismiss() },
                    secondaryButton: .destructive(Text("重新做一遍")) { overwriteBlocked = false }
                )
            case .confirmRedetect:
                return Alert(
                    title: Text("重新找一遍零件？"),
                    message: Text("会按现在圈的范围重找一遍零件。已经找好的零件框、量好的格子、判好的颜色、摆好的拼豆板都跟着作废，要从头再走一遍。"),
                    primaryButton: .cancel(Text("取消")),
                    secondaryButton: .destructive(Text("重新找")) { runDetection() }
                )
            case .classifyNote(let text):
                return Alert(
                    title: Text("有零件没看成"),
                    message: Text(text),
                    primaryButton: .default(Text("回零件清单")) { path = [.list] },
                    secondaryButton: .cancel(Text("知道了"))
                )
            case .detectFoundNothing:
                return Alert(
                    title: Text("这块范围里没找到零件"),
                    message: Text("把框挪到有零件的那一片再试一次 —— 原来的零件还留着。"),
                    dismissButton: .cancel(Text("知道了"))
                )
            }
        }
    }

    // MARK: - 载入

    private func load() async {
        let id = project.id
        let loader = inventoryManager.imageLoader
        let maxPixel = Self.overviewMaxPixel
        // 有原图就用原图 —— 它是上传时另存的全分辨率副本，只有这条流程会读（见 PatternSourceStore）。
        // 没有就退回 SwiftData 里那份压缩图，流程完全一样，只是一格豆子的像素少一半。
        //
        // 读盘和解码都扔到后台：这个 View 是 @MainActor，而原图是几十 MB 的文件，
        // `Data(contentsOf:)` 加解码放在主线程上，就是打开这个模式时界面先僵一下。
        var data = await Task.detached(priority: .userInitiated) { PatternSourceStore.data(for: id) }.value
        if data == nil { data = await loader?.thumbnail(for: id) }
        let bytes = data
        let low = await Task.detached(priority: .userInitiated) {
            bytes.flatMap { ImageDownsampler.downsampleToUIImage($0, maxPixelSize: maxPixel) }
        }.value
        // `?? .unreadable` 而不是 `.missing`：loader 为 nil 意味着连 modelContext 都没有，
        // 那是「我根本没法读你的数据」—— 最不该被当成「这个项目本来就没做过」的情况。
        let loaded = await loader?.partsSheet(for: id) ?? .unreadable
        guard !Task.isCancelled else { return }

        self.overview = low
        // 先用低清版兜底，保证后面每一屏立刻有图可用。
        // 高清版是「更好」，不是「必需」—— 早先把它做成必需，一旦裁失败或者还没裁完，
        // 用户面对的就是一个永远转不完的 spinner，没有任何出路。
        if let low { self.work = .whole(low) }

        switch loaded {
        case .unreadable:
            // 「读不出来」不等于「没做过」。当成没做过的话用户被扔回第一屏，
            // 他以为要重来，一按「开始找零件」就把那份只是暂时打不开的数据永久盖掉。
            self.overwriteBlocked = true
            self.prompt = .loadFailed
        case .missing:
            break
        case .loaded(let saved):
            self.roi = saved.roi
            self.parts = saved.parts
            self.palette = saved.palette
            self.calibration = saved.calibration
            self.anyColorCode = saved.anyColorCode
            self.detectedGeneration = sourceGeneration
            self.emptyHex = saved.emptyHex
            self.anyColorHex = saved.anyColorHex
            self.detectedROI = saved.roi

            // 剔掉指向已经不存在的零件的摆位。早先「重新找零件」只清标定不清板子，
            // 存量数据里可能留着一板子孤儿：板上画不出任何东西，又因为 boards 非空
            // 进不了自动排版，用户在那一屏完全没有出路。一个活的摆位都不剩 = 等于没摆过。
            let liveIds = Set(saved.parts.map(\.id))
            var live = (saved.boards ?? []).map { board -> PartsBoard in
                var cleaned = board
                cleaned.placements.removeAll { !liveIds.contains($0.partId) }
                return cleaned
            }
            if live.allSatisfy(\.placements.isEmpty) { live = [] }
            self.boards = live

            // 上次做到哪儿，这次就从哪儿接着来。
            //
            // 之前只认「拆过零件 → 回到清单」这一档，于是判完色、改完色号退出去再进来，
            // 落点还是零件清单 —— 而从清单往下走会重新判一遍色，用户改过的色号全被盖掉。
            // 他看到的就是「填好的颜色不见了」。判过色的（格子里有内容）直接回到核对页。
            //
            // 已经开始摆板子的，直接回到板子那屏 —— 那时候用户是真拿着豆子在拼，
            // 每次进来还要从核对颜色再点一下过去，纯属白点。
            if !saved.parts.isEmpty, low != nil {
                if !live.isEmpty {
                    self.path = [.list, .cellSize, .baseColor, .review, .board]
                } else {
                    self.path = saved.parts.contains(where: \.hasCells)
                        ? [.list, .cellSize, .baseColor, .review]
                        : [.list]
                }
            }
        }
        self.didLoadOnce = true

        // 高清版在后台换上去，换好之后界面自己刷新，用户不用等
        await prepareWorkImage()
    }

    /// 整张图纸的低清版长边上限。这一版只给「圈零件区」看轮廓，1600 足够，
    /// 也把首屏的解码代价压到最低。
    private static let overviewMaxPixel = 1600

    /// 上一步 AI 读色号表得到的「每个色号多少颗」。核对颜色那屏拿它当参照。
    /// 同一个色号被记了多次时相加 —— 表格识别偶尔会把一个色号拆成两行。
    private var legendCounts: [String: Int] {
        project.beadUsage.reduce(into: [:]) { result, usage in
            result[usage.colorCode, default: 0] += usage.quantity
        }
    }

    /// 解码整张图纸时的像素上限。
    ///
    /// **原图没超过这个数就一个像素都不降 —— 直接用原图。** 早先这里是「长边压到 3600」，
    /// 一张本来就不大的图纸也照砍，一格豆子白白少掉三分之一的像素。
    /// 1200 万像素解出来约 48 MB，是一次瞬时峰值（裁完零件区就还回去），
    /// 而且只在多零件模式开着时发生。真遇到几千万像素的扫描件才会按比例降。
    private static let workPixelBudget = 12_000_000

    /// 按原图实际大小决定解码尺寸：够小就用原图，太大才按预算等比缩。
    private static func decodeMaxPixel(for data: Data) -> Int {
        guard let native = ImageDownsampler.pixelSize(of: data) else { return 3600 }
        let total = Double(native.width) * Double(native.height)
        let long = Double(max(native.width, native.height))
        guard total > Double(workPixelBudget) else { return Int(long.rounded(.up)) }
        return max(1600, Int((long * (Double(workPixelBudget) / total).squareRoot()).rounded()))
    }

    /// 已经裁到高清版的那块区域。用来判断「要不要重裁」，
    /// 不能拿 `work.region` 判 —— 低清兜底版的 region 是整张图，会被误认成没裁过。
    @State private var highResRegion: CGRect?
    /// 现在这份高清版是拿第几代源裁的。跟 `highResRegion` 一起比，缺一不可 ——
    /// 用户补了原图之后区域没变但源变了，只比区域会以为「已经是最新的了」。
    @State private var highResGeneration = -1
    /// 正在进行的那次高清升级。存着它是为了让别人**等得到**它，见 `prepareWorkImage`。
    @State private var upgradeTask: Task<Void, Never>?

    /// 用户刚补了一张原图：整张的低清版和零件区的高清版都要重出一次，
    /// 界面上立刻能看出变清楚了 —— 否则他选完图什么都没发生，只能怀疑是不是没选上。
    private func reloadFromSource() async {
        let id = project.id
        let maxPixel = Self.overviewMaxPixel
        // 同 load()：读盘和解码都不放主线程，否则刚选完原图界面会僵住。
        guard let data = await Task.detached(priority: .userInitiated, operation: {
            PatternSourceStore.data(for: id)
        }).value else { return }
        if let low = await Task.detached(priority: .userInitiated, operation: {
            ImageDownsampler.downsampleToUIImage(data, maxPixelSize: maxPixel)
        }).value {
            overview = low
        }
        // 换源用「代」来记，**不能靠清空 highResRegion**：清空之后
        // `prepareWorkImage` 第一句会去等已经在跑的那次升级，而那次跑完又会把
        // highResRegion 设回来，紧接着的判断就以为「已经是最新的了」——
        // 用户刚补的原图于是永远不会被重新裁一次。
        sourceGeneration += 1
        await prepareWorkImage()
    }

    /// 确保高清工作图是当前零件区、当前这一代源的那一版；已经在升级就**等它做完**。
    ///
    /// 「已经是最新」和「正在升级」不能共用一个 return：`runDetection` 全靠
    /// `await prepareWorkImage()` 保证检测跑在高清图上。早先合成一个 return 之后，
    /// 用户刚在提示条里补完原图就点「开始找零件」，检测跑的还是 1600px 的兜底版，
    /// 而提示条这时已经消失 —— 他连「是不是没生效」都没法验证。
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

    /// 从原图裁出零件区的高清版，换掉低清兜底版。
    /// 失败就什么都不做 —— 低清版还在，流程照样往下走，只是图糊一点。
    private func upgradeWorkImage(region: CGRect, generation: Int) async {
        let id = project.id
        let loader = inventoryManager.imageLoader
        // 读盘放后台：原图是几十 MB 的文件，`Data(contentsOf:)` 在主线程上会卡住界面。
        var source = await Task.detached(priority: .userInitiated) { PatternSourceStore.data(for: id) }.value
        if source == nil { source = await loader?.thumbnail(for: id) }
        guard let data = source else { return }
        let built = await Task.detached(priority: .userInitiated) { () -> PartsWorkImage? in
            // autoreleasepool：整图那份大 CGImage 用完立刻还回去，只留裁出来的那块。
            //
            // 实测这一整段（取字节 + 解码 + 裁切）只要 0.10s，所以它从来不是「慢」的来源；
            // 早先那次界面卡死是因为把它做成了进入下一屏的必需条件，失败就没有退路。
            autoreleasepool {
                let maxPixel = Self.decodeMaxPixel(for: data)
                guard let full = ImageDownsampler.downsampleToUIImage(data, maxPixelSize: maxPixel),
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
        self.highResGeneration = generation
    }

    // MARK: - 拆零件

    /// 「开始找零件」这个按钮按下去之后的事。
    ///
    /// 第一屏是从后面任何一屏一路返回就能到的地方，而它唯一的主按钮就是「开始找零件」。
    /// 直接重跑的话，判过色的几万格、摆好的拼豆板一声不响全没了。
    private func startDetection() {
        // 零件还在、零件区没动过、底下的图也还是同一张：他多半只是退回来看一眼框。
        // 送回零件清单，别重跑。
        //
        // 「图还是同一张」这条不能漏：用户在这一屏的提示条里补了张原图，正是想在清晰的图上
        // 重新识别一次，这时候把他直接推去零件清单，他手里还是低清图上找出来的零件，
        // 而唯一的出路是把框挪一个像素 —— 没人猜得到。
        if !parts.isEmpty, detectedROI == roi, detectedGeneration == sourceGeneration {
            path = [.list]
            return
        }
        // 已经有零件了就先问一句，说清楚会丢什么。
        //
        // 门槛是「有零件」而不是「判过色」：零件清单页删 / 补 / 合并 / 拆开框，
        // 在五十几个零件的图纸上就是半小时的活，它一样不能被一次误碰洗掉。
        if !parts.isEmpty {
            prompt = .confirmRedetect
            return
        }
        runDetection()
    }

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
                AppLogger.shared.error("PartsSheet", "detect_without_work_image", metadata: [
                    "projectId": project.id.uuidString
                ])
                return
            }
            let generation = sourceGeneration
            let detected = await Task.detached(priority: .userInitiated) {
                PartsDetector.detect(in: source, roi: currentROI, options: PartsDetectionOptions())
            }.value
            // 一个零件都没找到就**别写回去**。框拖到空白边距上是很容易的事，
            // 而写回去等于把库里那份（可能是几天的活）换成一张空清单，用户面对的是
            // 一个空零件清单，没有任何提示，也没有回头路。
            guard !detected.isEmpty else {
                self.busy = nil
                self.prompt = .detectFoundNothing
                // 用户是特地圈了一块才按的按钮，这里一个都没找到，多半是框圈歪了 ——
                // 但检测器自己退化时也是这个现象，留个带范围的日志才分得清。
                AppLogger.shared.info("PartsSheet", "detect_found_nothing", metadata: [
                    "projectId": project.id.uuidString,
                    "roi": "\(currentROI)"
                ])
                return
            }
            self.parts = detected.map { BeadPart(rowBand: $0.rowBand, bounds: $0.bounds) }
            // 换了零件区就等于换了一张图纸，之前量的格子、判的色、摆好的板子全部作废。
            // 板子必须一起清：placement 指的是旧零件的 id，留着就是一板子孤儿 ——
            // 板上画不出东西，又因为 boards 非空进不了自动排版，那一屏成了死胡同。
            self.calibration = nil
            self.boards = []
            self.palette = []
            self.detectedROI = currentROI
            self.detectedGeneration = generation
            self.busy = nil
            self.dirty = true
            self.persist()
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
        let base = emptyHex
        let any = anyColorHex
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
                emptyHex: base,
                anyColorHex: any,
                progress: { done, total in
                    Task { @MainActor in busy = "正在看每格什么颜色…（\(done)/\(total)）" }
                }
            )
            await MainActor.run {
                self.busy = nil
                // 一个零件都没看成 = 图根本没抠出来（框太小 / 图坏了），
                // **不是**「这张图纸上没有豆子」。这时候写回去会把所有零件的格子清成空，
                // 核对页只会显示「一共 0 颗」，用户完全不知道该改哪儿。
                if result.unreadableParts == result.parts.count, !result.parts.isEmpty {
                    self.prompt = .classifyNote(String(
                        localized: "所有零件的框里都取不到图，一格颜色都没看出来。多半是框圈得太小，回零件清单改一改再来一次。"
                    ))
                    return
                }
                self.parts = result.parts
                self.palette = result.palette
                self.dirty = true
                // 存不上会自己弹「这一步没存上」。那句话比「有几个零件没看成」要紧，
                // 所以只在存住了的前提下才覆盖提示 —— 两句话抢同一个口子时，
                // 丢掉的必须是次要的那句。
                let saved = self.persist()
                if saved, result.unreadableParts > 0 {
                    self.prompt = .classifyNote(String(
                        localized: "有 \(result.unreadableParts) 个零件的框里取不到图，它们的格子是空的。回零件清单看看这几个框是不是太小了。"
                    ))
                }
                self.path = [.list, .cellSize, .baseColor, .review]
            }
        }
    }

    // MARK: - 保存

    /// 把当前进度写回项目。
    ///
    /// **每走完一步就存一次**，而不是等用户点「完成」。拆五十几个零件、量格子、
    /// 一个色号一个色号地核对，这是个能横跨好几天的活；中途退出去（甚至只是被电话打断）
    /// 就全部作废，没有人受得了。
    /// - Returns: 这次调用之后，内存里的东西是不是都已经在库里了。
    ///   **调用方一律用返回值判断，不要另存一个「上次失败了吗」的 @State 再读回来** ——
    ///   @State 写完同一轮读回来不保证拿到新值（`PartsBoardStepView.DragSession` 就是栽在这上面）。
    @discardableResult
    private func persist() -> Bool {
        guard dirty else { return true }
        // 进来的时候就没读出旧数据：那份字节还在库里，只是这次打不开。
        // 这时候写回去等于拿现在这份（多半是空的）把它永久盖掉。用户点过
        // 「重新做一遍」之后 overwriteBlocked 会被显式清掉。
        guard !overwriteBlocked else {
            AppLogger.shared.error("PartsSheet", "persist_blocked_unreadable", metadata: [
                "projectId": project.id.uuidString
            ])
            // 再问一次，别让「关闭」变成一个既不响应也不解释的按钮 ——
            // 一次点击要么有效果，要么有说法。
            prompt = .loadFailed
            return false
        }
        let sheet = BeadPartsSheet(
            roi: roi,
            workingImageSize: work?.image.size ?? .zero,
            colorSystem: project.colorSystem,
            parts: parts,
            palette: palette,
            calibration: calibration,
            anyColorCode: anyColorCode,
            emptyHex: emptyHex,
            anyColorHex: anyColorHex,
            boards: boards.isEmpty ? nil : boards
        )
        guard inventoryManager.updateProjectPartsSheet(project.id, sheet: sheet) else {
            // 没写进去。这里绝不能算了 —— 用户手上这些东西全在内存里，
            // 而屏幕上跟存好了长得一模一样，他关掉就再也找不回来。
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
