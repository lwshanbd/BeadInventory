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
        Text("tip.scan.title")
    }
    var message: Text? {
        Text("tip.scan.message")
    }
    var image: Image? {
        Image(systemName: "doc.text.viewfinder")
    }
}

struct APISetupTip: Tip {
    @Parameter
    static var hasConfiguredAPI: Bool = false

    var title: Text {
        Text("tip.apisetup.title")
    }
    var message: Text? {
        Text("tip.apisetup.message")
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
        Text("tip.planmerge.title")
    }
    var message: Text? {
        Text("tip.planmerge.message")
    }
    var image: Image? {
        Image(systemName: "arrow.triangle.merge")
    }
}

struct ReplenishTip: Tip {
    @Parameter
    static var hasUsedReplenish: Bool = false

    var title: Text {
        Text("tip.replenish.title")
    }
    var message: Text? {
        Text("tip.replenish.message")
    }
    var image: Image? {
        Image(systemName: "cart.fill")
    }

    var rules: [Rule] {
        #Rule(Self.$hasUsedReplenish) { $0 == false }
    }
}

// MARK: - 更多页相关

struct BackupTip: Tip {
    var title: Text {
        Text("tip.backup.title")
    }
    var message: Text? {
        Text("tip.backup.message")
    }
    var image: Image? {
        Image(systemName: "externaldrive.fill")
    }
}

