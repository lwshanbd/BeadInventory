//
//  ScanView.swift
//  BeadInventory
//
//  图纸扫描和AI识别界面
//

import SwiftUI
import PhotosUI
import UIKit

struct ScanView: View {
    enum Layout {
        static let imageSelectionHeight: CGFloat = 250
        static let pinnedImageHeight: CGFloat = 250
        static let expandedPinnedImageHeight: CGFloat = 320
    }

    @EnvironmentObject var inventoryManager: InventoryManager
    @ObservedObject private var aiService = AIServiceManager.shared

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
    /// 图片编码失败。必须可见 —— 静默失败会让用户拿到一个永远没有图的项目。
    @State private var imageEncodeFailed = false
    @State private var deductionFailureMessage = ""
    @State private var deductSuccessAt: Date = .distantPast

    /// 选图失败提示（PhotoPicker / loadTransferable / UIImage 解码任一阶段失败都走这里）。
    /// 之前 handlePhotoItemChange 走 try?，错误全静默 —— 用户表现是转圈停了什么也没出现，
    /// 报障没线索。改成 do/catch + alert + AppLogger.error。
    @State private var showingPhotoLoadError = false
    @State private var photoLoadErrorMessage = ""

    private let similarityService = ColorSimilarityService()

    // 缩略图相关
    @State private var originalImage: UIImage?       // 原始图片（裁剪前）
    @State private var thumbnailImage: UIImage?      // 缩略图（可裁切）
    @State private var showingThumbnailCrop = false  // 显示缩略图裁切视图

