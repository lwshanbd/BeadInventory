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
//  **保证的**:每个项目的四个 blob 由**一次 fetch**取回(`ProjectImageLoader.blobs(for:)`),
//  所以单条记录内部的图片来自同一事务视图,不会出现"新缩略图 + 旧成品图"这种自相矛盾。
//
//  **不保证的**:整库不是同一时刻的快照。metadata 在主线程一次性取,各项目的图片随后
//  逐条取,所以项目之间、以及同一项目的 metadata 与图片之间,可能跨越用户的修改。
//  这是备份工具的常规取舍,已明确接受,并写进 manifest 的 `consistencyModel` 备查。
//
//  初版实现其实**连逐记录一致都没做到** —— 一个项目的四张图分四次取,来自四个不同时刻,
//  却仍在 manifest 里声称 `per-record`。复审指出后改成单次 fetch 补齐。
//  记在这里是因为:声称的语义和实现的语义脱节,比语义本身弱要危险得多。
//
//  要做到全库同一时刻需要单一持久化事务视图,复杂度高一个量级,防的却是低频且后果轻微
//  的情况 —— 不做。
//
//  ## 读失败绝不等于"没有图"
//
//  `blobs(for:)` 读取失败会 **throw,整次备份终止**。这一条不是防御性编程,是必需的:
//  恢复端按"完整快照"语义处理缺失字段(有则写、无则**显式清空**),所以一旦把读失败
//  记成"这条没图",恢复就会把用户的图**永久删掉** —— 一次瞬时错误被转写成"用户删了图"。

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
    /// 进货记录。旧 JSON 格式有这一节（`data["purchaseRecords"]`），
    /// 新格式初版漏了 —— 那会是与 patternGrid 完全同类的静默数据丢失，补上。
    var purchaseRecords: [ArchivedPurchaseRecord]
    var currentBrandId: UUID?
}

struct ArchivedPurchaseRecord: Codable {
    let id: UUID
    var name: String
    var date: Date
    var brandId: UUID
    var items: [ArchivedPurchaseItem]
    var note: String?
}

struct ArchivedPurchaseItem: Codable {
    let id: UUID
    let colorCode: String
    var quantity: Int
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
        let purchaseRecords: [PurchaseRecord]
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

            // **单次 fetch 取回该项目的全部 blob** —— 同一事务视图，
            // 这才让「逐记录一致」名副其实。分四次取的话，同一个项目的四张图会来自四个
            // 不同时刻，归档里可能出现"新缩略图 + 旧成品图"这种自身矛盾的记录。
            //
            // **读失败会 throw，整次备份就此终止**（不再往下写）。绝不能把读失败当成
            // "这条没图" —— 恢复端按完整快照语义会显式清空，那等于把一次瞬时读取错误
            // 转写成"用户删了图"，造成永久数据丢失。
            let blobs = try await imageLoader.blobs(for: project.id)

