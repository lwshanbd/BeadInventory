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
    @EnvironmentObject var inventoryManager: InventoryManager
    @StateObject private var aiService = AIServiceManager()

    @State private var selectedImage: UIImage?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var showingManualEntry = false
    @State private var showingConfirmation = false
    @State private var projectName = ""
    @State private var isLoadingImage = false
    @State private var isRecognizing = false
    @State private var recognizedItems: [RecognizedItem] = []
    @State private var errorMessage: String?

    // 识别结果项
    struct RecognizedItem: Identifiable {
        let id = UUID()
        var colorCode: String
        var quantity: Int
    }

    var totalBeads: Int {
        recognizedItems.reduce(0) { $0 + $1.quantity }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // 图片选择区域
                    ImageSelectionSection(
                        selectedImage: $selectedImage,
                        selectedPhotoItem: $selectedPhotoItem,
                        showingCamera: $showingCamera,
                        isLoadingImage: $isLoadingImage
                    )

                    // AI 配置状态提示
                    if !aiService.isConfigured {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("请先在设置中配置 AI API")
                                .font(.caption)
                            Spacer()
                            NavigationLink("去设置") {
                                AISettingsView(aiService: aiService)
                            }
                            .font(.caption)
                        }
                        .padding()
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(8)
                        .padding(.horizontal)
                    }

                    // 识别按钮
                    if selectedImage != nil {
                        Button {
                            recognizeImage()
                        } label: {
                            HStack {
                                if isRecognizing {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "sparkles")
                                }
                                Text(isRecognizing ? "AI 识别中..." : "AI 识别")
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(aiService.isConfigured ? Color.accentColor : Color.gray)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                        .disabled(isRecognizing || !aiService.isConfigured)
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

                    // 识别结果
                    if !recognizedItems.isEmpty {
                        RecognizedResultsSectionNew(
                            items: $recognizedItems,
                            totalBeads: totalBeads,
                            inventoryManager: inventoryManager
                        )
                    }

                    // 手动添加按钮
                    Button {
                        showingManualEntry = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle")
                            Text("手动添加")
                        }
                        .font(.subheadline)
                        .foregroundColor(.accentColor)
                    }
                    .padding(.top, 8)

                    // 确认扣减按钮
                    if !recognizedItems.isEmpty {
                        VStack(spacing: 12) {
                            TextField("项目名称（可选）", text: $projectName)
                                .textFieldStyle(.roundedBorder)
                                .padding(.horizontal)

                            Button {
                                showingConfirmation = true
                            } label: {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                    Text("确认并从库存扣减")
                                }
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.green)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                            }
                            .padding(.horizontal)
                        }
                    }

                    Spacer(minLength: 50)
                }
                .padding(.vertical)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("图纸扫描")
            .sheet(isPresented: $showingCamera) {
                CameraPicker(image: $selectedImage)
            }
            .onChange(of: selectedPhotoItem) { newItem in
                guard let newItem = newItem else { return }
                isLoadingImage = true
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        await MainActor.run {
                            selectedImage = image
                            isLoadingImage = false
                        }
                    } else {
                        await MainActor.run {
                            isLoadingImage = false
                        }
                    }
                }
            }
            .sheet(isPresented: $showingManualEntry) {
                ManualEntrySheetNew(onAdd: addManualItem)
            }
            .alert("确认扣减", isPresented: $showingConfirmation) {
                Button("取消", role: .cancel) { }
                Button("确认扣减") {
                    applyToInventory()
                }
            } message: {
                Text("将从库存中扣减 \(totalBeads) 颗豆子，共 \(recognizedItems.count) 种颜色。此操作不可撤销。")
            }
        }
    }

    func recognizeImage() {
        guard let image = selectedImage else { return }

        isRecognizing = true
        errorMessage = nil

        Task {
            do {
                let items = try await aiService.recognizeImage(image)
                await MainActor.run {
                    recognizedItems = items.map { RecognizedItem(colorCode: $0.colorCode, quantity: $0.quantity) }
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
        // 创建项目记录
        let beadUsages = recognizedItems.map { item in
            BeadUsage(colorCode: item.colorCode, quantity: item.quantity)
        }
        let project = ProjectRecord(
            name: projectName.isEmpty ? "图纸\(Date().formatted(date: .numeric, time: .omitted))" : projectName,
            beadUsage: beadUsages
        )
        inventoryManager.addProject(project)

        // 从库存扣减
        for item in recognizedItems {
            _ = inventoryManager.deductFromStock(colorCode: item.colorCode, amount: item.quantity)
        }

        // 清除结果
        recognizedItems = []
        selectedImage = nil
        selectedPhotoItem = nil
        projectName = ""
    }

    func addManualItem(colorCode: String, quantity: Int) {
        recognizedItems.append(RecognizedItem(colorCode: colorCode.uppercased(), quantity: quantity))
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

// MARK: - 图片选择区域
struct ImageSelectionSection: View {
    @Binding var selectedImage: UIImage?
    @Binding var selectedPhotoItem: PhotosPickerItem?
    @Binding var showingCamera: Bool
    @Binding var isLoadingImage: Bool

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
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 250)
                    .cornerRadius(12)
                    .shadow(radius: 4)

                Button("重新选择") {
                    selectedImage = nil
                    selectedPhotoItem = nil
                }
                .font(.caption)
                .foregroundColor(.secondary)
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
                    .keyboardType(.numberPad)
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
                        .keyboardType(.numberPad)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("识别结果")
                    .font(.headline)
                Spacer()
                Text("共 \(items.count) 色 / \(totalBeads) 颗")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ForEach(items) { item in
                RecognizedItemRowNew(
                    item: item,
                    inventoryManager: inventoryManager,
                    onUpdate: { code, qty in
                        if let index = items.firstIndex(where: { $0.id == item.id }) {
                            if let c = code { items[index].colorCode = c.uppercased() }
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
    }
}

struct RecognizedItemRowNew: View {
    let item: ScanView.RecognizedItem
    let inventoryManager: InventoryManager
    let onUpdate: (String?, Int?) -> Void
    let onRemove: () -> Void

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
                    .keyboardType(.numberPad)
                    .frame(width: 60)

                Button("保存") {
                    onUpdate(editCode.isEmpty ? nil : editCode, Int(editQuantity))
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
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }
}

// MARK: - 新版手动添加弹窗
struct ManualEntrySheetNew: View {
    let onAdd: (String, Int) -> Void
    @Environment(\.dismiss) var dismiss

    @State private var colorCode = ""
    @State private var quantity = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("色号信息") {
                    TextField("MARD色号", text: $colorCode)
                        .textInputAutocapitalization(.characters)

                    TextField("数量", text: $quantity)
                        .keyboardType(.numberPad)
                }

                Section {
                    Button {
                        if let qty = Int(quantity), qty > 0 {
                            onAdd(colorCode, qty)
                            colorCode = ""
                            quantity = ""
                        }
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
}

// MARK: - AI 设置视图（从 ScanView 跳转）
struct AISettingsView: View {
    @ObservedObject var aiService: AIServiceManager

    var body: some View {
        Form {
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

                Picker("模型", selection: $aiService.config.model) {
                    if aiService.config.provider == .openai {
                        ForEach(AIConfig.openAIModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    } else {
                        ForEach(AIConfig.anthropicModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                }
            } header: {
                Text("AI 配置")
            } footer: {
                Text("支持 OpenAI GPT-4o 和 Anthropic Claude。如需代理可填写自定义 API 地址。")
            }

            Section {
                HStack {
                    Image(systemName: aiService.isConfigured ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundColor(aiService.isConfigured ? .green : .orange)
                    Text(aiService.isConfigured ? "已配置，可以使用 AI 识别" : "请填写 API Key")
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("AI 设置")
    }
}

#Preview {
    ScanView()
        .environmentObject(InventoryManager())
}
