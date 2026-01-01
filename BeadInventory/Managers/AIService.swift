//
//  AIService.swift
//  BeadInventory
//
//  AI图像识别服务 - 支持 OpenAI 和 Anthropic
//

import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - AI 配置

enum AIProvider: String, CaseIterable, Codable {
    case builtIn = "默认"
    case openai = "OpenAI"
    case anthropic = "Anthropic"
}

struct AIConfig: Codable {
    var provider: AIProvider
    var apiKey: String
    var baseURL: String  // 自定义API地址，空则使用默认
    var model: String

    static let defaultOpenAIURL = "https://api.openai.com/v1"
    static let defaultAnthropicURL = "https://api.anthropic.com"

    // 内置 Kimi API 配置（用户不可见）
    static let builtInBaseURL = "https://api.moonshot.cn/v1"
    static let builtInModel = "kimi-latest"
    static let builtInAPIKey = "sk-BjdA5dEnGUHxjLQvDb3pi93xaYyGdMpMwZdWxXutMnJiimsH"

    static let openAIModels = ["gpt-5-mini-2025-08-07", "gpt-4o", "gpt-4o-mini", "gpt-4-turbo"]
    static let anthropicModels = ["claude-sonnet-4-5-20250929", "claude-sonnet-4-20250514", "claude-3-5-sonnet-20241022", "claude-3-haiku-20240307"]

    static func defaultModel(for provider: AIProvider) -> String {
        switch provider {
        case .builtIn:
            return builtInModel
        case .openai:
            return "gpt-5-mini-2025-08-07"
        case .anthropic:
            return "claude-sonnet-4-5-20250929"
        }
    }

    init(provider: AIProvider = .builtIn, apiKey: String = "", baseURL: String = "", model: String = "") {
        self.provider = provider
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model.isEmpty ? AIConfig.defaultModel(for: provider) : model
    }

    var effectiveBaseURL: String {
        switch provider {
        case .builtIn:
            return AIConfig.builtInBaseURL
        case .openai:
            return baseURL.isEmpty ? AIConfig.defaultOpenAIURL : baseURL
        case .anthropic:
            return baseURL.isEmpty ? AIConfig.defaultAnthropicURL : baseURL
        }
    }

    var effectiveAPIKey: String {
        if provider == .builtIn {
            return AIConfig.builtInAPIKey
        }
        return apiKey
    }

    var effectiveModel: String {
        if provider == .builtIn {
            return AIConfig.builtInModel
        }
        return model
    }
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

class AIServiceManager: ObservableObject {
    // 单例模式，确保所有视图共享同一配置
    static let shared = AIServiceManager()

    @Published var config: AIConfig {
        didSet {
            saveConfig()
            // 内置模式不需要验证模型
            guard config.provider != .builtIn else { return }
            // 当 provider 改变时，如果当前模型不在新 provider 的模型列表中，则重置为默认模型
            let validModels = config.provider == .openai ? AIConfig.openAIModels : AIConfig.anthropicModels
            if !validModels.contains(config.model) {
                config.model = AIConfig.defaultModel(for: config.provider)
            }
        }
    }
    @Published var isProcessing = false
    @Published var errorMessage: String?

    private let configKey = "AIServiceConfig"

    init() {
        if let data = UserDefaults.standard.data(forKey: configKey),
           let saved = try? JSONDecoder().decode(AIConfig.self, from: data) {
            self.config = saved
        } else {
            self.config = AIConfig()
        }
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
        // 内置模式始终已配置
        if config.provider == .builtIn {
            return true
        }
        return !config.apiKey.isEmpty
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

    // MARK: - 图像识别

    func recognizeImage(_ image: UIImage) async throws -> [AIRecognizedItem] {
        guard isConfigured else {
            throw AIError.notConfigured
        }

        // 预处理图片（减少水印影响）
        let processedImage = preprocessImage(image)
        print("[AI Debug] 原图尺寸: \(image.size), 处理后: \(processedImage.size)")

        // 优先使用PNG格式（无损），如果太大则使用高质量JPEG
        // PNG对于表格文字识别效果更好，不会有JPEG压缩伪影
        let imageData: Data
        let mediaType: String

        if let pngData = processedImage.pngData() {
            // PNG文件如果小于10MB，直接使用PNG
            if pngData.count < 10 * 1024 * 1024 {
                imageData = pngData
                mediaType = "image/png"
                print("[AI Debug] 使用PNG格式，大小: \(pngData.count / 1024)KB")
            } else {
                // 太大则使用高质量JPEG
                guard let jpegData = processedImage.jpegData(compressionQuality: 0.95) else {
                    throw AIError.imageProcessingFailed
                }
                imageData = jpegData
                mediaType = "image/jpeg"
                print("[AI Debug] PNG太大，使用JPEG格式，大小: \(jpegData.count / 1024)KB")
            }
        } else if let jpegData = processedImage.jpegData(compressionQuality: 0.95) {
            imageData = jpegData
            mediaType = "image/jpeg"
            print("[AI Debug] 使用JPEG格式，大小: \(jpegData.count / 1024)KB")
        } else {
            throw AIError.imageProcessingFailed
        }

        let base64Image = imageData.base64EncodedString()
        print("[AI Debug] Base64长度: \(base64Image.count)")

        switch config.provider {
        case .builtIn, .openai:
            // 内置 Kimi 和 OpenAI 使用相同的 API 格式
            return try await recognizeWithOpenAI(base64Image: base64Image, mediaType: mediaType)
        case .anthropic:
            return try await recognizeWithAnthropic(base64Image: base64Image, mediaType: mediaType)
        }
    }

    // MARK: - OpenAI 实现

    private func recognizeWithOpenAI(base64Image: String, mediaType: String) async throws -> [AIRecognizedItem] {
        let url = URL(string: "\(config.effectiveBaseURL)/chat/completions")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.effectiveAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let systemPrompt = """
        你是一个珠子色号表格识别助手。请仔细分析图片中的表格。

        表格结构说明：
        - 这是一个多行多列的表格，每一列代表一种颜色
        - 第一行或者其中某一行是MARD品牌的色号（格式如：F8, A17, B195, DH01, IC09等，通常是字母+数字）
        - 最后一行是该颜色需要的豆子数量（纯数字）
        - 中间可能有其他品牌的色号（vivid, 漫漫, 卡卡），请忽略这些行

        你的任务：
        1. 仔细观察图片中的表格
        2. 识别每一列的MARD色号（第一行）和对应数量（最后一行）
        3. 只返回JSON格式结果，不要其他文字
        4. 如果检测到"任意色"，color_code应当叫做"any"

        输出格式（严格JSON）：
        {"items":[{"color_code":"F8","quantity":100},{"color_code":"A17","quantity":50}]}

        注意：
        - 只返回MARD色号，忽略其他品牌行
        - color_code是字符串，quantity是整数
        - 如果某列无法识别，跳过该列
        - 只输出JSON，不要解释
        - 图片可能有水印干扰，请仔细辨认文字
        """

        let body: [String: Any] = [
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
                            "text": "请识别这张色号表格图片，提取所有MARD色号和对应的数量。注意图片可能有水印，请仔细辨认。只返回JSON。"
                        ]
                    ]
                ]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.networkError("Invalid response")
        }

