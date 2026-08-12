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
    @AppStorage(PatternSourceStore.keepSourceDefaultsKey) private var keepPatternSource = true
    @AppStorage("defaultColorSystem") private var defaultColorSystemRaw: String = "MARD"
    @State private var showingResetAlert = false
    @State private var showingResetUsageAlert = false
    @State private var defaultStock = "1000"

    var body: some View {
        NavigationStack {
            List {
                // AI 图像识别（点入二级页）
                Section {
                    NavigationLink {
                        RecognitionSettingsScreen()
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(Theme.ColorToken.Morandi.mauve.opacity(0.15))
                                    .frame(width: 34, height: 34)
                                Image(systemName: "sparkles")
                                    .font(.system(size: 17))
                                    .foregroundStyle(Theme.ColorToken.Morandi.mauve)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("AI 图像识别")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Theme.ColorToken.Text.primary)
                                Text(aiService.statusMessage)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if aiService.isConfigured {
                                Text("已配置")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.ColorToken.Status.success)
                            } else {
                                Text("未配置")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.ColorToken.Status.warning)
                            }
                        }
                    }
                } header: {
                    Text("AI 图像识别")
                } footer: {
                    Text("配置云端 API 或下载本地模型用于扫描识别")
                }

                // 拼图模式：是否留一份原图
                Section {
                    Toggle("上传图纸时默认保留原图", isOn: $keepPatternSource)
                } header: {
                    Text("拼图模式")
                } footer: {
                    Text("这里只是**默认值**：每次传图时那张图下面都有一个「留一份原图」的开关，可以一张一张定 —— 十张图纸里往往只有几张会真的去拼。\n原图只用在拼图模式里，用来看清每一格的颜色。列表和详情页仍然用压缩后的图；原图存在本机，不占 iCloud、不进备份。拼完之后可以在「多零件模式」的零件清单页点「拼好了」把它删掉。")
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
                        .foregroundColor(Theme.ColorToken.Status.warning)
                    }
                    .disabled(inventoryManager.currentBrandId == nil)

                    Button {
                        showingResetUsageAlert = true
                    } label: {
                        HStack {
                            Image(systemName: "xmark.circle")
                            Text("清除使用记录")
                        }
                        .foregroundColor(Theme.ColorToken.Status.error)
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

// MARK: - AI 图像识别 二级页（新设计）
//
// 骨架：SecondaryNav → ScrollView → BISegmented (cloud/local)
//   → 状态卡 hero（success=sage 立边 / 失败=rose 立边）
//   → cloud: AI 提供商 radio list + API Key/模型 配置卡 + 自定义 URL 卡
//   → local: 设备能力提示 + 本地模型卡片列表
//   → 教程链接 GroupCard
//
// flavor = Morandi.mauve（AI 识别入口图标色）
struct RecognitionSettingsScreen: View {
    @ObservedObject private var aiService = AIServiceManager.shared
    @ObservedObject private var localModelManager = LocalModelManager.shared
    @State private var showingAPIHelpSheet = false
    @State private var isAPIKeyVisible = false
    @State private var isTesting = false
    @State private var testResult: TestConnectionResult?

    private var deviceProfile: LocalModelDeviceProfile { .current }

    var body: some View {
        VStack(spacing: 0) {
            BISecondaryNav(title: "AI 图像识别") {
                BINavIconButton(systemImage: "book") {
                    showingAPIHelpSheet = true
                }
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    // 后端切换 segmented
                    backendSegmented
                        .padding(.horizontal, 18)
                        .padding(.top, 6)
                        .padding(.bottom, 14)

                    // 状态卡 hero
                    statusHeroCard
                        .padding(.horizontal, 18)
                        .padding(.bottom, 4)

                    if aiService.config.backend == .cloud {
                        cloudSections
                    } else {
                        localSections
                    }

                    // 教程链接
                    BIGroupHeader(title: "帮助")
                    BIGroupCard {
                        BIListRow(
                            icon: "book.closed.fill",
                            iconColor: Theme.ColorToken.Morandi.mauve,
                            title: "如何申请 API Key",
                            subtitle: "查看各家平台的注册和获取流程",
                            isLast: false,
                            action: { showingAPIHelpSheet = true }
                        )
                        BIListRow(
                            icon: "questionmark.circle.fill",
                            iconColor: Theme.ColorToken.Morandi.mauve,
                            title: "识别效果不佳怎么办",
                            subtitle: "图片预处理与提示词建议",
                            isLast: true,
                            action: { showingAPIHelpSheet = true }
                        )
                    }

                    Color.clear.frame(height: 24)
                }
            }
            .background(Theme.ColorToken.Surface.background)
        }
        .background(Theme.ColorToken.Surface.background)
        .navigationBarHidden(true)
        .environment(\.tabFlavor, .workshop) // mauve
        .sheet(isPresented: $showingAPIHelpSheet) {
            HelpCenterNavigationView(initialDestination: .scanAPISetup)
        }
        .onAppear {
            localModelManager.refreshDownloadedModels()
        }
    }

    // MARK: cloud / local segmented
    private var backendSegmented: some View {
        BISegmented(
            selection: $aiService.config.backend,
            segments: [
                (.cloud, String(localized: "云端")),
                (.local, String(localized: "本地模型"))
            ],
            fillWidth: true
        )
    }

    // MARK: 状态卡
    private var statusHeroCard: some View {
        let success = aiService.isConfigured
        let accent: Color = success ? Theme.ColorToken.Status.success : Theme.ColorToken.Morandi.rose
        let iconName = success ? "checkmark" : "exclamationmark"

        return HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(accent.opacity(0.18))
                    .frame(width: 36, height: 36)
                Image(systemName: iconName)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(aiService.statusMessage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.Text.primary)
                    .lineLimit(2)
                Text(aiService.setupBannerText)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 4)
        }
        .padding(14)
        .background(
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.ColorToken.Surface.elevated)
                Rectangle()
                    .fill(accent)
                    .frame(width: 3)
                    .clipShape(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
        )
    }

    // MARK: cloud
    @ViewBuilder
    private var cloudSections: some View {
        // AI 提供商
        BIGroupHeader(title: "AI 提供商")
        BIGroupCard {
            let providers = AIProvider.allCases
            ForEach(Array(providers.enumerated()), id: \.element) { idx, provider in
                ProviderRadioRow(
                    provider: provider,
                    isSelected: aiService.config.provider == provider,
                    isLast: idx == providers.count - 1,
                    onSelect: {
                        aiService.config.provider = provider
                        aiService.config.model = AIConfig.defaultModel(for: provider)
                    }
                )
            }
        }

        // API 配置
        BIGroupHeader(title: "API 配置", hint: aiService.config.provider.rawValue)
        BIGroupCard(footer: cloudProviderFooterText(for: aiService.config.provider)) {
            // API Key 输入（包在 surface-subtle 圆角 10）
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("API Key")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                    Spacer()
                    Button {
                        isAPIKeyVisible.toggle()
                    } label: {
                        Image(systemName: isAPIKeyVisible ? "eye.slash" : "eye")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.ColorToken.Text.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                Group {
                    if isAPIKeyVisible {
                        TextField("sk-...", text: $aiService.config.apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        SecureField("sk-...", text: $aiService.config.apiKey)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                .font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.ColorToken.Surface.subtle)
                )

                if aiService.config.hasKeyFormatWarning {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.ColorToken.Status.warning)
                        Text("\(aiService.config.provider.rawValue) 的 API Key 通常以 \"sk-\" 开头，请确认。")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.ColorToken.Status.warning)
                    }
                }
            }
            .padding(14)
            divider

            // 模型选择
            HStack(spacing: 12) {
                Text("模型")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.ColorToken.Text.primary)
                Spacer()
                Picker("", selection: $aiService.config.model) {
                    ForEach(models(for: aiService.config.provider), id: \.self) { m in
                        Text(m).tag(m)
                    }
                }
                .labelsHidden()
                .tint(Theme.ColorToken.Morandi.mauve)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            divider

            // 自定义 API 地址
            HStack(spacing: 12) {
                Text("自定义 API 地址")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.ColorToken.Text.primary)
                Spacer()
                Toggle("", isOn: $aiService.config.enableCustomURL)
                    .labelsHidden()
                    .tint(Theme.ColorToken.Morandi.sage)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            if aiService.config.enableCustomURL {
                divider
                VStack(alignment: .leading, spacing: 6) {
                    Text("API 地址")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                    TextField("https://...", text: $aiService.config.baseURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .font(.system(size: 13, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Theme.ColorToken.Surface.subtle)
                        )
                }
                .padding(14)
            }
        }

        // 测试连接 / 主操作 CTA
        VStack(spacing: 8) {
            BIPrimaryButton("测试连接", systemImage: "bolt.fill") {
                Task {
                    isTesting = true
                    defer { isTesting = false }
                    testResult = nil
                    let result = await aiService.testConnection()
                    testResult = result
                }
            }
            .disabled(aiService.config.apiKey.isEmpty || isTesting)
            .overlay(alignment: .center) {
                if isTesting {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                }
            }

            if let testResult, !isTesting {
                testResultLabel(for: testResult)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }

    @ViewBuilder
    private func testResultLabel(for result: TestConnectionResult) -> some View {
        switch result {
        case .success(let latencyMs):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                Text("连接成功 · \(latencyMs) ms")
                    .font(.system(size: 12))
            }
            .foregroundStyle(Theme.ColorToken.Morandi.sage)
        case .failure(let reason):
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                Text("失败：\(reason)")
                    .font(.system(size: 12))
                    .multilineTextAlignment(.leading)
            }
            .foregroundStyle(Theme.ColorToken.Morandi.rose)
        }
    }

    // MARK: local
    @ViewBuilder
    private var localSections: some View {
        // 设备能力卡
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 18))
                .foregroundStyle(Theme.ColorToken.Morandi.mauve)
            VStack(alignment: .leading, spacing: 4) {
                Text("设备能力")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.Text.primary)
                Text(deviceProfile.summaryText)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                    .lineLimit(4)
            }
            Spacer(minLength: 4)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.ColorToken.Morandi.mauve.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.ColorToken.Morandi.mauve.opacity(0.30), lineWidth: 1)
        )
        .padding(.horizontal, 18)
        .padding(.top, 14)

        let models = LocalRecognitionModel.allCases
        let downloadedCount = models.filter { localModelManager.isDownloaded($0) }.count
        BIGroupHeader(title: "可用模型", hint: "\(downloadedCount) / \(models.count) 已下载")

        VStack(spacing: 10) {
            ForEach(models) { model in
                LocalModelOptionCard(
                    model: model,
                    isSelected: aiService.config.localModel == model,
                    aiService: aiService,
                    localModelManager: localModelManager,
                    recommendationText: deviceProfile.recommendation(for: model)
                )
            }
        }
        .padding(.horizontal, 18)
    }

    // MARK: helpers
    private var divider: some View {
        Rectangle()
            .fill(Theme.ColorToken.Border.divider)
            .frame(height: 1)
            .padding(.leading, 14)
    }

    private func models(for provider: AIProvider) -> [String] {
        switch provider {
        case .kimi:      return AIConfig.kimiModels
        case .openai:    return AIConfig.openAIModels
        case .anthropic: return AIConfig.anthropicModels
        case .qwen:      return AIConfig.qwenModels
        case .gemini:    return AIConfig.geminiModels
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

// MARK: - AI 提供商 radio row
private struct ProviderRadioRow: View {
    let provider: AIProvider
    let isSelected: Bool
    let isLast: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // radio
                ZStack {
                    Circle()
                        .stroke(
                            isSelected ? Color.clear : Theme.ColorToken.Border.default,
                            lineWidth: 2
                        )
                        .background(
                            Circle().fill(isSelected ? Theme.ColorToken.Fill.mauve : Color.clear)
                        )
                        .frame(width: 22, height: 22)
                    if isSelected {
                        Circle()
                            .fill(.white)
                            .frame(width: 8, height: 8)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(provider.rawValue)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.ColorToken.Text.primary)
                        if isRecommended {
                            BIBadge("推荐", style: .success)
                        }
                    }
                    Text(subtitleText)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(
                isSelected ? Theme.ColorToken.Morandi.mauve.opacity(0.08) : Color.clear
            )
            .overlay(alignment: .bottom) {
                if !isLast {
                    Rectangle()
                        .fill(Theme.ColorToken.Border.divider)
                        .frame(height: 1)
                        .padding(.leading, 48)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var isRecommended: Bool { provider == .kimi }

    private var subtitleText: String {
        switch provider {
        case .kimi:      return String(localized: "国内可直连 · 内置 Key 可用")
        case .openai:    return String(localized: "GPT 系列 · 需要 API Key")
        case .anthropic: return String(localized: "Claude 系列 · 需要 API Key")
        case .qwen:      return String(localized: "阿里云通义千问 · 需要 API Key")
        case .gemini:    return String(localized: "Google Gemini · 需要 API Key")
        }
    }
}

/// 本地模型卡片（新设计）：
/// 左侧 mauve 立边表示当前选中；圆形 radio + 模型名 + 推荐徽章
/// 描述 / 体积 / 已下载徽章；下载进度条；底部下载/选择/删除按钮
struct LocalModelOptionCard: View {
    let model: LocalRecognitionModel
    let isSelected: Bool
    @ObservedObject var aiService: AIServiceManager
    @ObservedObject var localModelManager: LocalModelManager
    let recommendationText: String

    @State private var isStartingDownload = false
    @State private var showingDeleteConfirmation = false

    private var isDownloaded: Bool { localModelManager.isDownloaded(model) }
    private var isDownloading: Bool { localModelManager.isDownloading.contains(model) }
    private var isDeleting: Bool { localModelManager.isDeleting.contains(model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                // radio
                Button {
                    if isDownloaded {
                        aiService.config.backend = .local
                        aiService.config.localModel = model
                    }
                } label: {
                    ZStack {
                        Circle()
                            .stroke(
                                isSelected ? Color.clear : Theme.ColorToken.Border.default,
                                lineWidth: 2
                            )
                            .background(
                                Circle().fill(isSelected ? Theme.ColorToken.Fill.mauve : Color.clear)
                            )
                            .frame(width: 18, height: 18)
                        if isSelected {
                            Circle()
                                .fill(.white)
                                .frame(width: 7, height: 7)
                        }
                    }
                    .padding(.top, 3)
                }
                .buttonStyle(.plain)
                .disabled(!isDownloaded)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.ColorToken.Text.primary)
                        if model == .qwen35_08b {
                            BIBadge("推荐", style: .accent)
                        }
                    }

                    Text(model.cautionText)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                        .lineLimit(3)

                    HStack(spacing: 6) {
                        Text(model.approximateDownloadSize)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.ColorToken.Text.tertiary)
                        if isDownloaded {
                            BIBadge("已下载", style: .success)
                        }
                    }
                }

                Spacer(minLength: 4)
            }

            Text(recommendationText)
                .font(.system(size: 11))
                .foregroundStyle(Theme.ColorToken.Text.secondary)
                .padding(.leading, 30)

            if isDownloading {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: localModelManager.progress(for: model))
                        .tint(Theme.ColorToken.Morandi.mauve)
                    Text("下载中 \(Int(localModelManager.progress(for: model) * 100))%")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                }
                .padding(.leading, 30)
            }

            if let errorMessage = localModelManager.errorMessage(for: model) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ColorToken.Status.error)
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ColorToken.Status.error)
                }
                .padding(.leading, 30)
            }

            // 底部操作
            HStack(spacing: 10) {
                if isDownloaded {
                    Button {
                        aiService.config.backend = .local
                        aiService.config.localModel = model
                    } label: {
                        Text(isSelected ? "当前已选" : "使用此模型")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .foregroundStyle(isSelected ? Theme.ColorToken.Text.tertiary : .white)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(isSelected ? Theme.ColorToken.Surface.subtle : Theme.ColorToken.Fill.mauve)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isSelected || isDeleting)

                    Button {
                        showingDeleteConfirmation = true
                    } label: {
                        HStack(spacing: 6) {
                            if isDeleting {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(isDeleting ? "删除中" : "删除")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .foregroundStyle(Theme.ColorToken.Status.error)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Theme.ColorToken.Status.error.opacity(0.10))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isDownloading || isDeleting || localModelManager.isLoadingModel)
                } else {
                    Button {
                        isStartingDownload = true
                        aiService.config.backend = .local
                        aiService.config.localModel = model
                        Task {
                            defer {
                                Task { @MainActor in isStartingDownload = false }
                            }
                            try? await localModelManager.downloadModel(model)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if isStartingDownload || isDownloading {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            } else {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 13))
                            }
                            Text(isDownloading ? "下载中" : "下载并使用")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .foregroundStyle(.white)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Theme.ColorToken.Fill.mauve)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isDownloading || isDeleting || isStartingDownload)
                }
            }
        }
        .padding(14)
        .background(
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.ColorToken.Surface.elevated)
                if isSelected {
                    Rectangle()
                        .fill(Theme.ColorToken.Morandi.mauve)
                        .frame(width: 3)
                        .clipShape(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                }
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isSelected ? Theme.ColorToken.Morandi.mauve : Theme.ColorToken.Border.default,
                    lineWidth: 1
                )
        )
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
                                .foregroundColor(Theme.ColorToken.Status.warning)
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
