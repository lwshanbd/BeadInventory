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
//  单图纸模式（`SinglePatternFlowView`）走的是同一套屏：量格子、底色、核对颜色三屏
//  是共用的代码，只是它没有「零件」这一层，所以少了「零件清单」和「拼豆板」两屏。
//

import SwiftUI

struct PartsSheetFlowView: View {
    let project: ProjectRecord

    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    /// 整张图纸那一版，给第一屏「圈零件区」用。
    @State private var overview: UIImage?
    /// 有字节但解不出图。跟「这个项目本来就没有图」是两回事，说法也不一样。
    @State private var imageUnreadable = false
    /// 零件区的高清版。圈完区之后现裁，后面所有步骤（找零件 / 量格子 / 判色 / 抠格子）都用它。
    ///
    /// 单独裁一版而不是直接用整图那份：零件区往往只占整张图的一半，把预算全花在真正要看的
    /// 那块上，一格豆子的像素能翻好几倍 —— 而量格子、判色、核对色号看的全是这一块。
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
    /// 这套板子是按哪一档松紧排的。跟 `boards` 一起存，理由见 `BeadPartsSheet.boardSpacing`。
    @State private var boardSpacing: BoardSpacing?

    @State private var busy: String?

    /// 核对页点「看零件 → 回去重对这一块」跳过去的那一块。
    ///
    /// 非 nil 时「量格子」那屏一进去就翻到它，主按钮也变成「对好了，回核对颜色」——
    /// 用户是为一块回来的，让他把剩下四十八块再翻一遍才走得掉是说不过去的。
    @State private var regridTarget: UUID?

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
    /// 以前几个弹窗平铺在同一个 view 上时，`runClassification` 能在同一轮里置起两个，
    /// SwiftUI 只 present 一个、另一个的标志停在 true 却没有界面 —— 要是被吞的是
    /// 「没存上」，`关闭` 和 `完成` 都会因为它停在 true 而**没反应也没有任何解释**。
    /// 收成一个值之后，「同时只有一句话」变成类型层面的事实。
    private enum Prompt: Identifiable {
        /// 存不进去。手上这些东西只活在内存里，得拦住他别关。
        ///
        /// 带着「第几次」：id 要是个常数，弹窗被吞掉一次之后 `prompt` 就永远停在这个值，
        /// 之后每次失败都赋成同一个 —— `.alert(item:)` 认不出变化，那句话再也不出现，
        /// 而「关闭」「完成」会因为 `persist()` 一直返回 false 变成两个既不响应也不解释的按钮。
        case saveFailed(Int)
        /// 库里有东西但打不开。接着做等于拿新的盖掉旧的，要他自己点头。
        case loadFailed
        /// 重新找零件会洗掉已有的成果。
        case confirmRedetect
        /// 重新判色会洗掉用户在核对页一格一格改过的色号。
        case confirmReclassify
        /// 判色时有零件的框里取不到图。出路是回零件清单改那几个框。
        case classifyNote(String)
        /// 图纸色号表里有色库对不上的色号（见 `PartsCellClassifier.Result.unknownLegendNote`）。
        /// 出路是去核对页看那几组，所以**不跟上面那条共用** —— 那条的默认按钮是「回零件清单」，
        /// 而这件事在零件清单上是解不了的。
        case legendNote(String)
        /// 这块范围里一个零件都没找到。出路是**留在这一屏**把框挪一挪，
        /// 所以刻意不跟上面那条共用 —— 标题和按钮都不一样，混用会出现
        /// 「标题说有零件没看成、正文说一个也没找到」，而且默认按钮会把人送进一个空清单。
        case detectFoundNothing

        var id: String {
            switch self {
            case .saveFailed(let attempt): return "save\(attempt)"
            case .loadFailed: return "load"
            case .confirmRedetect: return "redetect"
            case .confirmReclassify: return "reclassify"
            case .classifyNote(let text): return "note:\(text)"
            case .legendNote(let text): return "legend:\(text)"
            case .detectFoundNothing: return "empty"
            }
        }
    }

