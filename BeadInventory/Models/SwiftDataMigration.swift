//
//  SwiftDataMigration.swift
//  BeadInventory
//
//  SwiftData 数据迁移方案
//
//  注意：SDHistoryRecord 的 targetName 属性使用了 @Attribute(originalName: "entityName")
//  这样 SwiftData 会自动从旧的 entityName 列读取数据，无需复杂的迁移逻辑
//

import Foundation
import SwiftData

// MARK: - Schema 版本定义

/// 当前 Schema 版本
enum CurrentSchema: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 1, 0)  // 1.1.0: entityName -> targetName

    static var models: [any PersistentModel.Type] {
        [
            SDBrand.self,
            SDBrandStock.self,
            SDProjectRecord.self,
            SDBeadUsage.self,
            SDHistoryRecord.self
        ]
    }
}

// MARK: - 迁移计划

/// BeadInventory 数据迁移计划
///
/// 版本历史：
/// - 1.0.0: 初始版本
/// - 1.1.0: SDHistoryRecord.entityName 重命名为 targetName（使用 originalName 属性自动迁移）
enum BeadInventoryMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [CurrentSchema.self]
    }

    static var stages: [MigrationStage] {
        // 由于使用了 @Attribute(originalName:)，SwiftData 会自动处理
        // 不需要额外的迁移阶段
        []
    }
}
