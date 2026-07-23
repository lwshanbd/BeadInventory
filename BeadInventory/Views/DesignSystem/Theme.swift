//
//  Theme.swift
//  BeadInventory
//
//  设计系统基础 token —— Spacing / Radius / Typography / 三层颜色
//

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
        static let pill: CGFloat = 999  // arbitrarily large — renders as full pill on any realistic component height
    }

    // MARK: - Typography
    enum Typography {
        static let pageTitle:     Font = .largeTitle.weight(.bold)
        static let sectionHeader: Font = .headline
        static let cardTitle:     Font = .title3.weight(.semibold)
        static let body:          Font = .body
        static let metadata:      Font = .caption
        static let number:        Font = .title2.monospacedDigit().weight(.semibold)
        /// Wordmark 字体 —— 设计稿 tokens.css 指定 "ZCOOL KuaiLe"（站酷快乐体，圆润可爱）。
        /// 字体文件 Resources/Fonts/ZCOOLKuaiLe-Regular.ttf，已在 Info.plist UIAppFonts 注册。
        static func wordmark(size: CGFloat = 32) -> Font {
            Font.custom("ZCOOLKuaiLe-Regular", size: size)
        }
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

            // 中性阶不再取固定 Asset，而是随色彩模式的 bg 派生（PaletteDeriver），
            // 保证任意主题下 chip/描边/文字灰阶与页面底色同色调。
            static var n50:  Color { Color(uiColor: ThemeManager.shared.dynamicNeutral(\.n50)) }
            static var n100: Color { Color(uiColor: ThemeManager.shared.dynamicNeutral(\.n100)) }
            static var n200: Color { Color(uiColor: ThemeManager.shared.dynamicNeutral(\.n200)) }
            static var n400: Color { Color(uiColor: ThemeManager.shared.dynamicNeutral(\.n400)) }
            static var n600: Color { Color(uiColor: ThemeManager.shared.dynamicNeutral(\.n600)) }
            static var n900: Color { Color(uiColor: ThemeManager.shared.dynamicNeutral(\.n900)) }
        }

        // Semantic tokens
        enum Status {
            static let success = Color("Semantic/Success")
            static let warning = Color("Semantic/Warning")
            static let error   = Color("Semantic/Error")
            static let info    = Color("Semantic/Info")
        }

        enum Text {
            static var primary:   Color { Palette.n900 }
            static var secondary: Color { Palette.n600 }
            static var tertiary:  Color { Palette.n400 }
            static let onAccent  = Color.white
        }

        enum Surface {
            /// 米奶页面底；运行时由 ThemeManager.shared 提供，自动跟随系统外观
            static var background: Color { Color(uiColor: ThemeManager.shared.dynamicBg) }
            /// 卡片底（偏纯白偏暖）；同上
            static var elevated:   Color { Color(uiColor: ThemeManager.shared.dynamicBgElev) }
            static var subtle: Color { Palette.n50 } // chip / 二级 surface
            static var strong: Color { Color(uiColor: ThemeManager.shared.dynamicNeutral(\.surfaceStrong)) } // 略深的中性
        }

        enum Border {
            static var `default`: Color { Palette.n200 }
            static var divider:   Color { Palette.n100 }
            // emphasis 见文件底部 Theme.ColorToken.Border.emphasisFallback（深层 View 丢失环境时用）；环境感知版请用 @Environment(\.tabFlavor).color。
        }

        enum Interactive {
            // primary 走 @Environment(\.tabFlavor).color；secondary 与 primaryFallback 见文件底部扩展。
            static let destructive = Status.error
        }

        /// 装饰色：用于统计卡片、分组徽章等"需要视觉变化但语义中性"的场景。
        /// 不要把它们当成语义色——绿不代表成功，红不代表错误，仅作风格变化。
        enum Decorative {
            // 原有 5 个保留 (mint/sky/lavender/rose/lemon)
            static var mint:     Color { Palette.mint }
            static var sky:      Color { Palette.sky }
            static var lavender: Color { Palette.lavender }
            static var rose:     Color { Palette.rose }
            static var lemon:    Color { Palette.lemon }
            // 新增 Morandi 命名（指向同一 colorset）
            static var latte: Color { Color("Palette/Peach") }
            static var sage:  Color { Color("Palette/Mint") }
            static var mauve: Color { Color("Palette/Lavender") }
            static var mist:  Color { Color("Palette/Sky") }
            static var honey: Color { Color("Palette/Lemon") }
        }

        /// 奶油拿铁 / 莫兰迪 6 色 · 与设计稿 tokens.css 对齐
        /// 通过现有 Palette/*.colorset 别名，dark mode 自动跟随
        enum Morandi {
            static let latte = Color("Palette/Peach")      // 库存锚 #C8966E
            static let rose  = Color("Palette/Coral")      // 警示/编辑 #C9928E
            static let sage  = Color("Palette/Mint")       // 统计锚 #9FB089
            static let mist  = Color("Palette/Sky")        // 更多锚 #94A8B6
            static let mauve = Color("Palette/Lavender")   // 工作台锚 #B196AE
            static let honey = Color("Palette/Lemon")      // 高亮/计划 #D8B97A
        }

        /// 强调「填充」色：按钮 / FAB / Hero 渐变 / 激活 chip 的底色。
        ///
        /// 与 Morandi（彩色文字、图标用，dark 提亮）不同，Fill 在深色下自动
        /// 「加深」（PaletteDeriver.darkAccentFill），保证 onAccent 白字对比、
        /// 且不会在近黑页面上形成刺眼的浅色块。填充场景一律用 Fill，不用 Morandi。
        enum Fill {
            private static func fill(_ lightHex: String) -> Color {
                Color(uiColor: UIColor { trait in
                    let hex = trait.userInterfaceStyle == .dark
                        ? PaletteDeriver.darkAccentFill(fromLightHex: lightHex)
                        : lightHex
                    return UIColor(themeHex: hex)
                })
            }
            static var latte: Color { fill("C8966E") }
            static var rose:  Color { fill("C9928E") }
            static var sage:  Color { fill("9FB089") }
            static var mist:  Color { fill("94A8B6") }
            static var mauve: Color { fill("B196AE") }
            static var honey: Color { fill("D8B97A") }
            /// 语义色的填充版（Semantic/* light 值，深色自动加深）
            static var error:   Color { fill("B86A60") }
            static var info:    Color { fill("748FA1") }
            static var success: Color { fill("7A9B6A") }
            static var warning: Color { fill("C99659") }
        }

        /// 投影色：深色模式下纯黑投影零可见度且让界面发脏，自动归零；
        /// 深色的分层改由描边（Border）与 Surface 亮度差承担。
        enum Shadow {
            private static func shadow(_ lightOpacity: CGFloat) -> Color {
                Color(uiColor: UIColor { trait in
                    trait.userInterfaceStyle == .dark
                        ? .clear
                        : UIColor.black.withAlphaComponent(lightOpacity)
                })
            }
            static var soft:   Color { shadow(0.06) }
            static var medium: Color { shadow(0.12) }
        }
    }
}

// MARK: - 环境感知颜色访问
//
// SwiftUI 的 ShapeStyle 扩展不能直接读环境；业务代码请用
// `@Environment(\.tabFlavor) var flavor` 自行读取后再 `.color`。
// 这里只暴露非环境感知的 fallback 色，深层 push 视图意外丢失环境时用。

extension Theme.ColorToken.Interactive {
    static var primaryFallback: Color { Color("Palette/Peach") }
    static var secondary:       Color { Color(uiColor: ThemeManager.shared.dynamicNeutral(\.n200)) }
}

extension Theme.ColorToken.Border {
    static var emphasisFallback: Color { Color("Palette/Peach") }
}
