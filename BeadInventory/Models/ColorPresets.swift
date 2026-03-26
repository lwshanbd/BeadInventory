//
//  ColorPresets.swift
//  BeadInventory
//
//  颜色预设数据 - 从 color.xlsx 提取
//

import Foundation

/// 颜色预设模式
enum ColorPreset: String, CaseIterable, Identifiable {
    case all = "全部颜色"
    case colors221 = "全部色"
    case colors144 = "144色"
    case colors120 = "120色"
    case colors96 = "96色"
    case colors72 = "72色"
    case custom = "自定义"

    var id: String { rawValue }

    /// 本地化显示名称（rawValue 用作枚举标识，不可修改）
    var displayName: String {
        switch self {
        case .all: return String(localized: "全部颜色")
        case .colors221: return String(localized: "全部色")
        case .colors144: return String(localized: "144色")
        case .colors120: return String(localized: "120色")
        case .colors96: return String(localized: "96色")
        case .colors72: return String(localized: "72色")
        case .custom: return String(localized: "自定义")
        }
    }

    /// 预设描述
    var description: String {
        switch self {
        case .all: return String(localized: "包含所有291种颜色")
        case .colors221: return String(localized: "221种常用实色")
        case .colors144: return String(localized: "常用颜色")
        case .colors120: return String(localized: "精选颜色")
        case .colors96: return String(localized: "基础颜色")
        case .colors72: return String(localized: "入门颜色")
        case .custom: return String(localized: "自选颜色")
        }
    }

    /// 获取预设包含的色号集合，nil 表示全选（所有颜色）
    var colorCodes: Set<String>? {
        switch self {
        case .all:
            return nil // nil 表示全选所有颜色
        case .colors221:
            return ColorPresetData.colors221
        case .colors144:
            return ColorPresetData.colors144
        case .colors120:
            return ColorPresetData.colors120
        case .colors96:
            return ColorPresetData.colors96
        case .colors72:
            return ColorPresetData.colors72
        case .custom:
            return nil // 自定义模式由用户选择
        }
    }

    /// 预设颜色数量（0 表示动态数量）
    var count: Int {
        switch self {
        case .all: return 291
        case .colors221: return 221
        case .colors144: return 144
        case .colors120: return 120
        case .colors96: return 96
        case .colors72: return 72
        case .custom: return 0
        }
    }

    /// 是否为自定义模式
    var isCustom: Bool {
        self == .custom
    }

    /// 是否为全选模式
    var isAll: Bool {
        self == .all
    }
}

// MARK: - 颜色预设数据
/// 从 color.xlsx 提取的预设色号数据
enum ColorPresetData {
    /// 221色（全部颜色）
    static let colors221: Set<String> = [
        "A1", "A2", "A3", "A4", "A5", "A6", "A7", "A8", "A9", "A10",
        "A11", "A12", "A13", "A14", "A15", "A16", "A17", "A18", "A19", "A20",
        "A21", "A22", "A23", "A24", "A25", "A26",
        "B1", "B2", "B3", "B4", "B5", "B6", "B7", "B8", "B9", "B10",
        "B11", "B12", "B13", "B14", "B15", "B16", "B17", "B18", "B19", "B20",
        "B21", "B22", "B23", "B24", "B25", "B26", "B27", "B28", "B29", "B30",
        "B31", "B32",
        "C1", "C2", "C3", "C4", "C5", "C6", "C7", "C8", "C9", "C10",
        "C11", "C12", "C13", "C14", "C15", "C16", "C17", "C18", "C19", "C20",
        "C21", "C22", "C23", "C24", "C25", "C26", "C27", "C28", "C29",
        "D1", "D2", "D3", "D4", "D5", "D6", "D7", "D8", "D9", "D10",
        "D11", "D12", "D13", "D14", "D15", "D16", "D17", "D18", "D19", "D20",
        "D21", "D22", "D23", "D24", "D25", "D26",
        "E1", "E2", "E3", "E4", "E5", "E6", "E7", "E8", "E9", "E10",
        "E11", "E12", "E13", "E14", "E15", "E16", "E17", "E18", "E19", "E20",
        "E21", "E22", "E23", "E24",
        "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10",
        "F11", "F12", "F13", "F14", "F15", "F16", "F17", "F18", "F19", "F20",
        "F21", "F22", "F23", "F24", "F25",
        "G1", "G2", "G3", "G4", "G5", "G6", "G7", "G8", "G9", "G10",
        "G11", "G12", "G13", "G14", "G15", "G16", "G17", "G18", "G19", "G20",
        "G21",
        "H1", "H2", "H3", "H4", "H5", "H6", "H7", "H8", "H9", "H10",
        "H11", "H12", "H13", "H14", "H15", "H16", "H17", "H18", "H19", "H20",
        "H21", "H22", "H23",
        "M1", "M2", "M3", "M4", "M5", "M6", "M7", "M8", "M9", "M10",
        "M11", "M12", "M13", "M14", "M15"
    ]

