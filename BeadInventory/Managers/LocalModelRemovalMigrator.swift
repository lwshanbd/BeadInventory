//
//  LocalModelRemovalMigrator.swift
//  BeadInventory
//
//  一次性升级迁移：本地模型识别下线后的善后
//

import Foundation

/// 本地模型识别下线后的一次性迁移。
///
/// 旧版本支持把 Qwen VLM 下到手机上做离线识别。这个功能已经整条移除，只剩两件事需要善后：
///
/// 1. **告诉用户识别方式变了。** 旧配置里 `backend == "本地模型"` 的用户，升级后会直接落到
///    云端那条路。如果他早年配过 API Key，界面上不会有任何异常——按钮照样能点，图片却开始
///    离开手机了。这种事必须明说一次。
/// 2. **把下过的模型删掉。** 模型落在 Documents/Caches 下的 `huggingface/models/...`，
///    单个 625 MB ~ 1.72 GB，Documents 还不会被系统自动清理、会进备份。删除入口已经随
///    `LocalModelManager` 一起没了，不主动清就是永久占地且用户无从下手。
///
/// 只跑一次，跑完落一个 flag。清理走后台线程（删几 GB 是真 IO）。
@MainActor
final class LocalModelRemovalMigrator: ObservableObject {
    static let shared = LocalModelRemovalMigrator()

    /// 需要向用户明说一次的迁移结果。为 nil 表示不用打扰用户。
    @Published private(set) var pendingNotice: Notice?

    struct Notice: Equatable {
        /// 这个用户升级前正在用本地识别（图片以前不出手机，现在会上传）
        let wasUsingLocalRecognition: Bool
        /// 清理掉的模型文件大小，0 表示没删到东西
        let freedBytes: Int64

        var title: String {
            wasUsingLocalRecognition
                ? String(localized: "本地模型识别已下线")
                : String(localized: "已清理本地模型残留")
        }

        var message: String {
            var lines: [String] = []
            if wasUsingLocalRecognition {
                lines.append(String(localized: "你之前用的是手机上的本地模型识别，这个功能已经下线。现在扫描统一走云端 API——识别时图片会上传到你配置的服务商（Kimi / OpenAI 等）。"))
                lines.append(String(localized: "如果还没填过 API Key，可以在「更多 → 设置 → AI 图像识别」里填。"))
            }
            if freedBytes > 0 {
                lines.append(String(localized: "之前下载的模型文件已经自动删除，给手机腾出了 \(Self.formatted(freedBytes))。"))
            }
            return lines.joined(separator: "\n\n")
        }

        private static func formatted(_ bytes: Int64) -> String {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            formatter.allowedUnits = [.useMB, .useGB]
            return formatter.string(fromByteCount: bytes)
        }
    }

    private let migratedKey = "LocalModelRemoval.migrated.v1"
    private let legacyConfigKey = "AIServiceConfig"
    private let legacyDownloadedPathsKey = "LocalRecognitionModelDownloadedPaths"

    /// 旧 `RecognitionBackend.local` 的 rawValue。当年直接拿中文 UI 文案当持久化键，
    /// 所以这里必须逐字对上，不能改。
    private let legacyLocalBackendRawValue = "本地模型"

    /// 旧 `LocalRecognitionModel.repositoryID`，用来拼出模型目录。
    private let legacyRepositoryIDs = [
        "mlx-community/Qwen3.5-0.8B-MLX-4bit",
        "mlx-community/Qwen3.5-2B-4bit"
    ]

    private init() {}

