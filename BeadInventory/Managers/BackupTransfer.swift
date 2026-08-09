//
//  BackupTransfer.swift
//  BeadInventory
//
//  备份的**运输层**:把归档送出 App、以及把外部归档安全地接进来。
//
//  ## 它解决的是什么
//
//  归档已经能写、能校验、能恢复,但用户**拿不出来**。上一个用户丢图的完整链条是:
//
//      App 崩溃 → 只能卸载重装 → Documents 随 App 一起被删
//        → 8 份含全部图片的备份陪葬 → 用户只剩自己导出的 CSV → CSV 载不动图
//
//  **备份一直在,他够不着。** 所以本文件的唯一验收标准是:
//  用户能趁 App 还能开把完整备份弄到 App 之外,重装后能弄回来、图片完整。
//
//  ## 为什么是 package 而不是 ZIP
//
//  `.beadbackup` 声明为 `com.apple.package` + `public.content`(见 Info.plist),
//  Files / iCloud Drive / AirDrop 会把这个目录当成**单个条目**呈现 —— 观感上就是一个文件。
//
//  不打 ZIP 的理由不是省事,是**安全**:目录格式天然没有"解压"这一步,
//  于是压缩炸弹与解压路径穿越这两类问题根本不存在。改成 ZIP 等于把它们请回来,
//  还要另写一套解压期的条目数/总量/路径校验。
//  运输层独立的好处在于:将来真需要跨平台,再加一个"导出为 ZIP"的选项即可,核心格式不动。
//
//  ## 运输层不依赖数据层
//
//  导出只需要目录 URL,**不碰 `InventoryManager`、不开 store**。这是刻意的:
//  将来的"无写入救援界面"(容器打不开的用户)也要能把既有归档分享出去 ——
//  那正是最需要导出的人群,不能把导出绑死在"数据层能正常工作"上。

import Foundation
import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable

extension UTType {
    /// 与 Info.plist 的 `UTExportedTypeDeclarations` 一一对应。
    static let beadInventoryBackup = UTType(exportedAs: "com.beadinventory.backup-archive")
}

// MARK: - 导出

/// 可分享的归档。
///
/// 用 `Transferable` + `FileRepresentation` 而不是裸 `ShareLink(item: URL)`:
///   - 明确声明传输的内容类型就是这个 package,接收方不用猜;
///   - `shouldAllowToOpenInPlace: false` —— 接收方拿到的是**副本**。
///     绝不能让外部应用就地打开我们 Documents 里的归档:那是用户最后的救命副本,
///     被别处就地改写或移动就没了。
struct BackupExport: Transferable {
    let archiveURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(
            exportedContentType: .beadInventoryBackup,
            shouldAllowToOpenInPlace: false
        ) { export in
            SentTransferredFile(export.archiveURL)
        }
    }
}

// MARK: - 导入:按清单、带上限的流式 staging

/// 把外部 package 安全地搬进 App 私有目录。
///
/// ## 为什么不能直接 `copyItem` 整个目录
///
/// 外部 package 是**不可信输入**,而它的 manifest 更不可信:
///
///   - manifest 声明的总量可以撒谎;
///   - 目录里可以塞**manifest 完全没引用**的文件 —— 比如一个 200 GB 的垃圾文件,
///     或几十万个小文件。**现有校验器看不见它们**:`validate()` 只遍历 manifest 引用的
///     blob,从不列举目录实际内容。
///
/// 所以"先整体复制、再校验"本身就是资源耗尽入口 —— 复制这一步就把盘撑满了。
///
/// ## 正确顺序
///
///     读 manifest(带大小上限,受 security scope 保护)
///       → 只用它生成**复制计划**(不信任任何结论)
///       → 轻量预检(条目数、按**源文件实际大小**估算的总量、磁盘余量)
///       → 用户确认            ← 必须在这里，不是 422 MB 复制完之后
///       → 逐项复制到 stage.partial，边复制边查上限
///       → 完整 validate(staging)
///       → apply(staging)
///
/// **只复制清单里列出的东西**,未被引用的文件一概不进来 —— 这同时也消掉了
/// "校验器看不见额外文件"这个盲区。
enum BackupImportStaging {

