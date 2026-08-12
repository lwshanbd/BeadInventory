//
//  ImageDownsampler.swift
//  BeadInventory
//
//  原图 → 小缩略图的 downsample 工具。供 displayThumbnail 字段生成 + 列表 row
//  在 displayThumbnail 缺失时的 fallback 解码使用。
//
//  设计要点：
//  - 用 ImageIO `CGImageSourceCreateThumbnailAtIndex` 而不是 UIImage(data:) + resize：
//    前者在 CGImageSource 内部直接生成目标尺寸位图，跳过全分辨率解码 → 内存峰值 KB 级
//    而不是 MB 级；后者会把原图先解码出来（30+ MB），背道而驰。
//  - `kCGImageSourceCreateThumbnailFromImageAlways = true` 强制生成（即使源图无 EXIF
//    thumbnail），`shouldCacheImmediately = true` 把解码挪到这里完成（而不是后续 draw time
//    在主线程上发生）。
//  - 输出 JPEG @ 0.85：经验值 —— 拼豆图大多色块密集，JPEG 0.85 几乎看不出退化，
//    单图通常 30-100 KB（vs 原 PNG 几 MB）。0.9 大小翻倍，0.8 开始能看到色块边缘 artifact。
//  - 标记 `nonisolated` —— 调用方可以从任意 Task / 后台 actor 调用，不必跳主线程。
//
//  错误处理：失败时返回 nil + logError 一条诊断。调用方需要兜底 ——
//  **写入 displayThumbnail = nil**（清空），让 `ProjectThumbnailImage` 走第二优先级
//  fallback（CGImageSourceCreateThumbnailAtIndex 实时 downsample）兜底。
//  Round-4 曾把"用原 thumbnail 字节兜底"，但那会让列表 row 通过 `UIImage(data:)` 解码 5-10 MB
//  PNG 重蹈 jetsam —— round-5 F1 改回 nil。

import Foundation
import UIKit
import ImageIO

enum ImageDownsampler {

    /// downsample 输出目标：512px 以内的最大边 + JPEG 0.85。
    /// 数字经过测算：列表 row 在 3x 设备上不超过 120pt，512px 已经远超显示需求 + 留出
    /// 用户从列表点开后的瞬间放大缓冲。再大就接近原图，没有压缩意义。
    static let defaultMaxPixelSize: Int = 512
    static let defaultJPEGQuality: CGFloat = 0.85

    /// 把 PNG / JPEG 原图字节降采样成小缩略图。
    ///
    /// - Parameters:
    ///   - sourceData: 原图字节（PNG/JPEG，任意尺寸）
    ///   - maxPixelSize: 输出最大边长（默认 512px）
    ///   - jpegQuality: JPEG 输出质量（默认 0.85）
    /// - Returns: JPEG 字节；失败返回 nil（不抛 throw，避免把"用户图坏了/格式特别"误升级成错误流）
    static nonisolated func downsample(
        _ sourceData: Data,
        maxPixelSize: Int = defaultMaxPixelSize,
        jpegQuality: CGFloat = defaultJPEGQuality
    ) -> Data? {
        // 用 ImageIO 不走 UIImage —— UIImage(data:) 会先解码全分辨率，内存峰值会到原图
        // RGBA × pixel 数（5MB PNG → ~30MB UIImage）。CGImageSource 直接出小图，峰值 KB 级。
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false  // 不缓存源图全分辨率
        ]
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, sourceOptions as CFDictionary) else {
            AppLogger.shared.error("ImageDownsampler", "create_source_failed", metadata: [
                "bytes": sourceData.count
            ])
            return nil
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,  // 应用 EXIF 方向
            kCGImageSourceShouldCacheImmediately: true,         // 解码在这里完成
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            AppLogger.shared.error("ImageDownsampler", "create_thumbnail_failed", metadata: [
                "bytes": sourceData.count,
                "maxPixelSize": maxPixelSize
            ])
            return nil
        }

        let uiThumb = UIImage(cgImage: cgThumb)
        guard let jpeg = uiThumb.jpegData(compressionQuality: jpegQuality) else {
            AppLogger.shared.error("ImageDownsampler", "jpeg_encode_failed", metadata: [
                "bytes": sourceData.count,
                "thumbWidth": cgThumb.width,
                "thumbHeight": cgThumb.height
            ])
            return nil
        }
        return jpeg
    }

    /// 只读图头，拿原图有多少像素 —— 不解码，代价是几十微秒。
    ///
    /// 拼图模式要按「解码出来会占多少内存」决定降不降采样：源图小于预算时就用原图，
    /// 别为了一个固定的长边上限把本来就够清楚的图纸砍糊了。
    /// （EXIF 方向可能让宽高对调，但这里只用来算总像素，对调不影响。）
    static nonisolated func pixelSize(of data: Data) -> CGSize? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    /// 跟 downsample 一样，但返回 UIImage 而不是字节 —— 给「列表 row 没有 displayThumbnail
    /// 时直接用 fallback 显示」的路径用，省一次 JPEG encode + decode round-trip。
    ///
    /// 注意：返回的 UIImage 已经预解码（kCGImageSourceShouldCacheImmediately），
    /// 上屏不会再触发主线程 decode。
    static nonisolated func downsampleToUIImage(
        _ sourceData: Data,
        maxPixelSize: Int = defaultMaxPixelSize
    ) -> UIImage? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, sourceOptions as CFDictionary) else {
            // **round-10 review Nit**：之前两个失败点都静默返 nil，跟兄弟 method `downsample`
            // 不对称。这条路径是老用户没有 displayThumbnail 时列表 row 的兜底降级 ——
            // 如果某些畸形 PNG / 损坏字节让 CGImageSource 创建失败，用户看到列表里那个 row
            // 永远是 placeholder，Sentry 抓不到 → 调查无从下手。补 logError 让监控可观测。
            AppLogger.shared.error("ImageDownsampler", "create_source_failed_uimage_path", metadata: [
                "sourceBytes": sourceData.count
            ])
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            AppLogger.shared.error("ImageDownsampler", "create_thumbnail_failed_uimage_path", metadata: [
                "sourceBytes": sourceData.count,
                "maxPixelSize": maxPixelSize
            ])
            return nil
        }
        return UIImage(cgImage: cgThumb)
    }

    // 注：原先有 `migrationThresholdBytes = 200_000` —— round-5 N1 后已弃用
    //（一张 199 KB 的 4000×4000 PNG 仍能 UIImage(data:) 解码爆 60MB，所以 migration 不能因
    // "字节小"就跳过 downsample）。常量已删除，避免给未来维护者错误信号。
}
