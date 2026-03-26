//
//  CSVImporter.swift
//  BeadInventory
//
//  CSV 库存导入服务
//

import Foundation
import UniformTypeIdentifiers

// MARK: - 导入条目

/// 单条导入记录
struct StockImportItem: Identifiable, Hashable {
    let id = UUID()
    let colorCode: String   // 色号
    let quantity: Int       // 数量
    let lineNumber: Int     // 原始行号（用于错误提示）
    var isValid: Bool       // 是否为有效色号
    var colorName: String?  // 颜色名称（匹配后填充）
}

/// 导入结果
struct CSVImportResult {
    let validItems: [StockImportItem]       // 有效条目
    let invalidItems: [StockImportItem]     // 无效条目（色号不存在）
    let duplicateItems: [StockImportItem]   // 重复条目（已合并到 validItems）
    let parseErrors: [String]               // 解析错误信息

    var totalValidQuantity: Int {
        validItems.reduce(0) { $0 + $1.quantity }
    }

    var isEmpty: Bool {
        validItems.isEmpty && invalidItems.isEmpty
    }

    var hasWarnings: Bool {
        !invalidItems.isEmpty || !parseErrors.isEmpty
    }
}

// MARK: - CSV 导入器

class CSVImporter {

    /// 支持的色号列名
    private static let colorCodeHeaders = [
        // 中文
        "色号", "颜色", "编号", "色码", "颜色编号", "色号编码",
        // 英文
        "color", "code", "colorcode", "color_code", "colour",
        "mardcode", "mard_code", "mard",
        "id", "sku", "item", "name", "no"
    ]
    /// 支持的数量列名
    private static let quantityHeaders = [
        // 中文
        "数量", "库存", "个数", "颗数", "数目", "总数", "存量", "数",
        // 英文
        "quantity", "qty", "amount", "stock", "count", "num", "number", "total", "inventory"
    ]

