//
//  WorkshopView.swift
//  BeadInventory
//
//  工作台 Tab：正在做的事。顶上切换「拼图」和「识别」两页。
//

import SwiftUI
import UIKit

struct WorkshopView: View {
    @Binding var externalImage: UIImage?

    @EnvironmentObject private var inventoryManager: InventoryManager
    @ObservedObject private var store = PatternWorkStore.shared
    /// 上次停在哪页。空 = 第一次打开：先显示识别页，拼图概况第一次扫完后定一次 ——
    /// 有正在拼的项目就切到拼图页 —— 之后就不再自己变。外部唤起扫描时 `ContentView` 也会写它。
    @AppStorage("workshopPage") private var pageRaw: String = ""

    enum Page: String, CaseIterable, Hashable {
        case puzzle
        case scan

        var label: String {
            switch self {
            case .puzzle: return String(localized: "拼图")
            case .scan: return String(localized: "识别")
            }
        }
    }

    private var page: Page { Page(rawValue: pageRaw) ?? .scan }

    private var pageBinding: Binding<Page> {
        Binding(get: { page }, set: { pageRaw = $0.rawValue })
    }

    var body: some View {
        VStack(spacing: 0) {
            BISegmented(
                selection: pageBinding,
                segments: Page.allCases.map { ($0, $0.label) },
                fillWidth: true
            )
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .background(Theme.ColorToken.Surface.background)

            // 两页都常驻，用 opacity 切：识别页切走再切回来，选好的图和识别结果不能丢。
            ZStack {
                PatternBoardView()
                    .opacity(page == .puzzle ? 1 : 0)
                    .allowsHitTesting(page == .puzzle)
                    .accessibilityHidden(page != .puzzle)
                ScanView(externalImage: $externalImage)
                    .opacity(page == .scan ? 1 : 0)
                    .allowsHitTesting(page == .scan)
                    .accessibilityHidden(page != .scan)
            }
        }
        .background(Theme.ColorToken.Surface.background)
        .task {
            store.refreshAll(using: inventoryManager)
            chooseDefaultPageIfNeeded()
        }
        // 两页都常驻，切页不会重跑 .task，所以切到拼图页时补一次（半分钟内扫过就跳过）
        .onChange(of: page) { _, newPage in
            if newPage == .puzzle { store.refreshAll(using: inventoryManager) }
        }
        // 别的设备同步过来新进度时
        .onChange(of: inventoryManager.projectBlobsRevision) { _, _ in
            store.refreshAll(using: inventoryManager)
        }
        .onChange(of: store.hasLoadedOnce) { _, _ in
            chooseDefaultPageIfNeeded()
        }
    }

    /// 第一次打开工作台、概况也扫完了：有正在拼的就切到拼图页。只定这一次。
    private func chooseDefaultPageIfNeeded() {
        guard pageRaw.isEmpty, store.hasLoadedOnce else { return }
        let anyInProgress = inventoryManager.projects.contains {
            store.listedSummary(for: $0.id)?.stage == .inProgress
        }
        pageRaw = (anyInProgress ? Page.puzzle : Page.scan).rawValue
    }
}

// MARK: - 拼图页

/// 进过拼图模式的项目，分两组：正在拼 / 拼完。
///
/// 计划和记录里的都算 —— 扣减和拼图是两件事。点了「拼完了」的进「拼完」，
/// 其余存过东西的都在「正在拼」。
struct PatternBoardView: View {
    @EnvironmentObject private var inventoryManager: InventoryManager
    @ObservedObject private var store = PatternWorkStore.shared
    @ObservedObject private var recents = PatternRecents.shared

    @State private var searchText = ""
    @State private var showsFinished = false
    @State private var patternLaunch: PatternLaunchRequest?

    struct Item: Identifiable {
        let project: ProjectRecord
        let summary: PatternWorkSummary
        /// 排序用：这台设备上最后打开的时间和数据里记的最后改动时间，取晚的那个
        let touchedAt: Date
        /// 带上分组。同一个项目换组时，只用项目 id 的话 LazyVStack 会把旧那一行原样搬过去，
        /// 内容不刷新（模拟器里实际看到过）。
        var id: String { "\(summary.stage)-\(project.id)" }
    }

    private var items: [Item] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return inventoryManager.projects.compactMap { project in
            guard let summary = store.listedSummary(for: project.id) else { return nil }
            if !query.isEmpty && !project.name.localizedCaseInsensitiveContains(query) { return nil }
            let opened = recents.entry(for: project.id)?.openedAt ?? .distantPast
            return Item(project: project, summary: summary, touchedAt: max(opened, summary.updatedAt))
        }
        .sorted { $0.touchedAt > $1.touchedAt }
    }

    var body: some View {
        let all = items
        let inProgress = all.filter { $0.summary.stage == .inProgress }
        let finished = all.filter { $0.summary.stage == .finished }

        Group {
            if all.isEmpty && searchText.isEmpty {
                if store.hasLoadedOnce {
                    ContentUnavailableView("没有可以拼的项目", systemImage: "square.grid.3x3.square")
                } else {
                    ProgressView()
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        searchField

                        if !inProgress.isEmpty {
                            sectionHeader(String(localized: "正在拼 · \(inProgress.count)"))
                            ForEach(inProgress) { row($0) }
                        }

                        if !finished.isEmpty {
                            Button {
                                withAnimation { showsFinished.toggle() }
                            } label: {
                                HStack {
                                    sectionHeader(String(localized: "拼完 · \(finished.count)"))
                                    Spacer()
                                    Image(systemName: showsFinished ? "chevron.down" : "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Theme.ColorToken.Text.tertiary)
                                        .padding(.trailing, 18)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if showsFinished {
                                ForEach(finished) { row($0) }
                            }
                        }

                        if all.isEmpty {
                            Text("没有符合条件的项目")
                                .font(.subheadline)
                                .foregroundStyle(Theme.ColorToken.Text.tertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        }
                    }
                    .padding(.bottom, 20)
                }
                .scrollDismissesKeyboard(.immediately)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ColorToken.Surface.background)
        .patternModeLauncher($patternLaunch)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ColorToken.Text.tertiary)
            TextField("搜索项目名称", text: $searchText)
                .font(.subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.ColorToken.Text.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.ColorToken.Surface.subtle)
        )
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.ColorToken.Text.secondary)
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 6)
    }

    private func row(_ item: Item) -> some View {
        Button {
            patternLaunch = PatternLaunchRequest(projectId: item.project.id)
        } label: {
            HStack(spacing: 12) {
                ProjectThumbnailImage(projectId: item.project.id) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.ColorToken.Surface.subtle)
                } content: { image in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.project.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ColorToken.Text.primary)
                        .lineLimit(1)
                    Text(item.summary.modeName)
                        .font(.caption)
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.Text.tertiary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if item.summary.stage == .finished {
                Button {
                    store.moveBackToInProgress(item.project.id, using: inventoryManager)
                } label: {
                    Label("移回正在拼", systemImage: "arrow.uturn.backward")
                }
            }
        }
    }
}
