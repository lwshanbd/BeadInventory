//
//  BISegmented.swift
//  BeadInventory
//
//  跑道型分段控件：选中项用 elevated 底 + 描边（浅色另有柔和投影，深色投影归零），未选中透明。
//

import SwiftUI

struct BISegmented<T: Hashable>: View {
    @Binding var selection: T
    var segments: [(value: T, label: String)]
    var fillWidth: Bool = false

    init(
        selection: Binding<T>,
        segments: [(value: T, label: String)],
        fillWidth: Bool = false
    ) {
        self._selection = selection
        self.segments = segments
        self.fillWidth = fillWidth
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(segments, id: \.value) { seg in
                segmentButton(seg.value, label: seg.label)
            }
        }
        .padding(3)
        .background(Theme.ColorToken.Surface.subtle)
        .clipShape(Capsule())
        // 铺满宽度也有个头：iPhone Duo 内屏、iPad 上横向有一千多点，两个字的段被拉成
        // 半屏宽的长条，眼睛得左右扫一大截才看到另一段。普通 iPhone 比这窄，不受影响。
        .frame(maxWidth: fillWidth ? CGFloat(segments.count) * 200 : nil)
    }

    @ViewBuilder
    private func segmentButton(_ value: T, label: String) -> some View {
        let isSelected = selection == value
        Button {
            selection = value
        } label: {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? Theme.ColorToken.Text.primary : Theme.ColorToken.Text.secondary)
                .padding(.vertical, 7)
                .padding(.horizontal, 14)
                .frame(maxWidth: fillWidth ? .infinity : nil)
                .background(
                    Group {
                        if isSelected {
                            // 深色下 elevated 与轨道底几乎同亮度、黑投影又不可见，
                            // 补一圈描边保证选中态可辨。
                            Capsule()
                                .fill(Theme.ColorToken.Surface.elevated)
                                .overlay(Capsule().strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1))
                                .shadow(color: Theme.ColorToken.Shadow.soft, radius: 1, x: 0, y: 1)
                        } else {
                            Color.clear
                        }
                    }
                )
                .clipShape(Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
