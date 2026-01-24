//
//  MoreView.swift
//  BeadInventory
//
//  更多功能页面
//

import SwiftUI

struct MoreView: View {
    @State private var showingImportFullData = false

    var body: some View {
        NavigationStack {
            List {
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
                                Text("自定义颜色")
                                Text("添加和管理自己的颜色")
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
