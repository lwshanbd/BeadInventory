//
//  ShippingView.swift
//  BeadInventory
//
//  运输中（待到货的购买记录）
//

import SwiftUI

struct ShippingView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var showingAddPurchase = false
    @State private var showingPasteSheet = false
    @State private var pasteError: String?
    @State private var showingPasteError = false

    var body: some View {
        VStack(spacing: 0) {
            if inventoryManager.purchaseRecords.isEmpty {
                // 空状态
                VStack(spacing: 16) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary.opacity(0.5))

                    Text("暂无运输中的订单")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    Text("点击下方按钮添加购买记录")
                        .font(.subheadline)
                        .foregroundColor(.secondary.opacity(0.8))

                    Button {
                        showingAddPurchase = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("添加购买记录")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.accentColor)
                        .cornerRadius(24)
                    }
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 购买记录列表
                List {
                    ForEach(inventoryManager.purchaseRecords) { record in
                        NavigationLink {
                            PurchaseRecordDetailView(record: record)
                        } label: {
                            PurchaseRecordRow(record: record)
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            let record = inventoryManager.purchaseRecords[index]
                            inventoryManager.deletePurchaseRecord(id: record.id)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("运输中")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    Button {
                        showingPasteSheet = true
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }

                    Button {
                        showingAddPurchase = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddPurchase) {
            AddPurchaseRecordView()
                .environmentObject(inventoryManager)
        }
        .sheet(isPresented: $showingPasteSheet) {
            PasteReplenishSheet()
                .environmentObject(inventoryManager)
        }
        .alert("粘贴失败", isPresented: $showingPasteError) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(pasteError ?? "未知错误")
        }
    }
}

// MARK: - 粘贴补豆建议弹窗
struct PasteReplenishSheet: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss
    @State private var selectedBrandId: UUID?
    @State private var recordName = ""
    @State private var parsedItems: [(colorCode: String, grams: Int)] = []
    @State private var parseError: String?
    @State private var hasParsed = false

    var totalGrams: Int {
        parsedItems.reduce(0) { $0 + $1.grams }
    }

    var totalBeads: Int {
        parsedItems.reduce(0) { $0 + $1.grams * 100 }  // 1g = 100颗
    }

    /// 生成默认名称（基于日期）
    var defaultName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日补豆"
        return formatter.string(from: Date())
    }

    var canSave: Bool {
        selectedBrandId != nil && !parsedItems.isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !hasParsed {
                    // 粘贴前的提示
                    VStack(spacing: 20) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 60))
                            .foregroundColor(.accentColor)

                        Text("粘贴补豆建议")
                            .font(.title2)
                            .fontWeight(.bold)

                        Text("请先在「补豆建议」页面复制 CSV，\n然后点击下方按钮粘贴")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)

                        Text("CSV 格式：色号,克数")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(8)

                        Button {
                            parseClipboard()
                        } label: {
                            HStack {
                                Image(systemName: "doc.on.clipboard.fill")
                                Text("从剪贴板粘贴")
                            }
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 14)
                            .background(Color.accentColor)
                            .cornerRadius(25)
                        }

                        if let error = parseError {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                                .padding(.top, 8)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    // 解析成功后的预览
                    ScrollView {
                        VStack(spacing: 16) {
                            // 品牌选择
                            VStack(alignment: .leading, spacing: 8) {
                                Text("选择品牌")
                                    .font(.headline)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 10) {
                                        ForEach(inventoryManager.brands) { brand in
                                            Button {
                                                selectedBrandId = brand.id
                                            } label: {
                                                Text(brand.name)
                                                    .font(.subheadline)
                                                    .padding(.horizontal, 16)
                                                    .padding(.vertical, 10)
                                                    .background(selectedBrandId == brand.id ? Color.accentColor : Color.gray.opacity(0.2))
                                                    .foregroundColor(selectedBrandId == brand.id ? .white : .primary)
                                                    .cornerRadius(20)
                                            }
                                        }
                                    }
                                }
                            }
                            .padding()
                            .background(Color(.systemBackground))
                            .cornerRadius(12)
                            .padding(.horizontal)

                            // 记录名称
                            HStack {
                                Text("名称")
                                    .foregroundColor(.secondary)
                                TextField("默认：\(defaultName)", text: $recordName)
                                    .textFieldStyle(.roundedBorder)
                            }
                            .padding(.horizontal)

                            // 汇总信息
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("共 \(parsedItems.count) 色")
                                        .font(.headline)
                                    Text("\(totalGrams)g（\(totalBeads) 颗）")
                                        .font(.subheadline)
                                        .foregroundColor(.green)
                                }
                                Spacer()
                                Button("重新粘贴") {
                                    hasParsed = false
                                    parsedItems = []
                                    parseError = nil
                                }
                                .font(.subheadline)
                            }
                            .padding()
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(12)
                            .padding(.horizontal)

                            // 颜色列表预览
                            VStack(alignment: .leading, spacing: 8) {
                                Text("补豆明细")
                                    .font(.headline)
                                    .padding(.horizontal)

                                ForEach(parsedItems, id: \.colorCode) { item in
                                    PasteItemRow(colorCode: item.colorCode, grams: item.grams)
                                }
                                .padding(.horizontal)
                            }
                        }
                        .padding(.vertical)
                    }

                    // 底部保存按钮
                    VStack(spacing: 0) {
                        Divider()
                        Button {
                            saveRecord()
                        } label: {
                            Text("保存到运输中")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(canSave ? Color.accentColor : Color.gray)
                                .cornerRadius(12)
                        }
                        .disabled(!canSave)
                        .padding()
                    }
                    .background(Color(.systemBackground))
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("粘贴补豆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    func parseClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            parseError = "剪贴板为空"
            return
        }

        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard lines.count > 1 else {
            parseError = "数据格式错误：至少需要标题行和一行数据"
            return
        }

        // 跳过标题行
        var items: [(colorCode: String, grams: Int)] = []
        for line in lines.dropFirst() {
            let parts = line.components(separatedBy: ",")
            guard parts.count >= 2 else { continue }
            let colorCode = parts[0].trimmingCharacters(in: .whitespaces)
            guard let grams = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            if grams > 0 {
                items.append((colorCode, grams))
            }
        }

        if items.isEmpty {
            parseError = "未找到有效数据"
            return
        }

        parsedItems = items
        hasParsed = true
        parseError = nil

        // 默认选中第一个品牌
        if selectedBrandId == nil, let firstBrand = inventoryManager.brands.first {
            selectedBrandId = firstBrand.id
        }
    }

    func saveRecord() {
        guard let brandId = selectedBrandId else { return }

        let items = parsedItems.map { item in
            PurchaseItem(colorCode: item.colorCode, quantity: item.grams * 100)  // 克数转颗数
        }

        let finalName = recordName.trimmingCharacters(in: .whitespaces).isEmpty ? defaultName : recordName

        inventoryManager.addPurchaseRecord(
            name: finalName,
            brandId: brandId,
            items: items,
            note: "从补豆建议粘贴"
        )

        dismiss()
    }
}

