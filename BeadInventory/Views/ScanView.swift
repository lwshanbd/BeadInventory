//
//  ScanView.swift
//  BeadInventory
//
//  图纸扫描和AI识别界面
//

import SwiftUI
import PhotosUI
import UIKit
import TipKit

struct ScanView: View {
    enum Layout {
        static let imageSelectionHeight: CGFloat = 250
        static let pinnedImageHeight: CGFloat = 250
        static let expandedPinnedImageHeight: CGFloat = 320
    }

    @EnvironmentObject var inventoryManager: InventoryManager
    @ObservedObject private var aiService = AIServiceManager.shared
    @ObservedObject private var localModelManager = LocalModelManager.shared

    /// 从外部传入的图片（如 Share Extension）
    @Binding var externalImage: UIImage?

    @State private var selectedImage: UIImage?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var showingManualEntry = false
    @State private var showingCropView = false
    @State private var projectName = ""
    @State private var isLoadingImage = false
    @State private var isRecognizing = false
    @State private var recognizedItems: [RecognizedItem] = []
    @State private var errorMessage: String?
    @State private var showingCreatePlan = false

    @State private var deductionResolver: DeductionResolver?
    @State private var showingDeductionFailure = false
    @State private var deductionFailureMessage = ""

    private let similarityService = ColorSimilarityService()

    // 缩略图相关
    @State private var originalImage: UIImage?       // 原始图片（裁剪前）
    @State private var thumbnailImage: UIImage?      // 缩略图（可裁切）
    @State private var showingThumbnailCrop = false  // 显示缩略图裁切视图

    // 图片固定功能
    @State private var isImagePinned = false         // 是否固定图片在顶部

    // 色号体系选择（独立于品牌）
    @AppStorage("defaultColorSystem") private var defaultColorSystemRaw: String = "MARD"
    @State private var scanColorSystem: ColorSystem = .mard

    // 引导弹窗
    @AppStorage("scanViewHelpShown") private var helpHasBeenDismissed = false
    @State private var showingHelpSheet = false
    init(externalImage: Binding<UIImage?> = .constant(nil)) {
        self._externalImage = externalImage
    }

    // 识别结果项
    struct RecognizedItem: Identifiable {
        let id = UUID()
        var colorCode: String
        var quantity: Int
    }

    var totalBeads: Int {
        recognizedItems.reduce(0) { $0 + $1.quantity }
    }

    /// 当前品牌的色系是否与扫描色系匹配
    var brandMatchesScanSystem: Bool {
        guard let brand = inventoryManager.currentBrand else { return false }
        return brand.colorSystem == scanColorSystem
    }

    /// 三段进度指示器的当前 step：0 识别，1 调整，2 确认
    /// 0：尚未识别（无识别结果）
    /// 1：已识别、正在调整（有识别结果但还没进入扣减审核）
    /// 2：进入扣减审核（已 push DeductionReviewView）
    private var stepperIndex: Int {
        if recognizedItems.isEmpty { return 0 }
        if deductionResolver != nil { return 2 }
        return 1
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 固定在顶部的图片（当 isImagePinned 为 true 时）
                if isImagePinned, let image = selectedImage {
                    PinnedImageView(
                        image: image,
                        isPinned: $isImagePinned,
                        showingCropView: $showingCropView,
                        onReselect: {
                            selectedImage = nil
                            selectedPhotoItem = nil
                            isImagePinned = false
                        }
                    )
                }

                // 三段进度指示器：识别 → 调整 → 确认
                BIStepper(steps: ["识别", "调整", "确认"], currentIndex: stepperIndex)
                    .padding(.vertical, Theme.Spacing.sm)

                GeometryReader { geometry in
                    ScrollView {
                        VStack(spacing: 20) {
                            TipView(ScanTip())
                                .padding(.horizontal)
                            if !aiService.isConfigured {
                                TipView(APISetupTip())
                                    .padding(.horizontal)
                            }
                            // 图片选择区域（当未固定时显示）
                            if !isImagePinned {
                                ImageSelectionSection(
                                    selectedImage: $selectedImage,
                                    selectedPhotoItem: $selectedPhotoItem,
                                    showingCamera: $showingCamera,
                                    isLoadingImage: $isLoadingImage,
                                    showingCropView: $showingCropView,
                                    isPinned: $isImagePinned,
                                    hasRecognizedItems: !recognizedItems.isEmpty
                                )
                            }

                            // AI 配置状态提示
                            aiStatusBanner

                            // 色号体系选择（独立于品牌，影响 AI 提示词和计划绑定）
                            colorSystemPicker

                            // 识别按钮
                            if selectedImage != nil {
                                recognitionButtons
                            }

                            // 错误提示
                            errorBanner

                            // 备扣品牌显示（仅显示与当前色号体系匹配的品牌）
                            if !recognizedItems.isEmpty {
                                brandPickerRow
                            }

                            // 识别结果
                            if !recognizedItems.isEmpty {
                                RecognizedResultsSectionNew(
                                    items: $recognizedItems,
                                    totalBeads: totalBeads,
                                    inventoryManager: inventoryManager,
                                    colorSystem: scanColorSystem,
                                    onClear: clearState
                                )
                            }

                            // 手动添加/编辑按钮
                            manualEntryButton

                            // 项目名称 + 缩略图预览（按钮已移至底部 safeAreaInset / toolbar Menu）
                            if !recognizedItems.isEmpty {
                                projectInfoSection
                            }

                            Spacer(minLength: 50)
                        }
                        .frame(width: geometry.size.width)
                        .padding(.vertical)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("图纸扫描")
            .safeAreaInset(edge: .bottom) { bottomCTAInset }
            .toolbar { scanToolbarContent }
            .pipe { applySheets($0) }
            .pipe { applyAlerts($0) }
            .pipe { applyChangeHandlers($0) }
            .pipe { applyHelpAndOnAppear($0) }
        }
    }

    /// Helper to chain View transforms without exploding type-checker complexity.
    private func applySheets<V: View>(_ view: V) -> some View {
        view
            .sheet(isPresented: $showingCamera) {
                CameraPicker(image: $selectedImage)
            }
            .sheet(isPresented: $showingManualEntry) {
                ManualEntrySheetNew(recognizedItems: $recognizedItems, colorSystem: scanColorSystem)
                    .environmentObject(inventoryManager)
            }
            .fullScreenCover(isPresented: $showingCropView) {
                if let image = selectedImage {
                    ImageCropView(image: image) { croppedImage in
                        selectedImage = croppedImage
                    }
                } else {
                    Color.black.onAppear { showingCropView = false }
                }
            }
            .fullScreenCover(isPresented: $showingThumbnailCrop) {
                if let image = thumbnailImage ?? originalImage {
                    ImageCropView(image: image) { croppedImage in
                        thumbnailImage = croppedImage
                    }
                } else {
                    Color.black.onAppear { showingThumbnailCrop = false }
                }
            }
            .navigationDestination(item: $deductionResolver) { resolver in
                DeductionReviewView(
                    resolver: resolver,
                    colorSystem: scanColorSystem,
                    matchingBrands: inventoryManager.brands
                        .filter { $0.colorSystem == scanColorSystem }
                        .sorted { $0.sortOrder < $1.sortOrder },
                    inventoryManager: inventoryManager,
                    similarityService: similarityService,
                    onConfirm: {
                        applyToInventoryWithResolver(resolver)
                    }
                )
            }
    }

    private func applyAlerts<V: View>(_ view: V) -> some View {
        view
            .alert("部分颜色扣减失败", isPresented: $showingDeductionFailure) {
                Button("知道了") { }
            } message: {
                Text(deductionFailureMessage)
            }
            .alert("创建计划", isPresented: $showingCreatePlan) {
                Button("取消", role: .cancel) { }
                Button("确认") {
                    createPlannedProject()
                }
            } message: {
                Text("将创建包含 \(totalBeads) 颗豆子（\(recognizedItems.count) 种颜色）的计划项目。执行时需要选择品牌。")
            }
    }

    private func applyChangeHandlers<V: View>(_ view: V) -> some View {
        view
            .onChange(of: selectedPhotoItem) { _, newItem in
                handlePhotoItemChange(newItem)
            }
            .onChange(of: selectedImage) { _, newImage in
                // 当从相机获取图片时，也设置原图和缩略图
                if let image = newImage, originalImage == nil {
                    originalImage = image
                    thumbnailImage = image
                }
            }
            .onChange(of: externalImage) { _, newImage in
                handleExternalImageChange(newImage)
            }
    }

    private func applyHelpAndOnAppear<V: View>(_ view: V) -> some View {
        view
            .sheet(isPresented: $showingHelpSheet) {
                ScanHelpSheet(
                    onDismiss: {
                        showingHelpSheet = false
                    },
                    onNeverShowAgain: {
                        helpHasBeenDismissed = true
                        showingHelpSheet = false
                    }
                )
            }
            .onAppear {
                scanColorSystem = ColorSystem(rawValue: defaultColorSystemRaw) ?? .mard
                if !helpHasBeenDismissed {
                    showingHelpSheet = true
                }
            }
    }

    private func handlePhotoItemChange(_ newItem: PhotosPickerItem?) {
        guard let newItem = newItem else { return }
        isLoadingImage = true
        Task {
            if let data = try? await newItem.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                await MainActor.run {
                    selectedImage = image
                    originalImage = image
                    thumbnailImage = image
                    isLoadingImage = false
                }
            } else {
                await MainActor.run {
                    isLoadingImage = false
                }
            }
        }
    }

