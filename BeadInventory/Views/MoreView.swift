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

                // 设置相关
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
                                Text("数据导出、导入等")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "gearshape.fill")
                                .foregroundColor(.gray)
                        }
                    }

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
                }

                // 关于
                Section {
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("关于")
                                Text("版本信息与帮助")
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
        }
    }
}

#Preview {
    MoreView()
        .environmentObject(InventoryManager())
}