// MARK: - 粘贴项行
struct PasteItemRow: View {
    let colorCode: String
    let grams: Int
    @EnvironmentObject var inventoryManager: InventoryManager

    var beadColor: BeadColor? {
        inventoryManager.findColor(byCode: colorCode)
    }

    var displayColor: Color {
        beadColor?.color ?? .gray
    }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(displayColor)
                .frame(width: 36, height: 36)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )

            Text(colorCode)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)

            Spacer()

            Text("\(grams)g")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("+\(grams * 100)")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.green)
        }
        .padding(10)
        .background(Color(.systemBackground))
        .cornerRadius(10)
    }
}

// MARK: - 购买记录行
struct PurchaseRecordRow: View {
    let record: PurchaseRecord
    @EnvironmentObject var inventoryManager: InventoryManager

    var brandName: String {
        inventoryManager.brands.first(where: { $0.id == record.brandId })?.name ?? "未知品牌"
    }

    var body: some View {
        HStack(spacing: 12) {
            // 图标
            Image(systemName: "shippingbox.fill")
                .font(.title2)
                .foregroundColor(.orange)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text(record.name)
                    .font(.headline)

                HStack(spacing: 8) {
                    Label(brandName, systemImage: "tag")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("·")
                        .foregroundColor(.secondary)

                    Text("\(record.colorCount) 色")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("·")
                        .foregroundColor(.secondary)

                    Text("+\(formatNumber(record.totalBeads)) 颗")
                        .font(.caption)
                        .foregroundColor(.green)
                }

                Text(record.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    func formatNumber(_ num: Int) -> String {
        if num >= 10000 {
            return String(format: "%.1fW", Double(num) / 10000)
        } else if num >= 1000 {
            return String(format: "%.1fK", Double(num) / 1000)
        }
        return "\(num)"
    }
}

// MARK: - 购买记录详情
struct PurchaseRecordDetailView: View {
    let record: PurchaseRecord
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss
    @State private var showingConfirmation = false
    @State private var showingDeleteConfirmation = false
    @State private var showingEditSheet = false

    // 获取最新的记录数据
    var currentRecord: PurchaseRecord {
        inventoryManager.purchaseRecords.first(where: { $0.id == record.id }) ?? record
    }

    var brandName: String {
        inventoryManager.brands.first(where: { $0.id == currentRecord.brandId })?.name ?? "未知品牌"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 概览卡片
                VStack(spacing: 12) {
                    HStack {
                        Image(systemName: "shippingbox.fill")
                            .font(.title)
                            .foregroundColor(.orange)
                        Text(currentRecord.name)
                            .font(.title2)
                            .fontWeight(.bold)
                        Spacer()
                    }

                    Divider()

                    HStack(spacing: 20) {
                        VStack(spacing: 4) {
                            Text(brandName)
                                .font(.headline)
                                .foregroundColor(.accentColor)
                            Text("品牌")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        VStack(spacing: 4) {
                            Text("\(currentRecord.colorCount)")
                                .font(.headline)
                                .foregroundColor(.purple)
                            Text("颜色数")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        VStack(spacing: 4) {
                            Text("+\(currentRecord.totalBeads)")
                                .font(.headline)
                                .foregroundColor(.green)
                            Text("总颗数")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let note = currentRecord.note, !note.isEmpty {
                        Divider()
                        HStack {
                            Text(note)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    }
                }
                .padding()
                .background(Color(.systemBackground))
                .cornerRadius(12)
                .padding(.horizontal)

                // 颜色列表
                VStack(alignment: .leading, spacing: 12) {
                    Text("购买明细")
                        .font(.headline)
                        .padding(.horizontal)

                    VStack(spacing: 8) {
                        ForEach(currentRecord.items) { item in
                            PurchaseItemRow(item: item)
                        }
                    }
                    .padding(.horizontal)
                }

                // 操作按钮
                VStack(spacing: 12) {
                    Button {
                        showingConfirmation = true
                    } label: {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                            Text("确认到货")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }

                    HStack(spacing: 24) {
                        Button {
                            showingEditSheet = true
                        } label: {
                            HStack {
                                Image(systemName: "pencil")
                                Text("编辑记录")
                            }
                            .font(.subheadline)
                            .foregroundColor(.accentColor)
                        }

                        Button {
                            showingDeleteConfirmation = true
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text("删除记录")
                            }
                            .font(.subheadline)
                            .foregroundColor(.red)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .padding(.vertical)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("购买详情")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingEditSheet) {
            EditPurchaseRecordSheet(record: currentRecord)
                .environmentObject(inventoryManager)
        }
        .alert("确认到货", isPresented: $showingConfirmation) {
            Button("取消", role: .cancel) { }
            Button("确认") {
                inventoryManager.confirmPurchaseRecord(id: record.id)
                dismiss()
            }
        } message: {
            Text("将把 \(currentRecord.colorCount) 种颜色共 \(currentRecord.totalBeads) 颗豆子添加到「\(brandName)」的库存中。")
        }
        .alert("删除记录", isPresented: $showingDeleteConfirmation) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) {
                inventoryManager.deletePurchaseRecord(id: record.id)
                dismiss()
            }
        } message: {
            Text("确定要删除这条购买记录吗？此操作不可撤销。")
        }
    }
}

// MARK: - 购买项行
struct PurchaseItemRow: View {
    let item: PurchaseItem
    @EnvironmentObject var inventoryManager: InventoryManager

    var beadColor: BeadColor? {
        inventoryManager.findColor(byCode: item.colorCode)
    }

    var displayColor: Color {
        beadColor?.color ?? .gray
    }

    var body: some View {
        HStack(spacing: 12) {
            // 颜色预览
            RoundedRectangle(cornerRadius: 6)
                .fill(displayColor)
                .frame(width: 36, height: 36)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )

            // 色号
            Text(item.colorCode)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)

            Spacer()

            // 数量
            Text("+\(item.quantity)")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.green)
        }
        .padding(10)
        .background(Color(.systemBackground))
        .cornerRadius(10)
    }
}

// MARK: - 添加购买记录
struct AddPurchaseRecordView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss

    @State private var recordName = ""
    @State private var selectedBrandId: UUID?
    @State private var note = ""
    @State private var selectedColors: Set<UUID> = []
    @State private var quantities: [UUID: Double] = [:]
    @State private var selectedSeries = "A"

    // 色系列表
    let colorSeries = ["A", "B", "C", "D", "E", "F", "G", "H", "M", "P", "Q", "R", "T", "Y", "ZG", "其他", "#"]
    let standardPrefixes = ["A", "B", "C", "D", "E", "F", "G", "H", "M", "P", "Q", "R", "T", "Y", "ZG"]

    var colorsInSeries: [BeadColor] {
        let sourceColors = selectedSeries == "#" ? inventoryManager.allBeadColors : inventoryManager.beadColors

        return sourceColors.filter { color in
            let code = color.mardCode

            if selectedSeries == "#" {
                return code.hasPrefix("#")
            } else if selectedSeries == "其他" {
                if code.hasPrefix("#") { return false }
                return !standardPrefixes.contains { prefix in
                    if prefix == "ZG" {
                        return code.hasPrefix("ZG")
                    } else {
                        return code.hasPrefix(prefix) && !code.hasPrefix("ZG")
                    }
                }
            } else if selectedSeries == "ZG" {
                return code.hasPrefix("ZG")
            } else {
                if code.hasPrefix("ZG") { return false }
                return code.hasPrefix(selectedSeries)
            }
        }.sorted { $0.mardCode.localizedStandardCompare($1.mardCode) == .orderedAscending }
    }

    var totalToAdd: Int {
        var total = 0
        for colorId in selectedColors {
            let qty = quantities[colorId] ?? 1.0
            total += Int(qty * 1000)
        }
        return total
    }

    var canSave: Bool {
        selectedBrandId != nil && !selectedColors.isEmpty
    }

    /// 生成默认名称（基于日期）
    var defaultName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日订单"
        return formatter.string(from: Date())
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 基本信息
                VStack(spacing: 12) {
                    // 记录名称（可选）
                    TextField("名称（可选，默认：\(defaultName)）", text: $recordName)
                        .textFieldStyle(.roundedBorder)

                    // 品牌选择
                    HStack {
                        Text("入库品牌:")
                            .foregroundColor(.secondary)
                        Spacer()
                        Picker("品牌", selection: $selectedBrandId) {
                            Text("请选择").tag(nil as UUID?)
                            ForEach(inventoryManager.brands) { brand in
                                Text(brand.name).tag(brand.id as UUID?)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    // 备注
                    TextField("备注（可选）", text: $note)
                        .textFieldStyle(.roundedBorder)
                }
                .padding()
                .background(Color(.systemBackground))

                // 色系选择器
                SeriesSelector(
                    series: colorSeries,
                    selectedSeries: $selectedSeries
                )
                .padding(.vertical, 8)

                // 颜色列表
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(colorsInSeries) { color in
                            ColorAddRow(
                                color: color,
                                isSelected: selectedColors.contains(color.id),
                                quantity: Binding(
                                    get: { quantities[color.id] ?? 1.0 },
                                    set: { quantities[color.id] = $0 }
                                ),
                                onToggle: {
                                    toggleSelection(color.id)
                                }
                            )
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 100)
                }
                .scrollDismissesKeyboard(.immediately)

                // 底部确认栏
                if !selectedColors.isEmpty {
                    VStack(spacing: 0) {
                        Divider()

                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("已选择 \(selectedColors.count) 色")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Text("共 +\(formatNumber(totalToAdd)) 颗")
                                    .font(.headline)
                                    .foregroundColor(.green)
                            }

                            Spacer()

                            Button(action: savePurchaseRecord) {
                                Text("保存记录")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 12)
                                    .background(canSave ? Color.accentColor : Color.gray)
                                    .cornerRadius(24)
                            }
                            .disabled(!canSave)
                        }
                        .padding()
                        .background(Color(.systemBackground))
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("添加购买记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            selectAllInSeries()
                        } label: {
                            Label("全选本色系", systemImage: "checkmark.circle")
                        }

                        Button {
                            selectedColors.removeAll()
                        } label: {
                            Label("全部取消", systemImage: "circle")
                        }
                    } label: {
                        Text("快速选择")
                    }
                }
            }
        }
    }

    func toggleSelection(_ colorId: UUID) {
        if selectedColors.contains(colorId) {
            selectedColors.remove(colorId)
        } else {
            selectedColors.insert(colorId)
            if quantities[colorId] == nil {
                quantities[colorId] = 1.0
            }
        }
    }

    func selectAllInSeries() {
        for color in colorsInSeries {
            selectedColors.insert(color.id)
            if quantities[color.id] == nil {
                quantities[color.id] = 1.0
            }
        }
    }

    func savePurchaseRecord() {
        guard let brandId = selectedBrandId else { return }

        var items: [PurchaseItem] = []
        for colorId in selectedColors {
            guard let color = inventoryManager.allBeadColors.first(where: { $0.id == colorId }) else { continue }
            let qty = quantities[colorId] ?? 1.0
            let amount = Int(qty * 1000)
            items.append(PurchaseItem(colorCode: color.mardCode, quantity: amount))
        }

        // 如果名称为空，使用默认名称
        let finalName = recordName.trimmingCharacters(in: .whitespaces).isEmpty ? defaultName : recordName

        inventoryManager.addPurchaseRecord(
            name: finalName,
            brandId: brandId,
            items: items,
            note: note.isEmpty ? nil : note
        )

        dismiss()
    }

    func formatNumber(_ num: Int) -> String {
        if num >= 10000 {
            return String(format: "%.1fW", Double(num) / 10000)
        } else if num >= 1000 {
            return String(format: "%.1fK", Double(num) / 1000)
        }
        return "\(num)"
    }
}