    private func handleExternalImageChange(_ newImage: UIImage?) {
        if let image = newImage {
            clearState()
            selectedImage = image
            originalImage = image
            thumbnailImage = image
            externalImage = nil
        }
    }

    // MARK: - 主 body 的子片段（拆分以减轻类型检查复杂度）

    @ViewBuilder
    private var aiStatusBanner: some View {
        if !aiService.isConfigured {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(Theme.ColorToken.Status.warning)
                VStack(alignment: .leading, spacing: 4) {
                    Text(aiService.statusMessage)
                        .font(.caption)
                    Text(aiService.setupBannerText)
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    if aiService.config.backend == .local,
                       localModelManager.isDownloading.contains(aiService.config.localModel) {
                        ProgressView(value: localModelManager.progress(for: aiService.config.localModel))
                            .progressViewStyle(.linear)
                    }
                }
                .font(.caption)
                Spacer()
                NavigationLink(aiService.setupActionTitle) {
                    RecognitionSettingsScreen()
                }
                .font(.caption)
            }
            .padding()
            .background(Theme.ColorToken.Status.warning.opacity(0.1))
            .cornerRadius(Theme.Radius.sm)
            .padding(.horizontal)
        } else if aiService.config.backend == .local {
            HStack(alignment: .top) {
                Image(systemName: "iphone.gen3")
                    .foregroundColor(Theme.ColorToken.Status.info)
                Text("当前使用 \(aiService.config.localModel.displayName) 本地识别。无需 API，但速度相对更慢，也可能引起发热。")
                    .font(.caption)
                Spacer()
            }
            .padding()
            .background(Theme.ColorToken.Status.info.opacity(0.08))
            .cornerRadius(Theme.Radius.sm)
            .padding(.horizontal)
        }
    }

    private var colorSystemPicker: some View {
        HStack {
            Text("色号体系:")
                .foregroundColor(.secondary)
                .font(.subheadline)
            Picker("色号体系", selection: $scanColorSystem) {
                Text("MARD").tag(ColorSystem.mard)
                Text("卡卡").tag(ColorSystem.kaka)
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal)
    }

    private var recognitionButtons: some View {
        HStack(spacing: 12) {
            // 表格识别按钮
            Button {
                recognizeImage(mode: .table)
            } label: {
                HStack {
                    if isRecognizing {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "tablecells")
                    }
                    Text(isRecognizing ? "识别中..." : "表格识别")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(aiService.isConfigured ? Color.accentColor : Theme.ColorToken.Border.default)
                .foregroundColor(.white)
                .cornerRadius(Theme.Radius.md)
            }
            .disabled(isRecognizing || !aiService.isConfigured)

            // 色号统计识别按钮
            Button {
                recognizeImage(mode: .blueprint)
            } label: {
                HStack {
                    if isRecognizing {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "doc.richtext")
                    }
                    Text(isRecognizing ? "识别中..." : "色号统计识别")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(aiService.isConfigured ? Color.orange : Theme.ColorToken.Border.default)
                .foregroundColor(.white)
                .cornerRadius(Theme.Radius.md)
            }
            .disabled(isRecognizing || !aiService.isConfigured)
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let error = errorMessage {
            Text(error)
                .font(.caption)
                .foregroundColor(Theme.ColorToken.Status.error)
                .padding()
                .background(Theme.ColorToken.Status.error.opacity(0.1))
                .cornerRadius(Theme.Radius.sm)
                .padding(.horizontal)
        }
    }

    private var brandPickerRow: some View {
        HStack {
            Text("备扣品牌:")
                .foregroundColor(.secondary)
            if inventoryManager.currentBrandId != nil,
               let brand = inventoryManager.currentBrand,
               brand.colorSystem == scanColorSystem {
                Text(brand.name)
                    .fontWeight(.medium)
                    .foregroundColor(.accentColor)
            } else {
                Text("请选择")
                    .foregroundColor(Theme.ColorToken.Status.warning)
            }
            Spacer()
            BrandPicker(colorSystemFilter: scanColorSystem)
        }
        .font(.subheadline)
        .padding(.horizontal)
    }

    private var manualEntryButton: some View {
        Button {
            showingManualEntry = true
        } label: {
            HStack {
                Image(systemName: recognizedItems.isEmpty ? "plus.circle" : "pencil.circle")
                Text(recognizedItems.isEmpty ? "手动添加" : "编辑颜色")
            }
            .font(.subheadline)
            .foregroundColor(.accentColor)
        }
        .padding(.top, 8)
    }

    private var projectInfoSection: some View {
        VStack(spacing: 16) {
            // 项目名称输入
            TextField("项目名称（可选）", text: $projectName)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            // 缩略图预览和裁切
            ThumbnailPreviewSection(
                thumbnailImage: $thumbnailImage,
                originalImage: originalImage,
                showingThumbnailCrop: $showingThumbnailCrop
            )
            .padding(.horizontal)

            // 提示信息
            if !brandMatchesScanSystem {
                HStack {
                    Image(systemName: inventoryManager.currentBrandId == nil ? "info.circle" : "exclamationmark.triangle")
                        .foregroundColor(inventoryManager.currentBrandId == nil ? .blue : .orange)
                    Text(inventoryManager.currentBrandId == nil
                         ? "创建计划无需选择品牌，执行时再选择"
                         : "当前品牌色系与扫描色系不匹配，请切换品牌")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: - 底部 sticky 单主 CTA

    @ViewBuilder
    private var bottomCTAInset: some View {
        if !recognizedItems.isEmpty {
            BIPrimaryButton("扣减库存", systemImage: "minus.circle.fill") {
                prepareDeduction()
            }
            .disabled(!brandMatchesScanSystem)
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.bottom, Theme.Spacing.sm)
            .background(.bar)
        }
    }

    // MARK: - 顶部 toolbar Menu（次级操作溢出）

    @ToolbarContentBuilder
    private var scanToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    showingCreatePlan = true
                } label: {
                    Label("仅创建计划，不扣减", systemImage: "calendar.badge.plus")
                }
                .disabled(recognizedItems.isEmpty)

                Divider()

                Button {
                    // 重新选择图片：清除当前图片但保留识别结果
                    selectedImage = nil
                    selectedPhotoItem = nil
                    isImagePinned = false
                } label: {
                    Label("重新选择图片", systemImage: "arrow.counterclockwise")
                }
                .disabled(selectedImage == nil)

                Button(role: .destructive) {
                    clearState()
                } label: {
                    Label("清空当前识别", systemImage: "trash")
                }
                .disabled(recognizedItems.isEmpty && selectedImage == nil)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    func recognizeImage(mode: RecognitionMode) {
        guard let image = selectedImage else { return }

        isRecognizing = true
        errorMessage = nil

        let colorSystem = scanColorSystem

        Task {
            do {
                let items = try await aiService.recognizeImage(image, mode: mode, colorSystem: colorSystem)
                await MainActor.run {
                    recognizedItems = items.map { item in
                        // 非 MARD 体系时，AI 返回的是该品牌的色号（如卡卡的 B3），需转为内部 mardCode
                        if colorSystem != .mard {
                            if let color = inventoryManager.findColor(byCode: item.colorCode, preferSystem: colorSystem) {
                                return RecognizedItem(colorCode: color.mardCode, quantity: item.quantity)
                            }
                            // 兜底：LLM 可能给出带前导零的格式（如 "B02"），而数据里实际存的是 "B2"。
                            // 去掉字母前缀后的前导零再查一次。
                            let normalized = Self.stripLeadingZerosFromBrandCode(item.colorCode)
                            if normalized != item.colorCode,
                               let color = inventoryManager.findColor(byCode: normalized, preferSystem: colorSystem) {
                                return RecognizedItem(colorCode: color.mardCode, quantity: item.quantity)
                            }
                        }
                        return RecognizedItem(colorCode: item.colorCode, quantity: item.quantity)
                    }
                    isRecognizing = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isRecognizing = false
                }
            }
        }
    }

    func prepareDeduction() {
        guard let brandId = inventoryManager.currentBrandId,
              brandMatchesScanSystem else { return }

        let resolver = DeductionResolver(inventoryManager: inventoryManager)
        resolver.initializeFromRecognizedItems(
            recognizedItems.map { (colorCode: $0.colorCode, quantity: $0.quantity) },
            primaryBrandId: brandId,
            colorSystem: scanColorSystem
        )
        self.deductionResolver = resolver
    }

    func applyToInventoryWithResolver(_ resolver: DeductionResolver) {
        // 先执行扣减（不保存），确认结果后再创建项目记录
        let failedItems = resolver.executeDeductions(shouldSave: false)

        let thumbnailData = generateThumbnailData()
        // 标记失败项为未扣减
        let beadUsages = resolver.items.map { item in
            BeadUsage(
                colorCode: item.mardCode,
                brandId: item.brandId,
                quantity: item.quantity,
                isDeducted: !failedItems.contains(where: { $0.id == item.id })
            )
        }
        let project = ProjectRecord(
            name: projectName.isEmpty ? "图纸\(Date().formatted(date: .numeric, time: .omitted))" : projectName,
            beadUsage: beadUsages,
            brandId: resolver.primaryBrandId,
            thumbnail: thumbnailData,
            colorSystem: scanColorSystem
        )
        inventoryManager.addProject(project) // addProject 内部已调用 saveData()

        clearState()

        if failedItems.isEmpty {
            deductionResolver = nil
        } else {
            // 先关闭 sheet，等动画结束后再弹出失败提示，避免 SwiftUI 同时 dismiss sheet + present alert 的竞争
            deductionResolver = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                showDeductionFailureIfNeeded(failedCodes: failedItems.map(\.colorCode))
            }
        }
    }

    /// 当有扣减失败的颜色时，构造并显示失败提示
    private func showDeductionFailureIfNeeded(failedCodes: [String]) {
        guard !failedCodes.isEmpty else { return }
        deductionFailureMessage = "以下 \(failedCodes.count) 种颜色扣减失败：\n\(failedCodes.joined(separator: "、"))"
        showingDeductionFailure = true
    }

    /// 去掉"字母前缀 + 前导零 + 数字"形式中的前导零（如 "B02" → "B2"、"P05" → "P5"）。
    /// 仅在严格匹配此形态时生效；纯数字、含特殊字符或 "B0" 这种归零后没有数字的情况保持原样。
    private static func stripLeadingZerosFromBrandCode(_ code: String) -> String {
        let trimmed = code.uppercased().trimmingCharacters(in: .whitespaces)
        guard let regex = try? NSRegularExpression(pattern: "^([A-Z]+)0+([1-9][0-9]*)$") else {
            return trimmed
        }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return regex.stringByReplacingMatches(in: trimmed, options: [], range: range, withTemplate: "$1$2")
    }

    func createPlannedProject() {
        // 生成压缩的缩略图数据
        let thumbnailData = generateThumbnailData()

        // 创建计划项目（不扣减库存）
        let beadUsages = recognizedItems.map { item in
            BeadUsage(colorCode: item.colorCode, brandId: nil, quantity: item.quantity, isDeducted: false)
        }
        let project = ProjectRecord(
            name: projectName.isEmpty ? "计划\(Date().formatted(date: .numeric, time: .omitted))" : projectName,
            beadUsage: beadUsages,
            brandId: nil,
            isPlanned: true,
            thumbnail: thumbnailData,
            colorSystem: scanColorSystem
        )
        inventoryManager.addPlannedProject(project)

        // 清除结果
        clearState()
    }

    /// 生成原分辨率缩略图数据（PNG 无损）。
    /// 拼图模式依赖原图做网格识别，所以这里不再压缩。
    func generateThumbnailData() -> Data? {
        return thumbnailImage?.pngData()
    }

    /// 清除所有状态
    func clearState() {
        recognizedItems = []
        selectedImage = nil
        selectedPhotoItem = nil
        projectName = ""
        originalImage = nil
        thumbnailImage = nil
        isImagePinned = false
    }

}

// MARK: - View 扩展：用 .pipe 把 modifier 链拆段（绕开 Swift 类型检查复杂度）

private extension View {
    func pipe<V: View>(_ transform: (Self) -> V) -> V {
        transform(self)
    }
}

// MARK: - 固定在顶部的图片视图
struct PinnedImageView: View {
    let image: UIImage
    @Binding var isPinned: Bool
    @Binding var showingCropView: Bool
    let onReselect: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            // 图片区域
            ScanPreviewImageView(
                image: image,
                maxHeight: isExpanded ? ScanView.Layout.expandedPinnedImageHeight : ScanView.Layout.pinnedImageHeight,
                cornerRadius: 8,
                shadowRadius: 2
            )
                .padding(.horizontal)
                .padding(.top, 8)
                .onTapGesture {
                    withAnimation {
                        isExpanded.toggle()
                    }
                }

            // 操作按钮
            HStack(spacing: 16) {
                Button {
                    withAnimation {
                        isExpanded.toggle()
                    }
                } label: {
                    Label(isExpanded ? "收起" : "展开", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }

                Button {
                    showingCropView = true
                } label: {
                    Label("裁切", systemImage: "crop")
                        .font(.caption)
                }

                Button {
                    withAnimation {
                        isPinned = false
                    }
                } label: {
                    Label("取消固定", systemImage: "pin.slash")
                        .font(.caption)
                }

                Button {
                    onReselect()
                } label: {
                    Text("重新选择")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 8)

            Divider()
        }
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
    }
}

// MARK: - 图片选择区域
struct ImageSelectionSection: View {
    @Binding var selectedImage: UIImage?
    @Binding var selectedPhotoItem: PhotosPickerItem?
    @Binding var showingCamera: Bool
    @Binding var isLoadingImage: Bool
    @Binding var showingCropView: Bool
    @Binding var isPinned: Bool
    var hasRecognizedItems: Bool

    var body: some View {
        VStack(spacing: 16) {
            if isLoadingImage {
                // 加载中
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("加载图片中...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .background(Color(.systemBackground))
                .cornerRadius(Theme.Radius.lg)
            } else if let image = selectedImage {
                ScanPreviewImageView(
                    image: image,
                    maxHeight: ScanView.Layout.imageSelectionHeight,
                    cornerRadius: 12,
                    shadowRadius: 4
                )

                HStack(spacing: 16) {
                    Button {
                        showingCropView = true
                    } label: {
                        Label("裁切", systemImage: "crop")
                            .font(.caption)
                    }

                    // 固定图片按钮（仅在有识别结果时显示）
                    if hasRecognizedItems {
                        Button {
                            withAnimation {
                                isPinned = true
                            }
                        } label: {
                            Label("固定", systemImage: "pin")
                                .font(.caption)
                        }
                    }

                    Button("重新选择") {
                        selectedImage = nil
                        selectedPhotoItem = nil
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            } else {
                // 占位区域
                VStack(spacing: 16) {
                    Image(systemName: "doc.text.image")
                        .font(.system(size: 50))
                        .foregroundColor(.secondary)

                    Text("选择或拍摄色号表格图片")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    HStack(spacing: 20) {
                        // 使用 SwiftUI 原生 PhotosPicker
                        PhotosPicker(selection: $selectedPhotoItem,
                                     matching: .images,
                                     photoLibrary: .shared()) {
                            Label("相册", systemImage: "photo.on.rectangle")
                                .font(.subheadline)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                                .background(Color.accentColor)
                                .foregroundColor(.white)
                                .cornerRadius(Theme.Radius.md)
                        }

                        Button {
                            showingCamera = true
                        } label: {
                            Label("拍照", systemImage: "camera")
                                .font(.subheadline)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                                .background(Theme.ColorToken.Status.warning)
                                .foregroundColor(.white)
                                .cornerRadius(Theme.Radius.md)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .background(Color(.systemBackground))
                .cornerRadius(Theme.Radius.lg)
            }
        }
        .padding(.horizontal)
    }
}

struct ScanPreviewImageView: View {
    let image: UIImage
    let maxHeight: CGFloat
    var cornerRadius: CGFloat = 12
    var shadowRadius: CGFloat = 0

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: maxHeight)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .shadow(radius: shadowRadius)
    }
}

// MARK: - 相机拍照
struct CameraPicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.image = image
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

// MARK: - 新版识别结果区域（不依赖 OCRManager）
struct RecognizedResultsSectionNew: View {
    @Binding var items: [ScanView.RecognizedItem]
    let totalBeads: Int
    let inventoryManager: InventoryManager
    var colorSystem: ColorSystem = .mard
    var onClear: (() -> Void)? = nil

    @State private var showingClearAlert = false
    @State private var sortOption: ResultSortOption = .original
    @State private var sortAscending: Bool = true

    enum ResultSortOption: String, CaseIterable {
        case original = "默认"
        case code = "色号"
        case quantity = "数量"
        case stock = "库存"

        var localizedName: String {
            switch self {
            case .original: return String(localized: "默认")
            case .code: return String(localized: "色号")
            case .quantity: return String(localized: "数量")
            case .stock: return String(localized: "库存")
            }
        }
    }

    // 排序后的结果
    var sortedItems: [ScanView.RecognizedItem] {
        guard sortOption != .original else { return items }

        let sorted: [ScanView.RecognizedItem]
        switch sortOption {
        case .original:
            return items
        case .code:
            sorted = items.sorted {
                // 严格按 mardCode 查，避免未匹配的原始色号跨品牌乱碰
                let code0 = inventoryManager.findColor(byMardCode: $0.colorCode)?.displayCode(for: colorSystem) ?? $0.colorCode
                let code1 = inventoryManager.findColor(byMardCode: $1.colorCode)?.displayCode(for: colorSystem) ?? $1.colorCode
                return code0.localizedStandardCompare(code1) == .orderedAscending
            }
        case .quantity:
            sorted = items.sorted { $0.quantity < $1.quantity }
        case .stock:
            sorted = items.sorted {
                let stock0 = getAvailableStock(for: $0.colorCode)
                let stock1 = getAvailableStock(for: $1.colorCode)
                return stock0 < stock1
            }
        }
        return sortAscending ? sorted : sorted.reversed()
    }

    func getAvailableStock(for colorCode: String) -> Int {
        guard let brandId = inventoryManager.currentBrandId,
              let stock = inventoryManager.getStock(brandId: brandId, mardCode: colorCode) else {
            return 0
        }
        return stock.available
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题栏
            HStack {
                Text("识别结果")
                    .font(.headline)
                Spacer()
                Text("共 \(items.count) 色 / \(totalBeads) 颗")
                    .font(.caption)
                    .foregroundColor(.secondary)

                // 清空按钮
                if onClear != nil {
                    Button {
                        showingClearAlert = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.subheadline)
                            .foregroundColor(Theme.ColorToken.Status.error)
                    }
                    .padding(.leading, 8)
                }
            }

            // 排序选项栏
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ResultSortOption.allCases, id: \.self) { option in
                        Button {
                            withAnimation {
                                if sortOption == option && option != .original {
                                    sortAscending.toggle()
                                } else {
                                    sortOption = option
                                    sortAscending = true
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(option.localizedName)
                                if sortOption == option && option != .original {
                                    Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                                        .font(.caption2)
                                }
                            }
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(sortOption == option ? Color.accentColor : Theme.ColorToken.Surface.subtle)
                            .foregroundColor(sortOption == option ? .white : .primary)
                            .cornerRadius(Theme.Radius.md)
                        }
                    }
                }
            }

            // 结果列表
            ForEach(sortedItems) { item in
                RecognizedItemRowNew(
                    item: item,
                    inventoryManager: inventoryManager,
                    colorSystem: colorSystem,
                    onUpdate: { code, qty in
                        if let index = items.firstIndex(where: { $0.id == item.id }) {
                            // 将所有修改合并到一个副本中，最后一次性写回，
                            // 避免多次触发 @Binding 更新导致 SwiftUI 在 ForEach 中崩溃
                            var updatedItem = items[index]
                            if let c = code {
                                // 非 MARD 色系时，用户输入的可能是该色系的色号，需转为内部 mardCode
                                if colorSystem != .mard,
                                   let color = inventoryManager.findColor(byCode: c, preferSystem: colorSystem) {
                                    updatedItem.colorCode = color.mardCode
                                } else {
                                    updatedItem.colorCode = c.uppercased()
                                }
                            }
                            if let q = qty { updatedItem.quantity = q }
                            items[index] = updatedItem
                        }
                    },
                    onRemove: {
                        items.removeAll { $0.id == item.id }
                    }
                )
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(Theme.Radius.lg)
        .padding(.horizontal)
        .alert("清空确认", isPresented: $showingClearAlert) {
            Button("取消", role: .cancel) { }
            Button("清空", role: .destructive) {
                onClear?()
            }
        } message: {
            Text("确定要清空所有已添加的颜色吗？")
        }
    }
}

struct RecognizedItemRowNew: View {
    let item: ScanView.RecognizedItem
    let inventoryManager: InventoryManager
    var colorSystem: ColorSystem = .mard
    let onUpdate: (String?, Int?) -> Void
    let onRemove: () -> Void

    @State private var isEditing = false
    @State private var editCode: String = ""
    @State private var editQuantity: String = ""
    @State private var showQuantityError = false

    var matchedColor: BeadColor? {
        // item.colorCode 在 recognizeImage 中已规范化为 mardCode（匹配成功时）或保留为原始品牌色号（未匹配时）。
        // 严格按 mardCode 查，避免未匹配的原始色号被无品牌偏好查找跨品牌错配
        // （如 Kaka 模式下 "B02" 撞到 COCO 的 cocoCode "B02" 显示成 H14）。
        inventoryManager.findColor(byMardCode: item.colorCode)
    }

    // 获取低库存阈值
    var lowStockThreshold: Int {
        guard let brandId = inventoryManager.currentBrandId else { return 100 }
        return inventoryManager.getLowStockThreshold(for: brandId)
    }

    // 计算当前库存和扣减后库存
    // isInsufficient: 库存不足（负数）
    // isLowStock: 低库存预警（低于阈值但非负）
    var stockInfo: (current: Int, after: Int, isInsufficient: Bool, isLowStock: Bool)? {
        guard let brandId = inventoryManager.currentBrandId,
              let stock = inventoryManager.getStock(brandId: brandId, mardCode: item.colorCode) else {
            return nil
        }
        let current = stock.available
        let after = current - item.quantity
        let isInsufficient = after < 0
        let isLowStock = !isInsufficient && after < lowStockThreshold
        return (current, after, isInsufficient, isLowStock)
    }

    var body: some View {
        HStack(spacing: 12) {
            // 颜色预览
            if let color = matchedColor {
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(color.color)
                    .frame(width: 36, height: 36)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(Theme.ColorToken.Border.default)
                    .frame(width: 36, height: 36)
                    .overlay(
                        Image(systemName: "questionmark")
                            .foregroundColor(Theme.ColorToken.Text.secondary)
                    )
            }

            // 色号和数量
            if isEditing {
                TextField("色号", text: $editCode)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)

                TextField("数量", text: $editQuantity)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.asciiCapableNumberPad)
                    .frame(width: 60)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .stroke(showQuantityError ? Theme.ColorToken.Status.error : Color.clear, lineWidth: 1)
                    )
                    .onChange(of: editQuantity) { _, _ in
                        showQuantityError = false
                    }

                Button("保存") {
                    guard let qty = Int(editQuantity), qty > 0 else {
                        showQuantityError = true
                        return
                    }
                    showQuantityError = false
                    onUpdate(editCode.isEmpty ? nil : editCode, qty)
                    isEditing = false
                }
                .font(.caption)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(matchedColor?.displayCode(for: colorSystem) ?? item.colorCode)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)

                    if matchedColor == nil {
                        Text("未匹配")
                            .font(.caption2)
                            .foregroundColor(Theme.ColorToken.Status.warning)
                    } else if let info = stockInfo {
                        // 显示库存状态
                        HStack(spacing: 4) {
                            Text("库存 \(info.current)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("→")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("\(info.after)")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundColor(info.isInsufficient ? .red : (info.isLowStock ? .orange : .green))
                            if info.isInsufficient {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundColor(Theme.ColorToken.Status.error)
                            } else if info.isLowStock {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundColor(Theme.ColorToken.Status.warning)
                            }
                        }
                    }
                }

                Spacer()

                Text("×\(item.quantity)")
                    .font(.headline)
                    .foregroundColor(.accentColor)

                // 操作按钮
                Menu {
                    Button {
                        // 编辑时显示当前色系的色号，而非内部 MARD 码
                        editCode = matchedColor?.displayCode(for: colorSystem) ?? item.colorCode
                        editQuantity = "\(item.quantity)"
                        isEditing = true
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }

                    Button(role: .destructive) {
                        onRemove()
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(stockInfo?.isInsufficient == true ? Theme.ColorToken.Status.error.opacity(0.1) : Theme.ColorToken.Surface.subtle)
        .cornerRadius(Theme.Radius.md)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(stockInfo?.isInsufficient == true ? Theme.ColorToken.Status.error.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }
}

// MARK: - 新版手动添加弹窗（类似添加库存的UI，支持多选，与已有结果同步）
struct ManualEntrySheetNew: View {
    @Binding var recognizedItems: [ScanView.RecognizedItem]
    var colorSystem: ColorSystem = .mard
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss

    @State private var selectedSeries = "A"
    @StateObject private var sel = SelectionContext<UUID>()
    @State private var quantities: [UUID: Int] = [:]  // 每个颜色的数量（以颜色ID为key）
    @State private var isInitialized = false

    var colorsInSeries: [BeadColor] {
        let prefixes = colorSystem.standardPrefixes

        return inventoryManager.allBeadColors.filter { color in
            // 非 MARD 体系下仅显示有对应色号的颜色
            if colorSystem != .mard && !color.hasCode(for: colorSystem) {
                return false
            }

            let code = color.displayCode(for: colorSystem)

            if selectedSeries == "#" {
                return code.hasPrefix("#")
            } else if selectedSeries == "其他" {
                return !prefixes.contains { prefix in
                    if prefix == "ZG" {
                        return code.hasPrefix("ZG")
                    } else {
                        return code.hasPrefix(prefix) && !code.hasPrefix("ZG")
                    }
                } && !code.hasPrefix("#")
            } else if selectedSeries == "ZG" {
                return code.hasPrefix("ZG")
            } else {
                if code.hasPrefix("ZG") { return false }
                if code.hasPrefix("#") { return false }
                return code.hasPrefix(selectedSeries)
            }
        }.sorted { $0.displayCode(for: colorSystem).localizedStandardCompare($1.displayCode(for: colorSystem)) == .orderedAscending }
    }

    var totalToAdd: Int {
        var total = 0
        for colorId in sel.selected {
            let qty = quantities[colorId] ?? 1
            total += qty
        }
        return total
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 色系选择器
                ManualEntrySeriesSelector(
                    series: colorSystem.colorSeries,
                    selectedSeries: $selectedSeries
                )
                .padding(.vertical, 8)

                // 颜色列表
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(colorsInSeries) { color in
                            ManualEntryColorRow(
                                color: color,
                                isSelected: sel.contains(color.id),
                                quantity: bindingForColor(color.id),
                                onToggle: {
                                    toggleSelection(color.id)
                                },
                                colorSystem: colorSystem
                            )
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 100)
                }
                .scrollDismissesKeyboard(.immediately)
                .onTapGesture {
                    // 点击空白区域收起键盘
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }

            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("编辑颜色")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                // Sheet 内"始终处于选择态"：选中任何颜色就显示统一动作条
                if sel.count > 0 {
                    MultiSelectActionBar(count: sel.count) {
                        HStack(spacing: Theme.Spacing.md) {
                            Text("共 \(totalToAdd) 颗")
                                .font(Theme.Typography.metadata)
                                .foregroundStyle(Theme.ColorToken.Text.secondary)
                            Button(action: confirmAdd) {
                                Text("添加")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 10)
                                    .background(Color.accentColor, in: Capsule())
                            }
                        }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if sel.count > 0 {
                        Button("清空") {
                            withAnimation {
                                sel.clear()
                                quantities.removeAll()
                            }
                        }
                        .foregroundColor(Theme.ColorToken.Status.error)
                    }
                }
            }
            .onAppear {
                selectedSeries = colorSystem.defaultSeries
                // Sheet 始终处于选择态：进入时即激活多选容器
                if !sel.isActive { sel.enter() }
                initializeFromRecognizedItems()
            }
        }
    }

    /// 从已有的识别结果初始化选择状态
    func initializeFromRecognizedItems() {
        guard !isInitialized else { return }
        isInitialized = true

        for item in recognizedItems {
            // 根据 mardCode 找到对应的颜色（包括自定义色号，兼容旧 C_ 前缀）
            // 严格按 mardCode 查，避免未匹配的原始色号跨品牌乱碰
            if let color = inventoryManager.findColor(byMardCode: item.colorCode) {
                sel.toggle(color.id)  // 进入时未选中 → toggle 等价于 insert
                quantities[color.id] = item.quantity
            }
        }
    }

    func toggleSelection(_ colorId: UUID) {
        withAnimation(.easeInOut(duration: 0.2)) {
            let wasSelected = sel.contains(colorId)
            sel.toggle(colorId)
            if wasSelected {
                quantities.removeValue(forKey: colorId)
            } else if quantities[colorId] == nil {
                quantities[colorId] = 1
            }
        }
    }

    func confirmAdd() {
        // 用新的选择替换原来的 recognizedItems
        var newItems: [ScanView.RecognizedItem] = []
        for colorId in sel.selected {
            guard let color = inventoryManager.allBeadColors.first(where: { $0.id == colorId }) else { continue }
            let qty = quantities[colorId] ?? 1
            newItems.append(ScanView.RecognizedItem(colorCode: color.mardCode, quantity: qty))
        }
        recognizedItems = newItems
        dismiss()
    }

    /// 为指定颜色创建稳定的 Binding
    func bindingForColor(_ colorId: UUID) -> Binding<Int> {
        Binding(
            get: { self.quantities[colorId] ?? 1 },
            set: { self.quantities[colorId] = $0 }
        )
    }
}

// MARK: - 手动添加色系选择器
struct ManualEntrySeriesSelector: View {
    let series: [String]
    @Binding var selectedSeries: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(series, id: \.self) { s in
                    Button {
                        withAnimation { selectedSeries = s }
                    } label: {
                        Text(ColorSystem.localizedSeriesName(s))
                            .font(.system(.subheadline, design: .rounded))
                            .fontWeight(.medium)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(selectedSeries == s ? Color.accentColor : Theme.ColorToken.Surface.subtle)
                            .foregroundColor(selectedSeries == s ? .white : .primary)
                            .cornerRadius(Theme.Radius.lg)
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}

// MARK: - 手动添加颜色行
struct ManualEntryColorRow: View {
    let color: BeadColor
    let isSelected: Bool
    @Binding var quantity: Int
    let onToggle: () -> Void
    var colorSystem: ColorSystem = .mard
    @EnvironmentObject var inventoryManager: InventoryManager

    var body: some View {
        HStack(spacing: 12) {
            // 选择按钮
            Button(action: onToggle) {
                ZStack {
                    Circle()
                        .stroke(isSelected ? Color.accentColor : Theme.ColorToken.Border.default, lineWidth: 2)
                        .frame(width: 28, height: 28)

                    if isSelected {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 20, height: 20)

                        Image(systemName: "checkmark")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                    }
                }
            }

            // 颜色预览
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(color.color)
                .frame(width: 40, height: 40)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
                )

            // 色号
            Text(color.displayCode(for: colorSystem))
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)

            Spacer()

            // 数量控制（仅在选中时显示）
            if isSelected {
                ManualEntryQuantityControl(quantity: $quantity)
            }
        }
        .padding(12)
        .background(Color(.systemBackground))
        .cornerRadius(Theme.Radius.md)
    }
}

// MARK: - 手动添加数量控制器（以1为单位）
struct ManualEntryQuantityControl: View {
    @Binding var quantity: Int
    @State private var editText: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            // 减少按钮
            Button {
                if quantity > 1 {
                    quantity -= 1
                    editText = "\(quantity)"
                }
            } label: {
                Image(systemName: "minus")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(quantity > 1 ? Theme.ColorToken.Text.tertiary : Theme.ColorToken.Border.default)
                    .cornerRadius(Theme.Radius.md)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(quantity <= 1)

            // 数量输入框
            TextField("", text: $editText)
                .keyboardType(.asciiCapableNumberPad)
                .multilineTextAlignment(.center)
                .font(.system(size: 16, weight: .regular, design: .monospaced))
                .frame(width: 60, height: 32)
                .background(Theme.ColorToken.Surface.subtle)
                .cornerRadius(Theme.Radius.sm)
                .focused($isFocused)
                .onChange(of: editText) { _, newValue in
                    let filtered = newValue.filter { $0.isNumber }
                    if filtered != newValue {
                        editText = filtered
                    }
                    if let value = Int(filtered), value > 0 {
                        quantity = value
                    }
                }

            // 增加按钮
            Button {
                quantity += 1
                editText = "\(quantity)"
            } label: {
                Image(systemName: "plus")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor)
                    .cornerRadius(Theme.Radius.md)
            }
            .buttonStyle(PlainButtonStyle())

            // 单位标签
            Text("颗")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .onAppear {
            editText = "\(quantity)"
        }
        .onChange(of: quantity) { _, newValue in
            if !isFocused {
                editText = "\(newValue)"
            }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused {
                if let value = Int(editText), value > 0 {
                    quantity = value
                }
                editText = "\(quantity)"
            }
        }
    }
}

