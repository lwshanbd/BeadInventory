//
//  AboutView.swift
//  BeadInventory
//
//  关于界面
//

import SwiftUI

struct AboutView: View {
    @EnvironmentObject var inventoryManager: InventoryManager

    var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "版本 \(version)"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                // App 图标和名称
                VStack(spacing: 16) {
                    Image("AppIconImage")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
                        .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 4)

                    Text("啃豆小仓")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text(appVersion)
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
                        Text("YJ")
                            .fontWeight(.semibold)
                            .foregroundColor(.pink)
                    }
                    .font(.title2)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.lg)
                        .fill(Theme.ColorToken.Status.error.opacity(0.1))
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
                .background(Theme.ColorToken.Surface.subtle)
                .cornerRadius(Theme.Radius.lg)
                .padding(.horizontal)

                // 开发者信息
                VStack(spacing: 16) {
                    Text("开发者")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack {
                        Image(systemName: "person.fill")
                            .foregroundColor(.accentColor)
                            .frame(width: 24)
                        Text("BD")
                            .fontWeight(.medium)
                        Spacer()
                    }
                }
                .padding()
                .background(Theme.ColorToken.Surface.subtle)
                .cornerRadius(Theme.Radius.lg)
                .padding(.horizontal)

                // 特别感谢
                VStack(spacing: 12) {
                    Text("特别感谢")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 8) {
                        Image(systemName: "pawprint.fill")
                            .foregroundColor(Theme.ColorToken.Status.warning)
                        Text("啃宝")
                            .fontWeight(.medium)
                        Text("&")
                            .foregroundColor(.secondary)
                        Text("Timea")
                            .fontWeight(.medium)
                        Image(systemName: "pawprint.fill")
                            .foregroundColor(Theme.ColorToken.Status.warning)
                    }
                    .font(.subheadline)

                    Text("感谢两位猫猫的陪伴")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Theme.ColorToken.Surface.subtle)
                .cornerRadius(Theme.Radius.lg)
                .padding(.horizontal)

                // 原创声明
                VStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.title2)
                        .foregroundColor(Theme.ColorToken.Status.info)
                    Text("支持原创，拒绝抄袭")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("啃豆小仓与每一份拼豆图纸都凝聚着创作者的心血，请尊重原创")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.lg)
                        .fill(Theme.ColorToken.Status.info.opacity(0.1))
                )
                .padding(.horizontal)

                // 致谢
                VStack(spacing: 8) {
                    Text("感谢使用啃豆小仓")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Text("2026")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Text("鲁ICP备2026003850号-1A")
                        .font(.caption2)
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
