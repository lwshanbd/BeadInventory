//
//  BIStepper.swift
//  BeadInventory
//
//  三段式进度指示器：识别 → 调整 → 确认。
//  纯视觉组件，颜色跟随 tabFlavor 环境。
//

import SwiftUI

struct BIStepper: View {
    let steps: [String]
    let currentIndex: Int

    @Environment(\.tabFlavor) private var flavor

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ForEach(Array(steps.enumerated()), id: \.offset) { idx, label in
                stepDot(idx: idx, label: label)
                if idx < steps.count - 1 {
                    Rectangle()
                        .fill(idx < currentIndex ? flavor.color : Theme.ColorToken.Border.divider)
                        .frame(height: 2)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    private func stepDot(idx: Int, label: String) -> some View {
        VStack(spacing: Theme.Spacing.xs) {
            ZStack {
                Circle()
                    .fill(idx <= currentIndex ? flavor.color : Theme.ColorToken.Surface.subtle)
                    .frame(width: 24, height: 24)
                if idx < currentIndex {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(idx + 1)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(idx == currentIndex ? .white : Theme.ColorToken.Text.tertiary)
                }
            }
            Text(label)
                .font(Theme.Typography.metadata)
                .foregroundStyle(idx <= currentIndex ? Theme.ColorToken.Text.primary : Theme.ColorToken.Text.tertiary)
        }
    }
}
