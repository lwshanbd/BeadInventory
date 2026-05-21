//
//  ImportStockView.swift
//  BeadInventory
//
//  CSV 库存导入视图
//

import SwiftUI
import UniformTypeIdentifiers

struct ImportStockView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss

    // 导入模式
    enum ImportMode {
        case forNewBrand              // 创建品牌时选择导入
        case forExistingBrand(UUID)   // 已有品牌导入
    }

    let mode: ImportMode
    let colorSystem: ColorSystem

    // 回调：创建品牌模式时返回导入数据
    var onImport: (([StockImportItem]) -> Void)?

    @State private var showingFilePicker = false
    @State private var importResult: CSVImportResult?
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var showingSuccessAlert = false
    @State private var importedCount = 0

    // 有效色号集合（按品牌使用的色号体系过滤）
    private var validColorCodes: Set<String> {
        Set(inventoryManager.beadColors
            .filter { $0.hasCode(for: colorSystem) }
            .map { $0.displayCode(for: colorSystem).uppercased() })
    }

    // 色号到名称映射（按品牌使用的色号体系）
    private var colorNameMap: [String: String] {
        var map: [String: String] = [:]
        for color in inventoryManager.beadColors where color.hasCode(for: colorSystem) {
            map[color.displayCode(for: colorSystem).uppercased()] = color.colorName
        }
        return map
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let result = importResult {
                    // 显示导入预览
                    ImportPreviewView(
                        result: result,
                        onConfirm: {
                            confirmImport(result: result)
                        },
                        onCancel: {
                            importResult = nil
                        }
                    )
                } else {
                    // 选择文件界面
                    selectFileView
                }
            }
            .navigationTitle("导入库存")
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
                allowedContentTypes: [.commaSeparatedText, .plainText],
                allowsMultipleSelection: false
            ) { result in
                handleFileSelection(result)
            }
            .alert("导入成功", isPresented: $showingSuccessAlert) {
                Button("确定") {
                    dismiss()
                }
            } message: {
                Text("成功导入 \(importedCount) 种颜色的库存")
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
            Image(systemName: "doc.text")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)

            // 说明文字
            VStack(spacing: 8) {
                Text("选择 CSV 文件")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("文件需包含「色号」和「数量」两列")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
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

            Spacer()

            // CSV 格式说明
            csvFormatHint
        }
        .padding()
    }

    // CSV 格式提示
    private var csvFormatHint: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CSV 格式示例")
                .font(.subheadline)
                .fontWeight(.medium)

            VStack(alignment: .leading, spacing: 4) {
                Text("色号,数量")
                Text("A1,500")
                Text("A2,1000")
                Text("B1,800")
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(.secondary)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.ColorToken.Surface.subtle)
            .cornerRadius(Theme.Radius.sm)

            Text("支持的列名：色号/颜色/color/code，数量/库存/quantity/stock 等")
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
            let result = CSVImporter.parse(
                content: content,
                validColorCodes: validColorCodes,
                colorNameMap: colorNameMap
            )

            if result.isEmpty && !result.parseErrors.isEmpty {
                errorMessage = result.parseErrors.joined(separator: "\n")
            } else {
                importResult = result
            }
        } catch {
            errorMessage = "无法读取文件：\(error.localizedDescription)"
        }

        isProcessing = false
    }

    // MARK: - 确认导入

    private func confirmImport(result: CSVImportResult) {
        switch mode {
        case .forNewBrand:
            // 创建品牌模式：返回导入数据
            onImport?(result.validItems)
            dismiss()

        case .forExistingBrand(let brandId):
            // 已有品牌模式：执行导入
            let items = result.validItems.map { ($0.colorCode, $0.quantity) }
            importedCount = inventoryManager.importStock(brandId: brandId, items: items)
            showingSuccessAlert = true
        }
    }
}

// MARK: - 导入预览视图

struct ImportPreviewView: View {
    let result: CSVImportResult
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var showingInvalidItems = false

    var body: some View {
        VStack(spacing: 0) {
            // 统计信息
            summarySection

            Divider()

            // 有效条目列表
            List {
                // 有效条目
                Section {
                    ForEach(result.validItems) { item in
                        ImportItemRow(item: item)
                    }
                } header: {
                    Text("待导入 (\(result.validItems.count) 种颜色)")
                }

                // 无效条目（可折叠）
                if !result.invalidItems.isEmpty {
                    Section {
                        DisclosureGroup("查看无效色号 (\(result.invalidItems.count) 个)") {
                            ForEach(result.invalidItems) { item in
                                HStack {
                                    Text(item.colorCode)
                                        .font(.system(.body, design: .monospaced))
                                    Spacer()
                                    Text("\(item.quantity)")
                                        .foregroundColor(.secondary)
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(Theme.ColorToken.Status.warning)
                                        .font(.caption)
                                }
                            }
                        }
                    } header: {
                        Text("无法导入")
                    } footer: {
                        Text("这些色号在系统中不存在，将被跳过")
                    }
                }

                // 解析错误
                if !result.parseErrors.isEmpty {
                    Section {
                        ForEach(result.parseErrors, id: \.self) { error in
                            Text(error)
                                .font(.caption)
                                .foregroundColor(Theme.ColorToken.Status.warning)
                        }
                    } header: {
                        Text("解析警告")
                    }
                }

                // 重复条目
                if !result.duplicateItems.isEmpty {
                    Section {
                        Text("发现 \(result.duplicateItems.count) 个重复色号，已自动合并数量")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } header: {
                        Text("重复处理")
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
                        .background(result.validItems.isEmpty ? Theme.ColorToken.Border.default : Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(Theme.Radius.md)
                }
                .disabled(result.validItems.isEmpty)
            }
            .padding()
        }
    }

    private var summarySection: some View {
        HStack(spacing: 20) {
            VStack {
                Text("\(result.validItems.count)")
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(.accentColor)
                Text("种颜色")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()
                .frame(height: 40)

            VStack {
                Text("\(result.totalValidQuantity)")
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(Theme.ColorToken.Status.success)
                Text("总数量")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if !result.invalidItems.isEmpty {
                Divider()
                    .frame(height: 40)

                VStack {
                    Text("\(result.invalidItems.count)")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(Theme.ColorToken.Status.warning)
                    Text("无效")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Theme.ColorToken.Surface.subtle)
    }
}

// MARK: - 导入条目行

struct ImportItemRow: View {
    let item: StockImportItem

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.colorCode)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)

                if let name = item.colorName {
                    Text(name)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Text("+\(item.quantity)")
                .font(.system(.body, design: .monospaced))
                .foregroundColor(Theme.ColorToken.Status.success)
                .fontWeight(.medium)
        }
    }
}

#Preview {
    ImportStockView(mode: .forNewBrand, colorSystem: .mard)
        .environmentObject(InventoryManager())
}
