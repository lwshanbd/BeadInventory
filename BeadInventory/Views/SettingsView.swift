//
//  SettingsView.swift
//  BeadInventory
//
//  设置界面
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @ObservedObject private var aiService = AIServiceManager.shared
    @AppStorage("defaultColorSystem") private var defaultColorSystemRaw: String = "MARD"
    @State private var showingResetAlert = false
    @State private var showingResetUsageAlert = false
    @State private var defaultStock = "1000"

    var body: some View {
        NavigationStack {
            List {
                // AI 识别设置
                Section {
                    Picker("AI 提供商", selection: $aiService.config.provider) {
                        ForEach(AIProvider.allCases, id: \.self) { provider in
                            Text(provider.rawValue).tag(provider)
                        }
                    }

                    SecureField("API Key", text: $aiService.config.apiKey)
                        .textContentType(.password)
                        .autocapitalization(.none)

                    TextField("API 地址（可选）", text: $aiService.config.baseURL)
                        .autocapitalization(.none)
                        .keyboardType(.URL)

                    if aiService.config.provider == .kimi {
                        Picker("模型", selection: $aiService.config.model) {
                            ForEach(AIConfig.kimiModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                    } else if aiService.config.provider == .openai {
                        Picker("模型", selection: $aiService.config.model) {
                            ForEach(AIConfig.openAIModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                    } else if aiService.config.provider == .anthropic {
                        Picker("模型", selection: $aiService.config.model) {
                            ForEach(AIConfig.anthropicModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                    } else if aiService.config.provider == .qwen {
                        Picker("模型", selection: $aiService.config.model) {
                            ForEach(AIConfig.qwenModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                    } else if aiService.config.provider == .gemini {
                        Picker("模型", selection: $aiService.config.model) {
                            ForEach(AIConfig.geminiModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                    }

                    // 配置状态提示
                    HStack {
                        Image(systemName: aiService.isConfigured ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundColor(aiService.isConfigured ? .green : .orange)
                        Text(aiService.isConfigured ? "已配置" : "请填写 API Key")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("AI 图像识别")
                } footer: {
                    if aiService.config.provider == .kimi {
                        Text("Kimi API Key 可从 platform.moonshot.cn 获取")
                    } else if aiService.config.provider == .openai {
                        Text("OpenAI API Key 可从 platform.openai.com 获取。如需代理可填写自定义 API 地址。")
                    } else if aiService.config.provider == .anthropic {
                        Text("Anthropic API Key 可从 console.anthropic.com 获取。")
                    } else if aiService.config.provider == .qwen {
                        Text("Qwen API Key 可从阿里云百炼平台 bailian.console.aliyun.com 获取。")
                    }
                }

                // 扫描默认设置
                Section {
                    Picker("默认色号体系", selection: Binding(
                        get: { ColorSystem(rawValue: defaultColorSystemRaw) ?? .mard },
                        set: { defaultColorSystemRaw = $0.rawValue }
                    )) {
                        Text("MARD").tag(ColorSystem.mard)
                        Text("卡卡").tag(ColorSystem.kaka)
                    }
                } header: {
                    Text("扫描默认设置")
                } footer: {
                    Text("新开扫描页面时默认使用的色号体系")
                }

                // 库存设置
                Section {
                    HStack {
                        Text("默认初始库存")
                        Spacer()
                        TextField("1000", text: $defaultStock)
                            .keyboardType(.asciiCapableNumberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }

                    Button {
                        showingResetAlert = true
                    } label: {
                        HStack {
                            Image(systemName: "arrow.counterclockwise")
                            Text("重置所有库存")
                        }
                        .foregroundColor(.orange)
                    }
                    .disabled(inventoryManager.currentBrandId == nil)

                    Button {
                        showingResetUsageAlert = true
                    } label: {
                        HStack {
                            Image(systemName: "xmark.circle")
                            Text("清除使用记录")
                        }
                        .foregroundColor(.red)
                    }
                    .disabled(inventoryManager.currentBrandId == nil)
                } header: {
                    if let brandName = inventoryManager.currentBrand?.name {
                        Text("库存设置 - \(brandName)")
                    } else {
                        Text("库存设置")
                    }
                } footer: {
                    if inventoryManager.currentBrandId == nil {
                        Text("请先选择或创建一个品牌")
                    }
                }

            }
            .navigationTitle("设置")
            .alert("重置库存", isPresented: $showingResetAlert) {
                Button("取消", role: .cancel) { }
                Button("重置", role: .destructive) {
                    let stock = Int(defaultStock) ?? 1000
                    inventoryManager.resetAllStock(to: stock)
                }
            } message: {
                if let brandName = inventoryManager.currentBrand?.name {
                    Text("将「\(brandName)」所有颜色的库存重置为 \(defaultStock) 颗，使用记录也将清零。此操作不可撤销。")
                } else {
                    Text("将所有颜色的库存重置为 \(defaultStock) 颗，使用记录也将清零。此操作不可撤销。")
                }
            }
            .alert("清除使用记录", isPresented: $showingResetUsageAlert) {
                Button("取消", role: .cancel) { }
                Button("清除", role: .destructive) {
                    inventoryManager.resetUsage()
                }
            } message: {
                if let brandName = inventoryManager.currentBrand?.name {
                    Text("将清除「\(brandName)」所有颜色的使用记录，库存数量不变。此操作不可撤销。")
                } else {
                    Text("将清除所有颜色的使用记录，库存数量不变。此操作不可撤销。")
                }
            }
        }
    }
}

// MARK: - 导出数据页面
struct ExportDataSheet: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var inventoryManager: InventoryManager
    @State private var exportType: ExportType = .currentBrand
    @State private var includeProjects = true
    @State private var isExporting = false
    @State private var showingShareSheet = false
    @State private var exportURL: URL?

    enum ExportType: String, CaseIterable {
        case currentBrand = "当前品牌"
        case allBrands = "所有品牌"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("导出范围", selection: $exportType) {
                        ForEach(ExportType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)

                    if exportType == .currentBrand {
                        if let brand = inventoryManager.currentBrand {
                            HStack {
                                Text("当前品牌")
                                Spacer()
                                Text(brand.name)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Text("请先选择一个品牌")
                                .foregroundColor(.orange)
                        }
                    }
                } header: {
                    Text("库存数据")
                }

                Section {
                    Toggle("包含项目记录", isOn: $includeProjects)
                } header: {
                    Text("项目数据")
                } footer: {
                    Text("导出所有项目的使用记录")
                }

                Section {
                    Button {
                        exportToCSV()
                    } label: {
                        HStack {
                            Image(systemName: "doc.text")
                            Text("导出为 CSV")
                            Spacer()
                            if isExporting {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isExporting || (exportType == .currentBrand && inventoryManager.currentBrandId == nil))

                    Button {
                        exportToJSON()
                    } label: {
                        HStack {
                            Image(systemName: "doc.badge.gearshape")
                            Text("导出为 JSON")
                            Spacer()
                            if isExporting {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isExporting || (exportType == .currentBrand && inventoryManager.currentBrandId == nil))
                } header: {
                    Text("导出格式")
                }
            }
            .navigationTitle("导出数据")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .sheet(isPresented: $showingShareSheet) {
                if let url = exportURL {
                    ShareSheet(items: [url])
                }
            }
        }
    }

    func exportToCSV() {
        isExporting = true

        var csv = ""

        // 导出库存数据
        csv += "# 库存数据\n"
        csv += "品牌,MARD色号,库存,已用,可用\n"

        let brandsToExport: [Brand]
        if exportType == .currentBrand, let brand = inventoryManager.currentBrand {
            brandsToExport = [brand]
        } else {
            brandsToExport = inventoryManager.brands
        }

        for brand in brandsToExport {
            let stocks = inventoryManager.brandStocks.filter { $0.brandId == brand.id }
            for stock in stocks {
                csv += "\(brand.name),\(stock.mardCode),\(stock.stock),\(stock.used),\(stock.available)\n"
            }
        }

        // 导出项目记录
        if includeProjects {
            csv += "\n# 项目记录\n"
            csv += "项目名称,日期,总用量,品牌,状态\n"

            for project in inventoryManager.projects {
                let brandName = inventoryManager.brands.first { $0.id == project.brandId }?.name ?? "未知"
                let status: String
                if project.isPlanned {
                    status = "计划中"
                } else if project.isArchived {
                    status = "已归档"
                } else {
                    status = "进行中"
                }
                let dateStr = formatDate(project.date)
                csv += "\(project.name),\(dateStr),\(project.totalBeads),\(brandName),\(status)\n"
            }

            csv += "\n# 项目详细用量\n"
            csv += "项目名称,色号,用量\n"

            for project in inventoryManager.projects {
                for usage in project.beadUsage {
                    csv += "\(project.name),\(usage.colorCode),\(usage.quantity)\n"
                }
            }
        }

        // 保存到临时文件
        let fileName = "BeadInventory_\(formatDateForFile(Date())).csv"
        saveAndShare(content: csv, fileName: fileName)
    }

    func exportToJSON() {
        isExporting = true

        var exportData: [String: Any] = [:]
        exportData["exportDate"] = ISO8601DateFormatter().string(from: Date())
        exportData["appVersion"] = "1.0"

        // 导出品牌
        let brandsToExport: [Brand]
        if exportType == .currentBrand, let brand = inventoryManager.currentBrand {
            brandsToExport = [brand]
        } else {
            brandsToExport = inventoryManager.brands
        }

        exportData["brands"] = brandsToExport.map { brand in
            [
                "id": brand.id.uuidString,
                "name": brand.name,
                "sortOrder": brand.sortOrder
            ]
        }

        // 导出库存
        var stocksData: [[String: Any]] = []
        for brand in brandsToExport {
            let stocks = inventoryManager.brandStocks.filter { $0.brandId == brand.id }
            for stock in stocks {
                stocksData.append([
                    "brandId": stock.brandId.uuidString,
                    "brandName": brand.name,
                    "mardCode": stock.mardCode,
                    "stock": stock.stock,
                    "used": stock.used,
                    "available": stock.available
                ])
            }
        }
        exportData["stocks"] = stocksData

        // 导出项目记录
        if includeProjects {
            exportData["projects"] = inventoryManager.projects.map { project in
                var projectData: [String: Any] = [
                    "id": project.id.uuidString,
                    "name": project.name,
                    "date": ISO8601DateFormatter().string(from: project.date),
                    "totalBeads": project.totalBeads,
                    "isArchived": project.isArchived,
                    "isPlanned": project.isPlanned
                ]
                if let brandId = project.brandId {
                    projectData["brandId"] = brandId.uuidString
                    projectData["brandName"] = inventoryManager.brands.first { $0.id == brandId }?.name ?? ""
                }
                projectData["beadUsage"] = project.beadUsage.map { usage in
                    [
                        "colorCode": usage.colorCode,
                        "quantity": usage.quantity,
                        "isDeducted": usage.isDeducted
                    ]
                }
                return projectData
            }
        }

        // 转换为 JSON
        if let jsonData = try? JSONSerialization.data(withJSONObject: exportData, options: [.prettyPrinted, .sortedKeys]),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            let fileName = "BeadInventory_\(formatDateForFile(Date())).json"
            saveAndShare(content: jsonString, fileName: fileName)
        } else {
            isExporting = false
        }
    }

    func saveAndShare(content: String, fileName: String) {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(fileName)

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            exportURL = fileURL
            isExporting = false
            showingShareSheet = true
        } catch {
            print("导出失败: \(error)")
            isExporting = false
        }
    }

    func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    func formatDateForFile(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: date)
    }
}

// MARK: - 分享Sheet
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - 帮助页面
struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HelpSection(
                    icon: "square.grid.3x3.fill",
                    title: "库存管理",
                    content: """
                    • 查看所有颜色的库存状态
                    • 点击颜色卡片可编辑库存
                    • 支持按品牌色号显示
                    • 可搜索任意品牌的色号
                    """
                )

                HelpSection(
                    icon: "doc.text.viewfinder",
                    title: "图纸扫描",
                    content: """
                    • 拍照或选择色号表格图片
                    • 自动识别色号和数量
                    • 可手动编辑识别结果
                    • 确认后自动从库存扣减
                    """
                )

                HelpSection(
                    icon: "paintpalette.fill",
                    title: "色号转换",
                    content: """
                    • 输入任意品牌色号查询
                    • 自动显示对应的其他品牌色号
                    • 支持 MARD、vivid、漫漫、卡卡
                    • 点击可复制色号
                    """
                )

                HelpSection(
                    icon: "chart.bar.fill",
                    title: "统计功能",
                    content: """
                    • 查看整体库存使用情况
                    • 使用量排行榜
                    • 低库存预警
                    • 项目历史记录
                    """
                )

                HelpSection(
                    icon: "lightbulb.fill",
                    title: "使用技巧",
                    content: """
                    • 建议初始库存设为1000颗/色
                    • 识别有水印图片时，可手动调整结果
                    • 定期导出数据做备份
                    • 低库存颜色会红色标识
                    """
                )
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("使用帮助")
    }
}

struct HelpSection: View {
    let icon: String
    let title: String
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.accentColor)
                    .font(.title2)

                Text(title)
                    .font(.headline)
            }

            Text(content)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
        .cornerRadius(16)
    }
}

#Preview {
    SettingsView()
        .environmentObject(InventoryManager())
}
