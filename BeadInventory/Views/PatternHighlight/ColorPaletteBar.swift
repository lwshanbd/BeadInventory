//
//  ColorPaletteBar.swift
//  BeadInventory
//
//  高亮页底部的色号条：点一个色号，图上就只亮它那些格子。
//
//  数字写的是**图上认出来多少格**，不是色号表里写的多少颗。用户此刻正拿着豆子对着屏幕，
//  他要点亮的是「图上这些格」，那就该报图上的数；跟色号表对不对得上是上面那条横幅的事。
//

import SwiftUI

struct ColorPaletteBar: View {
    struct Entry: Identifiable {
        let code: String
        /// 图上认出来多少格
        let count: Int
        /// 这个色号不在图纸的色号表里（多半是判色时套到了一个表上没有的色号）。
        /// 用虚线圈标出来 —— 它照样能点亮，但值得用户看一眼。
        let isExtra: Bool
        /// 这个色号已经标过「拼完了」。角上挂个勾，色号本身压淡一档。
        let isDone: Bool
        /// 这颗豆子长什么样。**由调用方查好再传进来**：色号→颜色这件事按色号体系分流
        /// （MARD 走 `findColor(byMardCode:)`，别的走 `findColor(byCode:preferSystem:)`），
        /// 这里自己扫一遍 `availableColors` 会跟核对页查出不同的颜色 ——
        /// 同一个色号在两屏上显示成两种颜色，用户只会以为自己看错了。
        let color: Color

        var id: String { code }
    }

    let entries: [Entry]
    @Binding var highlightedCodes: Set<String>

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(entries) { entry in
                    paletteChip(entry)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.regularMaterial)
    }

    private func paletteChip(_ entry: Entry) -> some View {
        let isSelected = highlightedCodes.contains(entry.code)
        return Button {
            if isSelected { highlightedCodes.remove(entry.code) }
            else { highlightedCodes.insert(entry.code) }
        } label: {
            VStack(spacing: 4) {
                Circle()
                    .fill(entry.color)
                    .frame(width: 32, height: 32)
                    .overlay(Circle().stroke(
                        isSelected ? Theme.ColorToken.Morandi.mauve :
                            (entry.isExtra ? Theme.ColorToken.Text.tertiary : Theme.ColorToken.Border.default),
                        lineWidth: isSelected ? 3 : (entry.isExtra ? 1.5 : 1)
                    ))
                    .overlay(
                        entry.isExtra
                            ? AnyView(
                                Circle()
                                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                                    .frame(width: 36, height: 36)
                            )
                            : AnyView(EmptyView())
                    )
                    // 勾压在圆点里面、**不往外探**：这条色号条是横向 ScrollView，
                    // 探出边的那半个勾会被它切掉。底下垫一圈白 —— 绿勾落在绿豆子上时，
                    // 不垫就跟底色糊成一团。圆点本身一点都不压暗：用户就是靠这块颜色
                    // 去认手上那袋豆子的。
                    .overlay(alignment: .topTrailing) {
                        if entry.isDone {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Theme.ColorToken.Text.onAccent,
                                                 Theme.ColorToken.Status.success)
                                .background(Circle().fill(Theme.ColorToken.Text.onAccent))
                        }
                    }
                Text(entry.code)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(entry.isExtra || entry.isDone ? .secondary : .primary)
                Text("\(entry.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(isSelected ? Theme.ColorToken.Morandi.mauve.opacity(0.15) : Color.clear)
            .cornerRadius(Theme.Radius.sm)
        }
        .buttonStyle(.plain)
    }
}
