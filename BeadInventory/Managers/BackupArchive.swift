//
//  BackupArchive.swift
//  BeadInventory
//
//  备份归档格式(v1)与**流式写出器**。
//
//  ## 它取代的是什么
//
//  旧的每周自动备份把整库编成一个巨型 JSON,图片走 base64 塞在里面。实测(Release 构建、
//  真实 669 项目库):
//
//      388 MB 原始 blob → 518 MB base64 字符串**同时驻留** → JSONSerialization 再物化一份
//      → 落盘 548 MB;主线程阻塞 3.14 秒
//
//  两个独立的病灶:
//    1. **base64 的 +33% 是白付的** —— 图片本来就是二进制,没有任何理由编成文本;
//    2. **全部同时驻留** —— 字典持有每一张图的 base64 直到序列化结束,峰值随项目数线性增长,
//       不存在单张上界。
//
//  本格式两条都消掉:图片以**原始二进制**逐个落成独立文件,写完即释放。
//  **峰值内存 = 单张最大图**,与项目数无关。
//
//  ## 格式
//
//      <name>.beadbackup/
//        manifest.json          —— formatVersion + 全部 metadata + 每个 blob 的 file/bytes/sha256
//        blobs/<uuid>.thumbnail
//        blobs/<uuid>.finished
//        blobs/<uuid>.display
//        blobs/<uuid>.grid
//
//  `patternGrid` 也进了归档 —— 旧 JSON 格式一直漏着它(`BackupManager` 源码里自注
//  「S4 follow-up:把 patternGrid 加进备份导出 JSON」),恢复后用户的网格标定会丢。
//
//  ## 原子提交
//
//  先写 `<name>.beadbackup.partial/`,全部条目与 manifest 落盘后再 `rename` 成最终名字。
//  **`.partial` 永远不出现在备份列表里,也不可被恢复** —— 中断留下的半成品不能被当成
//  可用备份,否则用户会拿一份残缺数据去覆盖好数据。
//
//  ## 一致性模型:逐记录一致(产品已裁决)
//
//  主线程只取一份 blob-free 的 metadata 快照,图片随后在后台逐条取。所以
//  **每条记录内部自洽,但整库不是同一时刻的快照** —— 备份期间用户若改了某个项目,
//  该项目可能拿到新 metadata + 旧图片。这是备份工具的常规取舍,已明确接受,
//  并写进 manifest 的 `consistencyModel` 字段备查。
//
//  要做到全库同一时刻需要单一持久化事务视图,复杂度高一个量级,防的却是低频且后果轻微
//  的情况 —— 不做。

import Foundation
import CryptoKit

// MARK: - 格式定义

/// 单个二进制条目的引用。校验和用于恢复前的完整性校验。
struct ArchivedBlobRef: Codable {
    let file: String        // 相对归档根的路径
    let bytes: Int
    let sha256: String
}

struct ArchivedProject: Codable {
    let id: UUID
    var name: String
    var date: Date
    var totalBeads: Int
    var brandId: UUID?
    var isArchived: Bool
    var parentId: UUID?
    var isPlanned: Bool
    var executedDate: Date?
    var completedDate: Date?
    var colorSystemRaw: String
    var beadUsage: [ArchivedBeadUsage]

    var thumbnail: ArchivedBlobRef?
    var finishedImage: ArchivedBlobRef?
    var displayThumbnail: ArchivedBlobRef?
    /// 拼图模式网格。旧 JSON 格式漏了它，本格式补上。
    var patternGrid: ArchivedBlobRef?
}

struct ArchivedBeadUsage: Codable {
    let colorCode: String
    let brandId: UUID?
    let quantity: Int
    let isDeducted: Bool
}

struct BackupArchiveManifest: Codable {
    /// 格式版本。恢复时必须校验 —— 未来版本不得被旧代码当成可读。
    let formatVersion: Int
    let createdAt: Date
    let appVersion: String
    /// 记录本归档的一致性语义，供将来排查"恢复出来的数据为什么不是同一时刻"。
    let consistencyModel: String