// MARK: - 缩略图预览区域
struct ThumbnailPreviewSection: View {
    @Binding var thumbnailImage: UIImage?
    let originalImage: UIImage?
    @Binding var showingThumbnailCrop: Bool

    // 上传新封面相关
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var uploadedImage: UIImage?  // 用户上传的新图片
    @State private var showingUploadedImageCrop = false
    @State private var isLoadingImage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("项目缩略图")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()

                // 上传新封面按钮
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    HStack(spacing: 4) {
                        Image(systemName: "photo.badge.plus")
                        Text(thumbnailImage == nil ? "上传封面" : "更换")
                    }
                    .font(.caption)
                    .foregroundColor(.accentColor)
                }
                .onChange(of: selectedPhotoItem) { _, newItem in
                    if let newItem = newItem {
                        isLoadingImage = true
                        Task {
                            if let data = try? await newItem.loadTransferable(type: Data.self),
                               let image = UIImage(data: data) {
                                await MainActor.run {
                                    uploadedImage = image
                                    isLoadingImage = false
                                    // 延迟打开裁切视图，确保状态已更新
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                        showingUploadedImageCrop = true
                                    }
                                }
                            } else {
                                await MainActor.run {
                                    isLoadingImage = false
                                }
                            }
                        }
                        selectedPhotoItem = nil
                    }
                }

                if thumbnailImage != nil {
                    Button {
                        showingThumbnailCrop = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "crop")
                            Text("裁切")
                        }
                        .font(.caption)
                        .foregroundColor(.accentColor)
                    }
                    .padding(.leading, 8)

                    Button {
                        thumbnailImage = nil
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle")
                            Text("移除")
                        }
                        .font(.caption)
                        .foregroundColor(Theme.ColorToken.Status.error)
                    }
                    .padding(.leading, 8)
                }
            }

            if isLoadingImage {
                HStack {
                    ProgressView()
                        .frame(width: 80, height: 80)
                    Text("加载图片中...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else if let image = thumbnailImage {
                HStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("将保存为项目封面")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("点击裁切可调整，或上传新封面")
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.7))
                    }

                    Spacer()
                }
            } else {
                HStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(Theme.ColorToken.Border.default.opacity(0.5))
                        .frame(width: 80, height: 80)
                        .overlay(
                            Image(systemName: "photo.badge.plus")
                                .font(.title2)
                                .foregroundColor(Theme.ColorToken.Text.secondary)
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("暂无封面图")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("点击「上传封面」添加")
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.7))
                    }

                    Spacer()
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(Theme.Radius.md)
        // 上传图片的裁切视图
        .fullScreenCover(isPresented: $showingUploadedImageCrop) {
            if let image = uploadedImage {
                ImageCropView(image: image) { croppedImage in
                    thumbnailImage = croppedImage
                    uploadedImage = nil
                }
            } else {
                // 如果没有图片，立即关闭
                Color.black.onAppear {
                    showingUploadedImageCrop = false
                }
            }
        }
        .onChange(of: showingUploadedImageCrop) { _, isShowing in
            // 如果裁切视图关闭且没有设置缩略图，清理上传的图片
            if !isShowing && uploadedImage != nil {
                uploadedImage = nil
            }
        }
    }
}

