//
//  ImportFullDataView.swift
//  BeadInventory
//
//  导入完整历史数据（包括品牌、库存、项目）
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - 导入数据结构

/// 导入的完整数据
struct ImportedFullData {
    var brands: [ImportedBrand]
    var stocks: [ImportedStock]
    var projects: [ImportedProject]
    var parseErrors: [String]

    var isEmpty: Bool {
        brands.isEmpty && stocks.isEmpty && projects.isEmpty
    }

    var hasWarnings: Bool {
        !parseErrors.isEmpty
    }
}

struct ImportedBrand: Identifiable, Hashable {
    let id: UUID
    let name: String
    let sortOrder: Int
    var isNew: Bool = true  // 是否为新品牌
}

struct ImportedStock: Identifiable, Hashable {
    let id = UUID()
    let brandName: String
    let brandId: UUID?
    let mardCode: String
    let stock: Int
    let used: Int
}

struct ImportedProject: Identifiable, Hashable {
    let id: UUID
    let name: String
    let date: Date
    let totalBeads: Int
    let brandName: String?
    let brandId: UUID?
    let isArchived: Bool
    let isPlanned: Bool
    let beadUsage: [ImportedBeadUsage]

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ImportedProject, rhs: ImportedProject) -> Bool {
        lhs.id == rhs.id
    }
}

struct ImportedBeadUsage: Identifiable, Hashable {
    let id = UUID()
    let colorCode: String
    let quantity: Int
    let isDeducted: Bool
}

// MARK: - 全量数据导入器

class FullDataImporter {

    /// 解析JSON格式的导出数据
    static func parseJSON(content: String) -> ImportedFullData {
        var brands: [ImportedBrand] = []
        var stocks: [ImportedStock] = []
        var projects: [ImportedProject] = []
        var parseErrors: [String] = []

        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            parseErrors.append("无法解析 JSON 格式")
            return ImportedFullData(brands: [], stocks: [], projects: [], parseErrors: parseErrors)
        }

        // 解析品牌
        if let brandsArray = json["brands"] as? [[String: Any]] {
            for brandDict in brandsArray {
                if let idStr = brandDict["id"] as? String,
                   let id = UUID(uuidString: idStr),
                   let name = brandDict["name"] as? String {
                    let sortOrder = brandDict["sortOrder"] as? Int ?? 0
                    brands.append(ImportedBrand(id: id, name: name, sortOrder: sortOrder))
                }
            }
        }

        // 解析库存
        if let stocksArray = json["stocks"] as? [[String: Any]] {
            for stockDict in stocksArray {
                let brandName = stockDict["brandName"] as? String ?? ""
                let brandIdStr = stockDict["brandId"] as? String
                let brandId = brandIdStr.flatMap { UUID(uuidString: $0) }
                let mardCode = stockDict["mardCode"] as? String ?? ""
                let stock = stockDict["stock"] as? Int ?? 0
                let used = stockDict["used"] as? Int ?? 0

                if !mardCode.isEmpty {
                    stocks.append(ImportedStock(
                        brandName: brandName,
                        brandId: brandId,
                        mardCode: mardCode,
                        stock: stock,
                        used: used
                    ))
                }
            }
        }

