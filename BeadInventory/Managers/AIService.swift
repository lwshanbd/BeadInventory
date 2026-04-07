//
//  AIService.swift
//  BeadInventory
//
//  AI图像识别服务 - 支持 Kimi、OpenAI、Anthropic、Qwen 和 Gemini
//

import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Combine
import Metal
import Hub
import MLX
import MLXLMCommon
import MLXVLM

// MARK: - AI 配置

enum RecognitionBackend: String, CaseIterable, Codable {
    case cloud = "云端模型"
    case local = "本地模型"

    var displayName: String {
        switch self {
        case .cloud: return String(localized: "云端模型")
        case .local: return String(localized: "本地模型")
        }
    }
}

enum AIProvider: String, CaseIterable, Codable {
    case kimi = "Kimi"
    case openai = "OpenAI"
    case anthropic = "Anthropic"
    case qwen = "Qwen"
    case gemini = "Gemini"
}

enum LocalRecognitionModel: String, CaseIterable, Codable, Identifiable {
    case qwen35_08b
    case qwen35_2b

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .qwen35_08b:
            return "Qwen3.5 0.8B (4bit)"
        case .qwen35_2b:
            return "Qwen3.5 2B (4bit)"
        }
    }

    var repositoryID: String {
        switch self {
        case .qwen35_08b:
            return "mlx-community/Qwen3.5-0.8B-MLX-4bit"
        case .qwen35_2b:
            return "mlx-community/Qwen3.5-2B-4bit"
        }
    }

    var approximateDownloadSize: String {
        switch self {
        case .qwen35_08b:
            return String(localized: "约 625 MB")
        case .qwen35_2b:
            return String(localized: "约 1.72 GB")
        }
    }

    var approximateStorageSize: String {
        approximateDownloadSize
    }

    var minimumRecommendedIPhoneGeneration: Int {
        switch self {
        case .qwen35_08b:
            return 14
        case .qwen35_2b:
            return 15
        }
    }

    var recommendationText: String {
        switch self {
        case .qwen35_08b:
            return String(localized: "推荐 iPhone 14 及以上机型优先选择，门槛更低，下载更小。")
        case .qwen35_2b:
            return String(localized: "推荐 iPhone 15 及以上机型选择，效果通常更好，但体积和负载更高。")
        }
    }

    var cautionText: String {
        switch self {
        case .qwen35_08b:
            return String(localized: "准确度会略低于云端识别，速度相对更慢，也可能带来发热。")
        case .qwen35_2b:
            return String(localized: "准确度通常高于 0.8B，但首次加载更久，更容易造成发热和内存压力。")
        }
    }
}

struct LocalModelDeviceProfile {
    let identifier: String

    static var current: LocalModelDeviceProfile {
        LocalModelDeviceProfile(identifier: currentIdentifier())
    }

    private static func currentIdentifier() -> String {
        if let simulatorModel = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"],
           !simulatorModel.isEmpty {
            return simulatorModel
        }

        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { cString in
                String(cString: cString)
            }
        }
    }

    private var marketedIPhoneGeneration: Int? {
        switch identifier {
        case "iPhone14,7", "iPhone14,8", "iPhone15,2", "iPhone15,3":
            return 14
        case "iPhone15,4", "iPhone15,5", "iPhone16,1", "iPhone16,2":
            return 15
        case let value where value.hasPrefix("iPhone17,"):
            return 16
        case let value where value.hasPrefix("iPhone18,"):
            return 17
        default:
            return nil
        }
    }

    func recommendation(for model: LocalRecognitionModel) -> String {
        guard let marketedIPhoneGeneration else {
            return String(localized: "\(model.recommendationText) 如果机型较老，建议优先使用云端识别。")
        }

        if marketedIPhoneGeneration >= model.minimumRecommendedIPhoneGeneration {
            return String(localized: "当前设备约为 iPhone \(marketedIPhoneGeneration) 或更新机型，\(model.displayName) 可以尝试。")
        }

        return String(localized: "当前设备约为 iPhone \(marketedIPhoneGeneration)，不建议选择 \(model.displayName)。建议改用云端识别，或退而求其次选择更小的本地模型。")
    }

    var summaryText: String {
        guard let marketedIPhoneGeneration else {
            return String(localized: "建议按机型选择：iPhone 14 及以上优先尝试 0.8B，iPhone 15 及以上再考虑 2B。")
        }

        switch marketedIPhoneGeneration {
        case 15...:
            return String(localized: "当前设备约为 iPhone \(marketedIPhoneGeneration) 或更新机型，可优先尝试 2B；如更看重下载体积、速度和发热，也可以选 0.8B。")
        case 14:
            return String(localized: "当前设备约为 iPhone 14 系列，建议优先选择 0.8B；2B 负载偏高，不建议。")
        default:
            return String(localized: "当前设备约为 iPhone \(marketedIPhoneGeneration)，更建议使用云端识别；若必须本地运行，请谨慎尝试 0.8B。")
        }
    }
}

struct AIConfig: Codable, Equatable {
    var backend: RecognitionBackend
    var provider: AIProvider
    var apiKey: String
    var baseURL: String  // 自定义API地址，空则使用默认
    var model: String
    var enableCustomURL: Bool  // 是否启用自定义API地址
    var localModel: LocalRecognitionModel

    static let defaultKimiURL = "https://api.moonshot.cn/v1"
    static let defaultOpenAIURL = "https://api.openai.com/v1"
    static let defaultAnthropicURL = "https://api.anthropic.com"
    static let defaultQwenURL = "https://dashscope.aliyuncs.com/compatible-mode/v1"
    static let defaultGeminiURL = "https://generativelanguage.googleapis.com/v1beta"

    static let kimiModels = ["kimi-k2.5"]
    static let openAIModels = ["gpt-5-mini", "gpt-5-nano", "gpt-5.2"]
    static let anthropicModels = ["claude-sonnet-4-5-20250929", "claude-sonnet-4-20250514", "claude-3-5-sonnet-20241022", "claude-3-haiku-20240307"]
    static let qwenModels = ["qwen3-vl-flash", "qwen-vl-max", "qwen3-vl-plus"]
    static let geminiModels = ["gemini-3-flash-preview", "gemini-3-pro-preview"]

    static func defaultModel(for provider: AIProvider) -> String {
        switch provider {
        case .kimi:
            return "kimi-k2.5"
        case .openai:
            return "gpt-5-mini"
        case .anthropic:
            return "claude-sonnet-4-5-20250929"
        case .qwen:
            return "qwen3-vl-flash"
        case .gemini:
            return "gemini-3-flash-preview"
        }
    }

    init(
        backend: RecognitionBackend = .cloud,
        provider: AIProvider = .kimi,
        apiKey: String = "",
        baseURL: String = "",
        model: String = "",
        enableCustomURL: Bool = false,
        localModel: LocalRecognitionModel = .qwen35_08b
    ) {
        self.backend = backend
        self.provider = provider
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model.isEmpty ? AIConfig.defaultModel(for: provider) : model
        self.enableCustomURL = enableCustomURL
        self.localModel = localModel
    }