// MARK: - AI 设置视图（从 ScanView 跳转）
struct AISettingsView: View {
    @ObservedObject var aiService: AIServiceManager

    var body: some View {
        RecognitionSettingsScreen()
    }
}

// MARK: - 图片裁切视图
struct ImageCropView: View {
    let image: UIImage
    let onCrop: (UIImage) -> Void
    @Environment(\.dismiss) var dismiss

    // 状态
    @State private var cropRect: CGRect = .zero
    @State private var isInitialized = false
    @State private var imageDisplayRect: CGRect = .zero  // 图片在容器内的显示区域（本地坐标）
    @State private var containerSize: CGSize = .zero

    // 预览状态
    @State private var croppedPreview: UIImage? = nil
    @State private var showingPreview = false

    var body: some View {
        NavigationStack {
            ZStack {
                if showingPreview, let preview = croppedPreview {
                    // 预览裁剪结果
                    CropPreviewView(
                        croppedImage: preview,
                        onConfirm: {
                            onCrop(preview)
                            dismiss()
                        },
                        onRetry: {
                            showingPreview = false
                            croppedPreview = nil
                        }
                    )
                } else {
                    // 裁切界面 - 使用单一 GeometryReader 确保坐标一致
                    GeometryReader { geometry in
                        let localContainerSize = geometry.size
                        let localImageRect = calculateImageRect(for: localContainerSize)

                        ZStack {
                            Color.black

                            // 图片
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(width: localImageRect.width, height: localImageRect.height)
                                .position(x: localImageRect.midX, y: localImageRect.midY)

                            // 遮罩和裁切框
                            if cropRect != .zero {
                                CropOverlayView(
                                    cropRect: $cropRect,
                                    imageRect: imageDisplayRect,
                                    containerSize: localContainerSize
                                )
                            }
                        }
                        .onAppear {
                            containerSize = localContainerSize
                            imageDisplayRect = localImageRect
                            if !isInitialized {
                                initializeCropRect(imageRect: localImageRect)
                            }
                        }
                        .onChange(of: geometry.size) { _, newSize in
                            if newSize.width > 0 && newSize.height > 0 {
                                containerSize = newSize
                                let newImageRect = calculateImageRect(for: newSize)
                                imageDisplayRect = newImageRect
                                if !isInitialized {
                                    initializeCropRect(imageRect: newImageRect)
                                }
                            }
                        }
                    }
                    .ignoresSafeArea(edges: .bottom)
                }
            }
            .navigationTitle(showingPreview ? "预览" : "裁切图片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(showingPreview ? "重新裁切" : "取消") {
                        if showingPreview {
                            showingPreview = false
                            croppedPreview = nil
                        } else {
                            dismiss()
                        }
                    }
                    .foregroundColor(.white)
                }
                if !showingPreview {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("预览") {
                            performCrop()
                        }
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                    }
                }
            }
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    /// 计算图片在容器中居中显示的区域
    func calculateImageRect(for size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else {
            return .zero
        }

        let imageAspect = image.size.width / image.size.height
        let containerAspect = size.width / size.height

        let displaySize: CGSize
        if imageAspect > containerAspect {
            // 图片更宽，以宽度为准
            let w = size.width
            let h = w / imageAspect
            displaySize = CGSize(width: w, height: h)
        } else {
            // 图片更高，以高度为准
            let h = size.height
            let w = h * imageAspect
            displaySize = CGSize(width: w, height: h)
        }

        // 居中
        let origin = CGPoint(
            x: (size.width - displaySize.width) / 2,
            y: (size.height - displaySize.height) / 2
        )

        return CGRect(origin: origin, size: displaySize)
    }

    func initializeCropRect(imageRect: CGRect) {
        guard imageRect.width > 0, imageRect.height > 0 else { return }
        guard !isInitialized else { return }

        // 初始化裁切框为图片中心区域的 80%
        let initialWidth = imageRect.width * 0.8
        let initialHeight = imageRect.height * 0.8
        cropRect = CGRect(
            x: imageRect.minX + (imageRect.width - initialWidth) / 2,
            y: imageRect.minY + (imageRect.height - initialHeight) / 2,
            width: initialWidth,
            height: initialHeight
        )
        isInitialized = true
    }

    func performCrop() {
        guard imageDisplayRect.width > 0, imageDisplayRect.height > 0,
              cropRect.width > 0, cropRect.height > 0 else {
            return
        }

        // 将裁切框坐标转换为相对于显示图片的坐标（0-1 范围）
        let relativeX = (cropRect.minX - imageDisplayRect.minX) / imageDisplayRect.width
        let relativeY = (cropRect.minY - imageDisplayRect.minY) / imageDisplayRect.height
        let relativeWidth = cropRect.width / imageDisplayRect.width
        let relativeHeight = cropRect.height / imageDisplayRect.height

        // 首先将图片方向正规化
        let normalizedImage = normalizeImageOrientation(image)

        // 计算在正确方向图片上的裁切区域
        let cropX = relativeX * normalizedImage.size.width
        let cropY = relativeY * normalizedImage.size.height
        let cropWidth = relativeWidth * normalizedImage.size.width
        let cropHeight = relativeHeight * normalizedImage.size.height

        let cropCGRect = CGRect(
            x: max(0, cropX),
            y: max(0, cropY),
            width: min(cropWidth, normalizedImage.size.width - max(0, cropX)),
            height: min(cropHeight, normalizedImage.size.height - max(0, cropY))
        )

        // 执行裁切
        if let cgImage = normalizedImage.cgImage?.cropping(to: cropCGRect) {
            let cropped = UIImage(cgImage: cgImage, scale: image.scale, orientation: .up)
            croppedPreview = cropped
            showingPreview = true
        }
    }

    /// 将图片方向正规化
    func normalizeImageOrientation(_ image: UIImage) -> UIImage {
        if image.imageOrientation == .up {
            return image
        }

        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        let normalizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return normalizedImage ?? image
    }
}

