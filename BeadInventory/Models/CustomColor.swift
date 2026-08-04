//
//  CustomColor.swift
//  BeadInventory
//
//  自定义色号模型 - 用户可以添加自己的颜色
//

import Foundation
import SwiftUI

/// 自定义色号模型
struct CustomColor: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var colorCode: String       // 用户定义的色号（如 "MY01"）
    var colorHex: String        // 颜色十六进制值（如 "FF5733"）
    var colorName: String       // 颜色名称（如 "珊瑚红"）
    var createdAt: Date         // 创建时间
    var updatedAt: Date         // 更新时间

    init(
        id: UUID = UUID(),
        colorCode: String,
        colorHex: String,
        colorName: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.colorCode = colorCode
        self.colorHex = colorHex
        self.colorName = colorName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 获取 SwiftUI Color
    var color: Color {
        Color(hex: colorHex)
    }

    /// 转换为 BeadColor 格式，方便在现有系统中使用
    /// 自定义色号使用 "#" 前缀以区分于预设颜色，并使其排序在最后
    var mardCode: String {
        "#\(colorCode)"
    }

    /// 转换为 BeadColor
    func toBeadColor(stock: Int = 0, used: Int = 0) -> BeadColor {
        BeadColor(
            id: id,
            colorHex: colorHex,
            mardCode: mardCode,
            cocoCode: colorCode,
            manmanCode: colorCode,
            panpanCode: colorCode,
            mixiaowoCode: colorCode,
            kakaCode: colorCode,
            colorName: colorName,
            stock: stock,
            used: used
        )
    }
}
