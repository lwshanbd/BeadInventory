//
//  AppTips.swift
//  BeadInventory
//
//  TipKit 提示定义
//

import TipKit

// MARK: - 扫描相关

struct ScanTip: Tip {
    var title: Text {
        Text("AI 智能识别")
    }
    var message: Text? {
        Text("拍照或选择色号统计图片，AI 自动识别色号和数量")
    }
    var image: Image? {
        Image(systemName: "doc.text.viewfinder")
    }
}

struct APISetupTip: Tip {
    @Parameter
    static var hasConfiguredAPI: Bool = false

    var title: Text {
        Text("先设置 AI 识别方式")
    }
    var message: Text? {
        Text("需要先配置本地模型或云端 API 才能使用扫描功能")
    }
    var image: Image? {
        Image(systemName: "gearshape.fill")
    }

    var rules: [Rule] {
        #Rule(Self.$hasConfiguredAPI) { $0 == false }
    }
}

// MARK: - 计划相关

struct PlanMergeTip: Tip {
    var title: Text {
        Text("合并计划更方便")
    }
    var message: Text? {
        Text("选中多个计划可以合并，一次性补豆更省心")
    }
    var image: Image? {
        Image(systemName: "arrow.triangle.merge")
    }
}

struct ReplenishTip: Tip {
    @Parameter
    static var hasUsedReplenish: Bool = false

    var title: Text {
        Text("试试补豆建议")
    }
    var message: Text? {
        Text("选中计划后点击「补豆建议」，自动计算每种颜色需要补多少")
    }
    var image: Image? {
        Image(systemName: "cart.fill")
    }

    var rules: [Rule] {
        #Rule(Self.$hasUsedReplenish) { $0 == false }
    }
}

// MARK: - 库存相关

struct ColorConverterTip: Tip {
    var title: Text {
        Text("不确定色号对应关系？")
    }
    var message: Text? {
        Text("去「更多」→「色号转换」查看不同品牌的色号对照")
    }
    var image: Image? {
        Image(systemName: "paintpalette.fill")
    }
}

// MARK: - 更多页相关

struct BackupTip: Tip {
    var title: Text {
        Text("记得备份数据")
    }
    var message: Text? {
        Text("定期备份可以防止数据意外丢失，去「数据与备份」导出")
    }
    var image: Image? {
        Image(systemName: "externaldrive.fill")
    }
}

struct ICloudSyncTip: Tip {
    var title: Text {
        Text("开启 iCloud 同步")
    }
    var message: Text? {
        Text("开启后数据自动在多设备之间同步备份")
    }
    var image: Image? {
        Image(systemName: "icloud.fill")
    }
}