        if httpResponse.statusCode != 200 {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("[AI Debug] API错误: \(errorText)")
            throw AIError.apiError("HTTP \(httpResponse.statusCode): \(errorText)")
        }

        // 解析响应
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIError.parseError("Failed to parse OpenAI response")
        }

        print("[AI Debug] GPT原始回复:\n\(content)")

        // 提取JSON部分
        let jsonText = extractJSON(from: content)
        print("[AI Debug] 提取的JSON:\n\(jsonText)")

        guard let jsonData = jsonText.data(using: .utf8) else {
            throw AIError.parseError("无法转换JSON文本")
        }

        let result = try JSONDecoder().decode(AIRecognitionResult.self, from: jsonData)
        print("[AI Debug] 解析成功，识别到 \(result.items.count) 个色号")
        return result.items
    }

    // MARK: - Anthropic 实现

    private func recognizeWithAnthropic(base64Image: String, mediaType: String) async throws -> [AIRecognizedItem] {
        let url = URL(string: "\(config.effectiveBaseURL)/v1/messages")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let systemPrompt = """
        你是一个珠子色号表格识别助手。请仔细分析图片中的表格。

        表格结构说明：
        - 这是一个多行多列的表格，每一列代表一种颜色
        - 第一行是MARD品牌的色号（格式如：F8, A17, B195, DH01, IC09等，通常是字母+数字）
        - 最后一行是该颜色需要的豆子数量（纯数字）
        - 中间可能有其他品牌的色号（vivid, 漫漫, 卡卡），请忽略这些行

        你的任务：
        1. 仔细观察图片中的表格
        2. 识别每一列的MARD色号（第一行）和对应数量（最后一行）
        3. 只返回JSON格式结果，不要其他文字
        4. 如果检测到"任意色"，color_code应当叫做"any"

        输出格式（严格JSON）：
        {"items":[{"color_code":"F8","quantity":100},{"color_code":"A17","quantity":50}]}

        注意：
        - 只返回MARD色号，忽略其他品牌行
        - color_code是字符串，quantity是整数
        - 如果某列无法识别，跳过该列
        - 只输出JSON，不要解释
        - 图片可能有水印干扰，请仔细辨认文字
        """

        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": 4096,
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
                            "text": "请识别这张色号表格图片，提取所有MARD色号和对应的数量。注意图片可能有水印，请仔细辨认。只返回JSON。"
                        ]
                    ]
                ]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.networkError("Invalid response")
        }

        if httpResponse.statusCode != 200 {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("[AI Debug] API错误: \(errorText)")
            throw AIError.apiError("HTTP \(httpResponse.statusCode): \(errorText)")
        }

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
                    throw AIError.parseError("无法转换JSON文本")
                }

                let result = try JSONDecoder().decode(AIRecognitionResult.self, from: jsonData)
                print("[AI Debug] 解析成功，识别到 \(result.items.count) 个色号")
                return result.items
            }
        }

        throw AIError.parseError("No text content found in response")
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

        return jsonText
    }
}

// MARK: - 错误类型

enum AIError: LocalizedError {
    case notConfigured
    case imageProcessingFailed
    case networkError(String)
    case apiError(String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "请先在设置中配置 AI API"
        case .imageProcessingFailed:
            return "图片处理失败"
        case .networkError(let msg):
            return "网络错误: \(msg)"
        case .apiError(let msg):
            return "API 错误: \(msg)"
        case .parseError(let msg):
            return "解析错误: \(msg)"
        }
    }
}
