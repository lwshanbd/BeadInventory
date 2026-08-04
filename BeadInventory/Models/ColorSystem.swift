//
//  ColorSystem.swift
//  BeadInventory
//
//  品牌色号体系枚举 - 定义不同品牌使用的色号编码系统
//

import Foundation

enum ColorSystem: String, Codable, CaseIterable, Identifiable, Sendable {
    case mard = "MARD"
    case coco = "COCO"
    case manman = "漫漫"
    case panpan = "盼盼"
    case mixiaowo = "咪小窝"
    case kaka = "卡卡"

    var id: String { rawValue }
    var displayName: String { rawValue }

    /// 色系列表（用于系列选择器）
    /// 注意：值作为数据标识符使用，不可本地化。显示时通过 localizedSeriesName() 翻译。
    var colorSeries: [String] {
        switch self {
        case .kaka:
            return ["B", "P", "R", "其他", "#"]
        default:
            return ["A", "B", "C", "D", "E", "F", "G", "H", "M", "P", "Q", "R", "T", "Y", "ZG", "其他", "#"]
        }
    }

    /// 将色系标识符转换为本地化显示名称
    static func localizedSeriesName(_ series: String) -> String {
        if series == "其他" {
            return String(localized: "其他")
        }
        return series
    }

    /// 标准色系前缀
    var standardPrefixes: [String] {
        switch self {
        case .kaka:
            return ["B", "P", "R"]
        default:
            return ["A", "B", "C", "D", "E", "F", "G", "H", "M", "P", "Q", "R", "T", "Y", "ZG"]
        }
    }

    /// 默认选中的系列
    var defaultSeries: String {
        switch self {
        case .kaka:
            return "B"
        default:
            return "A"
        }
    }
}