    // 兼容旧版配置（没有 backend / localModel / enableCustomURL 字段）
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        backend = try container.decodeIfPresent(RecognitionBackend.self, forKey: .backend) ?? .cloud
        provider = try container.decode(AIProvider.self, forKey: .provider)
        apiKey = try container.decode(String.self, forKey: .apiKey)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        model = try container.decode(String.self, forKey: .model)
        enableCustomURL = try container.decodeIfPresent(Bool.self, forKey: .enableCustomURL) ?? false
        localModel = try container.decodeIfPresent(LocalRecognitionModel.self, forKey: .localModel) ?? .qwen35_08b
    }

    var effectiveBaseURL: String {
        let customURL = enableCustomURL ? baseURL : ""
        switch provider {
        case .kimi:
            return customURL.isEmpty ? AIConfig.defaultKimiURL : customURL
        case .openai:
            return customURL.isEmpty ? AIConfig.defaultOpenAIURL : customURL
        case .anthropic:
            return customURL.isEmpty ? AIConfig.defaultAnthropicURL : customURL
        case .qwen:
            return customURL.isEmpty ? AIConfig.defaultQwenURL : customURL
        case .gemini:
            return customURL.isEmpty ? AIConfig.defaultGeminiURL : customURL
        }
    }

    var effectiveAPIKey: String {
        return apiKey
    }

    /// 检查当前 provider 的 API Key 格式是否可疑（不以 sk- 开头）
    var hasKeyFormatWarning: Bool {
        guard !apiKey.isEmpty else { return false }
        switch provider {
        case .kimi, .openai, .qwen:
            return !apiKey.hasPrefix("sk-")
        case .anthropic, .gemini:
            return false
        }
    }

    var effectiveModel: String {
        return model
    }
}

// MARK: - 本地模型管理

@MainActor
final class LocalModelManager: ObservableObject {
    static let shared = LocalModelManager()

