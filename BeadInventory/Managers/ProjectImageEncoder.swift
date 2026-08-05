//
//  ProjectImageEncoder.swift
//  BeadInventory
//
//  用户图片（图纸 thumbnail / 成品图 finishedImage）落盘前的统一编码器。
//
//  ## 为什么需要它
//
//  拼图模式的引入（`730cd29`）把三个图片写入点从「200×200 JPEG 0.6」一次性改成了
//  `pngData()`。commit message 原话是「两处都改为 pngData() 无损存储」。这里面其实是
//  **两件事被捆在一起**：
//
//      分辨率  200×200      →  全分辨率      ← 对的，拼图模式确实需要（200px 采样不了 100×100 网格）
//      编码    JPEG 0.6     →  PNG 无损      ← 纯浪费
//
//  同一张 2400px 图，PNG ≈ 13 MB，JPEG 0.92 ≈ 0.8 MB —— 分辨率一个像素没少。
//  1300 倍膨胀里约 9-16 倍是白给的，而这 9-16 倍正是把 SQLite 库撑到 GB 级的原因：
//
//    - `thumbnail` / `finishedImage` / `displayThumbnail` 都是 **inline BLOB**。
//      SQLite 改任何一列都要重写整条记录（含全部 overflow page）。往一条内联着 13 MB
//      原图的行里写 100 KB 的 `displayThumbnail`，实际写盘就是 13 MB。
//      458 项目 ≈ 6 GB，加 WAL + checkpoint = 用户 IPS 里那 68.72 GB dirty writes。
//    - 库涨到 GB 级之后，CoreData+CloudKit 的
//      `_performPostSaveTasks:andForceFullVacuum:` / `sqlite3_wal_checkpoint_v2`
//      会持 EXCLUSIVE 锁数十秒，撞上首屏那次 fetch → `0x8BADF00D` scene-create 看门狗。
//
//  所以本编码器只做一件事：**把无损那半撤回，分辨率那半原样保留**。
//
//  ## 对拼图模式的影响（已逐条核对，不是估计）
//
//  - `BeadPatternGrid.corners` 是**归一化 0-1** 坐标（见 `GridGeometry.denormalize`），
//    只要宽高比不变，重编码后现有网格标定完全不受影响，不需要任何坐标迁移。
//  - `GridCellSampler` 每格取 8 个采样点（0.2/0.5/0.8 三档，**避开格边和中心文字**）后
//    求平均再做 ΔE 匹配，阈值 30。JPEG 的 ringing 集中在色块边界，正是被 8 点布局避开的位置，
//    且平均进一步压制残余噪声。
//  - `GridCellSampler` 里 near-white 预过滤的注释本来就写着「图纸背景常带轻微色偏
//    （JPEG 压缩、屏幕色温等）」—— 采样链路本就是按「输入带 JPEG 色偏」设计的。
//
//  ## 编码策略
//
//  1. 超过 `maxPixelSize` 的图先降到 `maxPixelSize`（防御 8000px 这种病态输入；
//     用户实测数据是 2400px 左右，绝大多数图走不到这一步，分辨率原样保留）。
//  2. **带 alpha → PNG**。带 alpha 的基本都是截图类合成图纸，PNG 对纯色块压缩率极高，
//     通常几百 KB 就够。不转 JPEG 是因为 JPEG 无 alpha，压平到白底会在深色模式下露馅。
//  3. **不带 alpha → JPEG**，质量从 0.92 起。
//  4. 结果超 `targetByteBudget` 就沿 `qualitySteps` / `pixelSizeSteps` 逐档退让，
//     直到进预算或触底（`minPixelSize`）。触底仍超预算就接受 —— 宁可留一张大图，
//     也不把用户的图纸糊到不能用。调用方（迁移器）靠 `didReachBudget` 记账避免反复重试。
//
//  ## 线程
//
//  全部 `nonisolated`，可以从任意后台 Task 调用。迁移器就是在后台 executor 上直接同步调。

import Foundation
import UIKit
import ImageIO

enum ProjectImageEncoder {

