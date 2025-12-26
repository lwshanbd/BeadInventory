//
//  ScanView.swift
//  BeadInventory
//
//  图纸扫描和OCR识别界面
//

import SwiftUI
import PhotosUI

struct ScanView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @StateObject private var ocrManager = OCRManager()

    @State private var selectedImage: UIImage?
    @State private var showingImagePicker = false
    @State private var showingCamera = false
    @State private var showingManualEntry = false
    @State private var showingConfirmation = false
    @State private var projectName = ""

    var totalBeads: Int {
        ocrManager.recognizedItems.reduce(0) { $0 + $1.quantity }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // 图片选择区域
                    ImageSelectionSection(
                        selectedImage: $selectedImage,
                        showingImagePicker: $showingImagePicker,
                        showingCamera: $showingCamera
                    )

                    // 识别按钮
                    if selectedImage != nil {
                        Button {
                            recognizeImage()
                        } label: {
                            HStack {
                                if ocrManager.isProcessing {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "text.viewfinder")
                                }
                                Text(ocrManager.isProcessing ? "识别中..." : "开始识别")
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                        .disabled(ocrManager.isProcessing)
                        .padding(.horizontal)
                    }

                    // 错误提示
                    if let error = ocrManager.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding()
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(8)
                            .padding(.horizontal)
                    }

                    // 识别结果
                    if !ocrManager.recognizedItems.isEmpty {
                        RecognizedResultsSection(
                            ocrManager: ocrManager,
                            totalBeads: totalBeads
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
                    if !ocrManager.recognizedItems.isEmpty {
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
            .sheet(isPresented: $showingImagePicker) {
                ImagePicker(image: $selectedImage, sourceType: .photoLibrary)
            }
            .sheet(isPresented: $showingCamera) {
                ImagePicker(image: $selectedImage, sourceType: .camera)
            }
            .sheet(isPresented: $showingManualEntry) {
                ManualEntrySheet(ocrManager: ocrManager)
            }
            .alert("确认扣减", isPresented: $showingConfirmation) {
                Button("取消", role: .cancel) { }
                Button("确认扣减") {
                    applyToInventory()
                }
            } message: {
                Text("将从库存中扣减 \(totalBeads) 颗豆子，共 \(ocrManager.recognizedItems.count) 种颜色。此操作不可撤销。")
            }
        }
    }

    func recognizeImage() {
        guard let image = selectedImage else { return }
        ocrManager.recognizeText(from: image) { _ in }
    }

    func applyToInventory() {
        // 创建项目记录
        let beadUsages = ocrManager.recognizedItems.map { item in
            BeadUsage(colorCode: item.colorCode, quantity: item.quantity)
        }
        let project = ProjectRecord(
            name: projectName.isEmpty ? "图纸\(Date().formatted(date: .numeric, time: .omitted))" : projectName,
            beadUsage: beadUsages
        )
        inventoryManager.addProject(project)

        // 从库存扣减
        for item in ocrManager.recognizedItems {
            _ = inventoryManager.deductFromStock(colorCode: item.colorCode, amount: item.quantity)
        }

        // 清除结果
        ocrManager.clearResults()
        selectedImage = nil
        projectName = ""
    }
}

// MARK: - 图片选择区域
struct ImageSelectionSection: View {
    @Binding var selectedImage: UIImage?
    @Binding var showingImagePicker: Bool
    @Binding var showingCamera: Bool

    var body: some View {
        VStack(spacing: 16) {
            if let image = selectedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 250)
                    .cornerRadius(12)
                    .shadow(radius: 4)

                Button("重新选择") {
                    selectedImage = nil
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
                        Button {
                            showingImagePicker = true
                        } label: {
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

// MARK: - 图片选择器
struct ImagePicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    let sourceType: UIImagePickerController.SourceType

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePicker

        init(_ parent: ImagePicker) {
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

#Preview {
    ScanView()
        .environmentObject(InventoryManager())
}
