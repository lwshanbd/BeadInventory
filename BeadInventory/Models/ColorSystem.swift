//
//  ColorSystem.swift
//  BeadInventory
//
//  品牌色号体系枚举 - 定义不同品牌使用的色号编码系统
//

import Foundation

enum ColorSystem: String, Codable, CaseIterable, Identifiable {
    case mard = "MARD"
    case coco = "COCO"
    case manman = "漫漫"
    case panpan = "盼盼"
    case mixiaowo = "咪小窝"
    case kaka = "卡卡"

    var id: String { rawValue }
    var displayName: String { rawValue }

    /// 色系列表（用于系列选择器）
    var colorSeries: [String] {
        switch self {
        case .kaka:
            return ["B", "P", "R", "其他", "#"]
        default:
            return ["A", "B", "C", "D", "E", "F", "G", "H", "M", "P", "Q", "R", "T", "Y", "ZG", "其他", "#"]
        }
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