    /// 输出最长边上限。2400px 是实测用户数据的典型值，3072 留一档余量：
    /// 常规图片走不到这条线，分辨率原样保留；只有病态大图（8000px 扫描件）才会被降。
    static let maxPixelSize: Int = 3072

    /// 单张图的目标字节预算。JPEG 0.92 @ 2400px 实测 ~0.8 MB，1.2 MB 留出细节丰富图的余量。
    /// 458 项目 × 1.2 MB 上限 = 550 MB，对比现状 6 GB。
    static let targetByteBudget: Int = 1_200_000

    /// 退让的下限 —— 再小就影响拼图模式网格识别了（100×100 网格 @ 1600px = 16px/格，
    /// 采样点间距 ~5px，仍然够用；再往下 8px/格 时 0.2/0.8 两档采样点会挤到格边上）。
    static let minPixelSize: Int = 1600

    /// 超过这个字节数就认为「这张图该被重编码」。迁移扫描器用它筛选候选行。
    /// 取 `targetByteBudget` 的 ~1.7 倍：正常编码结果稳定落在阈值下方，
    /// 保证迁移**收敛**（重编码过的行不会被下一轮重新选中）。
    static let compactionThresholdBytes: Int = 2_000_000

    private static let qualitySteps: [CGFloat] = [0.92, 0.85, 0.78]
    private static let pixelSizeSteps: [Int] = [maxPixelSize, 2400, 2000, minPixelSize]

    /// 编码结果。`didReachBudget == false` 表示触底后仍超预算 —— 调用方应记账，
    /// 不要指望下次重试能变小（同样的输入会得到同样的结果，重试只是白烧 CPU + 写盘）。
    struct EncodeResult: Sendable {
        let data: Data
        let didReachBudget: Bool
        let usedLossless: Bool
        let pixelSize: CGSize
    }

    // MARK: - 写入路径（UIImage → Data）

    /// 用户在 App 里选好图、准备落盘时调用（ScanView / ProjectImageEditorSheet /
    /// Share Extension）。替代原来的裸 `image.pngData()`。
    static nonisolated func encode(_ image: UIImage) -> Data? {
        encodeResult(image)?.data
    }

    static nonisolated func encodeResult(_ image: UIImage) -> EncodeResult? {
        guard let cg = image.cgImage else {
            // CIImage-backed UIImage（滤镜产物）没有 cgImage。走 renderer 兜底：
            // 按原尺寸渲一遍拿到位图，再进正常流程。
            guard let rendered = renderToCGImage(image, maxPixelSize: maxPixelSize) else {
                AppLogger.shared.error("ProjectImageEncoder", "no_cgimage", metadata: [
                    "size": "\(image.size)"
                ])
                return nil
            }
            return encodeCGImage(rendered, hasAlpha: cgImageHasAlpha(rendered))
        }
        // UIImage 的 orientation 必须在这里烘进位图 —— 否则 JPEG 靠 EXIF 记方向，
        // 而 `GridCellSampler` 直接吃 `UIImage.cgImage` 的裸像素（不看 orientation），
        // 拼图模式的网格会跟图对不上。
        let oriented: CGImage
        if image.imageOrientation == .up {
            oriented = cg
        } else {
            guard let r = renderToCGImage(image, maxPixelSize: maxPixelSize) else { return nil }
            oriented = r
        }
        return encodeCGImage(oriented, hasAlpha: cgImageHasAlpha(oriented))
    }

    // MARK: - 迁移路径（Data → Data）

