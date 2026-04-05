//
//  DeductionItem.swift
//  BeadInventory
//
//  扣减项数据结构：记录每个颜色的品牌分配状态
//

import Foundation

struct DeductionItem: Identifiable {
    let id: UUID
    var mardCode: String
    var colorCode: String
    var quantity: Int
    var brandId: UUID
    var isManualOverride: Bool

    var availableStock: Int
    var isInsufficient: Bool

    var originalMardCode: String?
    var originalColorCode: String?

    init(mardCode: String, colorCode: String, quantity: Int, brandId: UUID) {
        self.id = UUID()
        self.mardCode = mardCode
        self.colorCode = colorCode
        self.quantity = quantity
        self.brandId = brandId
        self.isManualOverride = false
        self.availableStock = 0
        self.isInsufficient = false
    }
}