            if let data = blobs.thumbnail {
                archived.thumbnail = try writeBlob(data, name: "\(project.id.uuidString).thumbnail",
                                                   in: blobsURL, root: partialURL)
            }
            if let data = blobs.finishedImage {
                archived.finishedImage = try writeBlob(data, name: "\(project.id.uuidString).finished",
                                                       in: blobsURL, root: partialURL)
            }
            if let data = blobs.displayThumbnail {
                archived.displayThumbnail = try writeBlob(data, name: "\(project.id.uuidString).display",
                                                          in: blobsURL, root: partialURL)
            }
            // patternGrid：旧 JSON 格式一直漏着，恢复后用户的网格标定会丢。
            // 这里直接搬原始 JSON 字节，不做解码再编码 —— 原来用 `try?` 编码，
            // 编码失败会静默丢掉网格，同样是"失败被转写成没有"。
            if let gridData = blobs.patternGridData {
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
            purchaseRecords: snapshot.purchaseRecords.map { record in
                ArchivedPurchaseRecord(
                    id: record.id, name: record.name, date: record.date, brandId: record.brandId,
                    items: record.items.map {
                        ArchivedPurchaseItem(id: $0.id, colorCode: $0.colorCode, quantity: $0.quantity)
                    },
                    note: record.note
                )
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
        //
        // **绝不为了提交先删掉同名旧归档。** 原来这里是 removeItem + moveItem ——
        // 一旦 move 失败（磁盘满、权限、卷变化），旧备份已经没了、新备份也没到位，
        // 两头空。而备份的全部意义就是"出事时还有一份"，为了写新的先毁掉旧的
        // 是把它最该起作用的场景拆掉。
        //
        // 改为：撞名就换一个唯一名字。多留一份备份的代价，远小于丢一份的代价；
        // 多出来的旧备份由既有的保留策略（maxBackupCount）自然轮转。
        var committedURL = finalURL
        if fm.fileExists(atPath: committedURL.path) {
            var suffix = 2
            repeat {
                committedURL = destinationDirectory
                    .appendingPathComponent("\(archiveName)-\(suffix).\(directoryExtension)")
                suffix += 1
            } while fm.fileExists(atPath: committedURL.path) && suffix < 100
        }
        do {
            try fm.moveItem(at: partialURL, to: committedURL)
        } catch {
            throw WriteError.ioFailed("提交归档失败: \(error)")
        }
        return committedURL
    }

    /// 列出目录里的可用归档。
    ///
    /// **`.partial` 一律不列出** —— 它按定义是中断留下的半成品,把它当成可恢复备份
    /// 会让用户拿残缺数据覆盖好数据。
    static func listArchives(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries.filter { $0.pathExtension == directoryExtension }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
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

// MARK: - 读取与校验

/// 归档读取器。
///
/// ## 为什么校验必须**全部先做完**再动数据
///
/// 现有的 JSON 恢复是**分段落盘**的:先把内存数组整体赋给 manager、`saveData()` 写
/// metadata,**再**由 `restoreProjectBlobsFromBackup` 单独写图。中间任何一步失败,
/// 用户就留在一个"metadata 是新的、图还是旧的"的半恢复状态 —— 而恢复往往正是
/// 用户数据已经出问题时才做的操作,再给他一个半损坏状态是最坏的结果。
///
/// 所以本读取器的契约是:**`validate()` 通过之前,一个字节都不写入 store。**
///
/// ## 威胁模型
///
/// 归档将来可由用户从「文件」App 导入 —— 也就是说 **manifest 的内容是不可信输入**。
/// 具体防的:
///
///   - **路径穿越**:manifest 里的 `file` 字段是相对路径,恶意归档可以写
///     `../../../../private/etc/passwd` 或绝对路径,让我们把任意文件当图片读进库。
///     防法是三层:拒绝绝对路径、拒绝任何 `..` 段、**规范化并解析符号链接后再验证
///     仍在归档根内**(只做前两层挡不住归档里放一个指向外部的 symlink)。
///   - **超大条目**:单个 blob 文件被做成几 GB,`Data(contentsOf:)` 直接 OOM。
///     所以读之前先看**文件系统报告的大小**,超限直接拒。
///   - **谎报大小 / 内容被篡改**:逐条校验实际字节数与 sha256。
///   - **未来格式**:`formatVersion` 高于本版一律拒绝,不做"尽力而为"解析。
enum BackupArchiveReader {

    /// 单个 blob 的大小上限。
    ///
    /// 正常图片经 `ProjectImageEncoder` 落在 1-2 MB;历史遗留的无损 PNG 最大见过 13 MB。
    /// 64 MB 给足余量,同时把"一个条目就能撑爆内存"挡在门外。
    static let maxBlobBytes = 64 * 1024 * 1024

    /// manifest.json 的大小上限。
    ///
    /// 原来直接 `Data(contentsOf:)` 整个读进来 —— 一个几 GB 的 manifest 就能在校验开始
    /// 之前把进程干掉。**先看文件大小再决定读不读**,与单条 blob 同理。
    /// 32 MB 对一个只含 metadata 的 JSON 是极宽的余量(实测 669 项目约 1 MB)。
    static let maxManifestBytes: Int64 = 32 * 1024 * 1024

    /// 条目数与总量上限。防的是"每条都不超限、但条数无限"这种绕过方式。
    static let maxProjects = 100_000
    static let maxBlobCount = 400_000          // 每项目最多 4 个
    static let maxTotalBlobBytes: Int64 = 64 * 1024 * 1024 * 1024   // 64 GB

    struct ValidationReport {
        let manifest: BackupArchiveManifest
        let root: URL
        let totalBlobBytes: Int64
        let blobCount: Int
    }

    enum ValidationError: Error, CustomStringConvertible {
        case manifestMissing
        case manifestUndecodable(String)
        case unsupportedFormatVersion(Int)
        case unsafeBlobPath(String)
        case blobMissing(String)
        case blobTooLarge(String, bytes: Int64)
        case blobSizeMismatch(String, declared: Int, actual: Int)
        case checksumMismatch(String)
        case insufficientDiskSpace(needed: Int64, available: Int64)
        case manifestTooLarge(bytes: Int64)
        case tooManyEntries(kindLabel: String, count: Int)
        case totalSizeExceedsLimit(bytes: Int64)

        /// 不带 payload 的稳定标识。
        ///
        /// 两个用途:①遥测 —— 上报只发这个,不发路径/文件名等用户内容(路径里可能有项目
        /// UUID,`description` 里还可能带解码器吐出的原始片段);②测试断言按 case 比对,
        /// 不依赖会随实现变化的描述文案。
        var kind: String {
            switch self {
            case .manifestMissing: return "manifestMissing"
            case .manifestUndecodable: return "manifestUndecodable"
            case .unsupportedFormatVersion: return "unsupportedFormatVersion"
            case .unsafeBlobPath: return "unsafeBlobPath"
            case .blobMissing: return "blobMissing"
            case .blobTooLarge: return "blobTooLarge"
            case .blobSizeMismatch: return "blobSizeMismatch"
            case .checksumMismatch: return "checksumMismatch"
            case .insufficientDiskSpace: return "insufficientDiskSpace"
            case .manifestTooLarge: return "manifestTooLarge"
            case .tooManyEntries: return "tooManyEntries"
            case .totalSizeExceedsLimit: return "totalSizeExceedsLimit"
            }
        }

        var description: String {
            switch self {
            case .manifestMissing: return "归档缺少 manifest.json"
            case .manifestUndecodable(let e): return "manifest 无法解析: \(e)"
            case .unsupportedFormatVersion(let v): return "备份格式版本 \(v) 高于当前版本，无法读取"
            case .unsafeBlobPath(let p): return "归档包含不安全的路径: \(p)"
            case .blobMissing(let p): return "归档缺少文件: \(p)"
            case .blobTooLarge(let p, let b): return "归档条目过大: \(p) (\(b) 字节)"
            case .blobSizeMismatch(let p, let d, let a): return "条目大小不符: \(p) 声明 \(d) 实际 \(a)"
            case .checksumMismatch(let p): return "条目校验和不符: \(p)"
            case .insufficientDiskSpace(let n, let a): return "磁盘空间不足：需要 \(n) 字节，可用 \(a)"
            case .manifestTooLarge(let b): return "manifest 过大: \(b) 字节"
            case .tooManyEntries(let k, let c): return "\(k) 条目数超限: \(c)"
            case .totalSizeExceedsLimit(let b): return "归档总量超限: \(b) 字节"
            }
        }
    }

    /// 完整校验。**通过之前不写入任何数据。**
    static func validate(archiveAt root: URL) throws -> ValidationReport {
        let fm = FileManager.default
        let manifestURL = root.appendingPathComponent("manifest.json")
        guard fm.fileExists(atPath: manifestURL.path) else { throw ValidationError.manifestMissing }

        // 先看大小再决定读不读 —— 否则一个几 GB 的 manifest 能在校验开始前就干掉进程。
        let manifestSize = ((try? fm.attributesOfItem(atPath: manifestURL.path))?[.size] as? NSNumber)?.int64Value ?? -1
        guard manifestSize <= maxManifestBytes else {
            throw ValidationError.manifestTooLarge(bytes: manifestSize)
        }

        let manifest: BackupArchiveManifest
        do {
            let data = try Data(contentsOf: manifestURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            manifest = try decoder.decode(BackupArchiveManifest.self, from: data)
        } catch {
            throw ValidationError.manifestUndecodable("\(error)")
        }

        // **精确匹配，不是 `<=`。** 原来写 `<= current` 等于放行 0 和负数版本 ——
        // 只有 v1 存在，任何别的值都说明这不是我们写出来的东西，不该"尽力而为"解析。
        guard manifest.formatVersion == BackupArchiveWriter.currentFormatVersion else {
            throw ValidationError.unsupportedFormatVersion(manifest.formatVersion)
        }

        // 条目数上限：防"每条都不超限、但条数无限"绕过单条限制。
        guard manifest.projects.count <= maxProjects else {
            throw ValidationError.tooManyEntries(kindLabel: "projects", count: manifest.projects.count)
        }

        var totalBytes: Int64 = 0
        var count = 0
        for project in manifest.projects {
            for ref in [project.thumbnail, project.finishedImage,
                        project.displayThumbnail, project.patternGrid].compactMap({ $0 }) {
                let url = try safeBlobURL(ref.file, root: root)
                guard fm.fileExists(atPath: url.path) else { throw ValidationError.blobMissing(ref.file) }

                // 先问文件系统要大小，再决定读不读 —— 顺序反过来就等于让归档决定我们分配多少内存。
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                let actual = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
                guard actual <= Int64(maxBlobBytes) else {
                    throw ValidationError.blobTooLarge(ref.file, bytes: actual)
                }
                guard actual == Int64(ref.bytes) else {
                    throw ValidationError.blobSizeMismatch(ref.file, declared: ref.bytes, actual: Int(actual))
                }

                let data = try Data(contentsOf: url)
                let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard hex == ref.sha256 else { throw ValidationError.checksumMismatch(ref.file) }

                totalBytes += actual
                count += 1
                // 边累加边查 —— 等全部算完再查就已经把时间花掉了，而且给了构造者
                // 用海量小条目拖死校验的机会。
                guard count <= maxBlobCount else {
                    throw ValidationError.tooManyEntries(kindLabel: "blobs", count: count)
                }
                guard totalBytes <= maxTotalBlobBytes else {
                    throw ValidationError.totalSizeExceedsLimit(bytes: totalBytes)
                }
            }
        }

        // 恢复要把这些字节写进 store，先确认盘装得下。
        if let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let available = values.volumeAvailableCapacityForImportantUsage,
           available < totalBytes {
            throw ValidationError.insufficientDiskSpace(needed: totalBytes, available: available)
        }

        return ValidationReport(manifest: manifest, root: root, totalBlobBytes: totalBytes, blobCount: count)
    }

    /// 把 manifest 里的相对路径解析成安全的绝对 URL。
    ///
    /// 三层防护缺一不可,见类型头注释的「威胁模型」。
    static func safeBlobURL(_ relative: String, root: URL) throws -> URL {
        guard !relative.isEmpty, !relative.hasPrefix("/") else {
            throw ValidationError.unsafeBlobPath(relative)
        }
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains("..") else {
            throw ValidationError.unsafeBlobPath(relative)
        }

        let rootStd = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(relative).standardizedFileURL

        // 第一道：规范化后必须在根内。
        guard candidate.path.hasPrefix(rootStd.path + "/") || candidate.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            throw ValidationError.unsafeBlobPath(relative)
        }
        // 第二道：文件存在时解析符号链接再验一次 —— 只做路径字符串检查挡不住
        // 归档里放一个指向外部的 symlink。
        if FileManager.default.fileExists(atPath: candidate.path) {
            let resolved = candidate.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(rootStd.path + "/") else {
                throw ValidationError.unsafeBlobPath(relative)
            }
        }
        return candidate
    }

    /// 按需读取单个 blob。**恢复时逐条调用,不要一次性全读** ——
    /// 一次性读全部正是写出器刚修掉的那个 OOM 形状。
    static func readBlob(_ ref: ArchivedBlobRef, root: URL) throws -> Data {
        let url = try safeBlobURL(ref.file, root: root)
        return try Data(contentsOf: url)
    }
}

// MARK: - 恢复(应用阶段)

/// 恢复日志。
///
/// `validate()` 保证了"格式和内容是好的",但保证不了"写到一半不被杀"。
/// 恢复过程要改 metadata + 逐条写图,进程若在中途被终止,库就停在半恢复状态 ——
/// 而恢复往往正是用户数据已经出问题时才做的操作,再给他一个半损坏的库是最坏结果。
///
/// 这里的做法与备份哨兵同型:**开工前落一条记录,完成后清掉**。下次启动读到残留,
/// 就知道库可能是半恢复的,并且知道该用哪个归档重跑 —— 归档还在盘上,重跑是幂等的。
///
/// 注:这不是事务。它做不到"回滚",能做到的是**不静默** —— 让半恢复状态可被发现、可被修复。
/// 真正的回滚需要在恢复前把整个 store 复制一份,对 GB 级库代价过高,不在本轮范围。
struct RestoreJournalEntry: Codable {
    let archivePath: String
    let startedAt: Date
    var phase: String
}

enum RestoreJournal {
    private static var fileURL: URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        let dir = base.appendingPathComponent("BackupState", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("restore_journal.json")
    }

    static func begin(archive: URL) {
        write(RestoreJournalEntry(archivePath: archive.path, startedAt: Date(), phase: "metadata"))
    }

    static func setPhase(_ phase: String) {
        guard var entry = residual() else { return }
        entry.phase = phase
        write(entry)
    }

    static func finish() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 非 nil = 上一次恢复没有走完，库可能处于半恢复状态。
    static func residual() -> RestoreJournalEntry? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RestoreJournalEntry.self, from: data)
    }

    private static func write(_ entry: RestoreJournalEntry) {
        guard let url = fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry) else { return }
        try? data.write(to: url, options: .atomic)
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.synchronize()
            try? handle.close()
        }
    }
}