    /// 已落盘的老图重编码。返回 nil 表示「不需要动」或「动不了」，调用方应保持原样。
    ///
    /// 内存边界：用 `CGImageSourceCreateThumbnailAtIndex` 直接在 source 层出目标尺寸位图，
    /// **不走 `UIImage(data:)` 的全分辨率解码**（13 MB PNG → 全解码是 ~30-60 MB UIImage，
    /// 正是 458 项目用户 jetsam 的老路）。峰值 ≈ 3072² × 4 ≈ 37 MB，迁移器一次只处理一张。
    ///
    /// - Parameter source: 库里现存的字节
    /// - Returns: 更小的新字节；已经够小 / 解不开 / 重编码后反而更大 → nil
    static nonisolated func recompress(_ source: Data) -> EncodeResult? {
        // **必须显式 autoreleasepool。**
        //
        // 这条路径要解一张全分辨率位图（3072×2304×4 ≈ 28 MB）并试多种编码，中间产物
        // （CGImage / UIImage / 每次 encode 出来的 Data）全是 autorelease 的。
        // 迁移器是在一个长跑的 async 循环里逐条调用它，Swift 并发的隐式 pool 不会在
        // 循环中间排空 —— 实测 24 条连续瘦身，进程 footprint 涨了 **935 MB**
        // （StoreCompactionIntegrationTests 抓到的）。真机上这就是 jetsam：
        // 修崩溃的迁移器自己把 App 干掉，与 round-10 那次「修 jetsam 的协调器自己撞 jetsam」
        // 是同一个形状。
        //
        // 加了 pool 之后每条处理完立即归还，峰值恒定为一张图。
        var result: EncodeResult?
        autoreleasepool {
            result = recompressInner(source)
        }
        return result
    }

    private static nonisolated func recompressInner(_ source: Data) -> EncodeResult? {
        guard source.count > compactionThresholdBytes else { return nil }

        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let imageSource = CGImageSourceCreateWithData(source as CFData, sourceOptions as CFDictionary) else {
            AppLogger.shared.error("ProjectImageEncoder", "recompress_create_source_failed", metadata: [
                "sourceBytes": source.count
            ])
            return nil
        }

        // alpha 判定走 properties，只读文件头，不解码。
        let hasAlpha: Bool
        if let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] {
            hasAlpha = (props[kCGImagePropertyHasAlpha] as? Bool) ?? false
        } else {
            hasAlpha = false
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // 烘进 EXIF 方向，理由同 encodeResult
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions as CFDictionary) else {
            AppLogger.shared.error("ProjectImageEncoder", "recompress_decode_failed", metadata: [
                "sourceBytes": source.count
            ])
            return nil
        }

        guard let result = encodeCGImage(decoded, hasAlpha: hasAlpha) else { return nil }

