//
//  AnnouncementManager.swift
//  BeadInventory
//
//  远程公告管理器 - 静默检查并展示公告
//

import Foundation
import CryptoKit

/// 公告数据模型
struct Announcement: Codable {
    let v: Int          // 格式版本，必须为 1
    let id: String      // 公告唯一标识
    let title: String   // 公告标题
    let message: String // 公告内容
    let ts: Int         // 时间戳（Unix）
    let sig: String     // HMAC-SHA256 签名（hex）
}

/// 远程公告管理器
/// 在 App 启动时静默访问指定 URL，若内容通过格式和签名校验则弹出公告
class AnnouncementManager: ObservableObject {
    static let shared = AnnouncementManager()

    // MARK: - 配置

    /// 公告数据 URL（修改为你的实际地址）
    /// 推荐用 GitHub Gist raw URL、GitHub Pages 或任何静态 JSON 托管
    private let announcementURL = "https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/announcement.json"

    /// HMAC 签名密钥（务必替换为你自己的密钥，保持保密）
    /// 用于验证公告确实由你发布，防止 URL 被劫持后伪造公告
    private let hmacKey = "REPLACE_WITH_YOUR_SECRET_KEY_HERE"

    /// 已展示公告 ID 的 UserDefaults key
    private let shownIDsKey = "AnnouncementManager.shownIDs"

    // MARK: - 状态

    /// 当前待展示的公告（UI 层监听此属性）
    @Published var currentAnnouncement: Announcement?

    private init() {}

    // MARK: - 公开方法

    /// 静默检查远程公告（App 启动时调用）
    func checkForAnnouncement() {
        guard let url = URL(string: announcementURL) else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            // 网络错误或非 200 状态码，静默忽略
            guard error == nil,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let data = data else {
                return
            }

            // 解析并校验
            guard let announcement = self.parseAndValidate(data: data) else {
                return
            }

            // 检查是否已经展示过
            if self.hasShown(id: announcement.id) {
                return
            }

            // 在主线程发布公告
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

    /// 解析 JSON 并进行完整校验
    private func parseAndValidate(data: Data) -> Announcement? {
        // 1. JSON 解析
        guard let announcement = try? JSONDecoder().decode(Announcement.self, from: data) else {
            return nil
        }

        // 2. 格式版本校验
        guard announcement.v == 1 else {
            return nil
        }

        // 3. 字段非空校验
        guard !announcement.id.isEmpty,
              !announcement.title.isEmpty,
              !announcement.message.isEmpty,
              !announcement.sig.isEmpty else {
            return nil
        }

        // 4. 时间戳合理性校验（不接受超过 90 天前或未来的公告）
        let now = Int(Date().timeIntervalSince1970)
        let maxAge = 90 * 24 * 3600 // 90 天
        guard announcement.ts > (now - maxAge), announcement.ts <= (now + 3600) else {
            return nil
        }

        // 5. HMAC-SHA256 签名校验
        guard verifySignature(announcement) else {
            return nil
        }

        return announcement
    }

    /// 验证 HMAC-SHA256 签名
    /// 签名内容 = "v|id|title|message|ts"
    private func verifySignature(_ announcement: Announcement) -> Bool {
        let payload = "\(announcement.v)|\(announcement.id)|\(announcement.title)|\(announcement.message)|\(announcement.ts)"
        guard let payloadData = payload.data(using: .utf8),
              let keyData = hmacKey.data(using: .utf8) else {
            return false
        }

        let key = SymmetricKey(data: keyData)
        let mac = HMAC<SHA256>.authenticationCode(for: payloadData, using: key)
        let computedSig = mac.map { String(format: "%02x", $0) }.joined()

        // 使用常量时间比较，防止时序攻击
        guard computedSig.count == announcement.sig.lowercased().count else {
            return false
        }
        var result: UInt8 = 0
        for (a, b) in zip(computedSig.utf8, announcement.sig.lowercased().utf8) {
            result |= a ^ b
        }
        return result == 0
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
