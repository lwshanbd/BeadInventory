//
//  PatternCalibrationView.swift
//  BeadInventory
//
//  拼图模式 - 网格标定页（PR1 占位，PR2 实现完整 UI）
//

import SwiftUI

struct PatternCalibrationView: View {
    let project: ProjectRecord

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "square.grid.3x3.square")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)

                Text("拼图模式")
                    .font(.title)
                    .bold()

                Text("项目：\(project.name)")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Text("网格标定 UI 将在 PR2 实现")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)

                if project.thumbnail == nil {
                    Text("⚠️ 此项目无图片，无法标定")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                Spacer()
            }
            .padding(.top, 80)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("标定网格")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    PatternCalibrationView(project: ProjectRecord(name: "示例项目"))
}
