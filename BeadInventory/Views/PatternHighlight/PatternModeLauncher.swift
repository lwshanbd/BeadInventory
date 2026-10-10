//
//  PatternModeLauncher.swift
//  BeadInventory
//
//  拼图模式的统一入口。
//
//  拼图模式能从四个地方进：工作台「继续拼」、识别结果「开始拼」、计划详情、记录详情。
//  每个地方要做的事完全一样 —— 选模式（或者用上次选的）、全屏打开流程、拼完问一句
//  要不要扣减 —— 所以收成一个 `.patternModeLauncher(_:)`，各页只管给一个项目 id。
//
//  ## 扣减和拼图是两件事
//
//  有人先扣再拼，有人拼完才扣，有人从来不进拼图模式。所以：
//  - 已扣减的项目（记录里的）一样能进拼图模式；
//  - 「继续拼」只看拼图进度，不管扣没扣；
//  - 拼完时只对**还没扣减**的项目问一句，而且只是问，点「以后再说」什么都不动。
//

import SwiftUI

// MARK: - 模式

enum PatternMode: String, Codable, Sendable {
    case single
    case parts
}

// MARK: - 最近拼过的项目（本机）

/// 进过拼图模式的项目、用的哪种模式、最后一次什么时候打开。
///
/// 两个用处：工作台「继续拼」按它排序；再次进入时直接用上次的模式，不再弹选择页。
///
/// **记在 `UserDefaults`，不写进项目数据。** 理由同 `PatternFinishPrompt`：写进
/// `ProjectRecord` 要多一次模型迁移，还会跟着 iCloud 同步 —— 「我最近在拼哪几个」
/// 是这台设备上的事。代价是换台设备「继续拼」是空的，进去要重选一次模式，进度本身
/// （网格、零件摆位）照样在项目数据里，不会丢。
@MainActor
final class PatternRecents: ObservableObject {
    static let shared = PatternRecents()

    struct Entry: Codable, Equatable {
        let projectId: UUID
        var mode: PatternMode
        var openedAt: Date
        /// 用户在「继续拼」里左滑移出了。模式还记着，下次再点进去不用重选；
        /// 再进一次拼图模式就回到列表里。
        var hidden: Bool?
    }

    private static let storageKey = "patternRecents"
    /// 记多少个。「继续拼」只看最近几个，记太多只是让 UserDefaults 越来越大。
    private static let limit = 50

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

    func mode(for projectId: UUID) -> PatternMode? {
        entries.first { $0.projectId == projectId }?.mode
    }

    /// 「继续拼」要列的那些，最近打开的在前。
    var visibleEntries: [Entry] {
        entries.filter { $0.hidden != true }.sorted { $0.openedAt > $1.openedAt }
    }

    func recordOpen(_ projectId: UUID, mode: PatternMode) {
        entries.removeAll { $0.projectId == projectId }
        entries.insert(Entry(projectId: projectId, mode: mode, openedAt: Date()), at: 0)
        if entries.count > Self.limit {
            entries = Array(entries.sorted { $0.openedAt > $1.openedAt }.prefix(Self.limit))
        }
        save()
    }

