//
//  PatternSourceStore.swift
//  BeadInventory
//
//  拼图模式专用的「原图」存放处
//
//  ## 它解决什么
//
//  进 App 的图会被 `ProjectImageEncoder` 砍到长边 3072、压进 1.2 MB 预算 ——
//  这对列表、详情、日历都够用，而且必须这么做（那份图要进 SwiftData 跟 iCloud 同步，
//  296 个项目的量级下不压就是灾难）。但拼图模式要逐格看颜色，实测压完之后
//  一格豆子只剩十来个像素，明显糊。
//
//  所以另存一份原图，**只给拼图模式用**。
//
//  ## 为什么放 Application Support 而不是别处
//
//      Documents/          ❌ 进 iTunes / iCloud 备份
//      tmp/                ❌ 系统随时清
//      Library/Caches/     ❌ 磁盘紧张时系统会**静默清掉** —— 用户哪天再进拼图模式
//                             发现图悄悄变糊了，还查不出原因
//      Application Support ✅ 本地、不会被系统随手删；再打上 isExcludedFromBackup
//                             就既不进备份也不占 iCloud
//
//  另外两条边界是现成的，不用额外做什么：
//  - iCloud 同步只覆盖 SwiftData 那个 store（`cloudKitDatabase` 挂在 ModelConfiguration 上），
//    磁盘文件天然不同步；
//  - `BackupManager` 是逐字段拼 JSON（projects → thumbnail base64），不是扫目录，
//    所以备份 / 恢复也碰不到这里。
//
//  ## 谁能读
//
//  **像素只有拼图模式和多零件模式读**（`SinglePatternFlowView.load` / `PartsSheetFlowView.load`，
//  两边都是「有原图用原图，没有退回封面」）。
//
//  另外详情页的「图纸原图」那一行（`PatternSourceRow`）也读，但只为了一张 240px 预览和
//  字节数，而且**必须走后台 downsample**，绝不能整张解码上屏。
//
//  除此之外，列表、日历一律走 `displayThumbnail` / `thumbnail` —— 这份文件是全分辨率的，
//  任何一个会批量渲染的地方碰它都是 jetsam。
//
//  ## 什么时候没有
//
//  很多时候都没有：上传那一屏选了不留的、这个功能上线前就存在的项目、从别的设备同步过来的
//  （它不同步）、用户点过「拼好了」的。所以**调用方必须能在没有原图时照常工作**，
//  退回用 SwiftData 里那份压缩图，只是糊一点。
//

import Foundation
import UIKit
import ImageIO

enum PatternSourceStore {

    /// 上传图纸时**默认**要不要留原图。默认开。
    ///
    /// 只是初值：留不留是每张图各自的决定，上传那一屏有一个开关，用户按这张图会不会
    /// 真的去拼来定（十张图纸里往往只有两三张会进拼图模式）。所以这里刻意不叫
    /// `isEnabled`，也不再在 `save` 里当成一道闸门 —— 调用方已经拿到了用户的答复，
    /// 存储层再拿一个全局设置去否决它，就成了「我明明勾了却没留下」。
    static let keepSourceDefaultsKey = "keepPatternSourceImage"

    static var keepsSourceByDefault: Bool {
        UserDefaults.standard.object(forKey: keepSourceDefaultsKey) as? Bool ?? true
    }

    // MARK: - 位置