    /// 全部资源上限。
    ///
    /// 封成值类型而不是散落的 `static let` + 可选参数:测试需要用很小的上限才能真的触发
    /// 各条防线(默认 64 GB,不注入的话"复制途中变大"这类用例在单测里根本触发不到),
    /// 但**不能因此让它变成运行时可配置** —— 生产只有 `.production` 一个取值。
    struct Limits {
        var totalBytes: Int64
        var blobBytes: Int64
        var projects: Int
        var blobCount: Int
        /// manifest 里其它集合的条目数上限。32 MB 的 manifest 解码后可以膨胀成巨量
        /// 小对象 —— 只限制 projects 挡不住这条。
        var collectionEntries: Int
        /// 流式复制的块大小。**复制是按块检查上限的**,不是复制完再看。
        var copyBlockBytes: Int
        /// 磁盘余量安全系数:staging 一份 + 恢复写入一份 + 余量。
        /// 只按"staging 一份"预检会在恢复阶段把盘撑满,而那时 metadata 已经替换过了。
        var diskHeadroomMultiplier: Double

        static let production = Limits(
            totalBytes: 64 * 1024 * 1024 * 1024,
            blobBytes: Int64(BackupArchiveReader.maxBlobBytes),
            projects: BackupArchiveReader.maxProjects,
            blobCount: BackupArchiveReader.maxBlobCount,
            collectionEntries: 500_000,
            copyBlockBytes: 1024 * 1024,
            diskHeadroomMultiplier: 2.5
        )
    }

    struct Plan {
        let manifest: BackupArchiveManifest
        /// 预检时读到的 manifest **原始字节**(已过大小上限)。
        ///
        /// staging 直接写这份,而不是确认后再从源读一遍 —— 否则用户点完"导入并替换"
        /// 到我们开始复制之间,源上的 manifest 可以被换成另一份,
        /// 于是"用户看到的项目数/体积"与"实际导入的东西"不是一回事。
        let manifestData: Data
        /// 相对路径 → 源 URL。**只含 manifest 引用的 blob**(manifest 本身走 `manifestData`)。
        let entries: [(relativePath: String, source: URL, bytes: Int64)]
        let totalBytes: Int64
    }

    enum StagingError: Error, CustomStringConvertible {
        case manifestMissing
        case manifestTooLarge(bytes: Int64)
        case manifestUndecodable(String)
        case unsupportedFormatVersion(Int)
        case unsafePath(String)
        case symlinkRejected(String)
        case notRegularFile(String)
        case entryMissing(String)
        case entryTooLarge(String, bytes: Int64)
        case totalTooLarge(bytes: Int64)
        case tooManyEntries(kindLabel: String, count: Int)
        case insufficientDisk(needed: Int64, available: Int64)
        case securityScopeDenied
        case copyFailed(String)

        var kind: String {
            switch self {
            case .manifestMissing: return "manifestMissing"
            case .manifestTooLarge: return "manifestTooLarge"
            case .manifestUndecodable: return "manifestUndecodable"
            case .unsupportedFormatVersion: return "unsupportedFormatVersion"
            case .unsafePath: return "unsafePath"
            case .symlinkRejected: return "symlinkRejected"
            case .notRegularFile: return "notRegularFile"
            case .entryMissing: return "entryMissing"
            case .entryTooLarge: return "entryTooLarge"
            case .totalTooLarge: return "totalTooLarge"
            case .tooManyEntries: return "tooManyEntries"
            case .insufficientDisk: return "insufficientDisk"
            case .securityScopeDenied: return "securityScopeDenied"
            case .copyFailed: return "copyFailed"
            }
        }

        var description: String {
            switch self {
            case .manifestMissing: return "所选文件不是有效的备份（缺少 manifest）"
            case .manifestTooLarge(let b): return "备份清单过大：\(b) 字节"
            case .manifestUndecodable(let e): return "备份清单无法解析：\(e)"
            case .unsupportedFormatVersion(let v): return "备份格式版本 \(v) 无法读取"
            case .unsafePath(let p): return "备份包含不安全的路径：\(p)"
            case .symlinkRejected(let p): return "备份包含符号链接，已拒绝：\(p)"
            case .notRegularFile(let p): return "备份条目不是普通文件：\(p)"
            case .entryMissing(let p): return "备份缺少文件：\(p)"
            case .entryTooLarge(let p, let b): return "备份条目过大：\(p)（\(b) 字节）"
            case .totalTooLarge(let b): return "备份总量超限：\(b) 字节"
            case .tooManyEntries(let k, let c): return "备份 \(k) 条目数超限：\(c)"
            case .insufficientDisk(let n, let a): return "存储空间不足：需要约 \(n / 1024 / 1024) MB，可用 \(a / 1024 / 1024) MB"
            case .securityScopeDenied: return "无法访问所选文件"
            case .copyFailed(let e): return "复制失败：\(e)"
            }
        }
    }

