//
//  BIStatBar.swift
//  BeadInventory
//
//  横向 3 格统计条 + 下方细进度条。
//  支持单元格警示态（warn）改用错误色强调。
//

import SwiftUI

struct BIStatBar: View {
    struct Cell {
        let label: String
        let value: String
        let sub: String
        var warn: Bool = false

        init(label: String, value: String, sub: String, warn: Bool = false) {
            self.label = label
            self.value = value
            self.sub = sub
            self.warn = warn
        }
    }

    var cells: [Cell]
    var progress: Double
    var progressColor: Color
    var progressLabel: String?

    init(
        cells: [Cell],
        progress: Double,
        progressColor: Color,
        progressLabel: String? = nil
    ) {
        self.cells = cells
        self.progress = progress
        self.progressColor = progressColor
        self.progressLabel = progressLabel
    }

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    private var resolvedProgressLabel: String {
        if let progressLabel { return progressLabel }
        return String(format: "%.1f%% 用量", clampedProgress * 100)
    }

    var body: some View {
        VStack(spacing: 8) {
            // 卡片：3 格
            HStack(spacing: 0) {
                ForEach(Array(cells.enumerated()), id: \.offset) { idx, cell in
                    cellView(cell)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if idx < cells.count - 1 {
                        Rectangle()
                            .fill(Theme.ColorToken.Border.divider)
                            .frame(width: 1, height: 28)
                            .padding(.horizontal, 10)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Theme.ColorToken.Surface.elevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
            )

            // 进度条 + 标签
            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(Theme.ColorToken.Surface.strong)
                            .frame(height: 5)
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(progressColor)
                            .frame(width: geo.size.width * CGFloat(clampedProgress), height: 5)
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 5)

                Text(resolvedProgressLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.ColorToken.Text.tertiary)
            }
        }
    }

    @ViewBuilder
    private func cellView(_ cell: Cell) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(cell.label)
                .font(.caption2)
                .foregroundStyle(Theme.ColorToken.Text.secondary)
                .tracking(0.4)
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                // 配合 InventoryView.formatLocale 的紧凑单位：单行 + 最多缩到 60%，
                // 防止极端宽度（不同 locale 的 compact 输出长度差异 / Dynamic Type）下溢出。
                Text(cell.value)
                    .font(.system(size: 22, weight: .semibold).monospacedDigit())
                    .foregroundStyle(cell.warn ? Theme.ColorToken.Status.error : Theme.ColorToken.Text.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(cell.sub)
                    .font(.system(size: 10))
                    .foregroundStyle(cell.warn ? Theme.ColorToken.Status.error : Theme.ColorToken.Text.tertiary)
                    .lineLimit(1)
            }
        }
    }
}
