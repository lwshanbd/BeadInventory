//
//  SharedImageManager.swift
//  BeadInventory
//
//  处理从 Share Extension 传入的图片
//

import SwiftUI
import UIKit

/// 共享图片管理器 - 用于主 App 和 Share Extension 之间传递图片
@MainActor
class SharedImageManager: ObservableObject {
    static let shared = SharedImageManager()

    /// App Group 标识符 - 需要在 Xcode 中配置
    static let appGroupIdentifier = "group.com.beadinventory.shared"

    /// 共享图片的文件名
    private let sharedImageFileName = "shared_image.jpg"

    /// 标记文件名（表示有新图片待处理）
    private let pendingFlagFileName = "pending_image"

    /// 当前待处理的共享图片
    @Published var pendingImage: UIImage?

    /// 是否有待处理的图片
    @Published var hasPendingImage: Bool = false

    private init() {}

    /// 获取 App Group 共享容器 URL
    var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier)
    }

    /// 共享图片的完整路径
    var sharedImageURL: URL? {
        sharedContainerURL?.appendingPathComponent(sharedImageFileName)
    }

    /// 待处理标记文件路径
    var pendingFlagURL: URL? {
        sharedContainerURL?.appendingPathComponent(pendingFlagFileName)
    }

    // MARK: - Share Extension 使用的方法

    /// 保存图片到共享容器（由 Share Extension 调用）
    func saveSharedImage(_ image: UIImage) -> Bool {
        guard let imageURL = sharedImageURL,
              let flagURL = pendingFlagURL else {
            print("SharedImageManager: 无法获取共享容器路径")
            return false
        }

        // PNG 无损保存（拼图模式需要原图做网格识别）
        guard let imageData = image.pngData() else {
            print("SharedImageManager: PNG 编码失败")
            return false
        }

        do {
            // 保存图片
            try imageData.write(to: imageURL)

            // 创建待处理标记文件
            try Data().write(to: flagURL)

            print("SharedImageManager: 图片已保存到共享容器")
            return true
        } catch {
            print("SharedImageManager: 保存图片失败 - \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 主 App 使用的方法

    /// 检查是否有待处理的共享图片
    func checkForPendingImage() {
        guard let flagURL = pendingFlagURL,
              let imageURL = sharedImageURL else {
            return
        }

        // 检查标记文件是否存在
        guard FileManager.default.fileExists(atPath: flagURL.path) else {
            return
        }

        // 加载图片
        if let imageData = try? Data(contentsOf: imageURL),
           let image = UIImage(data: imageData) {
            DispatchQueue.main.async {
                self.pendingImage = image
                self.hasPendingImage = true
            }
            print("SharedImageManager: 发现待处理的共享图片")
        }

        // 删除标记文件（表示已处理）
        try? FileManager.default.removeItem(at: flagURL)
    }

    /// 清除待处理的图片
    func clearPendingImage() {
        pendingImage = nil
        hasPendingImage = false

        // 清理共享容器中的文件
        if let imageURL = sharedImageURL {
            try? FileManager.default.removeItem(at: imageURL)
        }
        if let flagURL = pendingFlagURL {
            try? FileManager.default.removeItem(at: flagURL)
        }
    }

    /// 获取并消费待处理的图片
    func consumePendingImage() -> UIImage? {
        let image = pendingImage
        clearPendingImage()
        return image
    }
}
