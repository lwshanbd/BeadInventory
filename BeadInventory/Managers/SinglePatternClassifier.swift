//
//  SinglePatternClassifier.swift
//  BeadInventory
//
//  单图纸模式 - 每一格是什么色号
//
//  两条线索，缺一不可：
//
//    颜色  跟多零件模式走同一套（`PartsCellClassifier`）：先把几千格的颜色聚成十几类，
//          一类整体配一个色号。同一片色块必然判成同一个结果，用户改一次改一整片。
//    字    平面图纸大多在每个格子里印着色号（「H7」「E12」）。这是图纸作者亲手写的答案，
//          比任何配色算法都准 —— 尤其是 E2/E3 这种在色彩上本来就挨着的近邻色。
//
//  所以颜色先跑，OCR 再跑一遍，**两边一致才采纳 OCR**（ΔE < 25）。OCR 会把 H7 看成 H2、
//  把 8 看成 B，光信它就会在图上留下一格格突兀的孤点；而光信颜色，近邻色分不开。
//  一致才改的规矩下，两种错都得同时犯才漏得过去。
//
//  ## 先探一下这张图纸到底有没有印字
//
//  逐格 OCR 是按格子数收费的：一张 120×90 的图纸就是一万次识别。而**很多图纸压根不印字**
//  （纯色块图、拍下来的成品照），那一万次一个字也认不出来，用户白等好几分钟。
//
//  所以先在整张图上均匀挑几十格试认一下：一格色号都对不上就直接收工，别再跑全量。
//  探测本身几秒钟，代价远小于它挡掉的那几分钟。
//

import UIKit

enum SinglePatternClassifier {

    /// 进度。文案由界面层决定 —— 这里不生产给用户看的句子。
    enum Phase {
        /// 正在看每格什么颜色
        case colors
        /// 正在试探图纸上有没有印色号
        case probing
        /// 正在逐格认色号（已完成 / 总数）
        case reading(done: Int, total: Int)
    }

    struct Result {
        /// 填好 rows / cols / gridRect / cells 的图纸
        var sheet: BeadPart
        /// 图根本没抠出来（框太小 / 图坏了）—— 一格都没看到。
        ///
        /// **必须跟「整张都是底色」分开**：两者在 `cells` 上长得一模一样（全是 `.empty`），
        /// 而用户看到的会是一句「一共 0 颗」，他没做错任何事，也不知道该改哪儿。
        var unreadable: Bool
        /// OCR 最终改掉了多少格。0 = 这张图纸没印色号，或者印的字跟颜色对不上（那就不采纳）。
        var ocrAdopted: Int
    }

    /// 逐格判色。耗时在秒到分钟级（取决于格子数和图纸有没有印字），调用方请放后台。
    static func classify(
        work: PartsWorkImage,
        sheet: BeadPart,
        calibration: PartsGridCalibration,
        colorSystem: ColorSystem,
        legendCodes: [String],
        availableColors: [BeadColor],
        emptyHex: String?,
        progress: ((Phase) -> Void)? = nil
    ) async -> Result {
        let area = sheet.gridRect ?? sheet.bounds
        progress?(.colors)

        let base = await Task.detached(priority: .userInitiated) {
            PartsCellClassifier.classify(
                work: work,
                parts: [sheet],
                roi: area,
                calibration: calibration,
                colorSystem: colorSystem,
                legendCodes: legendCodes,
                availableColors: availableColors,
                emptyHex: emptyHex,
                // 单图纸模式没有「任意色」这一档：它是立体图纸色号表里的一行字，
                // 平面图纸上不存在。判色时少一档，核对页也就少一个用户永远用不到的按钮。
                anyColorHex: nil
            )
        }.value

        guard var part = base.parts.first, part.rows > 0, part.cols > 0 else {
            return Result(sheet: sheet, unreadable: true, ocrAdopted: 0)
        }
        guard base.unreadableParts == 0 else {
            return Result(sheet: part, unreadable: true, ocrAdopted: 0)
        }

        let read = await readPrintedCodes(
            work: work,
            part: part,
            cellLabs: base.cellLabs.first ?? [],
            colorSystem: colorSystem,
            legendCodes: legendCodes,
            availableColors: availableColors,
            progress: progress
        )
        part.cells = read.cells
        return Result(sheet: part, unreadable: false, ocrAdopted: read.adopted)
    }

    // MARK: - 认格子里印着的字

    /// OCR 结果跟这一格实际颜色的最大容许色差。
    ///
    /// 25 是「同一族的深浅变化」和「跨族」的分界：H7 认成 H2（黑 vs 白）会被挡下来，
    /// E2 认成 E3（相邻色阶）放过去 —— 后者正是颜色分不开、要靠字来定的那一类。
    private static let verifyDeltaE: Double = 25

    /// 试探阶段最多认多少格
    private static let probeCells = 60
    /// 试探里至少要认出几格才值得跑全量
    private static let probeHits = 3