    /// 从相册选进来的那张图的**原始字节**。建项目时另存一份给拼图模式用
    /// （见 `patternSourceData()` 和 `PatternSourceStore`）。
    @State private var pickedOriginalData: Data?
    /// 这一张要不要留原图。
    ///
    /// **是每张图各自的决定，不是一个全局开关。** 用户一次可能传十张图纸，只有其中
    /// 两三张会真的进拼图模式去逐格对色号；剩下的留一份几十 MB 的原图纯属白占地方。
    /// 设置里那个开关只决定这里的**初值**（见 `PatternSourceStore.keepsSourceByDefault`）。
    @State private var keepPatternSource = PatternSourceStore.keepsSourceByDefault

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
        /// 用户在缺豆建议行上「应用推荐品牌」时记下的目标品牌；
        /// 进入 DeductionResolver 时会调用 overrideBrand(...) 落地。
        var preferredBrandId: UUID? = nil
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
                        onReselect: resetPickedImage
                    )
                }

                // 三段进度指示器卡片：上传图纸 → 识别调整 → 扣减执行
                ScanStepIndicatorCard(currentIndex: stepperIndex)

                GeometryReader { geometry in
                    ScrollView {
                        VStack(spacing: 20) {
                            // 图片选择区域（当未固定时显示）
                            if !isImagePinned {
                                ImageSelectionSection(
                                    selectedImage: $selectedImage,
                                    selectedPhotoItem: $selectedPhotoItem,
                                    showingCamera: $showingCamera,
                                    isLoadingImage: $isLoadingImage,
                                    showingCropView: $showingCropView,
                                    isPinned: $isImagePinned,
                                    keepPatternSource: $keepPatternSource,
                                    originalByteCount: pickedOriginalData?.count,
                                    hasRecognizedItems: !recognizedItems.isEmpty,
                                    onReselect: resetPickedImage,
                                    onManualTap: { showingManualEntry = true }
                                )
                            }

                            // AI 配置状态提示
                            aiStatusBanner

                            // 色号体系 + 备扣品牌（合并卡片）
                            contextBarCard

                            // 识别按钮
                            if selectedImage != nil {
                                recognitionButtons
                            }

                            // 错误提示
                            errorBanner

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
            .background(Theme.ColorToken.Surface.background)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
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
            .haptic(.success, trigger: deductSuccessAt)
            .haptic(.error, trigger: showingDeductionFailure)
            .haptic(.error, trigger: imageEncodeFailed)
            .alert("图片处理失败", isPresented: $imageEncodeFailed) {
                Button("好", role: .cancel) { }
            } message: {
                Text("这张图片无法处理，项目未创建。请重试或换一张图片。")
            }
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
            .alert("图片加载失败", isPresented: $showingPhotoLoadError) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(photoLoadErrorMessage)
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
            // 用户可能扫描完跑到 inventory tab 删品牌 / 改品牌色系 / 切扫描色系，
            // 回来时 recognizedItems 里残留的 preferredBrandId 就成了 dangling UUID。
            // 行视图本身没观察 inventoryManager（pass as let），不会自动清；这里在
            // ScanView 顶层统一捕获 brands 和 scanColorSystem 的变化，把 dangling
            // 的 preferredBrandId 清掉 + 写一条 warning 留 trace。
            .onChange(of: inventoryManager.brands) { _, _ in
                cleanupDanglingPreferredBrands()
            }
            .onChange(of: scanColorSystem) { _, _ in
                cleanupDanglingPreferredBrands()
            }
    }

    /// 把指向已删除品牌 / 色系已变 / 跟当前 scanColorSystem 不匹配的 preferredBrandId 清掉。
    /// 在 inventoryManager.brands 或 scanColorSystem 变化时调用，让 UI 上的"已切换为 X"
    /// 状态跟实际可用的 override 保持一致。每条丢弃落 AppLogger.warning，便于事后排查。
    private func cleanupDanglingPreferredBrands() {
        for index in recognizedItems.indices {
            guard let preferred = recognizedItems[index].preferredBrandId else { continue }
            guard let brand = inventoryManager.brands.first(where: { $0.id == preferred }) else {
                AppLogger.shared.warning("Scan", "preferred_brand_self_healed_missing", metadata: [
                    "preferredBrandId": preferred.uuidString,
                    "mardCode": recognizedItems[index].colorCode
                ])
                recognizedItems[index].preferredBrandId = nil
                continue
            }
            if brand.colorSystem != scanColorSystem {
                AppLogger.shared.warning("Scan", "preferred_brand_self_healed_color_system_mismatch", metadata: [
                    "preferredBrandId": preferred.uuidString,
                    "brandColorSystem": "\(brand.colorSystem)",
                    "scanColorSystem": "\(scanColorSystem)"
                ])
                recognizedItems[index].preferredBrandId = nil
            }
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
        // 三个可能失败的点都分开处理，避免之前 try? + UIImage(data:) ?? 全合并成一个 else
        // 的静默失败。错误统一进 alert + log。
        Task {
            do {
                guard let data = try await newItem.loadTransferable(type: Data.self) else {
                    AppLogger.shared.warning("Scan", "photo_load_empty_data", metadata: [:])
                    await MainActor.run {
                        isLoadingImage = false
                        photoLoadErrorMessage = String(localized: "图片内容为空，请重新选择。")
                        showingPhotoLoadError = true
                    }
                    return
                }
                guard let image = UIImage(data: data) else {
                    AppLogger.shared.error("Scan", "photo_decode_failed", metadata: ["bytes": "\(data.count)"])
                    await MainActor.run {
                        isLoadingImage = false
                        photoLoadErrorMessage = String(localized: "图片格式无法识别（仅支持 HEIC/JPG/PNG）。")
                        showingPhotoLoadError = true
                    }
                    return
                }
                await MainActor.run {
                    selectedImage = image
                    originalImage = image
                    thumbnailImage = image
                    pickedOriginalData = data
                    keepPatternSource = PatternSourceStore.keepsSourceByDefault
                    isLoadingImage = false
                }
            } catch {
                AppLogger.shared.error("Scan", "photo_load_failed", metadata: ["error": "\(error)"])
                await MainActor.run {
                    isLoadingImage = false
                    photoLoadErrorMessage = error.localizedDescription
                    showingPhotoLoadError = true
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

    /// 建项目时给拼图模式另存的那份「原图」。
    ///
    /// 识别图纸这条路上，用户传的那张图本来就是全分辨率的，可这以前只被压成封面存进库里
    /// （长边 3072、1.2 MB 预算），拼图模式要逐格看颜色时就只剩十来个像素一格。
    /// 用户上传时手里明明有原图，却要等走到拼图模式才被提示「去相册再选一次」——
    /// 所以现在建项目的同时就把它留下来。
    ///
    /// 存的是**用户传进来的那张图纸**；只要他传过图，封面后来被怎么改都不影响这一份。
    ///
    /// 这一条是用户报障换来的：识别完之后在下面那张封面上裁一刀（或者换成一张成品照），
    /// 存成计划，再进拼图模式 —— 图纸变成了那张封面。用户的心智很清楚：上面那张是我要
    /// 拼的图纸，下面那张是列表里给自己看的封面，改封面不该动图纸。
    ///
    /// 三条来源，优先级从高到低：
    ///   - 相册选的 → 那份原始字节（没有二次编码，最干净）
    ///   - 拍照 / 从别处传进来的 → 手上那张重出无损 PNG。分享进来的那张在 Share Extension
    ///     里已经被 `ProjectImageEncoder` 压过一道（分辨率保留、编码有损），这里只是原样留下，
    ///     画质不会因为存成 PNG 就回来。
    ///   - 一张图纸都没传过（手动加色号、只上传了封面）→ 那封面就是唯一的图，用它。
    ///     只有这一条会落到封面上。
    ///
    /// 两张图取景不同不要紧：拼图模式一次会话里只认一张（有原图用原图、没有才退回封面，
    /// 见 `SinglePatternFlowView.load`）。单张模式还会把对格子时那张的尺寸记进
    /// `BeadPatternGrid.sourceImageSize`，下次进来宽高比对不上就作废网格；零件模式没有这道检查。
    ///
    /// 用户在上传那一屏把「留原图」关掉时返回 nil，一个字节都不写。
    ///
    /// 项目建好之后规矩不一样：封面编辑器（`ProjectImageEditorSheet`）**一个字节都不写**，
    /// 改封面碰不到图纸；换图纸只有一个入口，就是详情页那一行（`PatternSourceRow`），
    /// 它会在覆盖前问一句。
    private func patternSourceData() -> Data? {
        guard keepPatternSource else { return nil }
        if let pickedOriginalData { return pickedOriginalData }
        return PatternSourceStore.lossless(originalImage ?? thumbnailImage)
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
                }
                .font(.caption)
                Spacer()
                NavigationLink(aiService.setupActionTitle) {
                    RecognitionSettingsScreen()
                }
                .font(.caption)
            }
            .padding()
            .background(
                // 深色下纯 warning 10% 压在深底上发闷；先垫 elevated 再点 warning 色、
                // 加同色描边，深浅两种模式都保有结构感。
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(Theme.ColorToken.Surface.elevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .fill(Theme.ColorToken.Status.warning.opacity(0.1))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .strokeBorder(Theme.ColorToken.Status.warning.opacity(0.3), lineWidth: 1)
            )
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

    /// 上下文卡片：色号体系（BISegmented）+ 备扣品牌（pill 按钮）合并
    private var contextBarCard: some View {
        VStack(spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.md) {
                Text("色号体系")
                    .font(.caption2)
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                    .frame(minWidth: 56, alignment: .leading)
                Spacer(minLength: 0)
                BISegmented(
                    selection: $scanColorSystem,
                    segments: [
                        (value: .mard, label: "MARD"),
                        (value: .kaka, label: "卡卡")
                    ]
                )
            }
            Rectangle()
                .fill(Theme.ColorToken.Border.divider)
                .frame(height: 1)
            HStack(spacing: Theme.Spacing.md) {
                Text("备扣品牌")
                    .font(.caption2)
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                    .frame(minWidth: 56, alignment: .leading)
                Spacer(minLength: 0)
                BrandPicker(colorSystemFilter: scanColorSystem)
            }
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.ColorToken.Surface.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
        )
        .padding(.horizontal, 18)
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
                .background(aiService.isConfigured ? Theme.ColorToken.Morandi.mauve : Theme.ColorToken.Border.default)
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
                .background(aiService.isConfigured ? Theme.ColorToken.Morandi.honey : Theme.ColorToken.Border.default)
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
                    .foregroundColor(Theme.ColorToken.Morandi.mauve)
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
            .foregroundColor(Theme.ColorToken.Morandi.mauve)
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
            ScanBottomCTABar(
                totalBeads: totalBeads,
                canDeduct: brandMatchesScanSystem,
                onPlan: { showingCreatePlan = true },
                onDeduct: { prepareDeduction() }
            )
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

                Button(action: resetPickedImage) {
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
        // DeductionResolver.initializeFromRecognizedItems 按顺序生成 items，索引对齐安全。
        // 把识别行上记下的 preferredBrandId 落到 resolver.overrideBrand(...)，
        // 让 ScanView 这一步选好的跨品牌方案直接传到下一页的扣减审核。
        //
        // 设计取向是「任意品牌」——用户哪怕选了 0 库存品牌，也要把 override 落到 resolver，
        // 让下一页扣减审核明确显示缺多少颗，而不是静默回退到主品牌。所以这里只保留两条
        // **数据完整性** guard（brand 不存在 / 色系不匹配），不再卡 stock>0：
        // - brand 不存在：UUID 指向已删除品牌，无法 deduct，必须丢。
        // - 色系不匹配：mardCode ↔ 品牌色号的映射会错位，是 cross-brand 扣减的硬约束。
        // - stock=0 / stock 缺失：是 UX 状态，不是数据完整性问题。让 override 通过，
        //   缺豆通过 DeductionReviewView 的常规缺豆 UI 展示。
        //
        // 两条 guard 仍走 warning（数据漂移/异常），落 override 不再 log。
        for (idx, recognized) in recognizedItems.enumerated() {
            guard let preferred = recognized.preferredBrandId,
                  idx < resolver.items.count else { continue }
            let resolverItem = resolver.items[idx]
            guard let brand = inventoryManager.brands.first(where: { $0.id == preferred }) else {
                AppLogger.shared.warning("Scan", "preferred_brand_dropped_brand_missing", metadata: [
                    "preferredBrandId": preferred.uuidString,
                    "mardCode": resolverItem.mardCode
                ])
                continue
            }
            guard brand.colorSystem == scanColorSystem else {
                AppLogger.shared.warning("Scan", "preferred_brand_dropped_color_system_mismatch", metadata: [
                    "preferredBrandId": preferred.uuidString,
                    "brandColorSystem": "\(brand.colorSystem)",
                    "scanColorSystem": "\(scanColorSystem)"
                ])
                continue
            }
            resolver.overrideBrand(for: resolverItem.id, to: preferred)
        }
        self.deductionResolver = resolver
    }

    func applyToInventoryWithResolver(_ resolver: DeductionResolver) {
        // **先编码再扣减。** 编码失败必须能干净中止，而扣减一旦执行就动了库存。
        // 早期写法是「扣减 → 编码（不检查 nil）→ 建项目 → clearState() → 放成功震动」：
        // 编码失败时用户会得到一个永久没有图、拼图模式永久不可用的项目，
        // 而 clearState() 已经把内存里那张图丢了，除了重扫一遍无法挽回 —— 却看到成功反馈。
        guard let thumbnailDataOrNil = generateThumbnailData() else {
            AppLogger.shared.error("Scan", "thumbnail_encode_failed_aborting_project", metadata: [:])
            // 先收起复核页再弹 alert —— 本函数下面 30 行的扣减失败路径就是这么做的，
            // 理由同样适用：`applyToInventoryWithResolver` 由
            // `navigationDestination(item: $deductionResolver)` 推出来的页面调用，
            // 此时 alert 挂在被盖住的根视图上，直接置位用户什么都看不到。
            deductionResolver = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                imageEncodeFailed = true
            }
            return   // 扣减走的是 shouldSave: false，此时尚未落盘，直接返回即可
        }
        let thumbnailData = thumbnailDataOrNil   // 可能是 nil（用户没图），那是合法的

        // 确认图能编码之后再执行扣减
        let failedItems = resolver.executeDeductions(shouldSave: false)
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
        // 封面存进去了再留原图，免得留下一个对不上任何项目的孤儿文件。
        // clearState() 会把图丢掉，所以必须在它之前。
        if let source = patternSourceData() {
            PatternSourceStore.save(source, for: project.id)
        }

        clearState()

        if failedItems.isEmpty {
            deductSuccessAt = Date()
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
        // 同 applyToInventoryWithResolver：**编码失败**不建项目、不清状态，让用户能重试；
        // 「用户没有封面图」是合法状态，照常建计划。
        guard let thumbnailDataOrNil = generateThumbnailData() else {
            AppLogger.shared.error("Scan", "thumbnail_encode_failed_aborting_plan", metadata: [:])
            imageEncodeFailed = true
            return
        }
        let thumbnailData = thumbnailDataOrNil

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
        if let source = patternSourceData() {
            PatternSourceStore.save(source, for: project.id)
        }

        // 清除结果
        clearState()
    }

    /// 生成落盘用的图纸数据。
    ///
    /// **分辨率原样保留**（拼图模式依赖它做网格识别），只撤回「无条件无损 PNG」那半 ——
    /// 编码器 PNG / JPEG 两种都试取小的，细节见 `ProjectImageEncoder` 头注释。
    ///
    /// 返回值是 `Data??`，因为调用方必须区分两件完全不同的事：
    ///   - `.some(nil)` = **用户没有封面图**。手动添加色号（`manualEntryButton` 是无条件
    ///     渲染的，压根不涉及图片）、或者用户主动点了「移除」—— 都是完全合法的状态，
    ///     项目照建不误，`thumbnail` 存 nil。
    ///   - `nil` = **编码失败**。这时候不能建项目，要报错让用户重试。
    ///
    /// 早期版本把两者都返回 `nil`，调用方一律当失败处理 —— 结果是**手动添加流程整个死掉**：
    /// 用户输完色号点扣减，弹「这张图片无法处理」，然后什么都没发生，而他根本没提供过图片。
    /// 这是 round-1 那个缺陷的镜像：上一层从「硬编码成功」变成了「对合法状态硬编码失败」。
    func generateThumbnailData() -> Data?? {
        guard let thumbnailImage else { return .some(nil) }   // 没有图，合法
        guard let encoded = ProjectImageEncoder.encode(thumbnailImage) else {
            return nil                                        // 有图但编码失败
        }
        return .some(encoded)
    }

    /// 「重新选择」：把上一张图的痕迹全部清掉，识别结果和项目名留着不动。
    ///
    /// 只清 `selectedImage` 是不够的：封面和那份原始字节还留着上一张。接着**用相机**
    /// 拍一张的话，`onChange(of: selectedImage)` 那条只在 `originalImage == nil` 时才接手，
    /// 于是封面、连同留给拼图模式的图纸，都还是上一张那张图。
    ///
    /// **所有「重新选择」入口都得走这里**，现在有三处：置顶图、上传卡片、工具栏菜单。
    /// 之前工具栏那处自己写了三行，于是上面那个 bug 从菜单进去照样能复现。
    private func resetPickedImage() {
        selectedImage = nil
        selectedPhotoItem = nil
        originalImage = nil
        thumbnailImage = nil
        pickedOriginalData = nil
        isImagePinned = false
        // 「留不留原图」是**这一张**的决定，不能带到下一张去 —— 上一张不留，
        // 不代表下一张也不留。回到设置里那个默认值。
        keepPatternSource = PatternSourceStore.keepsSourceByDefault
    }

    /// 清除所有状态：`resetPickedImage()` 那一份，外加识别结果和项目名。
    ///
    /// 「这一张图要清什么」只在 `resetPickedImage()` 里定义一次 —— 两边各抄一份清单的
    /// 结果就是以后加了新状态只改一边。
    func clearState() {
        resetPickedImage()
        recognizedItems = []
        projectName = ""
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
        .background(Theme.ColorToken.Surface.elevated)
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
    /// 这一张要不要留原图（见 ScanView 里同名 State 的注释）
    @Binding var keepPatternSource: Bool
    /// 相册那份原始字节有多大。相机拍的、Share Extension 传进来的没有这份字节，就是 nil，
    /// 那时不写数字，免得报一个还没编码出来、多半不准的大小。
    var originalByteCount: Int?
    var hasRecognizedItems: Bool
    /// 「重新选择」。不能只把 `selectedImage` 置 nil —— 上一张图的封面和原始字节
    /// 还留在 ScanView 里，见 `ScanView.resetPickedImage()`。
    var onReselect: () -> Void
    var onManualTap: (() -> Void)? = nil

    @Environment(\.tabFlavor) private var flavor

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
                .background(Theme.ColorToken.Surface.elevated)
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

                    Button("重新选择", action: onReselect)
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                keepSourceRow
            } else {
                // 莫兰迪上传占位区域：虚线圆角 + mauve 图标块 + 三个动作按钮
                emptyUploadZone
            }
        }
        .padding(.horizontal)
    }

    /// 「这张要不要留原图」。
    ///
    /// 摆在图的正下方，不藏进设置里 —— 十张图纸里往往只有两三张会真的进拼图模式，
    /// 而一份原图动辄几十 MB。这个判断只有当着这张图的面才做得出来，事后在设置里
    /// 翻一个全局开关既晚了也不对（那时候十张图已经全留下了）。
    ///
    /// 写出实际大小是因为它直接决定用户怎么选：「19.1 MB」和「留一份原图」不是一回事。
    private var keepSourceRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $keepPatternSource) {
                HStack(spacing: 6) {
                    Text("保留原图")
                        .font(.caption)
                    if let bytes = originalByteCount {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
            }
            .toggleStyle(.switch)
            .tint(Theme.ColorToken.Morandi.mauve)

            Text(keepPatternSource
                 ? "拼图模式需要保留原图才能看清每格颜色，原图存于本机，不占用 iCloud 空间。完成拼图后可删除"
                 : "这张图纸将无法使用拼图模式。以后需要时，可以在拼图模式里重新选择原图。")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var emptyUploadZone: some View {
        VStack(spacing: Theme.Spacing.md) {
            // 主图标块：56pt mauve 圆角 + 右下角 BeadView
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 18)
                    .fill(flavor.color.opacity(0.15))
                    .frame(width: 56, height: 56)
                    .overlay(
                        Image(systemName: "doc.text.image")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(flavor.color)
                    )
                BeadView(color: flavor.color, size: 18)
                    .offset(x: 6, y: 6)
            }
            .padding(.top, 4)

            VStack(spacing: 4) {
                Text("选择图纸开始识别")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ColorToken.Text.primary)
                Text("支持表格、色号统计、拼图等图纸")
                    .font(.caption2)
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
            }

            HStack(spacing: Theme.Spacing.sm) {
                // 相册（filled mauve）
                // `.current` = 相册里存的是什么格式就给什么字节。默认的 `.automatic`
                // 会把 HEIC 转码成 JPEG —— 那是一次有损重编码，而拼豆模式那份原图
                // 要的就是「一个字节都没动过」。
                PhotosPicker(
                    selection: $selectedPhotoItem,
                    matching: .images,
                    preferredItemEncoding: .current,
                    photoLibrary: .shared()
                ) {
                    Label("相册", systemImage: "photo.on.rectangle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ColorToken.Text.onAccent)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(flavor.fill, in: RoundedRectangle(cornerRadius: 12))
                }

                // 拍照（outlined）
                Button {
                    showingCamera = true
                } label: {
                    Label("拍照", systemImage: "camera")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ColorToken.Text.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Theme.ColorToken.Surface.elevated)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
                        )
                }

                // 手动（outlined）
                if let onManualTap {
                    Button {
                        onManualTap()
                    } label: {
                        Label("手动", systemImage: "pencil")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ColorToken.Text.primary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Theme.ColorToken.Surface.elevated)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
                            )
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Theme.ColorToken.Surface.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(
                    Theme.ColorToken.Border.default,
                    style: StrokeStyle(lineWidth: 2, dash: [6, 5])
                )
        )
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
    @State private var resultFilter: RecognizedResultsFilter = .all

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

    /// 该 item 当前在 *生效品牌*（preferred 优先，否则主品牌）下是否缺豆。
    ///
    /// 缺 BrandStock 记录的颜色按 0 库存算 —— 这种状态通常是用户切了色系 / 删了
    /// 品牌后还残留的 stale 数据，把它当"不缺豆"会让 shortage 筛选 / 缺豆 chip
    /// 静默漏报。
    private func itemHasEffectiveShortage(_ item: ScanView.RecognizedItem) -> Bool {
        let effectiveBrandId = item.preferredBrandId ?? inventoryManager.currentBrandId
        guard let brandId = effectiveBrandId else { return false }
        let available = inventoryManager.getStock(brandId: brandId, mardCode: item.colorCode)?.available ?? 0
        return (available - item.quantity) < 0
    }

    /// 缺豆项数量（按生效品牌算；切换后被解决的项不再算缺豆）
    private var shortageCount: Int {
        items.reduce(0) { $0 + (itemHasEffectiveShortage($1) ? 1 : 0) }
    }

    /// 已应用跨品牌建议的项数量
    private var overriddenCount: Int {
        items.reduce(0) { $0 + ($1.preferredBrandId != nil ? 1 : 0) }
    }

    /// 按筛选过滤
    private var visibleItems: [ScanView.RecognizedItem] {
        switch resultFilter {
        case .all:
            return sortedItems
        case .shortage:
            return sortedItems.filter { itemHasEffectiveShortage($0) }
        case .overridden:
            return sortedItems.filter { $0.preferredBrandId != nil }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题/筛选 chip 行
            HStack(spacing: 8) {
                Text("已识别 \(items.count) 项")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ColorToken.Text.primary)
                Spacer()
                BIChip(
                    "全部",
                    active: resultFilter == .all,
                    size: .sm
                )
                .onTapGesture { resultFilter = .all }
                if shortageCount > 0 {
                    BIChip(
                        "缺豆 \(shortageCount)",
                        active: resultFilter == .shortage,
                        color: Theme.ColorToken.Morandi.rose,
                        size: .sm
                    )
                    .onTapGesture { resultFilter = .shortage }
                }
                if overriddenCount > 0 {
                    BIChip(
                        "改品牌 \(overriddenCount)",
                        active: resultFilter == .overridden,
                        color: Theme.ColorToken.Morandi.honey,
                        size: .sm
                    )
                    .onTapGesture { resultFilter = .overridden }
                }
                if onClear != nil {
                    Button {
                        showingClearAlert = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.subheadline)
                            .foregroundStyle(Theme.ColorToken.Status.error)
                    }
                    .padding(.leading, 4)
                }
            }

            // 总量摘要
            Text("共 \(items.count) 色 / \(totalBeads) 颗")
                .font(.caption2)
                .foregroundStyle(Theme.ColorToken.Text.tertiary)

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
                            .background(sortOption == option ? Theme.ColorToken.Morandi.mauve : Theme.ColorToken.Surface.subtle)
                            .foregroundColor(sortOption == option ? .white : .primary)
                            .cornerRadius(Theme.Radius.md)
                        }
                    }
                }
            }

            // 结果列表 —— 直接 LazyVStack，外层 ScrollView 自然滚动。
            // 之前为了用 SwiftUI .swipeActions(edge:) 不得不包 List，引出"List 嵌在
            // ScrollView 里要手算高度"的反模式（写死 76/44，Dynamic Type / 长品牌名
            // / 英文翻译都能再触发裁切）。现在 SwipeActionRow 用 DragGesture 复刻了
            // swipe 揭示按钮，可放在任何容器，整套高度估算彻底删掉。
            LazyVStack(spacing: 8) {
                ForEach(visibleItems) { item in
                    RecognizedItemRowNew(
                        item: item,
                        inventoryManager: inventoryManager,
                        colorSystem: colorSystem,
                        onUpdate: { code, qty in
                            if let index = items.firstIndex(where: { $0.id == item.id }) {
                                var updatedItem = items[index]
                                let oldColorCode = updatedItem.colorCode
                                if let c = code {
                                    if colorSystem != .mard,
                                       let color = inventoryManager.findColor(byCode: c, preferSystem: colorSystem) {
                                        updatedItem.colorCode = color.mardCode
                                    } else {
                                        updatedItem.colorCode = c.uppercased()
                                    }
                                }
                                if let q = qty { updatedItem.quantity = q }
                                // colorCode 改了 → 之前选好的 preferredBrandId 是基于旧颜色的库存挑出来的，
                                // 对新颜色不一定还成立。直接清掉强制用户重选，避免把豆扣到错的品牌上。
                                if updatedItem.colorCode != oldColorCode {
                                    updatedItem.preferredBrandId = nil
                                }
                                items[index] = updatedItem
                            }
                        },
                        onRemove: {
                            items.removeAll { $0.id == item.id }
                        },
                        onApplyPreferredBrand: { brandId in
                            if let index = items.firstIndex(where: { $0.id == item.id }) {
                                items[index].preferredBrandId = brandId
                            }
                        }
                    )
                }
            }

            // 提示 pill
            HStack {
                Text("← 左滑任意一行可编辑、更换品牌或删除")
                    .font(.caption2)
                    .foregroundStyle(Theme.ColorToken.Text.tertiary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.ColorToken.Surface.subtle)
            )
        }
        .padding()
        .background(Theme.ColorToken.Surface.elevated)
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
    /// 设置该行的跨品牌偏好。传 brandId = 切到目标品牌；传 nil = 清除偏好回到主品牌。
    /// 触发点：缺豆建议行的「试试用 X」/「改回」按钮、左滑「改品牌」的 confirmationDialog、
    /// 长按 contextMenu 的「改用品牌」子菜单。
    var onApplyPreferredBrand: (UUID?) -> Void = { _ in }

    @Environment(\.tabFlavor) private var flavor
    @State private var isEditing = false
    @State private var editCode: String = ""
    @State private var editQuantity: String = ""
    @State private var showQuantityError = false
    @State private var showingBrandPicker = false

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

    /// 该行实际计算库存/缺口时所用的品牌：用户已应用推荐品牌时用推荐品牌，否则用当前主品牌。
    var effectiveBrandId: UUID? {
        item.preferredBrandId ?? inventoryManager.currentBrandId
    }

    // 计算当前库存和扣减后库存
    // isInsufficient: 库存不足（负数）
    // isLowStock: 低库存预警（低于阈值但非负）
    var stockInfo: (current: Int, after: Int, isInsufficient: Bool, isLowStock: Bool)? {
        guard let brandId = effectiveBrandId else { return nil }
        // BrandStock 记录缺失（用户改了色系 / 删了品牌 / 跨设备同步漂移）按 0 库存算。
        // 之前直接 return nil 会让行不显示任何 stock 指示，看起来"没问题"但下一页扣减
        // 直接缺豆，是典型的 missing-data masquerading as success。
        let current = inventoryManager.getStock(brandId: brandId, mardCode: item.colorCode)?.available ?? 0
        let after = current - item.quantity
        let isInsufficient = after < 0
        let isLowStock = !isInsufficient && after < lowStockThreshold
        return (current, after, isInsufficient, isLowStock)
    }

    /// 是否已通过缺豆建议切到了非主品牌（live：要求被指向的品牌仍存在）。
    /// 注意：直接看 `item.preferredBrandId != nil` 会把"指向已删除品牌"的 dangling
    /// 状态也算成已 override —— 表现为橙色蜂蜜边框 + 没库存信息 + 没徽章 + 没
    /// recommendation，用户摸不着头脑。通过看 overriddenBrand 来过滤 dangling，
    /// ScanView 级的 cleanupDanglingPreferredBrands 会同步把 preferredBrandId 清掉。
    var isBrandOverridden: Bool { overriddenBrand != nil }

    /// 已应用推荐品牌时，对应的 Brand
    var overriddenBrand: Brand? {
        guard let id = item.preferredBrandId else { return nil }
        return inventoryManager.brands.first(where: { $0.id == id })
    }

    /// 同色系下的所有可选品牌（含当前主品牌），按 sortOrder 排序。
    /// 给 contextMenu 的「改用品牌」子菜单使用 —— 不限缺豆，用户可以任意切换。
    var brandsForOverride: [Brand] {
        inventoryManager.brands
            .filter { $0.colorSystem == colorSystem }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// 当前色系下、非当前主品牌中、对该 mardCode 仍有库存的最佳替补品牌。
    /// 用于在还没应用推荐时显示"试试用 X"建议。
    /// 选择策略：库存可用量最大者；并列时取 sortOrder 较小（视为更优先）。
    var candidateBrand: (brand: Brand, available: Int)? {
        let currentId = inventoryManager.currentBrandId
        var best: (Brand, Int)? = nil
        for brand in inventoryManager.brands
        where brand.id != currentId && brand.colorSystem == colorSystem {
            guard let stock = inventoryManager.getStock(brandId: brand.id, mardCode: item.colorCode),
                  stock.available > 0 else { continue }
            if let current = best {
                if stock.available > current.1
                    || (stock.available == current.1 && brand.sortOrder < current.0.sortOrder) {
                    best = (brand, stock.available)
                }
            } else {
                best = (brand, stock.available)
            }
        }
        return best
    }

    /// 短缺：在 *当前生效品牌* 下缺豆数量为正
    var shortageDelta: Int? {
        guard let info = stockInfo, info.isInsufficient else { return nil }
        return -info.after
    }

    /// 仅看主品牌的缺口（用于判断"是否需要展示跨品牌建议行"，
    /// 哪怕用户已经切换、原始缺豆问题依然存在所以建议行也应当持续可见以便撤销）。
    /// 主品牌缺 BrandStock 记录按 0 库存算 —— 否则用户主品牌没库存数据但缺豆建议行
    /// 完全不弹，会让人摸不着头脑。
    var primaryShortageDelta: Int? {
        guard let primaryId = inventoryManager.currentBrandId else { return nil }
        let available = inventoryManager.getStock(brandId: primaryId, mardCode: item.colorCode)?.available ?? 0
        let after = available - item.quantity
        return after < 0 ? -after : nil
    }

    /// 是否要展示跨品牌建议行：1) 已应用推荐品牌（要给撤销入口）；或 2) 主品牌缺豆且能找到候选品牌
    var shouldShowRecommendation: Bool {
        if isBrandOverridden { return true }
        return primaryShortageDelta != nil && candidateBrand != nil
    }

    private var borderColor: Color {
        if shortageDelta != nil { return Theme.ColorToken.Morandi.rose }
        if isBrandOverridden { return Theme.ColorToken.Morandi.honey }
        return Theme.ColorToken.Border.default
    }

    private var leftEdgeColor: Color? {
        if shortageDelta != nil { return Theme.ColorToken.Morandi.rose }
        if isBrandOverridden { return Theme.ColorToken.Morandi.honey }
        return nil
    }

    var body: some View {
        SwipeActionRow(
            actions: [
                SwipeActionItem(
                    "编辑",
                    systemImage: "pencil",
                    tint: Theme.ColorToken.Morandi.mauve
                ) {
                    editCode = matchedColor?.displayCode(for: colorSystem) ?? item.colorCode
                    editQuantity = "\(item.quantity)"
                    isEditing = true
                },
                // 「改品牌」：不限缺豆场景，任何颜色都能切到同色系下的其他品牌。
                // handler 只翻 state，真正的选择走下面的 confirmationDialog。
                SwipeActionItem(
                    "更换品牌",
                    systemImage: "arrow.left.arrow.right",
                    tint: Theme.ColorToken.Morandi.honey
                ) {
                    showingBrandPicker = true
                },
                SwipeActionItem(
                    "删除",
                    systemImage: "trash",
                    tint: Theme.ColorToken.Morandi.rose,
                    role: .destructive
                ) {
                    onRemove()
                }
            ]
        ) {
            VStack(alignment: .leading, spacing: 0) {
                mainRow
                if shouldShowRecommendation {
                    recommendationRow
                }
            }
            .padding(0)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Theme.ColorToken.Surface.elevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(borderColor, lineWidth: 1)
            )
            .overlay(alignment: .leading) {
                if let edgeColor = leftEdgeColor {
                    Rectangle()
                        .fill(edgeColor)
                        .frame(width: 3)
                        .clipShape(
                            RoundedRectangle(cornerRadius: 2)
                        )
                        .padding(.vertical, 4)
                }
            }
            // contextMenu 必须挂在卡片本体上而不是 SwipeActionRow 外层 ——
            // 外层的 simultaneousGesture(DragGesture) 会和 contextMenu 的长按
            // 识别冲突、把长按手势吃掉（实测在 iPhone 17 Pro Max sim 上 2.5s
            // 长按都不弹），把 contextMenu 移到内层 VStack 上分离两个手势作用
            // 域之后就正常了。
            .contextMenu {
                Button {
                    editCode = matchedColor?.displayCode(for: colorSystem) ?? item.colorCode
                    editQuantity = "\(item.quantity)"
                    isEditing = true
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
                // 任意颜色都能改品牌（不限缺豆场景）。子菜单列出同色系所有品牌 +
                // 各自该色号的库存量，当前生效品牌前缀打勾。
                // 选当前主品牌 = 清掉 override；选其他品牌 = 设 override。
                Menu {
                    if isBrandOverridden {
                        Button {
                            onApplyPreferredBrand(nil)
                        } label: {
                            Label("切换回主品牌", systemImage: "arrow.uturn.backward")
                        }
                        Divider()
                    }
                    ForEach(brandsForOverride) { brand in
                        let stock = inventoryManager.getStock(brandId: brand.id, mardCode: item.colorCode)?.available ?? 0
                        let isCurrent = brand.id == (item.preferredBrandId ?? inventoryManager.currentBrandId)
                        Button {
                            if brand.id == inventoryManager.currentBrandId {
                                onApplyPreferredBrand(nil)
                            } else {
                                onApplyPreferredBrand(brand.id)
                            }
                        } label: {
                            if isCurrent {
                                Label("\(brand.name) · 库存 \(stock)", systemImage: "checkmark")
                            } else {
                                Text("\(brand.name) · 库存 \(stock)")
                            }
                        }
                    }
                } label: {
                    Label("改用品牌", systemImage: "arrow.left.arrow.right")
                }
                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
        // 左滑的「改品牌」按钮触发的选择器。同色系所有品牌 + 各自该色号库存量。
        // 用 confirmationDialog 是因为它原生支持「按钮列表 + 取消」这种半屏 UI，
        // 而且自带 destructive/cancel 角色样式，不用自己撸 Sheet。
        .confirmationDialog(
            brandPickerTitle,
            isPresented: $showingBrandPicker,
            titleVisibility: .visible
        ) {
            ForEach(brandsForOverride) { brand in
                let stock = inventoryManager.getStock(brandId: brand.id, mardCode: item.colorCode)?.available ?? 0
                let isCurrent = brand.id == (item.preferredBrandId ?? inventoryManager.currentBrandId)
                Button {
                    if brand.id == inventoryManager.currentBrandId {
                        onApplyPreferredBrand(nil)
                    } else {
                        onApplyPreferredBrand(brand.id)
                    }
                } label: {
                    // confirmationDialog 的 Button label 在 iOS 上只取 Text，
                    // 用 ✓ 前缀直观标出当前生效品牌。
                    Text(isCurrent ? "✓ \(brand.name) · 库存 \(stock)" : "\(brand.name) · 库存 \(stock)")
                }
            }
            if isBrandOverridden {
                Button("切换回主品牌", role: .destructive) {
                    onApplyPreferredBrand(nil)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(brandPickerMessage)
        }
    }

    /// confirmationDialog 标题：色号
    private var brandPickerTitle: String {
        let code = matchedColor?.displayCode(for: colorSystem) ?? item.colorCode
        return String(localized: "更换品牌 · \(code)")
    }

    /// confirmationDialog 副标题：数量
    private var brandPickerMessage: String {
        String(localized: "本图需要 \(item.quantity) 颗")
    }

    @ViewBuilder
    private var mainRow: some View {
        HStack(spacing: 12) {
            // 颜色珠子
            if let color = matchedColor {
                BeadView(color: color.color, size: 32)
            } else {
                ZStack {
                    Circle()
                        .fill(Theme.ColorToken.Surface.subtle)
                        .frame(width: 32, height: 32)
                    Image(systemName: "questionmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                }
            }

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
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.ColorToken.Text.primary)

                    stockLine
                }

                Spacer()

                qtyChip
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var stockLine: some View {
        if matchedColor == nil {
            Text("未匹配")
                .font(.caption2)
                .foregroundStyle(Theme.ColorToken.Status.warning)
        } else if let delta = shortageDelta, let info = stockInfo {
            // 主品牌或已切换品牌仍缺豆：前缀带上品牌名（仅在 override 状态下），并保留 error 色
            let prefix = overriddenBrand.map { "\($0.name) " } ?? ""
            Text("\(prefix)缺\(delta)颗 · 库存仅\(info.current)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.Status.error)
        } else if let info = stockInfo {
            HStack(spacing: 4) {
                let prefix = overriddenBrand.map { "\($0.name) " } ?? ""
                Text("\(prefix)库存 \(info.current) → \(info.after)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                if info.isLowStock {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(Theme.ColorToken.Status.warning)
                }
            }
        }
    }

    @ViewBuilder
    private var qtyChip: some View {
        VStack(alignment: .trailing, spacing: 4) {
            VStack(spacing: 0) {
                Text("\(item.quantity)")
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.ColorToken.Text.primary)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Theme.ColorToken.Surface.subtle)
                    )
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Theme.ColorToken.Border.default)
                            .frame(height: 2)
                            .padding(.horizontal, 2)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            if let brand = overriddenBrand {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 9, weight: .bold))
                    Text(brand.name)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(Theme.ColorToken.Text.onAccent)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(Theme.ColorToken.Fill.honey)
                )
            }
        }
    }

    /// 跨品牌建议 / 已切换状态行。
    /// - 未切换 + 主品牌缺豆 + 有候选品牌：「✨ 试试用 [品牌] · 可补 N / M 颗 →」 点击 = 应用
    /// - 已切换：「✓ 已切换为 [品牌] · 已补 X 颗」 + 「改回主品牌」 点击 = 撤销
    @ViewBuilder
    private var recommendationRow: some View {
        VStack(spacing: 0) {
            // dashed 顶部分隔
            Rectangle()
                .fill(Color.clear)
                .frame(height: 1)
                .overlay(
                    Rectangle()
                        .strokeBorder(
                            Theme.ColorToken.Border.divider,
                            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                        )
                )
            if isBrandOverridden, let brand = overriddenBrand {
                appliedRecommendationContent(brand: brand)
            } else if let cand = candidateBrand, let shortage = primaryShortageDelta {
                suggestRecommendationContent(brand: cand.brand, available: cand.available, shortage: shortage)
            }
        }
    }

    @ViewBuilder
    private func suggestRecommendationContent(brand: Brand, available: Int, shortage: Int) -> some View {
        let covered = min(available, shortage)
        let fullyCovers = covered >= shortage
        Button {
            onApplyPreferredBrand(brand.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(Theme.ColorToken.Morandi.honey)
                Text("改用")
                    .font(.caption2)
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                Text(brand.name)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.ColorToken.Text.onAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.ColorToken.Fill.honey))
                    .lineLimit(1)
                Text(fullyCovers ? "可补足 \(shortage) 颗" : "可补 \(covered) / \(shortage) 颗")
                    .font(.caption2)
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(Theme.ColorToken.Text.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func appliedRecommendationContent(brand: Brand) -> some View {
        // 切换后的状态：已用 = min(quantity, 该品牌该色库存)
        let appliedAvailable: Int = {
            guard let stock = inventoryManager.getStock(brandId: brand.id, mardCode: item.colorCode) else { return 0 }
            return stock.available
        }()
        let coveredNow = min(appliedAvailable, item.quantity)
        let stillShortAfter = max(0, item.quantity - appliedAvailable)
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Theme.ColorToken.Morandi.honey)
            Text("已切换为")
                .font(.caption2)
                .foregroundStyle(Theme.ColorToken.Text.secondary)
            Text(brand.name)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.ColorToken.Text.onAccent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Theme.ColorToken.Fill.honey))
                .lineLimit(1)
            if stillShortAfter > 0 {
                Text("已补 \(coveredNow) · 仍差 \(stillShortAfter)")
                    .font(.caption2)
                    .foregroundStyle(Theme.ColorToken.Status.error)
            } else {
                Text("已补足 \(coveredNow) 颗")
                    .font(.caption2)
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
            }
            Spacer()
            Button {
                onApplyPreferredBrand(nil)
            } label: {
                Text("改回")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.ColorToken.Morandi.mauve)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
            .background(Theme.ColorToken.Surface.background)
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
                                    .background(Theme.ColorToken.Fill.mauve, in: Capsule())
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
                            .background(selectedSeries == s ? Theme.ColorToken.Morandi.mauve : Theme.ColorToken.Surface.subtle)
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
                        .stroke(isSelected ? Theme.ColorToken.Morandi.mauve : Theme.ColorToken.Border.default, lineWidth: 2)
                        .frame(width: 28, height: 28)

                    if isSelected {
                        Circle()
                            .fill(Theme.ColorToken.Morandi.mauve)
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
        .background(Theme.ColorToken.Surface.elevated)
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
                    .background(Theme.ColorToken.Fill.mauve)
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
                Text("封面")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()

                // 上传新封面按钮
                PhotosPicker(selection: $selectedPhotoItem, matching: .images,
                             preferredItemEncoding: .current) {
                    HStack(spacing: 4) {
                        Image(systemName: "photo.badge.plus")
                        Text(thumbnailImage == nil ? "上传封面" : "更换")
                    }
                    .font(.caption)
                    .foregroundColor(Theme.ColorToken.Morandi.mauve)
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
                        .foregroundColor(Theme.ColorToken.Morandi.mauve)
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
                        Text("列表中显示的即为此图")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        // 用户报障的根子就是把这两件事当成了一件：他在这里裁了一刀，
                        // 以为只动了列表上的小图，结果拼图模式要拼的那张也跟着变了。
                        //
                        // **只在真的传过图纸时才说这句话。** 手动加色号那条路上传进来的
                        // 封面就是唯一的图，`patternSourceData()` 最后一行会把它当图纸存 ——
                        // 那种情况下这句安抚话恰好是反的。
                        if originalImage != nil {
                            Text("裁切或换一张都不影响拼图模式用的图纸")
                                .font(.caption2)
                                .foregroundColor(.secondary.opacity(0.7))
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("此项目没有单独的图纸原图，拼图模式将直接使用此封面")
                                .font(.caption2)
                                .foregroundColor(.secondary.opacity(0.7))
                                .fixedSize(horizontal: false, vertical: true)
                        }
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
                        Text("暂无封面")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("未添加时列表将显示占位图")
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.7))
                    }

                    Spacer()
                }
            }
        }
        .padding()
        .background(Theme.ColorToken.Surface.elevated)
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
                        .background(Theme.ColorToken.Fill.mauve)
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
                            Text("1. 在设置中配置云端 API（填写 API Key）")
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
                            Text("上方为「表格」，下方为「色号统计」")
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
                        .background(Theme.ColorToken.Fill.mauve)
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
            .background(Theme.ColorToken.Surface.elevated)
        }
        .presentationDetents([.large])
    }
}