        // 解析项目
        if let projectsArray = json["projects"] as? [[String: Any]] {
            let dateFormatter = ISO8601DateFormatter()

            for projectDict in projectsArray {
                guard let idStr = projectDict["id"] as? String,
                      let id = UUID(uuidString: idStr),
                      let name = projectDict["name"] as? String else {
                    continue
                }

                let dateStr = projectDict["date"] as? String ?? ""
                let date = dateFormatter.date(from: dateStr) ?? Date()
                let totalBeads = projectDict["totalBeads"] as? Int ?? 0
                let brandName = projectDict["brandName"] as? String
                let brandIdStr = projectDict["brandId"] as? String
                let brandId = brandIdStr.flatMap { UUID(uuidString: $0) }
                let isArchived = projectDict["isArchived"] as? Bool ?? false
                var isPlanned = projectDict["isPlanned"] as? Bool ?? false

                // 解析用量
                var beadUsage: [ImportedBeadUsage] = []
                var hasAnyDeducted = false
                if let usageArray = projectDict["beadUsage"] as? [[String: Any]] {
                    for usageDict in usageArray {
                        if let colorCode = usageDict["colorCode"] as? String,
                           let quantity = usageDict["quantity"] as? Int {
                            let isDeducted = usageDict["isDeducted"] as? Bool ?? false
                            if isDeducted {
                                hasAnyDeducted = true
                            }
                            beadUsage.append(ImportedBeadUsage(
                                colorCode: colorCode,
                                quantity: quantity,
                                isDeducted: isDeducted
                            ))
                        }
                    }
                }

                // 兼容旧版本数据：如果 JSON 中没有 isPlanned 字段，
                // 通过检查用量是否已扣减来推断是否为计划项目
                let hasExplicitIsPlanned = projectDict["isPlanned"] != nil
                if !hasExplicitIsPlanned && !isArchived && !beadUsage.isEmpty && !hasAnyDeducted {
                    // 所有用量都未扣减，且不是归档项目，推断为计划项目
                    isPlanned = true
                }

                projects.append(ImportedProject(
                    id: id,
                    name: name,
                    date: date,
                    totalBeads: totalBeads,
                    brandName: brandName,
                    brandId: brandId,
                    isArchived: isArchived,
                    isPlanned: isPlanned,
                    beadUsage: beadUsage
                ))
            }
        }

        return ImportedFullData(brands: brands, stocks: stocks, projects: projects, parseErrors: parseErrors)
    }

    /// 解析CSV格式的导出数据
    static func parseCSV(content: String) -> ImportedFullData {
        var brands: [ImportedBrand] = []
        var stocks: [ImportedStock] = []
        var projects: [ImportedProject] = []
        let parseErrors: [String] = []

        // 用于临时存储项目用量
        var projectUsageMap: [String: [ImportedBeadUsage]] = [:]
        var projectInfoMap: [String: (date: Date, totalBeads: Int, brandName: String, status: String)] = [:]

        var currentSection = ""
        let lines = content.components(separatedBy: .newlines)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"

        for (_, line) in lines.enumerated() {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            // 跳过空行
            guard !trimmedLine.isEmpty else { continue }

            // 检测分区标记
            if trimmedLine.hasPrefix("# ") {
                if trimmedLine.contains("库存数据") {
                    currentSection = "stocks"
                } else if trimmedLine.contains("项目记录") {
                    currentSection = "projects"
                } else if trimmedLine.contains("项目详细用量") {
                    currentSection = "usage"
                }
                continue
            }

            // 跳过表头行
            if isHeaderLine(trimmedLine) { continue }

            // 根据当前分区解析数据
            let columns = parseCSVLine(trimmedLine, delimiter: detectDelimiter(trimmedLine))

            switch currentSection {
            case "stocks":
                if columns.count >= 4 {
                    let brandName = columns[0]
                    let mardCode = columns[1].uppercased()
                    let stock = Int(columns[2]) ?? 0
                    let used = Int(columns[3]) ?? 0

                    if !mardCode.isEmpty {
                        // 检查是否有新品牌
                        if !brands.contains(where: { $0.name == brandName }) && !brandName.isEmpty {
                            brands.append(ImportedBrand(
                                id: UUID(),
                                name: brandName,
                                sortOrder: brands.count
                            ))
                        }

                        stocks.append(ImportedStock(
                            brandName: brandName,
                            brandId: nil,
                            mardCode: mardCode,
                            stock: stock,
                            used: used
                        ))
                    }
                }

            case "projects":
                if columns.count >= 5 {
                    let projectName = columns[0]
                    let dateStr = columns[1]
                    let totalBeads = Int(columns[2]) ?? 0
                    let brandName = columns[3]
                    let status = columns[4]

                    let date = dateFormatter.date(from: dateStr) ?? Date()
                    projectInfoMap[projectName] = (date, totalBeads, brandName, status)
                }

            case "usage":
                if columns.count >= 3 {
                    let projectName = columns[0]
                    let colorCode = columns[1].uppercased()
                    let quantity = Int(columns[2]) ?? 0

                    if quantity > 0 {
                        let usage = ImportedBeadUsage(
                            colorCode: colorCode,
                            quantity: quantity,
                            isDeducted: false
                        )

                        if projectUsageMap[projectName] != nil {
                            projectUsageMap[projectName]?.append(usage)
                        } else {
                            projectUsageMap[projectName] = [usage]
                        }
                    }
                }

            default:
                // 如果没有分区标记，尝试作为简单库存数据解析
                if columns.count >= 2 {
                    let code = columns[0].uppercased()
                    if let quantity = Int(columns[1]), quantity > 0 {
                        stocks.append(ImportedStock(
                            brandName: "",
                            brandId: nil,
                            mardCode: code,
                            stock: quantity,
                            used: 0
                        ))
                    }
                }
            }
        }

        // 组合项目信息和用量
        for (projectName, info) in projectInfoMap {
            let rawUsage = projectUsageMap[projectName] ?? []
            let isArchived = info.status == "已归档"
            let isPlanned = info.status == "计划中"

            // 根据项目状态推断 isDeducted：计划中的项目未扣减，已执行的项目已扣减
            let usage = rawUsage.map { u in
                ImportedBeadUsage(
                    colorCode: u.colorCode,
                    quantity: u.quantity,
                    isDeducted: !isPlanned  // 非计划项目的用量视为已扣减
                )
            }

            projects.append(ImportedProject(
                id: UUID(),
                name: projectName,
                date: info.date,
                totalBeads: info.totalBeads,
                brandName: info.brandName.isEmpty ? nil : info.brandName,
                brandId: nil,
                isArchived: isArchived,
                isPlanned: isPlanned,
                beadUsage: usage
            ))
        }

        // 按日期排序项目（新的在前）
        projects.sort { $0.date > $1.date }

        return ImportedFullData(brands: brands, stocks: stocks, projects: projects, parseErrors: parseErrors)
    }

    /// 检测是否为表头行
    private static func isHeaderLine(_ line: String) -> Bool {
        let headerKeywords = ["品牌", "MARD", "色号", "库存", "已用", "项目名称", "日期", "状态", "用量", "颜色"]
        let lowercased = line.lowercased()
        return headerKeywords.contains { lowercased.contains($0.lowercased()) }
    }

    /// 检测分隔符
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
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
        }
        result.append(current.trimmingCharacters(in: .whitespaces))

        return result
    }

    /// 自动检测文件格式并解析
    static func parse(content: String) -> ImportedFullData {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        // 尝试检测是否为JSON
        if trimmed.hasPrefix("{") {
            return parseJSON(content: content)
        } else {
            return parseCSV(content: content)
        }
    }
}

