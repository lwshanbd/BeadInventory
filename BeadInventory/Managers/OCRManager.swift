//
//  OCRManager.swift
//  BeadInventory
//
//  OCR图片识别管理器 - 使用Vision框架识别色号表格
//

import Foundation
import Vision
import UIKit

class OCRManager: ObservableObject {
    @Published var isProcessing = false
    @Published var recognizedItems: [RecognizedBeadItem] = []
    @Published var errorMessage: String?

    struct RecognizedBeadItem: Identifiable {
        let id = UUID()
        var colorCode: String
        var quantity: Int
        var brand: String
        var isConfirmed: Bool = false
    }

    // MARK: - 图片预处理（去除水印干扰）

    func preprocessImage(_ image: UIImage) -> UIImage? {
        guard let ciImage = CIImage(image: image) else { return nil }

        let context = CIContext()

        // 1. 增强对比度
        let contrastFilter = CIFilter(name: "CIColorControls")!
        contrastFilter.setValue(ciImage, forKey: kCIInputImageKey)
        contrastFilter.setValue(1.2, forKey: kCIInputContrastKey)
        contrastFilter.setValue(0.0, forKey: kCIInputSaturationKey) // 转灰度有助于OCR
        contrastFilter.setValue(0.1, forKey: kCIInputBrightnessKey)

        guard let contrastOutput = contrastFilter.outputImage else { return nil }

        // 2. 锐化
        let sharpenFilter = CIFilter(name: "CISharpenLuminance")!
        sharpenFilter.setValue(contrastOutput, forKey: kCIInputImageKey)
        sharpenFilter.setValue(0.5, forKey: kCIInputSharpnessKey)

        guard let sharpenOutput = sharpenFilter.outputImage else { return nil }

        // 3. 降噪
        let noiseFilter = CIFilter(name: "CINoiseReduction")!
        noiseFilter.setValue(sharpenOutput, forKey: kCIInputImageKey)
        noiseFilter.setValue(0.02, forKey: "inputNoiseLevel")
        noiseFilter.setValue(0.4, forKey: "inputSharpness")

        guard let finalOutput = noiseFilter.outputImage,
              let cgImage = context.createCGImage(finalOutput, from: finalOutput.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    // MARK: - OCR识别

    func recognizeText(from image: UIImage, completion: @escaping ([RecognizedBeadItem]) -> Void) {
        isProcessing = true
        errorMessage = nil
        recognizedItems = []

        // 预处理图片
        let processedImage = preprocessImage(image) ?? image

        guard let cgImage = processedImage.cgImage else {
            errorMessage = "无法处理图片"
            isProcessing = false
            completion([])
            return
        }

        let request = VNRecognizeTextRequest { [weak self] request, error in
            DispatchQueue.main.async {
                self?.isProcessing = false

                if let error = error {
                    self?.errorMessage = "识别失败: \(error.localizedDescription)"
                    completion([])
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    self?.errorMessage = "无法获取识别结果"
                    completion([])
                    return
                }

                let items = self?.parseRecognizedText(observations) ?? []
                self?.recognizedItems = items
                completion(items)
            }
        }

        // 配置识别参数
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "处理失败: \(error.localizedDescription)"
                    self.isProcessing = false
                    completion([])
                }
            }
        }
    }

    // MARK: - 解析识别结果

    private func parseRecognizedText(_ observations: [VNRecognizedTextObservation]) -> [RecognizedBeadItem] {
        var items: [RecognizedBeadItem] = []
        var allTexts: [(String, CGRect)] = []

        // 收集所有识别的文本和位置
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            allTexts.append((candidate.string, observation.boundingBox))
        }

        // 按Y坐标（行）分组
        let sortedByY = allTexts.sorted { $0.1.minY > $1.1.minY }

        // 解析表格结构
        // 查找包含品牌关键词的行
        var currentBrand = "MARD"
        var colorCodePattern = try? NSRegularExpression(pattern: "^[A-Z]\\d+$|^\\d+$", options: .caseInsensitive)
        var quantityPattern = try? NSRegularExpression(pattern: "^\\d{1,4}$", options: [])

        for (text, _) in sortedByY {
            let trimmedText = text.trimmingCharacters(in: .whitespaces)

            // 检测品牌行
            if trimmedText.contains("MARD") {
                currentBrand = "MARD"
            } else if trimmedText.lowercased().contains("vivid") {
                currentBrand = "vivid"
            } else if trimmedText.contains("漫漫") {
                currentBrand = "漫漫"
            } else if trimmedText.contains("卡卡") {
                currentBrand = "卡卡"
            } else if trimmedText.contains("豆量") || trimmedText.contains("数量") {
                // 这是豆量行，尝试提取数字
                let numbers = extractNumbers(from: trimmedText)
                // 将数字与之前识别的色号配对
                continue
            }

            // 尝试解析整行数据（可能包含多个色号或数量）
            let components = trimmedText.components(separatedBy: CharacterSet.whitespaces)

            for component in components {
                let clean = component.trimmingCharacters(in: .punctuationCharacters)

                // 检查是否是色号格式 (如 F8, A17, B195, 81, 213)
                if isColorCode(clean) {
                    // 暂存色号，等待配对数量
                    continue
                }

                // 检查是否是数量 (纯数字，通常1-4位)
                if let quantity = Int(clean), quantity > 0 && quantity < 10000 {
                    // 这可能是豆量
                    continue
                }
            }
        }

        // 简化解析：提取所有可能的色号-数量对
        items = parseTableData(from: allTexts)

        return items
    }

    private func isColorCode(_ text: String) -> Bool {
        // 色号格式: 字母+数字 (如F8, A17) 或 纯数字 (如81, 213)
        let patterns = [
            "^[A-Za-z]\\d{1,3}$",           // F8, A17, B195
            "^[A-Za-z]{2}\\d{1,3}$",        // DH01, IC09
            "^\\*?[A-Za-z]\\d{1,3}$",       // *B195
            "^\\d{1,3}$"                     // 81, 213 (vivid)
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(text.startIndex..., in: text)
                if regex.firstMatch(in: text, options: [], range: range) != nil {
                    return true
                }
            }
        }
        return false
    }

    private func extractNumbers(from text: String) -> [Int] {
        let pattern = "\\d+"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }

        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)

        return matches.compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return Int(text[range])
        }
    }

    private func parseTableData(from texts: [(String, CGRect)]) -> [RecognizedBeadItem] {
        var items: [RecognizedBeadItem] = []

        // 按位置分组，尝试匹配同一列的色号和数量
        let sortedTexts = texts.sorted { $0.1.minX < $1.1.minX }

        var colorCodes: [String] = []
        var quantities: [Int] = []
        var currentBrand = "MARD"

        for (text, _) in sortedTexts {
            let components = text.components(separatedBy: CharacterSet.whitespaces)

            for component in components {
                let clean = component.trimmingCharacters(in: .punctuationCharacters)

                if isColorCode(clean) && clean.count <= 5 {
                    colorCodes.append(clean.uppercased())
                } else if let num = Int(clean), num > 0 && num < 5000 {
                    quantities.append(num)
                }

                // 检测品牌
                if clean.uppercased().contains("MARD") {
                    currentBrand = "MARD"
                } else if clean.lowercased().contains("vivid") {
                    currentBrand = "vivid"
                }
            }
        }

        // 配对色号和数量
        // 假设豆量行在最后，与色号一一对应
        let pairCount = min(colorCodes.count, quantities.count)
        for i in 0..<pairCount {
            items.append(RecognizedBeadItem(
                colorCode: colorCodes[i],
                quantity: quantities[i],
                brand: currentBrand
            ))
        }

        return items
    }

    // MARK: - 手动添加/编辑识别结果

    func addItem(colorCode: String, quantity: Int, brand: String) {
        let item = RecognizedBeadItem(
            colorCode: colorCode.uppercased(),
            quantity: quantity,
            brand: brand,
            isConfirmed: true
        )
        recognizedItems.append(item)
    }

    func updateItem(id: UUID, colorCode: String?, quantity: Int?) {
        if let index = recognizedItems.firstIndex(where: { $0.id == id }) {
            if let code = colorCode {
                recognizedItems[index].colorCode = code.uppercased()
            }
            if let qty = quantity {
                recognizedItems[index].quantity = qty
            }
            recognizedItems[index].isConfirmed = true
        }
    }

    func removeItem(id: UUID) {
        recognizedItems.removeAll { $0.id == id }
    }

    func clearResults() {
        recognizedItems = []
        errorMessage = nil
    }
}
