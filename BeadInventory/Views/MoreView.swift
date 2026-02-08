//
//  MoreView.swift
//  BeadInventory
//
//  更多功能页面
//

import SwiftUI

struct MoreView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var showingImportFullData = false
    @State private var showingScanHelp = false
    @State private var showingBackupRestore = false
    @State private var showingExportSheet = false
    @State private var showingImportColorSheet = false

    var body: some View {
        NavigationStack {
            List {
                // 运输中
                Section {
                    NavigationLink {
                        ShippingView()
                    } label: {
                        Label {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("运输中")
                                    Text("待到货的购买记录")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if !inventoryManager.purchaseRecords.isEmpty {
                                    Text("\(inventoryManager.purchaseRecords.count)")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(Color.orange)
                                        .cornerRadius(10)
                                }
                            }
                        } icon: {
                            Image(systemName: "shippingbox.fill")
                                .foregroundColor(.orange)
                        }
                    }
                }

                // 成品展示
                Section {
                    NavigationLink {
                        CalendarView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("成品日历")
                                Text("按日期查看完成的作品")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "calendar.badge.checkmark")
                                .foregroundColor(.green)
                        }
                    }
                }

                // 历史记录
                Section {
                    NavigationLink {
                        HistoryView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("历史记录")
                                Text("查看操作记录，支持撤回")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundColor(.orange)
                        }
                    }
                }

                // 颜色管理
                Section {
                    NavigationLink {
                        ColorConverterView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("色号转换")
                                Text("不同品牌间的色号对照")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "paintpalette.fill")
                                .foregroundColor(.purple)
                        }
                    }

                    NavigationLink {
                        CustomColorsView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("自定义色号")
                                Text("添加和管理自己的色号")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "eyedropper.halffull")
                                .foregroundColor(.pink)
                        }
                    }
                }

                // 数据管理
                Section {
                    Button {
                        showingExportSheet = true
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("导出库存数据")
                                Text("导出为 CSV 或 JSON 文件")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "square.and.arrow.up.fill")
                                .foregroundColor(.blue)
                        }
                    }
                    .foregroundColor(.primary)

                    Button {
                        showingImportFullData = true
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("导入历史数据")
                                Text("从备份文件恢复全部数据")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "arrow.down.doc.fill")
                                .foregroundColor(.green)
                        }
                    }
                    .foregroundColor(.primary)

                    Button {
                        showingBackupRestore = true
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("恢复备份")
                                Text("从自动备份恢复数据")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "arrow.clockwise.icloud.fill")
                                .foregroundColor(.cyan)
                        }
                    }
                    .foregroundColor(.primary)

                    Button {
                        showingImportColorSheet = true
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("导入色号表")
                                Text("从 CSV 导入色号对照数据")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "tablecells.fill")
                                .foregroundColor(.purple)
                        }
                    }
                    .foregroundColor(.primary)
                }

                // 设置
                Section {
                    NavigationLink {
                        BrandSettingsView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("品牌管理")
                                Text("添加、编辑品牌信息")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "tag.fill")
                                .foregroundColor(.blue)
                        }
                    }

                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("设置")
                                Text("AI识别、库存等配置")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "gearshape.fill")
                                .foregroundColor(.gray)
                        }
                    }
                }

                // 帮助与关于
                Section {
                    Button {
                        showingScanHelp = true
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("AI扫描帮助")
                                Text("查看扫描识别使用说明")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "questionmark.circle.fill")
                                .foregroundColor(.orange)
                        }
                    }
                    .foregroundColor(.primary)

                    NavigationLink {
                        HelpView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("使用帮助")
                                Text("功能介绍与使用技巧")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "book.fill")
                                .foregroundColor(.teal)
                        }
                    }

                    NavigationLink {
                        AboutView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("关于")
                                Text("版本信息")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(.accentColor)
                        }
                    }
                }
            }
            .navigationTitle("更多")
            .sheet(isPresented: $showingImportFullData) {
                ImportFullDataView()
            }
            .sheet(isPresented: $showingScanHelp) {
                ScanHelpSheet(onDismiss: {
                    showingScanHelp = false
                })
            }
            .sheet(isPresented: $showingBackupRestore) {
                BackupRestoreView()
            }
            .sheet(isPresented: $showingExportSheet) {
                ExportDataSheet(inventoryManager: inventoryManager)
            }
            .sheet(isPresented: $showingImportColorSheet) {
                ImportColorSheet()
            }
        }
    }
}

#Preview {
    MoreView()
        .environmentObject(InventoryManager())
}