// MARK: - 导入完整数据视图

struct ImportFullDataView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss

    @State private var showingFilePicker = false
    @State private var importData: ImportedFullData?
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var showingSuccessAlert = false
    @State private var importSummary = ""

    // 导入选项
    @State private var importBrands = true
    @State private var importStocks = true
    @State private var importProjects = true
    @State private var overwriteExisting = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let data = importData {
                    // 显示导入预览
                    ImportFullDataPreviewView(
                        data: data,
                        importBrands: $importBrands,
                        importStocks: $importStocks,
                        importProjects: $importProjects,
                        overwriteExisting: $overwriteExisting,
                        onConfirm: {
                            performImport(data: data)
                        },
                        onCancel: {
                            importData = nil
                        }
                    )
                } else {
                    // 选择文件界面
                    selectFileView
                }
            }
            .navigationTitle("导入历史数据")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: [.json, .commaSeparatedText, .plainText],
                allowsMultipleSelection: false
            ) { result in
                handleFileSelection(result)
            }
            .alert("导入成功", isPresented: $showingSuccessAlert) {
                Button("确定") {
                    dismiss()
                }
            } message: {
                Text(importSummary)
            }
            .alert("导入失败", isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("确定") { }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - 选择文件界面

    private var selectFileView: some View {
        VStack(spacing: 24) {
            Spacer()

            // 图标
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)

            // 说明文字
            VStack(spacing: 8) {
                Text("导入历史数据")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("选择由「导出库存数据」功能导出的 CSV 或 JSON 文件")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            // 选择文件按钮
            Button {
                showingFilePicker = true
            } label: {
                HStack {
                    Image(systemName: "folder")
                    Text("选择文件")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.accentColor)
                .foregroundColor(.white)
                .cornerRadius(Theme.Radius.md)
            }
            .padding(.horizontal, 40)

            if isProcessing {
                ProgressView("正在解析...")
            }

            Spacer()

            // 说明
            supportedFormatHint
        }
        .padding()
    }

    // 支持的格式提示
    private var supportedFormatHint: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("支持的数据")
                .font(.subheadline)
                .fontWeight(.medium)

            VStack(alignment: .leading, spacing: 8) {
                FormatHintRow(icon: "tag.fill", text: "品牌信息")
                FormatHintRow(icon: "square.grid.3x3.fill", text: "库存数据（色号、数量、已用）")
                FormatHintRow(icon: "doc.text.fill", text: "项目记录（包含详细用量）")
            }
            .padding()
            .background(Theme.ColorToken.Surface.subtle)
            .cornerRadius(Theme.Radius.sm)

            Text("支持 JSON 和 CSV 格式，会自动识别")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(Theme.Radius.md)
    }

    // MARK: - 文件处理

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            processFile(url)

        case .failure(let error):
            errorMessage = "无法选择文件：\(error.localizedDescription)"
        }
    }

    private func processFile(_ url: URL) {
        isProcessing = true

        // 获取文件访问权限
        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = "无法访问文件"
            isProcessing = false
            return
        }

        defer {
            url.stopAccessingSecurityScopedResource()
        }

        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let result = FullDataImporter.parse(content: content)

            if result.isEmpty && !result.parseErrors.isEmpty {
                errorMessage = result.parseErrors.joined(separator: "\n")
            } else if result.isEmpty {
                errorMessage = "文件中没有找到可导入的数据"
            } else {
                importData = result
            }
        } catch {
            errorMessage = "无法读取文件：\(error.localizedDescription)"
        }

        isProcessing = false
    }

    // MARK: - 执行导入

    private func performImport(data: ImportedFullData) {
        var brandCount = 0
        var stockCount = 0
        var projectCount = 0

        // 建立品牌名称到ID的映射
        var brandNameToId: [String: UUID] = [:]

        // 先加载现有品牌的映射
        for brand in inventoryManager.brands {
            brandNameToId[brand.name] = brand.id
        }

        // 导入品牌
        if importBrands {
            for importedBrand in data.brands {
                // 检查是否已存在同名品牌
                if let existingBrand = inventoryManager.brands.first(where: { $0.name == importedBrand.name }) {
                    brandNameToId[importedBrand.name] = existingBrand.id
                } else {
                    // 创建新品牌
                    let newBrand = inventoryManager.addBrand(name: importedBrand.name, defaultStock: 0)
                    brandNameToId[importedBrand.name] = newBrand.id
                    brandCount += 1
                }
            }
        }

        // 导入库存
        if importStocks {
            // 按品牌分组
            var stocksByBrand: [String: [(mardCode: String, stock: Int, used: Int)]] = [:]
            for stock in data.stocks {
                let brandName = stock.brandName.isEmpty ? (inventoryManager.currentBrand?.name ?? "") : stock.brandName
                if stocksByBrand[brandName] != nil {
                    stocksByBrand[brandName]?.append((stock.mardCode, stock.stock, stock.used))
                } else {
                    stocksByBrand[brandName] = [(stock.mardCode, stock.stock, stock.used)]
                }
            }

            for (brandName, stocks) in stocksByBrand {
                guard let brandId = brandNameToId[brandName] ?? inventoryManager.currentBrandId else {
                    continue
                }

                for stockItem in stocks {
                    // 查找现有库存
                    if let existingIndex = inventoryManager.brandStocks.firstIndex(where: {
                        $0.brandId == brandId && $0.mardCode == stockItem.mardCode
                    }) {
                        if overwriteExisting {
                            // 覆盖现有数据
                            inventoryManager.brandStocks[existingIndex].stock = stockItem.stock
                            inventoryManager.brandStocks[existingIndex].used = stockItem.used
                        } else {
                            // 累加数据
                            inventoryManager.brandStocks[existingIndex].stock += stockItem.stock
                            inventoryManager.brandStocks[existingIndex].used += stockItem.used
                        }
                        stockCount += 1
                    } else {
                        // 创建新库存记录
                        let newStock = BrandStock(
                            brandId: brandId,
                            mardCode: stockItem.mardCode,
                            stock: stockItem.stock,
                            used: stockItem.used,
                            isHidden: false
                        )
                        inventoryManager.brandStocks.append(newStock)
                        stockCount += 1
                    }
                }
            }
        }

        // 导入项目
        if importProjects {
            for importedProject in data.projects {
                // 检查是否已存在同名同日期的项目
                let existsProject = inventoryManager.projects.contains { existing in
                    existing.name == importedProject.name &&
                    Calendar.current.isDate(existing.date, inSameDayAs: importedProject.date)
                }

                if existsProject && !overwriteExisting {
                    continue
                }

                // 确定项目关联的品牌
                var projectBrandId: UUID? = nil
                if let brandName = importedProject.brandName {
                    projectBrandId = brandNameToId[brandName]
                }
                if projectBrandId == nil {
                    projectBrandId = inventoryManager.currentBrandId
                }

                // 转换用量数据
                let beadUsage = importedProject.beadUsage.map { usage in
                    BeadUsage(
                        colorCode: usage.colorCode,
                        brandId: projectBrandId,
                        quantity: usage.quantity,
                        isDeducted: usage.isDeducted
                    )
                }

                // 创建项目记录
                let project = ProjectRecord(
                    name: importedProject.name,
                    date: importedProject.date,
                    beadUsage: beadUsage,
                    brandId: projectBrandId,
                    isArchived: importedProject.isArchived,
                    isPlanned: importedProject.isPlanned
                )

                inventoryManager.projects.append(project)
                projectCount += 1
            }

            // 按日期排序
            inventoryManager.projects.sort { $0.date > $1.date }
        }

        // 保存数据
        inventoryManager.saveData()

        // 生成摘要
        var summaryParts: [String] = []
        if brandCount > 0 {
            summaryParts.append("新增 \(brandCount) 个品牌")
        }
        if stockCount > 0 {
            summaryParts.append("导入 \(stockCount) 条库存记录")
        }
        if projectCount > 0 {
            summaryParts.append("导入 \(projectCount) 个项目")
        }

        if summaryParts.isEmpty {
            importSummary = "没有新数据需要导入"
        } else {
            importSummary = summaryParts.joined(separator: "\n")
        }

        showingSuccessAlert = true
    }
}

