//
//  PatternModeLauncher.swift
//  BeadInventory
//
//  拼图模式的统一入口。
//
//  拼图模式能从四个地方进：工作台「拼图」页、识别结果「开始拼」、计划详情、记录详情。
//  每个地方要做的事完全一样 —— 选模式（或者用已有的）、全屏打开流程、拼完问一句
//  要不要扣减 —— 所以收成一个 `.patternModeLauncher(_:)`，各页只管给一个项目 id。
//
//  ## 扣减和拼图是两件事
//
//  有人先扣再拼，有人拼完才扣，有人从来不进拼图模式。所以：
//  - 已扣减的项目（记录里的）一样能进拼图模式；
//  - 「拼图」页只看拼没拼完，不管扣没扣；
//  - 点「拼完了」时只对**还没扣减**的项目问一句，而且只是问，点「以后再说」什么都不动。
//
//  ## 拼没拼完只认用户那一下
//
//  拼图页只有两组：「正在拼」「拼完」。进过拼图模式、存过东西的都在「正在拼」；
//  用户在拼图模式里点了「拼完了」才进「拼完」（记在项目的 `patternFinishedAt` 上，
//  一个项目一份，不分模式）。
//  不从颜色勾了几个、零件组装了几块往外推 —— 推出来的规则用户看不见，
//  推错了就是「我明明拼完了它还说没拼完」。
//

import SwiftUI

// MARK: - 模式

enum PatternMode: String, Codable, Sendable {
    case single
    case parts
}

// MARK: - 本机最近打开记录

/// 这台设备上最近一次打开某个项目拼图模式的时间和模式。
///
/// 拼图数据本身（网格、零件）在项目里，跟着 iCloud 走；这里只补两件项目数据回答不了的事：
/// 「正在拼」里谁排前面（最近打开的在前），以及一个项目两种模式都做过时默认进哪个。
///
/// **记在 `UserDefaults`，不写进项目数据**：写进 `ProjectRecord` 要多一次模型迁移，
/// 而「我最近在这台设备上开过哪个」本来就是这台设备的事。
@MainActor
final class PatternRecents: ObservableObject {
    static let shared = PatternRecents()

    struct Entry: Codable, Equatable {
        let projectId: UUID
        var mode: PatternMode
        var openedAt: Date
    }

    private static let storageKey = "patternRecents"
    /// 记多少个。只拿来排序和挑默认模式，记太多只是让 UserDefaults 越来越大。
    private static let limit = 200