    /// 逐格 OCR，跟颜色一致的才写回去。
    /// - Returns: 改过之后的格子矩阵，以及真正改掉的格数。
    private static func readPrintedCodes(
        work: PartsWorkImage,
        part: BeadPart,
        cellLabs: [[LabColor?]],
        colorSystem: ColorSystem,
        legendCodes: [String],
        availableColors: [BeadColor],
        progress: ((Phase) -> Void)?
    ) async -> (cells: [[PartCellFill]], adopted: Int) {
        var cells = part.cells
        // 图纸没写用色表就没有「允许的色号」，OCR 认出来的字也就没有东西可比对。
        let allowed = Set(legendCodes)
        guard !allowed.isEmpty, let area = part.gridRect else { return (cells, 0) }

        // OCR 拿到的坐标系是「传进去的那张图」，而 gridRect 是相对整张图纸的 ——
        // 工作图多半只是图纸的一块，不翻译过去每一格都会裁到隔壁去。
        let local = work.localRect(area)
        let probe = BeadPatternGrid(
            corners: GridCorners(
                topLeft: CGPoint(x: local.minX, y: local.minY),
                topRight: CGPoint(x: local.maxX, y: local.minY),
                bottomLeft: CGPoint(x: local.minX, y: local.maxY),
                bottomRight: CGPoint(x: local.maxX, y: local.maxY)
            ),
            rows: part.rows, cols: part.cols,
            cellColorCodes: [],
            lastCalibratedAt: Date(),
            sourceImageSize: work.image.size,
            colorSystem: colorSystem
        )

        var codeToLab: [String: LabColor] = [:]
        for color in availableColors where color.hasCode(for: colorSystem) {
            if let lab = GridCellSampler.lab(forHex: color.colorHex) {
                codeToLab[color.displayCode(for: colorSystem)] = lab
            }
        }

        progress?(.probing)
        guard await hasPrintedCodes(work: work, grid: probe, allowed: allowed, codeToLab: codeToLab) else {
            return (cells, 0)
        }

        let total = part.rows * part.cols
        progress?(.reading(done: 0, total: total))
        let ocr = await GridOCRSampler.shared.sampleAllCellsPerCell(
            image: work.image,
            grid: probe,
            allowedCodes: allowed,
            cellLabs: cellLabs.isEmpty ? nil : cellLabs,
            codeToLab: codeToLab,
            progress: { done, count in
                // 每 50 格报一次：一万格的图纸每格都报一次，光切主线程就够慢的
                if done == 1 || done % 50 == 0 || done == count {
                    progress?(.reading(done: done, total: count))
                }
            }
        )

        var adopted = 0
        for r in 0..<part.rows {
            for c in 0..<part.cols {
                guard r < ocr.count, c < ocr[r].count, let code = ocr[r][c],
                      r < cells.count, c < cells[r].count else { continue }
                // 认出来的字得跟这一格**图上真实的颜色**对得上才采纳。
                // 对不上说明八成是看错了（H7 看成 H2），留着颜色那边的结论。
                guard r < cellLabs.count, c < cellLabs[r].count,
                      let lab = cellLabs[r][c],
                      let printed = codeToLab[code],
                      GridCellSampler.deltaE(lab, printed) < verifyDeltaE else { continue }
                guard cells[r][c] != .code(code) else { continue }
                cells[r][c] = .code(code)
                adopted += 1
            }
        }
        return (cells, adopted)
    }

    /// 在整张图上均匀挑几十格试认一下，看这张图纸到底有没有印色号。
    /// 均匀挑而不是取开头一片：图纸左上角常常是一大片背景，取那儿只会得出「没印字」。
    private static func hasPrintedCodes(
        work: PartsWorkImage,
        grid: BeadPatternGrid,
        allowed: Set<String>,
        codeToLab: [String: LabColor]
    ) async -> Bool {
        guard let cg = work.image.cgImage else { return false }
        let total = grid.rows * grid.cols
        guard total > 0 else { return false }
        // 格子本来就不多的图纸直接跑全量 —— 探测省下来的那点时间还不够它自己花的
        guard total > probeCells * 4 else { return true }

        let stride = max(1, total / probeCells)
        let width = CGFloat(cg.width)
        let height = CGFloat(cg.height)
        return await Task.detached(priority: .userInitiated) {
            var hits = 0
            var index = stride / 2
            while index < total {
                let code = GridOCRSampler.ocrSingleCell(
                    cgImage: cg,
                    row: index / grid.cols, col: index % grid.cols,
                    grid: grid,
                    imageWidth: width, imageHeight: height,
                    allowedCodes: allowed,
                    codeToLab: codeToLab
                )
                if code != nil {
                    hits += 1
                    if hits >= probeHits { return true }
                }
                index += stride
            }
            return false
        }.value
    }
}