// MARK: - 格式提示行

struct FormatHintRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .frame(width: 20)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - 导入预览视图

struct ImportFullDataPreviewView: View {
    let data: ImportedFullData
    @Binding var importBrands: Bool
    @Binding var importStocks: Bool
    @Binding var importProjects: Bool
    @Binding var overwriteExisting: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 统计信息
            summarySection

            Divider()

            // 详情列表
            List {
                // 导入选项
                Section {
                    if !data.brands.isEmpty {
                        Toggle(isOn: $importBrands) {
                            HStack {
                                Image(systemName: "tag.fill")
                                    .foregroundColor(Theme.ColorToken.Status.info)
                                Text("导入品牌")
                                Spacer()
                                Text("\(data.brands.count) 个")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    if !data.stocks.isEmpty {
                        Toggle(isOn: $importStocks) {
                            HStack {
                                Image(systemName: "square.grid.3x3.fill")
                                    .foregroundColor(Theme.ColorToken.Status.success)
                                Text("导入库存")
                                Spacer()
                                Text("\(data.stocks.count) 条")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    if !data.projects.isEmpty {
                        Toggle(isOn: $importProjects) {
                            HStack {
                                Image(systemName: "doc.text.fill")
                                    .foregroundColor(Theme.ColorToken.Status.warning)
                                Text("导入项目")
                                Spacer()
                                Text("\(data.projects.count) 个")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("选择导入内容")
                }

                // 高级选项
                Section {
                    Toggle(isOn: $overwriteExisting) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("覆盖现有数据")
                            Text("关闭时会累加库存数量、跳过同名项目")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("导入选项")
                }

                // 品牌预览
                if !data.brands.isEmpty && importBrands {
                    Section {
                        ForEach(data.brands.prefix(5)) { brand in
                            HStack {
                                Text(brand.name)
                                    .fontWeight(.medium)
                                Spacer()
                                Text("品牌")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        if data.brands.count > 5 {
                            Text("还有 \(data.brands.count - 5) 个品牌...")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    } header: {
                        Text("品牌预览")
                    }
                }

                // 库存预览
                if !data.stocks.isEmpty && importStocks {
                    Section {
                        ForEach(data.stocks.prefix(5)) { stock in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(stock.mardCode)
                                        .font(.system(.body, design: .monospaced))
                                        .fontWeight(.medium)
                                    if !stock.brandName.isEmpty {
                                        Text(stock.brandName)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("库存 \(stock.stock)")
                                        .font(.subheadline)
                                    Text("已用 \(stock.used)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        if data.stocks.count > 5 {
                            Text("还有 \(data.stocks.count - 5) 条库存记录...")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    } header: {
                        Text("库存预览")
                    }
                }

                // 项目预览
                if !data.projects.isEmpty && importProjects {
                    Section {
                        ForEach(data.projects.prefix(5)) { project in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(project.name)
                                        .fontWeight(.medium)
                                    HStack(spacing: 8) {
                                        Text(project.date.formatted(date: .abbreviated, time: .omitted))
                                        Text("·")
                                        Text("\(project.totalBeads) 颗")
                                        if project.isPlanned {
                                            Text("计划中")
                                                .foregroundColor(Theme.ColorToken.Status.info)
                                        } else if project.isArchived {
                                            Text("已归档")
                                                .foregroundColor(Theme.ColorToken.Text.secondary)
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                }
                                Spacer()
                                Text("\(project.beadUsage.count) 色")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        if data.projects.count > 5 {
                            Text("还有 \(data.projects.count - 5) 个项目...")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    } header: {
                        Text("项目预览")
                    }
                }

                // 解析警告
                if !data.parseErrors.isEmpty {
                    Section {
                        ForEach(data.parseErrors, id: \.self) { error in
                            Text(error)
                                .font(.caption)
                                .foregroundColor(Theme.ColorToken.Status.warning)
                        }
                    } header: {
                        Text("解析警告")
                    }
                }
            }

            Divider()

            // 操作按钮
            HStack(spacing: 16) {
                Button {
                    onCancel()
                } label: {
                    Text("重新选择")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Theme.ColorToken.Surface.subtle)
                        .foregroundColor(.primary)
                        .cornerRadius(Theme.Radius.md)
                }

                Button {
                    onConfirm()
                } label: {
                    Text("确认导入")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(canImport ? Color.accentColor : Theme.ColorToken.Border.default)
                        .foregroundColor(.white)
                        .cornerRadius(Theme.Radius.md)
                }
                .disabled(!canImport)
            }
            .padding()
        }
    }

    private var canImport: Bool {
        (importBrands && !data.brands.isEmpty) ||
        (importStocks && !data.stocks.isEmpty) ||
        (importProjects && !data.projects.isEmpty)
    }

    private var summarySection: some View {
        HStack(spacing: 20) {
            if !data.brands.isEmpty {
                VStack {
                    Text("\(data.brands.count)")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(Theme.ColorToken.Status.info)
                    Text("品牌")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if !data.stocks.isEmpty {
                if !data.brands.isEmpty {
                    Divider().frame(height: 40)
                }
                VStack {
                    Text("\(data.stocks.count)")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(Theme.ColorToken.Status.success)
                    Text("库存")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if !data.projects.isEmpty {
                if !data.stocks.isEmpty || !data.brands.isEmpty {
                    Divider().frame(height: 40)
                }
                VStack {
                    Text("\(data.projects.count)")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(Theme.ColorToken.Status.warning)
                    Text("项目")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Theme.ColorToken.Surface.subtle)
    }
}

#Preview {
    ImportFullDataView()
        .environmentObject(InventoryManager())
}
