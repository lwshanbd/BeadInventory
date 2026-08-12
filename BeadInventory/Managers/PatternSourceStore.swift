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
//  **只有多零件模式**。列表、日历、详情页一律走 `displayThumbnail` / `thumbnail`，
//  跟这里完全隔离 —— 这份文件是全分辨率的，任何一个会批量渲染的地方碰它都是 jetsam。
//
//  ## 什么时候没有
//
//  很多时候都没有：开关关掉的、这个功能上线前就存在的项目、从别的设备同步过来的
//  （它不同步）、用户点过「拼好了」的。所以**调用方必须能在没有原图时照常工作**，
//  退回用 SwiftData 里那份压缩图，只是糊一点。
//

import Foundation
import UIKit

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
    /// - Parameter data: 用户选的那张图的**原始字节**（相册选图能直接拿到）。
    static func save(_ data: Data, for projectId: UUID) {
        guard let url = url(for: projectId) else { return }
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
        } catch {
            // 存不下不是错误路径 —— 拼图模式退回用压缩图照常能用，不要打扰用户
            AppLogger.shared.warning("PatternSource", "save_failed", metadata: [
                "projectId": projectId.uuidString, "error": "\(error)"
            ])
        }
    }

    /// 没有原始字节可用时（裁过封面、相机拍的、Share Extension 传进来的）拿什么存。
    ///
    /// **PNG，无损。** 这里以前是 `jpegData(0.95)` —— 用户传一张 5.8 MB 的图纸，
    /// 走裁剪那条路存下来只剩两三 MB，他在零件清单看到「留了一份原图，占 2.1 MB」，
    /// 结论只能是「你还是压了我的图」。他是对的：0.95 也是有损，色块边界该糊还是糊，
    /// 而这份图存在的唯一理由就是逐格看颜色。
    ///
    /// 拼豆图纸是大片纯色块，PNG 压得极好（实测 3640×5320 的图纸只有 207 KB）；
    /// 真正会变大的是拍照进来的那种，而那种本来也没有原始字节可用。
    /// 存不下就是存不下 —— 拼图模式退回用压缩图照常能走。
    static func lossless(_ image: UIImage?) -> Data? {
        image?.pngData()
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

    /// 删掉某个项目的原图。
    /// 两个调用点：用户点「拼好了」，以及项目被删除（后者是资源正确性，
    /// 不删就永远留下一个谁也不会再读的孤儿文件）。
    static func remove(for projectId: UUID) {
        guard let url = url(for: projectId) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
