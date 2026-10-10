//
//  WorkshopView.swift
//  BeadInventory
//
//  工作台 Tab：正在做的事 —— 识别图纸、拼图模式。
//  「我的计划」已经搬出去成了独立的「计划」Tab（五栏：库存 / 计划 / 工作台 / 记录 / 更多）。
//

import SwiftUI
import UIKit

struct WorkshopView: View {
    @Binding var externalImage: UIImage?

    var body: some View {
        ScanView(externalImage: $externalImage)
    }
}

// MARK: - 继续拼

/// 工作台顶上那一排：最近进过拼图模式、还没拼完的项目，点一下回到上次的地方。
///
/// 只看拼图进度，不管扣没扣 —— 有人先扣再拼。拼完了（全部色号标记完成 / 全部零件
/// 已组装）就不再列出来。长按可以手动移出。
///
/// 放在扫描页里而不是工作台另起一页：用户拿起手机要么是接着拼，要么是扫一张新的，
/// 两件事在同一屏上，不用先选。
struct ContinueAssemblingSection: View {
    /// 拼图模式关掉之后加一，进度重读一次。
    let refreshToken: Int
    let onSelect: (UUID) -> Void

    @EnvironmentObject private var inventoryManager: InventoryManager
    @ObservedObject private var recents = PatternRecents.shared

    /// 读完进度、筛掉拼完的之后，真正要显示的
    @State private var items: [Item] = []

    private struct Item: Identifiable, Equatable {
        let project: ProjectRecord
        let progress: PatternProgress?
        var id: UUID { project.id }
    }

    /// 最多列几个。再多就不是「继续」了，用户自己去计划 / 记录里找。
    private static let limit = 10

    private var candidates: [(ProjectRecord, PatternMode)] {
        let byId = Dictionary(inventoryManager.projects.map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        return recents.visibleEntries
            .compactMap { entry in byId[entry.projectId].map { ($0, entry.mode) } }
            .prefix(Self.limit)
            .map { $0 }
    }

    private struct LoadKey: Equatable {
        let ids: [UUID]
        let refreshToken: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 占位。列表还没读出来时这里什么都没有，没有它 SwiftUI 不认为这个视图
            // 出现过，下面的 .task 永远不跑，列表也就永远是空的。
            Color.clear.frame(height: 0)
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("继续拼")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                        .padding(.horizontal, Theme.Spacing.lg)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(items) { item in
                                card(item)
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.lg)
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 8)
            }
        }
        .task(id: LoadKey(ids: candidates.map(\.0.id), refreshToken: refreshToken)) {
            await load()
        }
    }

    private func card(_ item: Item) -> some View {
        Button {
            onSelect(item.project.id)
        } label: {
            HStack(spacing: 10) {
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
                    if let progress = item.progress {
                        Text(progress.summary)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.ColorToken.Text.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(width: 150, alignment: .leading)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Theme.ColorToken.Surface.elevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                recents.hide(item.project.id)
                items.removeAll { $0.id == item.id }
            } label: {
                Label("从「继续拼」中移除", systemImage: "eye.slash")
            }
        }
    }

    private func load() async {
        let candidates = self.candidates
        guard !candidates.isEmpty, let loader = inventoryManager.imageLoader else {
            items = []
            return
        }
        var loaded: [Item] = []
        for (project, mode) in candidates {
            let progress = await loader.patternProgress(for: project.id, mode: mode)
            if Task.isCancelled { return }
            // 读不出来的照样列着（不显示进度），只有确认拼完了才不列
            if progress?.isComplete == true { continue }
            loaded.append(Item(project: project, progress: progress))
        }
        items = loaded
    }
}