    /// 检查当前设备是否支持 MLX 本地模型（需要 Apple GPU Family 7+，即 A14 及以上芯片）
    static let isDeviceSupported: Bool = {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return false
        }
        // Apple GPU Family 7 对应 A14+ 芯片，是 MLX 运行的最低要求
        return device.supportsFamily(.apple7)
    }()

    @Published private(set) var downloadProgress: [LocalRecognitionModel: Double] = [:]
    @Published private(set) var isDownloading: Set<LocalRecognitionModel> = []
    @Published private(set) var isDeleting: Set<LocalRecognitionModel> = []
    @Published private(set) var lastErrorByModel: [LocalRecognitionModel: String] = [:]
    @Published private(set) var downloadedPaths: [LocalRecognitionModel: String] = [:]
    @Published private(set) var loadedModel: LocalRecognitionModel?
    @Published private(set) var isLoadingModel = false

    private let downloadedPathsKey = "LocalRecognitionModelDownloadedPaths"
    private var container: ModelContainer?

    private init() {
        guard Self.isDeviceSupported else {
            AppLogger.shared.warning("LocalModel", "device_not_supported_for_mlx")
            return
        }

        if let data = UserDefaults.standard.data(forKey: downloadedPathsKey),
           let saved = try? JSONDecoder().decode([LocalRecognitionModel: String].self, from: data) {
            self.downloadedPaths = saved
        }

        refreshDownloadedModels()
    }

    func isDownloaded(_ model: LocalRecognitionModel) -> Bool {
        installedDirectory(for: model) != nil
    }

    func localDirectory(for model: LocalRecognitionModel) -> URL? {
        installedDirectory(for: model)
    }

    func progress(for model: LocalRecognitionModel) -> Double {
        downloadProgress[model] ?? 0
    }

    private func isPathCompatible(_ path: String, for model: LocalRecognitionModel) -> Bool {
        let normalizedComponents = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        let expectedComponents = ["models"] + model.repositoryID.split(separator: "/").map(String.init)
        return Array(normalizedComponents.suffix(expectedComponents.count)) == expectedComponents
    }

    func errorMessage(for model: LocalRecognitionModel) -> String? {
        lastErrorByModel[model]
    }

    func refreshDownloadedModels() {
        let resolvedPaths = LocalRecognitionModel.allCases.reduce(into: [LocalRecognitionModel: String]()) { result, model in
            if let directory = installedDirectory(for: model) {
                result[model] = directory.path
            }
        }

        if downloadedPaths != resolvedPaths {
            downloadedPaths = resolvedPaths
            persistDownloadedPaths()
        }

        if let loadedModel, resolvedPaths[loadedModel] == nil {
            unloadCurrentModel()
        }
    }

    func downloadModel(_ model: LocalRecognitionModel) async throws {
        guard Self.isDeviceSupported else {
            throw AIError.deviceNotSupported
        }

        if let existingDirectory = installedDirectory(for: model) {
            downloadedPaths[model] = existingDirectory.path
            downloadProgress[model] = 1
            lastErrorByModel[model] = nil
            persistDownloadedPaths()
            return
        }

        guard !isDownloading.contains(model) else { return }

        isDownloading.insert(model)
        downloadProgress[model] = 0
        lastErrorByModel[model] = nil

        defer {
            isDownloading.remove(model)
            if isDownloaded(model) {
                downloadProgress[model] = 1
            }
        }

        do {
            let repo = Hub.Repo(id: model.repositoryID)
            let directory = try await Hub.snapshot(from: repo) { progress in
                let total = progress.totalUnitCount
                let fraction = total > 0
                    ? Double(progress.completedUnitCount) / Double(total)
                    : progress.fractionCompleted

                Task { @MainActor in
                    self.downloadProgress[model] = max(0, min(fraction, 1))
                }
            }

            guard isInstalledDirectory(directory) else {
                throw AIError.parseError(String(localized: "模型文件不完整，请重试下载"))
            }

            downloadedPaths[model] = directory.path
            persistDownloadedPaths()
        } catch {
            lastErrorByModel[model] = error.localizedDescription
            throw error
        }
    }

    func deleteModel(_ model: LocalRecognitionModel) async throws {
        guard !isDeleting.contains(model) else { return }
        guard !isDownloading.contains(model) else {
            throw AIError.parseError(String(localized: "模型正在下载，暂时不能删除"))
        }

        isDeleting.insert(model)
        lastErrorByModel[model] = nil

        defer {
            isDeleting.remove(model)
        }

        if loadedModel == model {
            unloadCurrentModel()
        }

        let fileManager = FileManager.default
        let directories = candidateDirectories(for: model).filter {
            fileManager.fileExists(atPath: $0.path) && isPathCompatible($0.path, for: model)
        }

        do {
            for directory in directories {
                try fileManager.removeItem(at: directory)
            }

            downloadedPaths.removeValue(forKey: model)
            downloadProgress.removeValue(forKey: model)
            lastErrorByModel[model] = nil
            persistDownloadedPaths()
            refreshDownloadedModels()
        } catch {
            lastErrorByModel[model] = error.localizedDescription
            refreshDownloadedModels()
            throw error
        }
    }

    func ensureLoaded(_ model: LocalRecognitionModel) async throws -> ModelContainer {
        guard Self.isDeviceSupported else {
            throw AIError.deviceNotSupported
        }

        if loadedModel == model, let container {
            return container
        }

        if loadedModel != model {
            unloadCurrentModel()
        }

        guard let directory = localDirectory(for: model) else {
            throw AIError.localModelNotDownloaded(model.displayName)
        }

        isLoadingModel = true
        defer { isLoadingModel = false }

        Memory.cacheLimit = Self.localCacheLimit(for: model)
        print("[AI Debug] MLX cache limit: \(Self.debugMemoryDescription(Memory.cacheLimit))")

        let configuration = ModelConfiguration(directory: directory)
        let loadedContainer = try await VLMModelFactory.shared.loadContainer(configuration: configuration)
        self.container = loadedContainer
        self.loadedModel = model
        return loadedContainer
    }

    func recognize(image: UIImage, model: LocalRecognitionModel, systemPrompt: String, userPrompt: String) async throws -> String {
        let container = try await ensureLoaded(model)

        guard let ciImage = preparedCIImage(from: image, for: model) else {
            throw AIError.imageProcessingFailed
        }

        let input = UserInput(chat: [
            .system(systemPrompt),
            .user(userPrompt, images: [.ciImage(ciImage)])
        ])

        Memory.clearCache()
        Memory.peakMemory = 0

        defer {
            Memory.clearCache()
            let clearedMemory = Memory.snapshot()
            print("[AI Debug] MLX 内存(clearCache 后): \(Self.debugSnapshotLine(clearedMemory))")
        }

        let result = try await container.perform { context in
            let prepareStartMemory = Memory.snapshot()
            let preparedInput = try await context.processor.prepare(input: input)
            let prepareEndMemory = Memory.snapshot()
            let promptMemoryGrowth = prepareStartMemory.delta(prepareEndMemory)

            let promptTokens = preparedInput.text.tokens.asArray(Int.self)
            let imageFrames = preparedInput.image?.frames ?? []

            var imageTokenIndex: Int?
            var spatialMergeSize: Int?

            switch context.model {
            case let qwen35 as Qwen35:
                imageTokenIndex = qwen35.config.imageTokenIndex
                spatialMergeSize = qwen35.config.visionConfiguration.spatialMergeSize
            case let qwen3VL as Qwen3VL:
                imageTokenIndex = qwen3VL.config.imageTokenIndex
                spatialMergeSize = qwen3VL.config.visionConfiguration.spatialMergeSize
            default:
                break
            }

            let imageTokenCount =
                imageTokenIndex.map { tokenIndex in
                    promptTokens.reduce(into: 0) { count, token in
                        if token == tokenIndex {
                            count += 1
                        }
                    }
                }

            let estimatedImageTokenCount: Int? = {
                guard let spatialMergeSize, !imageFrames.isEmpty else {
                    return nil
                }
                let mergeArea = spatialMergeSize * spatialMergeSize
                return imageFrames.reduce(0) { total, frame in
                    total + (frame.product / mergeArea)
                }
            }()

            let frameSummary = imageFrames.map { frame in
                "\(frame.t)x\(frame.h)x\(frame.w)"
            }.joined(separator: ", ")

            if let imageTokenCount {
                print(
                    "[AI Debug] 本地 prompt tokens: 总计 \(promptTokens.count)，图像占位 \(imageTokenCount)，其余 \(max(promptTokens.count - imageTokenCount, 0))"
                )
            } else {
                print("[AI Debug] 本地 prompt tokens: 总计 \(promptTokens.count)，图像占位 token 无法直接统计")
            }

            if !frameSummary.isEmpty {
                print("[AI Debug] 本地图像网格 THW: \(frameSummary)")
            }

            if let estimatedImageTokenCount {
                if let spatialMergeSize {
                    print(
                        "[AI Debug] 本地图像 token 估算: \(estimatedImageTokenCount) (spatial merge size: \(spatialMergeSize))"
                    )
                } else {
                    print("[AI Debug] 本地图像 token 估算: \(estimatedImageTokenCount)")
                }
            }

            let maxGeneratedTokens = Self.localMaxGeneratedTokens(for: model)
            let maxKVSize = promptTokens.count + maxGeneratedTokens + 64
            let prefillStepSize = Self.localPrefillStepSize(for: model)
            let parameters = GenerateParameters(
                maxTokens: maxGeneratedTokens,
                maxKVSize: maxKVSize,
                temperature: 0.1,
                topP: 0.9,
                prefillStepSize: prefillStepSize
            )

            print(
                "[AI Debug] 本地生成参数: maxTokens=\(maxGeneratedTokens), maxKVSize=\(maxKVSize), prefillStepSize=\(prefillStepSize)"
            )
            print(
                "[AI Debug] MLX 内存(prepare 增量): \(Self.debugSnapshotLine(promptMemoryGrowth))"
            )

            let generationStartMemory = Memory.snapshot()
            let stream = try MLXLMCommon.generate(
                input: preparedInput,
                parameters: parameters,
                context: context
            )
            var generatedOutput = ""

            for await generation in stream {
                switch generation {
                case .chunk(let chunk):
                    generatedOutput += chunk
                case .info(let info):
                    print(
                        "[AI Debug] 本地生成完成: promptTokens=\(info.promptTokenCount), generationTokens=\(info.generationTokenCount), stopReason=\(info.stopReason)"
                    )
                case .toolCall(let call):
                    print("[AI Debug] 本地生成 tool call: \(call.function.name)")
                }
            }

            let generationEndMemory = Memory.snapshot()
            let generationGrowth = generationStartMemory.delta(generationEndMemory)

            print(
                "[AI Debug] MLX 内存(generate 结束): \(Self.debugSnapshotLine(generationEndMemory))"
            )
            print(
                "[AI Debug] MLX 内存(generate 增量): \(Self.debugSnapshotLine(generationGrowth))"
            )

            return generatedOutput
        }

        return result
    }

    private func persistDownloadedPaths() {
        if let data = try? JSONEncoder().encode(downloadedPaths) {
            UserDefaults.standard.set(data, forKey: downloadedPathsKey)
        }
    }

    private func unloadCurrentModel() {
        container = nil
        loadedModel = nil
        Memory.clearCache()
    }

    private func installedDirectory(for model: LocalRecognitionModel) -> URL? {
        candidateDirectories(for: model).first(where: isInstalledDirectory(_:))
    }

    private func candidateDirectories(for model: LocalRecognitionModel) -> [URL] {
        var candidates: [URL] = []

        if let savedPath = downloadedPaths[model], isPathCompatible(savedPath, for: model) {
            candidates.append(URL(fileURLWithPath: savedPath, isDirectory: true))
        }

        candidates.append(expectedDirectory(for: model, searchDirectory: .documentDirectory))
        candidates.append(expectedDirectory(for: model, searchDirectory: .cachesDirectory))

        var uniquePaths = Set<String>()
        return candidates.filter { url in
            uniquePaths.insert(url.standardizedFileURL.path).inserted
        }
    }

    private func expectedDirectory(
        for model: LocalRecognitionModel,
        searchDirectory: FileManager.SearchPathDirectory
    ) -> URL {
        guard let baseDirectory = FileManager.default.urls(for: searchDirectory, in: .userDomainMask).first else {
            AppLogger.shared.error("LocalModel", "user_domain_directory_unavailable", metadata: [
                "searchDirectory": "\(searchDirectory.rawValue)"
            ])
            // 兜底：使用 Application Support 目录，避免 tmp 被系统清理导致模型丢失
            let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            return fallback
                .appendingPathComponent("huggingface", isDirectory: true)
                .appendingPathComponent("models", isDirectory: true)
        }
        return model.repositoryID
            .split(separator: "/")
            .reduce(
                baseDirectory
                    .appendingPathComponent("huggingface", isDirectory: true)
                    .appendingPathComponent("models", isDirectory: true)
            ) { partialURL, component in
                partialURL.appendingPathComponent(String(component), isDirectory: true)
            }
    }

    private func isInstalledDirectory(_ directory: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }

        let requiredFiles = [
            "config.json",
            "tokenizer.json",
            "tokenizer_config.json"
        ]

        guard requiredFiles.allSatisfy({ fileManager.fileExists(atPath: directory.appendingPathComponent($0).path) }) else {
            return false
        }

        let hasProcessorConfig =
            fileManager.fileExists(atPath: directory.appendingPathComponent("preprocessor_config.json").path) ||
            fileManager.fileExists(atPath: directory.appendingPathComponent("processor_config.json").path)

        guard hasProcessorConfig else {
            return false
        }

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension == "safetensors" {
                return true
            }
        }

        return false
    }

    private func preparedCIImage(from image: UIImage, for model: LocalRecognitionModel) -> CIImage? {
        guard var ciImage = CIImage(image: image) else {
            return nil
        }

        // 本地视觉模型更容易受显存/内存峰值影响。这里做一次轻微锐化，
        // 再按比例缩图，尽量保留表格边缘，同时压低峰值内存。
        if let sharpenFilter = CIFilter(name: "CISharpenLuminance") {
            sharpenFilter.setValue(ciImage, forKey: kCIInputImageKey)
            sharpenFilter.setValue(0.22, forKey: kCIInputSharpnessKey)
            if let output = sharpenFilter.outputImage {
                ciImage = output
            }
        }

        let maxDimension = localImageMaxDimension(for: model)
        let extent = ciImage.extent.integral
        let longestEdge = max(extent.width, extent.height)

        guard longestEdge > maxDimension else {
            return ciImage
        }

        let scale = maxDimension / longestEdge
        if let lanczosFilter = CIFilter(name: "CILanczosScaleTransform") {
            lanczosFilter.setValue(ciImage, forKey: kCIInputImageKey)
            lanczosFilter.setValue(scale, forKey: kCIInputScaleKey)
            lanczosFilter.setValue(1.0, forKey: kCIInputAspectRatioKey)
            if let output = lanczosFilter.outputImage {
                ciImage = output
            }
        } else {
            ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        print("[AI Debug] 本地图像预处理完成：最长边 \(Int(longestEdge)) -> \(Int(maxDimension))")
        return ciImage
    }

    private func localImageMaxDimension(for model: LocalRecognitionModel) -> CGFloat {
        switch model {
        case .qwen35_08b:
            return 1152
        case .qwen35_2b:
            return 960
        }
    }

    nonisolated private static func localCacheLimit(for model: LocalRecognitionModel) -> Int {
        switch model {
        case .qwen35_08b:
            return 96 * 1024 * 1024
        case .qwen35_2b:
            return 64 * 1024 * 1024
        }
    }

    nonisolated private static func localMaxGeneratedTokens(for model: LocalRecognitionModel) -> Int {
        switch model {
        case .qwen35_08b:
            return 512
        case .qwen35_2b:
            return 384
        }
    }

    nonisolated private static func localPrefillStepSize(for model: LocalRecognitionModel) -> Int {
        switch model {
        case .qwen35_08b:
            return 384
        case .qwen35_2b:
            return 256
        }
    }

    nonisolated private static func debugMemoryDescription(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(bytes))
    }

    nonisolated private static func debugSnapshotLine(_ snapshot: Memory.Snapshot) -> String {
        snapshot.description.replacingOccurrences(of: "\n", with: " | ")
    }
}

