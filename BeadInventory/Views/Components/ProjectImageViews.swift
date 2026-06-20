//
//  ProjectImageViews.swift
//  BeadInventory
//
//  按需异步加载项目图片的 SwiftUI 组件。
//
//  背景：自 v2.0.x 起 `InventoryManager.projects` 不再持有大 Data blob，以免 458+ 项目级
//  用户加载完即 ~200MB 撞 jetsam。两个组件是按需取图 + 解码的标准入口。
//
//  **`ProjectThumbnailImage` 的关键 jetsam 修复**：列表 row 用的缩略图视图**永远不**
//  直接 `UIImage(data: raw_thumbnail)` —— raw thumbnail 是全分辨率 PNG，可达 5-10 MB，
//  解码后 UIImage 占 30+ MB；10 个 LazyVStack row 同屏 = 300+ MB ⇒ jetsam。优先级：
//
//    1. **`fetchProjectDisplayThumbnail`** —— 512px JPEG 0.85 小图，~50-100 KB，UIImage(data:) 安全
//    2. **没有 displayThumbnail 则 `ImageDownsampler.downsampleToUIImage(thumbnail)`** ——
//       CGImageSourceCreateThumbnailAtIndex 在 source 层就限制尺寸，内存峰值 KB 级
//    3. 都失败 → placeholder
//
//  这样老用户的大图在迁移协调器还没跑完之前也安全（走路径 2），新数据直接走路径 1。
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
            // 显示守门：image 是给当前 projectId 加载的就显示。
            // **修复闪烁（PR #48 上线后用户报告）**：之前这里是 `loadedKey == currentKey`，
            // currentKey 含 projectBlobsRevision，迁移协调器每写一个 displayThumbnail
            // 就 bump 一次 revision → 屏幕上每个 row 立刻被判定为"过期" → body 翻成
            // placeholder（六色图）→ .task 重跑取图 → image 重新显示 → 下次 bump 又翻回
            // placeholder。458 项目用户场景：迁移 ~10/sec × 10 row = ~100 翻转/秒，
            // 视觉上就是六色图持续闪烁 + 卡顿。
            //
            // 修法：只要 image 是给当前 projectId 加载的就显示。revision bump 只触发
            // .task 重跑（atomic 替换 image），body 不主动翻成 placeholder。
            // LazyVStack row reuse（projectId 切换）仍会触发翻 placeholder —— 那是正确行为。
            if let image, loadedKey?.projectId == projectId {
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
        // 只在切换到**不同** projectId 时清旧图 —— revision bump（同 projectId）保留旧图
        // 等新图加载完原子替换，避免闪烁（见 body 注释）。
        if loadedKey?.projectId != key.projectId {
            self.image = nil
            self.loadedKey = nil
        }

        // **关键 jetsam 修复**：列表 row 优先读 displayThumbnail（小图），没有就 ImageDownsampler 现场降级。
        // 永远不直接 UIImage(data: raw_thumbnail) —— raw 是 5-10 MB PNG，解码后 30+ MB × 10 row = jetsam。
        let displayData = inventoryManager.fetchProjectDisplayThumbnail(for: key.projectId)
        if let displayData {
            let decoded = await decode(displayData: displayData)
            guard !Task.isCancelled, currentKey == key else { return }
            self.image = decoded
            self.loadedKey = key
            return
        }

        // 没有 displayThumbnail（老数据，迁移协调器还没跑到 / 跑失败）→ 现场降级原图。
        // ImageDownsampler.downsampleToUIImage 用 CGImageSourceCreateThumbnailAtIndex 在 source 层
        // 就限制尺寸，内存峰值 KB 级 —— 比 UIImage(data: raw_thumbnail) 安全得多。
        let thumbData = inventoryManager.fetchProjectThumbnailData(for: key.projectId)
        let decoded = await downsampleOnTheFly(rawData: thumbData)
        guard !Task.isCancelled, currentKey == key else { return }
        self.image = decoded
        self.loadedKey = key
    }

    private nonisolated func decode(displayData: Data) async -> UIImage? {
        // 50-100 KB 的 JPEG，UIImage(data:) 解码安全
        return UIImage(data: displayData)
    }

    private nonisolated func downsampleOnTheFly(rawData: Data?) async -> UIImage? {
        guard let rawData else { return nil }
        return ImageDownsampler.downsampleToUIImage(rawData)
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
            // 同 ProjectThumbnailImage：只看 projectId 是否匹配，不看 revision —— 否则
            // 迁移协调器 / 编辑等 revision bump 会让所有 finished image 视图闪 placeholder。
            if let image, loadedKey?.projectId == projectId {
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
        // 同 ProjectThumbnailImage：只在 projectId 切换时清旧图。
        if loadedKey?.projectId != key.projectId {
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

// MARK: - 项目成品图缩略（网格用）

/// 异步加载并**降级**项目成品图，专供日历 / 网格等"小尺寸、多格同屏"场景。
///
/// 与 `ProjectFinishedImage` 的关键差异：后者 `UIImage(data: finishedImage)` 全分辨率解码，
/// 单张详情图安全；但**网格里几十格同屏会把内存峰值叠起来**（成品图存盘虽限 ~400px，旧数据 /
/// 备份导入的可能更大）。本组件走 `ImageDownsampler.downsampleToUIImage(_:maxPixelSize:)`，
/// 在 CGImageSource 层就限制输出边长，每格解码 KB 级 —— 这是 blob 网格的 jetsam-safe 入口。
///
/// 防闪烁 / revision 处理与 `ProjectThumbnailImage` 完全一致（见该处注释）。
struct ProjectFinishedThumbnail<Placeholder: View, Content: View>: View {
    let projectId: UUID
    /// 降级后最大边长（px）。默认 160 适配 ~44pt @3x 的日历格。
    var maxPixelSize: Int = 160
    @ViewBuilder let placeholder: () -> Placeholder
    @ViewBuilder let content: (UIImage) -> Content

    @EnvironmentObject private var inventoryManager: InventoryManager
    @State private var image: UIImage?
    @State private var loadedKey: TaskKey?

    var body: some View {
        Group {
            if let image, loadedKey?.projectId == projectId {
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
        // 只在切换到不同 projectId 时清旧图，revision bump 保留旧图等新图原子替换（防闪烁）。
        if loadedKey?.projectId != key.projectId {
            self.image = nil
            self.loadedKey = nil
        }
        let data = inventoryManager.fetchProjectFinishedImageData(for: key.projectId)
        let decoded = await downsample(data: data, maxPixelSize: maxPixelSize)
        guard !Task.isCancelled, currentKey == key else { return }
        self.image = decoded
        self.loadedKey = key
    }

    private nonisolated func downsample(data: Data?, maxPixelSize: Int) async -> UIImage? {
        guard let data else { return nil }
        return ImageDownsampler.downsampleToUIImage(data, maxPixelSize: maxPixelSize)
    }

    private struct TaskKey: Hashable {
        let projectId: UUID
        let revision: Int
    }
}
