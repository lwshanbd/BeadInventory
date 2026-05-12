//
//  ColorPaletteBar.swift
//  BeadInventory
//
//  底部调色板：项目用到的色号，按用量降序，支持多选高亮
//

import SwiftUI

struct ColorPaletteBar: View {
    let beadUsage: [BeadUsage]
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
                    paletteChip(usage: usage)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.regularMaterial)
    }

    private func paletteChip(usage: BeadUsage) -> some View {
        let isSelected = highlightedCodes.contains(usage.colorCode)
        let hex = availableColors.first { $0.displayCode(for: colorSystem) == usage.colorCode }?
            .colorHex ?? "#CCCCCC"
        return Button {
            if isSelected { highlightedCodes.remove(usage.colorCode) }
            else { highlightedCodes.insert(usage.colorCode) }
        } label: {
            VStack(spacing: 4) {
                Circle()
                    .fill(Color(hex: hex))
                    .frame(width: 32, height: 32)
                    .overlay(Circle().stroke(
                        isSelected ? Color.accentColor : Color.gray.opacity(0.4),
                        lineWidth: isSelected ? 3 : 1
                    ))
                Text(usage.colorCode)
                    .font(.caption2)
                    .lineLimit(1)
                Text("\(usage.quantity)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}