        // 重编码后反而更大（源本来就是高效编码的小图，只是像素多）—— 保持原样更好。
        guard result.data.count < source.count else {
            AppLogger.shared.info("ProjectImageEncoder", "recompress_not_beneficial", metadata: [
                "sourceBytes": source.count,
                "encodedBytes": result.data.count
            ])
            return nil
        }
        return result
    }

    // MARK: - 内部

    private static nonisolated func encodeCGImage(_ image: CGImage, hasAlpha: Bool) -> EncodeResult? {
        var lastAttempt: EncodeResult?
        let longestEdge = max(image.width, image.height)
        guard longestEdge > 0 else { return nil }

        // 每一档的**实际**输出边长是 min(原图边长, 档位)。原图比某档小时该档退化成「不缩放」，
        // 跟前一档结果相同 —— 用 triedEdges 去重，避免对同一尺寸重复编码烧 CPU。
        // （早期写法在这里 `break`，导致 2400px 的图永远试不到 2000/1600 两档退让。）
        var triedEdges = Set<Int>()

        for pixelSize in pixelSizeSteps {
            let effectiveEdge = min(longestEdge, pixelSize)
            guard triedEdges.insert(effectiveEdge).inserted else { continue }

            // 每一档单独 pool：一档要试 PNG + 三档 JPEG 质量，四份 Data 全是 autorelease 的，
            // 不当场归还的话「试探性编码」的中间产物会全程堆着。
            var settled: EncodeResult?
            autoreleasepool {
                settled = attempt(image: image, edge: effectiveEdge, longestEdge: longestEdge,
                                  hasAlpha: hasAlpha, best: &lastAttempt)
            }
            if let settled { return settled }
        }

        if let lastAttempt {
            AppLogger.shared.info("ProjectImageEncoder", "budget_not_reached", metadata: [
                "bytes": lastAttempt.data.count,
                "budget": targetByteBudget,
                "lossless": lastAttempt.usedLossless,
                "pixelSize": "\(lastAttempt.pixelSize)"
            ])
        } else {
            AppLogger.shared.error("ProjectImageEncoder", "encode_produced_nothing", metadata: [
                "width": image.width,
                "height": image.height,
                "hasAlpha": hasAlpha
            ])
        }
        return lastAttempt
    }

    /// 单个尺寸档位的尝试。进预算就返回结果；否则把「目前最小的一版」记进 `best` 返回 nil。
    private static nonisolated func attempt(
        image: CGImage,
        edge: Int,
        longestEdge: Int,
        hasAlpha: Bool,
        best lastAttempt: inout EncodeResult?
    ) -> EncodeResult? {
        let scaled: CGImage
        if edge == longestEdge {
            scaled = image                                  // 不缩放，分辨率原样保留
        } else {
            guard let s = resize(image, maxPixelSize: edge) else { return nil }
            scaled = s
        }

        let size = CGSize(width: scaled.width, height: scaled.height)
        let ui = UIImage(cgImage: scaled)

        // **先试 PNG，够小就用 PNG。**
        //
        // 这不是保守，是实测结论：纯色块合成图纸（拼豆图纸最常见的形态）PNG 压得极好 ——
        // 2400px 的 100×100 色块图 PNG 只有 228 KB，而同一张图 JPEG 0.92 反而要 1.05 MB
        // （JPEG 的 DCT 最不擅长处理锐利色块边界，网格线更是每条都要花码率）。
        // 早期版本无脑上 JPEG，会把这批用户的图从 228 KB 放大到 1 MB —— 修崩溃的过程中
        // 把一部分人搞得更糟。
        //
        // 真正撑爆库的 13 MB 图是**照片型**内容（2400px / 13MB ≈ 2.2 字节每像素，
        // 纯色块图不可能到这个密度），那类图 PNG 压不动、JPEG 一压就下来，走下面的分支。
        if let png = ui.pngData() {
            let result = EncodeResult(data: png, didReachBudget: png.count <= targetByteBudget,
                                      usedLossless: true, pixelSize: size)
            if result.didReachBudget { return result }
            lastAttempt = smaller(lastAttempt, result)
        }

        // 带 alpha 不能转 JPEG（无 alpha 通道，压平到白底会在深色模式下露馅），
        // 只能靠降分辨率继续退让。
        guard !hasAlpha else { return nil }

        for quality in qualitySteps {
            guard let jpeg = ui.jpegData(compressionQuality: quality) else { continue }
            let result = EncodeResult(data: jpeg, didReachBudget: jpeg.count <= targetByteBudget,
                                      usedLossless: false, pixelSize: size)
            if result.didReachBudget { return result }
            lastAttempt = smaller(lastAttempt, result)
        }
        return nil
    }

    private static nonisolated func smaller(_ a: EncodeResult?, _ b: EncodeResult) -> EncodeResult {
        guard let a else { return b }
        return b.data.count < a.data.count ? b : a
    }

    private static nonisolated func cgImageHasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast:
            return true
        case .none, .noneSkipFirst, .noneSkipLast, .alphaOnly:
            return false
        @unknown default:
            return false
        }
    }

    private static nonisolated func resize(_ image: CGImage, maxPixelSize: Int) -> CGImage? {
        let longestEdge = max(image.width, image.height)
        guard longestEdge > maxPixelSize else { return image }
        let scale = CGFloat(maxPixelSize) / CGFloat(longestEdge)
        let target = CGSize(width: (CGFloat(image.width) * scale).rounded(),
                            height: (CGFloat(image.height) * scale).rounded())
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1            // 按像素画，不要乘设备 scale
        format.opaque = !cgImageHasAlpha(image)
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let ui = renderer.image { _ in
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: target))
        }
        return ui.cgImage
    }

    /// UIImage → 已应用 orientation 的 CGImage（顺带做上限降采样）。
    private static nonisolated func renderToCGImage(_ image: UIImage, maxPixelSize: Int) -> CGImage? {
        let longestEdge = max(image.size.width, image.size.height)
        guard longestEdge > 0 else { return nil }
        let scale = min(CGFloat(maxPixelSize) / longestEdge, 1.0)
        let target = CGSize(width: (image.size.width * scale).rounded(),
                            height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        // renderer.image 内部 draw 会应用 UIImage.imageOrientation
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }.cgImage
    }
}
