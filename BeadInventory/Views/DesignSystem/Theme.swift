import SwiftUI

enum Theme {

    // MARK: - Spacing
    enum Spacing {
        static let xs:  CGFloat = 4
        static let sm:  CGFloat = 8
        static let md:  CGFloat = 12
        static let lg:  CGFloat = 16
        static let xl:  CGFloat = 20
        static let xxl: CGFloat = 24
    }

    // MARK: - Radius
    enum Radius {
        static let sm:   CGFloat = 8
        static let md:   CGFloat = 12
        static let lg:   CGFloat = 16
        static let pill: CGFloat = 999
    }

    // MARK: - Typography
    enum Typography {
        static let pageTitle:     Font = .largeTitle.weight(.bold)
        static let sectionHeader: Font = .headline
        static let cardTitle:     Font = .title3.weight(.semibold)
        static let body:          Font = .body
        static let metadata:      Font = .caption
        static let number:        Font = .title2.monospacedDigit().weight(.semibold)
    }

    // MARK: - Color tokens
    enum ColorToken {

        // Palette accessors（仅 Theme 内部可访问，业务代码不应直接用）
        fileprivate enum Palette {
            static let peach    = Color("Palette/Peach")
            static let coral    = Color("Palette/Coral")
            static let lavender = Color("Palette/Lavender")
            static let mint     = Color("Palette/Mint")
            static let sky      = Color("Palette/Sky")
            static let lemon    = Color("Palette/Lemon")
            static let rose     = Color("Palette/Rose")

            static let n50  = Color("Palette/Neutral50")
            static let n100 = Color("Palette/Neutral100")
            static let n200 = Color("Palette/Neutral200")
            static let n400 = Color("Palette/Neutral400")
            static let n600 = Color("Palette/Neutral600")
            static let n900 = Color("Palette/Neutral900")
        }

        // Semantic tokens
        enum Status {
            static let success = Color("Semantic/Success")
            static let warning = Color("Semantic/Warning")
            static let error   = Color("Semantic/Error")
            static let info    = Color("Semantic/Info")
        }

        enum Text {
            static let primary   = Palette.n900
            static let secondary = Palette.n600
            static let tertiary  = Palette.n400
            static let onAccent  = Color.white
        }

        enum Surface {
            static let background = Color(.systemGroupedBackground)
            static let elevated   = Color(.systemBackground)
            static let subtle     = Palette.n50
        }

        enum Border {
            static let `default` = Palette.n200
            static let divider   = Palette.n100
            // emphasis 依赖 TabFlavor，留到 Task 2 再补
        }

        enum Interactive {
            // primary / secondary 依赖 TabFlavor 环境，留到 Task 2
            static let destructive = Status.error
        }
    }
}
