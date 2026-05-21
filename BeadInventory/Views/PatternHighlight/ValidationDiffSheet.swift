//
//  ValidationDiffSheet.swift
//  BeadInventory
//
//  网格 vs 图例差异展示 + 一键修正
//

import SwiftUI

struct ValidationDiffSheet: View {
    let diffs: [GridValidationDiff]
    let onAdoptGridForCode: (String, Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(diffs) { d in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(d.code)
                                    .font(.headline)
                                Spacer()
                                deltaBadge(d: d)
                            }
                            HStack(spacing: 12) {
                                statLabel(title: "网格识别", value: d.gridCount, color: .blue)
                                statLabel(title: "图例标注", value: d.legendCount, color: .gray)
                                Spacer()
                                Button("以网格为准") {
                                    onAdoptGridForCode(d.code, d.gridCount)
                                }
                                .font(.caption)
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } footer: {
                    Text("点击「以网格为准」将该色号的图例用量更新为网格识别的数量。")
                        .font(.caption2)
                }
            }
            .navigationTitle("识别差异 (\(diffs.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func statLabel(title: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text("\(value)")
                .font(.headline)
                .foregroundStyle(color)
        }
    }

    private func deltaBadge(d: GridValidationDiff) -> some View {
        let txt = d.delta > 0 ? "+\(d.delta)" : "\(d.delta)"
        return Text(txt)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(d.delta > 0 ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
            .foregroundStyle(d.delta > 0 ? Color.green : Color.red)
            .cornerRadius(Theme.Radius.sm)
    }
}
