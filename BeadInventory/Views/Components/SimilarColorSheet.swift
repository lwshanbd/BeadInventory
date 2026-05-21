//
//  SimilarColorSheet.swift
//  BeadInventory
//
//  相似色选择弹窗
//

import SwiftUI

struct SimilarColorSheet: View {
    let originalColor: BeadColor?
    let originalColorCode: String
    let similarColors: [SimilarColor]
    let colorSystem: ColorSystem
    var onSelect: (SimilarColor) -> Void

    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let color = originalColor {
                    Section("原色") {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                .fill(color.color)
                                .frame(width: 48, height: 48)
                                .overlay(
                                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                )
                            VStack(alignment: .leading) {
                                Text(originalColorCode)
                                    .font(.system(.body, design: .monospaced))
                                    .fontWeight(.medium)
                                if !color.colorName.isEmpty {
                                    Text(color.colorName)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .listRowBackground(Color(.systemGray6))
                    }
                }

                if similarColors.isEmpty {
                    Section {
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundColor(.secondary)
                            Text("未找到相似色")
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    Section("可用相似色") {
                        ForEach(similarColors, id: \.beadColor.id) { similar in
                            Button {
                                onSelect(similar)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                        .fill(similar.beadColor.color)
                                        .frame(width: 48, height: 48)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                        )

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(similar.beadColor.displayCode(for: colorSystem))
                                            .font(.system(.body, design: .monospaced))
                                            .fontWeight(.medium)
                                            .foregroundColor(.primary)
                                        if !similar.beadColor.colorName.isEmpty {
                                            Text(similar.beadColor.colorName)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }

                                    Spacer()

                                    VStack(alignment: .trailing) {
                                        Text("库存 \(similar.availableStock)")
                                            .font(.caption)
                                            .foregroundColor(.green)
                                    }

                                    Image(systemName: "arrow.right.circle.fill")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("查找相似色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
