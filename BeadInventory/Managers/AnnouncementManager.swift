//
//  AnnouncementManager.swift
//  BeadInventory
//
//  远程公告管理器 - 静默检查并展示公告
//

import Foundation

/// 公告数据模型
struct Announcement: Codable {
    let v: Int          // 格式版本，必须为 1
    let id: String      // 公告唯一标识
    let title: String   // 公告标题
    let message: String // 公告内容
    let ts: Int         // 时间戳（Unix），用于过滤过期/未来公告
}

/// 远程公告管理器
/// 在 App 启动时静默访问指定 URL，若内容通过格式校验则弹出公告
class AnnouncementManager: ObservableObject {
    static let shared = AnnouncementManager()

    // MARK: - 配置

    /// 公告数据 URL
    /// 托管于 GitHub Pages（源: main 分支 /docs 目录）
    private let announcementURL = "https://lwshanbd.github.io/BeadInventory/announcement.json"

    /// 已展示公告 ID 的 UserDefaults key
    private let shownIDsKey = "AnnouncementManager.shownIDs"

    // MARK: - 状态

    /// 当前待展示的公告（UI 层监听此属性）
    @Published var currentAnnouncement: Announcement?

    private init() {}

    // MARK: - 公开方法

    /// 静默检查远程公告（App 启动时调用）
    func checkForAnnouncement() {
        AppLogger.shared.info("Announcement", "check_started")

        guard let url = URL(string: announcementURL) else {
            AppLogger.shared.error("Announcement", "url_invalid", metadata: ["url": announcementURL])
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                AppLogger.shared.info("Announcement", "fetch_failed", metadata: ["error": "\(error.localizedDescription)"])
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                AppLogger.shared.warning("Announcement", "fetch_no_http_response")
                return
            }
            guard httpResponse.statusCode == 200 else {
                AppLogger.shared.warning("Announcement", "fetch_non_200", metadata: ["status": "\(httpResponse.statusCode)"])
                return
            }
            guard let data = data else {
                AppLogger.shared.warning("Announcement", "fetch_empty_body")
                return
            }

            guard let announcement = self.parseAndValidate(data: data) else {
                return
            }

            if self.hasShown(id: announcement.id) {
                AppLogger.shared.info("Announcement", "already_shown", metadata: ["id": announcement.id])
                return
            }

            AppLogger.shared.info("Announcement", "validated", metadata: ["id": announcement.id])
            DispatchQueue.main.async {
                self.currentAnnouncement = announcement
            }
        }.resume()
    }

    /// 标记公告已展示
    func markAsShown(_ announcement: Announcement) {
        var shownIDs = getShownIDs()
        shownIDs.insert(announcement.id)
        // 只保留最近 50 条记录，防止无限增长
        if shownIDs.count > 50 {
            let sorted = shownIDs.sorted()
            shownIDs = Set(sorted.suffix(50))
        }
        UserDefaults.standard.set(Array(shownIDs), forKey: shownIDsKey)
    }

    /// 清除公告状态
    func dismiss() {
        if let announcement = currentAnnouncement {
            markAsShown(announcement)
        }
        currentAnnouncement = nil
    }

    // MARK: - 内部方法

    /// 解析 JSON 并进行格式校验
    private func parseAndValidate(data: Data) -> Announcement? {
        guard let announcement = try? JSONDecoder().decode(Announcement.self, from: data) else {
            AppLogger.shared.warning("Announcement", "json_decode_failed")
            return nil
        }

        guard announcement.v == 1 else {
            AppLogger.shared.warning("Announcement", "version_unsupported", metadata: ["v": "\(announcement.v)"])
            return nil
        }

        guard !announcement.id.isEmpty,
              !announcement.title.isEmpty,
              !announcement.message.isEmpty else {
            AppLogger.shared.warning("Announcement", "empty_fields")
            return nil
        }

        // 时间戳合理性校验：过滤过旧或未来公告，防止忘记撤下的旧公告被重新展示
        let now = Int(Date().timeIntervalSince1970)
        let maxAge = 90 * 24 * 3600 // 90 天
        guard announcement.ts > (now - maxAge), announcement.ts <= (now + 3600) else {
            AppLogger.shared.warning("Announcement", "timestamp_out_of_range", metadata: ["ts": "\(announcement.ts)", "now": "\(now)"])
            return nil
        }

        return announcement
    }

    /// 获取已展示过的公告 ID 集合
    private func getShownIDs() -> Set<String> {
        let array = UserDefaults.standard.stringArray(forKey: shownIDsKey) ?? []
        return Set(array)
    }

    /// 检查指定公告是否已展示
    private func hasShown(id: String) -> Bool {
        return getShownIDs().contains(id)
    }
}