    private static var directory: URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        let dir = base.appendingPathComponent("PatternSources", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var marked = dir
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? marked.setResourceValues(values)
            } catch {
                AppLogger.shared.error("PatternSource", "create_directory_failed", metadata: [
                    "error": "\(error)"
                ])
                return nil
            }
        }
        return dir
    }

    private static func url(for projectId: UUID) -> URL? {
        directory?.appendingPathComponent("\(projectId.uuidString).img", isDirectory: false)
    }

    // MARK: - 读写

    /// 存一份原图。要不要存由调用方决定（见 `keepsSourceByDefault`）。
    /// - Parameter data: 原始字节，或 `lossless()` 重出的无损 PNG。
    /// - Returns: 有没有真的写进去。**换图**那条路必须看这个返回值 ——
    ///   写不成就得把库里那份（上一张图的）删掉，否则拼图模式会拿旧原图当这张图纸用。
    @discardableResult
    static func save(_ data: Data, for projectId: UUID) -> Bool {
        guard let url = url(for: projectId) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            // 单个文件也标一次：目录属性在某些恢复路径下不会被继承
            var marked = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? marked.setResourceValues(values)
            AppLogger.shared.info("PatternSource", "saved", metadata: [
                "projectId": projectId.uuidString, "bytes": data.count
            ])
            return true
        } catch {
            // 第一次存存不下不是错误路径 —— 拼图模式退回用压缩图照常能用，不要打扰用户。
            // 换图那条路不一样，调用方看返回值自己收拾（见上面 Returns）。
            AppLogger.shared.warning("PatternSource", "save_failed", metadata: [
                "projectId": projectId.uuidString, "error": "\(error)"
            ])
            return false
        }
    }

    /// 没有原始字节可用时（相机拍的、Share Extension 传进来的）拿什么存。
    ///
    /// **PNG，无损。** 这里以前是 `jpegData(0.95)` —— 用户传一张 5.8 MB 的图纸，
    /// 走这条路存下来只剩两三 MB，他在零件清单看到「留了一份原图，占 2.1 MB」，
    /// 结论只能是「你还是压了我的图」。他是对的：0.95 也是有损，色块边界该糊还是糊，
    /// 而这份图存在的唯一理由就是逐格看颜色。
    ///
    /// 拼豆图纸是大片纯色块，PNG 压得极好（实测 3640×5320 的图纸只有 207 KB）；
    /// 真正会变大的是拍照进来的那种，而那种本来也没有原始字节可用。
    ///
    /// **编码前必须先把方向烘进位图。** PNG 不带 orientation 标签，而 UIKit 不会替你转 ——
    /// 相机拍出来的 UIImage 是 `.right`，直接 `pngData()` 存下来就是躺倒的。原来的
    /// `jpegData(0.95)` 写了 EXIF 方向、读取端也应用了，换成 PNG 才暴露出来。
    /// 后果不是「看着歪」：多零件模式所有几何量都相对封面归一化，源图躺了整片零件框都对不上。
    /// 封面那条链路（`ProjectImageEncoder`）早就在做这件事，理由写在那边同一处。
    static func lossless(_ image: UIImage?) -> Data? {
        guard let image else { return nil }
        let upright: UIImage
        if image.imageOrientation == .up {
            upright = image
        } else {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            upright = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: image.size))
            }
        }
        guard let data = upright.pngData() else {
            // 用户是明确勾了「保留原图」才走到这儿的。编不出来就得看得见 ——
            // 调用方会因为拿到 nil 而什么都不存，屏幕上却跟存好了一模一样。
            AppLogger.shared.error("PatternSource", "lossless_encode_failed", metadata: [
                "pixelSize": "\(image.size)",
                "orientation": "\(image.imageOrientation.rawValue)"
            ])
            return nil
        }
        return data
    }

    /// 取原图字节。没有就返回 nil，调用方退回用压缩图。
    static func data(for projectId: UUID) -> Data? {
        guard let url = url(for: projectId),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func exists(for projectId: UUID) -> Bool {
        guard let url = url(for: projectId) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// 这个项目的原图占了多少字节（没有就是 0）—— 给「拼好了」的确认弹窗用。
    static func byteSize(for projectId: UUID) -> Int {
        guard let url = url(for: projectId),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else { return 0 }
        return values.fileSize ?? 0
    }

    /// 删掉某个项目的原图。三种情形会走到：用户在零件清单页点「拼好了」
    /// （`PartsListStepView`）、用户在详情页「图纸原图」那一行按「删掉」
    /// （`PatternSourceRow`），以及项目被删除（后者是资源正确性，不删就永远
    /// 留下一个谁也不会再读的孤儿文件）。
    ///
    /// - Returns: 删完之后这个项目确实没有原图了。**「本来就没有」也算成功。**
    ///   前两条路都是用户按了确认弹窗才走到这儿的，失败必须说一声 —— 静默失败会让
    ///   他看到东西原封不动回来，再点一次还是一样，而屏幕上没有任何线索。
    @discardableResult
    static func remove(for projectId: UUID) -> Bool {
        guard let url = url(for: projectId) else {
            AppLogger.shared.error("PatternSource", "remove_no_directory", metadata: [
                "projectId": projectId.uuidString
            ])
            return false
        }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch CocoaError.fileNoSuchFile {
            return true   // 已经没了，正是想要的结果
        } catch {
            AppLogger.shared.error("PatternSource", "remove_failed", metadata: [
                "projectId": projectId.uuidString, "error": "\(error)"
            ])
            return false
        }
    }
}

// MARK: - 多张图纸拼成一张

extension PatternSourceStore {

    /// 拼出来的那张图最多多少像素。多零件模式解码零件区的预算是 6000 万像素
    /// （`PartsSheetFlowView.workPixelBudget`），超过它也会被那边等比缩回来；
    /// 这里再留点余量，因为拼的时候画布和正在画的那一页同时在内存里。
    private static let stitchedPixelBudget = 48_000_000

    /// 把几张图纸从上到下拼成一张，存成这个项目的原图。
    ///
    /// ## 为什么是拼成一张，而不是让拼图模式认多张图
    ///
    /// 有的立体图纸零件太多，作者分成两三张图发。色号统计表只有一张，AI 识别那一步
    /// 只看那张就够；可多零件模式、投影模式要的是**所有零件**。这两个模式从头到尾
    /// 按「一个项目一张原图」写（零件坐标是相对整张图归一化的），拼成一张长图，
    /// 它们一行都不用改就能看到所有零件。
    ///
    /// 拼的时候**不缩放单页**：多零件模式整张图只量一个格距（每个零件的格线位置
    /// 各自对，格距是共用的）。同一个作者导出的几张图，格子一样大，原样拼就对得上。
    /// 真要是几张图格子大小不一样（比如一张截图一张拍照），在这里猜比例缩放只会
    /// 把本来对的那张也弄错，不如原样交给用户在「量格子」那一步看。
    ///
    /// 页与页之间留一道底色的空白，免得上一页底边和下一页顶边的零件贴在一起，
    /// 被当成一个零件。
    ///
    /// 总像素超过预算时所有页**一起**等比缩小，相对大小不变。
    ///
    /// - Returns: 无损 PNG。只有一页时原样返回那一页的字节。任何一页解不出来就返回 nil，
    ///   调用方退回只存第一页（缺一页总比整个项目没有原图强）。
    static func stitched(_ pages: [Data]) -> Data? {
        guard pages.count > 1 else { return pages.first }

        let sizes = pages.map(orientedPixelSize(of:))
        guard sizes.allSatisfy({ $0 != nil }) else {
            AppLogger.shared.error("PatternSource", "stitch_unreadable_page", metadata: ["pages": pages.count])
            return nil
        }
        let nativeSizes = sizes.compactMap { $0 }
        let totalPixels = nativeSizes.reduce(0.0) { $0 + Double($1.width * $1.height) }
        let scale = min(1, (Double(stitchedPixelBudget) / max(totalPixels, 1)).squareRoot())

        let pageSizes = nativeSizes.map {
            CGSize(width: max(1, ($0.width * scale).rounded()), height: max(1, ($0.height * scale).rounded()))
        }
        let canvasWidth = pageSizes.map(\.width).max() ?? 1
        let gap = max(16, (canvasWidth * 0.02).rounded())
        let canvasHeight = pageSizes.reduce(0) { $0 + $1.height } + gap * CGFloat(pageSizes.count - 1)

        // 第一页左上角那个像素当底色：图纸的底几乎都是纯色，用它填空白和窄页右边
        // 空出来的那块，多零件模式找零件时就不会把空白当成一块东西。
        let background = pages.first.flatMap(cornerColor(of:)) ?? .white

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        var failed = false
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: canvasWidth, height: canvasHeight), format: format
        ).image { context in
            background.setFill()
            context.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
            var y: CGFloat = 0
            for (data, size) in zip(pages, pageSizes) {
                // 一页一页解码、画完就放掉，内存里同时只有画布和一页
                autoreleasepool {
                    let maxPixel = Int(max(size.width, size.height))
                    if let page = ImageDownsampler.downsampleToUIImage(data, maxPixelSize: maxPixel) {
                        page.draw(in: CGRect(x: 0, y: y, width: size.width, height: size.height))
                    } else {
                        failed = true
                    }
                }
                y += size.height + gap
            }
        }
        guard !failed, let png = image.pngData() else {
            AppLogger.shared.error("PatternSource", "stitch_failed", metadata: ["pages": pages.count])
            return nil
        }
        AppLogger.shared.info("PatternSource", "stitched", metadata: [
            "pages": pages.count,
            "width": Int(canvasWidth), "height": Int(canvasHeight),
            "bytes": png.count
        ])
        return png
    }

    /// 摆正之后的像素尺寸。`ImageDownsampler.pixelSize` 不管 EXIF 方向，
    /// 竖着拍的照片会读成横的，拼的时候那一页就被压扁了。
    private static func orientedPixelSize(of data: Data) -> CGSize? {
        guard let size = ImageDownsampler.pixelSize(of: data) else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let orientation = properties[kCGImagePropertyOrientation] as? UInt32,
              (5...8).contains(orientation) else { return size }
        return CGSize(width: size.height, height: size.width)
    }

    private static func cornerColor(of data: Data) -> UIColor? {
        guard let small = ImageDownsampler.downsampleToUIImage(data, maxPixelSize: 64)?.cgImage,
              let corner = small.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1)) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(corner, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                       blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }
}
