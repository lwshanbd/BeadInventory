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

    /// 按 SQLite 的结果码分类，**不要按「哪一次调用失败了」分类**。
    ///
    /// 踩过的坑：schema 探测那步原本把所有失败一律记成 `.unsupportedStore`，而那恰恰是
    /// 唯一会回退到 SwiftData BLOB 谓词（实测 +1.26 GB）的分支。库被 CloudKit 的
    /// vacuum 持锁时 `PRAGMA table_info` 会 `SQLITE_BUSY`（busy_timeout 只有 2 秒），
    /// 于是「瞬时忙」被判成「永久不支持」→ 在最不该吃内存的时刻物化 120×13 MB。
    /// 分类法自己的盲区把它本来要防的失败模式放了进来。
    static func classify(_ db: OpaquePointer?) -> StoreScanFailure {
        guard let db else { return .transient }
        return classify(resultCode: sqlite3_errcode(db))
    }

    /// 纯函数版 —— 分类表本身可以直接表驱动测试，不用把真库驱进 SQLITE_NOTADB 那种状态。
    ///
    /// **默认方向是 `.transient`。** 认错成瞬时的代价是下次启动多扫一遍（零物化，
    /// 实测 0.016 MB）；认错成永久的代价是走 SwiftData BLOB 回退（实测 +1.26 GB）
    /// 或者整个功能停摆 —— 两边不对称，所以**只有确证「换个时间也一样」的码**才进永久档。
    ///
    /// 特别说明 `SQLITE_READONLY`：名字像永久，实际上它最常见的出场方式是
    /// `SQLITE_READONLY_RECOVERY / _CANTINIT` —— **只读连接**打开一个 WAL 库时发现
    /// WAL 需要恢复（App 刚崩过），而恢复必须由写连接（App 自己的 SwiftData 连接）
    /// 来做。等主连接把库打开、WAL 恢复完，重试就能过 —— 这是教科书式的瞬时失败。
    /// PERM / AUTH 是文件层权限（沙盒态漂移），也可能随生命周期变化，同归瞬时档。
    static func classify(resultCode: Int32) -> StoreScanFailure {
        switch resultCode & 0xFF {
        case SQLITE_ERROR,      // SQL / schema 不匹配 —— 对同一库确定性复现
             SQLITE_CORRUPT,    // 库文件损坏
             SQLITE_NOTADB,     // 根本不是 SQLite 文件
             SQLITE_FORMAT,
             SQLITE_MISMATCH:
            return .unsupportedStore
        default:
            return .transient
        }
    }
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
    ) -> Result<[Candidate], ScanFailure> {
        scanIDs(
            storeURL: storeURL,
            table: table,
            sizeExpression: "(coalesce(length(\(thumbnailColumn)), 0) + coalesce(length(\(finishedImageColumn)), 0) + coalesce(length(\(displayThumbnailColumn)), 0))",
            where: """
            length(\(thumbnailColumn)) > ?1 \
            OR length(\(finishedImageColumn)) > ?1 \
            OR (\(thumbnailColumn) IS NOT NULL AND \(displayThumbnailColumn) IS NULL)
            """,
            requiredColumns: [thumbnailColumn, finishedImageColumn, displayThumbnailColumn],
            thresholdBytes: thresholdBytes,
            limit: limit,
            excluding: excluding
        )
    }

    /// 一条候选：ID + 当时行内相关列长度**之和**。
    ///
    /// 带上字节数是为了让协调器的 stubborn 记账能**按内容键控**而不是按 ID 永久拉黑 ——
    /// 用户换图 / 备份恢复 / CloudKit 从未升级设备同步来新图之后，字节数变了就该重新考虑。
    ///
    /// 用 sum 而不是 max：max 只反映最大那列，用户换掉**较小**那张图（或清掉
    /// displayThumbnail）时 max 不变 → 指纹不变 → 该行被继续拉黑（round-2 双审两侧命中）。
    /// sum 让任何一列的变化都改变指纹（等长替换仍撞，但那需要字节数恰好相同，可接受）。
    ///
    /// **口径耦合（三处必须一致，改一处要同步另两处）**：
    ///   1. 本文件两个 sizeExpression（项目 = 三个图片列之和；历史 = 两列快照之和）
    ///   2. `compactOne` 保存后算的 `scannerMetricBytes`
    ///   3. `compactHistoryOne` 保存后算的 `bytesWritten`
    /// stubborn 键靠这个数字对得上，口径漂移 = 拉黑永远失配。
    struct Candidate: Equatable, Sendable {
        let id: UUID
        let bytes: Int
    }

    /// 两张表共用的实现：只读连接 + schema 保险丝 + 取 ZID。
    ///
    /// `whereClause` 里的 `?1` 绑定 `thresholdBytes`，`?2` 绑定 limit。
    /// 谓词一律写成 `length(<直接列引用>)` 的形态 —— SQLite 只对这种形态启用
    /// `OPFLAG_LENGTHARG`（只读记录头的 serial type，不追 overflow page 链）。
    /// 套一层表达式（`length(coalesce(x, ''))` 之类）就会退化成真的把 blob 读出来。
    private static func scanIDs(
        storeURL: URL,
        table: String,
        sizeExpression: String,
        where whereClause: String,
        requiredColumns: [String],
        thresholdBytes: Int,
        limit: Int,
        excluding: Set<UUID>
    ) -> Result<[Candidate], ScanFailure> {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return .failure(.unsupportedStore)
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            let failure = StoreScanFailure.classify(db)
            if db != nil { sqlite3_close(db) }
            return .failure(failure)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2_000)

        // schema 保险丝
        var existingColumns = Set<String>()
        do {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else {
                return .failure(StoreScanFailure.classify(db))
            }
            defer { sqlite3_finalize(stmt) }
            var rc = sqlite3_step(stmt)
            while rc == SQLITE_ROW {
                if let name = sqlite3_column_text(stmt, 1) {
                    existingColumns.insert(String(cString: name).uppercased())
                }
                rc = sqlite3_step(stmt)
            }
            // **终止码必须检查。** 原来写的是 `while sqlite3_step(...) == SQLITE_ROW`，
            // 中途 SQLITE_BUSY 会安静地退出循环，留下一份**残缺**的列名集合，
            // 下面的 allSatisfy 随即失败 → 又是一次「瞬时忙被判成永久不支持」。
            guard rc == SQLITE_DONE else {
                return .failure(StoreScanFailure.classify(db))
            }
        }
        guard ([idColumn] + requiredColumns).allSatisfy({ existingColumns.contains($0) }) else {
            return .failure(.unsupportedStore)
        }

        // `excluding` 在 Swift 侧过滤而不是塞进 SQL：集合通常是空或个位数，
        // 拼 IN (...) 反而要处理绑定上限。多取一些行再过滤即可。
        // `sizeExpression` 里每个 length() 的实参仍是**裸列引用**，OPFLAG_LENGTHARG
        // 优化按 length() 逐个判定，套在 max()/coalesce() 外层不影响它。
        // （ProjectImageCompactionScannerTests 的 footprint 断言仍然钉着这条。）
        let sql = "SELECT \(idColumn), \(sizeExpression) FROM \(table) WHERE \(whereClause) LIMIT ?2"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return .failure(StoreScanFailure.classify(db))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(thresholdBytes))
        sqlite3_bind_int64(stmt, 2, Int64(limit + excluding.count))

        var ids: [Candidate] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            let uuid: UUID
            switch sqlite3_column_type(stmt, 0) {
            case SQLITE_BLOB where sqlite3_column_bytes(stmt, 0) == 16:
                // 声称 16 字节却取不到指针 = 行本身坏了，永久
                guard let raw = sqlite3_column_blob(stmt, 0) else { return .failure(.unsupportedStore) }
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
                ids.append(Candidate(id: uuid, bytes: Int(sqlite3_column_int64(stmt, 1))))
                if ids.count >= limit { break }
            }
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_ROW || rc == SQLITE_DONE else {
            return .failure(StoreScanFailure.classify(db))
        }
        return .success(ids)
    }

    // MARK: - 历史表

    private static let historyTable = "ZSDHISTORYRECORD"
    private static let historyBeforeColumn = "ZBEFORESNAPSHOT"
    private static let historyAfterColumn = "ZAFTERSNAPSHOT"

    /// 找出快照过大的历史记录 ID。理由同项目行 —— 见 `HistorySnapshotCompactor` 头注释：
    /// 快照走 JSONEncoder，`Data` 被编成 base64（+33%），单条可达 34 MB，
    /// `maxRecords = 100` 时历史表单独可达 GB 级。
    static func scanHistoryCandidates(
        storeURL: URL,
        thresholdBytes: Int,
        limit: Int,
        excluding: Set<UUID>
    ) -> Result<[Candidate], ScanFailure> {
        scanIDs(
            storeURL: storeURL,
            table: historyTable,
            sizeExpression: "(coalesce(length(\(historyBeforeColumn)), 0) + coalesce(length(\(historyAfterColumn)), 0))",
            where: "length(\(historyBeforeColumn)) > ?1 OR length(\(historyAfterColumn)) > ?1",
            requiredColumns: [historyBeforeColumn, historyAfterColumn],
            thresholdBytes: thresholdBytes,
            limit: limit,
            excluding: excluding
        )
    }
}