// MARK: - 编辑购买记录
struct EditPurchaseRecordSheet: View {
    let record: PurchaseRecord
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss

    @State private var recordName: String = ""
    @State private var note: String = ""
    @State private var items: [EditableItem] = []
    @State private var showingAddColor = false

    struct EditableItem: Identifiable {
        let id = UUID()
        var colorCode: String
        var quantity: Int  // 颗数
    }

    var totalBeads: Int {
        items.reduce(0) { $0 + $1.quantity }
    }

    var hasChanges: Bool {
        let nameChanged = recordName != record.name
        let noteChanged = note != (record.note ?? "")
        let itemsChanged = items.count != record.items.count ||
            !items.enumerated().allSatisfy { index, item in
                index < record.items.count &&
                item.colorCode == record.items[index].colorCode &&
                item.quantity == record.items[index].quantity
            }
        return nameChanged || noteChanged || itemsChanged
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 16) {
                        // 基本信息
                        VStack(spacing: 12) {
                            HStack {
                                Text("名称")
                                    .foregroundColor(.secondary)
                                TextField("记录名称", text: $recordName)
                                    .textFieldStyle(.roundedBorder)
                            }

                            HStack {
                                Text("备注")
                                    .foregroundColor(.secondary)
                                TextField("备注（可选）", text: $note)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                        .padding()
                        .background(Color(.systemBackground))
                        .cornerRadius(12)
                        .padding(.horizontal)

                        // 汇总信息
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("共 \(items.count) 色")
                                    .font(.headline)
                                Text("+\(totalBeads) 颗")
                                    .font(.subheadline)
                                    .foregroundColor(.green)
                            }
                            Spacer()
                            Button {
                                showingAddColor = true
                            } label: {
                                HStack {
                                    Image(systemName: "plus.circle.fill")
                                    Text("添加颜色")
                                }
                                .font(.subheadline)
                            }
                        }
                        .padding()
                        .background(Color(.systemBackground))
                        .cornerRadius(12)
                        .padding(.horizontal)

                        // 颜色列表
                        VStack(alignment: .leading, spacing: 8) {
                            Text("购买明细")
                                .font(.headline)
                                .padding(.horizontal)

                            if items.isEmpty {
                                Text("暂无颜色")
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                            } else {
                                ForEach($items) { $item in
                                    EditableItemRow(
                                        item: $item,
                                        onDelete: {
                                            items.removeAll { $0.id == item.id }
                                        }
                                    )
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                    .padding(.vertical)
                }

                // 底部保存按钮
                VStack(spacing: 0) {
                    Divider()
                    Button {
                        saveChanges()
                    } label: {
                        Text("保存修改")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(hasChanges && !items.isEmpty ? Color.accentColor : Color.gray)
                            .cornerRadius(12)
                    }
                    .disabled(!hasChanges || items.isEmpty)
                    .padding()
                }
                .background(Color(.systemBackground))
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("编辑记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                recordName = record.name
                note = record.note ?? ""
                items = record.items.map { EditableItem(colorCode: $0.colorCode, quantity: $0.quantity) }
            }
            .sheet(isPresented: $showingAddColor) {
                AddColorToRecordSheet(brandId: record.brandId) { colorCode, quantity in
                    // 检查是否已存在该颜色
                    if let existingIndex = items.firstIndex(where: { $0.colorCode == colorCode }) {
                        items[existingIndex].quantity += quantity
                    } else {
                        items.append(EditableItem(colorCode: colorCode, quantity: quantity))
                    }
                }
                .environmentObject(inventoryManager)
            }
        }
    }

    func saveChanges() {
        let purchaseItems = items.map { PurchaseItem(colorCode: $0.colorCode, quantity: $0.quantity) }
        inventoryManager.updatePurchaseRecord(
            id: record.id,
            name: recordName,
            items: purchaseItems,
            note: note.isEmpty ? nil : note
        )
        dismiss()
    }
}

// MARK: - 可编辑项行
struct EditableItemRow: View {
    @Binding var item: EditPurchaseRecordSheet.EditableItem
    let onDelete: () -> Void
    @EnvironmentObject var inventoryManager: InventoryManager

