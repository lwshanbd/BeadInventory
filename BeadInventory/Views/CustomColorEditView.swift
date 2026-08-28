//
//  CustomColorEditView.swift
//  BeadInventory
//
//  自定义色号编辑 —— 半屏 sheet 风格：
//  drag handle → bead 大头 + 标题 → 基本信息 GroupCard → 启用品牌 GroupCard → 主操作按钮
//  本页 flavor = mauve（跟随入口色）。
//

import SwiftUI

struct CustomColorEditView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss

    /// 编辑模式：传入 customColor 时为编辑，否则为新增
    let editingColor: CustomColor?

    @State private var colorCode: String = ""
    @State private var colorName: String = ""
    @State private var hexInput: String = "E5BFA3"
    @State private var selectedColor: Color = Color(hex: "E5BFA3")

    @State private var enabledBrandIds: Set<UUID> = []

    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var showingDeleteAlert = false
    @State private var showingAddSuccessHint = false

    private let flavor = Theme.ColorToken.Morandi.mauve
    private let honey = Theme.ColorToken.Morandi.honey
    private let sage = Theme.ColorToken.Morandi.sage

    private var isEditing: Bool { editingColor != nil }

    private var canSave: Bool {
        let trimmed = colorCode.trimmingCharacters(in: .whitespaces)
        let normalizedHex = hexInput.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && (normalizedHex.count == 6 || normalizedHex.count == 3)
    }

    private var enabledCountText: String {
        "\(enabledBrandIds.count) / \(inventoryManager.brands.count)"
    }

    private let quickColors: [String] = [
        "E5BFA3", "F1B7B0", "7B8FA1", "A8B998", "A87B5C", "C6B79E",
        "D9A89A", "B3998C", "8FA6B5", "C9B3D5", "E8C58E", "9DBFA8",
        "FF6B6B", "FFA94D", "FFD93D", "6BCB77", "4D96FF", "9B5DE5",
        "2C3E50", "808080", "FFFFFF", "000000",
    ]

    var body: some View {
        VStack(spacing: 0) {
            dragHandle
                .padding(.top, 8)
                .padding(.bottom, 6)

            headerRow
                .padding(.horizontal, 18)
                .padding(.bottom, 14)

            ScrollView {
                VStack(spacing: 14) {
                    basicInfoCard
                    quickPickCard
                    if !inventoryManager.brands.isEmpty {
                        brandsHeader
                        brandsCard
                    }
                    if isEditing {
                        BIGroupCard {
                            BIDangerRow(
                                icon: "trash",
                                title: "删除此色号",
                                subtitle: "所有品牌的相关库存也会被删除",
                                isLast: true
                            ) {
                                showingDeleteAlert = true
                            }
                        }
                    }
                }
                .padding(.top, 2)
                .padding(.bottom, 110)
            }

            bottomBar
        }
        .background(Theme.ColorToken.Surface.background)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .alert("错误", isPresented: $showingError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .alert("添加成功", isPresented: $showingAddSuccessHint) {
            Button("知道了") { dismiss() }
        } message: {
            Text("自定义色号已添加。\n如需在品牌中使用，请前往「启用品牌」打开对应开关。")
        }
        .alert("确认删除", isPresented: $showingDeleteAlert) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { performDelete() }
        } message: {
            Text("确定要删除这个自定义色号吗？\n删除后将无法恢复，且该颜色在所有品牌中的库存记录也将被删除。")
        }
        .onAppear(perform: setup)
    }

    // MARK: - Drag handle

    private var dragHandle: some View {
        Capsule()
            .fill(Theme.ColorToken.Border.default)
            .frame(width: 40, height: 4)
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 14) {
            BeadView(color: selectedColor, size: 56, ring: honey)

            VStack(alignment: .leading, spacing: 2) {
                Text(isEditing ? "编辑自定义色号" : "添加自定义色号")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.ColorToken.Text.primary)
                Text(isEditing
                     ? "修改 HEX 会同步到所有品牌"
                     : "添加后可在下方启用所需品牌")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
            }

            Spacer(minLength: 8)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.ColorToken.Surface.subtle))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Basic info card

    private var basicInfoCard: some View {
        BIGroupCard(footer: "色号一旦创建无法修改；HEX 会立即影响所有品牌中该色号的展示。") {
            VStack(spacing: 0) {
                editRow(label: "色号") {
                    if isEditing {
                        Text(displayCode)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.ColorToken.Text.primary)
                    } else {
                        TextField("如 MY01", text: $colorCode)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled(true)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(Theme.ColorToken.Text.primary)
                    }
                }
                divider
                editRow(label: "名称") {
                    TextField("如 自配 · 杏色", text: $colorName)
                        .font(.system(size: 14, weight: .medium))
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(Theme.ColorToken.Text.primary)
                }
                divider
                editRow(label: "HEX", isLast: true) {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selectedColor)
                            .frame(width: 22, height: 22)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
                            )
                        HStack(spacing: 2) {
                            Text("#")
                                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.ColorToken.Text.tertiary)
                            TextField("FF6B6B", text: $hexInput)
                                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled(true)
                                .frame(width: 78)
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(Theme.ColorToken.Text.primary)
                                .onChange(of: hexInput) { _, newValue in
                                    let filtered = String(newValue.uppercased().filter { $0.isHexDigit }.prefix(6))
                                    if filtered != newValue { hexInput = filtered }
                                    if filtered.count == 6 || filtered.count == 3 {
                                        selectedColor = Color(hex: filtered)
                                    }
                                }
                        }
                    }
                }
            }
        }
    }

    private var displayCode: String {
        let raw = colorCode.trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? "—" : "#\(raw)"
    }

    private func editRow<Trailing: View>(label: String, isLast: Bool = false, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Theme.ColorToken.Text.secondary)
                .frame(width: 50, alignment: .leading)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(Theme.ColorToken.Border.divider)
                    .frame(height: 1)
                    .padding(.leading, 14)
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 0)
    }

    // MARK: - Quick pick

    private var quickPickCard: some View {
        BIGroupCard(title: "快捷取色") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 8), spacing: 10) {
                ForEach(quickColors, id: \.self) { hex in
                    Button {
                        hexInput = hex
                        selectedColor = Color(hex: hex)
                    } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 28, height: 28)
                            .overlay(
                                Circle()
                                    .strokeBorder(
                                        hexInput.uppercased() == hex ? flavor : Theme.ColorToken.Border.default,
                                        lineWidth: hexInput.uppercased() == hex ? 2.5 : 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
        }
    }

    // MARK: - Brands

    private var brandsHeader: some View {
        BIGroupHeader(title: "启用品牌", hint: enabledCountText)
    }

    private var brandsCard: some View {
        BIGroupCard(footer: isEditing ? nil : "新增的色号默认在所有品牌中关闭，按需打开。") {
            VStack(spacing: 0) {
                ForEach(Array(inventoryManager.brands.enumerated()), id: \.element.id) { idx, brand in
                    brandToggleRow(brand: brand, isLast: idx == inventoryManager.brands.count - 1)
                }
            }
        }
    }

    private func brandToggleRow(brand: Brand, isLast: Bool) -> some View {
        let isOn = Binding<Bool>(
            get: { enabledBrandIds.contains(brand.id) },
            set: { newValue in
                if newValue { enabledBrandIds.insert(brand.id) }
                else { enabledBrandIds.remove(brand.id) }
            }
        )
        return HStack(spacing: 10) {
            Circle()
                .fill(enabledBrandIds.contains(brand.id) ? flavor : Theme.ColorToken.Text.tertiary.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(brand.name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(enabledBrandIds.contains(brand.id) ? Theme.ColorToken.Text.primary : Theme.ColorToken.Text.tertiary)
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(sage)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(Theme.ColorToken.Border.divider)
                    .frame(height: 1)
                    .padding(.leading, 30)
            }
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Text("取消")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Theme.ColorToken.Surface.subtle)
                    )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)

            Button {
                saveColor()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                    Text(isEditing ? "保存更改" : "添加")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(canSave ? flavor : Theme.ColorToken.Text.tertiary)
                )
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 18)
        .background(
            Theme.ColorToken.Surface.background
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Theme.ColorToken.Border.divider)
                        .frame(height: 1)
                }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - Setup / persistence

    private func setup() {
        if let color = editingColor {
            colorCode = color.colorCode
            colorName = color.colorName
            hexInput = color.colorHex.uppercased()
            selectedColor = Color(hex: color.colorHex)

            // 当前启用的品牌 = 该自定义色号在 brandStock 中 isHidden == false 的品牌
            var enabled: Set<UUID> = []
            for stock in inventoryManager.brandStocks where stock.mardCode == color.mardCode && !stock.isHidden {
                enabled.insert(stock.brandId)
            }
            enabledBrandIds = enabled
        } else {
            // 新增时默认不启用任何品牌（与现有行为一致）
            enabledBrandIds = []
        }
    }

    private func saveColor() {
        let trimmedCode = colorCode.trimmingCharacters(in: .whitespaces).uppercased()
        let trimmedName = colorName.trimmingCharacters(in: .whitespaces)
        let trimmedHex = hexInput.trimmingCharacters(in: .whitespaces).uppercased()

        guard !trimmedCode.isEmpty else {
            errorMessage = "请输入色号"
            showingError = true
            return
        }
        guard trimmedHex.count == 6 || trimmedHex.count == 3 else {
            errorMessage = "请输入有效的 HEX 颜色值"
            showingError = true
            return
        }

        if let editing = editingColor {
            let success = inventoryManager.updateCustomColor(
                id: editing.id,
                colorHex: trimmedHex,
                colorName: trimmedName
            )
            if !success {
                errorMessage = "更新失败，请重试"
                showingError = true
                return
            }
            applyBrandToggles(for: editing.mardCode)
            dismiss()
        } else {
            if let newColor = inventoryManager.addCustomColor(
                colorCode: trimmedCode,
                colorHex: trimmedHex,
                colorName: trimmedName
            ) {
                applyBrandToggles(for: newColor.mardCode)
                // 如果用户在新增时已经勾选了至少一个品牌，直接关闭；否则提示
                if enabledBrandIds.isEmpty {
                    showingAddSuccessHint = true
                } else {
                    dismiss()
                }
            } else {
                errorMessage = "色号已存在或与现有颜色冲突"
                showingError = true
            }
        }
    }

    /// 把当前 enabledBrandIds 的选择写回 brandStocks（hide / unhide）
    private func applyBrandToggles(for mardCode: String) {
        for brand in inventoryManager.brands {
            let shouldEnable = enabledBrandIds.contains(brand.id)
            if shouldEnable {
                inventoryManager.unhideColor(brandId: brand.id, mardCode: mardCode, defaultStock: 0)
            } else {
                inventoryManager.hideColor(brandId: brand.id, mardCode: mardCode)
            }
        }
    }

    private func performDelete() {
        guard let editing = editingColor else { return }
        _ = inventoryManager.deleteCustomColor(id: editing.id)
        dismiss()
    }
}

#Preview {
    CustomColorEditView(editingColor: nil as CustomColor?)
        .environmentObject(InventoryManager())
}
