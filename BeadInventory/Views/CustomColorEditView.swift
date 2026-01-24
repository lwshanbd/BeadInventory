//
//  CustomColorEditView.swift
//  BeadInventory
//
//  自定义颜色编辑视图 - 添加/编辑自定义颜色
//

import SwiftUI

struct CustomColorEditView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss

    // 编辑模式：传入 customColor 时为编辑，否则为新增
    let editingColor: CustomColor?

    @State private var colorCode: String = ""
    @State private var colorName: String = ""
    @State private var selectedColor: Color = .red
    @State private var showingColorPicker = false
    @State private var showingError = false
    @State private var errorMessage = ""

    // 用于手动输入 Hex
    @State private var hexInput: String = "FF0000"

    var isEditing: Bool {
        editingColor != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                // 颜色预览
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            Circle()
                                .fill(selectedColor)
                                .frame(width: 100, height: 100)
                                .overlay(
                                    Circle()
                                        .stroke(Color.gray.opacity(0.3), lineWidth: 2)
                                )
                                .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)

                            Text(colorCode.isEmpty ? "色号" : colorCode)
                                .font(.headline)
                                .foregroundColor(colorCode.isEmpty ? .secondary : .primary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                // 基本信息
                Section(header: Text("基本信息")) {
                    HStack {
                        Text("色号")
                        Spacer()
                        TextField("例如: MY01", text: $colorCode)
                            .textInputAutocapitalization(.characters)
                            .multilineTextAlignment(.trailing)
                            .disabled(isEditing)  // 编辑时不允许修改色号
                    }

                    HStack {
                        Text("名称")
                        Spacer()
                        TextField("例如: 珊瑚红", text: $colorName)
                            .multilineTextAlignment(.trailing)
                    }
                }

                // 颜色选择
                Section(header: Text("颜色选择")) {
                    // 系统调色板
                    ColorPicker("选择颜色", selection: $selectedColor, supportsOpacity: false)
                        .onChange(of: selectedColor) { _, newColor in
                            hexInput = newColor.toHex() ?? "FF0000"
                        }

                    // 手动输入 Hex
                    HStack {
                        Text("Hex 值")
                        Spacer()
                        Text("#")
                            .foregroundColor(.secondary)
                        TextField("FF0000", text: $hexInput)
                            .textInputAutocapitalization(.characters)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: hexInput) { _, newValue in
                                // 过滤非法字符
                                let filtered = newValue.filter { $0.isHexDigit }
                                if filtered != newValue {
                                    hexInput = String(filtered.prefix(6))
                                }
                                // 更新颜色预览
                                if filtered.count == 6 || filtered.count == 3 {
                                    selectedColor = Color(hex: filtered)
                                }
                            }
                    }
                }

                // 常用颜色快捷选择
                Section(header: Text("快捷选择")) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 8) {
                        ForEach(quickColors, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 32, height: 32)
                                .overlay(
                                    Circle()
                                        .stroke(selectedColorHex == hex ? Color.accentColor : Color.gray.opacity(0.2), lineWidth: selectedColorHex == hex ? 3 : 1)
                                )
                                .onTapGesture {
                                    selectedColor = Color(hex: hex)
                                    hexInput = hex
                                }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle(isEditing ? "编辑颜色" : "添加自定义颜色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "保存" : "添加") {
                        saveColor()
                    }
                    .disabled(colorCode.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .alert("错误", isPresented: $showingError) {
                Button("确定", role: .cancel) { }
            } message: {
                Text(errorMessage)
            }
            .onAppear {
                if let color = editingColor {
                    colorCode = color.colorCode
                    colorName = color.colorName
                    hexInput = color.colorHex
                    selectedColor = Color(hex: color.colorHex)
                }
            }
        }
    }

    private var selectedColorHex: String {
        hexInput.uppercased()
    }

    // 常用颜色列表
    private let quickColors: [String] = [
        // 红色系
        "FF0000", "FF4444", "FF6B6B", "E74C3C",
        // 橙色系
        "FF8C00", "FFA500", "FFB347", "F39C12",
        // 黄色系
        "FFFF00", "FFD700", "F1C40F", "FFEB3B",
        // 绿色系
        "00FF00", "32CD32", "2ECC71", "27AE60",
        // 青色系
        "00FFFF", "00CED1", "1ABC9C", "16A085",
        // 蓝色系
        "0000FF", "1E90FF", "3498DB", "2980B9",
        // 紫色系
        "8B00FF", "9B59B6", "8E44AD", "663399",
        // 粉色系
        "FF69B4", "FF1493", "E91E63", "C71585",
        // 棕色系
        "8B4513", "A0522D", "D2691E", "CD853F",
        // 灰色系
        "808080", "A9A9A9", "C0C0C0", "D3D3D3",
        // 黑白
        "000000", "FFFFFF", "2C3E50", "34495E"
    ]

    private func saveColor() {
        let trimmedCode = colorCode.trimmingCharacters(in: .whitespaces).uppercased()
        let trimmedName = colorName.trimmingCharacters(in: .whitespaces)
        let colorHex = hexInput.uppercased()

        guard !trimmedCode.isEmpty else {
            errorMessage = "请输入色号"
            showingError = true
            return
        }

        guard colorHex.count == 6 || colorHex.count == 3 else {
            errorMessage = "请输入有效的颜色值"
            showingError = true
            return
        }

        if isEditing {
            // 更新现有颜色
            if let editingColor = editingColor {
                let success = inventoryManager.updateCustomColor(
                    id: editingColor.id,
                    colorHex: colorHex,
                    colorName: trimmedName
                )
                if success {
                    dismiss()
                } else {
                    errorMessage = "更新失败，请重试"
                    showingError = true
                }
            }
        } else {
            // 添加新颜色
            if let _ = inventoryManager.addCustomColor(
                colorCode: trimmedCode,
                colorHex: colorHex,
                colorName: trimmedName
            ) {
                dismiss()
            } else {
                errorMessage = "色号已存在或与现有颜色冲突"
                showingError = true
            }
        }
    }
}

// MARK: - Color 扩展
extension Color {
    /// 将 Color 转换为 Hex 字符串
    func toHex() -> String? {
        guard let components = UIColor(self).cgColor.components else { return nil }
        let r = components[0]
        let g = components.count > 1 ? components[1] : r
        let b = components.count > 2 ? components[2] : r

        return String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

// MARK: - Character 扩展
extension Character {
    var isHexDigit: Bool {
        return "0123456789ABCDEFabcdef".contains(self)
    }
}

#Preview {
    CustomColorEditView(editingColor: nil)
        .environmentObject(InventoryManager())
}
