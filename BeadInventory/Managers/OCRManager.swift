//
//  OCRManager.swift
//  BeadInventory
//
//  OCR图片识别管理器 - 使用Vision框架识别色号表格
//

import Foundation
import Vision
import UIKit

@MainActor
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
        var allTexts: [(String, CGRect)] = []

        // 收集所有识别的文本和位置
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            allTexts.append((candidate.string, observation.boundingBox))
        }

        // 使用新的表格解析逻辑
        return parseTableData(from: allTexts)
    }

    private func parseTableData(from texts: [(String, CGRect)]) -> [RecognizedBeadItem] {
        var items: [RecognizedBeadItem] = []

        // 收集所有色号和数量
        var colorCodes: [(text: String, x: CGFloat, y: CGFloat)] = []
        var quantities: [(value: Int, x: CGFloat, y: CGFloat)] = []

        for (text, rect) in texts {
            let components = text.components(separatedBy: CharacterSet.whitespaces)
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }
                .filter { !$0.isEmpty }

            let width = rect.width / max(CGFloat(components.count), 1)

            for (index, component) in components.enumerated() {
                let centerX = components.count == 1 ? rect.midX : rect.minX + width * (CGFloat(index) + 0.5)
                let centerY = rect.midY

                // 跳过关键词
                let upper = component.uppercased()
                if upper.contains("MARD") || upper.contains("VIVID") ||
                   component.contains("漫漫") || component.contains("卡卡") ||
                   component.contains("豆量") || component.contains("数量") ||
                   component.contains("色号") || component.contains("合计") {
                    continue
                }

                // 判断是色号还是数量
                // MARD色号格式：字母+数字（如F8, A17, B195）或纯小数字（1-9）
                if isMardStyleCode(component) {
                    // 明确的MARD格式（字母+数字）
                    colorCodes.append((component.uppercased(), centerX, centerY))
                } else if let num = Int(component), num > 0 && num < 10000 {
                    // 纯数字：根据大小判断
                    if num >= 10 {
                        // 10以上更可能是数量
                        quantities.append((num, centerX, centerY))
                    } else {
                        // 1-9可能是色号也可能是数量，暂时都保存
                        colorCodes.append((component, centerX, centerY))
                        quantities.append((num, centerX, centerY))
                    }
                }
            }
        }

        print("[OCR Debug] 找到 \(colorCodes.count) 个色号, \(quantities.count) 个数量")

        guard !colorCodes.isEmpty && !quantities.isEmpty else { return items }

        // 策略：按X坐标配对（最近邻匹配）
        // 数量应该在色号的下方（Y坐标更小），且X坐标接近
        var usedColorIndices = Set<Int>()

        for qty in quantities {
            var bestMatchIndex: Int?
            var bestScore: CGFloat = .greatestFiniteMagnitude

            for (index, code) in colorCodes.enumerated() {
                if usedColorIndices.contains(index) { continue }

                // 色号应该在数量上方（Y更大）
                guard code.y > qty.y else { continue }

                // 计算匹配分数：X距离越小越好
                let xDistance = abs(code.x - qty.x)
                if xDistance < bestScore {
                    bestScore = xDistance
                    bestMatchIndex = index
                }
            }

            // 放宽匹配阈值到15%
            if let matchIndex = bestMatchIndex, bestScore < 0.15 {
                usedColorIndices.insert(matchIndex)
                items.append(RecognizedBeadItem(
                    colorCode: colorCodes[matchIndex].text,
                    quantity: qty.value,
                    brand: "MARD"
                ))
            }
        }

        print("[OCR Debug] 成功配对 \(items.count) 个结果")
        return items
    }

    // 判断是否是MARD风格的色号（字母+数字）
    private func isMardStyleCode(_ text: String) -> Bool {
        let patterns = [
            "^[A-Za-z]\\d{1,3}$",           // F8, A17, B195
            "^[A-Za-z]{2}\\d{1,3}$",        // DH01, IC09
            "^\\*?[A-Za-z]\\d{1,3}$",       // *B195
            "^[A-Za-z]\\d{1,3}[A-Za-z]?$"   // A17B 等变体
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
