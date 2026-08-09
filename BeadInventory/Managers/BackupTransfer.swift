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

    /// 单次导入允许的最大总字节。与 `BackupArchiveReader.maxTotalBlobBytes` 同量级,
    /// 但这里量的是**源文件实际大小之和**,不是 manifest 的声明值。
    static let maxSourceTotalBytes: Int64 = 64 * 1024 * 1024 * 1024

    /// 磁盘余量安全系数。
    ///
    /// 需要的空间不止 staging 一份:恢复时还要把这些字节写进 store,
    /// 再留一点余量给 WAL / 临时文件。只按"staging 一份"预检会在恢复阶段把盘撑满,
    /// 而那时 metadata 已经替换过了 —— 半恢复状态。
    static let diskHeadroomMultiplier: Double = 2.5

    struct Plan {
        let manifest: BackupArchiveManifest
        /// 相对路径 → 源 URL。**只含 manifest 引用的条目 + manifest.json 自身。**
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
    static func makePlan(source: URL, totalLimit: Int64 = maxSourceTotalBytes) throws -> Plan {
        let fm = FileManager.default
        let manifestURL = source.appendingPathComponent("manifest.json")
        guard fm.fileExists(atPath: manifestURL.path) else { throw StagingError.manifestMissing }

        let manifestSize = ((try? fm.attributesOfItem(atPath: manifestURL.path))?[.size] as? NSNumber)?.int64Value ?? -1
        guard manifestSize <= BackupArchiveReader.maxManifestBytes else {
            throw StagingError.manifestTooLarge(bytes: manifestSize)
        }

        let manifest: BackupArchiveManifest
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            manifest = try decoder.decode(BackupArchiveManifest.self, from: try Data(contentsOf: manifestURL))
        } catch {
            throw StagingError.manifestUndecodable("\(error)")
        }
        guard manifest.formatVersion == BackupArchiveWriter.currentFormatVersion else {
            throw StagingError.unsupportedFormatVersion(manifest.formatVersion)
        }

        var entries: [(String, URL, Int64)] = [("manifest.json", manifestURL, manifestSize)]
        var total: Int64 = manifestSize

        for project in manifest.projects {
            for ref in [project.thumbnail, project.finishedImage,
                        project.displayThumbnail, project.patternGrid].compactMap({ $0 }) {
                // **路径形状必须精确匹配 `blobs/<单段文件名>`。**
                //
                // 复用 safeBlobURL 的越界检查还不够 —— 它只保证"不跑出归档根"，
                // 但 `blobs/a/b/c/.../x` 这种深层嵌套仍然合法。写出器只会产生
                // `blobs/<uuid>.<kind>` 一种形状，所以任何别的形状都说明这不是我们写的东西。
                //
                // 收紧的实际收益：materialize 只需 `blobs/` 一层目录，不必按外部输入
                // 递归创建目录树 —— 少一整类"用超深路径把文件系统或我们的建目录逻辑
                // 拖垮"的可能。
                let components = ref.file.split(separator: "/", omittingEmptySubsequences: false)
                guard components.count == 2, components[0] == "blobs",
                      !components[1].isEmpty, components[1] != ".", components[1] != ".." else {
                    throw StagingError.unsafePath(ref.file)
                }

                // 再走一遍校验器那套（绝对路径、`..`、解析符号链接后越界）。
                let url: URL
                do {
                    url = try BackupArchiveReader.safeBlobURL(ref.file, root: source)
                } catch {
                    throw StagingError.unsafePath(ref.file)
                }

                // **只接受普通文件。** 符号链接一律拒绝 —— 即便 safeBlobURL 已经查过
                // 解析后是否越界，这里再挡一道：我们要复制的是内容，跟进链接毫无必要，
                // 而链接目标可能在复制期间被换掉。
                let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
                if values?.isSymbolicLink == true { throw StagingError.symlinkRejected(ref.file) }
                guard fm.fileExists(atPath: url.path) else { throw StagingError.entryMissing(ref.file) }
                guard values?.isRegularFile == true else { throw StagingError.notRegularFile(ref.file) }

                // 用**源文件实际大小**，不用 manifest 的声明值 —— 声明值不可信。
                let actual = Int64(values?.fileSize ?? 0)
                guard actual <= Int64(BackupArchiveReader.maxBlobBytes) else {
                    throw StagingError.entryTooLarge(ref.file, bytes: actual)
                }
                total += actual
                guard total <= totalLimit else { throw StagingError.totalTooLarge(bytes: total) }

                entries.append((ref.file, url, actual))
            }
        }

        // 磁盘预检：staging 一份 + 恢复写入一份 + 余量。
        let needed = Int64(Double(total) * diskHeadroomMultiplier)
        if let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
           let values = try? base.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let available = values.volumeAvailableCapacityForImportantUsage,
           available < needed {
            throw StagingError.insufficientDisk(needed: needed, available: available)
        }

        return Plan(manifest: manifest, entries: entries, totalBytes: total)
    }

    // MARK: - 阶段二:按计划复制

    /// 按计划逐项复制到 staging。**只复制计划里的条目**,未被引用的文件一概不进来。
    ///
    /// - Important: 调用方必须在**用户确认之后**才调用本方法 —— 这一步才是那 422 MB。
    static func materialize(_ plan: Plan, source: URL,
                            totalLimit: Int64 = maxSourceTotalBytes) throws -> URL {
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
        for entry in plan.entries {
            let dest = partial.appendingPathComponent(entry.relativePath)
            do {
                try fm.copyItem(at: entry.source, to: dest)
            } catch {
                try? fm.removeItem(at: partial)
                throw StagingError.copyFailed("\(entry.relativePath): \(error)")
            }
            // 复制途中源文件可能被换成更大的东西 —— 以**落地后的实际大小**再查一次。
            let landed = ((try? fm.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber)?.int64Value ?? 0
            copied += landed
            if copied > totalLimit {
                try? fm.removeItem(at: partial)
                throw StagingError.totalTooLarge(bytes: copied)
            }
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
