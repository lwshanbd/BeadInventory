//
//  ProjectImageCompactionScanner.swift
//  BeadInventory
//
//  用只读 SQLite 连接找出「需要瘦身的项目行」。
//
//  ## 为什么不能用 SwiftData 谓词
//
//  `#Predicate { $0.thumbnail != nil }` 即使配 `propertiesToFetch = [\.id]`，实测仍会把
//  命中行的 blob 内容 SELECT 进内存（120 条 × 13 MB → +1.26 GB，见
//  `InitialLoadMemoryDiagnosticTests`）。投影只控制生成对象的字段，不控制 SELECT 出来的列。
//  迁移器一次要过全表，走 SwiftData 谓词就是当场 jetsam。
//
//  ## 为什么 `length(ZTHUMBNAIL)` 不会物化 blob
//
//  SQLite 对「`length()` / `typeof()` 的实参是直接的列引用」这种形态有专门优化：
//  代码生成时给 `OP_Column` 打上 `OPFLAG_LENGTHARG`，只读记录头里的 serial type
//  推出字节数，**不去追 overflow page 链**。所以
//  `WHERE length(ZTHUMBNAIL) > ?` 的代价与 `IS NOT NULL` 同级。
//
//  这个优化是本文件成立的前提，所以 `ProjectImageCompactionScannerTests`
//  在真实体量库上直接量 phys_footprint 把它钉住 —— 万一未来 SQLite 改了实现，
//  测试会先红，而不是等用户 jetsam。
//
//  ## 安全边界（同 ProjectBlobExistenceScanner）
//
//  - `SQLITE_OPEN_READONLY` 打开，不可能写坏 store；WAL 下读的是一致性快照。
//  - `PRAGMA table_info` 核对表 / 列存在，对不上返回 nil。
//  - ZID 兼容 16 字节 BLOB 与 TEXT 两种存储；出现解析不了的行整次作废返回 nil，
//    **绝不静默丢行**（丢行 = 那个项目永远不被瘦身，库永远瘦不下来）。

import Foundation
import SQLite3

/// raw SQLite 扫描的失败原因 —— 调用方**必须**区分这两种。
///
/// 两个扫描器（存在性 / 瘦身候选）共用。分开的理由是回退策略完全相反：
///   - `.unsupportedStore` 是永久状态（in-memory 测试库、未来 schema 变更），
///     回退到 SwiftData 查询是对的。
///   - `.transient` 是 SQLITE_BUSY / I/O 错误，**不能**回退 —— SwiftData 的 BLOB 谓词
///     实测 +1.26GB，而扫描忙的时候恰恰是最不该吃内存的时候（迁移期间尤其）。
///     正确做法是保留上一次的结果、等下次刷新。
enum StoreScanFailure: Error, Equatable {
    case unsupportedStore
    case transient
}

enum ProjectImageCompactionScanner {
    private static let table = "ZSDPROJECTRECORD"
    private static let idColumn = "ZID"
    private static let thumbnailColumn = "ZTHUMBNAIL"
    private static let finishedImageColumn = "ZFINISHEDIMAGE"
    private static let displayThumbnailColumn = "ZDISPLAYTHUMBNAIL"

    typealias ScanFailure = StoreScanFailure

    /// 找出需要瘦身的项目 ID。
    ///
    /// 命中条件（并集）：
    ///   1. `thumbnail` 或 `finishedImage` 字节数超过 `thresholdBytes` —— 需要重编码
    ///   2. 有 `thumbnail` 但没有 `displayThumbnail` —— 需要回填列表小图（原迁移职责）
    ///
    /// - Parameter excluding: 已知「试过但压不下去」的项目（见协调器的 stubborn 记账）。
    ///   不排除的话这些行每轮都会被选中重写，那就是换了个触发器的写放大。
    static func scanCandidates(
        storeURL: URL,
        thresholdBytes: Int,
        limit: Int,
        excluding: Set<UUID>
    ) -> Result<[UUID], ScanFailure> {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return .failure(.unsupportedStore)
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if db != nil { sqlite3_close(db) }
            return .failure(.transient)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2_000)

        // schema 保险丝
        var existingColumns = Set<String>()
        do {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else {
                return .failure(.unsupportedStore)
            }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let name = sqlite3_column_text(stmt, 1) {
                    existingColumns.insert(String(cString: name).uppercased())
                }
            }
        }
        let required = [idColumn, thumbnailColumn, finishedImageColumn, displayThumbnailColumn]
        guard required.allSatisfy({ existingColumns.contains($0) }) else {
            return .failure(.unsupportedStore)
        }

        // `excluding` 在 Swift 侧过滤而不是塞进 SQL：集合通常是空或个位数，
        // 拼 IN (...) 反而要处理绑定上限。多取一些行再过滤即可。
        let fetchLimit = limit + excluding.count

        let sql = """
        SELECT \(idColumn) FROM \(table) \
        WHERE length(\(thumbnailColumn)) > ?1 \
           OR length(\(finishedImageColumn)) > ?1 \
           OR (\(thumbnailColumn) IS NOT NULL AND \(displayThumbnailColumn) IS NULL) \
        LIMIT ?2
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return .failure(.transient)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(thresholdBytes))
        sqlite3_bind_int64(stmt, 2, Int64(fetchLimit))

        var ids: [UUID] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            let uuid: UUID
            switch sqlite3_column_type(stmt, 0) {
            case SQLITE_BLOB where sqlite3_column_bytes(stmt, 0) == 16:
                guard let raw = sqlite3_column_blob(stmt, 0) else { return .failure(.transient) }
                uuid = UUID(uuid: raw.load(as: uuid_t.self))
            case SQLITE_TEXT:
                guard let c = sqlite3_column_text(stmt, 0),
                      let parsed = UUID(uuidString: String(cString: c)) else {
                    return .failure(.unsupportedStore)
                }
                uuid = parsed
            default:
                // ZID 形态不符合任何已知存储方式：假设失效，整次作废
                return .failure(.unsupportedStore)
            }
            if !excluding.contains(uuid) {
                ids.append(uuid)
                if ids.count >= limit { break }
            }
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_ROW || rc == SQLITE_DONE else {
            return .failure(.transient)
        }
        return .success(ids)
    }
}