// MARK: - 裁切预览视图
struct CropPreviewView: View {
    let croppedImage: UIImage
    let onConfirm: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            // 预览图片
            Image(uiImage: croppedImage)
                .resizable()
                .scaledToFit()
                .cornerRadius(Theme.Radius.md)
                .padding(.horizontal, 20)

            // 尺寸信息
            Text("尺寸: \(Int(croppedImage.size.width)) × \(Int(croppedImage.size.height))")
                .font(.caption)
                .foregroundColor(Theme.ColorToken.Text.secondary)

            Spacer()

            // 按钮
            HStack(spacing: 20) {
                Button {
                    onRetry()
                } label: {
                    Text("重新裁切")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Theme.ColorToken.Border.default)
                        .foregroundColor(.white)
                        .cornerRadius(Theme.Radius.md)
                }

                Button {
                    onConfirm()
                } label: {
                    Text("使用此图片")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(Theme.Radius.md)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
        .background(Color.black)
    }
}

// MARK: - 裁切遮罩和框
struct CropOverlayView: View {
    @Binding var cropRect: CGRect
    let imageRect: CGRect
    let containerSize: CGSize

    @State private var dragStart: CGPoint = .zero
    @State private var initialRect: CGRect = .zero

    let minSize: CGFloat = 60
    let handleSize: CGFloat = 44

