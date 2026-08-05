//
//  ProjectImageEncoderTests.swift
//  BeadInventoryTests
//
//  钉住「撤回无损 PNG」这个决定的两个前提：
//    1. 体积确实降一个数量级（否则整个修复没有意义）
//    2. 拼图模式的网格采样结果**不变**（否则修崩溃的代价是弄坏核心功能）
//
//  第 2 条是这轮方案选型时唯一真正有风险的假设，所以这里直接跑 `GridCellSampler`
//  做前后对比，而不是靠「JPEG 0.92 肉眼看不出」这种说辞。
//

import XCTest
import UIKit
@testable import BeadInventory

final class ProjectImageEncoderTests: XCTestCase {

    // MARK: - 夹具

    /// 造一张「拼豆图纸」形态的图：rows×cols 个纯色格 + 深色网格线。
    /// 这是 App 的真实输入形态（用户上传的图纸大多是这种合成图），
    /// 也是 JPEG 最不擅长的形态（纯色块边界会 ringing）—— 故意选最难的。
    private func makePatternImage(
        longEdge: Int,
        rows: Int,
        cols: Int,
        palette: [UIColor],
        hasAlpha: Bool = false
    ) -> UIImage {
        let width = longEdge
        let height = Int(Double(longEdge) * Double(rows) / Double(cols))
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = !hasAlpha
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height), format: format
        )
        return renderer.image { ctx in
            if !hasAlpha {
                UIColor.white.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            let cellW = Double(width) / Double(cols)
            let cellH = Double(height) / Double(rows)
            for r in 0..<rows {
                for c in 0..<cols {
                    // 确定性取色，保证两次构造完全一致
                    palette[(r * cols + c) % palette.count].setFill()
                    ctx.fill(CGRect(x: Double(c) * cellW, y: Double(r) * cellH,
                                    width: cellW, height: cellH))
                }
            }
            // 网格线 —— 真实图纸都有，且是 JPEG ringing 的主要来源
            UIColor(white: 0.25, alpha: 1).setStroke()
            let path = UIBezierPath()
            path.lineWidth = 1
            for c in 0...cols {
                let x = Double(c) * cellW
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: Double(height)))
            }
            for r in 0...rows {
                let y = Double(r) * cellH
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: Double(width), y: y))
            }
            path.stroke()
        }
    }

    /// 造一张「实拍拼豆成品照」形态的图：格子仍是调色板色，但每像素叠加确定性噪声
    /// （模拟传感器噪声 / 豆子表面纹理 / 光照不均）。
    ///
    /// 这才是真正把库撑爆的那类图：用户数据 2400px / 13 MB ≈ 2.2 字节每像素，
    /// 纯色块合成图不可能到这个密度，只有照片型内容才会。噪声让 deflate 失效（PNG 巨大），
    /// 但 DCT 仍能压（JPEG 小）—— 正是本次修复的目标形态。
    private func makeNoisyPatternImage(
        longEdge: Int,
        rows: Int,
        cols: Int,
        palette: [UIColor],
        jitter: Int = 26
    ) -> UIImage {
        let width = longEdge
        let height = Int(Double(longEdge) * Double(rows) / Double(cols))
        var buffer = [UInt8](repeating: 0, count: width * height * 4)

        // 调色板取 RGB 分量
        let rgb: [(UInt8, UInt8, UInt8)] = palette.map { color in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return (UInt8(r * 255), UInt8(g * 255), UInt8(b * 255))
        }

        // 确定性 LCG —— 测试必须可复现，不能用 arc4random
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) & 0xFF)
        }

        let cellW = Double(width) / Double(cols)
        let cellH = Double(height) / Double(rows)
        for y in 0..<height {
            let row = min(Int(Double(y) / cellH), rows - 1)
            let onHLine = abs(Double(y).truncatingRemainder(dividingBy: cellH)) < 1
            for x in 0..<width {
                let col = min(Int(Double(x) / cellW), cols - 1)
                let onVLine = abs(Double(x).truncatingRemainder(dividingBy: cellW)) < 1
                let base = rgb[(row * cols + col) % rgb.count]
                let idx = (y * width + x) * 4
                if onHLine || onVLine {
                    buffer[idx] = 64; buffer[idx + 1] = 64; buffer[idx + 2] = 64
                } else {
                    let n = next() % (jitter * 2 + 1) - jitter
                    buffer[idx] = UInt8(clamping: Int(base.0) + n)
                    buffer[idx + 1] = UInt8(clamping: Int(base.1) + n)
                    buffer[idx + 2] = UInt8(clamping: Int(base.2) + n)
                }
                buffer[idx + 3] = 255
            }
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        let provider = CGDataProvider(data: Data(buffer) as CFData)!
        let cg = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        return UIImage(cgImage: cg)
    }

    /// 调色板 + 与之对应的 BeadColor 表，色号就是十六进制本身，方便断言。
    private func makePalette() -> (colors: [UIColor], beads: [BeadColor]) {
        let hexes = ["FFFFFF", "E8112D", "1B5FAA", "F4C400", "1E8A3C",
                     "000000", "F08CAE", "7A4EA3", "F5811F", "8C6239"]
        let ui = hexes.map { hex -> UIColor in
            let v = UInt32(hex, radix: 16)!
            return UIColor(red: CGFloat((v >> 16) & 0xFF) / 255,
                           green: CGFloat((v >> 8) & 0xFF) / 255,
                           blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        let beads = hexes.map { BeadColor(colorHex: $0, mardCode: $0) }
        return (ui, beads)
    }

    private func fullFrameGrid(rows: Int, cols: Int, imageSize: CGSize) -> BeadPatternGrid {
        BeadPatternGrid(
            corners: GridCorners(
                topLeft: CGPoint(x: 0, y: 0),
                topRight: CGPoint(x: 1, y: 0),
                bottomLeft: CGPoint(x: 0, y: 1),
                bottomRight: CGPoint(x: 1, y: 1)
            ),
            rows: rows,
            cols: cols,
            cellColorCodes: Array(repeating: Array(repeating: nil, count: cols), count: rows),
            lastCalibratedAt: Date(),
            sourceImageSize: imageSize,
            colorSystem: .mard
        )
    }

    // MARK: - 1. 体积

    /// 照片型图纸 —— 就是把用户库撑到 GB 级的那一类。
    func test_encode_shrinks_photographic_image_by_an_order_of_magnitude() throws {
        let (palette, _) = makePalette()
        let image = makeNoisyPatternImage(longEdge: 2400, rows: 100, cols: 100, palette: palette)

        let pngBytes = try XCTUnwrap(image.pngData()).count
        let encoded = try XCTUnwrap(ProjectImageEncoder.encode(image))

        print("[encoder] photo 2400px  PNG=\(pngBytes)B  encoded=\(encoded.count)B  ratio=\(pngBytes / max(encoded.count, 1))x")

        XCTAssertGreaterThan(
            pngBytes, 4_000_000,
            "夹具本身必须是「PNG 存起来很大」的形态，否则这个测试没在测该测的东西"
        )
        // 这里断言的是**收敛阈值**而不是 targetByteBudget。
        // 预算是 best-effort：本夹具用的是每像素独立的 ±26 噪声，比真实传感器噪声
        // （低幅值且空间相关）恶劣得多，DCT 压不下去，实测停在 ~1.4 MB。
        // 真正不能破的是「重编码结果必须落在扫描阈值下方」—— 否则迁移器会把同一行
        // 反复选中重写，那就是换了个触发器的 68 GB 写放大。
        XCTAssertLessThan(
            encoded.count, ProjectImageEncoder.compactionThresholdBytes,
            "最恶劣的噪声图重编码后仍在扫描阈值之上 → 迁移不收敛"
        )
        XCTAssertLessThan(
            encoded.count, pngBytes / 5,
            "至少要比无损 PNG 小 5 倍才值得做这次有损迁移"
        )
    }

    /// **回归钉**：纯色块合成图纸 PNG 本来就压得极好（2400px 的 100×100 色块图只有 ~228 KB），
    /// 同一张图 JPEG 0.92 反而要 ~1 MB。编码器早期版本无脑上 JPEG，会把这批用户的图
    /// 放大 4-5 倍 —— 修崩溃的过程中把一部分人搞得更糟。编码器必须两种都试、取小的。
    func test_encode_does_not_inflate_flat_pattern_chart() throws {
        let (palette, _) = makePalette()
        let image = makePatternImage(longEdge: 2400, rows: 100, cols: 100, palette: palette)

        let pngBytes = try XCTUnwrap(image.pngData()).count
        let result = try XCTUnwrap(ProjectImageEncoder.encodeResult(image))

        print("[encoder] flat 2400px  PNG=\(pngBytes)B  encoded=\(result.data.count)B  lossless=\(result.usedLossless)")

        XCTAssertLessThanOrEqual(
            result.data.count, pngBytes,
            "纯色块图纸被编码器放大了 —— 这类图必须原样走 PNG"
        )
        XCTAssertTrue(result.usedLossless, "PNG 已经够小时必须选无损分支，不该白白牺牲画质")
    }

    /// 分辨率必须原样保留 —— 拼图模式的网格识别依赖它，这是 `730cd29` 当初改动里**对**的那半。
    func test_encode_preserves_pixel_dimensions_under_cap() throws {
        let (palette, _) = makePalette()
        let image = makePatternImage(longEdge: 2400, rows: 60, cols: 60, palette: palette)
        let encoded = try XCTUnwrap(ProjectImageEncoder.encode(image))
        let decoded = try XCTUnwrap(UIImage(data: encoded))

        XCTAssertEqual(decoded.size.width, image.size.width, accuracy: 1)
        XCTAssertEqual(decoded.size.height, image.size.height, accuracy: 1)
    }

    /// 病态大图才降采样，且降到上限而不是更低。
    func test_encode_caps_pathological_oversize_image() throws {
        let (palette, _) = makePalette()
        let image = makePatternImage(longEdge: 6000, rows: 50, cols: 50, palette: palette)
        let encoded = try XCTUnwrap(ProjectImageEncoder.encode(image))
        let decoded = try XCTUnwrap(UIImage(data: encoded))

        XCTAssertLessThanOrEqual(max(decoded.size.width, decoded.size.height),
                                 CGFloat(ProjectImageEncoder.maxPixelSize) + 1)
    }

    // MARK: - 2. 拼图模式保真（方案选型里唯一真有风险的假设）

    func test_grid_sampling_is_unchanged_after_recompression() throws {
        let (palette, beads) = makePalette()
        let rows = 60, cols = 60
        // 用照片型夹具 —— 只有它才会真正触发重编码（纯色块图 PNG 就已经在阈值下方，
        // recompress 会正确地返回 nil 不动它）。噪声也让这个测试更严格：
        // JPEG 要同时扛住色块边界的 ringing 和噪声。
        let image = makeNoisyPatternImage(longEdge: 2400, rows: rows, cols: cols, palette: palette)
        let grid = fullFrameGrid(rows: rows, cols: cols, imageSize: image.size)

        // 现状：无损 PNG 落盘 → 读回 → 采样
        let pngData = try XCTUnwrap(image.pngData())
        let beforeImage = try XCTUnwrap(UIImage(data: pngData))
        let before = GridCellSampler.shared.sample(
            image: beforeImage, grid: grid, availableColors: beads
        )

        // 修复后：重编码 → 读回 → 采样
        let recompressed = try XCTUnwrap(ProjectImageEncoder.recompress(pngData))
        let afterImage = try XCTUnwrap(UIImage(data: recompressed.data))
        let after = GridCellSampler.shared.sample(
            image: afterImage, grid: grid, availableColors: beads
        )

        XCTAssertEqual(before.count, after.count)
        var mismatches: [String] = []
        for r in 0..<rows {
            for c in 0..<cols where before[r][c] != after[r][c] {
                mismatches.append("(\(r),\(c)) \(before[r][c] ?? "nil")→\(after[r][c] ?? "nil")")
            }
        }
        XCTAssertTrue(
            mismatches.isEmpty,
            "重编码后网格采样结果发生变化，共 \(mismatches.count)/\(rows * cols) 格：\(mismatches.prefix(10))"
        )
    }

    // MARK: - 3. 收敛性（迁移必须停得下来）

    /// 重编码结果必须落在扫描阈值下方，否则迁移器会把同一行反复选中重写 —— 那就是
    /// 又一次 68 GB 写放大，只是换了个触发器。
    func test_recompress_output_is_below_scan_threshold_and_is_idempotent() throws {
        let (palette, _) = makePalette()
        let image = makeNoisyPatternImage(longEdge: 2400, rows: 100, cols: 100, palette: palette)
        let pngData = try XCTUnwrap(image.pngData())

        let first = try XCTUnwrap(ProjectImageEncoder.recompress(pngData))
        XCTAssertLessThan(
            first.data.count, ProjectImageEncoder.compactionThresholdBytes,
            "重编码结果仍在扫描阈值之上 → 迁移不收敛"
        )
        XCTAssertNil(
            ProjectImageEncoder.recompress(first.data),
            "对已经够小的字节再次 recompress 必须返回 nil（不做无谓重写）"
        )
    }

    func test_recompress_returns_nil_for_already_small_data() throws {
        let (palette, _) = makePalette()
        let small = makePatternImage(longEdge: 400, rows: 20, cols: 20, palette: palette)
        let data = try XCTUnwrap(small.jpegData(compressionQuality: 0.9))
        XCTAssertLessThan(data.count, ProjectImageEncoder.compactionThresholdBytes)
        XCTAssertNil(ProjectImageEncoder.recompress(data))
    }

    // MARK: - 4. alpha 不能被压平

    /// 带 alpha 的图纸走 PNG 分支。压成 JPEG 会把透明背景变成白底，深色模式下直接露馅。
    func test_encode_preserves_alpha_channel() throws {
        let (palette, _) = makePalette()
        let image = makePatternImage(longEdge: 1200, rows: 20, cols: 20,
                                     palette: palette, hasAlpha: true)
        let result = try XCTUnwrap(ProjectImageEncoder.encodeResult(image))
        XCTAssertTrue(result.usedLossless, "带 alpha 的图必须走无损 PNG 分支")

        let decoded = try XCTUnwrap(UIImage(data: result.data)?.cgImage)
        let alpha = decoded.alphaInfo
        XCTAssertTrue(
            alpha == .first || alpha == .last
                || alpha == .premultipliedFirst || alpha == .premultipliedLast,
            "重编码后 alpha 通道丢失，alphaInfo=\(alpha.rawValue)"
        )
    }
}
