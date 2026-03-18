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
    @ObservedObject private var localModelManager = LocalModelManager.shared

    /// 从外部传入的图片（如 Share Extension）
    @Binding var externalImage: UIImage?

    @State private var selectedImage: UIImage?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var showingManualEntry = false
    @State private var showingConfirmation = false
    @State private var showingCropView = false
    @State private var projectName = ""
    @State private var isLoadingImage = false
    @State private var isRecognizing = false
    @State private var recognizedItems: [RecognizedItem] = []
    @State private var errorMessage: String?
    @State private var showingCreatePlan = false

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

    /// 检查扣除后库存会变为负数的颜色
    var insufficientStockItems: [(colorCode: String, currentStock: Int, deductAmount: Int)] {
        guard let brandId = inventoryManager.currentBrandId else { return [] }
        var result: [(colorCode: String, currentStock: Int, deductAmount: Int)] = []
        for item in recognizedItems {
            let stock = inventoryManager.getStock(brandId: brandId, mardCode: item.colorCode)
            let currentStock = stock?.available ?? 0
            if currentStock < item.quantity {
                // 显示当前扫描色号体系的色号（而非内部 mardCode）
                let displayCode = inventoryManager.findColor(byCode: item.colorCode)?.displayCode(for: scanColorSystem) ?? item.colorCode
                result.append((colorCode: displayCode, currentStock: currentStock, deductAmount: item.quantity))
            }
        }
        return result
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
                                    hasRecognizedItems: !recognizedItems.isEmpty
                                )
                            }

                            // AI 配置状态提示
                            if !aiService.isConfigured {
                                HStack {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange)
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
                                .background(Color.orange.opacity(0.1))
                                .cornerRadius(8)
                                .padding(.horizontal)
                            } else if aiService.config.backend == .local {
                                HStack(alignment: .top) {
                                    Image(systemName: "iphone.gen3")
                                        .foregroundColor(.blue)
                                    Text("当前使用 \(aiService.config.localModel.displayName) 本地识别。无需 API，但速度相对更慢，也可能引起发热。")
                                        .font(.caption)
                                    Spacer()
                                }
                                .padding()
                                .background(Color.blue.opacity(0.08))
                                .cornerRadius(8)
                                .padding(.horizontal)
                            }

                            // 色号体系选择（独立于品牌，影响 AI 提示词和计划绑定）
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

                            // 识别按钮
                            if selectedImage != nil {
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
                                        .background(aiService.isConfigured ? Color.accentColor : Color.gray)
                                        .foregroundColor(.white)
                                        .cornerRadius(12)
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
                                        .background(aiService.isConfigured ? Color.orange : Color.gray)
                                        .foregroundColor(.white)
                                        .cornerRadius(12)
                                    }
                                    .disabled(isRecognizing || !aiService.isConfigured)
                                }
                                .padding(.horizontal)
                            }

                            // 错误提示
                            if let error = errorMessage {
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(.red)
                                    .padding()
                                    .background(Color.red.opacity(0.1))
                                    .cornerRadius(8)
                                    .padding(.horizontal)
                            }

                            // 备扣品牌显示（仅显示与当前色号体系匹配的品牌）
                            if !recognizedItems.isEmpty {
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
                                            .foregroundColor(.orange)
                                    }
                                    Spacer()
                                    BrandPicker(colorSystemFilter: scanColorSystem)
                                }
                                .font(.subheadline)
                                .padding(.horizontal)
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

                            // 确认操作按钮区域
                            if !recognizedItems.isEmpty {
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

                                    // 两个操作按钮
                                    HStack(spacing: 12) {
                                        // 创建计划按钮（不需要选择品牌）
                                        Button {
                                            showingCreatePlan = true
                                        } label: {
                                            HStack {
                                                Image(systemName: "calendar.badge.plus")
                                                Text("创建计划")
                                            }
                                            .font(.headline)
                                            .frame(maxWidth: .infinity)
                                            .padding()
                                            .background(Color.orange)
                                            .foregroundColor(.white)
                                            .cornerRadius(12)
                                        }

                                        // 扣减库存按钮（需要选择匹配色系的品牌）
                                        Button {
                                            showingConfirmation = true
                                        } label: {
                                            HStack {
                                                Image(systemName: insufficientStockItems.isEmpty ? "minus.circle.fill" : "exclamationmark.triangle.fill")
                                                Text("扣减库存")
                                            }
                                            .font(.headline)
                                            .frame(maxWidth: .infinity)
                                            .padding()
                                            .background(brandMatchesScanSystem ? (insufficientStockItems.isEmpty ? Color.green : Color.red) : Color.gray)
                                            .foregroundColor(.white)
                                            .cornerRadius(12)
                                        }
                                        .disabled(!brandMatchesScanSystem)
                                    }
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
            .sheet(isPresented: $showingCamera) {
                CameraPicker(image: $selectedImage)
            }
            .onChange(of: selectedPhotoItem) { _, newItem in
                guard let newItem = newItem else { return }
                isLoadingImage = true
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        await MainActor.run {
                            selectedImage = image
                            // 保存原图作为缩略图来源
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
            .onChange(of: selectedImage) { _, newImage in
                // 当从相机获取图片时，也设置原图和缩略图
                if let image = newImage, originalImage == nil {
                    originalImage = image
                    thumbnailImage = image
                }
            }
            // 监听从 Share Extension 传入的外部图片
            .onChange(of: externalImage) { _, newImage in
                if let image = newImage {
                    // 清除之前的状态
                    clearState()
                    // 设置新图片
                    selectedImage = image
                    originalImage = image
                    thumbnailImage = image
                    // 清除外部图片引用
                    externalImage = nil
                }
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
                // 优先使用当前缩略图（可能是用户上传的新图片），否则使用原始图
                if let image = thumbnailImage ?? originalImage {
                    ImageCropView(image: image) { croppedImage in
                        thumbnailImage = croppedImage
                    }
                } else {
                    Color.black.onAppear { showingThumbnailCrop = false }
                }
            }
            .alert("确认扣减", isPresented: $showingConfirmation) {
                Button("取消", role: .cancel) { }
                Button("确认扣减", role: insufficientStockItems.isEmpty ? .none : .destructive) {
                    applyToInventory()
                }
            } message: {
                if insufficientStockItems.isEmpty {
                    Text("将从库存中扣减 \(totalBeads) 颗豆子，共 \(recognizedItems.count) 种颜色。")
                } else {
                    Text("将从库存中扣减 \(totalBeads) 颗豆子，共 \(recognizedItems.count) 种颜色。\n\n⚠️ 以下 \(insufficientStockItems.count) 种颜色扣除后库存将为负数：\n\(insufficientStockItems.map { "\($0.colorCode): \($0.currentStock) - \($0.deductAmount) = \($0.currentStock - $0.deductAmount)" }.joined(separator: "\n"))")
                }
            }
            .alert("创建计划", isPresented: $showingCreatePlan) {
                Button("取消", role: .cancel) { }
                Button("确认") {
                    createPlannedProject()
                }
            } message: {
                Text("将创建包含 \(totalBeads) 颗豆子（\(recognizedItems.count) 种颜色）的计划项目。执行时需要选择品牌。")
            }
            // 引导弹窗
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
                // 从设置中读取默认色号体系
                scanColorSystem = ColorSystem(rawValue: defaultColorSystemRaw) ?? .mard
                // 首次打开时显示引导弹窗
                if !helpHasBeenDismissed {
                    showingHelpSheet = true
                }
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
                        if colorSystem != .mard,
                           let color = inventoryManager.findColor(byCode: item.colorCode, preferSystem: colorSystem) {
                            return RecognizedItem(colorCode: color.mardCode, quantity: item.quantity)
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

    func applyToInventory() {
        guard let brandId = inventoryManager.currentBrandId,
              brandMatchesScanSystem else { return }

        // 生成压缩的缩略图数据
        let thumbnailData = generateThumbnailData()

        // 创建项目记录
        let beadUsages = recognizedItems.map { item in
            BeadUsage(colorCode: item.colorCode, brandId: brandId, quantity: item.quantity, isDeducted: true)
        }
        let project = ProjectRecord(
            name: projectName.isEmpty ? "图纸\(Date().formatted(date: .numeric, time: .omitted))" : projectName,
            beadUsage: beadUsages,
            brandId: brandId,
            thumbnail: thumbnailData,
            colorSystem: scanColorSystem
        )
        inventoryManager.addProject(project)

        // 从当前品牌库存扣减（批量操作，不逐个保存）
        for item in recognizedItems {
            _ = inventoryManager.deductFromStock(brandId: brandId, colorCode: item.colorCode, amount: item.quantity, shouldSave: false)
        }
        // 统一保存
        inventoryManager.saveData()

        // 清除结果
        clearState()
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

    /// 生成压缩的缩略图数据（最大200x200像素，JPEG压缩）
    func generateThumbnailData() -> Data? {
        guard let image = thumbnailImage else { return nil }

        // 计算缩放后的尺寸（最大200x200）
        let maxSize: CGFloat = 200
        let scale = min(maxSize / image.size.width, maxSize / image.size.height, 1.0)
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        // 绘制缩略图
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        // 压缩为JPEG（质量0.6）
        return resizedImage?.jpegData(compressionQuality: 0.6)
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

    func removeItem(id: UUID) {
        recognizedItems.removeAll { $0.id == id }
    }

    func updateItem(id: UUID, colorCode: String?, quantity: Int?) {
        if let index = recognizedItems.firstIndex(where: { $0.id == id }) {
            if let code = colorCode {
                recognizedItems[index].colorCode = code.uppercased()
            }
            if let qty = quantity {
                recognizedItems[index].quantity = qty
            }
        }
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
                .cornerRadius(16)
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
                                .cornerRadius(10)
                        }

                        Button {
                            showingCamera = true
                        } label: {
                            Label("拍照", systemImage: "camera")
                                .font(.subheadline)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                                .background(Color.orange)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .background(Color(.systemBackground))
                .cornerRadius(16)
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
        GeometryReader { geometry in
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: geometry.size.width, height: maxHeight)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .shadow(radius: shadowRadius)
        }
        .frame(height: maxHeight)
    }
}

// MARK: - 识别结果区域
struct RecognizedResultsSection: View {
    @ObservedObject var ocrManager: OCRManager
    let totalBeads: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("识别结果")
                    .font(.headline)
                Spacer()
                Text("共 \(ocrManager.recognizedItems.count) 色 / \(totalBeads) 颗")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ForEach(ocrManager.recognizedItems) { item in
                RecognizedItemRow(item: item, ocrManager: ocrManager)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .padding(.horizontal)
    }
}

struct RecognizedItemRow: View {
    let item: OCRManager.RecognizedBeadItem
    @ObservedObject var ocrManager: OCRManager
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var isEditing = false
    @State private var editCode: String = ""
    @State private var editQuantity: String = ""

    var matchedColor: BeadColor? {
        inventoryManager.findColor(byCode: item.colorCode)
    }

    var body: some View {
        HStack(spacing: 12) {
            // 颜色预览
            if let color = matchedColor {
                RoundedRectangle(cornerRadius: 6)
                    .fill(color.color)
                    .frame(width: 36, height: 36)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Image(systemName: "questionmark")
                            .foregroundColor(.gray)
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

                Button("保存") {
                    if let qty = Int(editQuantity) {
                        ocrManager.updateItem(id: item.id, colorCode: editCode, quantity: qty)
                    }
                    isEditing = false
                }
                .font(.caption)
            } else {
                VStack(alignment: .leading) {
                    Text(item.colorCode)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)

                    if matchedColor == nil {
                        Text("未匹配")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }

                Spacer()

                Text("×\(item.quantity)")
                    .font(.headline)
                    .foregroundColor(.accentColor)

                // 操作按钮
                Menu {
                    Button {
                        editCode = item.colorCode
                        editQuantity = "\(item.quantity)"
                        isEditing = true
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }

                    Button(role: .destructive) {
                        ocrManager.removeItem(id: item.id)
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
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }
}

// MARK: - 手动添加弹窗
struct ManualEntrySheet: View {
    @ObservedObject var ocrManager: OCRManager
    @Environment(\.dismiss) var dismiss

    @State private var colorCode = ""
    @State private var quantity = ""
    @State private var selectedBrand = "MARD"

    let brands = ["MARD", "vivid", "漫漫", "卡卡"]

    var body: some View {
        NavigationStack {
            Form {
                Section("色号信息") {
                    Picker("品牌", selection: $selectedBrand) {
                        ForEach(brands, id: \.self) { brand in
                            Text(brand).tag(brand)
                        }
                    }

                    TextField("色号", text: $colorCode)
                        .textInputAutocapitalization(.characters)

                    TextField("数量", text: $quantity)
                        .keyboardType(.asciiCapableNumberPad)
                }

                Section {
                    Button {
                        addItem()
                    } label: {
                        HStack {
                            Spacer()
                            Text("添加")
                                .fontWeight(.medium)
                            Spacer()
                        }
                    }
                    .disabled(colorCode.isEmpty || quantity.isEmpty)
                }
            }
            .navigationTitle("手动添加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    func addItem() {
        guard let qty = Int(quantity), qty > 0 else { return }
        ocrManager.addItem(colorCode: colorCode, quantity: qty, brand: selectedBrand)
        colorCode = ""
        quantity = ""
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
                let code0 = inventoryManager.findColor(byCode: $0.colorCode)?.displayCode(for: colorSystem) ?? $0.colorCode
                let code1 = inventoryManager.findColor(byCode: $1.colorCode)?.displayCode(for: colorSystem) ?? $1.colorCode
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
                            .foregroundColor(.red)
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
                                Text(option.rawValue)
                                if sortOption == option && option != .original {
                                    Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                                        .font(.caption2)
                                }
                            }
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(sortOption == option ? Color.accentColor : Color(.systemGray5))
                            .foregroundColor(sortOption == option ? .white : .primary)
                            .cornerRadius(12)
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
                            if let c = code {
                                // 非 MARD 色系时，用户输入的可能是该色系的色号，需转为内部 mardCode
                                if colorSystem != .mard,
                                   let color = inventoryManager.findColor(byCode: c, preferSystem: colorSystem) {
                                    items[index].colorCode = color.mardCode
                                } else {
                                    items[index].colorCode = c.uppercased()
                                }
                            }
                            if let q = qty { items[index].quantity = q }
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
        .cornerRadius(16)
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

    var matchedColor: BeadColor? {
        inventoryManager.findColor(byCode: item.colorCode)
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
                RoundedRectangle(cornerRadius: 6)
                    .fill(color.color)
                    .frame(width: 36, height: 36)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Image(systemName: "questionmark")
                            .foregroundColor(.gray)
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

                Button("保存") {
                    onUpdate(editCode.isEmpty ? nil : editCode, Int(editQuantity))
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
                            .foregroundColor(.orange)
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
                                    .foregroundColor(.red)
                            } else if info.isLowStock {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
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
        .background(stockInfo?.isInsufficient == true ? Color.red.opacity(0.1) : Color(.systemGray6))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(stockInfo?.isInsufficient == true ? Color.red.opacity(0.3) : Color.clear, lineWidth: 1)
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
    @State private var selectedColors: Set<UUID> = []
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
        for colorId in selectedColors {
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
                                isSelected: selectedColors.contains(color.id),
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

                // 底部确认栏
                if !selectedColors.isEmpty {
                    ManualEntryConfirmBar(
                        selectedCount: selectedColors.count,
                        totalQuantity: totalToAdd,
                        onConfirm: confirmAdd
                    )
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("编辑颜色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !selectedColors.isEmpty {
                        Button("清空") {
                            selectedColors.removeAll()
                            quantities.removeAll()
                        }
                        .foregroundColor(.red)
                    }
                }
            }
            .onAppear {
                selectedSeries = colorSystem.defaultSeries
                initializeFromRecognizedItems()
            }
        }
    }

    /// 从已有的识别结果初始化选择状态
    func initializeFromRecognizedItems() {
        guard !isInitialized else { return }
        isInitialized = true

        for item in recognizedItems {
            // 根据色号找到对应的颜色（包括自定义色号，兼容旧 C_ 前缀）
            if let color = inventoryManager.findColor(byCode: item.colorCode) {
                selectedColors.insert(color.id)
                quantities[color.id] = item.quantity
            }
        }
    }

    func toggleSelection(_ colorId: UUID) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if selectedColors.contains(colorId) {
                selectedColors.remove(colorId)
                quantities.removeValue(forKey: colorId)
            } else {
                selectedColors.insert(colorId)
                if quantities[colorId] == nil {
                    quantities[colorId] = 1
                }
            }
        }
    }

    func confirmAdd() {
        // 用新的选择替换原来的 recognizedItems
        var newItems: [ScanView.RecognizedItem] = []
        for colorId in selectedColors {
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
                        Text(s)
                            .font(.system(.subheadline, design: .rounded))
                            .fontWeight(.medium)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(selectedSeries == s ? Color.accentColor : Color(.systemGray5))
                            .foregroundColor(selectedSeries == s ? .white : .primary)
                            .cornerRadius(20)
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
                        .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: 2)
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
            RoundedRectangle(cornerRadius: 6)
                .fill(color.color)
                .frame(width: 40, height: 40)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
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
        .cornerRadius(12)
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
                    .background(quantity > 1 ? Color.gray.opacity(0.6) : Color.gray.opacity(0.3))
                    .cornerRadius(14)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(quantity <= 1)

            // 数量输入框
            TextField("", text: $editText)
                .keyboardType(.asciiCapableNumberPad)
                .multilineTextAlignment(.center)
                .font(.system(size: 16, weight: .regular, design: .monospaced))
                .frame(width: 60, height: 32)
                .background(Color(.systemGray6))
                .cornerRadius(8)
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
                    .cornerRadius(14)
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
                        .foregroundColor(.red)
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
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
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
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 80, height: 80)
                        .overlay(
                            Image(systemName: "photo.badge.plus")
                                .font(.title2)
                                .foregroundColor(.gray)
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
        .cornerRadius(12)
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

// MARK: - 手动添加确认栏（多选模式）
struct ManualEntryConfirmBar: View {
    let selectedCount: Int
    let totalQuantity: Int
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("已选择 \(selectedCount) 色")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("共 \(totalQuantity) 颗")
                        .font(.headline)
                        .foregroundColor(.accentColor)
                }

                Spacer()

                Button(action: onConfirm) {
                    Text("添加")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                        .background(Color.accentColor)
                        .cornerRadius(24)
                }
            }
            .padding()
            .background(Color(.systemBackground))
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
                .cornerRadius(12)
                .padding(.horizontal, 20)

            // 尺寸信息
            Text("尺寸: \(Int(croppedImage.size.width)) × \(Int(croppedImage.size.height))")
                .font(.caption)
                .foregroundColor(.gray)

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
                        .background(Color.gray.opacity(0.3))
                        .foregroundColor(.white)
                        .cornerRadius(12)
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
                        .cornerRadius(12)
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
                            Text("1. 先选择识别方式：可下载本地模型，也可配置云端 API")
                            Text("2. 裁切图纸，请只保留图纸下方豆量汇总")
                            Text("3. 扫描")
                        }
                        .font(.body)
                        .padding(.horizontal, 20)

                        Image("HelpNew1")
                            .resizable()
                            .scaledToFit()
                            .cornerRadius(12)
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
                            .cornerRadius(12)
                            .padding(.horizontal, 20)

                        Image("HelpNew3")
                            .resizable()
                            .scaledToFit()
                            .cornerRadius(12)
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
                        .cornerRadius(12)
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