extension BackupArchiveReader {

    /// 应用一个**已校验**的归档。
    ///
    /// - Important: 只接受 `ValidationReport` 而不是 URL —— 类型上强制"先校验后应用"。
    ///   传不进来一个没验过的归档,是刻意的。
    ///
    /// 图片**逐条**读取写入:`readBlob` 一次一个,写完即释放。任何时刻内存里最多一张图,
    /// 与写出侧对称。**不要**改成先收集成数组再一次性交给
    /// `restoreProjectBlobsFromBackup` —— 那个签名一次收全部条目,正是写出器刚修掉的
    /// OOM 形状(388 MB 图会一次性全进内存)。
    @MainActor
    static func apply(
        _ report: ValidationReport,
        to manager: InventoryManager,
        onProgress: (Int, Int) -> Void = { _, _ in }
    ) throws {
        RestoreJournal.begin(archive: report.root)
        // **刻意不用 `defer { finish() }`** —— defer 在抛错退出时同样会执行，
        // 那会把"metadata 已替换、blob 写到一半失败"的库标记成"恢复完成"，
        // 恰好抹掉这个日志唯一的作用。日志只在**全部成功后**才清除，见函数末尾。
        let m = report.manifest

        // ① metadata 整体替换（语义就是"替换全部数据"，不是合并）
        manager.brands = m.brands.map {
            Brand(id: $0.id, name: $0.name, sortOrder: $0.sortOrder, createdAt: $0.createdAt,
                  lowStockThreshold: $0.lowStockThreshold,
                  colorSystem: ColorSystem(rawValue: $0.colorSystemRaw) ?? .mard)
        }
        manager.brandStocks = m.brandStocks.map {
            BrandStock(id: $0.id, brandId: $0.brandId, mardCode: $0.mardCode,
                       stock: $0.stock, used: $0.used, isHidden: $0.isHidden)
        }
        manager.customColors = m.customColors.map {
            CustomColor(id: $0.id, colorCode: $0.colorCode, colorHex: $0.colorHex,
                        colorName: $0.colorName, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
        }
        manager.purchaseRecords = m.purchaseRecords.map { r in
            PurchaseRecord(id: r.id, name: r.name, date: r.date, brandId: r.brandId,
                           items: r.items.map { PurchaseItem(id: $0.id, colorCode: $0.colorCode, quantity: $0.quantity) },
                           note: r.note)
        }
        manager.currentBrandId = m.currentBrandId
        // projects 只放 metadata —— 图片走下面的直写接口。
        // 塞进 manager.projects 的 ProjectRecord 恒不带 blob（v2.0.x 起的既定约束）。
        manager.projects = m.projects.map { p in
            ProjectRecord(
                id: p.id, name: p.name, date: p.date,
                beadUsage: p.beadUsage.map {
                    BeadUsage(colorCode: $0.colorCode, brandId: $0.brandId,
                              quantity: $0.quantity, isDeducted: $0.isDeducted)
                },
                totalBeads: p.totalBeads, brandId: p.brandId, isArchived: p.isArchived,
                parentId: p.parentId, isPlanned: p.isPlanned, executedDate: p.executedDate,
                completedDate: p.completedDate,
                colorSystem: ColorSystem(rawValue: p.colorSystemRaw) ?? .mard
            )
        }
        manager.saveData()

        // ② 图片逐条写回
        RestoreJournal.setPhase("blobs")
        let total = m.projects.count
        for (index, p) in m.projects.enumerated() {
            let thumbnail = try p.thumbnail.map { try readBlob($0, root: report.root) }
            let finished = try p.finishedImage.map { try readBlob($0, root: report.root) }
            let display = try p.displayThumbnail.map { try readBlob($0, root: report.root) }
            let gridData = try p.patternGrid.map { try readBlob($0, root: report.root) }

            // 单条调用 —— 见方法注释里关于 OOM 形状的说明。
            let result = manager.restoreProjectBlobsFromBackup([(
                id: p.id,
                thumbnail: thumbnail,
                finishedImage: finished,
                patternGridData: gridData,
                // 本格式**总是**如实表达 patternGrid 的有无：
                // 有则写、没有则显式清空。旧 JSON 格式压根没这个字段，只能 provided=false
                // （不动 store 旧值），那是兼容妥协，不是本格式该继承的行为。
                patternGridProvided: true,
                displayThumbnail: display,
                displayThumbnailProvided: true
            )])

            // **返回值必须检查。** 原来这里是 `_ =` —— 写失败被静默吞掉，
            // 结果是"部分 blob 没写进去"的库照样被标成恢复完成。
            // 而 metadata 已经替换过了，用户拿到的是一个自己不知道有问题的库。
            guard result.failedIDs.isEmpty else {
                throw RestoreError.blobWriteFailed(projectID: p.id)
            }

            onProgress(index + 1, total)
        }

        // 只有走到这里才算完成 —— 日志此时才清除。
        RestoreJournal.finish()
    }

    enum RestoreError: Error, CustomStringConvertible {
        case blobWriteFailed(projectID: UUID)

        var description: String {
            switch self {
            case .blobWriteFailed(let id): return "项目 \(id) 的图片写入失败，恢复已中止"
            }
        }
    }
}
