//
//  ColorScheme.swift
//  BeadInventory
//
//  色彩模式：调色板与方案的内存模型。
//

import Foundation
import SwiftUI
import UIKit

typealias ColorHex = String   // "RRGGBB" 大写无前缀

struct ColorPalette: Codable, Equatable, Hashable {
    var bg:     ColorHex
    var bgElev: ColorHex
}

struct AppColorScheme: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String           // 内建：本地化 key；自定义：用户输入字符串
    var light: ColorPalette
    var dark:  ColorPalette
    var isBuiltin: Bool
    let createdAt: Date
    var updatedAt: Date
}

extension UIColor {
    /// 从 "RRGGBB" / "#RRGGBB" 解析。非法值返回 fallback（默认 systemBackground）。
    convenience init(themeHex hex: String, fallback: UIColor = .systemBackground) {
        let trimmed = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard trimmed.count == 6,
              let value = UInt32(trimmed, radix: 16) else {
            self.init(cgColor: fallback.cgColor)
            return
        }
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >>  8) & 0xFF) / 255.0
        let b = CGFloat( value        & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}

extension ColorPalette {
    static let defaultLight = ColorPalette(bg: "FAF5EC", bgElev: "FFFDF8")
    static let defaultDark  = ColorPalette(bg: "1B1714", bgElev: "25201B")
}