    var beadColor: BeadColor? {
        inventoryManager.findColor(byCode: item.colorCode)
    }

    var displayColor: Color {
        beadColor?.color ?? .gray
    }

    var grams: Int {
        item.quantity / 100  // 100颗 = 1g
    }

    var body: some View {
        HStack(spacing: 12) {
            // 颜色预览
            RoundedRectangle(cornerRadius: 6)
                .fill(displayColor)
                .frame(width: 36, height: 36)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )

            // 色号
            Text(item.colorCode)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)

            Spacer()

            // 数量调整
            HStack(spacing: 8) {
                Button {
                    if item.quantity > 1000 {
                        item.quantity -= 1000
                    }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundColor(item.quantity > 1000 ? .blue : .gray)
                        .font(.title3)
                }
                .disabled(item.quantity <= 1000)

                VStack(spacing: 0) {
                    Text("\(item.quantity)")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.green)
                    Text("\(grams)g")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(minWidth: 50)

                Button {
                    item.quantity += 1000
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.blue)
                        .font(.title3)
                }
            }

            // 删除按钮
            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .foregroundColor(.red)
                    .font(.subheadline)
            }
            .padding(.leading, 8)
        }
        .padding(10)
        .background(Color(.systemBackground))
        .cornerRadius(10)
    }
}

