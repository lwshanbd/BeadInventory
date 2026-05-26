//
//  ProjectImageViews.swift
//  BeadInventory
//
//  按需异步加载项目图片的 SwiftUI 组件。
//
//  背景：自 v2.0.x 起 `InventoryManager.projects` 不再持有 thumbnail / finishedImage
//  两个大 Data blob，以免 458+ 项目级用户加载完即 ~200MB 撞 jetsam。这两个组件
//  是按需取图 + 解码的标准入口：
//
//    - .task(id: 复合 key 含 projectId + projectBlobsRevision) 触发取图
//    - SwiftData fetch 单条 row（InventoryManager 是 @MainActor —— 取图本身仍在主 actor 跑）
//    - UIImage(data:) 创建实例（实际解码延迟到上屏 draw time）
//    - 取图失败 / 还没取到时回落到调用方提供的 placeholder
//
//  关于"异步"的真相：本组件不是把 SwiftData fetch 真的搬到后台线程跑 —— fetch 仍在
//  MainActor 上。`.task { }` 的好处是 (1) 让出当前 runloop tick，避免首屏 commit 和
//  fetch 串在同一帧上挤碎窗口；(2) Task 可取消，row 切换 / view 销毁时不残留。
//  真正想完全脱离主 actor 需要后台 ModelActor —— 留 follow-up。
//
//  调用方负责 frame / clipShape / 圆角等视觉装饰；本组件只负责图源管理。
//

import SwiftUI

// MARK: - 项目缩略图

/// 异步加载项目缩略图。
///
/// 用法：
/// ```swift
/// ProjectThumbnailImage(projectId: project.id) {
///     // 占位 / 空态
///     Image(systemName: "photo")
/// } content: { uiImage in
///     Image(uiImage: uiImage)
///         .resizable()
///         .scaledToFill()
/// }
/// ```
struct ProjectThumbnailImage<Placeholder: View, Content: View>: View {
    let projectId: UUID
    @ViewBuilder let placeholder: () -> Placeholder
    @ViewBuilder let content: (UIImage) -> Content

    @EnvironmentObject private var inventoryManager: InventoryManager
    @State private var image: UIImage?

    var body: some View {
        Group {
            // 用 loadedKey 守门 —— 只有 image 是为「当前 projectId + revision」加载的才显示。
            // LazyVStack row reuse + revision 跳变都会让 key 变，旧图立刻被认为是过期。
            if let image, loadedKey == currentKey {
                content(image)
            } else {
                placeholder()
            }
        }
        .task(id: currentKey) {
            await loadImage(for: currentKey)
        }
    }

    private var currentKey: TaskKey {
        TaskKey(projectId: projectId, revision: inventoryManager.projectBlobsRevision)
    }

    private func loadImage(for key: TaskKey) async {
        // 先清旧图，再去取新图 —— 否则切到一个没图的项目时，旧 image 状态会让
        // body 的 `if let image` 直接显示上一个项目的图。
        // 注意：要清的是「不属于当前 key」的旧值。
        if loadedKey != key {
            self.image = nil
            self.loadedKey = nil
        }
        // SwiftData fetch + UIImage 解码丢到默认优先级 Task —— 不阻塞 SwiftUI layout commit
        // 的关键 runloop tick（InventoryManager 是 @MainActor，fetch 仍走主 actor）。
        let data = inventoryManager.fetchProjectThumbnailData(for: key.projectId)
        let decoded = await decode(data: data)
        // 任务可能在 view 切换期间被取消；async 边界上重新校验 key。
        guard !Task.isCancelled, currentKey == key else { return }
        self.image = decoded
        self.loadedKey = key
    }

    private nonisolated func decode(data: Data?) async -> UIImage? {
        guard let data else { return nil }
        return UIImage(data: data)
    }

    @State private var loadedKey: TaskKey?

    private struct TaskKey: Hashable {
        let projectId: UUID
        let revision: Int
    }
}

// MARK: - 项目成品图

/// 异步加载项目成品图（仅已执行项目使用）。
struct ProjectFinishedImage<Placeholder: View, Content: View>: View {
    let projectId: UUID
    @ViewBuilder let placeholder: () -> Placeholder
    @ViewBuilder let content: (UIImage) -> Content

    @EnvironmentObject private var inventoryManager: InventoryManager
    @State private var image: UIImage?
    @State private var loadedKey: TaskKey?

    var body: some View {
        Group {
            if let image, loadedKey == currentKey {
                content(image)
            } else {
                placeholder()
            }
        }
        .task(id: currentKey) {
            await loadImage(for: currentKey)
        }
    }

    private var currentKey: TaskKey {
        TaskKey(projectId: projectId, revision: inventoryManager.projectBlobsRevision)
    }

    private func loadImage(for key: TaskKey) async {
        if loadedKey != key {
            self.image = nil
            self.loadedKey = nil
        }
        let data = inventoryManager.fetchProjectFinishedImageData(for: key.projectId)
        let decoded = await decode(data: data)
        guard !Task.isCancelled, currentKey == key else { return }
        self.image = decoded
        self.loadedKey = key
    }

    private nonisolated func decode(data: Data?) async -> UIImage? {
        guard let data else { return nil }
        return UIImage(data: data)
    }

    private struct TaskKey: Hashable {
        let projectId: UUID
        let revision: Int
    }
}
