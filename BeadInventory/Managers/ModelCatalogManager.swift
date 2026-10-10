//
//  ModelCatalogManager.swift
//  BeadInventory
//
//  AI 模型清单的在线更新。
//
//  每次 App 变成活跃状态（冷启动、回前台）去 GitHub Pages 拉一份 models.json。拉到了、而且跟本地不同，就换上并缓存；
//  拉不到就用上次缓存的那份，连缓存都没有就用下面写死的内置清单。
//
//  用户选的模型只在「新清单里已经没有它」时才会被换成该 provider 的默认模型，
//  清单里的 default 不会去覆盖用户还能用的选择。这条规则落在
//  `AIServiceManager.normalizedConfig` 里，这里只负责提供清单。
//

import Foundation

/// 一个 provider 能选的模型，以及它的默认模型
struct ProviderModels: Codable, Equatable {
    let models: [String]
    let `default`: String
}

/// models.json 的格式。providers 的 key 是 `AIProvider.rawValue`（"Kimi"、"OpenAI"……）。
struct ModelCatalog: Codable, Equatable {
    let v: Int
    let providers: [String: ProviderModels]
}

final class ModelCatalogManager {
    static let shared = ModelCatalogManager()

    // MARK: - 配置

    /// 托管于 GitHub Pages（源: main 分支 /docs 目录），跟公告同一个站点
    private let catalogURL = "https://lwshanbd.github.io/BeadInventory/models.json"

    /// 上一次拉到并合并好的完整清单（ModelCatalog 格式）
    private let cacheKey = "ModelCatalogManager.cachedCatalog"

    /// 内置清单：从没拉到过远端清单时用它。
    /// 2026-10 更新（照各家官方模型文档）。均需支持图像输入（识别用）。
    /// 改这里要同步改 docs/models.json。
    static let builtIn: [AIProvider: ProviderModels] = [
        // Kimi：默认 K2.6（长期可用）；K3 为旗舰，原生视觉。
        .kimi: ProviderModels(models: ["kimi-k2.6", "kimi-k3"], default: "kimi-k2.6"),
        // OpenAI：GPT-6 家族（luna 入门 / 6.1-sol 中档 / astra 旗舰）为主；GPT-5.6 尚未弃用，保留给已经在用的人。
        // gpt-6-sol 官方定位是编程和 agent，不放进来。
        .openai: ProviderModels(models: ["gpt-6-luna", "gpt-6.1-sol", "gpt-6-astra", "gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol"], default: "gpt-6-luna"),
        // Anthropic：当前这一代，外加 Haiku 4.5。Haiku 4.5 虽归入 legacy 但没停服，
        // 去掉的话选它的人会被换到贵一倍的默认 sonnet-5-5。
        // Sonnet 5 / Opus 4.8 / Fable 5 等去掉，选着它们的用户会被换到默认的 sonnet-5-5。
        .anthropic: ProviderModels(models: ["claude-sonnet-5-5", "claude-haiku-5-5", "claude-opus-5-5", "claude-fable-5-1", "claude-haiku-4-5"], default: "claude-sonnet-5-5"),
        // Qwen：百炼当前模型页上能看图的主线模型。3.6 和 qwen3-vl 已不在模型页上，去掉。
        .qwen: ProviderModels(models: ["qwen3.8-flash", "qwen3.7-plus", "qwen3.8-max"], default: "qwen3.8-flash"),
        // Gemini：3.8-flash 为最新稳定版；3.5-flash 已被 Google 服务端转到 3.6-flash，去掉
        // （选着它的用户会被换到默认的 3.8-flash）；3.1-pro 仍是 preview ID
        .gemini: ProviderModels(models: ["gemini-3.8-flash", "gemini-3.6-flash", "gemini-3.5-flash-lite", "gemini-3.1-pro-preview"], default: "gemini-3.8-flash"),
    ]

    // MARK: - 状态

    // AIConfig.init 等非主线程路径也会读清单，用锁护着，不挂在 MainActor 上
    private let lock = NSLock()
    private var current: [AIProvider: ProviderModels]
    private var isFetching = false