// MARK: - 添加颜色到记录
struct AddColorToRecordSheet: View {
    let brandId: UUID
    let onAdd: (String, Int) -> Void

    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) var dismiss

    @State private var selectedSeries = "A"
    @State private var selectedColorId: UUID?
    @State private var quantity: Double = 1.0  // 千颗

    // 色系列表
    let colorSeries = ["A", "B", "C", "D", "E", "F", "G", "H", "M", "P", "Q", "R", "T", "Y", "ZG", "其他", "#"]
    let standardPrefixes = ["A", "B", "C", "D", "E", "F", "G", "H", "M", "P", "Q", "R", "T", "Y", "ZG"]

    var colorsInSeries: [BeadColor] {
        let sourceColors = selectedSeries == "#" ? inventoryManager.allBeadColors : inventoryManager.beadColors

        return sourceColors.filter { color in
            let code = color.mardCode

            if selectedSeries == "#" {
                return code.hasPrefix("#")
            } else if selectedSeries == "其他" {
                if code.hasPrefix("#") { return false }
                return !standardPrefixes.contains { prefix in
                    if prefix == "ZG" {
                        return code.hasPrefix("ZG")
                    } else {
                        return code.hasPrefix(prefix) && !code.hasPrefix("ZG")
                    }
                }
            } else if selectedSeries == "ZG" {
                return code.hasPrefix("ZG")
            } else {
                if code.hasPrefix("ZG") { return false }
                return code.hasPrefix(selectedSeries)
            }
        }.sorted { $0.mardCode.localizedStandardCompare($1.mardCode) == .orderedAscending }
    }

    var selectedColor: BeadColor? {
        guard let id = selectedColorId else { return nil }
        return inventoryManager.allBeadColors.first { $0.id == id }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 色系选择器
                SeriesSelector(
                    series: colorSeries,
                    selectedSeries: $selectedSeries
                )
                .padding(.vertical, 8)

                // 颜色列表
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(colorsInSeries) { color in
                            Button {
                                selectedColorId = color.id
                            } label: {
                                HStack(spacing: 12) {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(color.color)
                                        .frame(width: 36, height: 36)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                        )

                                    Text(color.mardCode)
                                        .font(.system(.body, design: .monospaced))
                                        .fontWeight(.medium)
                                        .foregroundColor(.primary)

                                    Spacer()

                                    if selectedColorId == color.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                                .padding(10)
                                .background(selectedColorId == color.id ? Color.accentColor.opacity(0.1) : Color(.systemBackground))
                                .cornerRadius(10)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 100)
                }

                // 底部确认栏
                if selectedColor != nil {
                    VStack(spacing: 0) {
                        Divider()

                        VStack(spacing: 12) {
                            // 已选颜色
                            HStack {
                                if let color = selectedColor {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(color.color)
                                        .frame(width: 24, height: 24)
                                    Text(color.mardCode)
                                        .font(.headline)
                                }
                                Spacer()
                            }

                            // 数量选择
                            HStack {
                                Text("数量（千颗）")
                                    .foregroundColor(.secondary)
                                Spacer()

                                HStack(spacing: 12) {
                                    Button {
                                        if quantity > 1 {
                                            quantity -= 1
                                        }
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .font(.title2)
                                            .foregroundColor(quantity > 1 ? .blue : .gray)
                                    }
                                    .disabled(quantity <= 1)

                                    Text("\(Int(quantity))")
                                        .font(.title3)
                                        .fontWeight(.semibold)
                                        .frame(minWidth: 40)

                                    Button {
                                        quantity += 1
                                    } label: {
                                        Image(systemName: "plus.circle.fill")
                                            .font(.title2)
                                            .foregroundColor(.blue)
                                    }
                                }
                            }

                            Button {
                                if let color = selectedColor {
                                    onAdd(color.mardCode, Int(quantity * 1000))
                                    dismiss()
                                }
                            } label: {
                                Text("添加 \(Int(quantity * 1000)) 颗")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.accentColor)
                                    .cornerRadius(12)
                            }
                        }
                        .padding()
                        .background(Color(.systemBackground))
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("添加颜色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        ShippingView()
            .environmentObject(InventoryManager())
    }
}
