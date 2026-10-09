//
//  PartsCellEnclosure.swift
//  BeadInventory
//
//  多零件模式 - 哪些格子是「被线围死的一格」
//
//  ## 为什么需要这一步
//
//  判「空」原来只看颜色：跟图纸底色差得不多就算空。可白色、米色、浅肉色的豆子
//  跟白纸在颜色上本来就分不开（白豆子和白纸差 0~2），于是零件里整片浅色豆子被判成空，
//  用户在核对页看到的是「脸没了」。调阈值救不回来。
//
//  能分开它们的是图纸的结构：每颗豆子都被格线单独围成一个小方块；零件外面的白纸
//  连成一大片，一直通到零件框外面；镂空也连成一片，跨好几格。所以把「深色的线」
//  当成墙，看每一格里的空白跟谁连在一起：
//
//  - 连到零件框边上 → 零件外面的白纸，空；
//  - 自己跨了两格以上 → 镂空，空；
//  - 只有一格大、被线围死 → 豆子。
//
//  格子里印的色号字也是深色的，同样当成墙。它只会把一格里的空白切碎，不会把两格连起来，
//  所以碰不到结论。也不用判断线是粗是细 —— 那一套试过，图一缩小粗线就糊得跟细线一样宽。
//
//  ## 已知分不开的
//
//  单格的小镂空（零件中间一个格子大的方孔）也是「被线围死的一格」，会被当成豆子。
//  试过看外圈是不是粗线、看空白有多大，都会连带误伤大量真豆子，不值得。用户在核对页改。
//

import Foundation

enum PartsCellEnclosure {

    /// 比底色暗这么多（Lab 的 L）的像素当成线。
    /// 格线和色号字都是黑的，跟白纸差 60 往上；浅色豆子跟白纸只差几个到十几个，
    /// 不会被当成线。底色是深色的图纸（棕色底）上，豆子比底色亮，同样不会被当成线。
    private static let lineDarkerThanBackground: Double = 30

    /// 每一格是不是「被线围死、只有一格大」。`[行][列]`。
    ///
    /// - Parameters:
    ///   - bitmap: 这个零件格子区（`gridRect`）的位图，跟 `sampleModes` 用的是同一张
    ///   - backgroundLab: 图纸底色。线是「比它暗得多」的像素
    static func enclosedCells(bitmap: PartsBitmap, rows: Int, cols: Int,
                              backgroundLab: LabColor) -> [[Bool]] {
        let w = bitmap.width, h = bitmap.height
        var result = [[Bool]](repeating: [Bool](repeating: false, count: max(cols, 0)), count: max(rows, 0))
        guard rows > 0, cols > 0, w > 2, h > 2 else { return result }

        // 1. 线。每个量化桶只判一次。
        let threshold = backgroundLab.l - lineDarkerThanBackground
        var isLineBucket = [Bool](repeating: false, count: QuantizedRGB.count)
        for i in 0..<QuantizedRGB.count {
            isLineBucket[i] = QuantizedRGB.labTable[i].l < threshold
        }
        var line = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) where isLineBucket[Int(bitmap.quantized[i])] {
            line[i] = true
        }
        // 往外扩 1 像素：图缩小以后 1 像素的细格线会被糊出缺口，空白从缺口漏过去，
        // 两颗豆子就连成一块、一起被判成空。扩一圈把缺口补上。
        var wall = line
        for y in 0..<h {
            for x in 0..<w where line[y * w + x] {
                if x > 0 { wall[y * w + x - 1] = true }
                if x < w - 1 { wall[y * w + x + 1] = true }
                if y > 0 { wall[(y - 1) * w + x] = true }
                if y < h - 1 { wall[(y + 1) * w + x] = true }
            }
        }

        // 2. 空白分块（4 连通），记下每块有没有碰到位图边。
        var label = [Int32](repeating: 0, count: w * h)
        var touchesBorder: [Bool] = [false]   // 下标是块号，0 号不用
        var stack: [Int] = []
        var next: Int32 = 0
        for start in 0..<(w * h) where !wall[start] && label[start] == 0 {
            next += 1
            var border = false
            label[start] = next
            stack.append(start)
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { border = true }
                @inline(__always) func visit(_ n: Int) {
                    if !wall[n] && label[n] == 0 {
                        label[n] = next
                        stack.append(n)
                    }
                }
                if x > 0 { visit(i - 1) }
                if x < w - 1 { visit(i + 1) }
                if y > 0 { visit(i - w) }
                if y < h - 1 { visit(i + w) }
            }
            touchesBorder.append(border)
        }

        // 3. 每格看中间那一小块落在哪块空白里（取最多的那块）。
        //    字大到把中间整块盖住时，扩大到整格（去掉四边的线）再找。
        let cellW = Double(w) / Double(cols)
        let cellH = Double(h) / Double(rows)
        var cellLabel = [[Int32]](repeating: [Int32](repeating: 0, count: cols), count: rows)
        var cellsPerLabel: [Int32: Int] = [:]
        var counts: [Int32: Int] = [:]
        func dominantLabel(r: Int, c: Int, from lo: Double, to hi: Double) -> Int32? {
            let x0 = max(0, Int((Double(c) + lo) * cellW))
            let x1 = min(w - 1, Int((Double(c) + hi) * cellW))
            let y0 = max(0, Int((Double(r) + lo) * cellH))
            let y1 = min(h - 1, Int((Double(r) + hi) * cellH))
            guard x1 >= x0, y1 >= y0 else { return nil }
            counts.removeAll(keepingCapacity: true)
            for y in y0...y1 {
                for x in x0...x1 {
                    let l = label[y * w + x]
                    if l > 0 { counts[l, default: 0] += 1 }
                }
            }
            return counts.max(by: { $0.value < $1.value })?.key
        }
        for r in 0..<rows {
            for c in 0..<cols {
                guard let winner = dominantLabel(r: r, c: c, from: 0.3, to: 0.7)
                        ?? dominantLabel(r: r, c: c, from: 0.15, to: 0.85) else { continue }
                cellLabel[r][c] = winner
                cellsPerLabel[winner, default: 0] += 1
            }
        }

        for r in 0..<rows {
            for c in 0..<cols {
                let l = cellLabel[r][c]
                guard l > 0 else { continue }
                result[r][c] = !touchesBorder[Int(l)] && cellsPerLabel[l] == 1
            }
        }
        return result
    }
}