    var body: some View {
        ZStack {
            // 半透明遮罩（裁切区域外）
            CropMaskShape(cropRect: cropRect)
                .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

            // 裁切框边框
            Rectangle()
                .stroke(Color.white, lineWidth: 2)
                .frame(width: cropRect.width, height: cropRect.height)
                .position(x: cropRect.midX, y: cropRect.midY)
                .allowsHitTesting(false)

            // 网格线
            CropGridShape()
                .stroke(Color.white.opacity(0.4), lineWidth: 1)
                .frame(width: cropRect.width, height: cropRect.height)
                .position(x: cropRect.midX, y: cropRect.midY)
                .allowsHitTesting(false)

            // 中心拖拽区域
            Rectangle()
                .fill(Color.white.opacity(0.001)) // 几乎透明但可点击
                .frame(width: max(0, cropRect.width - handleSize * 2), height: max(0, cropRect.height - handleSize * 2))
                .position(x: cropRect.midX, y: cropRect.midY)
                .gesture(dragGesture(for: .center))

            // 四个角的手柄
            cornerHandle(at: .topLeft)
            cornerHandle(at: .topRight)
            cornerHandle(at: .bottomLeft)
            cornerHandle(at: .bottomRight)
        }
    }

    enum DragLocation {
        case center, topLeft, topRight, bottomLeft, bottomRight
    }

