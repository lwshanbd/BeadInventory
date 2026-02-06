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
}
