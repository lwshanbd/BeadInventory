//
//  ProjectMetadataScanner.swift
//  BeadInventory
//
//  项目列表的只读 SQLite 元数据读取。
//
//  SwiftData 的 `propertiesToFetch` 不能保证不会在访问 @Model 属性时触发整行
//  Core Data fault。SDProjectRecord 的图片仍是 inline BLOB，整行 fault 会沿着
//  overflow page 把图片读进来；这正是大库冷启动和 CloudKit refresh 卡顿的根因。
//
//  此扫描器只读取项目 metadata 和 bead usage 的小字段。它绝不 SELECT 四个图片列，
//  因此 SQLite 无需追踪图片的 overflow page。表结构不符合预期时返回
//  `.unsupportedStore`，调用方再走 SwiftData 兼容路径；瞬时 I/O/锁竞争则返回
//  `.transient`，不能在最忙的时候退回会物化 BLOB 的路径。
//

import Foundation
import SQLite3

enum ProjectMetadataScanner {
    private static let projectsTable = "ZSDPROJECTRECORD"
    private static let usagesTable = "ZSDBEADUSAGE"

    static func load(storeURL: URL) -> Result<[ProjectRecord], StoreScanFailure> {
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

        let projectColumns = [
            "Z_PK", "ZID", "ZNAME", "ZDATE", "ZTOTALBEADS", "ZBRANDID",
            "ZISARCHIVED", "ZPARENTID", "ZISPLANNED", "ZEXECUTEDDATE",
            "ZCOMPLETEDDATE", "ZCOLORSYSTEMRAW"
        ]
        let usageColumns = [
            "Z_PK", "ZPROJECT", "ZID", "ZCOLORCODE", "ZBRANDID",
            "ZQUANTITY", "ZISDEDUCTED"
        ]
        switch validate(table: projectsTable, requiredColumns: projectColumns, db: db) {
        case .success: break
        case .failure(let failure): return .failure(failure)
        }
        switch validate(table: usagesTable, requiredColumns: usageColumns, db: db) {
        case .success: break
        case .failure(let failure): return .failure(failure)
        }

        // 注意：不要在这里使用 SELECT p.* 或任何图片列。SQLite 只有在列被真正读取时
        // 才会沿 overflow page 取 inline BLOB；这份显式列清单是性能安全边界。
        let sql = """
        SELECT
            p.Z_PK, p.ZID, p.ZNAME, p.ZDATE, p.ZTOTALBEADS, p.ZBRANDID,
            p.ZISARCHIVED, p.ZPARENTID, p.ZISPLANNED, p.ZEXECUTEDDATE,
            p.ZCOMPLETEDDATE, p.ZCOLORSYSTEMRAW,
            u.ZID, u.ZCOLORCODE, u.ZBRANDID, u.ZQUANTITY, u.ZISDEDUCTED
        FROM ZSDPROJECTRECORD p
        LEFT JOIN ZSDBEADUSAGE u ON u.ZPROJECT = p.Z_PK
        ORDER BY p.ZDATE DESC, u.Z_PK ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return .failure(StoreScanFailure.classify(db))
        }
        defer { sqlite3_finalize(statement) }

        var projects: [ProjectRecord] = []
        var currentProjectPrimaryKey: Int64?
        var resultCode = sqlite3_step(statement)
        while resultCode == SQLITE_ROW {
            let primaryKey = sqlite3_column_int64(statement, 0)
            if primaryKey != currentProjectPrimaryKey {
                guard let id = requiredUUID(statement, column: 1),
                      let name = requiredText(statement, column: 2) else {
                    return .failure(.unsupportedStore)
                }
                let brandID = optionalUUID(statement, column: 5)
                let parentID = optionalUUID(statement, column: 7)
                guard brandID.isValid, parentID.isValid else {
                    return .failure(.unsupportedStore)
                }

                let date = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 3))
                let executedDate = optionalDate(statement, column: 9)
                let completedDate = optionalDate(statement, column: 10)
                let colorSystem = optionalText(statement, column: 11)
                    .flatMap(ColorSystem.init(rawValue:)) ?? .mard
                projects.append(ProjectRecord(
                    id: id,
                    name: name,
                    date: date,
                    beadUsage: [],
                    totalBeads: Int(sqlite3_column_int64(statement, 4)),
                    brandId: brandID.value,
                    isArchived: sqlite3_column_int(statement, 6) != 0,
                    parentId: parentID.value,
                    isPlanned: sqlite3_column_int(statement, 8) != 0,
                    executedDate: executedDate,
                    thumbnail: nil,
                    finishedImage: nil,
                    completedDate: completedDate,
                    colorSystem: colorSystem,
                    patternGrid: nil,
                    displayThumbnail: nil
                ))
                currentProjectPrimaryKey = primaryKey
            }

            // LEFT JOIN 没有用量时，u.ZID 为 NULL；这不是坏数据。
            if sqlite3_column_type(statement, 12) != SQLITE_NULL {
                guard let id = requiredUUID(statement, column: 12),
                      let colorCode = requiredText(statement, column: 13) else {
                    return .failure(.unsupportedStore)
                }
                let brandID = optionalUUID(statement, column: 14)
                guard brandID.isValid else { return .failure(.unsupportedStore) }
                projects[projects.count - 1].beadUsage.append(BeadUsage(
                    id: id,
                    colorCode: colorCode,
                    brandId: brandID.value,
                    quantity: Int(sqlite3_column_int64(statement, 15)),
                    isDeducted: sqlite3_column_int(statement, 16) != 0
                ))
            }
            resultCode = sqlite3_step(statement)
        }

        guard resultCode == SQLITE_DONE else {
            return .failure(StoreScanFailure.classify(db))
        }
        return .success(projects)
    }

    private static func validate(
        table: String,
        requiredColumns: [String],
        db: OpaquePointer
    ) -> Result<Void, StoreScanFailure> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK, let statement else {
            return .failure(StoreScanFailure.classify(db))
        }
        defer { sqlite3_finalize(statement) }

        var columns = Set<String>()
        var resultCode = sqlite3_step(statement)
        while resultCode == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) {
                columns.insert(String(cString: name).uppercased())
            }
            resultCode = sqlite3_step(statement)
        }
        guard resultCode == SQLITE_DONE else {
            return .failure(StoreScanFailure.classify(db))
        }
        return requiredColumns.allSatisfy { columns.contains($0) }
            ? .success(())
            : .failure(.unsupportedStore)
    }

    private static func requiredUUID(_ statement: OpaquePointer, column: Int32) -> UUID? {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_BLOB where sqlite3_column_bytes(statement, column) == 16:
            guard let raw = sqlite3_column_blob(statement, column) else { return nil }
            return UUID(uuid: raw.load(as: uuid_t.self))
        case SQLITE_TEXT:
            guard let raw = sqlite3_column_text(statement, column) else { return nil }
            return UUID(uuidString: String(cString: raw))
        default:
            return nil
        }
    }

    private static func optionalUUID(_ statement: OpaquePointer, column: Int32) -> (isValid: Bool, value: UUID?) {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            return (true, nil)
        }
        guard let value = requiredUUID(statement, column: column) else {
            return (false, nil)
        }
        return (true, value)
    }

    private static func requiredText(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let raw = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: raw)
    }

    private static func optionalText(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let raw = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: raw)
    }

    private static func optionalDate(_ statement: OpaquePointer, column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, column))
    }
}
