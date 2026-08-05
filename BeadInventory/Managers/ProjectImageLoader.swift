//
//  ProjectImageLoader.swift
//  BeadInventory
//
//  列表 / 日历 / 详情页取图的**后台**入口。
//
//  ## 它修的是哪一条崩溃栈
//
//  用户那份 1.8.0 的 `.ips`，主线程栈是：
//
//      UIApplication _firstCommitBlock
//        → CA::Transaction::commit
//          → _UIHostingView.layoutSubviews
//            → SwiftUI ViewGraphRootValueUpdater.render
//              → Update.dispatchActions
//                → （我们的代码）
//                  → NSManagedObjectContext.performAndWait
//                    → sqlite3_step
//                      → _platform_memmove        ← 正在拷那 13 MB blob
//
//  来源就是 `ProjectImageViews`：`InventoryManager` 是 `@MainActor`，
//  `fetchProjectDisplayThumbnail` / `fetchProjectThumbnailData` 都是**主线程同步
//  SwiftData fetch**。首屏一次渲染 10 个 row，每个 row 至少一次主线程读库；
//  老数据（`displayThumbnail == nil`）还会掉进第二条 fallback，
//  在主线程上把 13 MB 原图整个读出来。
//
//  再叠加库涨到 GB 级之后 CoreData+CloudKit 的
//  `_performPostSaveTasks:andForceFullVacuum:` 持 EXCLUSIVE 锁 —— 这些读全部排队，
//  首帧提交被拖过 scene-create 看门狗的 2.06s → `0x8BADF00D`。
//
//  ## 为什么是 actor
//
//  两个作用，缺一不可：
//
//  1. **脱离主线程**：所有 fetch 跑在独立的后台 `ModelContext` 上，主线程只等结果。
//     库再忙也只是图晚一点出来，不会挡住首帧提交。
//  2. **串行化**：actor 隔离天然保证同一时刻只有一次取图在飞。这对
//     `downsampledRawThumbnail` 尤其关键 —— 老数据还没瘦身完时，10 个 row 并发各读
//     一份 13 MB 原图就是 130 MB 瞬时峰值，正是 jetsam 的老路。串行之后峰值恒定为一份。
//
//  `ModelContext` 不是 Sendable，所以这里持有的是 `ModelContainer`（Sendable），
//  每次调用现开一个 context —— 与 `ThumbnailMigrationCoordinator` 里的后台写入同型。

import Foundation
import SwiftData
import UIKit