// MARK: - 莫兰迪风步骤指示器卡片
struct ScanStepIndicatorCard: View {
    let currentIndex: Int
    private let steps: [String] = ["上传图纸", "识别调整", "扣减执行"]

    @Environment(\.tabFlavor) private var flavor

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { idx, label in
                stepCell(idx: idx, label: label)
                if idx < steps.count - 1 {
                    Rectangle()
                        .fill(idx < currentIndex ? Theme.ColorToken.Status.success : Theme.ColorToken.Border.default)
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 16) // 与圆圈中心对齐（label 在下方）
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.ColorToken.Surface.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
        )
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func stepCell(idx: Int, label: String) -> some View {
        VStack(spacing: 6) {
            ZStack {
                if idx == currentIndex {
                    Circle()
                        .stroke(flavor.color.opacity(0.35), lineWidth: 3)
                        .frame(width: 28, height: 28)
                }
                Circle()
                    .fill(circleFill(idx: idx))
                    .frame(width: 22, height: 22)
                if idx < currentIndex {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.ColorToken.Text.onAccent)
                } else {
                    Text("\(idx + 1)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(circleTextColor(idx: idx))
                }
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(idx <= currentIndex ? Theme.ColorToken.Text.primary : Theme.ColorToken.Text.tertiary)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func circleFill(idx: Int) -> Color {
        if idx < currentIndex { return Theme.ColorToken.Status.success }
        if idx == currentIndex { return flavor.color }
        return Theme.ColorToken.Surface.subtle
    }

    private func circleTextColor(idx: Int) -> Color {
        if idx == currentIndex { return Theme.ColorToken.Text.onAccent }
        return Theme.ColorToken.Text.tertiary
    }
}

// MARK: - 识别结果筛选状态
enum RecognizedResultsFilter: Hashable {
    case all, shortage, overridden
}

// MARK: - 莫兰迪风底部 CTA 条
struct ScanBottomCTABar: View {
    let totalBeads: Int
    let canDeduct: Bool
    let onPlan: () -> Void
    let onDeduct: () -> Void

    @Environment(\.tabFlavor) private var flavor

    var body: some View {
        HStack(spacing: 12) {
            // 存为计划（outlined）
            Button(action: onPlan) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar.badge.plus")
                    Text("存为计划")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ColorToken.Text.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Theme.ColorToken.Surface.elevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
                )
            }

            // 扣减 N 颗（filled mauve）
            Button(action: onDeduct) {
                HStack(spacing: 6) {
                    Image(systemName: "minus.circle.fill")
                    Text("扣减 \(totalBeads) 颗")
                }
                .font(.headline)
                .foregroundStyle(Theme.ColorToken.Text.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(canDeduct ? flavor.fill : Theme.ColorToken.Border.default)
                )
                .shadow(color: Theme.ColorToken.Shadow.soft, radius: 4, x: 0, y: 2)
            }
            .disabled(!canDeduct)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .background(.bar)
    }
}

#Preview {
    ScanView()
        .environmentObject(InventoryManager())
}
