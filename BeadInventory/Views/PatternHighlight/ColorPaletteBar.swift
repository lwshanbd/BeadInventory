//
//  ColorPaletteBar.swift
//  BeadInventory
//
//  底部调色板：项目用到的色号 + 网格里识别到但不在图例的额外色号（标注"空白格"）
//

import SwiftUI

struct ColorPaletteBar: View {
    let beadUsage: [BeadUsage]
    /// 在 cellColorCodes 出现但不在 beadUsage 的色号 + 数量（典型：H2 用于空白格）
    let extraCodes: [(code: String, count: Int)]
    let colorSystem: ColorSystem
    @Binding var highlightedCodes: Set<String>
    let availableColors: [BeadColor]

    private var sortedUsage: [BeadUsage] {
        beadUsage.sorted { $0.quantity > $1.quantity }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sortedUsage, id: \.id) { usage in
                    paletteChip(code: usage.colorCode, count: usage.quantity, isExtra: false)
                }
                ForEach(extraCodes, id: \.code) { extra in
                    paletteChip(code: extra.code, count: extra.count, isExtra: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.regularMaterial)
    }

    private func paletteChip(code: String, count: Int, isExtra: Bool) -> some View {
        let isSelected = highlightedCodes.contains(code)
        let hex = availableColors.first { $0.displayCode(for: colorSystem) == code }?
            .colorHex ?? "#CCCCCC"
        let labelText = isExtra ? "\(code)(空白)" : code
        return Button {
            if isSelected { highlightedCodes.remove(code) }
            else { highlightedCodes.insert(code) }
        } label: {
            VStack(spacing: 4) {
                Circle()
                    .fill(Color(hex: hex))
                    .frame(width: 32, height: 32)
                    .overlay(Circle().stroke(
                        isSelected ? Color.accentColor :
                            (isExtra ? Theme.ColorToken.Text.tertiary : Theme.ColorToken.Border.default),
                        lineWidth: isSelected ? 3 : (isExtra ? 1.5 : 1)
                    ))
                    // 额外色号用虚线圈标记
                    .overlay(
                        isExtra
                            ? AnyView(
                                Circle()
                                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                                    .frame(width: 36, height: 36)
                            )
                            : AnyView(EmptyView())
                    )
                Text(labelText)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(isExtra ? .secondary : .primary)
                Text("\(count)")
                    .font(.caption2)
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            .cornerRadius(Theme.Radius.sm)
        }
        .buttonStyle(.plain)
    }
}