    /// 解析 CSV 内容
    /// - Parameters:
    ///   - content: CSV 文件内容
    ///   - validColorCodes: 有效色号集合（用于验证）
    ///   - colorNameMap: 色号到名称的映射
    /// - Returns: 导入结果
    static func parse(
        content: String,
        validColorCodes: Set<String>,
        colorNameMap: [String: String] = [:]
    ) -> CSVImportResult {
        var validItems: [StockImportItem] = []
        var invalidItems: [StockImportItem] = []
        var parseErrors: [String] = []
        var seenCodes: [String: Int] = [:] // 用于合并重复色号
        var duplicateItems: [StockImportItem] = []

        // 分割行
        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else {
            parseErrors.append(String(localized: "CSV 文件为空"))
            return CSVImportResult(
                validItems: [],
                invalidItems: [],
                duplicateItems: [],
                parseErrors: parseErrors
            )
        }

        // 检测分隔符
        let delimiter = detectDelimiter(lines[0])

        // 解析表头
        let headerLine = lines[0].lowercased()
        let headers = parseCSVLine(headerLine, delimiter: delimiter)

        var colorCodeIndex: Int?
        var quantityIndex: Int?

        for (index, header) in headers.enumerated() {
            let cleanHeader = header.trimmingCharacters(in: .whitespaces).lowercased()
            if colorCodeHeaders.contains(cleanHeader) {
                colorCodeIndex = index
            } else if quantityHeaders.contains(cleanHeader) {
                quantityIndex = index
            }
        }

        // 如果没有找到表头，尝试简单两列格式
        if colorCodeIndex == nil || quantityIndex == nil {
            // 假设第一列是色号，第二列是数量
            if headers.count >= 2 {
                // 检查第二列是否看起来像数字
                if let _ = Int(headers[1].trimmingCharacters(in: .whitespaces)) {
                    colorCodeIndex = 0
                    quantityIndex = 1
                } else {
                    colorCodeIndex = 0
                    quantityIndex = 1
                }
            } else if headers.count == 1 {
                parseErrors.append(String(localized: "CSV 需要至少两列：色号和数量"))
                return CSVImportResult(
                    validItems: [],
                    invalidItems: [],
                    duplicateItems: [],
                    parseErrors: parseErrors
                )
            }
        }

        guard let codeIdx = colorCodeIndex, let qtyIdx = quantityIndex else {
            parseErrors.append(String(localized: "无法识别 CSV 列：需要包含「色号」和「数量」列"))
            return CSVImportResult(
                validItems: [],
                invalidItems: [],
                duplicateItems: [],
                parseErrors: parseErrors
            )
        }

        // 判断第一行是否为数据行（没有表头）
        let startLine: Int
        if let firstQty = Int(headers[qtyIdx].trimmingCharacters(in: .whitespaces)),
           firstQty > 0 {
            // 第一行看起来像数据
            startLine = 0
        } else {
            startLine = 1
        }

        // 解析数据行
        for (index, line) in lines.enumerated() {
            if index < startLine { continue }

            let lineNumber = index + 1
            let columns = parseCSVLine(line, delimiter: delimiter)

            guard columns.count > max(codeIdx, qtyIdx) else {
                parseErrors.append(String(localized: "第 \(lineNumber) 行列数不足"))
                continue
            }

            let colorCode = columns[codeIdx]
                .trimmingCharacters(in: .whitespaces)
                .uppercased()

            let quantityStr = columns[qtyIdx]
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: ",", with: "")

            guard !colorCode.isEmpty else {
                parseErrors.append(String(localized: "第 \(lineNumber) 行色号为空"))
                continue
            }

            guard let quantity = Int(quantityStr), quantity > 0 else {
                parseErrors.append(String(localized: "第 \(lineNumber) 行数量无效：\(quantityStr)"))
                continue
            }

            let isValid = validColorCodes.contains(colorCode)
            let colorName = colorNameMap[colorCode]

            // 检查重复
            if let existingIndex = seenCodes[colorCode] {
                // 合并重复项
                let originalItem = StockImportItem(
                    colorCode: colorCode,
                    quantity: quantity,
                    lineNumber: lineNumber,
                    isValid: isValid,
                    colorName: colorName
                )
                duplicateItems.append(originalItem)

                if isValid {
                    validItems[existingIndex] = StockImportItem(
                        colorCode: colorCode,
                        quantity: validItems[existingIndex].quantity + quantity,
                        lineNumber: validItems[existingIndex].lineNumber,
                        isValid: true,
                        colorName: colorName
                    )
                }
            } else {
                let item = StockImportItem(
                    colorCode: colorCode,
                    quantity: quantity,
                    lineNumber: lineNumber,
                    isValid: isValid,
                    colorName: colorName
                )

                if isValid {
                    seenCodes[colorCode] = validItems.count
                    validItems.append(item)
                } else {
                    invalidItems.append(item)
                }
            }
        }

        return CSVImportResult(
            validItems: validItems,
            invalidItems: invalidItems,
            duplicateItems: duplicateItems,
            parseErrors: parseErrors
        )
    }

    /// 检测 CSV 分隔符
    private static func detectDelimiter(_ line: String) -> Character {
        let commaCount = line.filter { $0 == "," }.count
        let semicolonCount = line.filter { $0 == ";" }.count
        let tabCount = line.filter { $0 == "\t" }.count

        if tabCount >= commaCount && tabCount >= semicolonCount {
            return "\t"
        } else if semicolonCount > commaCount {
            return ";"
        }
        return ","
    }

    /// 解析 CSV 行（处理引号）
    private static func parseCSVLine(_ line: String, delimiter: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false

        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == delimiter && !inQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        result.append(current)

        return result
    }

    /// 生成示例 CSV 内容
    static func generateSampleCSV() -> String {
        """
        色号,数量
        A1,500
        A2,1000
        B1,800
        C3,1200
        """
    }
}

// MARK: - UTType 扩展

extension UTType {
    static var csv: UTType {
        UTType(filenameExtension: "csv") ?? .commaSeparatedText
    }
}
