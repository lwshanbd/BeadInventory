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
//  **照片型** 2400px 图，PNG ≈ 13 MB，重编码后 ≈ 1.5 MB —— 分辨率一个像素没少
//  （真机实测 12,975,516 B → 1,560,605 B）。纯色块图纸相反，PNG 本来就小，见下面「编码策略」。
//  这一个数量级正是把 SQLite 库撑到 GB 级的原因：
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
//  - `GridCellSampler` 每格取 8 个采样点（0.2/0.5/0.8 三档，**避开格边和中心文字**），
//    **每点各自做 ΔE ≤ 30 匹配再投票，需 ≥2 票才判定色号**。JPEG 的 ringing 集中在色块
//    边界，正是被 8 点布局避开的位置；即使个别点被污染，2/8 的投票门槛也会把它吸收掉。
//    （平均 Lab 只喂 near-white 预过滤，不参与色号判定 —— 别把它当成抗噪机制。）
//  - `GridCellSampler` 里 near-white 预过滤的注释本来就写着「图纸背景常带轻微色偏
//    （JPEG 压缩、屏幕色温等）」—— 采样链路本就是按「输入带 JPEG 色偏」设计的。
//
//  ## 编码策略
//
//  1. 超过 `maxPixelSize` 的图先降到 `maxPixelSize`（防御 8000px 这种病态输入；
//     用户实测数据是 2400px 左右，绝大多数图走不到这一步，分辨率原样保留）。
//  2. **PNG 永远先试**。进预算就用 PNG —— 纯色块合成图纸（拼豆图纸最常见的形态）
//     PNG 压得极好，2400px 的 100×100 色块图只有 228 KB，而同一张 JPEG 0.92 反而要
//     1.05 MB（DCT 最不擅长锐利色块边界）。无脑上 JPEG 会把这批用户的图放大 4-5 倍。
//  3. PNG 超预算且**真的没有透明像素** → 再试 JPEG，质量 0.92 起。
//     注意判据是「有没有透明**像素**」而不是「有没有 alpha 通道」——
//     裁剪 / 方向归一化的渲染产物几乎总是带 alpha 通道但完全不透明，
//     早期实现在这里判错，让相机照片全部退化成 PNG-only（见 `containsTransparency`）。
//  4. 仍超预算就沿 `pixelSizeSteps`（外层）× `qualitySteps`（内层）逐档退让，
//     直到进预算或触底（`minPixelSize`）。触底仍超预算就接受 —— 宁可留一张大图，
//     也不把用户的图纸糊到不能用。
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

    /// 单张图的目标字节预算。照片型 2400px 图重编码实测落在 1.4-1.6 MB（噪声越强 DCT 越压不动），
    /// 纯色块图纸则远低于此。**预算是 best-effort 目标，不是保证** —— 触底仍超预算会被接受，
    /// 真正的硬约束是 `compactionThresholdBytes`。
    static let targetByteBudget: Int = 1_200_000

    /// 退让的下限 —— 再小就影响拼图模式网格识别了（100×100 网格 @ 1600px = 16px/格，
    /// 采样点间距 ~5px，仍然够用；再往下 8px/格 时 0.2/0.8 两档采样点会挤到格边上）。
    static let minPixelSize: Int = 1600

    /// 超过这个字节数就认为「这张图该被重编码」。迁移扫描器用它筛选候选行。
    ///
    /// 取 `targetByteBudget` 的 ~1.7 倍，让正常编码结果稳定落在阈值下方，绝大多数行一轮收敛。
    /// **但这不是结构性保证** —— `encodeCGImage` 在触底仍超预算时照样返回结果，
    /// `recompressInner` 只要比源小就接受。真正兜底终止的是两层记账：
    /// 本轮靠协调器的 `excluded` 集合，跨启动靠 `.stubborn` 落盘（见
    /// `ThumbnailMigrationCoordinator`）。
    static let compactionThresholdBytes: Int = 2_000_000

    private static let qualitySteps: [CGFloat] = [0.92, 0.85, 0.78]
    private static let pixelSizeSteps: [Int] = [maxPixelSize, 2400, 2000, minPixelSize]

    /// 编码结果。
    ///
    /// `didReachBudget` / `usedLossless` / `pixelSize` 三个字段**仅供诊断与测试**，
    /// 不要拿它们做控制流：`didReachBudget` 量的是 `targetByteBudget`（1.2 MB），
    /// 而迁移器关心的收敛问题量的是 `compactionThresholdBytes`（2 MB），两者不是一回事。
    /// 迁移器判断「还要不要再管这一行」应该直接比 `data.count` 与阈值。
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
            // 源信息全丢了，只能保守当作带 alpha。
            guard let rendered = renderToCGImage(image, maxPixelSize: maxPixelSize, hasAlpha: true) else {
                AppLogger.shared.error("ProjectImageEncoder", "no_cgimage", metadata: [
                    "size": "\(image.size)"
                ])
                return nil
            }
            return encodeCGImage(rendered, hasAlpha: containsTransparency(rendered))
        }

        // **alpha 必须取自源图，不能取自渲染产物。**
        //
        // 这里踩过一个会让整个修复失效的坑：`renderToCGImage` 原本硬编码
        // `format.opaque = false`，产物一律带 alpha 通道（premultipliedFirst）。而
        // `attempt` 里带 alpha 就禁用 JPEG 分支（JPEG 无 alpha），于是**任何 orientation
        // 不是 .up 的图都只剩 PNG 阶梯，永远进不了预算**。
        //
        // 而 iPhone 相机照片的 orientation 就是 `.right` —— 也就是最常见的输入路径。
        // 实测同一张 2400px 噪声图：
        //     .up      → 1,429,323 B (JPEG)
        //     .right   → 4,318,567 B (PNG)   ← 3 倍大，且高于 compactionThresholdBytes
        // 高于扫描阈值意味着这类行**永远不收敛**，迁移器每轮都会重新选中它。
        // 裁剪路径同理（`ImageCropView.normalizeImageOrientation` 也是 opaque: false）。
        let sourceHasAlpha = containsTransparency(cg)

        // UIImage 的 orientation 必须在这里烘进位图 —— 否则 JPEG 靠 EXIF 记方向，
        // 而 `GridCellSampler` 直接吃 `UIImage.cgImage` 的裸像素（不看 orientation），
        // 拼图模式的网格会跟图对不上。
        let oriented: CGImage
        if image.imageOrientation == .up {
            oriented = cg
        } else {
            guard let r = renderToCGImage(image, maxPixelSize: maxPixelSize, hasAlpha: sourceHasAlpha) else {
                // 这条路径以前静默返 nil —— 而调用方把 nil 当成「用户要删图」，
                // 会把现存照片清掉（见 ProjectDetailView 的 guard）。至少要可观测。
                AppLogger.shared.error("ProjectImageEncoder", "orientation_render_failed", metadata: [
                    "size": "\(image.size)",
                    "orientation": "\(image.imageOrientation.rawValue)"
                ])
                return nil
            }
            oriented = r
        }
        return encodeCGImage(oriented, hasAlpha: sourceHasAlpha)
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

        // 透明度以**解码出来的位图**为准，不看 `kCGImagePropertyHasAlpha` ——
        // 那个属性报的同样是「有没有 alpha 通道」，对我们自己早期版本落盘的
        // RGBA PNG 一律为 true，会把整批老数据锁死在 PNG-only 路径上。
        guard let result = encodeCGImage(decoded, hasAlpha: containsTransparency(decoded)) else { return nil }

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

    /// 图里**是否真的有透明像素** —— 不是「有没有 alpha 通道」。
    ///
    /// 这个区分是 C1 的核心。带 alpha 通道的图绝大多数是完全不透明的：
    /// `UIGraphicsImageRenderer` 只要 `opaque == false` 就输出 `premultipliedFirst`，
    /// 而裁剪（`ImageCropView.normalizeImageOrientation`）和方向归一化都走它。
    /// 早期实现拿「有 alpha 通道」当「有透明度」来禁用 JPEG，结果是**裁剪过或旋转过的
    /// 照片全部退化成 PNG-only**，压不到阈值下方、迁移永不收敛 —— 实测一张裁剪过的
    /// 2400px 照片输出 5,840,831 B。
    ///
    /// 判定成本：先看 alphaInfo 快速否定（没通道就不可能透明）；有通道时才把 alpha
    /// 通道单独渲染出来扫一遍。渲染上限压到 1024px（~1 MB 缓冲）—— 真正的透明图纸
    /// 都是大片透明区域，降采样后依然可见；代价是可能漏掉零星几个像素的透明度，
    /// 那种情况压平成白底在视觉上也无差别。
    ///
    /// 任何一步失败都保守返回 `true`（走无损），宁可图大一点也不能把用户的透明图压平。
    private static nonisolated func containsTransparency(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false                      // 没有 alpha 通道，不可能有透明像素
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
            break                             // 有通道，得看实际像素
        @unknown default:
            return true                       // 不认识的形态，保守
        }

        let maxScanEdge = 1024
        let longest = max(image.width, image.height)
        let scale = longest > maxScanEdge ? Double(maxScanEdge) / Double(longest) : 1
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))

        // **缓冲必须清零，不能预填 255。**
        //
        // `CGContext.draw` 是 source-over 合成，不是 copy。目标预填 255（alpha=1.0）时
        //     dst = src + 1·(1 − src) = 1
        // 恒等于不透明 —— 函数结构上不可能返回 true，任何透明图都会被判成不透明，
        // 进而被 JPEG 压平。实测：4.8 MB 的半透明图 → usedLossless=false，
        // 解码回来 alphaInfo=noneSkipFirst，**透明度被永久摧毁**。
        //
        // 这比它要修的原 bug 更糟：原 bug 只是图偏大，这个是不可逆地毁用户数据，
        // 而且迁移器会在后台自动对存量图执行。
        //
        // 清零之后 source-over 得到 dst = src，即真实 alpha；而且「画不上去」
        // （draw 无效）也会留下 0 → 报告有透明 → 走无损，方向仍然是保守的。
        var buffer = [UInt8](repeating: 0, count: w * h)
        let rendered = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard rendered else {
            AppLogger.shared.error("ProjectImageEncoder", "alpha_scan_failed", metadata: [
                "width": image.width, "height": image.height
            ])
            return true
        }
        return buffer.contains { $0 < 255 }
    }

    private static nonisolated func resize(_ image: CGImage, maxPixelSize: Int) -> CGImage? {
        let longestEdge = max(image.width, image.height)
        guard longestEdge > maxPixelSize else { return image }
        let scale = CGFloat(maxPixelSize) / CGFloat(longestEdge)
        let target = CGSize(width: (CGFloat(image.width) * scale).rounded(),
                            height: (CGFloat(image.height) * scale).rounded())
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1            // 按像素画，不要乘设备 scale
        format.opaque = !containsTransparency(image)
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let ui = renderer.image { _ in
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: target))
        }
        return ui.cgImage
    }

    /// UIImage → 已应用 orientation 的 CGImage（顺带做上限降采样）。
    ///
    /// `hasAlpha` 必须由调用方按**源图**传入：渲染器的 `opaque` 决定产物有没有 alpha 通道，
    /// 而下游拿 alpha 通道当「有透明度」用来禁用 JPEG。硬编码 false 会让所有旋转过的
    /// 照片（相机图就是 `.right`）退化成 PNG-only，见 `encodeResult` 里的详细说明。
    private static nonisolated func renderToCGImage(
        _ image: UIImage,
        maxPixelSize: Int,
        hasAlpha: Bool
    ) -> CGImage? {
        let longestEdge = max(image.size.width, image.size.height)
        guard longestEdge > 0 else { return nil }
        let scale = min(CGFloat(maxPixelSize) / longestEdge, 1.0)
        let target = CGSize(width: (image.size.width * scale).rounded(),
                            height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = !hasAlpha
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        // renderer.image 内部 draw 会应用 UIImage.imageOrientation
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }.cgImage
    }
}
