//
//  DataMigration.swift
//  BeadInventory
//
//  数据迁移 - 处理版本升级时的数据迁移
//

import Foundation

class DataMigration {
    static let migrationVersionKey = "dataMigrationVersion"
    static let currentVersion = 3  // 版本 3 = 项目绑定色号体系

    static func migrateIfNeeded(manager: InventoryManager) {
        let currentMigrationVersion = UserDefaults.standard.integer(forKey: migrationVersionKey)

        if currentMigrationVersion < 2 {
            migrateToMultiBrand(manager: manager)
            UserDefaults.standard.set(2, forKey: migrationVersionKey)
        }

        if currentMigrationVersion < 3 {
            migrateToColorSystemAware(manager: manager)
            UserDefaults.standard.set(3, forKey: migrationVersionKey)
        }
    }

    /// 版本 3 迁移：为旧的 SDProjectRecord 补充 colorSystemRaw 字段
    private static func migrateToColorSystemAware(manager: InventoryManager) {
        // struct 层的 ProjectRecord 已通过 init(from decoder:) 的 decodeIfPresent 处理
        // SwiftData 层：确保所有 SDProjectRecord 的 colorSystemRaw 有值
        manager.migrateProjectColorSystem()
    }

    private static func migrateToMultiBrand(manager: InventoryManager) {
        // 如果已经有品牌数据，不需要迁移
        if !manager.brands.isEmpty {
            return
        }

        // 检查是否有现有的库存数据需要迁移
        let hasExistingStock = manager.beadColors.contains { $0.stock != 1000 || $0.used != 0 }

        if hasExistingStock {
            // 创建默认品牌
            let defaultBrand = Brand(
                name: "默认品牌",
                sortOrder: 0
            )
            manager.brands.append(defaultBrand)

            // 将现有 BeadColor 的库存迁移到默认品牌
            for color in manager.beadColors {
                let brandStock = BrandStock(
                    brandId: defaultBrand.id,
                    mardCode: color.mardCode,
                    stock: color.stock,
                    used: color.used
                )
                manager.brandStocks.append(brandStock)
            }

            // 迁移项目记录中的 BeadUsage（关联到默认品牌）
            for i in manager.projects.indices {
                var newUsages: [BeadUsage] = []
                for usage in manager.projects[i].beadUsage {
                    let newUsage = BeadUsage(
                        id: usage.id,
                        colorCode: usage.colorCode,
                        brandId: defaultBrand.id,
                        quantity: usage.quantity,
                        isDeducted: usage.isDeducted
                    )
                    newUsages.append(newUsage)
                }
                manager.projects[i] = ProjectRecord(
                    id: manager.projects[i].id,
                    name: manager.projects[i].name,
                    date: manager.projects[i].date,
                    beadUsage: newUsages,
                    brandId: defaultBrand.id
                )
            }

            // 设置默认选中品牌
            manager.currentBrandId = defaultBrand.id

            // 保存迁移后的数据
            manager.saveData()
        }
        // 如果没有现有库存数据，不创建默认品牌，让用户自己创建
    }
}
