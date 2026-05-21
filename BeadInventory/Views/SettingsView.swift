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
                RecognitionSettingsSections(aiService: aiService)

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

struct RecognitionSettingsScreen: View {
    @ObservedObject private var aiService = AIServiceManager.shared

    var body: some View {
        Form {
            RecognitionSettingsSections(aiService: aiService)
        }
        .navigationTitle("识别设置")
    }
}

struct RecognitionSettingsSections: View {
    @ObservedObject var aiService: AIServiceManager
    @ObservedObject private var localModelManager = LocalModelManager.shared
    @State private var showingAPIHelpSheet = false

    private var deviceProfile: LocalModelDeviceProfile {
        .current
    }

    var body: some View {
        Section {
            Picker("识别方式", selection: $aiService.config.backend) {
                ForEach(RecognitionBackend.allCases, id: \.self) { backend in
                    Text(backend.displayName).tag(backend)
                }
            }
            .pickerStyle(.segmented)

            if aiService.config.backend == .local {
                localBackendContent
            } else {
                cloudBackendContent
            }
        } header: {
            Text("AI 图像识别")
        } footer: {
            Text(sectionFooterText)
        }

        Section("当前状态") {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: aiService.isConfigured ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundColor(aiService.isConfigured ? .green : .orange)
                    .font(.headline)

                VStack(alignment: .leading, spacing: 4) {
                    Text(aiService.statusMessage)
                        .font(.subheadline)

                    Text(aiService.setupBannerText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .sheet(isPresented: $showingAPIHelpSheet) {
            HelpCenterNavigationView(initialDestination: .scanAPISetup)
        }
        .onAppear {
            localModelManager.refreshDownloadedModels()
            APISetupTip.hasConfiguredAPI = aiService.isConfigured
        }
        .onChange(of: aiService.isConfigured) { _, newValue in
            APISetupTip.hasConfiguredAPI = newValue
        }
    }

    private var localBackendContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(deviceProfile.summaryText)
                .font(.footnote)
                .foregroundColor(.secondary)

            ForEach(LocalRecognitionModel.allCases) { model in
                LocalModelOptionCard(
                    model: model,
                    isSelected: aiService.config.localModel == model,
                    aiService: aiService,
                    localModelManager: localModelManager,
                    recommendationText: deviceProfile.recommendation(for: model)
                )
            }
        }
        .padding(.vertical, 4)
    }

    private var cloudBackendContent: some View {
        Group {
            HStack {
                Text("API 配置")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                Button {
                    showingAPIHelpSheet = true
                } label: {
                    Image(systemName: "questionmark.circle")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("API 配置帮助")
            }

            Picker("AI 提供商", selection: $aiService.config.provider) {
                ForEach(AIProvider.allCases, id: \.self) { provider in
                    Text(provider.rawValue).tag(provider)
                }
            }

            SecureField("API Key", text: $aiService.config.apiKey)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if aiService.config.hasKeyFormatWarning {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text("\(aiService.config.provider.rawValue) 的 API Key 通常以 \"sk-\" 开头，你当前填写的 Key 格式可能不正确，请确认。")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            Toggle("自定义 API 地址", isOn: $aiService.config.enableCustomURL)

            if aiService.config.enableCustomURL {
                TextField("API 地址", text: $aiService.config.baseURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
            }

            Picker("模型", selection: $aiService.config.model) {
                ForEach(models(for: aiService.config.provider), id: \.self) { model in
                    Text(model).tag(model)
                }
            }
        }
    }

    private var sectionFooterText: String {
        if aiService.config.backend == .local {
            return "推荐优先使用云端在线模型：识别更准、速度更快、无需占用本机存储。本地模型仅建议在无网络环境使用——下载体积较大，识别速度较慢，也可能造成手机发热。"
        }

        return cloudProviderFooterText(for: aiService.config.provider)
    }

    private func models(for provider: AIProvider) -> [String] {
        switch provider {
        case .kimi:
            return AIConfig.kimiModels
        case .openai:
            return AIConfig.openAIModels
        case .anthropic:
            return AIConfig.anthropicModels
        case .qwen:
            return AIConfig.qwenModels
        case .gemini:
            return AIConfig.geminiModels
        }
    }

    private func cloudProviderFooterText(for provider: AIProvider) -> String {
        switch provider {
        case .kimi:
            return "Kimi API Key 可从 platform.moonshot.cn 获取。"
        case .openai:
            return "OpenAI API Key 可从 platform.openai.com 获取；如需代理可填写自定义 API 地址。"
        case .anthropic:
            return "Anthropic API Key 可从 console.anthropic.com 获取。"
        case .qwen:
            return "Qwen API Key 可从阿里云百炼平台 bailian.console.aliyun.com 获取。"
        case .gemini:
            return "Gemini API Key 可从 aistudio.google.com 获取。"
        }
    }
}

/// 注：本卡片的"选择/下载"和"删除模型"按钮在 BIDS Task 4 中**未**迁移到
/// BISecondaryButton / BIDestructiveButton。理由：两者的 label 包含动态
/// `ProgressView`（下载中 / 删除中状态）与 `isSelected` 驱动的 tint，
/// 当前 BIDS 按钮组件 API 不支持这种动态 label/tint。如未来扩展组件
/// 支持自定义 label，可一并迁移。
struct LocalModelOptionCard: View {
    let model: LocalRecognitionModel
    let isSelected: Bool
    @ObservedObject var aiService: AIServiceManager
    @ObservedObject var localModelManager: LocalModelManager
    let recommendationText: String

    @State private var isStartingDownload = false
    @State private var showingDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.displayName)
                        .font(.headline)

                    Text("下载 \(model.approximateDownloadSize) · 占用约 \(model.approximateStorageSize)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if localModelManager.isDownloaded(model) {
                    Label("已下载", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }

            Text(recommendationText)
                .font(.subheadline)

            Text(model.cautionText)
                .font(.caption)
                .foregroundColor(.secondary)

            if localModelManager.isDownloading.contains(model) {
                ProgressView(value: localModelManager.progress(for: model))
                Text("下载中 \(Int(localModelManager.progress(for: model) * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let errorMessage = localModelManager.errorMessage(for: model) {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            if localModelManager.isDownloaded(model) {
                HStack(spacing: 10) {
                    Button {
                        aiService.config.backend = .local
                        aiService.config.localModel = model
                    } label: {
                        HStack {
                            Text(buttonTitle)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(localModelManager.isDeleting.contains(model) || isSelected)
                    .tint(isSelected ? .green : .accentColor)

                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        HStack {
                            if localModelManager.isDeleting.contains(model) {
                                ProgressView()
                            }
                            Text(localModelManager.isDeleting.contains(model) ? "删除中" : "删除模型")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        localModelManager.isDownloading.contains(model) ||
                        localModelManager.isDeleting.contains(model) ||
                        localModelManager.isLoadingModel
                    )
                    .tint(.red)
                }
            } else {
                Button {
                    isStartingDownload = true
                    aiService.config.backend = .local
                    aiService.config.localModel = model
                    Task {
                        do {
                            try await localModelManager.downloadModel(model)
                            await MainActor.run {
                                isStartingDownload = false
                            }
                        } catch {
                            await MainActor.run {
                                isStartingDownload = false
                            }
                        }
                    }
                } label: {
                    HStack {
                        if isStartingDownload {
                            ProgressView()
                        }
                        Text(buttonTitle)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    localModelManager.isDownloading.contains(model) ||
                    localModelManager.isDeleting.contains(model) ||
                    isStartingDownload
                )
                .tint(isSelected ? .green : .accentColor)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .alert("删除 \(model.displayName)？", isPresented: $showingDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除模型", role: .destructive) {
                Task {
                    try? await localModelManager.deleteModel(model)
                }
            }
        } message: {
            Text("删除后会释放本地存储空间；如果之后还要使用，需要重新下载。")
        }
    }

    private var buttonTitle: String {
        if localModelManager.isDownloaded(model) {
            return isSelected ? "当前已选" : "使用此模型"
        }
        return "下载并使用"
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

        var localizedName: String {
            switch self {
            case .currentBrand: return String(localized: "当前品牌")
            case .allBrands: return String(localized: "所有品牌")
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("导出范围", selection: $exportType) {
                        ForEach(ExportType.allCases, id: \.self) { type in
                            Text(type.localizedName).tag(type)
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


#Preview {
    SettingsView()
        .environmentObject(InventoryManager())
}