    var projects: [ArchivedProject]
    var brands: [ArchivedBrand]
    var brandStocks: [ArchivedBrandStock]
    var customColors: [ArchivedCustomColor]
    var currentBrandId: UUID?
}

struct ArchivedBrand: Codable {
    let id: UUID
    var name: String
    var sortOrder: Int
    var createdAt: Date
    var lowStockThreshold: Int
    var colorSystemRaw: String
}

struct ArchivedBrandStock: Codable {
    let id: UUID
    var brandId: UUID
    var mardCode: String
    var stock: Int
    var used: Int
    var isHidden: Bool
}

struct ArchivedCustomColor: Codable {
    let id: UUID
    var colorCode: String
    var colorName: String
    var colorHex: String
    var createdAt: Date
    var updatedAt: Date
}

// MARK: - 写出

enum BackupArchiveWriter {

    static let currentFormatVersion = 1
    static let directoryExtension = "beadbackup"
    static let partialSuffix = ".partial"

    enum WriteError: Error {
        case cancelled
        case ioFailed(String)
    }

    /// 主线程侧的 blob-free 快照。
    ///
    /// **刻意不含任何图片字节** —— 它就是"逐记录一致"里那份 metadata 基准。
    /// `InventoryManager.projects` 缓存本来就不带 blob（v2.0.x 起为避免 jetsam），
    /// 所以这一步是纯拷贝，不触发任何取图。
    struct MetadataSnapshot {
        let projects: [ProjectRecord]
        let brands: [Brand]
        let brandStocks: [BrandStock]
        let customColors: [CustomColor]
        let currentBrandId: UUID?
        let appVersion: String
    }