    @Published private(set) var entries: [Entry]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = decoded
        } else {
            entries = []
        }
    }

    func entry(for projectId: UUID) -> Entry? {
        entries.first { $0.projectId == projectId }
    }

    func recordOpen(_ projectId: UUID, mode: PatternMode) {
        entries.removeAll { $0.projectId == projectId }
        entries.insert(Entry(projectId: projectId, mode: mode, openedAt: Date()), at: 0)
        if entries.count > Self.limit {
            entries = Array(entries.sorted { $0.openedAt > $1.openedAt }.prefix(Self.limit))
        }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

// MARK: - 概况

/// 拼图页的两组
enum PatternStage: Sendable {
    case inProgress
    case finished
}

/// 一个项目在某一种模式里的概况。从网格 / 零件数据里读出来，读完就把大数据扔掉。
struct PatternWorkSummary: Equatable, Sendable {
    let mode: PatternMode
    let stage: PatternStage
    /// 数据里记的最后一次改动时间。排序用，也用来在两种模式都做过时挑一个。
    let updatedAt: Date

    var modeName: String {
        mode == .single ? String(localized: "单图纸") : String(localized: "多零件")
    }

    /// - Parameter finishedAt: 项目的拼完时间（见 `ProjectImageLoader.patternWork(for:)`）。两种模式共用这一个。
    static func single(_ grid: BeadPatternGrid, finishedAt: Date?) -> PatternWorkSummary {
        PatternWorkSummary(
            mode: .single,
            stage: finishedAt == nil ? .inProgress : .finished,
            updatedAt: max(grid.lastCalibratedAt, finishedAt ?? .distantPast)
        )
    }

    static func parts(_ sheet: BeadPartsSheet, finishedAt: Date?) -> PatternWorkSummary {
        PatternWorkSummary(
            mode: .parts,
            stage: finishedAt == nil ? .inProgress : .finished,
            updatedAt: max(sheet.lastUpdatedAt, finishedAt ?? .distantPast)
        )
    }

    /// 选了这个模式但一点数据都还没存（比如只裁了个框就退出）
    static func empty(_ mode: PatternMode) -> PatternWorkSummary {
        PatternWorkSummary(mode: mode, stage: .inProgress, updatedAt: .distantPast)
    }
}

/// 一个项目两种模式各自的概况。没做过的那种是 nil。
struct PatternWork: Sendable {
    var single: PatternWorkSummary?
    var parts: PatternWorkSummary?
    /// 有一种存着数据但这次没读出来（库忙、字节解不开）。这时不能拿它当「没做过」。
    var unreadable = false

    var isEmpty: Bool { single == nil && parts == nil }
}

extension ProjectImageLoader {
    /// 零件数据一份能有一两 MB，在这个 actor 里解码、算完就扔，不带回主线程。
    ///
    /// 拼完时间以项目那一列为准。那一列是空的、网格 / 零件数据里却记着（老版本的存法），
    /// 就用数据里的。打开拼图模式时会搬到项目上（见 `PatternFinishLoader`），
    /// 搬之前、或者搬失败时，都靠这里兜底。
    func patternWork(for projectId: UUID) -> PatternWork {
        var work = PatternWork()
        var grid: BeadPatternGrid?
        var sheet: BeadPartsSheet?
        switch patternGridLoad(for: projectId) {
        case .loaded(let loaded): grid = loaded
        case .missing: break
        case .unreadable: work.unreadable = true
        }
        switch partsSheet(for: projectId) {
        case .loaded(let loaded): sheet = loaded
        case .missing: break
        case .unreadable: work.unreadable = true
        }
        let finishedAt: Date?
        switch patternFinishedAt(for: projectId) {
        case .success(let date):
            finishedAt = date ?? grid?.finishedAt ?? sheet?.finishedAt
        case .failure:
            // 读不出来就别猜：猜成「没拼完」会把拼完的项目挪进「正在拼」。
            // 两份概况都不给，调用方留着上次的；第一次扫描没有上次的，这个项目这一轮先不列
            work.unreadable = true
            return work
        }
        work.single = grid.map { .single($0, finishedAt: finishedAt) }
        work.parts = sheet.map { .parts($0, finishedAt: finishedAt) }
        return work
    }
}

// MARK: - 拼图概况缓存

/// 所有项目的拼图概况。拼图页、计划页、详情页都从这里读。
///
/// 算一份概况要把零件数据整个解码一遍，几十个项目就是几十 MB，所以：
/// - 先用 SQLite 只看记录头，找出哪些项目存过网格或零件，没存过的一个都不碰；
/// - 算好的留在内存里。拼图模式关掉时只重算那一个；整体重扫最多半分钟一次，
///   算完一次性换上（别的设备同步过来的改动靠这一步跟上）。
@MainActor
final class PatternWorkStore: ObservableObject {
    static let shared = PatternWorkStore()

    @Published private(set) var works: [UUID: PatternWork] = [:]
    /// 至少成功扫过一遍了。在这之前拼图页显示「正在读取」，不显示「没有项目」。
    @Published private(set) var hasLoadedOnce = false

    private var refreshTask: Task<Void, Never>?
    private var lastFullRefresh: Date?
    /// 扫的过程中又有人要扫（比如同步刚送来新数据）：这一遍完了再来一遍。
    private var needsAnotherRefresh = false
    private static let minRefreshInterval: TimeInterval = 30

    /// 这个项目现在该用哪种模式、拼到哪了。
    ///
    /// 拼没拼完是项目的事，两种模式的拼完状态一样，这里只挑模式：
    /// 两种都做过时，这台设备上最后用的那种优先，没记录就取最近改过的那种。
    /// 只做过一种：就是那种。本机最近选了另一种但那边还什么都没做（比如点了
    /// 「更换拼图模式」又退出来），仍然显示做过的这种 —— 不能让一次误点把进度藏起来。
    /// 都没做过但这台设备上选过模式：那种模式的空概况。
    func summary(for projectId: UUID) -> PatternWorkSummary? {
        let recent = PatternRecents.shared.entry(for: projectId)?.mode
        let work = works[projectId]
        switch (work?.single, work?.parts) {
        case let (s?, p?):
            if let recent { return recent == .single ? s : p }
            return s.updatedAt >= p.updatedAt ? s : p
        case let (s?, nil):
            return s
        case let (nil, p?):
            return p
        case (nil, nil):
            return recent.map { .empty($0) }
        }
    }

    /// 重扫一遍。半分钟内扫过就不扫；正在扫就等这一遍完了再补一遍。
    func refreshAll(using inventoryManager: InventoryManager) {
        if refreshTask != nil {
            needsAnotherRefresh = true
            return
        }
        if let lastFullRefresh, Date().timeIntervalSince(lastFullRefresh) < Self.minRefreshInterval {
            return
        }
        guard let loader = inventoryManager.imageLoader,
              let storeURL = inventoryManager.storeURL else { return }
        refreshTask = Task { [weak self] in
            let scanned = await Task.detached(priority: .utility) {
                ProjectBlobExistenceScanner.scanPatternWork(storeURL: storeURL)
            }.value
            guard let self else { return }
            defer {
                self.refreshTask = nil
                if self.needsAnotherRefresh {
                    self.needsAnotherRefresh = false
                    self.lastFullRefresh = nil
                    self.refreshAll(using: inventoryManager)
                }
            }
            guard case .success(let ids) = scanned else {
                // 不标记「已加载」：显示「没有项目」会让人以为全没了，下次进来再扫
                AppLogger.shared.error("PatternWork", "scan_failed", metadata: ["error": "\(scanned)"])
                return
            }
            var updated: [UUID: PatternWork] = [:]
            for id in ids.grid.union(ids.parts) {
                let work = await loader.patternWork(for: id)
                // 这次没读出来：留着上次的，别让在拼的项目从列表里消失
                updated[id] = (work.unreadable ? self.works[id] : nil) ?? work
            }
            // 一次性换上：逐个写会让每张计划卡片跟着重绘几十遍
            self.works = updated
            self.hasLoadedOnce = true
            self.lastFullRefresh = Date()
        }
    }

    /// 拼图页、计划卡片用：只有存过东西的项目才算进「正在拼 / 拼完」。
    /// 只选了模式、什么都没存（裁了个框就退出）的不列。
    func listedSummary(for projectId: UUID) -> PatternWorkSummary? {
        guard works[projectId] != nil else { return nil }
        return summary(for: projectId)
    }

    /// 「移回正在拼」：清掉项目上的拼完时间。
    ///
    /// 顺带清掉老版本记在网格 / 零件数据里的 `finishedAt`，不然概况会拿它兜底，
    /// 看起来还是拼完。没有老数据的项目只读不写。
    /// - Returns: false = 没写进去，或者有一份数据没读出来（没法确认里面有没有老的拼完时间），
    ///   调用方要告诉用户。读不出来时不能当成「没有数据」跳过 —— 那样点了没反应，也没有说法。
    @discardableResult
    func moveBackToInProgress(_ projectId: UUID, using inventoryManager: InventoryManager) -> Bool {
        defer { Task { await refresh(projectId, using: inventoryManager) } }
        // 先读完再写：读到一半失败就什么都不动，按钮和库里保持一致
        guard case .success(let gridData) = inventoryManager.fetchProjectPatternGridDataResult(for: projectId),
              case .success(let sheetData) = inventoryManager.fetchProjectPartsSheetDataResult(for: projectId) else {
            return false
        }
        guard inventoryManager.updateProjectPatternFinishedAt(projectId, finishedAt: nil) else { return false }
        var ok = true
        if var grid = SDProjectRecord.decodePatternGrid(gridData, projectId: projectId), grid.finishedAt != nil {
            grid.finishedAt = nil
            ok = inventoryManager.updateProjectPatternGrid(projectId, grid: grid) && ok
        }
        if var sheet = SDProjectRecord.decodePartsSheet(sheetData, projectId: projectId), sheet.finishedAt != nil {
            sheet.finishedAt = nil
            ok = inventoryManager.updateProjectPartsSheet(projectId, sheet: sheet) && ok
        }
        return ok
    }

    /// 只重算一个。拼图模式关掉、详情页出现、缓存里还没有这个项目时用。
    @discardableResult
    func refresh(_ projectId: UUID, using inventoryManager: InventoryManager) async -> PatternWorkSummary? {
        guard let loader = inventoryManager.imageLoader else { return summary(for: projectId) }
        let work = await loader.patternWork(for: projectId)
        if !work.unreadable {
            works[projectId] = work.isEmpty ? nil : work
        }
        return summary(for: projectId)
    }
}

// MARK: - 流程里的「拼完了」

/// 打开拼图流程时读拼完状态，顺手把老数据搬到项目上。
/// 点「拼完了 / 移回正在拼」的写入在两个流程的 `markFinished` / `markUnfinished` 里。
@MainActor
enum PatternFinishLoader {
    struct Result {
        /// 给按钮用：拼完了没有。
        let finishedAt: Date?
        /// 流程存进度时要原样写回自己那份数据的老拼完时间。
        ///
        /// 流程存进度是整份新建网格 / 零件数据，不带老字段。老值还没搬到项目上时
        /// （读项目那一列失败、或者搬的时候没写进去），不带回去它就在第一次存进度时没了，
        /// 拼完的项目悄悄回到「正在拼」。搬成功了是 nil。
        let legacyToKeep: Date?
    }

    /// - Parameter ownLegacy: 流程自己读到的那份数据里的老 `finishedAt`。
    ///   另一种模式的那份由这里自己去读：老值可能只记在另一边，
    ///   只看自己这边的话，按钮说没拼完，工作台却说拼完了。
    static func load(
        _ projectId: UUID,
        mode: PatternMode,
        ownLegacy: Date?,
        using inventoryManager: InventoryManager
    ) async -> Result {
        guard let loader = inventoryManager.imageLoader else {
            AppLogger.shared.error("PatternFinish", "no_loader", metadata: ["projectId": projectId.uuidString])
            return Result(finishedAt: ownLegacy, legacyToKeep: ownLegacy)
        }
        switch await loader.patternFinishedAt(for: projectId) {
        case .success(let date?):
            return Result(finishedAt: date, legacyToKeep: nil)
        case .success(nil):
            var legacy = ownLegacy
            if legacy == nil {
                switch mode {
                case .single:
                    if case .loaded(let sheet) = await loader.partsSheet(for: projectId) { legacy = sheet.finishedAt }
                case .parts:
                    if case .loaded(let grid) = await loader.patternGridLoad(for: projectId) { legacy = grid.finishedAt }
                }
            }
            guard let legacy else { return Result(finishedAt: nil, legacyToKeep: nil) }
            guard inventoryManager.updateProjectPatternFinishedAt(projectId, finishedAt: legacy) else {
                AppLogger.shared.error("PatternFinish", "legacy_migration_failed", metadata: ["projectId": projectId.uuidString])
                return Result(finishedAt: legacy, legacyToKeep: ownLegacy)
            }
            return Result(finishedAt: legacy, legacyToKeep: nil)
        case .failure:
            // 读不出项目那一列：按钮先照老数据显示，老值留在数据里下次再搬
            AppLogger.shared.error("PatternFinish", "column_unreadable", metadata: ["projectId": projectId.uuidString])
            return Result(finishedAt: ownLegacy, legacyToKeep: ownLegacy)
        }
    }
}

// MARK: - 启动请求

/// 「我要进这个项目的拼图模式」。各页把它塞进 `.patternModeLauncher(_:)` 绑定的那个值。
struct PatternLaunchRequest: Equatable {
    let projectId: UUID
    /// 不管有没有做过，先让用户选模式。「更换拼图模式」用。
    var choosesMode = false
    /// 区分两次相同的请求（连点同一个项目两次）。
    let token = UUID()
}

extension View {
    /// 挂上拼图模式：选模式页、全屏流程、拼完后的扣减询问。
    ///
    /// - Parameter onFlowDismissed: 流程关掉之后调用。详情页拿它刷新「图纸原图」那一行，
    ///   因为拼图模式里能删也能补原图。
    func patternModeLauncher(
        _ request: Binding<PatternLaunchRequest?>,
        onFlowDismissed: @escaping () -> Void = {}
    ) -> some View {
        modifier(PatternModeLauncherModifier(request: request, onFlowDismissed: onFlowDismissed))
    }
}

private struct PatternModeLauncherModifier: ViewModifier {
    @Binding var request: PatternLaunchRequest?
    let onFlowDismissed: () -> Void

    @EnvironmentObject private var inventoryManager: InventoryManager

    private struct Running: Identifiable {
        let projectId: UUID
        let mode: PatternMode
        var id: UUID { projectId }
    }

    @State private var showsPicker = false
    /// 选模式页是给哪个项目开的
    @State private var pickerProjectId: UUID?
    /// 选模式页里选了什么。要等它收起之后再开流程，同时 present 会被 SwiftUI 吞掉。
    @State private var pendingMode: PatternMode?
    @State private var running: Running?
    /// 最近一次打开的流程。fullScreenCover 的 onDismiss 跑的时候 `running` 已经是 nil 了。
    @State private var lastRun: Running?
    /// 用户在流程里点的是「拼完了」而不是「退出」
    @State private var finishedTapped = false
    @State private var askDeductFor: ProjectRecord?
    @State private var executing: ProjectRecord?

    func body(content: Content) -> some View {
        content
            .onChange(of: request) { _, newValue in
                guard let newValue else { return }
                request = nil
                start(newValue)
            }
            .sheet(isPresented: $showsPicker, onDismiss: openPendingMode) {
                PatternModeSelectionSheet(
                    onSelectSinglePattern: { pendingMode = .single },
                    onSelectMultiPart: { pendingMode = .parts }
                )
            }
            .fullScreenCover(item: $running, onDismiss: flowDismissed) { run in
                flow(for: run)
            }
            .alert(
                "要扣减库存吗？",
                isPresented: Binding(
                    get: { askDeductFor != nil },
                    set: { if !$0 { askDeductFor = nil } }
                ),
                presenting: askDeductFor
            ) { project in
                Button("扣减库存") { executing = project }
                Button("以后再说", role: .cancel) { }
            } message: { project in
                Text("「\(project.name)」已经拼完了。")
            }
            .sheet(item: $executing) { project in
                ExecutePlannedProjectSheet(project: project)
                    .environmentObject(inventoryManager)
            }
    }

    @ViewBuilder
    private func flow(for run: Running) -> some View {
        if let project = inventoryManager.projects.first(where: { $0.id == run.projectId }) {
            switch run.mode {
            case .single:
                SinglePatternFlowView(project: project, onFinished: { finishedTapped = true })
                    .environmentObject(inventoryManager)
            case .parts:
                PartsSheetFlowView(project: project, onFinished: { finishedTapped = true })
                    .environmentObject(inventoryManager)
            }
        } else {
            // 项目在流程打开前一刻被删了（比如另一台设备同步过来）
            Color.clear.onAppear { running = nil }
        }
    }

    private func start(_ request: PatternLaunchRequest) {
        let projectId = request.projectId
        if request.choosesMode {
            showPicker(for: projectId)
            return
        }
        if let mode = PatternWorkStore.shared.summary(for: projectId)?.mode {
            open(projectId, mode: mode)
            return
        }
        // 缓存里还没有（拼图页没打开过）：现查一次这个项目做过哪种
        Task {
            let summary = await PatternWorkStore.shared.refresh(projectId, using: inventoryManager)
            if let mode = summary?.mode {
                open(projectId, mode: mode)
            } else {
                showPicker(for: projectId)
            }
        }
    }

    private func showPicker(for projectId: UUID) {
        pendingMode = nil
        pickerProjectId = projectId
        showsPicker = true
    }

    private func openPendingMode() {
        defer {
            pickerProjectId = nil
            pendingMode = nil
        }
        guard let projectId = pickerProjectId, let mode = pendingMode else { return }
        open(projectId, mode: mode)
    }

    private func open(_ projectId: UUID, mode: PatternMode) {
        PatternRecents.shared.recordOpen(projectId, mode: mode)
        finishedTapped = false
        let run = Running(projectId: projectId, mode: mode)
        lastRun = run
        running = run
    }

    /// 流程关掉了。重算这个项目的概况；点的是「拼完了」、项目还没扣减，才问要不要扣。
    private func flowDismissed() {
        onFlowDismissed()
        guard let run = lastRun else { return }
        let askIfFinished = finishedTapped
        finishedTapped = false
        Task {
            let summary = await PatternWorkStore.shared.refresh(run.projectId, using: inventoryManager)
            guard askIfFinished, summary?.stage == .finished,
                  let project = inventoryManager.projects.first(where: { $0.id == run.projectId }),
                  project.isPlanned else { return }
            askDeductFor = project
        }
    }
}

// MARK: - 详情页上的按钮

/// 计划详情、记录详情共用的那一块：一行「单图纸 · 正在拼」+「开始拼 / 继续拼」。
struct PatternModeEntryButton: View {
    let projectId: UUID
    let action: () -> Void

    @EnvironmentObject private var inventoryManager: InventoryManager
    @ObservedObject private var store = PatternWorkStore.shared
    @ObservedObject private var recents = PatternRecents.shared

    private var summary: PatternWorkSummary? { store.summary(for: projectId) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if let summary = store.listedSummary(for: projectId) {
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.3x3.square")
                    Text(summary.stage == .finished
                         ? String(localized: "\(summary.modeName) · 拼完")
                         : String(localized: "\(summary.modeName) · 正在拼"))
                }
                .font(.subheadline)
                .foregroundStyle(Theme.ColorToken.Text.secondary)
            }

            Button(action: action) {
                HStack {
                    Image(systemName: "square.grid.3x3.square")
                    Text(summary == nil ? "开始拼" : "继续拼")
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Theme.ColorToken.Fill.mauve)
                .cornerRadius(Theme.Radius.md)
            }
        }
        .task(id: projectId) {
            await store.refresh(projectId, using: inventoryManager)
        }
    }
}

// MARK: - 列表卡片上的进度

/// 计划卡片右下角那一小行：「正在拼」或「拼完」。
///
/// 只读缓存，不自己去库里取 —— 计划列表可能有几百张卡。缓存由计划页、拼图页的整体扫描，
/// 以及详情页和拼图模式关掉时的单个重算填上。
struct PatternProgressLabel: View {
    let projectId: UUID

    @ObservedObject private var store = PatternWorkStore.shared
    @ObservedObject private var recents = PatternRecents.shared

    private var label: String {
        switch store.listedSummary(for: projectId)?.stage {
        case .inProgress: return String(localized: "正在拼")
        case .finished: return String(localized: "拼完")
        case nil: return ""
        }
    }

    var body: some View {
        Text(label)
            .font(.system(size: 11))
            .foregroundStyle(Theme.ColorToken.Morandi.mauve)
            .lineLimit(1)
    }
}