    func cornerHandle(at location: DragLocation) -> some View {
        let position: CGPoint = {
            switch location {
            case .topLeft: return CGPoint(x: cropRect.minX, y: cropRect.minY)
            case .topRight: return CGPoint(x: cropRect.maxX, y: cropRect.minY)
            case .bottomLeft: return CGPoint(x: cropRect.minX, y: cropRect.maxY)
            case .bottomRight: return CGPoint(x: cropRect.maxX, y: cropRect.maxY)
            case .center: return CGPoint(x: cropRect.midX, y: cropRect.midY)
            }
        }()

        return Circle()
            .fill(Color.white)
            .frame(width: 24, height: 24)
            .overlay(Circle().stroke(Color.black.opacity(0.3), lineWidth: 1))
            .position(position)
            .gesture(dragGesture(for: location))
    }

    func dragGesture(for location: DragLocation) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == .zero {
                    dragStart = value.startLocation
                    initialRect = cropRect
                }

                let translation = CGSize(
                    width: value.location.x - dragStart.x,
                    height: value.location.y - dragStart.y
                )

                var newRect = initialRect

                switch location {
                case .center:
                    newRect.origin.x = initialRect.origin.x + translation.width
                    newRect.origin.y = initialRect.origin.y + translation.height

                case .topLeft:
                    newRect.origin.x = initialRect.origin.x + translation.width
                    newRect.origin.y = initialRect.origin.y + translation.height
                    newRect.size.width = initialRect.width - translation.width
                    newRect.size.height = initialRect.height - translation.height

                case .topRight:
                    newRect.origin.y = initialRect.origin.y + translation.height
                    newRect.size.width = initialRect.width + translation.width
                    newRect.size.height = initialRect.height - translation.height

                case .bottomLeft:
                    newRect.origin.x = initialRect.origin.x + translation.width
                    newRect.size.width = initialRect.width - translation.width
                    newRect.size.height = initialRect.height + translation.height

                case .bottomRight:
                    newRect.size.width = initialRect.width + translation.width
                    newRect.size.height = initialRect.height + translation.height
                }

