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
            /// 页面底；随色彩模式（默认奶油拿铁为米奶暖调），自动跟随系统外观
            static var background: Color { Color(uiColor: ThemeManager.shared.dynamicBg) }
            /// 卡片底；随色彩模式（默认为偏纯白偏暖），同上
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
            // primary：填充底用 @Environment(\.tabFlavor).fill（深色自动加深），
            // 彩色前景才用 .color。secondary 与 primaryFallback 见文件底部扩展。
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
        /// 通过现有 Palette/*.colorset 别名；dark 变体是「提亮」版，为彩色文字/
        /// 图标/描边设计——**禁止当填充底压白字**，填充场景一律用 Fill。
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
        /// 「加深」（PaletteDeriver.darkAccentFill）。当前色板的白字对比 ≥4.5
        /// 由 PaletteDeriverTests 单测卡住（非函数级保证——新增 Fill 色必须
        /// 同步加进那条单测）。填充场景一律用 Fill，不用 Morandi。
        enum Fill {
            private static func fill(_ lightHex: String) -> Color {
                Color(uiColor: UIColor { trait in
                    let hex = trait.userInterfaceStyle == .dark
                        ? PaletteDeriver.darkAccentFill(fromLightHex: lightHex)
                        : lightHex
                    return UIColor(themeHex: hex)
                })
            }
            static var latte: Color { fill(AccentHex.latte) }
            static var rose:  Color { fill(AccentHex.rose) }
            static var sage:  Color { fill(AccentHex.sage) }
            static var mist:  Color { fill(AccentHex.mist) }
            static var mauve: Color { fill(AccentHex.mauve) }
            static var honey: Color { fill(AccentHex.honey) }
            /// 语义色的填充版（Semantic/* light 值，深色自动加深）
            static var error:   Color { fill(AccentHex.error) }
            static var info:    Color { fill(AccentHex.info) }
            static var success: Color { fill(AccentHex.success) }
            static var warning: Color { fill(AccentHex.warning) }
        }

        /// Fill 的 light 值 = 对应 Asset colorset 的 light 分量（手动镜像）。
        /// 单一数据源：Fill 与单测都引用这里；与 Asset 的一致性由
        /// ThemeAccentHexTests 卡住，设计师改 colorset 时测试会失败提醒同步。
        enum AccentHex {
            static let latte   = "C8966E"   // Palette/Peach
            static let rose    = "C9928E"   // Palette/Coral
            static let sage    = "9FB089"   // Palette/Mint
            static let mist    = "94A8B6"   // Palette/Sky
            static let mauve   = "B196AE"   // Palette/Lavender
            static let honey   = "D8B97A"   // Palette/Lemon
            static let error   = "B86A60"   // Semantic/Error
            static let info    = "748FA1"   // Semantic/Info
            static let success = "7A9B6A"   // Semantic/Success
            static let warning = "C99659"   // Semantic/Warning

            /// (hex, Asset 名) 对照表——一致性单测与对比度单测都遍历它
            static let assetPairs: [(hex: String, assetName: String)] = [
                (latte, "Palette/Peach"), (rose, "Palette/Coral"),
                (sage, "Palette/Mint"), (mist, "Palette/Sky"),
                (mauve, "Palette/Lavender"), (honey, "Palette/Lemon"),
                (error, "Semantic/Error"), (info, "Semantic/Info"),
                (success, "Semantic/Success"), (warning, "Semantic/Warning"),
            ]
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
// `@Environment(\.tabFlavor) var flavor` 自行读取——填充底用 `.fill`，
// 彩色前景（文字/图标/描边）才用 `.color`。
// 这里只暴露非环境感知的 fallback 色，深层 push 视图意外丢失环境时用。

extension Theme.ColorToken.Interactive {
    /// 仅限前景/描边场景；填充底请用 Theme.ColorToken.Fill.latte
    static var primaryFallback: Color { Color("Palette/Peach") }
    static var secondary:       Color { Color(uiColor: ThemeManager.shared.dynamicNeutral(\.n200)) }
}

extension Theme.ColorToken.Border {
    static var emphasisFallback: Color { Color("Palette/Peach") }
}