actor ProjectImageLoader {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    /// 列表 row 用的小图（512px JPEG，~50-100 KB）。
    func displayThumbnail(for projectId: UUID) -> Data? {
        fetchColumn(projectId: projectId, keyPath: \.displayThumbnail, event: "display_thumbnail")
    }

    /// 成品图原字节。调用方自己决定怎么解码。
    func finishedImage(for projectId: UUID) -> Data? {
        fetchColumn(projectId: projectId, keyPath: \.finishedImage, event: "finished_image")
    }

    /// 图纸原字节（拼图模式 / 详情大图）。
    func thumbnail(for projectId: UUID) -> Data? {
        fetchColumn(projectId: projectId, keyPath: \.thumbnail, event: "thumbnail")
    }

    /// 拼图模式网格（四角 / 行列 / 色号矩阵）。字节很小，但仍然走后台 —— 它总是跟
    /// `thumbnail` 一起被取，留在主线程就白白抵消了另一半的改动。
    func patternGrid(for projectId: UUID) -> BeadPatternGrid? {
        guard let data = fetchColumn(projectId: projectId, keyPath: \.patternGridData, event: "pattern_grid") else {
            return nil
        }
        return SDProjectRecord.decodePatternGrid(data, projectId: projectId)
    }

    /// 老数据没有 `displayThumbnail` 时的兜底：读原图 → 现场降级成小图。
    ///
    /// **只走 `ImageDownsampler`，永远不 `UIImage(data: raw)`** —— 后者会全分辨率解码
    /// （13 MB PNG → 30-60 MB UIImage）。`CGImageSourceCreateThumbnailAtIndex` 在 source 层
    /// 就限制尺寸，峰值 KB 级。
    ///
    /// 返回 UIImage 而不是 Data：省掉一次 JPEG encode/decode 往返，也让「原图字节」
    /// 不会流出这个 actor（调用方拿不到就不可能不小心把它存起来）。
    func downsampledRawThumbnail(for projectId: UUID) -> UIImage? {
        enter()
        defer { leave() }
        guard let raw = fetchColumn(projectId: projectId, keyPath: \.thumbnail, event: "raw_thumbnail_fallback") else {
            return nil
        }
        return ImageDownsampler.downsampleToUIImage(raw)
    }

    /// 日历格子用的成品图小图：读原字节 → 现场降级到 `maxPixelSize`。
    ///
    /// 降级放在 actor 内部而不是让调用方拿着 `Data` 自己做，是为了让**原字节不流出**这个
    /// actor —— 调用方拿不到就不可能不小心把它存进 `@State` 常驻内存。
    ///
    /// - Returns: `bytesFound` 区分「库里就没有这张图」和「有字节但解不开」。
    ///   日历只为 `projectIDsWithFinishedImage` 里的项目渲染图片分支，
    ///   所以 `bytesFound == false` 说明集合与库漂移了（删除/合并/恢复竞态留下的陈旧成员），
    ///   调用方要留日志，别静默成空格子。
    func downsampledFinishedImage(
        for projectId: UUID,
        maxPixelSize: Int
    ) -> (bytesFound: Bool, image: UIImage?) {
        enter()
        defer { leave() }
        guard let data = fetchColumn(projectId: projectId, keyPath: \.finishedImage, event: "finished_image_thumbnail") else {
            return (false, nil)
        }
        let image = ImageDownsampler.downsampleToUIImage(data, maxPixelSize: max(1, maxPixelSize))
        if image == nil {
            // 有字节但解不开 = 真正的损坏信号，而调用方只对 bytesFound == false 记日志，
            // 于是这一格会渲染成空白且零遥测。补一条。
            AppLogger.shared.error("ProjectImageLoader", "finished_image_undecodable", metadata: [
                "projectId": projectId.uuidString, "bytes": data.count
            ])
        }
        return (true, image)
    }

    // MARK: - 测试探针

    /// 供 `ProjectImageLoaderTests` 钉住「取图不在主线程」这条不变量。
    /// 一旦有人把本类改回 `@MainActor`（或把 fetch 挪回 `InventoryManager`），测试会红。
    func isCurrentlyOnMainThreadForTesting() -> Bool { Thread.isMainThread }

    /// 观测到的最大并发数。
    ///
    /// 窗口刻意盖住**整个公开方法**（含 `ImageDownsampler` 那半），而不只是 fetch：
    /// 原来只包 `fetchColumn`，而 fetch 是同步的 actor 方法，actor 隔离下并发数
    /// 结构上不可能大于 1 —— 断言恒真，是个自证命题。真正有内存代价、也真正可能
    /// 被未来某次「加个 await」破坏的是「读原图 + 降级」这一整段。
    private(set) var peakConcurrencyForTesting = 0
    private var inFlight = 0

    private func enter() {
        inFlight += 1
        if inFlight > peakConcurrencyForTesting { peakConcurrencyForTesting = inFlight }
    }
    private func leave() { inFlight -= 1 }

    // MARK: - 内部

    /// 单列投影 fetch。
    ///
    /// `propertiesToFetch` 限定单列是必须的：不限定的话，同行的其它 blob
    /// （raw thumbnail 可能是 MB 级）会跟着一起物化 —— 列表每滚一个 row 都要付这份代价。
    ///
    /// 早期写法是 `switch keyPath { ... default: break }`，而 `propertiesToFetch` 的默认值
    /// 是 `[]` = **不投影** = SELECT 全列。也就是说将来加一个 blob 列 + 一个忘记加 case 的
    /// 取值方法，就会静默物化整行 —— 正是本文件存在要防的那个回归，且无编译错误、
    /// 无测试失败、无日志。现在直接把 keyPath 传给 `propertiesToFetch`
    ///（它要的是 `[PartialKeyPath<T>]`，`KeyPath<_, Data?>` 可以直接上转），
    /// 少一个 switch 也就少一处可以漏的地方。
    private func fetchColumn(
        projectId: UUID,
        keyPath: KeyPath<SDProjectRecord, Data?>,
        event: String
    ) -> Data? {
        var descriptor = FetchDescriptor<SDProjectRecord>(
            predicate: #Predicate { $0.id == projectId }
        )
        descriptor.fetchLimit = 1
        descriptor.propertiesToFetch = [keyPath]
        do {
            let context = ModelContext(container)
            return try context.fetch(descriptor).first?[keyPath: keyPath]
        } catch {
            // 把「SwiftData 抛错」和「真的没图」分开记 —— 否则 store 损坏看起来就像无图。
            AppLogger.shared.error("ProjectImageLoader", "fetch_failed", metadata: [
                "column": event,
                "projectId": projectId.uuidString,
                "error": "\(error)"
            ])
            return nil
        }
    }
}