// MARK: - 识别模式

enum RecognitionMode {
    case table      // 表格识别
    case blueprint  // 图纸识别
}

// MARK: - 识别结果

struct AIRecognizedItem: Codable {
    let colorCode: String
    let quantity: Int

    enum CodingKeys: String, CodingKey {
        case colorCode = "color_code"
        case quantity
    }
}

struct AIRecognitionResult: Codable {
    let items: [AIRecognizedItem]
}

// MARK: - AI 服务管理器

@MainActor
class AIServiceManager: ObservableObject {
    // 单例模式，确保所有视图共享同一配置
    static let shared = AIServiceManager()

    @Published var config: AIConfig {
        didSet {
            let normalized = Self.normalizedConfig(from: config)
            if normalized != config {
                config = normalized
            } else {
                saveConfig()
            }
        }
    }
    @Published var isProcessing = false
    @Published var errorMessage: String?

    private let configKey = "AIServiceConfig"
    private var cancellables = Set<AnyCancellable>()

    init() {
        if let data = UserDefaults.standard.data(forKey: configKey),
           let saved = try? JSONDecoder().decode(AIConfig.self, from: data) {
            self.config = Self.normalizedConfig(from: saved)
        } else {
            self.config = AIConfig()
        }

        LocalModelManager.shared.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    private func saveConfig() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: configKey)
        }
    }

    /// 切换 provider 并重置模型为对应的默认值
    func switchProvider(to provider: AIProvider) {
        config.provider = provider
        config.model = AIConfig.defaultModel(for: provider)
    }

    var isConfigured: Bool {
        switch config.backend {
        case .cloud:
            return !config.apiKey.isEmpty
        case .local:
            return LocalModelManager.shared.isDownloaded(config.localModel)
        }
    }

    var statusMessage: String {
        switch config.backend {
        case .cloud:
            return isConfigured ? String(localized: "云端识别已配置") : String(localized: "请填写 API Key")
        case .local:
            if LocalModelManager.shared.isDownloading.contains(config.localModel) {
                return String(localized: "正在下载 \(config.localModel.displayName)")
            }
            if LocalModelManager.shared.isDownloaded(config.localModel) {
                return String(localized: "\(config.localModel.displayName) 已下载，可直接识别")
            }
            return String(localized: "请先下载本地模型")
        }
    }

    var setupActionTitle: String {
        config.backend == .local ? String(localized: "去下载") : String(localized: "去设置")
    }

    var setupBannerText: String {
        switch config.backend {
        case .cloud:
            return String(localized: "云端识别通常更准确也更快，但需要配置 API Key。")
        case .local:
            return String(localized: "本地识别可免去 API 配置，但准确度会略差于云端，速度更慢，也可能造成手机发热。")
        }
    }

    private static func normalizedConfig(from config: AIConfig) -> AIConfig {
        var normalized = config

        let validModels: [String]
        switch normalized.provider {
        case .kimi:
            validModels = AIConfig.kimiModels
        case .openai:
            validModels = AIConfig.openAIModels
        case .anthropic:
            validModels = AIConfig.anthropicModels
        case .qwen:
            validModels = AIConfig.qwenModels
        case .gemini:
            validModels = AIConfig.geminiModels
        }

        if !validModels.contains(normalized.model) {
            normalized.model = AIConfig.defaultModel(for: normalized.provider)
        }

        return normalized
    }

    // MARK: - 图像预处理（减少水印影响）

    private let ciContext = CIContext()

    /// 预处理图片以减少水印干扰
    private func preprocessImage(_ image: UIImage) -> UIImage {
        guard let ciImage = CIImage(image: image) else {
            print("[AI Debug] 无法创建CIImage，使用原图")
            return image
        }

        var processedImage = ciImage

        // 1. 增强对比度 - 使文字更清晰，水印更淡
        if let contrastFilter = CIFilter(name: "CIColorControls") {
            contrastFilter.setValue(processedImage, forKey: kCIInputImageKey)
            contrastFilter.setValue(1.15, forKey: kCIInputContrastKey)  // 轻微增强对比度
            contrastFilter.setValue(0.05, forKey: kCIInputBrightnessKey)  // 略微提亮
            contrastFilter.setValue(1.0, forKey: kCIInputSaturationKey)  // 保持饱和度
            if let output = contrastFilter.outputImage {
                processedImage = output
            }
        }

        // 2. 锐化 - 使文字边缘更清晰
        if let sharpenFilter = CIFilter(name: "CISharpenLuminance") {
            sharpenFilter.setValue(processedImage, forKey: kCIInputImageKey)
            sharpenFilter.setValue(0.5, forKey: kCIInputSharpnessKey)
            if let output = sharpenFilter.outputImage {
                processedImage = output
            }
        }

        // 3. 高光恢复 - 使浅色水印更不明显
        if let highlightFilter = CIFilter(name: "CIHighlightShadowAdjust") {
            highlightFilter.setValue(processedImage, forKey: kCIInputImageKey)
            highlightFilter.setValue(0.3, forKey: "inputHighlightAmount")  // 压制高光（水印通常是浅色）
            highlightFilter.setValue(0.0, forKey: "inputShadowAmount")
            if let output = highlightFilter.outputImage {
                processedImage = output
            }
        }

        // 4. 局部对比度增强（使文字更突出）
        if let unsharpMask = CIFilter(name: "CIUnsharpMask") {
            unsharpMask.setValue(processedImage, forKey: kCIInputImageKey)
            unsharpMask.setValue(2.5, forKey: kCIInputRadiusKey)
            unsharpMask.setValue(0.5, forKey: kCIInputIntensityKey)
            if let output = unsharpMask.outputImage {
                processedImage = output
            }
        }

        // 转换回UIImage
        guard let cgImage = ciContext.createCGImage(processedImage, from: processedImage.extent) else {
            print("[AI Debug] 无法创建CGImage，使用原图")
            return image
        }

        print("[AI Debug] 图片预处理完成：对比度增强、锐化、高光压制")
        return UIImage(cgImage: cgImage)
    }

    /// 等比例缩放图片，使其编码后数据不超过指定大小
    private func compressImageIfNeeded(_ image: UIImage, maxBytes: Int = 10 * 1024 * 1024) throws -> UIImage {
        // 先检查 JPEG 大小，不超限就直接返回
        if let jpegData = image.jpegData(compressionQuality: 0.95), jpegData.count <= maxBytes {
            return image
        }

        // 超限了，逐步缩小直到 JPEG 不超限
        var current = image
        for i in 0..<5 {
            let scale: CGFloat = 0.8
            let newSize = CGSize(width: current.size.width * scale, height: current.size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: newSize)
            let resized = renderer.image { _ in
                current.draw(in: CGRect(origin: .zero, size: newSize))
            }

            if let data = resized.jpegData(compressionQuality: 0.95), data.count <= maxBytes {
                print("[AI Debug] 图片超限，第\(i+1)次缩放至 \(Int(newSize.width))×\(Int(newSize.height))，JPEG 大小: \(data.count / 1024)KB")
                return resized
            }

            current = resized
        }

        // 兜底：强制缩放到长边 2048px
        let maxDim: CGFloat = 2048
        let ratio = min(maxDim / current.size.width, maxDim / current.size.height, 1.0)
        let finalSize = CGSize(width: current.size.width * ratio, height: current.size.height * ratio)
        let renderer = UIGraphicsImageRenderer(size: finalSize)
        let result = renderer.image { _ in
            current.draw(in: CGRect(origin: .zero, size: finalSize))
        }
        print("[AI Debug] 图片兜底缩放至 \(Int(finalSize.width))×\(Int(finalSize.height))")

        // 最终校验：如果仍然超限，说明图片无法在合理尺寸内压缩
        if let finalData = result.jpegData(compressionQuality: 0.95), finalData.count > maxBytes {
            print("[AI Debug] WARNING: 兜底缩放后仍超限 \(finalData.count / 1024)KB，放弃压缩")
            throw AIError.imageProcessingFailed
        }
        return result
    }

    /// 校验 HTTP 响应状态码，非 200 时抛出对应错误
    private func validateHTTPResponse(_ response: HTTPURLResponse, data: Data) throws {
        guard response.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("[AI Debug] API错误: \(errorText)")
            if response.statusCode == 429 {
                throw AIError.serverOverloaded(errorText)
            }
            throw AIError.apiError("HTTP \(response.statusCode): \(errorText)")
        }
    }

    // MARK: - 图像识别

    func recognizeImage(_ image: UIImage, mode: RecognitionMode = .table, colorSystem: ColorSystem = .mard) async throws -> [AIRecognizedItem] {
        switch config.backend {
        case .cloud:
            guard !config.apiKey.isEmpty else {
                throw AIError.notConfigured
            }
        case .local:
            guard LocalModelManager.shared.isDownloaded(config.localModel) else {
                throw AIError.localModelNotDownloaded(config.localModel.displayName)
            }
        }

        // 预处理图片（减少水印影响）
        let processedImage = preprocessImage(image)

        // 打印 AI 配置信息
        print("[AI Debug] ========== AI 识别开始 ==========")
        print("[AI Debug] 识别方式: \(config.backend.rawValue)")
        if config.backend == .cloud {
            print("[AI Debug] AI 提供商: \(config.provider.rawValue)")
            print("[AI Debug] 模型: \(config.effectiveModel)")
            print("[AI Debug] API 地址: \(config.effectiveBaseURL)")
        } else {
            print("[AI Debug] 本地模型: \(config.localModel.displayName)")
        }
        print("[AI Debug] 原图尺寸: \(image.size), 处理后: \(processedImage.size)")
        print("[AI Debug] 识别模式: \(mode == .table ? "表格识别" : "图纸识别")")
        print("[AI Debug] 色号体系: \(colorSystem.rawValue)")

        if config.backend == .local {
            return try await recognizeWithLocalModel(image: processedImage, mode: mode, colorSystem: colorSystem)
        }

        // 如果图片数据超过 10MB，先等比例缩放
        let finalImage = try compressImageIfNeeded(processedImage)

        // 优先使用PNG格式（无损），如果太大则使用高质量JPEG
        // PNG对于表格文字识别效果更好，不会有JPEG压缩伪影
        let imageData: Data
        let mediaType: String

        if let pngData = finalImage.pngData() {
            if pngData.count < 10 * 1024 * 1024 {
                imageData = pngData
                mediaType = "image/png"
                print("[AI Debug] 使用PNG格式，大小: \(pngData.count / 1024)KB")
            } else {
                guard let jpegData = finalImage.jpegData(compressionQuality: 0.95) else {
                    throw AIError.imageProcessingFailed
                }
                imageData = jpegData
                mediaType = "image/jpeg"
                print("[AI Debug] PNG太大，使用JPEG格式，大小: \(jpegData.count / 1024)KB")
            }
        } else if let jpegData = finalImage.jpegData(compressionQuality: 0.95) {
            imageData = jpegData
            mediaType = "image/jpeg"
            print("[AI Debug] 使用JPEG格式，大小: \(jpegData.count / 1024)KB")
        } else {
            throw AIError.imageProcessingFailed
        }

        let base64Image = imageData.base64EncodedString()
        print("[AI Debug] Base64长度: \(base64Image.count)")

        switch config.provider {
        case .kimi, .openai, .qwen:
            // Kimi、OpenAI、Qwen 使用相同的 API 格式（OpenAI 兼容）
            return try await recognizeWithOpenAI(base64Image: base64Image, mediaType: mediaType, mode: mode, colorSystem: colorSystem)
        case .anthropic:
            return try await recognizeWithAnthropic(base64Image: base64Image, mediaType: mediaType, mode: mode, colorSystem: colorSystem)
        case .gemini:
            return try await recognizeWithGemini(base64Image: base64Image, mediaType: mediaType, mode: mode, colorSystem: colorSystem)
        }
    }

    // MARK: - 提示词生成

    /// 根据识别模式和色号体系生成 AI 提示词
    private func buildPrompts(mode: RecognitionMode, colorSystem: ColorSystem) -> (system: String, user: String) {
        switch mode {
        case .table:
            switch colorSystem {
            case .kaka:
                let system = """
                你是一个拼豆色号表格识别助手。请仔细分析图片中的表格。

                表格结构说明：
                - 这是一个多行多列的表格，每一列代表一种颜色
                - 表格中有多行，分别对应不同品牌的色号和数量
                - 其中某一行是卡卡品牌的色号，卡卡色号有三种前缀：
                  - B系列：B1, B2, B3, B108, B257 等
                  - P系列：P1, P2, P3, P30 等
                  - R系列：R1, R2, R3, R20 等
                  - 格式统一为：单个字母(B/P/R) + 数字
                - 其中某一行是该颜色需要的豆子数量（纯数字）
                - 其他行可能是其他品牌的色号（MARD, vivid, 漫漫），请忽略这些行
                - 重要：卡卡行和数量行的位置不固定，请先观察表格结构，判断哪一行是卡卡色号、哪一行是数量

                特殊情况 - 双区块表格：
                - 当颜色数量较多时，图片中可能出现上下两个独立的表格区块
                - 每个区块都有自己的品牌行和数量行
                - 请分别识别两个区块中的所有卡卡色号和数量，合并输出

                你的任务：
                1. 先观察表格结构，确定卡卡行和数量行的位置
                2. 识别每一列的卡卡色号和对应数量
                3. 如果有多个表格区块，分别识别后合并结果
                4. 只返回JSON格式结果，不要其他文字
                5. 如果检测到"任意色"，color_code应当叫做"any"

                输出格式（严格JSON）：
                {"items":[{"color_code":"B3","quantity":100},{"color_code":"P12","quantity":50},{"color_code":"R5","quantity":30}]}

                注意：
                - 只返回卡卡色号（B/P/R+数字格式），忽略其他品牌行
                - color_code是字符串，quantity是整数
                - 顶层必须是单个JSON对象，格式必须是 {"items":[...]}
                - 不要返回裸数组 [...]，不要返回单个条目对象
                - 不要使用```json代码块，不要输出任何额外说明文字
                - quantity必须是纯整数，不能加括号，不能是字符串
                - 如果某列无法识别，跳过该列
                - 只输出JSON，不要解释
                - 图片可能有水印干扰，请仔细辨认文字
                """
                let user = "请识别这张色号表格图片，提取所有卡卡色号和对应的数量。卡卡色号有B、P、R三种前缀（如B3, B257, P12, R5），格式为单个字母+数字。先判断表格结构，找到卡卡行和数量行。如有多个表格区块请全部识别。返回内容必须且只能是严格JSON，顶层必须是 {\"items\":[...]}，不要返回裸数组，不要使用代码块，quantity必须是整数。"
                return (system, user)

            default:
                // MARD 及其他品牌使用默认的 MARD 提示词
                let system = """
                你是一个拼豆色号表格识别助手。请仔细分析图片中的表格。

                表格结构说明：
                - 这是一个多行多列的表格，每一列代表一种颜色
                - 表格中有多行，分别对应不同品牌的色号和数量
                - 其中某一行是MARD品牌的色号（格式如：F8, A17, B195, DH01, IC09等，通常是字母+数字）
                - 其中某一行是该颜色需要的豆子数量（纯数字）
                - 其他行可能是其他品牌的色号（vivid, 漫漫, 卡卡），请忽略这些行
                - 重要：MARD行和数量行的位置不固定，请先观察表格结构，判断哪一行是MARD色号、哪一行是数量

                特殊情况 - 双区块表格：
                - 当颜色数量较多时，图片中可能出现上下两个独立的表格区块
                - 每个区块都有自己的品牌行和数量行
                - 请分别识别两个区块中的所有MARD色号和数量，合并输出

                你的任务：
                1. 先观察表格结构，确定MARD行和数量行的位置
                2. 识别每一列的MARD色号和对应数量
                3. 如果有多个表格区块，分别识别后合并结果
                4. 只返回JSON格式结果，不要其他文字
                5. 如果检测到"任意色"，color_code应当叫做"any"

                输出格式（严格JSON）：
                {"items":[{"color_code":"F8","quantity":100},{"color_code":"A17","quantity":50}]}

                注意：
                - 只返回MARD色号，忽略其他品牌行
                - color_code是字符串，quantity是整数
                - 顶层必须是单个JSON对象，格式必须是 {"items":[...]}
                - 不要返回裸数组 [...]，不要返回单个条目对象
                - 不要使用```json代码块，不要输出任何额外说明文字
                - quantity必须是纯整数，不能加括号，不能是字符串
                - 如果某列无法识别，跳过该列
                - 只输出JSON，不要解释
                - 图片可能有水印干扰，请仔细辨认文字
                """
                let user = "请识别这张色号表格图片，提取所有MARD色号和对应的数量。先判断表格结构，找到MARD行和数量行。如有多个表格区块请全部识别。返回内容必须且只能是严格JSON，顶层必须是 {\"items\":[...]}，不要返回裸数组，不要使用代码块，quantity必须是整数。"
                return (system, user)
            }

        case .blueprint:
            // 色号统计识别：统一为一套 prompt，不区分体系，识别所有格式色号
            let system = """
            你是一个拼豆图纸识别助手。请仔细分析图片中的拼豆图纸。

            图纸结构说明：
            - 这是一张拼豆图纸，上面标注了各种颜色的色号和对应数量
            - 色号格式通常是字母+数字的组合，常见格式包括：
              - MARD色号：F8, A17, B195, DH01, IC09 等
              - 卡卡色号：B3, B257, P12, R5 等（B/P/R+数字）
              - 其他品牌色号也可能出现
            - 每个色号旁边（下方、侧面或附近）会标注该颜色需要的豆子数量（纯数字）
            - 色号和数量可能以各种方式排列：横排、竖排、分散在图纸各处

            你的任务：
            1. 仔细扫描整张图纸
            2. 找出所有的色号及其对应的数量（不限品牌，识别所有字母+数字格式的色号）
            3. 只返回JSON格式结果，不要其他文字
            4. 如果检测到"任意色"，color_code应当叫做"any"

            输出格式（严格JSON）：
            {"items":[{"color_code":"F8","quantity":100},{"color_code":"B3","quantity":50}]}

            注意：
            - color_code是字符串（字母+数字），quantity是整数
            - 顶层必须是单个JSON对象，格式必须是 {"items":[...]}
            - 不要返回裸数组 [...]，不要返回单个条目对象
            - 不要使用```json代码块，不要输出任何额外说明文字
            - quantity必须是纯整数，不能加括号，不能是字符串
            - 如果某个色号无法识别数量，跳过该项
            - 只输出JSON，不要解释
            - 图片可能有水印干扰，请仔细辨认文字
            - 数量通常在色号的下方或旁边
            """
            let user = "请识别这张拼豆图纸，找出所有色号和对应的数量。色号通常是字母+数字（如F8, A17, B3, B257），数量在色号附近。返回内容必须且只能是严格JSON，顶层必须是 {\"items\":[...]}，不要返回裸数组，不要使用代码块，quantity必须是整数。"
            return (system, user)
        }
    }

    private func recognizeWithLocalModel(image: UIImage, mode: RecognitionMode, colorSystem: ColorSystem) async throws -> [AIRecognizedItem] {
        let prompts = buildPrompts(mode: mode, colorSystem: colorSystem)
        let output = try await LocalModelManager.shared.recognize(
            image: image,
            model: config.localModel,
            systemPrompt: prompts.system,
            userPrompt: prompts.user
        )

        print("[AI Debug] 本地模型原始回复:\n\(output)")

        let jsonText = extractJSON(from: output)
        print("[AI Debug] 本地模型提取 JSON:\n\(jsonText)")

        guard let jsonData = jsonText.data(using: .utf8) else {
            throw AIError.parseError(String(localized: "无法转换本地模型返回的 JSON 文本"))
        }

        let result = try JSONDecoder().decode(AIRecognitionResult.self, from: jsonData)
        print("[AI Debug] 本地模型解析成功，识别到 \(result.items.count) 个色号")
        return result.items
    }

    // MARK: - OpenAI 实现

    private func recognizeWithOpenAI(base64Image: String, mediaType: String, mode: RecognitionMode, colorSystem: ColorSystem = .mard) async throws -> [AIRecognizedItem] {
        guard let url = URL(string: "\(config.effectiveBaseURL)/chat/completions") else {
            throw AIError.networkError("Invalid API URL: \(config.effectiveBaseURL)/chat/completions")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.effectiveAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let prompts = buildPrompts(mode: mode, colorSystem: colorSystem)
        let systemPrompt = prompts.system
        let userPrompt = prompts.user

        // OpenAI 使用 max_completion_tokens，Kimi 使用 max_tokens
        var body: [String: Any] = [
            "model": config.effectiveModel,
            "messages": [
                ["role": "system", "content": systemPrompt],
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image_url",
                            "image_url": [
                                "url": "data:\(mediaType);base64,\(base64Image)"
                            ]
                        ],
                        [
                            "type": "text",
                            "text": userPrompt
                        ]
                    ]
                ]
            ]
        ]

        // 根据提供商设置不同的 token 限制参数
        // OpenAI 使用 max_completion_tokens，Kimi/Qwen 使用 max_tokens
        if config.provider == .openai {
            body["max_completion_tokens"] = 8192
        } else {
            body["max_tokens"] = 8192
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 180  // AI 视觉识别可能需要较长时间，设置 3 分钟超时

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.networkError("Invalid response")
        }

        try validateHTTPResponse(httpResponse, data: data)

        // 解析响应
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIError.parseError("Failed to parse OpenAI response")
        }

        // 检查是否被截断
        if let finishReason = firstChoice["finish_reason"] as? String {
            print("[AI Debug] 完成原因: \(finishReason)")
            if finishReason == "length" {
                print("[AI Debug] ⚠️ 警告：输出因长度限制被截断！")
            }
        }

        print("[AI Debug] GPT原始回复:\n\(content)")

        // 提取JSON部分
        let jsonText = extractJSON(from: content)
        print("[AI Debug] 提取的JSON:\n\(jsonText)")

        guard let jsonData = jsonText.data(using: .utf8) else {
            throw AIError.parseError(String(localized: "无法转换JSON文本"))
        }

        let result = try JSONDecoder().decode(AIRecognitionResult.self, from: jsonData)
        print("[AI Debug] 解析成功，识别到 \(result.items.count) 个色号")
        return result.items
    }

    // MARK: - Anthropic 实现

    private func recognizeWithAnthropic(base64Image: String, mediaType: String, mode: RecognitionMode, colorSystem: ColorSystem = .mard) async throws -> [AIRecognizedItem] {
        guard let url = URL(string: "\(config.effectiveBaseURL)/v1/messages") else {
            throw AIError.networkError("Invalid API URL: \(config.effectiveBaseURL)/v1/messages")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let prompts = buildPrompts(mode: mode, colorSystem: colorSystem)
        let systemPrompt = prompts.system
        let userPrompt = prompts.user

        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": 8192,  // 设置足够大的输出限制，避免颜色多时被截断
            "system": systemPrompt,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": mediaType,
                                "data": base64Image
                            ]
                        ],
                        [
                            "type": "text",
                            "text": userPrompt
                        ]
                    ]
                ]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 180  // AI 视觉识别可能需要较长时间，设置 3 分钟超时

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.networkError("Invalid response")
        }

        try validateHTTPResponse(httpResponse, data: data)

        // 解析响应
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw AIError.parseError("Failed to parse Anthropic response")
        }

        // 找到 text 类型的内容
        for block in content {
            if let type = block["type"] as? String, type == "text",
               let text = block["text"] as? String {
                print("[AI Debug] Claude原始回复:\n\(text)")

                // 提取JSON部分（可能包含在```json ... ```中）
                let jsonText = extractJSON(from: text)
                print("[AI Debug] 提取的JSON:\n\(jsonText)")

                guard let jsonData = jsonText.data(using: .utf8) else {
                    throw AIError.parseError(String(localized: "无法转换JSON文本"))
                }

                let result = try JSONDecoder().decode(AIRecognitionResult.self, from: jsonData)
                print("[AI Debug] 解析成功，识别到 \(result.items.count) 个色号")
                return result.items
            }
        }

        throw AIError.parseError("No text content found in response")
    }

    // MARK: - Gemini 实现

    private func recognizeWithGemini(base64Image: String, mediaType: String, mode: RecognitionMode, colorSystem: ColorSystem = .mard) async throws -> [AIRecognizedItem] {
        guard let url = URL(string: "\(config.effectiveBaseURL)/models/\(config.effectiveModel):generateContent?key=\(config.effectiveAPIKey)") else {
            throw AIError.networkError("Invalid API URL for Gemini")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let prompts = buildPrompts(mode: mode, colorSystem: colorSystem)
        // Gemini 使用合并的 system+user 作为单一 prompt
        let prompt = prompts.system + "\n\n" + prompts.user

        // Gemini API 格式
        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        [
                            "inline_data": [
                                "mime_type": mediaType,
                                "data": base64Image
                            ]
                        ],
                        [
                            "text": prompt
                        ]
                    ]
                ]
            ],
            "generationConfig": [
                "maxOutputTokens": 8192
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 180

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.networkError("Invalid response")
        }

        try validateHTTPResponse(httpResponse, data: data)

        // 解析 Gemini 响应
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw AIError.parseError("Failed to parse Gemini response")
        }

        // 找到 text 部分
        for part in parts {
            if let text = part["text"] as? String {
                print("[AI Debug] Gemini原始回复:\n\(text)")

                let jsonText = extractJSON(from: text)
                print("[AI Debug] 提取的JSON:\n\(jsonText)")

                guard let jsonData = jsonText.data(using: .utf8) else {
                    throw AIError.parseError(String(localized: "无法转换JSON文本"))
                }

                let result = try JSONDecoder().decode(AIRecognitionResult.self, from: jsonData)
                print("[AI Debug] 解析成功，识别到 \(result.items.count) 个色号")
                return result.items
            }
        }

        throw AIError.parseError("No text content found in Gemini response")
    }

    // 从文本中提取JSON
    private func extractJSON(from text: String) -> String {
        var jsonText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 移除markdown代码块标记
        if jsonText.hasPrefix("```json") {
            jsonText = String(jsonText.dropFirst(7))
        } else if jsonText.hasPrefix("```") {
            jsonText = String(jsonText.dropFirst(3))
        }

        if jsonText.hasSuffix("```") {
            jsonText = String(jsonText.dropLast(3))
        }

        jsonText = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)

        // 如果还是找不到JSON，尝试查找 { 开头的部分
        if !jsonText.hasPrefix("{") {
            if let startIndex = jsonText.firstIndex(of: "{"),
               let endIndex = jsonText.lastIndex(of: "}") {
                jsonText = String(jsonText[startIndex...endIndex])
            }
        }

        // 修复常见的 JSON 格式问题
        jsonText = fixJSONFormat(jsonText)

        return jsonText
    }

    // 修复常见的 JSON 格式问题
    private func fixJSONFormat(_ json: String) -> String {
        var fixed = json

        // 修复多余的括号问题（如 "]}" 变成 "]]}" 或 "}}" 等）
        // 统计括号数量
        let openBraces = fixed.filter { $0 == "{" }.count
        let closeBraces = fixed.filter { $0 == "}" }.count
        let openBrackets = fixed.filter { $0 == "[" }.count
        let closeBrackets = fixed.filter { $0 == "]" }.count

        // 如果 ] 比 [ 多，从末尾移除多余的 ]
        if closeBrackets > openBrackets {
            let excess = closeBrackets - openBrackets
            for _ in 0..<excess {
                if let lastIndex = fixed.lastIndex(of: "]") {
                    // 确保不是在字符串内部
                    let afterIndex = fixed.index(after: lastIndex)
                    if afterIndex == fixed.endIndex || fixed[afterIndex] == "}" || fixed[afterIndex] == "]" || fixed[afterIndex] == "," {
                        fixed.remove(at: lastIndex)
                        print("[AI Debug] 修复：移除多余的 ]")
                    }
                }
            }
        }

        // 如果 } 比 { 多，从末尾移除多余的 }
        if closeBraces > openBraces {
            let excess = closeBraces - openBraces
            for _ in 0..<excess {
                if let lastIndex = fixed.lastIndex(of: "}") {
                    fixed.remove(at: lastIndex)
                    print("[AI Debug] 修复：移除多余的 }")
                }
            }
        }

        // 如果 { 比 } 多，在末尾添加 }
        if openBraces > closeBraces {
            let missing = openBraces - closeBraces
            for _ in 0..<missing {
                fixed.append("}")
                print("[AI Debug] 修复：添加缺失的 }")
            }
        }

        // 如果 [ 比 ] 多，在末尾添加 ]
        if openBrackets > closeBrackets {
            let missing = openBrackets - closeBrackets
            for _ in 0..<missing {
                // 在最后一个 } 之前插入 ]
                if let lastBrace = fixed.lastIndex(of: "}") {
                    fixed.insert("]", at: lastBrace)
                } else {
                    fixed.append("]")
                }
                print("[AI Debug] 修复：添加缺失的 ]")
            }
        }

        return fixed
    }
}

// MARK: - 错误类型

enum AIError: LocalizedError {
    case notConfigured
    case localModelNotDownloaded(String)
    case deviceNotSupported
    case imageProcessingFailed
    case networkError(String)
    case apiError(String)
    case serverOverloaded(String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String(localized: "请先配置云端 API，或下载本地模型")
        case .localModelNotDownloaded(let modelName):
            return String(localized: "请先下载本地模型：\(modelName)")
        case .deviceNotSupported:
            return String(localized: "当前设备不支持本地模型，需要搭载 A14 及以上芯片的设备")
        case .imageProcessingFailed:
            return String(localized: "图片处理失败")
        case .networkError(let msg):
            return String(localized: "网络错误: \(msg)")
        case .apiError(let msg):
            return String(localized: "API 错误: \(msg)")
        case .serverOverloaded:
            return String(localized: "Kimi 服务器当前算力紧张，暂时无法响应，请稍后再试（非本应用问题）")
        case .parseError(let msg):
            return String(localized: "解析错误: \(msg)")
        }
    }
}
