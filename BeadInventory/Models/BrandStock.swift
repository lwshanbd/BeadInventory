//
//  BrandStock.swift
//  BeadInventory
//
//  品牌库存模型 - 记录某品牌下某颜色的库存
//

import Foundation

struct BrandStock: Identifiable, Codable, Hashable {
    let id: UUID
    let brandId: UUID          // 关联的品牌 ID
    let mardCode: String       // 使用 MARD 色号作为颜色的唯一标识
    var stock: Int             // 库存数量
    var used: Int              // 已使用数量

    var available: Int {
        stock - used
    }

    init(
        id: UUID = UUID(),
        brandId: UUID,
        mardCode: String,
        stock: Int = 1000,
        used: Int = 0
    ) {
        self.id = id
        self.brandId = brandId
        self.mardCode = mardCode
        self.stock = stock
        self.used = used
    }
}