    // MARK: - 阶段一:轻量预检,生成复制计划

    /// **不复制任何东西**,只读 manifest 并核对每个被引用条目的存在性与大小。
    ///
    /// 调用方必须已持有 `source` 的 security scope。
    /// - Parameter totalLimit: 总量上限。**仅为测试可注入**;生产一律用默认值。
    ///   不做成可注入的话,"复制途中源文件变大"这类用例在单测里根本触发不到
    ///   (默认 64 GB),那条防线就只能靠读代码相信它有效。
    static func makePlan(source: URL, limits: Limits = .production) throws -> Plan {
        let fm = FileManager.default
        let manifestURL = source.appendingPathComponent("manifest.json")
        guard fm.fileExists(atPath: manifestURL.path) else { throw StagingError.manifestMissing }

        // **manifest 也必须先验形态。** 之前只验 blob，manifest 却可以是一条指向外部
        // 目标的符号链接 —— 我们会跟着它读到归档外的文件，与"复制前拒绝 symlink"
        // 这个安全承诺自相矛盾。它还是**第一个**被读的东西，漏在这里等于前门没锁。
        try requireRegularFile(at: manifestURL, label: "manifest.json")

        let manifestSize = ((try? fm.attributesOfItem(atPath: manifestURL.path))?[.size] as? NSNumber)?.int64Value ?? -1
        guard manifestSize <= BackupArchiveReader.maxManifestBytes else {
            throw StagingError.manifestTooLarge(bytes: manifestSize)
        }

        // 读到的原始字节要留着 —— staging 直接写它，见 Plan.manifestData 的说明。
        let manifestData: Data
        let manifest: BackupArchiveManifest
        do {
            manifestData = try Data(contentsOf: manifestURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            manifest = try decoder.decode(BackupArchiveManifest.self, from: manifestData)
        } catch {
            throw StagingError.manifestUndecodable("\(error)")
        }
        guard manifest.formatVersion == BackupArchiveWriter.currentFormatVersion else {
            throw StagingError.unsupportedFormatVersion(manifest.formatVersion)
        }

        // **条目数预检必须在这里，不能等到 staging 之后的 validate()。**
        //
        // 否则一份恶意 manifest 可以先让用户确认、再让我们复制几十万个小文件，
        // 最后才在校验阶段被拒 —— 代价已经全部付掉了。
        guard manifest.projects.count <= limits.projects else {
            throw StagingError.tooManyEntries(kindLabel: "projects", count: manifest.projects.count)
        }
        // 只限制 projects 挡不住"32 MB manifest 解码成巨量小对象"：其它集合同样要限，
        // 嵌套的 beadUsage / items 也要算进去。
        var collectionCount = manifest.brands.count + manifest.brandStocks.count
            + manifest.customColors.count + manifest.purchaseRecords.count
        for r in manifest.purchaseRecords { collectionCount += r.items.count }
        for p in manifest.projects { collectionCount += p.beadUsage.count }
        guard collectionCount <= limits.collectionEntries else {
            throw StagingError.tooManyEntries(kindLabel: "collections", count: collectionCount)
        }

        var entries: [(String, URL, Int64)] = []
        var total: Int64 = manifestSize
        // 总量检查必须在进 blob 循环**之前**先做一次：只含 manifest 的归档
        // （blob 数为 0）根本进不了循环，那条上限就永远不会被执行 ——
        // 生产默认值下触发不到，但 Limits 的契约不该有这种缺口。
        guard total <= limits.totalBytes else { throw StagingError.totalTooLarge(bytes: total) }
        var blobCount = 0

        for project in manifest.projects {
            for ref in [project.thumbnail, project.finishedImage,
                        project.displayThumbnail, project.patternGrid].compactMap({ $0 }) {
                blobCount += 1
                guard blobCount <= limits.blobCount else {
                    throw StagingError.tooManyEntries(kindLabel: "blobs", count: blobCount)
                }

                // **路径形状必须精确匹配 `blobs/<单段文件名>`。**
                //
                // 复用 safeBlobURL 的越界检查还不够 —— 它只保证"不跑出归档根"，
                // 但 `blobs/a/b/c/.../x` 这种深层嵌套仍然合法。写出器只会产生
                // `blobs/<uuid>.<kind>` 一种形状，任何别的形状都说明这不是我们写的东西。
                //
                // 收紧的实际收益：materialize 只需 `blobs/` 一层目录，不必按外部输入
                // 递归创建目录树。
                let components = ref.file.split(separator: "/", omittingEmptySubsequences: false)
                guard components.count == 2, components[0] == "blobs",
                      !components[1].isEmpty, components[1] != ".", components[1] != ".." else {
                    throw StagingError.unsafePath(ref.file)
                }

                let url: URL
                do {
                    url = try BackupArchiveReader.safeBlobURL(ref.file, root: source)
                } catch {
                    throw StagingError.unsafePath(ref.file)
                }

                try requireRegularFile(at: url, label: ref.file)

                // 用**源文件实际大小**，不用 manifest 的声明值 —— 声明值不可信。
                let actual = fileSize(url)
                guard actual <= limits.blobBytes else {
                    throw StagingError.entryTooLarge(ref.file, bytes: actual)
                }
                total += actual
                guard total <= limits.totalBytes else { throw StagingError.totalTooLarge(bytes: total) }

                entries.append((ref.file, url, actual))
            }
        }

        // 磁盘预检：staging 一份 + 恢复写入一份 + 余量。
        let needed = Int64(Double(total) * limits.diskHeadroomMultiplier)
        if let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
           let values = try? base.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let available = values.volumeAvailableCapacityForImportantUsage,
           available < needed {
            throw StagingError.insufficientDisk(needed: needed, available: available)
        }

        return Plan(manifest: manifest, manifestData: manifestData, entries: entries, totalBytes: total)
    }

    /// 必须是**普通文件**：拒绝符号链接、目录、设备节点等一切别的东西。
    ///
    /// 预检和复制前各调一次 —— 两次之间源可以被换掉，所以不能只查一次。
    private static func requireRegularFile(at url: URL, label: String) throws {
        // **必须用 `attributesOfItem` 而不是 `URL.resourceValues`。**
        //
        // `resourceValues` 是**按 URL 实例缓存的**：预检时读过一次（那时确实是普通文件），
        // 复制前拿同一个 URL 再读，返回的是缓存值 —— 于是"复制前重新验形态"这道
        // TOCTOU 防护形同虚设。测试 testSourceSwappedToDirectoryBeforeCopyIsRejected
        // 就是这么发现的：源已经被换成目录，检查却仍然放行。
        //
        // `attributesOfItem` 每次真去 stat，且不跟随符号链接（`.typeSymbolicLink`
        // 会如实报出来），正是这里需要的语义。
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            throw StagingError.entryMissing(label)
        }
        let type = attrs[.type] as? FileAttributeType
        if type == .typeSymbolicLink { throw StagingError.symlinkRejected(label) }
        guard type == .typeRegular else { throw StagingError.notRegularFile(label) }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - 阶段二:按计划复制

    /// 按计划逐项复制到 staging。**只复制计划里的条目**,未被引用的文件一概不进来。
    ///
    /// - Important: 调用方必须在**用户确认之后**才调用本方法 —— 这一步才是那 422 MB。
    static func materialize(_ plan: Plan, source: URL, limits: Limits = .production) throws -> URL {
        let fm = FileManager.default
        let root = try stagingRoot()
        let partial = root.appendingPathComponent("import-\(UUID().uuidString).beadbackup.partial")
        let final = URL(fileURLWithPath: partial.path.replacingOccurrences(of: ".partial", with: ""))

        try? fm.removeItem(at: partial)
        do {
            try fm.createDirectory(at: partial.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        } catch {
            throw StagingError.copyFailed("创建暂存目录失败: \(error)")
        }

        var copied: Int64 = 0
        do {
            // manifest 写**预检时读到的那份字节**，不重新从源读 —— 用户点确认到这里
            // 之间，源上的 manifest 可以被换掉，那样"用户看到的"和"实际导入的"就不是
            // 一回事了。
            copied += Int64(plan.manifestData.count)
            // 与 blob 一样，写之前先查 —— 否则 manifest 这一段绕过了上限契约。
            guard copied <= limits.totalBytes else { throw StagingError.totalTooLarge(bytes: copied) }
            try plan.manifestData.write(to: partial.appendingPathComponent("manifest.json"))

            for entry in plan.entries {
                // 复制**前**再验一次形态：预检到现在之间，源可以被换成 symlink 或目录。
                try requireRegularFile(at: entry.source, label: entry.relativePath)
                try streamCopy(from: entry.source,
                               to: partial.appendingPathComponent(entry.relativePath),
                               label: entry.relativePath,
                               copiedSoFar: &copied,
                               limits: limits)
            }
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }

        try? fm.removeItem(at: final)
        do {
            try fm.moveItem(at: partial, to: final)
        } catch {
            try? fm.removeItem(at: partial)
            throw StagingError.copyFailed("提交暂存目录失败: \(error)")
        }
        return final
    }

    /// 按块流式复制,**每写一块前检查单条与累计上限**。
    ///
    /// ## 为什么不能用 `FileManager.copyItem`
    ///
    /// `copyItem` 是全有全无的:它会先把整个文件搬完,我们只能在它返回**之后**才看到
    /// 落地大小。也就是说源在预检之后被换成一个 200 GB 的文件时,那 200 GB 已经写完了 ——
    /// 上限检查发生在灾难之后,等于没有。
    ///
    /// (此前的"源变大"测试用 200 KB 验证,通过的是"事后拒绝"这条,
    /// 恰好没有暴露"复制过程不受限"这个真问题 —— 那个测试给了假信心。)
    ///
    /// 流式复制则在每块写入前判断,超限立即停手,最坏只多写一个块。
    private static func streamCopy(
        from src: URL, to dst: URL, label: String,
        copiedSoFar: inout Int64, limits: Limits
    ) throws {
        guard let input = try? FileHandle(forReadingFrom: src) else {
            throw StagingError.copyFailed("无法读取 \(label)")
        }
        defer { try? input.close() }

        guard FileManager.default.createFile(atPath: dst.path, contents: nil),
              let output = try? FileHandle(forWritingTo: dst) else {
            throw StagingError.copyFailed("无法写入 \(label)")
        }
        defer { try? output.close() }

        var entryBytes: Int64 = 0
        while true {
            let chunk: Data?
            do { chunk = try input.read(upToCount: limits.copyBlockBytes) }
            catch { throw StagingError.copyFailed("\(label): \(error)") }
            guard let chunk, !chunk.isEmpty else { break }

            // **先判断，后写入。**
            entryBytes += Int64(chunk.count)
            if entryBytes > limits.blobBytes {
                throw StagingError.entryTooLarge(label, bytes: entryBytes)
            }
            copiedSoFar += Int64(chunk.count)
            if copiedSoFar > limits.totalBytes {
                throw StagingError.totalTooLarge(bytes: copiedSoFar)
            }

            do { try output.write(contentsOf: chunk) }
            catch { throw StagingError.copyFailed("\(label): \(error)") }
        }
    }

    // MARK: - staging 生命周期

    static func stagingRoot() throws -> URL {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw StagingError.copyFailed("无法定位 Application Support")
        }
        let dir = base.appendingPathComponent("ImportStaging", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 清理**无人引用**的 staging 残留。启动时调用一次。
    ///
    /// 进程若在 `materialize` 的 rename 之后、`apply` 开始之前被杀,就会留下一份
    /// 成品 staging 而 `RestoreJournal` 里没有它 —— 没有任何东西会再引用它,
    /// 但它可能有几百 MB。`.partial` 同理(中断的复制)。
    ///
    /// **只删没被 journal 指向的**:被指向的那份正是用户重跑恢复要用的。
    static func cleanupOrphans() {
        guard let root = try? stagingRoot(),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil) else { return }
        let referenced = RestoreJournal.residual()?.archivePath
        for url in entries where url.path != referenced {
            try? FileManager.default.removeItem(at: url)
            AppLogger.shared.info("BackupImport", "orphan_staging_removed", metadata: [
                "name": url.lastPathComponent
            ])
        }
    }

    /// 清理 staging。
    ///
    /// **失败时绝不能无条件删。**`RestoreJournal` 在 `apply` 中断后会指向这份 staging 归档,
    /// 用户重跑恢复靠的就是它还在盘上。删了的话,刚补好的"半恢复可重试"机制当场失效 ——
    /// 用户看到红色横幅、点"重新恢复该归档",却找不到归档。
    ///
    /// 所以清理只在这三种情况下发生:
    ///   - 校验失败 / 用户取消 → 删(还没动过任何数据)
    ///   - apply 成功且 journal 已清除 → 删
    ///   - apply 抛错或进程被杀 → **保留**,直到重试成功或用户明确放弃
    static func cleanupIfSafe(_ staging: URL) {
        if let residual = RestoreJournal.residual(),
           residual.archivePath == staging.path {
            AppLogger.shared.warning("BackupImport", "staging_retained_for_retry", metadata: [
                "phase": residual.phase
            ])
            return
        }
        try? FileManager.default.removeItem(at: staging)
    }
}
