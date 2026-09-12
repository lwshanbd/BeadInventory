//
//  PartsBoardUsage.swift
//  BeadInventory
//
//  多零件模式 · 板上实际摆着多少颗豆子
//
//  计划里那份「每个色号多少颗」是扫描那步 AI 读色号表读出来的，是图纸**印着**的数。
//  多零件模式走完之后有一份更实在的数：每个零件切成了 rows × cols 格、每格的色号
//  用户在核对页一条一条看过、零件又一个一个摆上了板。板上现在摆着几颗，就是他真要
//  从盒子里抓几颗。所以排完板之后，扣库存按这边的数算。
//
//  ## 数的是板上的，不是图纸上的
//
//  没摆上板的零件不算（板子不够、或者用户故意先不拼那几个），同一个零件摆了两遍就
//  算两遍。这跟「这张图纸一共多少颗」是两个数，用户在拼豆板那一屏看到的「还有 N 个
//  未摆放」说的就是它们的差。
//
//  转向不影响颗数 —— 一个零件转 90° 还是那些格子，所以这里不碰 `PartPlacement.turns`，
//  也不用过 `PartFootprint`。
//

import Foundation

enum PartsBoardUsage {

    /// 「任意色」的格子最后扣到哪个色号上。
    ///
    /// 任意色在图纸上不是色号，是色号表里那一行「这里用什么颜色都行」。它得有个去处，
    /// 否则板上实实在在的几百颗豆子会从扣减单里凭空消失。约定是用户自己在
    /// 「更多 → 自定义色号」里建一个叫这个名字的色号，任意色就扣到它头上。
    /// 没建过也照样列出来 —— 扣不动会被记成「未扣减」，比一声不吭地少扣几百颗强。
    static let anyColorCode = "任意色"

    /// 格子里的「任意色」标识（`PartCellFill.groupKey`）
    static let anyColorGroupKey = "#any"

    /// 板上实际摆着的豆子：`PartCellFill.groupKey` → 颗数。还没排板子时是空的。
    static func placedCounts(in sheet: BeadPartsSheet) -> [String: Int] {
        guard let boards = sheet.boards, !boards.isEmpty else { return [:] }
        let partsById = Dictionary(sheet.parts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var counts: [String: Int] = [:]
        for board in boards {
            for placement in board.placements {
                guard let part = partsById[placement.partId] else { continue }
                for row in part.cells {
                    for cell in row where cell.needsBead {
                        counts[cell.groupKey, default: 0] += 1
                    }
                }
            }
        }
        return counts
    }

    /// 板上实际摆着的豆子 → 计划用量。
    ///
    /// - Parameter resolveCode: 把一个码翻成 canonical mardCode。格子里存的是
    ///   `displayCode(for: colorSystem)`（见 `PartsCellClassifier`），而 `beadUsage.colorCode`
    ///   存的永远是 mardCode —— 卡卡 / COCO 图纸上这两者不是一回事，不翻这一道会扣错颜色。
    ///   翻不动时返回 nil，原样留着：这条会以「未扣减」收场，用户看得见。
    ///
    ///   第二个参数说的是「这一条是任意色那一条」。**两者查法不一样**，所以必须分开告诉
    ///   调用方：任意色落在自定义色号上，本体系色表里根本没有它；而格子里的色号要按
    ///   图纸自己的体系解释。光看字符串区分不开 —— 图纸指定的任意色色号可以长得跟
    ///   一个合法的本体系色号一模一样。
    ///
    /// 排序按颗数从多到少（`BeadColorTally`），颗数一样时按色号 —— 扣减清单每次打开
    /// 都得是同一个次序，否则用户没法拿它跟上一次比。
    static func beadUsage(
        in sheet: BeadPartsSheet,
        resolveCode: (String, Bool) -> String?
    ) -> [BeadUsage] {
        let counts = placedCounts(in: sheet)
        guard !counts.isEmpty else { return [] }

        // 两个显示码翻到同一颗豆子上是可能的，合并掉；合并后仍按原来的次序排。
        var merged: [String: Int] = [:]
        var order: [String] = []
        for (key, count) in BeadColorTally.ordered(counts) {
            let isAnyColor = key == anyColorGroupKey
            let raw = isAnyColor ? (sheet.anyColorCode ?? anyColorCode) : key
            let code = resolveCode(raw, isAnyColor) ?? raw
            if merged[code] == nil { order.append(code) }
            merged[code, default: 0] += count
        }
        return order.map { BeadUsage(colorCode: $0, quantity: merged[$0] ?? 0) }
    }

    /// 两份用量说的是不是同一件事（色号 → 颗数一样）。
    /// 比的不是数组：`BeadUsage` 每造一次都是新 id，按元素比永远不相等，
    /// 那样每存一次进度都会白记一条历史、白写一次库。
    static func isSameUsage(_ lhs: [BeadUsage], _ rhs: [BeadUsage]) -> Bool {
        func table(_ usages: [BeadUsage]) -> [String: Int] {
            usages.reduce(into: [:]) { $0[$1.colorCode, default: 0] += $1.quantity }
        }
        return table(lhs) == table(rhs)
    }
}
