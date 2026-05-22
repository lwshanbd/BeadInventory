//
//  BIChip.swift
//  BeadInventory
//
//  胶囊型 Chip：支持激活态着色，可选前置图标视图。
//

import SwiftUI

enum ChipSize {
    case sm, md
}

struct BIChip<Leading: View>: View {
    var label: String
    var active: Bool
    var color: Color?
    var size: ChipSize
    @ViewBuilder var leading: () -> Leading

    @Environment(\.tabFlavor) private var flavor

    init(
        label: String,
        active: Bool = false,
        color: Color? = nil,
        size: ChipSize = .md,
        @ViewBuilder leading: @escaping () -> Leading
    ) {
        self.label = label
        self.active = active
        self.color = color
        self.size = size
        self.leading = leading
    }

    private var resolvedActiveColor: Color {
        color ?? flavor.color
    }

    private var background: Color {
        active ? resolvedActiveColor : Theme.ColorToken.Surface.subtle
    }

    private var foreground: Color {
        active ? Color.white : Theme.ColorToken.Text.secondary
    }

    private var font: Font {
        switch size {
        case .sm: return .caption.weight(.semibold)
        case .md: return .subheadline.weight(.semibold)
        }
    }

    private var verticalPadding: CGFloat {
        switch size {
        case .sm: return 4
        case .md: return 6
        }
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .sm: return 10
        case .md: return 12
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            leading()
            Text(label)
                .font(font)
        }
        .foregroundStyle(foreground)
        .padding(.vertical, verticalPadding)
        .padding(.horizontal, horizontalPadding)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.pill))
    }
}

extension BIChip where Leading == EmptyView {
    init(
        _ label: String,
        active: Bool = false,
        color: Color? = nil,
        size: ChipSize = .md
    ) {
        self.label = label
        self.active = active
        self.color = color
        self.size = size
        self.leading = { EmptyView() }
    }
}