    /// 流式写出归档。
    ///
    /// - 图片经 `ProjectImageLoader`（后台 actor、单列投影）**逐条**取出，写完即释放；
    ///   任何时刻内存里最多一张图。
    /// - 每写完一条检查一次取消。
    /// - 全部写完才 `rename` 成最终名字；中途失败留下的 `.partial` 不会被列出或恢复。
    ///
    /// - Returns: 最终归档目录 URL。
    static func write(
        snapshot: MetadataSnapshot,
        imageLoader: ProjectImageLoader,
        to destinationDirectory: URL,
        archiveName: String,
        onPhase: (String) -> Void = { _ in }
    ) async throws -> URL {
        let fm = FileManager.default
        let finalURL = destinationDirectory.appendingPathComponent("\(archiveName).\(directoryExtension)")
        let partialURL = destinationDirectory.appendingPathComponent("\(archiveName).\(directoryExtension)\(partialSuffix)")

        // 残留的同名 .partial（上次中断）直接清掉 —— 它按定义不可用。
        if fm.fileExists(atPath: partialURL.path) {
            try? fm.removeItem(at: partialURL)
        }
        let blobsURL = partialURL.appendingPathComponent("blobs", isDirectory: true)
        do {
            try fm.createDirectory(at: blobsURL, withIntermediateDirectories: true)
        } catch {
            throw WriteError.ioFailed("创建归档目录失败: \(error)")
        }

        onPhase("writing_blobs")

        var archivedProjects: [ArchivedProject] = []
        archivedProjects.reserveCapacity(snapshot.projects.count)

        for project in snapshot.projects {
            if Task.isCancelled { throw WriteError.cancelled }

            var archived = ArchivedProject(
                id: project.id,
                name: project.name,
                date: project.date,
                totalBeads: project.totalBeads,
                brandId: project.brandId,
                isArchived: project.isArchived,
                parentId: project.parentId,
                isPlanned: project.isPlanned,
                executedDate: project.executedDate,
                completedDate: project.completedDate,
                colorSystemRaw: project.colorSystem.rawValue,
                beadUsage: project.beadUsage.map {
                    ArchivedBeadUsage(colorCode: $0.colorCode, brandId: $0.brandId,
                                      quantity: $0.quantity, isDeducted: $0.isDeducted)
                }
            )

            // 逐个字段取 → 写 → 释放。每个 await 之间内存里只有一张图。
            // autoreleasepool 不适用于 async 边界，靠的是作用域立即结束 + 不累积引用。
            if let data = await imageLoader.thumbnail(for: project.id) {
                archived.thumbnail = try writeBlob(data, name: "\(project.id.uuidString).thumbnail",
                                                   in: blobsURL, root: partialURL)
            }
            if Task.isCancelled { throw WriteError.cancelled }

            if let data = await imageLoader.finishedImage(for: project.id) {
                archived.finishedImage = try writeBlob(data, name: "\(project.id.uuidString).finished",
                                                       in: blobsURL, root: partialURL)
            }
            if Task.isCancelled { throw WriteError.cancelled }

            if let data = await imageLoader.displayThumbnail(for: project.id) {
                archived.displayThumbnail = try writeBlob(data, name: "\(project.id.uuidString).display",
                                                          in: blobsURL, root: partialURL)
            }
            if Task.isCancelled { throw WriteError.cancelled }

            // patternGrid：旧 JSON 格式一直漏着，恢复后用户的网格标定会丢。
            if let grid = await imageLoader.patternGrid(for: project.id),
               let gridData = try? JSONEncoder().encode(grid) {
                archived.patternGrid = try writeBlob(gridData, name: "\(project.id.uuidString).grid",
                                                     in: blobsURL, root: partialURL)
            }

            archivedProjects.append(archived)
        }

        onPhase("writing_manifest")
        if Task.isCancelled { throw WriteError.cancelled }

        let manifest = BackupArchiveManifest(
            formatVersion: currentFormatVersion,
            createdAt: Date(),
            appVersion: snapshot.appVersion,
            consistencyModel: "per-record",
            projects: archivedProjects,
            brands: snapshot.brands.map {
                ArchivedBrand(id: $0.id, name: $0.name, sortOrder: $0.sortOrder,
                              createdAt: $0.createdAt, lowStockThreshold: $0.lowStockThreshold,
                              colorSystemRaw: $0.colorSystem.rawValue)
            },
            brandStocks: snapshot.brandStocks.map {
                ArchivedBrandStock(id: $0.id, brandId: $0.brandId, mardCode: $0.mardCode,
                                   stock: $0.stock, used: $0.used, isHidden: $0.isHidden)
            },
            customColors: snapshot.customColors.map {
                ArchivedCustomColor(id: $0.id, colorCode: $0.colorCode, colorName: $0.colorName,
                                    colorHex: $0.colorHex, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
            },
            currentBrandId: snapshot.currentBrandId
        )

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(manifest)
            try data.write(to: partialURL.appendingPathComponent("manifest.json"), options: .atomic)
        } catch {
            throw WriteError.ioFailed("写 manifest 失败: \(error)")
        }

        onPhase("committing")

        // 原子提交：目录 rename 在同卷上是原子的。到这一步之前，外界看到的一直是
        // `.partial`（不可列出、不可恢复）。
        if fm.fileExists(atPath: finalURL.path) {
            try? fm.removeItem(at: finalURL)
        }
        do {
            try fm.moveItem(at: partialURL, to: finalURL)
        } catch {
            throw WriteError.ioFailed("提交归档失败: \(error)")
        }
        return finalURL
    }

    /// 写一个二进制条目并返回其引用(含 sha256)。
    ///
    /// `data` 在本函数返回后即无引用 —— 调用方也不持有,所以峰值恒为单张。
    private static func writeBlob(
        _ data: Data, name: String, in blobsURL: URL, root: URL
    ) throws -> ArchivedBlobRef {
        let fileURL = blobsURL.appendingPathComponent(name)
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw WriteError.ioFailed("写 blob 失败 \(name): \(error)")
        }
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return ArchivedBlobRef(file: "blobs/\(name)", bytes: data.count, sha256: hex)
    }
}
