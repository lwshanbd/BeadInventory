//
//  SettingsView.swift
//  BeadInventory
//
//  设置界面
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var showingResetAlert = false
    @State private var showingResetUsageAlert = false
    @State private var defaultStock = "1000"
    @State private var showingImportSheet = false

    var body: some View {
        NavigationStack {
            List {
                // 库存设置
                Section {
                    HStack {
                        Text("默认初始库存")
                        Spacer()
                        TextField("1000", text: $defaultStock)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }

                    Button {
                        showingResetAlert = true
                    } label: {
                        HStack {
                            Image(systemName: "arrow.counterclockwise")
                            Text("重置所有库存")
                        }
                        .foregroundColor(.orange)
                    }

                    Button {
                        showingResetUsageAlert = true
                    } label: {
                        HStack {
                            Image(systemName: "xmark.circle")
                            Text("清除使用记录")
                        }
                        .foregroundColor(.red)
                    }
                } header: {
                    Text("库存设置")
                }

                // 数据管理
                Section {
                    Button {
                        showingImportSheet = true
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.down")
                            Text("导入色号表")
                        }
                    }

                    Button {
                        exportData()
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text("导出库存数据")
                        }
                    }
                } header: {
                    Text("数据管理")
                }

                // 关于
                Section {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("颜色数量")
                        Spacer()
                        Text("\(inventoryManager.beadColors.count) 色")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("项目数量")
                        Spacer()
                        Text("\(inventoryManager.projects.count) 个")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("关于")
                }

                // 使用说明
                Section {
                    NavigationLink {
                        HelpView()
                    } label: {
                        HStack {
                            Image(systemName: "questionmark.circle")
                            Text("使用帮助")
                        }
                    }
                }
            }
            .navigationTitle("设置")
            .alert("重置库存", isPresented: $showingResetAlert) {
                Button("取消", role: .cancel) { }
                Button("重置", role: .destructive) {
                    let stock = Int(defaultStock) ?? 1000
                    inventoryManager.resetAllStock(to: stock)
                }
            } message: {
                Text("将所有颜色的库存重置为 \(defaultStock) 颗，使用记录也将清零。此操作不可撤销。")
            }
            .alert("清除使用记录", isPresented: $showingResetUsageAlert) {
                Button("取消", role: .cancel) { }
                Button("清除", role: .destructive) {
                    inventoryManager.resetUsage()
                }
            } message: {
                Text("将清除所有颜色的使用记录，库存数量不变。此操作不可撤销。")
            }
            .sheet(isPresented: $showingImportSheet) {
                ImportColorSheet()
            }
        }
    }

    func exportData() {
        // 生成CSV格式数据
        var csv = "MARD色号,vivid色号,漫漫色号,卡卡色号,颜色名称,库存,已用,可用\n"
        for color in inventoryManager.beadColors {
            csv += "\(color.mardCode),\(color.vividCode),\(color.manmanCode),\(color.kakaCode),\(color.colorName),\(color.stock),\(color.used),\(color.available)\n"
        }

        // 复制到剪贴板
        UIPasteboard.general.string = csv

        // 实际应用中可以使用UIActivityViewController分享
    }
}

// MARK: - 导入色号表
struct ImportColorSheet: View {
    @Environment(\.dismiss) var dismiss
    @State private var csvText = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("粘贴CSV格式的色号对照表")
                    .font(.headline)

                Text("格式：MARD色号,vivid色号,漫漫色号,卡卡色号,颜色名称,HEX颜色")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextEditor(text: $csvText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 200)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )

                Button {
                    importColors()
                } label: {
                    Text("导入")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .disabled(csvText.isEmpty)

                Spacer()
            }
            .padding()
            .navigationTitle("导入色号表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    func importColors() {
        // TODO: 实现CSV解析和导入
        dismiss()
    }
}

// MARK: - 帮助页面
struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HelpSection(
                    icon: "square.grid.3x3.fill",
                    title: "库存管理",
                    content: """
                    • 查看所有颜色的库存状态
                    • 点击颜色卡片可编辑库存
                    • 支持按品牌色号显示
                    • 可搜索任意品牌的色号
                    """
                )

                HelpSection(
                    icon: "doc.text.viewfinder",
                    title: "图纸扫描",
                    content: """
                    • 拍照或选择色号表格图片
                    • 自动识别色号和数量
                    • 可手动编辑识别结果
                    • 确认后自动从库存扣减
                    """
                )

                HelpSection(
                    icon: "paintpalette.fill",
                    title: "色号转换",
                    content: """
                    • 输入任意品牌色号查询
                    • 自动显示对应的其他品牌色号
                    • 支持 MARD、vivid、漫漫、卡卡
                    • 点击可复制色号
                    """
                )

                HelpSection(
                    icon: "chart.bar.fill",
                    title: "统计功能",
                    content: """
                    • 查看整体库存使用情况
                    • 使用量排行榜
                    • 低库存预警
                    • 项目历史记录
                    """
                )

                HelpSection(
                    icon: "lightbulb.fill",
                    title: "使用技巧",
                    content: """
                    • 建议初始库存设为1000颗/色
                    • 识别有水印图片时，可手动调整结果
                    • 定期导出数据做备份
                    • 低库存颜色会红色标识
                    """
                )
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("使用帮助")
    }
}

struct HelpSection: View {
    let icon: String
    let title: String
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.accentColor)
                    .font(.title2)

                Text(title)
                    .font(.headline)
            }

            Text(content)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
        .cornerRadius(16)
    }
}

#Preview {
    SettingsView()
        .environmentObject(InventoryManager())
}
