//
//  AboutView.swift
//  BeadInventory
//
//  关于界面
//

import SwiftUI

struct AboutView: View {
    @EnvironmentObject var inventoryManager: InventoryManager

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                // App 图标和名称
                VStack(spacing: 16) {
                    Image(systemName: "circle.grid.3x3.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.pink, .purple, .blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    Text("啃豆小仓")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text("版本 1.0.0")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 40)

                // 献给 Yujia
                VStack(spacing: 12) {
                    Text("Made with")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    HStack(spacing: 4) {
                        Image(systemName: "heart.fill")
                            .foregroundColor(.pink)
                        Text("for")
                            .foregroundColor(.secondary)
                        Text("Yujia")
                            .fontWeight(.semibold)
                            .foregroundColor(.pink)
                    }
                    .font(.title2)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.pink.opacity(0.1))
                )
                .padding(.horizontal)

                // 统计信息
                VStack(spacing: 16) {
                    Text("应用数据")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 20) {
                        StatBlock(
                            icon: "paintpalette.fill",
                            value: "\(inventoryManager.beadColors.count)",
                            label: "颜色",
                            color: .blue
                        )
                        StatBlock(
                            icon: "building.2.fill",
                            value: "\(inventoryManager.brands.count)",
                            label: "品牌",
                            color: .purple
                        )
                        StatBlock(
                            icon: "doc.text.fill",
                            value: "\(inventoryManager.projects.count)",
                            label: "项目",
                            color: .orange
                        )
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(16)
                .padding(.horizontal)

                // 开发者信息
                VStack(spacing: 16) {
                    Text("开发者")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(spacing: 12) {
                        HStack {
                            Image(systemName: "person.fill")
                                .foregroundColor(.accentColor)
                                .frame(width: 24)
                            Text("Baodi Shan")
                                .fontWeight(.medium)
                            Spacer()
                        }

                        HStack {
                            Image(systemName: "envelope.fill")
                                .foregroundColor(.accentColor)
                                .frame(width: 24)
                            Link("lwshanbd@gmail.com", destination: URL(string: "mailto:lwshanbd@gmail.com")!)
                                .foregroundColor(.accentColor)
                            Spacer()
                        }
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(16)
                .padding(.horizontal)

                // 特别感谢
                VStack(spacing: 12) {
                    Text("特别感谢")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 8) {
                        Image(systemName: "pawprint.fill")
                            .foregroundColor(.orange)
                        Text("啃宝")
                            .fontWeight(.medium)
                        Text("&")
                            .foregroundColor(.secondary)
                        Text("Timea")
                            .fontWeight(.medium)
                        Image(systemName: "pawprint.fill")
                            .foregroundColor(.orange)
                    }
                    .font(.subheadline)

                    Text("感谢两位猫猫的陪伴")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(16)
                .padding(.horizontal)

                // 致谢
                VStack(spacing: 8) {
                    Text("感谢使用啃豆小仓")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Text("2024")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 20)
                .padding(.bottom, 40)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 统计块
struct StatBlock: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)

            Text(value)
                .font(.title2)
                .fontWeight(.bold)

            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    NavigationStack {
        AboutView()
            .environmentObject(InventoryManager())
    }
}
