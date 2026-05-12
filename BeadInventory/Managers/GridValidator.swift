//
//  GridValidator.swift
//  BeadInventory
//
//  对比 BeadPatternGrid.cellColorCodes 与 ProjectRecord.beadUsage，输出差异。
//

import Foundation

struct GridValidationDiff: Equatable, Identifiable {
    var id: String { code }
    let code: String
    let gridCount: Int      // 网格识别出的数量
    let legendCount: Int    // beadUsage 里登记的数量

    var delta: Int { gridCount - legendCount }
    var isMatch: Bool { delta == 0 }
}

enum GridValidator {
    /// 返回所有 code 的对比，按 |delta| 降序。code 来自二者并集。
    static func compare(grid: BeadPatternGrid, beadUsage: [BeadUsage]) -> [GridValidationDiff] {
        var gridCounts: [String: Int] = [:]
        for row in grid.cellColorCodes {
            for cell in row {
                guard let c = cell else { continue }
                gridCounts[c, default: 0] += 1
            }
        }
        var legendCounts: [String: Int] = [:]
        for usage in beadUsage {
            legendCounts[usage.colorCode, default: 0] += usage.quantity
        }

        let allCodes = Set(gridCounts.keys).union(legendCounts.keys)
        let diffs = allCodes.map { code in
            GridValidationDiff(
                code: code,
                gridCount: gridCounts[code] ?? 0,
                legendCount: legendCounts[code] ?? 0
            )
        }
        return diffs.sorted { abs($0.delta) > abs($1.delta) }
    }

    /// 取只有差异的项。
    static func mismatches(grid: BeadPatternGrid, beadUsage: [BeadUsage]) -> [GridValidationDiff] {
        compare(grid: grid, beadUsage: beadUsage).filter { !$0.isMatch }
    }
}