    private init() {
        // 同步读缓存：AIServiceManager 初始化时就要拿它校验用户存的模型。
        // 要是这里先用内置清单，用户选了个只在远端清单里有的新模型，一启动就会被打回默认。
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let cached = Self.resolve(data: data, base: Self.builtIn) {
            current = cached
            AppLogger.shared.info("ModelCatalog", "loaded_from_cache")
        } else {
            current = Self.builtIn
        }
    }

    // MARK: - 读

    func entry(for provider: AIProvider) -> ProviderModels {
        lock.lock()
        defer { lock.unlock() }
        return current[provider] ?? Self.builtIn[provider]!
    }

    // MARK: - 刷新

    /// 静默拉一次远端清单。跟本地不同才替换、才通知 AIServiceManager。
    func refresh() {
        lock.lock()
        if isFetching {
            lock.unlock()
            return
        }
        isFetching = true
        lock.unlock()

        guard let url = URL(string: catalogURL) else {
            AppLogger.shared.error("ModelCatalog", "url_invalid", metadata: ["url": catalogURL])
            finishFetching()
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            defer { self.finishFetching() }

            if let error {
                AppLogger.shared.info("ModelCatalog", "fetch_failed", metadata: ["error": "\(error.localizedDescription)"])
                return
            }
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200, let data else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                AppLogger.shared.warning("ModelCatalog", "fetch_bad_response", metadata: ["status": "\(status)"])
                return
            }
            self.lock.lock()
            let base = self.current
            self.lock.unlock()
            guard let resolved = Self.resolve(data: data, base: base) else { return }

            self.lock.lock()
            let changed = resolved != self.current
            if changed { self.current = resolved }
            self.lock.unlock()

            guard changed else {
                AppLogger.shared.info("ModelCatalog", "unchanged")
                return
            }

            // 存合并后的结果，不存远端原文：远端这次漏写的 provider，下次冷启动也还是上一份清单里的
            let merged = ModelCatalog(v: 1, providers: Dictionary(uniqueKeysWithValues: resolved.map { ($0.key.rawValue, $0.value) }))
            if let encoded = try? JSONEncoder().encode(merged) {
                UserDefaults.standard.set(encoded, forKey: self.cacheKey)
            }
            AppLogger.shared.info("ModelCatalog", "updated")
            Task { @MainActor in
                AIServiceManager.shared.modelCatalogDidChange()
            }
        }.resume()
    }

    private func finishFetching() {
        lock.lock()
        isFetching = false
        lock.unlock()
    }

    // MARK: - 解析

    /// 解析 models.json，在 base 上逐个 provider 覆盖。远端没写或写空的 provider 保留 base 里的。
    /// 整份不认识就返回 nil（不替换、不缓存）。
    private static func resolve(data: Data, base: [AIProvider: ProviderModels]) -> [AIProvider: ProviderModels]? {
        guard let catalog = try? JSONDecoder().decode(ModelCatalog.self, from: data) else {
            AppLogger.shared.warning("ModelCatalog", "json_decode_failed")
            return nil
        }
        guard catalog.v == 1 else {
            AppLogger.shared.warning("ModelCatalog", "version_unsupported", metadata: ["v": "\(catalog.v)"])
            return nil
        }

        var result = base
        for provider in AIProvider.allCases {
            guard let remote = catalog.providers[provider.rawValue] else { continue }

            // 去空白、去重，保持原顺序（顺序就是设置页里的显示顺序）
            var seen = Set<String>()
            let models = remote.models
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
            guard !models.isEmpty else {
                AppLogger.shared.warning("ModelCatalog", "provider_empty", metadata: ["provider": provider.rawValue])
                continue
            }

            // default 写错了（不在列表里）就退到列表第一个，免得把用户强制换到一个不存在的模型上
            let declaredDefault = remote.default.trimmingCharacters(in: .whitespacesAndNewlines)
            let defaultModel: String
            if models.contains(declaredDefault) {
                defaultModel = declaredDefault
            } else {
                AppLogger.shared.warning(
                    "ModelCatalog", "default_not_in_models",
                    metadata: ["provider": provider.rawValue, "default": declaredDefault]
                )
                defaultModel = models[0]
            }

            result[provider] = ProviderModels(models: models, default: defaultModel)
        }
        return result
    }
}
