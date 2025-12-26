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
        var allTexts: [(String, CGRect)] = []

        // 收集所有识别的文本和位置
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            allTexts.append((candidate.string, observation.boundingBox))
        }

        // 使用基于列的解析方法
        return parseTableByColumns(from: allTexts)
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

    // MARK: - 基于列的表格解析（核心修复）

    private func parseTableByColumns(from texts: [(String, CGRect)]) -> [RecognizedBeadItem] {
        var items: [RecognizedBeadItem] = []

        // 按Y坐标分组（Y坐标相近的在同一行）
        // 注意：Vision框架的Y坐标是从下往上的（0在底部）
        let yTolerance: CGFloat = 0.03
        var rows: [[((String, CGRect))]] = []
        let sortedByY = texts.sorted { $0.1.midY > $1.1.midY } // 从上到下

        var currentRow: [(String, CGRect)] = []
        var lastY: CGFloat = -1

        for item in sortedByY {
            if lastY < 0 || abs(item.1.midY - lastY) < yTolerance {
                currentRow.append(item)
                lastY = item.1.midY
            } else {
                if !currentRow.isEmpty {
                    rows.append(currentRow)
                }
                currentRow = [item]
                lastY = item.1.midY
            }
        }
        if !currentRow.isEmpty {
            rows.append(currentRow)
        }

        // 2. 识别每行的类型
        var brandRows: [String: [(String, CGRect)]] = [:]
        var quantityRow: [(String, CGRect)] = []

        for row in rows {
            // 合并同一行的所有文本来判断行类型
            let rowText = row.map { $0.0 }.joined(separator: " ")

            if rowText.contains("MARD") || rowText.contains("mard") {
                brandRows["MARD"] = row
            } else if rowText.lowercased().contains("vivid") {
                brandRows["vivid"] = row
            } else if rowText.contains("漫漫") || rowText.contains("渡渡") {
                brandRows["漫漫"] = row
            } else if rowText.contains("卡卡") {
                brandRows["卡卡"] = row
            } else if rowText.contains("豆量") || rowText.contains("数量") || rowText.contains("豆数") {
                quantityRow = row
            }
        }

        // 3. 如果没找到明确的品牌行标记，尝试根据位置推断
        // 通常表格结构是：第一行色号，最后一行数量
        if brandRows.isEmpty && rows.count >= 2 {
            // 假设第一个包含色号的行是MARD
            for row in rows {
                let hasColorCodes = row.contains { isColorCode(cleanText($0.0)) }
                if hasColorCodes {
                    brandRows["MARD"] = row
                    break
                }
            }
        }

        // 4. 如果没找到豆量行，找最后一行包含纯数字的行
        if quantityRow.isEmpty {
            for row in rows.reversed() {
                let numbers = row.filter {
                    let clean = cleanText($0.0)
                    if let num = Int(clean), num > 0 && num < 10000 {
                        return true
                    }
                    return false
                }
                if numbers.count >= 2 {  // 至少有2个数量
                    quantityRow = row
                    break
                }
            }
        }

        // 5. 按X坐标对齐列，配对色号和数量
        guard let primaryBrand = brandRows.first else {
            // 回退到简单解析
            return fallbackParsing(from: texts)
        }

        let brandName = primaryBrand.key
        var brandColorCodes = primaryBrand.value
            .sorted { $0.1.midX < $1.1.midX }  // 按X坐标排序
            .compactMap { item -> (String, CGFloat)? in
                let clean = cleanText(item.0)
                if isColorCode(clean) {
                    return (clean.uppercased(), item.1.midX)
                }
                return nil
            }

        var quantities = quantityRow
            .sorted { $0.1.midX < $1.1.midX }
            .compactMap { item -> (Int, CGFloat)? in
                let clean = cleanText(item.0)
                if let num = Int(clean), num > 0 && num < 10000 {
                    return (num, item.1.midX)
                }
                return nil
            }

        // 6. 根据X坐标对齐配对
        let xTolerance: CGFloat = 0.05

        for (colorCode, colorX) in brandColorCodes {
            // 找到X坐标最接近的数量
            var bestMatch: (Int, CGFloat)? = nil
            var bestDistance: CGFloat = CGFloat.greatestFiniteMagnitude

            for (quantity, quantityX) in quantities {
                let distance = abs(colorX - quantityX)
                if distance < bestDistance {
                    bestDistance = distance
                    bestMatch = (quantity, quantityX)
                }
            }

            if let match = bestMatch, bestDistance < xTolerance * 3 {
                items.append(RecognizedBeadItem(
                    colorCode: colorCode,
                    quantity: match.0,
                    brand: brandName
                ))
                // 移除已配对的数量
                quantities.removeAll { $0.1 == match.1 }
            }
        }

        // 7. 如果列对齐配对结果太少，尝试顺序配对
        if items.count < 3 && brandColorCodes.count > 0 && quantities.count > 0 {
            items.removeAll()
            // 重新获取数量（因为之前可能被移除了）
            quantities = quantityRow
                .sorted { $0.1.midX < $1.1.midX }
                .compactMap { item -> (Int, CGFloat)? in
                    let clean = cleanText(item.0)
                    if let num = Int(clean), num > 0 && num < 10000 {
                        return (num, item.1.midX)
                    }
                    return nil
                }

            let pairCount = min(brandColorCodes.count, quantities.count)
            for i in 0..<pairCount {
                items.append(RecognizedBeadItem(
                    colorCode: brandColorCodes[i].0,
                    quantity: quantities[i].0,
                    brand: brandName
                ))
            }
        }

        return items
    }

    // 清理文本，去除多余字符
    private func cleanText(_ text: String) -> String {
        return text.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: .punctuationCharacters)
            .replacingOccurrences(of: "*", with: "")
    }

    // 回退解析方法：当表格结构识别失败时使用
    private func fallbackParsing(from texts: [(String, CGRect)]) -> [RecognizedBeadItem] {
        var items: [RecognizedBeadItem] = []
        var allColorCodes: [(String, CGFloat)] = []
        var allQuantities: [(Int, CGFloat)] = []

        for (text, rect) in texts {
            let components = text.components(separatedBy: CharacterSet.whitespaces)

            for component in components {
                let clean = cleanText(component)

                if isColorCode(clean) && clean.count <= 5 {
                    allColorCodes.append((clean.uppercased(), rect.midX))
                } else if let num = Int(clean), num > 0 && num < 5000 {
                    allQuantities.append((num, rect.midX))
                }
            }
        }

        // 按X坐标排序
        allColorCodes.sort { $0.1 < $1.1 }
        allQuantities.sort { $0.1 < $1.1 }

        // 去重色号（同一列可能有多个品牌的色号）
        var seenCodes = Set<String>()
        var uniqueColorCodes: [(String, CGFloat)] = []
        for code in allColorCodes {
            if !seenCodes.contains(code.0) {
                seenCodes.insert(code.0)
                uniqueColorCodes.append(code)
            }
        }

        // 配对
        let pairCount = min(uniqueColorCodes.count, allQuantities.count)
        for i in 0..<pairCount {
            items.append(RecognizedBeadItem(
                colorCode: uniqueColorCodes[i].0,
                quantity: allQuantities[i].0,
                brand: "MARD"
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
