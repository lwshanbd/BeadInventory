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

    /// 同 `patternGrid(for:)`，但把「没做过」和「读不出来」分开。
    ///
    /// 单图纸流程要拿它决定**能不能覆写**：网格里存着用户一个色号一个色号核对过的
    /// 几千格结果，跟多零件那份是同一量级的活。只拿到 nil 的话，流程会把用户当成
    /// 新用户扔回第一屏，而他往下走一步就用新结果把那份只是暂时打不开的字节永久盖掉。
    /// 理由和三态本身都同 `partsSheet(for:)`。
    func patternGridLoad(for projectId: UUID) -> PatternGridLoad {
        switch fetchColumnResult(projectId: projectId, keyPath: \.patternGridData, event: "pattern_grid") {
        case .failure:
            return .unreadable
        case .success(.none):
            return .missing
        case .success(.some(let data)):
            guard let grid = SDProjectRecord.decodePatternGrid(data, projectId: projectId) else {
                return .unreadable
            }
            return .loaded(grid)
        }
    }

    /// 多零件模式的图纸数据（零件框 / 调色板 / 格子标定）。同样是小字节，走后台的理由
    /// 也一样 —— 它总是跟 `thumbnail` 一起被取。
    ///
    /// 返回三态而不是 `BeadPartsSheet?`：**「没做过」和「读不出来」不能是同一个答案。**
    /// 调用方拿到 nil 就会把用户当成新用户扔回第一屏，而他一往下走就会用空白数据
    /// 把那份只是暂时打不开的字节永久盖掉 —— 五十几个零件、几万格色号一次没了。
    func partsSheet(for projectId: UUID) -> PartsSheetLoad {
        switch fetchColumnResult(projectId: projectId, keyPath: \.partsSheetData, event: "parts_sheet") {
        case .failure:
            return .unreadable
        case .success(.none):
            return .missing
        case .success(.some(let data)):
            guard let sheet = SDProjectRecord.decodePartsSheet(data, projectId: projectId) else {
                return .unreadable
            }
            return .loaded(sheet)
        }
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

    // MARK: - 备份用:单次 fetch 取回一个项目的全部 blob

    /// 一个项目的全部 blob。
    struct ProjectBlobs: Sendable {
        let thumbnail: Data?
        let finishedImage: Data?
        let displayThumbnail: Data?
        let patternGridData: Data?
        /// 多零件图纸。**必须跟其它 blob 同批取** —— 它不在这份快照里的话，
        /// 归档就会声称"这个项目没有零件数据"，恢复端照办把用户的多零件进度清掉。
        let partsSheetData: Data?
    }

    enum LoadError: Error, CustomStringConvertible {
        case fetchFailed(projectId: UUID, underlying: String)
        /// 行在 metadata 快照之后消失了(通常是用户删了这个项目)。
        /// **可重试失败** —— 下次备份基于新的快照就一致了。
        case projectRowMissing(projectId: UUID)

        var description: String {
            switch self {
            case .fetchFailed(let id, let e): return "读取项目 \(id) 的图片失败: \(e)"
            case .projectRowMissing(let id): return "项目 \(id) 在备份过程中消失（可能已被删除）"
            }
        }
    }

    /// 取回一个项目的全部 blob —— **单次 fetch,同一事务视图**。
    ///
    /// ## 为什么必须是单次 fetch(而不是调四遍上面的单列方法)
    ///
    /// 备份的一致性语义是「逐记录一致」(产品裁决)。分四次取,同一个项目的四张图会来自
    /// 四个不同时刻 —— 用户在备份期间改了图,归档里就可能是"新缩略图 + 旧成品图"这种
    /// 自身矛盾的记录。单次 fetch 才让"逐记录一致"名副其实。
    ///
    /// 内存代价是**一个项目的全部 blob 同时在内存**(约两张图量级),仍然与项目总数无关 ——
    /// 这跟"全表物化"是两回事。
    ///
    /// ## 为什么 throw 而不是返回 nil
    ///
    /// 上面那组单列方法把「真的没图」和「fetch 抛错」**都返回 nil**(错误只进了日志)。
    /// 对视图层那是合理的降级;但对备份是致命的 ——
    ///
    ///     一次瞬时读取失败 → 备份记成"这条没图" → 恢复时按"完整快照"语义显式清空
    ///       → 图被永久删除
    ///
    /// 也就是说"读失败"会被转写成"用户删了图"。备份路径必须能区分这两者,所以这里
    /// 用 throw 把失败暴露出去,由调用方决定终止整次备份。
    func blobs(for projectId: UUID) throws -> ProjectBlobs {
        var descriptor = FetchDescriptor<SDProjectRecord>(
            predicate: #Predicate { $0.id == projectId }
        )
        descriptor.fetchLimit = 1
        descriptor.propertiesToFetch = [
            \.thumbnail, \.finishedImage, \.displayThumbnail, \.patternGridData, \.partsSheetData
        ]
        do {
            let context = ModelContext(container)
            guard let row = try context.fetch(descriptor).first else {
                // **行消失必须抛错,不能返回全 nil。**
                //
                // metadata 快照是在这之前取的,所以"快照里有、现在没有"意味着用户在备份
                // 期间删掉了这个项目。若在这里返回全 nil,归档里就会写成
                // **「项目还在、四张图都没有」** —— 而恢复端按"字段缺失即显式清空"处理,
                // 于是恢复会**复活一个已删除的项目、并且它的图全丢**。
                // 那是一份内部自相矛盾的备份,比备份失败糟得多。
                //
                // 也刻意**不**在这里"跳过该项目":`first == nil` 只说明没查到行,
                // 不能断定原因就是"用户删了"。把"查不到"直接翻译成"已删除"正是
                // 本方法存在要修的那类歧义(见下方 throw 的理由)。
                // 抛出可重试失败,让本次备份保留为 `.partial`,下次基于新快照重来即可。
                throw LoadError.projectRowMissing(projectId: projectId)
            }
            return ProjectBlobs(
                thumbnail: row.thumbnail,
                finishedImage: row.finishedImage,
                displayThumbnail: row.displayThumbnail,
                patternGridData: row.patternGridData,
                partsSheetData: row.partsSheetData
            )
        } catch {
            AppLogger.shared.error("ProjectImageLoader", "blobs_fetch_failed", metadata: [
                "projectId": projectId.uuidString, "error": "\(error)"
            ])
            throw LoadError.fetchFailed(projectId: projectId, underlying: "\(error)")
        }
    }

    // MARK: - 测试探针

    /// 供 `ProjectImageLoaderTests` 钉住「取图不在主线程」这条不变量。
    /// 一旦有人把本类改回 `@MainActor`（或把 fetch 挪回 `InventoryManager`），测试会红。
    func isCurrentlyOnMainThreadForTesting() -> Bool { Thread.isMainThread }

    /// 观测到的最大并发数。
    ///
    /// 窗口盖的是**两条降级方法**（`downsampledRawThumbnail` / `downsampledFinishedImage`），
    /// 不是全部六个公开方法 —— 纯 fetch 方法是同步 actor 方法，隔离下并发数结构上
    /// 不可能大于 1，包了也是自证命题；真正有内存代价、也真正可能被未来某次
    /// 「加个 await」破坏的，是「读原图 + 降级」这两段。
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
        switch fetchColumnResult(projectId: projectId, keyPath: keyPath, event: event) {
        case .success(let data): return data
        case .failure: return nil
        }
    }

    /// 同上，但把「fetch 抛错」留给调用方。取图那几条把抛错和无图一起压成 nil 是对的
    /// （晚一点出图而已），要写回原地的那几条不行 —— 见 `partsSheet(for:)`。
    private func fetchColumnResult(
        projectId: UUID,
        keyPath: KeyPath<SDProjectRecord, Data?>,
        event: String
    ) -> Result<Data?, Error> {
        var descriptor = FetchDescriptor<SDProjectRecord>(
            predicate: #Predicate { $0.id == projectId }
        )
        descriptor.fetchLimit = 1
        descriptor.propertiesToFetch = [keyPath]
        do {
            let context = ModelContext(container)
            return .success(try context.fetch(descriptor).first?[keyPath: keyPath])
        } catch {
            // 把「SwiftData 抛错」和「真的没图」分开记 —— 否则 store 损坏看起来就像无图。
            AppLogger.shared.error("ProjectImageLoader", "fetch_failed", metadata: [
                "column": event,
                "projectId": projectId.uuidString,
                "error": "\(error)"
            ])
            return .failure(error)
        }
    }
}

/// 读一份多零件图纸的结果。
///
/// `unreadable` 覆盖两种情况：fetch 抛错（store 忙 / 损坏）和 JSON 解不开。
/// 两种都**有字节在库里**，只是这次没拿到 —— 调用方必须把它跟「库里就没有」分开对待，
/// 否则会拿空白覆盖掉用户真实存在的进度。
enum PartsSheetLoad: Sendable {
    /// 库里就没有这份数据 —— 用户确实还没做过。
    /// 刻意不叫 `none`：调用方多半写成 `?? .none`，那里跟 `Optional.none` 是分不清的。
    case missing
    case loaded(BeadPartsSheet)
    /// 有字节但这次取不出来 / 解不开。**不能当成「没有」**，覆写要停下来问用户。
    case unreadable
}

/// 读一份单图纸网格的结果。三态的理由完全同 `PartsSheetLoad` ——
/// 网格里同样存着用户逐格核对过的成果，「读不出来」当成「没做过」一样会把它盖掉。
enum PatternGridLoad: Sendable {
    case missing
    case loaded(BeadPatternGrid)
    case unreadable
}
