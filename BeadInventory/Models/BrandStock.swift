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
    var isHidden: Bool         // 是否隐藏（隐藏的色号不显示在库存列表中）

    var available: Int {
        stock - used
    }

    init(
        id: UUID = UUID(),
        brandId: UUID,
        mardCode: String,
        stock: Int = 1000,
        used: Int = 0,
        isHidden: Bool = false
    ) {
        self.id = id
        self.brandId = brandId
        self.mardCode = mardCode
        self.stock = stock
        self.used = used
        self.isHidden = isHidden
    }

    // 自定义解码器以支持向后兼容（旧数据没有 isHidden 字段）
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        brandId = try container.decode(UUID.self, forKey: .brandId)
        mardCode = try container.decode(String.self, forKey: .mardCode)
        stock = try container.decode(Int.self, forKey: .stock)
        used = try container.decode(Int.self, forKey: .used)
        // 向后兼容：旧数据没有 isHidden 字段时默认为 false
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
    }
}