    /// App 启动时调用一次。已经迁移过就直接返回。
    func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedKey) else { return }

        let wasUsingLocal = legacyBackendWasLocal()
        let candidates = residueDirectories()

        Task.detached(priority: .utility) { [legacyDownloadedPathsKey, migratedKey] in
            let freed = Self.removeResidue(at: candidates)

            await MainActor.run {
                let defaults = UserDefaults.standard
                defaults.removeObject(forKey: legacyDownloadedPathsKey)
                defaults.set(true, forKey: migratedKey)

                AppLogger.shared.info("LocalModelRemoval", "migration_done", metadata: [
                    "wasUsingLocal": "\(wasUsingLocal)",
                    "freedBytes": "\(freed)"
                ])

                if wasUsingLocal || freed > 0 {
                    self.pendingNotice = Notice(wasUsingLocalRecognition: wasUsingLocal, freedBytes: freed)
                }
            }
        }
    }

    /// 用户点掉提示。
    func acknowledgeNotice() {
        pendingNotice = nil
    }

    // MARK: - 旧配置探测

    /// 直接读原始 JSON，而不是解码成 `AIConfig`——`backend` 这个字段在新版 `AIConfig`
    /// 里已经不存在了，解码时会被静默丢弃，事后无从判断用户升级前用的是哪条路。
    private func legacyBackendWasLocal() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: legacyConfigKey),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["backend"] as? String == legacyLocalBackendRawValue
    }

    // MARK: - 残留清理

    /// 拼出所有可能的模型目录：两处 `UserDefaults` 记下的实际路径 + 两个搜索目录下的约定路径。
    private func residueDirectories() -> [URL] {
        var candidates: [URL] = []

        // 旧代码把实际下载路径存了下来（HubApi 解析出的位置不一定等于约定路径）
        if let data = UserDefaults.standard.data(forKey: legacyDownloadedPathsKey),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            candidates.append(contentsOf: saved.values.map { URL(fileURLWithPath: $0, isDirectory: true) })
        }

        for searchDirectory in [FileManager.SearchPathDirectory.documentDirectory, .cachesDirectory] {
            guard let base = FileManager.default.urls(for: searchDirectory, in: .userDomainMask).first else {
                continue
            }
            let modelsRoot = base
                .appendingPathComponent("huggingface", isDirectory: true)
                .appendingPathComponent("models", isDirectory: true)
            for repositoryID in legacyRepositoryIDs {
                let directory = repositoryID
                    .split(separator: "/")
                    .reduce(modelsRoot) { $0.appendingPathComponent(String($1), isDirectory: true) }
                candidates.append(directory)
            }
        }

        // 去重，并且只保留路径尾部确实是 `models/<owner>/<repo>` 的——存下来的路径可能被
        // 改过、可能指向别处，宁可漏删也不能删错目录。
        var seen = Set<String>()
        return candidates.filter { url in
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { return false }
            return Self.isLegacyModelPath(url, allowedRepositoryIDs: legacyRepositoryIDs)
        }
    }

    /// 路径尾部必须是 `models/mlx-community/<已知模型名>`，否则一律不碰。
    nonisolated private static func isLegacyModelPath(_ url: URL, allowedRepositoryIDs: [String]) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        return allowedRepositoryIDs.contains { repositoryID in
            let expected = ["models"] + repositoryID.split(separator: "/").map(String.init)
            return Array(components.suffix(expected.count)) == expected
        }
    }

    /// 删除目录并返回释放的字节数。删完顺手把空掉的 `mlx-community` / `models` / `huggingface` 收掉。
    nonisolated private static func removeResidue(at directories: [URL]) -> Int64 {
        let fileManager = FileManager.default
        var freed: Int64 = 0
        var parentsToPrune: [URL] = []

        for directory in directories {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }

            let size = directorySize(directory)
            do {
                try fileManager.removeItem(at: directory)
                freed += size
                AppLogger.shared.info("LocalModelRemoval", "residue_removed", metadata: [
                    "bytes": "\(size)"
                ])
                // mlx-community → models → huggingface
                parentsToPrune.append(contentsOf: [
                    directory.deletingLastPathComponent(),
                    directory.deletingLastPathComponent().deletingLastPathComponent(),
                    directory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                ])
            } catch {
                // 不吞：删不掉的话用户会看到存储一直占着，日志是唯一线索
                AppLogger.shared.error("LocalModelRemoval", "residue_remove_failed", metadata: [
                    "error": "\(error.localizedDescription)"
                ])
            }
        }

        for parent in parentsToPrune {
            let isEmpty = (try? fileManager.contentsOfDirectory(atPath: parent.path))?.isEmpty ?? false
            guard isEmpty else { continue }
            try? fileManager.removeItem(at: parent)
        }

        return freed
    }

    nonisolated private static func directorySize(_ directory: URL) -> Int64 {
        guard let enumerator = fileManager_enumerator(directory) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }

    nonisolated private static func fileManager_enumerator(_ directory: URL) -> FileManager.DirectoryEnumerator? {
        FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: []
        )
    }
}
