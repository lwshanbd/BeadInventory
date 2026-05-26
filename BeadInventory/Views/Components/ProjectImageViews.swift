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
//    - SwiftData fetch 单条 row + UIImage(data:) 解码尽量丢到 Task 里
//    - 取图失败 / 还没取到时回落到调用方提供的 placeholder
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
            if let image {
                content(image)
            } else {
                placeholder()
            }
        }
        // 复合 key：projectId 变 → 切换到另一个项目重取；revision 变 → 同项目缩略图被更新后重取。
        .task(id: TaskKey(projectId: projectId, revision: inventoryManager.projectBlobsRevision)) {
            await loadImage()
        }
    }

    private func loadImage() async {
        let id = projectId
        // SwiftData fetch + UIImage 解码丢到默认优先级 Task —— 不阻塞主线程关键渲染。
        let data = inventoryManager.fetchProjectThumbnailData(for: id)
        let decoded = await decode(data: data)
        // 任务可能在 view 切换期间被取消；async 边界上检查一下。
        guard !Task.isCancelled, id == projectId else { return }
        self.image = decoded
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

// MARK: - 项目成品图

/// 异步加载项目成品图（仅已执行项目使用）。
struct ProjectFinishedImage<Placeholder: View, Content: View>: View {
    let projectId: UUID
    @ViewBuilder let placeholder: () -> Placeholder
    @ViewBuilder let content: (UIImage) -> Content

    @EnvironmentObject private var inventoryManager: InventoryManager
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                content(image)
            } else {
                placeholder()
            }
        }
        .task(id: TaskKey(projectId: projectId, revision: inventoryManager.projectBlobsRevision)) {
            await loadImage()
        }
    }

    private func loadImage() async {
        let id = projectId
        let data = inventoryManager.fetchProjectFinishedImageData(for: id)
        let decoded = await decode(data: data)
        guard !Task.isCancelled, id == projectId else { return }
        self.image = decoded
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