                // 约束最小尺寸
                if newRect.width < minSize {
                    if location == .topLeft || location == .bottomLeft {
                        newRect.origin.x = initialRect.maxX - minSize
                    }
                    newRect.size.width = minSize
                }
                if newRect.height < minSize {
                    if location == .topLeft || location == .topRight {
                        newRect.origin.y = initialRect.maxY - minSize
                    }
                    newRect.size.height = minSize
                }

                // 约束在图片范围内
                newRect.origin.x = max(imageRect.minX, min(newRect.origin.x, imageRect.maxX - newRect.width))
                newRect.origin.y = max(imageRect.minY, min(newRect.origin.y, imageRect.maxY - newRect.height))

                if newRect.maxX > imageRect.maxX {
                    newRect.size.width = imageRect.maxX - newRect.origin.x
                }
                if newRect.maxY > imageRect.maxY {
                    newRect.size.height = imageRect.maxY - newRect.origin.y
                }

                cropRect = newRect
            }
            .onEnded { _ in
                dragStart = .zero
                initialRect = .zero
            }
    }
}

// MARK: - 裁切遮罩形状
struct CropMaskShape: Shape {
    let cropRect: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addRect(cropRect)
        return path
    }
}

// MARK: - 网格线形状
struct CropGridShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()

        // 垂直线 (三分法)
        let thirdW = rect.width / 3
        path.move(to: CGPoint(x: thirdW, y: 0))
        path.addLine(to: CGPoint(x: thirdW, y: rect.height))
        path.move(to: CGPoint(x: thirdW * 2, y: 0))
        path.addLine(to: CGPoint(x: thirdW * 2, y: rect.height))

        // 水平线 (三分法)
        let thirdH = rect.height / 3
        path.move(to: CGPoint(x: 0, y: thirdH))
        path.addLine(to: CGPoint(x: rect.width, y: thirdH))
        path.move(to: CGPoint(x: 0, y: thirdH * 2))
        path.addLine(to: CGPoint(x: rect.width, y: thirdH * 2))

        return path
    }
}

// MARK: - 扫描引导弹窗
struct ScanHelpSheet: View {
    let onDismiss: () -> Void
    var onNeverShowAgain: (() -> Void)? = nil  // 可选，从"更多"页面打开时不需要

    var body: some View {
        VStack(spacing: 0) {
            // 翻页内容区域
            TabView {
                // 第一页
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("啃豆小仓AI扫描使用教程（1）")
                            .font(.title3)
                            .fontWeight(.bold)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 24)

                        VStack(alignment: .leading, spacing: 12) {
                            Text("1. 先选择识别方式：推荐配置云端 API（更准更快），也可下载本地模型离线使用")
                            Text("2. 裁切图纸，请只保留图纸下方豆量汇总")
                            Text("3. 扫描")
                        }
                        .font(.body)
                        .padding(.horizontal, 20)

                        Image("HelpNew1")
                            .resizable()
                            .scaledToFit()
                            .cornerRadius(Theme.Radius.md)
                            .padding(.horizontal, 20)

                        Spacer(minLength: 100)
                    }
                }

                // 第二页
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("啃豆小仓AI扫描使用教程（2）")
                            .font(.title3)
                            .fontWeight(.bold)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 24)

                        VStack(spacing: 4) {
                            Text("上边的叫「表格」，下边的叫「色号统计」")
                            Text("目前啃豆小仓无法直接识别你的「图纸」")
                        }
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 20)

                        Image("HelpNew2")
                            .resizable()
                            .scaledToFit()
                            .cornerRadius(Theme.Radius.md)
                            .padding(.horizontal, 20)

                        Image("HelpNew3")
                            .resizable()
                            .scaledToFit()
                            .cornerRadius(Theme.Radius.md)
                            .padding(.horizontal, 20)

                        Spacer(minLength: 100)
                    }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            // 按钮区域
            VStack(spacing: 12) {
                Button {
                    onDismiss()
                } label: {
                    Text("好的")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(Theme.Radius.md)
                }

                if let onNeverShowAgain = onNeverShowAgain {
                    Button {
                        onNeverShowAgain()
                    } label: {
                        Text("不再显示")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .background(Color(.systemBackground))
        }
        .presentationDetents([.large])
    }
}

#Preview {
    ScanView()
        .environmentObject(InventoryManager())
}
