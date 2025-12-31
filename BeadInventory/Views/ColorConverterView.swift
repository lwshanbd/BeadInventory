//
//  ColorConverterView.swift
//  BeadInventory
//
//  色号转换查询界面
//

import SwiftUI

struct ColorConverterView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var searchText = ""
    @State private var selectedColor: BeadColor?

    var searchResults: [BeadColor] {
        inventoryManager.searchColors(searchText)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 搜索框
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)

                    TextField("输入任意品牌色号查询...", text: $searchText)
                        .textInputAutocapitalization(.characters)

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding()
                .background(Color(.systemBackground))
                .cornerRadius(12)
                .padding()

                // 搜索结果
                if searchText.isEmpty {
                    // 空状态
                    VStack(spacing: 16) {
                        Image(systemName: "paintpalette")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary.opacity(0.5))

                        Text("输入色号查询转换")
                            .font(.headline)
                            .foregroundColor(.secondary)

                        Text("支持 MARD、COCO、漫漫、盼盼、咪小窝 色号")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxHeight: .infinity)
                } else if searchResults.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary.opacity(0.5))

                        Text("未找到匹配的色号")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(searchResults) { color in
                                ColorConversionCard(color: color)
                                    .onTapGesture {
                                        selectedColor = color
                                    }
                            }
                        }
                        .padding()
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("色号转换")
            .sheet(item: $selectedColor) { color in
                ColorDetailSheet(color: color)
            }
        }
    }
}

// MARK: - 色号转换卡片
struct ColorConversionCard: View {
    let color: BeadColor

    var body: some View {
        HStack(spacing: 16) {
            // 颜色预览
            RoundedRectangle(cornerRadius: 10)
                .fill(color.color)
                .frame(width: 60, height: 60)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )

            // 各品牌色号
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    BrandCodeLabel(brand: "MARD", code: color.mardCode, color: .blue)
                    BrandCodeLabel(brand: "COCO", code: color.cocoCode, color: .purple)
                    BrandCodeLabel(brand: "漫漫", code: color.manmanCode, color: .orange)
                }

                HStack(spacing: 8) {
                    BrandCodeLabel(brand: "盼盼", code: color.panpanCode, color: .green)
                    BrandCodeLabel(brand: "咪小窝", code: color.mixiaowoCode, color: .pink)
                }
            }

            Spacer()

            // 库存状态
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(color.available)")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(color.available < 100 ? .red : .primary)

                Text("可用")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
    }
}

struct BrandCodeLabel: View {
    let brand: String
    let code: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(brand)
                .font(.caption2)
                .foregroundColor(.secondary)

            Text(code.isEmpty ? "-" : code)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color.opacity(0.15))
                .foregroundColor(color)
                .cornerRadius(4)
        }
    }
}

// MARK: - 颜色详情弹窗
struct ColorDetailSheet: View {
    let color: BeadColor
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // 大颜色预览
                    RoundedRectangle(cornerRadius: 20)
                        .fill(color.color)
                        .frame(height: 150)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 2)
                        )
                        .shadow(color: color.color.opacity(0.3), radius: 10, x: 0, y: 5)

                    Text(color.colorName)
                        .font(.title2)
                        .fontWeight(.bold)

                    // 色号对照表
                    VStack(spacing: 0) {
                        ConversionRow(brand: "MARD", code: color.mardCode, brandColor: .blue)
                        Divider()
                        ConversionRow(brand: "COCO", code: color.cocoCode, brandColor: .purple)
                        Divider()
                        ConversionRow(brand: "漫漫", code: color.manmanCode, brandColor: .orange)
                        Divider()
                        ConversionRow(brand: "盼盼", code: color.panpanCode, brandColor: .green)
                        Divider()
                        ConversionRow(brand: "咪小窝", code: color.mixiaowoCode, brandColor: .pink)
                    }
                    .background(Color(.systemBackground))
                    .cornerRadius(16)

                    // 库存信息
                    VStack(spacing: 0) {
                        HStack {
                            Text("总库存")
                            Spacer()
                            Text("\(color.stock)")
                                .fontWeight(.medium)
                        }
                        .padding()

                        Divider()

                        HStack {
                            Text("已使用")
                            Spacer()
                            Text("\(color.used)")
                                .fontWeight(.medium)
                                .foregroundColor(.orange)
                        }
                        .padding()

                        Divider()

                        HStack {
                            Text("可用数量")
                            Spacer()
                            Text("\(color.available)")
                                .fontWeight(.bold)
                                .foregroundColor(color.available < 100 ? .red : .green)
                        }
                        .padding()
                    }
                    .background(Color(.systemBackground))
                    .cornerRadius(16)

                    // 颜色代码
                    VStack(spacing: 0) {
                        HStack {
                            Text("HEX")
                            Spacer()
                            Text("#\(color.colorHex)")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)

                            Button {
                                UIPasteboard.general.string = "#\(color.colorHex)"
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding()
                    }
                    .background(Color(.systemBackground))
                    .cornerRadius(16)
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("颜色详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

struct ConversionRow: View {
    let brand: String
    let code: String
    let brandColor: Color

    var body: some View {
        HStack {
            Text(brand)
                .foregroundColor(.secondary)

            Spacer()

            if code.isEmpty {
                Text("-")
                    .foregroundColor(.secondary)
            } else {
                Text(code)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.semibold)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(brandColor.opacity(0.15))
                    .foregroundColor(brandColor)
                    .cornerRadius(8)
            }

            Button {
                if !code.isEmpty {
                    UIPasteboard.general.string = code
                }
            } label: {
                Image(systemName: "doc.on.doc")
                    .foregroundColor(code.isEmpty ? .gray : .accentColor)
            }
            .disabled(code.isEmpty)
        }
        .padding()
    }
}

#Preview {
    ColorConverterView()
        .environmentObject(InventoryManager())
}