    /// 144色
    static let colors144: Set<String> = [
        "A1", "A2", "A3", "A4", "A5", "A6", "A7", "A8", "A9", "A10",
        "A11", "A12", "A13", "A14", "A15",
        "B1", "B2", "B3", "B4", "B5", "B6", "B7", "B8", "B10",
        "B11", "B12", "B13", "B14", "B15", "B16", "B17", "B18", "B19", "B20",
        "C1", "C2", "C3", "C4", "C5", "C6", "C7", "C8", "C9", "C10",
        "C11", "C13", "C14", "C15", "C16", "C17",
        "D1", "D2", "D3", "D5", "D6", "D7", "D8", "D9",
        "D11", "D12", "D13", "D14", "D15", "D16", "D17", "D18", "D19", "D20",
        "D21",
        "E1", "E2", "E3", "E4", "E5", "E6", "E7", "E8", "E9", "E10",
        "E11", "E12", "E13", "E14", "E15",
        "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10",
        "F11", "F12", "F13", "F14",
        "G1", "G2", "G3", "G4", "G5", "G6", "G7", "G8", "G9", "G10",
        "G11", "G12", "G13", "G14", "G15", "G16", "G17",
        "H1", "H2", "H3", "H4", "H5", "H6", "H7", "H8", "H9", "H10",
        "H11", "H12", "H13", "H14",
        "M1", "M2", "M3", "M4", "M5", "M6", "M7", "M8", "M9", "M10",
        "M11", "M12", "M13", "M14", "M15"
    ]

    /// 120色
    static let colors120: Set<String> = [
        "A1", "A3", "A4", "A5", "A6", "A7", "A8", "A9", "A10",
        "A11", "A12", "A13", "A14", "A15",
        "B1", "B2", "B3", "B4", "B5", "B6", "B7", "B8", "B10",
        "B11", "B12", "B13", "B14", "B15", "B16", "B17", "B18", "B19", "B20",
        "C1", "C2", "C3", "C4", "C5", "C6", "C7", "C8", "C9", "C10",
        "C11", "C13", "C14", "C15", "C16", "C17",
        "D1", "D2", "D3", "D5", "D6", "D7", "D8", "D9",
        "D11", "D12", "D13", "D14", "D15", "D16", "D17", "D18", "D19", "D20",
        "D21",
        "E1", "E2", "E3", "E4", "E5", "E6", "E7", "E8", "E9", "E10",
        "E11", "E12", "E13", "E14", "E15",
        "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10",
        "F11", "F12", "F13", "F14",
        "G1", "G2", "G3", "G5", "G6", "G7", "G8", "G9",
        "G13", "G14", "G17",
        "H1", "H2", "H3", "H4", "H5", "H6", "H7", "H12",
        "M5", "M6", "M9", "M12"
    ]

    /// 96色
    static let colors96: Set<String> = [
        "A3", "A4", "A6", "A7", "A10", "A11", "A13", "A14",
        "B3", "B5", "B7", "B8", "B10", "B12", "B14", "B17", "B18", "B19", "B20",
        "C2", "C3", "C5", "C6", "C7", "C8", "C10", "C11", "C13", "C16",
        "D2", "D3", "D5", "D6", "D7", "D8", "D9",
        "D11", "D12", "D13", "D14", "D15", "D16", "D18", "D19", "D20", "D21",
        "E1", "E2", "E3", "E4", "E5", "E6", "E7", "E8", "E9", "E10",
        "E11", "E12", "E13", "E14", "E15",
        "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10",
        "F11", "F12", "F13", "F14",
        "G1", "G2", "G3", "G5", "G7", "G8", "G9", "G13", "G14", "G17",
        "H1", "H2", "H3", "H4", "H5", "H6", "H7",
        "M5", "M6", "M9", "M12"
    ]

    /// 72色
    static let colors72: Set<String> = [
        "A3", "A4", "A6", "A7", "A10", "A11", "A13",
        "B3", "B5", "B7", "B8", "B10", "B12", "B14", "B17", "B18", "B19", "B20",
        "C2", "C3", "C5", "C6", "C7", "C8", "C10", "C11", "C13", "C16",
        "D2", "D3", "D6", "D7", "D8", "D9",
        "D11", "D12", "D13", "D14", "D15", "D16", "D18", "D19", "D20", "D21",
        "E1", "E2", "E3", "E4", "E5", "E7", "E8", "E12", "E13",
        "F5", "F7", "F8", "F10", "F13",
        "G1", "G2", "G3", "G5", "G7", "G8", "G9", "G13",
        "H1", "H2", "H3", "H4", "H5", "H7"
    ]
}