    @State private var prompt: Prompt?
    /// 存盘失败了几次。只用来让 `Prompt.saveFailed` 每次都是一个新身份，见那里。
    @State private var saveAttempt = 0

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
                } else if imageUnreadable {
                    // 「读不出来」不等于「没有」—— 这跟 partsSheet 那边 `.unreadable` /
                    // `.missing` 分开处理是同一件事，图片这条路当初漏了。报成「还没有图纸」
                    // 的话用户跑去详情页，图明明就在那儿，然后他没有任何下一步可走。
                    ContentUnavailableView(
                        "本次无法读取此图纸",
                        systemImage: "photo.badge.exclamationmark",
                        description: Text("图纸仍保留在项目中，只是本次无法打开。请退出后重新进入再试；若持续失败，请前往详情页重新选择一张。")
                    )
                } else {
                    ContentUnavailableView(
                        "项目还没有图纸",
                        systemImage: "photo.badge.exclamationmark",
                        description: Text("请先在项目详情中添加一张图纸，再使用多零件模式。")
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
                            parts: tracked($parts),
                            // 给它图不等于要求它有图：拿到了就能点开零件跟图纸原图对一眼，
                            // 没拿到（裁失败）这一屏照常摆板子。
                            work: work,
                            boards: tracked($boards),
                            boardSpacing: tracked($boardSpacing),
                            colorSystem: project.colorSystem,
                            onPersist: { persist() },
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
                            // 单拎出去，不是为了好看：这几个参数一多，整个
                            // `navigationDestination` 的闭包就超出类型检查器的耐心
                            //（"unable to type-check this expression in reasonable time"）。
                            cellSizeStep(work: work)
                        case .baseColor:
                            PartsBaseColorStepView(
                                work: work,
                                roi: roi,
                                calibration: calibration,
                                emptyHex: tracked($emptyHex),
                                anyColorHex: tracked($anyColorHex),
                                onContinue: { requestClassification() },
                                // 非 nil 就是「判过色了」。原样回去，一格都不重算。
                                onKeepExisting: hasClassified
                                    ? { path = [.list, .cellSize, .baseColor, .review] }
                                    : nil
                            )
                        case .review:
                            PartsColorReviewStepView(
                                work: work,
                                parts: tracked($parts),
                                colorSystem: project.colorSystem,
                                legendCounts: legendCounts,
                                onPersist: { persist() },
                                onFinish: {
                                    persist()
                                    path = [.list, .cellSize, .baseColor, .review, .board]
                                },
                                onRegridPart: { id in
                                    persist()
                                    regridTarget = id
                                    path = [.list, .cellSize]
                                },
                                onGroupRecolored: { from, to in recolorPalette(from: from, to: to) }
                            )
                            .environmentObject(inventoryManager)
                            // 重对过格子的那一块回来时是空的，进这一屏先把它补判上。
                            .task { await classifyMissingParts() }
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
        }
        // **盖在整个 NavigationStack 上，不是盖在根视图上。** 判色是从「底色和任意色」
        // 那一屏按下去的，而那一屏是被 push 上来的 —— 转圈要是挂在根视图上，就整个被压在
        // 底下看不见：用户按完判色屏幕上什么都没发生，几十秒里他只能反复按。
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
        // 离开「量格子」就等于这一趟结束了，不管是按了回程按钮还是直接返回。
        // 不收的话，用户下次自己走到「量格子」还会看到一个「对好了，回核对颜色」——
        // 而他这次根本不是从核对页来的。
        .onChange(of: path) { _, new in
            if new.last != .cellSize { regridTarget = nil }
        }
        // 切出去接个电话不该丢掉刚改的色号 —— 核对页的修改是直接落在 parts 上的，
        // 不等到「完成」那一下。
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { persist() }
        }
        // 一个弹窗口子，所有要跟用户说的话轮流用它。见 Prompt 的注释。
        .alert(item: $prompt) { prompt in
            switch prompt {
            // 存不上必须让他看见。五十几个零件框、几万格色号、拼豆板摆位，
            // 存不进去就只活在内存里，而屏幕上看起来跟存好了一模一样。
            case .saveFailed:
                return Alert(
                    title: Text("此步骤未保存"),
                    message: Text("刚完成的操作尚未写入项目，现在关闭将会丢失。请勿关闭，继续往下每一步都会自动保存。"),
                    primaryButton: .cancel(Text("知道了")),
                    secondaryButton: .destructive(Text("仍然关闭")) { dismiss() }
                )
            // 有进度但打不开：接着做等于拿新结果盖掉旧的那份，得他自己点头。
            case .loadFailed:
                return Alert(
                    title: Text("之前的进度本次无法打开"),
                    message: Text("此项目上次的零件数据本次无法读取。建议先退出，稍后重新进入再试；若现在重做，原有数据将被本次结果覆盖。"),
                    primaryButton: .cancel(Text("先退出")) { dismiss() },
                    secondaryButton: .destructive(Text("重新开始")) { overwriteBlocked = false }
                )
            case .confirmRedetect:
                return Alert(
                    title: Text("重新查找零件？"),
                    message: Text("将按当前框选范围重新查找零件。已识别的零件框、网格、颜色及排布结果都将作废，需要重新完成整个流程。"),
                    primaryButton: .cancel(Text("取消")),
                    secondaryButton: .destructive(Text("重新查找")) { runDetection() }
                )
            // 判色是从头重算每一格，用户在核对页一格一格改过的色号会被整片盖掉 ——
            // 那是几天的活，而在这个改动之前，触发它只要在这一屏点一下。
            case .confirmReclassify:
                return Alert(
                    title: Text("重新识别颜色？"),
                    message: Text("将按当前底色和任意色重新识别每一格颜色，核对页中修改过的色号将全部作废，需要重新核对。如需继续之前的核对，请点「取消」，再点上方「返回核对颜色」。"),
                    primaryButton: .cancel(Text("取消")),
                    secondaryButton: .destructive(Text("重新判色")) { runClassification() }
                )
            case .classifyNote(let text):
                return Alert(
                    title: Text("部分零件未识别"),
                    message: Text(text),
                    primaryButton: .default(Text("返回零件清单")) { path = [.list] },
                    secondaryButton: .cancel(Text("知道了"))
                )
            case .legendNote(let text):
                return Alert(
                    title: Text("有几个色号色库里没有"),
                    message: Text(text),
                    dismissButton: .default(Text("知道了"))
                )
            case .detectFoundNothing:
                return Alert(
                    title: Text("该范围内未找到零件"),
                    message: Text("请将框移动到有零件的区域后重试，原有零件数据仍会保留。"),
                    dismissButton: .cancel(Text("知道了"))
                )
            }
        }
    }

    // MARK: - 载入

    private func load() async {
        let id = project.id
        let loader = inventoryManager.imageLoader
        // 有原图就用原图 —— 它是上传时另存的全分辨率副本（见 PatternSourceStore）。
        // 没有就退回 SwiftData 里那份压缩图，流程完全一样，只是一格豆子的像素少一半。
        //
        // 读盘和解码都扔到后台：这个 View 是 @MainActor，而原图是几十 MB 的文件，
        // `Data(contentsOf:)` 加解码放在主线程上，就是打开这个模式时界面先僵一下。
        var data = await Task.detached(priority: .userInitiated) { PatternSourceStore.data(for: id) }.value
        if data == nil { data = await loader?.thumbnail(for: id) }
        let bytes = data
        let low = await Task.detached(priority: .userInitiated) {
            bytes.flatMap { ImageDownsampler.downsampleToUIImage($0, maxPixelSize: Self.decodeMaxPixel(for: $0, budget: Self.overviewPixelBudget)) }
        }.value
        // `?? .unreadable` 而不是 `.missing`：loader 为 nil 意味着连 modelContext 都没有，
        // 那是「我根本没法读你的数据」—— 最不该被当成「这个项目本来就没做过」的情况。
        let loaded = await loader?.partsSheet(for: id) ?? .unreadable
        guard !Task.isCancelled else { return }

        self.overview = low
        self.imageUnreadable = (bytes != nil && low == nil)
        // 先拿整张图那一版兜底，保证后面每一屏立刻有图可用。
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
            // 老图纸的 `.tight` 在这里一次性落定，别留给下游每次读的时候再推一遍 ——
            // 那样「nil」就同时是「没排过」和「老数据」两个意思，判一次漏一次。
            // 落定之后 nil 只剩一个意思：还没排过，用用户偏好。
            //
            // 板子清空了就等于没排过，那一档也跟着作废：留着的话下次进去自动排会照着
            // 一套已经不存在的板子的松紧排，而不是用户当前的偏好。
            self.boardSpacing = live.isEmpty ? nil : (saved.boardSpacing ?? .tight)

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

    /// 上一步 AI 读色号表得到的「这张图纸每个色号多少颗」。核对颜色那屏拿它当参照，
    /// 也拿它当「改色号时优先给哪几个候选」的依据 —— 图纸上就用了这么些颜色。
    /// 同一个色号被记了多次时相加 —— 表格识别偶尔会把一个色号拆成两行。
    ///
    /// **key 必须翻成当前体系的显示码**：`beadUsage.colorCode` 存的是 canonical mardCode
    /// （ScanView.recognizeImage 的约定），而核对页格子里存的是 `displayCode(for: colorSystem)`。
    /// 不翻这一道，COCO / 卡卡这些非 MARD 图纸上两边永远对不上 —— 色号胶囊上那句
    /// 「认出 X 颗 / 图纸写 Y 颗」于是一个字都不显示，用户没有任何参照物判断判色对不对。
    ///
    /// **有一种情况翻不对，暂时没有干净的解法**：那个约定的另一半是「AI 没匹配上时存的是
    /// 原始字符串」。非 MARD 图纸上，一个恰好长得像合法 MARD 码的原始串会在这里查到
    /// **另一个颜色**，然后被翻成那个颜色的本体系码，于是图纸上某个色号会显示一个
    /// 来路不明但看着很确定的对照数。在这个调用点上，原始串和真 mardCode 无法区分 ——
    /// 要根治得在扫描那步给 beadUsage 记一个「匹配上了没有」的标记。
    /// 查不到色号的那一支反而是安全的：key 原样留着，匹配不上任何一组，只是不显示对照数。
    private var legendCounts: [String: Int] {
        project.beadUsage.reduce(into: [:]) { result, usage in
            let key = inventoryManager.findColor(byMardCode: usage.colorCode)?
                .displayCode(for: project.colorSystem) ?? usage.colorCode
            result[key, default: 0] += usage.quantity
        }
    }

    /// 整张图纸那一版的像素预算。**这一版会一直留在内存里**（第一屏随时要用），
    /// 所以给的是「够铺满画布」的量，不是原图。1200 万像素解出来约 48 MB。
    ///
    /// 主要给圈零件区那屏用（整张图在手机上撑死一千多点宽，1200 万像素是它的四五倍），
    /// 同时也是后面几屏的兜底 —— 零件区那一版裁好之前，它们先拿这张顶着。
    ///
    /// 这里以前是写死「长边砍到 1600」，理由是「圈零件区只要看个轮廓」。那是错的：
    /// 3600×5200 的图纸砍成 1108×1600 再铺满 1320×1911 的画布，用户进多零件模式第一眼
    /// 看到的就是一张放大过的低清图 —— 而他刚刚才特地保留了原图。
    private static let overviewPixelBudget = 12_000_000

    /// 零件区那一版的像素预算。**这一版决定用户能不能看清一颗豆子**：量格子、判色、
    /// 核对色号全靠它，放大之后一格有多少像素就是这里定的。
    ///
    /// 所以给得很高 —— 常见的图纸和手机照片（4800 万像素以内）**一个像素都不降**。
    /// 解码峰值确实大，但只是瞬时的：`upgradeWorkImage` 把零件区重画成一张独立位图，
    /// 整图那份当场还回去，常驻的只有零件区那块（**重画那一步不能省**，理由见那里）。
    /// 上限仍然留着，免得几亿像素的扫描件把 App 撑爆。
    private static let workPixelBudget = 60_000_000

    /// 按原图实际大小决定解码尺寸：够小就用原图，太大才按预算等比缩。
    private static func decodeMaxPixel(for data: Data, budget: Int) -> Int {
        guard let native = ImageDownsampler.pixelSize(of: data) else { return 3600 }
        let total = Double(native.width) * Double(native.height)
        let long = Double(max(native.width, native.height))
        guard total > Double(budget) else { return Int(long.rounded(.up)) }
        return max(1600, Int((long * (Double(budget) / total).squareRoot()).rounded()))
    }

    /// 已经裁到高清版的那块区域。用来判断「要不要重裁」，
    /// 不能拿 `work.region` 判 —— 兜底那版的 region 是整张图，会被误认成没裁过。
    @State private var highResRegion: CGRect?
    /// 现在这份高清版是拿第几代源裁的。跟 `highResRegion` 一起比，缺一不可 ——
    /// 用户补了原图之后区域没变但源变了，只比区域会以为「已经是最新的了」。
    @State private var highResGeneration = -1
    /// 正在进行的那次高清升级。存着它是为了让别人**等得到**它，见 `prepareWorkImage`。
    @State private var upgradeTask: Task<Void, Never>?

    /// 用户刚补了一张原图：整张那一版和零件区那一版都要重出一次，
    /// 界面上立刻能看出变清楚了 —— 否则他选完图什么都没发生，只能怀疑是不是没选上。
    private func reloadFromSource() async {
        let id = project.id
        // 同 load()：读盘和解码都不放主线程，否则刚选完原图界面会僵住。
        guard let data = await Task.detached(priority: .userInitiated, operation: {
            PatternSourceStore.data(for: id)
        }).value else { return }
        if let low = await Task.detached(priority: .userInitiated, operation: {
            ImageDownsampler.downsampleToUIImage(data, maxPixelSize: Self.decodeMaxPixel(for: data, budget: Self.overviewPixelBudget))
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

    /// 从原图裁出零件区那一版（零件区只占整张图一小块，同样的像素预算全花在这儿），
    /// 换掉兜底的整图版。失败就什么都不做 —— 兜底那版还在，流程照样往下走。
    private func upgradeWorkImage(region: CGRect, generation: Int) async {
        let id = project.id
        let loader = inventoryManager.imageLoader
        // 读盘放后台：原图是几十 MB 的文件，`Data(contentsOf:)` 在主线程上会卡住界面。
        var source = await Task.detached(priority: .userInitiated) { PatternSourceStore.data(for: id) }.value
        if source == nil { source = await loader?.thumbnail(for: id) }
        guard let data = source else { return }
        let built = await Task.detached(priority: .userInitiated) { () -> PartsWorkImage? in
            // 实测这一整段（取字节 + 解码 + 裁切）只要 0.10s，所以它从来不是「慢」的来源；
            // 早先那次界面卡死是因为把它做成了进入下一屏的必需条件，失败就没有退路。
            autoreleasepool {
                let maxPixel = Self.decodeMaxPixel(for: data, budget: Self.workPixelBudget)
                guard let full = ImageDownsampler.downsampleToUIImage(data, maxPixelSize: maxPixel),
                      let crop = PartsThumbnailMaker.cropExact(.whole(full), normalized: region) else { return nil }
                let cropped = crop.image
                // **必须重画一份。** `CGImage.cropping(to:)` 不复制像素，它跟整图共享
                // data provider —— 只要裁剪结果活着，整图那份解码就一直躺在内存里。
                // 而解码是 `kCGImageSourceShouldCacheImmediately`，6000 万像素就是 240 MB，
                // 会在多零件模式整个会话期间常驻（autoreleasepool 对此无能为力）。
                // 重画一次之后留下的只有零件区那块，整图当场就能还回去。
                let format = UIGraphicsImageRendererFormat.default()
                format.scale = 1
                format.opaque = true
                let detached = UIGraphicsImageRenderer(size: cropped.size, format: format).image { _ in
                    cropped.draw(in: CGRect(origin: .zero, size: cropped.size))
                }
                return PartsWorkImage(image: detached, region: crop.rect)
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
        busy = "正在识别零件…"

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
            self.boardSpacing = nil
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

    /// 已经判过色了。核对页的修改全落在 `parts` 的格子里，所以「有格子」就等于
    /// 「这儿有东西可丢」。
    private var hasClassified: Bool { parts.contains(where: \.hasCells) }

    /// 「开始判色 / 重新判色」这个按钮按下去之后的事。
    ///
    /// 判色是从头重算每一格 —— 第一次走到这儿这正是用户要的，但从核对页返回之后
    /// 再按一次，用户一格一格改过的色号会被整片盖掉。所以判过色的先问一句。
    ///
    /// **能不能判得成，必须在弹确认框之前就问清楚。** `runClassification` 开头那道
    /// 守卫是直接 return 的，从确认框里撞上它，用户看到的是「点了红色确认之后什么都没发生」——
    /// 他只会认为东西已经没了、只是界面没刷新，比这次要修的死按钮还难受。
    /// 没有标定就直接送回量格子，那一屏的标题本身就是说法。
    private func requestClassification() {
        guard calibration?.isUsable == true else {
            path = [.list, .cellSize]
            return
        }
        if hasClassified {
            prompt = .confirmReclassify
            return
        }
        runClassification()
    }

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
                        localized: "所有零件的框选区域均无法读取到图像，未能识别出任何颜色。可能是框选范围过小，请返回零件清单调整后重试。"
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
                        localized: "有 \(result.unreadableParts) 个零件的选框内无法取得图像，格子为空。请返回零件清单，检查这些选框是否过小"
                    ))
                } else if saved, let note = result.unknownLegendNote {
                    // 出路不一样（这条是「去核对页看一眼」，上面那条是「回零件清单改框」），
                    // 所以两句话不共用一个弹窗。抢同一个口子时让掉的是这条 ——
                    // 零件没看成会让整块零件空着，比色号写得对不对要紧。
                    self.prompt = .legendNote(note)
                }
                self.path = [.list, .cellSize, .baseColor, .review]
            }
        }
    }

    private func cellSizeStep(work: PartsWorkImage) -> some View {
        PartsCellSizeStepView(
            work: work,
            parts: tracked($parts),
            calibration: tracked($calibration),
            onConfirmPart: { persist() },
            onContinue: {
                persist()
                path = [.list, .cellSize, .baseColor]
            },
            focusPartId: regridTarget,
            // 从核对页跳过来的才有回程按钮。**闭包在，就说明是那一趟** ——
            // 用 `regridTarget != nil` 现算，别缓存成一个 Bool：
            // 那样退出去再进来会剩一个通向空处的按钮。
            onReturn: regridTarget == nil ? nil : {
                persist()
                path = [.list, .cellSize, .baseColor, .review]
            },
            // 多零件模式回核对页会自动补判空着的那一块，所以格线一挪就能放心
            // 把旧颜色作废，见那个参数的注释。
            clearsColorsWhenGridMoves: true
        )
    }

    /// 用户在核对页把一整类改成了别的色号：调色板跟着改。
    ///
    /// **不改的话补判会把他的修正原样抹掉。** 核对页改的是 `parts` 里的格子，
    /// 一个字节都不会回到 `palette`；而 `classifyMissingParts` 沿用的正是 `palette`。
    /// 于是「把一整类从 H8 纠正成 H7」之后再回去重对一块格子，那一块又变回 H8 ——
    /// 核对页上同一种颜色出现两个色号，用户得自己发现、自己再改一次。
    private func recolorPalette(from: PartCellFill, to: PartCellFill) {
        let fromRole = Self.paletteRole(of: from)
        let toRole = Self.paletteRole(of: to)
        guard fromRole != toRole else { return }
        var changed = false
        for index in palette.indices where palette[index].role == fromRole {
            palette[index].role = toRole
            // 这一条不再是自动匹配的结果了，那个距离没有意义
            palette[index].matchDeltaE = nil
            changed = true
        }
        if changed { dirty = true }
    }

    private static func paletteRole(of fill: PartCellFill) -> PartsPaletteEntry.Role {
        switch fill {
        case .empty: return .empty
        case .anyColor: return .anyColor
        case .code(let code): return .code(code)
        }
    }

    /// 进核对页时，把「有网格、却没有格子」的零件补判一遍。
    ///
    /// 这是用户报的那个 bug 的正面：他在核对页点开一块、跳回「量格子」重对格线，
    /// 回来时那一块的旧格子已经作废清掉了（格线一挪，每格盖住的就是别的豆子），
    /// **而新的没人去判** —— 那一块从此在所有色号组里一格都不占，看起来像是被吞了。
    ///
    /// 只补这几块，不碰别人：`runClassification` 是从头重算整张图纸并整个替换 `parts`，
    /// 走那条路等于把另外四十八块手工核对过的色号全洗掉，为修一块赔上几天的活。
    ///
    /// 颜色身份沿用上一次判色留下的调色板（见 `PartsCellClassifier.reclassify`），
    /// 补出来的这块跟旁边那些说的是同一套色号。
    private func classifyMissingParts() async {
        guard let work, let calibration, calibration.isUsable else { return }
        let pending = parts.filter { $0.rows > 0 && $0.cols > 0 && !$0.hasCells }
        guard !pending.isEmpty else { return }

        busy = pending.count == 1
            ? String(localized: "正在看这一块每格什么颜色…")
            : String(localized: "正在看这 \(pending.count) 块每格什么颜色…")

        let table = palette
        let currentROI = roi
        let colorSystem = project.colorSystem
        let legend = project.beadUsage.map(\.colorCode)
        let colors = inventoryManager.beadColors
        let base = emptyHex
        let any = anyColorHex
        let judged = await Task.detached(priority: .userInitiated) { () -> [BeadPart] in
            // 没有调色板可沿用（从没判过色 / 老数据）：这几块单独走一遍完整判色。
            // 聚类只看这几块，色号可能跟别处对不齐 —— 但那是退化情形下的次优解，
            // 比让用户面对一块永远空着的零件强。
            guard !table.isEmpty else {
                return PartsCellClassifier.classify(
                    work: work, parts: pending, roi: currentROI, calibration: calibration,
                    colorSystem: colorSystem, legendCodes: legend, availableColors: colors,
                    emptyHex: base, anyColorHex: any
                ).parts
            }
            return pending.map { part in
                PartsCellClassifier.reclassify(work: work, part: part, palette: table) ?? part
            }
        }.value

        busy = nil

        // 按 id 写回，不按下标 —— 判色跑在后台的这几秒里，用户在别的屏（比如画笔）
        // 完全可能已经删掉 / 补过零件了。
        var updated = parts
        var unreadable = 0
        for part in judged {
            guard let index = updated.firstIndex(where: { $0.id == part.id }) else { continue }
            guard part.hasCells else {
                // 图没抠出来。**也要写一片空格子进去**，否则下次进这一屏又会重判一遍，
                // 用户每进一次核对页都白等一次转圈，而结果永远是空的。
                unreadable += 1
                updated[index].cells = Array(
                    repeating: Array(repeating: PartCellFill.empty, count: max(part.cols, 0)),
                    count: max(part.rows, 0)
                )
                continue
            }
            updated[index] = part
        }
        parts = updated
        dirty = true
        let saved = persist()
        // 存不上会自己弹「这一步没存上」，那句话比这条要紧（同 `runClassification`）。
        if saved, unreadable > 0 {
            prompt = .classifyNote(String(
                localized: "有 \(unreadable) 个零件的框里取不到图，它们的格子是空的。回零件清单看看这几个框是不是太小了。"
            ))
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
            boards: boards.isEmpty ? nil : boards,
            boardSpacing: boards.isEmpty ? nil : boardSpacing
        )
        guard inventoryManager.updateProjectPartsSheet(project.id, sheet: sheet) else {
            // 没写进去。这里绝不能算了 —— 用户手上这些东西全在内存里，
            // 而屏幕上跟存好了长得一模一样，他关掉就再也找不回来。
            //
            // 也要记一笔：弹窗是给用户看的，日志是事后查「他那次到底为什么丢了」用的。
            // 隔壁 `persist_blocked_unreadable` 一直有，这条一直没有。
            AppLogger.shared.error("PartsSheet", "persist_write_failed", metadata: [
                "projectId": project.id.uuidString,
                "parts": "\(parts.count)",
                "boards": "\(boards.count)"
            ])
            saveAttempt += 1
            prompt = .saveFailed(saveAttempt)
            return false
        }
        dirty = false
        return true
    }

    private func save() {
        if persist() { dismiss() }
    }
}