    func hide(_ projectId: UUID) {
        guard let i = entries.firstIndex(where: { $0.projectId == projectId }) else { return }
        entries[i].hidden = true
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

// MARK: - 进度

/// 一个项目在拼图模式里拼到哪了。
///
/// - 单图纸：图上一共几个色号、标记完成了几个。判法跟高亮页那条色号条一致：
///   `doneColors[色号]` 等于这个色号当前的格数才算完成（格数变了就当没标过）。
/// - 多零件：一共几个零件、标记已组装几个，跟组装页顶上那行「已组装 a/b」一致。
struct PatternProgress: Equatable, Sendable {
    let mode: PatternMode
    let done: Int
    let total: Int

    var isComplete: Bool { total > 0 && done >= total }

    /// 卡片、详情页上那一行。还没量过格子 / 圈过零件时 total 是 0，只写模式名。
    var summary: String {
        switch mode {
        case .single:
            return total > 0 ? String(localized: "单图纸 · 已完成 \(done)/\(total) 色") : String(localized: "单图纸")
        case .parts:
            return total > 0 ? String(localized: "多零件 · 已组装 \(done)/\(total)") : String(localized: "多零件")
        }
    }

    /// 计划卡片上的小标签，越短越好。
    var badge: String { "\(done)/\(total)" }

    static func single(_ grid: BeadPatternGrid) -> PatternProgress {
        var counts: [String: Int] = [:]
        for row in grid.cellColorCodes {
            for case let code? in row {
                counts[code, default: 0] += 1
            }
        }
        let doneColors = grid.doneColors ?? [:]
        let done = counts.filter { doneColors[$0.key] == $0.value }.count
        return PatternProgress(mode: .single, done: done, total: counts.count)
    }

    static func parts(_ sheet: BeadPartsSheet) -> PatternProgress {
        let assembled = Set(sheet.assembledPartIds ?? [])
        let done = sheet.parts.filter { assembled.contains($0.id) }.count
        return PatternProgress(mode: .parts, done: done, total: sheet.parts.count)
    }
}

extension ProjectImageLoader {
    /// 按记下的模式读一次进度。读不出来（库忙、字节解不开）返回 nil，
    /// 调用方按「不知道」处理 —— 不显示进度，也不当成拼完了。
    func patternProgress(for projectId: UUID, mode: PatternMode) -> PatternProgress? {
        switch mode {
        // 选了模式但还没量网格 / 圈零件就退出了：进过、没进度，total 是 0。
        case .single:
            switch patternGridLoad(for: projectId) {
            case .loaded(let grid): return .single(grid)
            case .missing: return PatternProgress(mode: .single, done: 0, total: 0)
            case .unreadable: return nil
            }
        case .parts:
            switch partsSheet(for: projectId) {
            case .loaded(let sheet): return .parts(sheet)
            case .missing: return PatternProgress(mode: .parts, done: 0, total: 0)
            case .unreadable: return nil
            }
        }
    }
}

// MARK: - 启动请求

/// 「我要进这个项目的拼图模式」。各页把它塞进 `.patternModeLauncher(_:)` 绑定的那个值。
struct PatternLaunchRequest: Equatable {
    let projectId: UUID
    /// 不管记没记过，先让用户选模式。「更换拼图模式」用。
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
    @ObservedObject private var recents = PatternRecents.shared

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
    /// 用户在流程里点的是「完成」而不是「关闭」
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
        if !request.choosesMode, let mode = recents.mode(for: request.projectId) {
            open(request.projectId, mode: mode)
        } else {
            pendingMode = nil
            pickerProjectId = request.projectId
            showsPicker = true
        }
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
        recents.recordOpen(projectId, mode: mode)
        finishedTapped = false
        let run = Running(projectId: projectId, mode: mode)
        lastRun = run
        running = run
    }

    /// 流程关掉了。点的是「完成」、真的拼完了、项目还没扣减，才问要不要扣。
    private func flowDismissed() {
        onFlowDismissed()
        guard finishedTapped, let loader = inventoryManager.imageLoader,
              let run = lastRun else { return }
        finishedTapped = false
        let projectId = run.projectId
        let mode = run.mode
        Task {
            let progress = await loader.patternProgress(for: projectId, mode: mode)
            guard progress?.isComplete == true,
                  let project = inventoryManager.projects.first(where: { $0.id == projectId }),
                  project.isPlanned else { return }
            askDeductFor = project
        }
    }
}

// MARK: - 详情页上的按钮

/// 计划详情、记录详情共用的那一块：一行进度 + 「开始拼 / 继续拼」。
struct PatternModeEntryButton: View {
    let projectId: UUID
    /// 拼图模式关掉之后加一，让进度重读一次。
    var refreshToken: Int = 0
    let action: () -> Void

    @EnvironmentObject private var inventoryManager: InventoryManager
    @ObservedObject private var recents = PatternRecents.shared
    @State private var progress: PatternProgress?

    private var mode: PatternMode? { recents.mode(for: projectId) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if let progress {
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.3x3.square")
                    Text(progress.summary)
                        .monospacedDigit()
                }
                .font(.subheadline)
                .foregroundStyle(Theme.ColorToken.Text.secondary)
            }

            Button(action: action) {
                HStack {
                    Image(systemName: "square.grid.3x3.square")
                    Text(mode == nil ? "开始拼" : "继续拼")
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Theme.ColorToken.Fill.mauve)
                .cornerRadius(Theme.Radius.md)
            }
        }
        .task(id: TaskKey(mode: mode, refreshToken: refreshToken)) {
            guard let mode, let loader = inventoryManager.imageLoader else {
                progress = nil
                return
            }
            progress = await loader.patternProgress(for: projectId, mode: mode)
        }
    }

    private struct TaskKey: Equatable {
        let mode: PatternMode?
        let refreshToken: Int
    }
}

// MARK: - 列表卡片上的进度

/// 计划卡片右下角那一小行「多零件 · 已组装 3/8」。
///
/// 只有这台设备上进过拼图模式的项目才去读（`PatternRecents` 里有它），其余的卡片
/// 什么都不做 —— 计划列表可能有几百张卡，不能每张都去库里取一次网格。
struct PatternProgressLabel: View {
    let projectId: UUID

    @EnvironmentObject private var inventoryManager: InventoryManager
    @ObservedObject private var recents = PatternRecents.shared
    @State private var progress: PatternProgress?

    private var label: String {
        guard let progress, progress.total > 0 else { return "" }
        return progress.isComplete ? String(localized: "已拼完") : progress.summary
    }

    var body: some View {
        // 始终放一个 Text：里面什么都没有的话 SwiftUI 不认为这个视图出现过，
        // 下面的 .task 永远不跑，进度也就永远读不出来。
        Text(label)
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(Theme.ColorToken.Morandi.mauve)
            .lineLimit(1)
            .task(id: recents.mode(for: projectId)) {
                guard let mode = recents.mode(for: projectId),
                      let loader = inventoryManager.imageLoader else {
                    progress = nil
                    return
                }
                progress = await loader.patternProgress(for: projectId, mode: mode)
            }
    }
}
