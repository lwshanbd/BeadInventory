//
//  PartsSheetUsage.swift
//  BeadInventory
//
//  多零件模式 · 核对完颜色之后，每个色号一共要几颗
//
//  计划里那份「每个色号多少颗」是扫描那步 AI 读色号表读出来的，是图纸上印着的数，
//  AI 会读错。多零件模式里用户把每个零件切成格子、一格一格对过颜色，对完是多少就是多少。
//  所以格子判完色之后，计划的用量换成格子里数出来的颗数，扣库存按它扣。
//
//  ## 数的是所有零件的格子 × 要拼几份，跟摆没摆上板无关
//
//  拼豆板那一屏只管「这些零件分几块板烫」，一个零件摆不摆、摆在第几块板上，都不改变这张图纸
//  要用多少颗豆子。早先这里按板上的摆位数，结果取下零件扣减数就跟着变，是错的。
//
//  份数是另一回事：用户在板上点「复制」，是想多拼一个（图纸上只画了一只耳朵），多拼的那份
//  豆子是真要用掉的。所以乘的是 `BeadPart.copyCount` —— 它记在零件上，取下一份只是把它放回
//  零件条待会儿再摆，份数不变，扣减也不变。
//
//  ## 跟核对颜色那一屏数的是同一种数法
//
//  核对页把所有零件现有的格子加起来（`PartsColorReviewStepView.groups`），这里照抄这个数法，
//  没有复制过零件时，用户在核对页看到几颗，计划就是几颗。复制了的话计划会多出那几份：
//  核对页是拿来跟图纸上印的数对的，图纸上可没画多拼的那份。还没划网格的零件没有格子，两边都不算。
//
//  ## 有零件等着重新判色时不算
//
//  「量格子」那屏重调一个零件的网格，会把它的格子清掉，回到核对页时再补判
//  （`PartsSheetFlowView.classifyMissingParts`）。中间这段时间数出来缺一块，拿去改计划会少扣。
//  所以只要有零件划好了网格却没有格子，这次就不给答案，计划保持原样。
//

import Foundation

enum PartsSheetUsage {

    /// 一个待翻译的码是从哪来的。两者查法不一样，见 `beadUsage` 的参数说明。
    enum CodeSource {
        /// 格子里的色号，按图纸自己的体系解释
        case cellCode
        /// 任意色要扣到的那个色号
        case anyColor
    }

    /// 任意色的格子扣到哪个色号上。
    ///
    /// 任意色在图纸上不是色号，是色号表里那一行「这里用什么颜色都行」。它得有个去处，
    /// 否则那几百颗豆子会从扣减单里凭空消失。约定是用户自己在「更多 → 自定义色号」里
    /// 建一个叫这个名字的色号，任意色就扣到它上面。没建过也照样列出来：执行扣减那一屏
    /// 这一行会显示库存不足，不会一声不吭地少扣。
    static let anyColorCode = "任意色"

    /// 所有零件的格子里，每类格子有几颗（`PartCellFill.groupKey` → 颗数，不含空格）。
    /// 复制过的零件乘上要拼的份数，理由见文件头。
    ///
    /// 一个判过色的零件都没有、或者有零件等着补判色时返回 nil，理由见文件头。
    static func cellCounts(in sheet: BeadPartsSheet) -> [String: Int]? {
        let awaitingJudgement = sheet.parts.contains { $0.rows > 0 && $0.cols > 0 && !$0.hasCells }
        guard !awaitingJudgement, sheet.parts.contains(where: \.hasCells) else { return nil }
        var counts: [String: Int] = [:]
        for part in sheet.parts {
            let times = part.copyCount
            for row in part.cells {
                for cell in row where cell.needsBead {
                    counts[cell.groupKey, default: 0] += times
                }
            }
        }
        return counts
    }

    /// 格子颗数 → 计划用量。
    ///
    /// - Parameters:
    ///   - anyColorCode: 任意色扣到哪个色号上，一般传 `sheet.anyColorCode ?? Self.anyColorCode`。
    ///   - resolveCode: 把一个码翻成 canonical mardCode。`beadUsage.colorCode` 存的永远是
    ///     mardCode，而格子里存的是 `displayCode(for: colorSystem)`（见 `PartsCellClassifier`）。
    ///     卡卡、COCO 图纸上这两者不是一回事，不翻会扣错颜色。
    ///     任意色那一条要单独查：它落在自定义色号上，本体系色表里没有它。
    ///     翻不出来时返回 nil，这个码原样写进用量。
    ///
    /// 排序按颗数从多到少，颗数一样按色号（`BeadColorTally`），排的是翻译之前的码。
    /// 两个码翻到同一颗豆子上时合成一条，合并后不重排。
    static func beadUsage(
        from counts: [String: Int],
        anyColorCode: String,
        resolveCode: (_ code: String, _ source: CodeSource) -> String?
    ) -> [BeadUsage] {
        let anyKey = PartCellFill.anyColor.groupKey
        var merged: [String: Int] = [:]
        var order: [String] = []
        for (key, count) in BeadColorTally.ordered(counts) where count > 0 {
            let source: CodeSource = key == anyKey ? .anyColor : .cellCode
            let raw = source == .anyColor ? anyColorCode : key
            let code = resolveCode(raw, source) ?? raw
            if merged[code] == nil { order.append(code) }
            merged[code, default: 0] += count
        }
        return order.map { BeadUsage(colorCode: $0, quantity: merged[$0] ?? 0) }
    }

    /// 两份用量说的是不是同一件事（色号 → 颗数一样）。
    /// 不直接比数组：`BeadUsage` 每造一次都是新 id，按元素比永远不相等。
    static func isSameUsage(_ lhs: [BeadUsage], _ rhs: [BeadUsage]) -> Bool {
        func table(_ usages: [BeadUsage]) -> [String: Int] {
            usages.reduce(into: [:]) { $0[$1.colorCode, default: 0] += $1.quantity }
        }
        return table(lhs) == table(rhs)
    }
}
