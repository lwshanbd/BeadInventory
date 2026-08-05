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

        // **取图一律走 ProjectImageLoader（后台 actor）**，不再调 InventoryManager 的
        // `fetchProject*Data` —— 那些是 @MainActor 同步 SwiftData fetch，首屏 10 个 row
        // 就是 10 次主线程读库，正是用户 `.ips` 里那条
        // `CA::Transaction::commit → … → sqlite3_step → _platform_memmove` 主线程栈。
        guard let loader = inventoryManager.imageLoader else { return }

        // 优先读 displayThumbnail（512px JPEG，~50-100 KB）
        if let displayData = await loader.displayThumbnail(for: key.projectId) {
            let decoded = await decode(displayData: displayData)
            guard !Task.isCancelled, currentKey == key else { return }
            self.image = decoded
            self.loadedKey = key
            return
        }

        // 没有 displayThumbnail（老数据，瘦身 pass 还没跑到）→ 现场降级原图。
        // 读原图 + 降级都在 loader 这个 actor 内部完成：
        //   - 不在主线程（不会再挡首帧提交）
        //   - actor 隔离天然串行，同一时刻只有一份原图在内存里
        //     （否则 10 个 row 并发各读一份 13 MB 就是 130 MB 瞬时峰值 = jetsam 老路）
        //   - 走 ImageDownsampler 而不是 UIImage(data: raw)，峰值 KB 级
        let decoded = await loader.downsampledRawThumbnail(for: key.projectId)
        guard !Task.isCancelled, currentKey == key else { return }
        self.image = decoded
        self.loadedKey = key
    }

    private nonisolated func decode(displayData: Data) async -> UIImage? {
        // 50-100 KB 的 JPEG，UIImage(data:) 解码安全
        return UIImage(data: displayData)
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
        // 同 ProjectThumbnailImage：走后台 actor，不在主线程读库。
        guard let loader = inventoryManager.imageLoader else { return }
        let data = await loader.finishedImage(for: key.projectId)
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

/// 极简异步信号量：把"取原图 blob + 降级"同时在飞的数量限制到 `limit` 个。
///
/// **非取消感知**：`wait()`/`signal()` 必须成对。调用方约定 —— `wait()` 之后到 `signal()`
/// 之间无 throw、无早退（取消也照常走到 `signal()`），故不会漏还配额、也不会过度 `signal`。
private actor ImageLoadGate {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { available = limit }

    func wait() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }   // 被 signal() 唤醒时即继承一个配额
    }

    func signal() {
        if waiters.isEmpty { available += 1 }
        else { waiters.removeFirst().resume() }                // 把配额直接转交给下一个等待者
    }
}

/// 全局闸门：限制成品图网格"取原图 + 降级"的并发度。
///
/// 成品图当前是整张原分辨率 PNG 落盘，一张手机照片可达数 MB；整月若有十几二十张作品，
/// `ProjectFinishedThumbnail` 的 `.task` 会几乎同时点火，原图 Data 在 fetch→downsample
/// 窗口内全都进内存就会叠成尖峰。限到 4 路在飞，峰值内存只压住 ~4 张原图。
private let finishedThumbnailLoadGate = ImageLoadGate(limit: 4)

/// 异步加载并**降级**项目成品图，专供日历 / 网格等"小尺寸、多格同屏"场景。
///
/// 与 `ProjectFinishedImage` 的关键差异：后者 `UIImage(data: finishedImage)` 全分辨率解码，
/// 单张详情图安全；但**网格里几十格同屏会把内存峰值叠起来**。注意成品图当前是**整张原分辨率
/// PNG 落盘**（`ProjectImageEditorSheet.generateImageData` 直接 `pngData()`，`maxImageSize`
/// 已失效），一张手机照片可达数 MB，所以网格降级是**必须的、不是可选优化**。本组件走
/// `ImageDownsampler.downsampleToUIImage(_:maxPixelSize:)`，在 CGImageSource 层就限制输出边长，
/// 每格解码 KB 级 —— 这是 blob 网格的 jetsam-safe 入口。原始 Data 仍会短暂进内存，故再叠一层
/// `finishedThumbnailLoadGate` 限制并发取图数。
///
/// 防闪烁 / revision 处理与 `ProjectThumbnailImage` 完全一致（完整推导见该处注释，三处需同步改）。
struct ProjectFinishedThumbnail<Placeholder: View, Content: View>: View {
    let projectId: UUID
    /// 降级后最大边长（px）。日历格约 44–52pt，3x 下约 130–160px；默认取上界 160 留点清晰度
    /// 余量（`scaledToFill` 按较长边吃分辨率）。
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
        TaskKey(projectId: projectId, revision: inventoryManager.projectBlobsRevision, maxPixelSize: maxPixelSize)
    }

    private func loadImage(for key: TaskKey) async {
        // 只在切换到不同 projectId 时清旧图，revision bump 保留旧图等新图原子替换（防闪烁）。
        if loadedKey?.projectId != key.projectId {
            self.image = nil
            self.loadedKey = nil
        }

        guard let loader = inventoryManager.imageLoader else { return }

        // 取图 + 降级在配额闸门内进行：withGatePermit 保证无论正常返回还是取消早退都归还配额。
        // 取图本身走后台 actor（不在主线程读库），闸门仍然保留 —— 它管的是「翻月时一次别
        // 排太多任务」，跟 actor 的串行化是两件事。
        let decoded = await withGatePermit {
            // 等待配额期间被取消（如翻月）就别再取图，提前退出（配额由 withGatePermit 归还）。
            if Task.isCancelled { return nil }
            let result = await loader.downsampledFinishedImage(
                for: key.projectId, maxPixelSize: maxPixelSize
            )
            if !result.bytesFound {
                // 日历只为 projectIDsWithFinishedImage 里的项目渲染图片分支，这里没字节 = set/DB 漂移
                // （删除/合并/恢复竞态留下的陈旧成员）。别静默成空格子，留一条日志好排查
                // —— 对齐 InventoryManager 里 snapshot_capture_gap 的可观测约定。
                AppLogger.shared.error("ProjectFinishedThumbnail", "finished_image_expected_but_nil", metadata: [
                    "projectId": key.projectId.uuidString
                ])
            }
            return result.image
        }

        guard !Task.isCancelled, currentKey == key else { return }
        self.image = decoded
        self.loadedKey = key
    }

    /// 持有一个 `finishedThumbnailLoadGate` 配额跑 `body`，结束（正常返回 / 取消早退）一定
    /// 归还配额 —— 把"`wait`/`signal` 之间不能漏 `signal`"从口头约定收进这一个地方，配平结构化。
    ///
    /// `body` 故意是**非抛出**的：闸门内若以后要做会抛错的活，编译器会在这里逼你先改签名
    /// （顺手补 do/catch 归还配额），从而杜绝"中间加了个 throw 就静默漏配额 → 整网格卡死"。
    private func withGatePermit(_ body: () async -> UIImage?) async -> UIImage? {
        await finishedThumbnailLoadGate.wait()
        let result = await body()
        await finishedThumbnailLoadGate.signal()
        return result
    }

    private nonisolated func downsample(data: Data?, maxPixelSize: Int) async -> UIImage? {
        guard let data else { return nil }
        return ImageDownsampler.downsampleToUIImage(data, maxPixelSize: maxPixelSize)
    }

    private struct TaskKey: Hashable {
        let projectId: UUID
        let revision: Int
        let maxPixelSize: Int
    }
}
