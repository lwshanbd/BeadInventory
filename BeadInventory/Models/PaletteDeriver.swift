//
//  PaletteDeriver.swift
//  BeadInventory
//
//  色彩模式：从主题 bg 色派生整套中性色阶。
//
//  设计原则：以「奶油拿铁」的 Asset 色值为参考阶梯 —— 记录每一档相对参考 bg
//  的 HSB 关系（S 比例、B 差值），套用目标 bg 的色相后重建。这样：
//  - 默认主题的派生结果与原 Asset 色值一致（无视觉回归）；
//  - 任意 bg（含用户自定义）都能得到同色调、对比度关系一致的中性阶。
//

import Foundation

/// 派生出的中性色阶（hex 均为 "RRGGBB" 大写）
struct DerivedNeutrals: Equatable {
    let n50: ColorHex
    let n100: ColorHex
    let n200: ColorHex
    let n400: ColorHex
    let n600: ColorHex
    let n900: ColorHex
    let surfaceStrong: ColorHex
}

enum PaletteDeriver {

    // MARK: - 参考阶梯（= 奶油拿铁 Asset 色值）

    private struct ReferenceLadder {
        let bg: ColorHex
        let n50: ColorHex
        let n100: ColorHex
        let n200: ColorHex
        let n400: ColorHex
        let n600: ColorHex
        let n900: ColorHex
        let surfaceStrong: ColorHex
    }

    private static let lightRef = ReferenceLadder(
        bg: "FAF5EC",
        n50: "F4ECDE", n100: "EFE6D5", n200: "E4D9C5",
        n400: "A89C87", n600: "7A6B58", n900: "2D261E",
        surfaceStrong: "EBE2D2"
    )

    private static let darkRef = ReferenceLadder(
        bg: "1B1714",
        n50: "2D2722", n100: "2E281F", n200: "3A3328",
        n400: "847868", n600: "B8A98F", n900: "F2EAD9",
        surfaceStrong: "38312A"
    )

    // MARK: - 派生入口

    /// 文字档的 WCAG 对比度下限（vs bg 与 bgElev 双表面取最差者）。
    /// 数值以「奶油拿铁参考阶梯本身能通过」为上界标定——n600 在参考浅色下
    /// 实测 4.73:1、n400 仅 2.52:1（设计如此），所以下限分别取 4.5 / 2.0，
    /// 保证恒等派生不被护栏改写。
    private static let contrastFloors: [(step: KeyPath<ReferenceLadder, ColorHex>, min: Double)] = [
        (\.n400, 2.0), (\.n600, 4.5), (\.n900, 7.0)
    ]

    /// 从主题 bg 派生中性阶。bg 非法时按对应模式的参考 bg 处理（即返回原 Asset 阶梯）。
    /// elevHex 传入卡片底色时，文字档（n400/n600/n900）的对比度下限会同时对
    /// bg 和 bgElev 校验——防止「对页面底达标、压在卡片上却不达标」（雾蓝海岸深色实测踩过）。
    static func neutrals(forBg bgHex: ColorHex, elevHex: ColorHex? = nil, isDark: Bool) -> DerivedNeutrals {
        let ref = isDark ? darkRef : lightRef
        let refBg = hsb(fromHex: ref.bg)!   // 参考色为内部常量，必定合法（有 round-trip 单测钉住）
        assert(refBg.s > 0, "参考 bg 不能无饱和——satRatio 除法依赖它")
        let themeBg = hsb(fromHex: bgHex) ?? refBg

        // 饱和度按「目标 bg 相对参考 bg」的比例缩放；参考 bg 有固定饱和度，分母安全。
        // 比例夹在 [0, 2.5]：高饱和自定义 bg 不至于把文字灰阶推成荧光色。
        let satRatio = min(themeBg.s / refBg.s, 2.5)

        func derive(_ stepHex: ColorHex) -> ColorHex {
            let step = hsb(fromHex: stepHex)!
            // 保留每一档相对参考 bg 的 hue 偏移（参考阶梯各档并非同一 hue，
            // 直接替换成主题 hue 会丢掉这层微差，恒等派生就不再精确）。
            let h = themeBg.h + (step.h - refBg.h)
            let s = min(step.s * satRatio, 0.9)
            let b = min(max(step.b + (themeBg.b - refBg.b), 0), 1)
            return hex(fromH: h, s: s, b: b)
        }

        // 对比度护栏：亮度平移 + [0,1] 夹取意味着极端 bg（比如浅色槽选了纯黑）
        // 会把整条文字阶梯夹到和 bg 同色——黑底黑字、无法自救。这里对文字档
        // 强制最小对比度，达不到就沿远离 bg 的方向调亮度（必要时降饱和）。
        let surfaces = [bgHex, elevHex].compactMap { $0 }.filter { hsb(fromHex: $0) != nil }
        let checkedSurfaces = surfaces.isEmpty ? [ref.bg] : surfaces

        func deriveText(_ stepKP: KeyPath<ReferenceLadder, ColorHex>, minRatio: Double) -> ColorHex {
            let raw = derive(ref[keyPath: stepKP])
            return ensureContrast(raw, against: checkedSurfaces, minRatio: minRatio)
        }

        var textSteps: [KeyPath<ReferenceLadder, ColorHex>: ColorHex] = [:]
        for floor in contrastFloors {
            textSteps[floor.step] = deriveText(floor.step, minRatio: floor.min)
        }

        return DerivedNeutrals(
            n50: derive(ref.n50),
            n100: derive(ref.n100),
            n200: derive(ref.n200),
            n400: textSteps[\.n400]!,
            n600: textSteps[\.n600]!,
            n900: textSteps[\.n900]!,
            surfaceStrong: derive(ref.surfaceStrong)
        )
    }

    /// 若 `colorHex` 对任一表面的对比度低于 `minRatio`，沿能达标的方向调整亮度
    /// （二分逼近），仍不够则逐步压饱和（极限是纯黑/纯白）。已达标则原样返回，
    /// 保证正常主题（含恒等派生）不被改写。
    private static func ensureContrast(_ colorHex: ColorHex, against surfaces: [ColorHex], minRatio: Double) -> ColorHex {
        func worstRatio(_ hexValue: ColorHex) -> Double {
            surfaces.compactMap { contrastRatio(hexValue, $0) }.min() ?? .infinity
        }
        if worstRatio(colorHex) >= minRatio { return colorHex }
        guard let c = hsb(fromHex: colorHex) else { return colorHex }

        func candidate(s: Double, b: Double) -> ColorHex { hex(fromH: c.h, s: s, b: b) }

        // 两个方向各自的极限对比度，选更好的一侧
        for s in [c.s, c.s * 0.5, 0] {
            let darkest = candidate(s: s, b: 0)
            let lightest = candidate(s: s, b: 1)
            let towardDark = worstRatio(darkest) >= worstRatio(lightest)
            let extremeHex = towardDark ? darkest : lightest
            guard worstRatio(extremeHex) >= minRatio else { continue }
            // 在 [b_extreme, c.b] 间二分，找刚好达标的最近亮度
            var lo = towardDark ? 0.0 : c.b
            var hi = towardDark ? c.b : 1.0
            for _ in 0..<18 {
                let mid = (lo + hi) / 2
                let ok = worstRatio(candidate(s: s, b: mid)) >= minRatio
                if towardDark {
                    if ok { lo = mid } else { hi = mid }
                } else {
                    if ok { hi = mid } else { lo = mid }
                }
            }
            let b = towardDark ? lo : hi
            let result = candidate(s: s, b: b)
            return worstRatio(result) >= minRatio ? result : extremeHex
        }
        // 纯黑/纯白都达不到（表面是中灰时可能发生）——返回可达的最大对比一侧
        let black = candidate(s: 0, b: 0), white = candidate(s: 0, b: 1)
        return worstRatio(black) >= worstRatio(white) ? black : white
    }

    // MARK: - WCAG 对比度

    static func relativeLuminance(fromHex hexString: ColorHex) -> Double? {
        let stripped = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        guard stripped.count == 6, let value = UInt32(stripped, radix: 16) else { return nil }
        func lin(_ c: UInt32) -> Double {
            let s = Double(c) / 255.0
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin((value >> 16) & 0xFF)
             + 0.7152 * lin((value >> 8) & 0xFF)
             + 0.0722 * lin(value & 0xFF)
    }

    static func contrastRatio(_ a: ColorHex, _ b: ColorHex) -> Double? {
        guard let la = relativeLuminance(fromHex: a),
              let lb = relativeLuminance(fromHex: b) else { return nil }
        let hi = max(la, lb), lo = min(la, lb)
        return (hi + 0.05) / (lo + 0.05)
    }

    // MARK: - 深色强调填充

    /// 深色模式下的强调「填充」色：保色相、压亮度、略提饱和。
    ///
    /// Asset 里 Morandi/Semantic 的 dark 变体是「提亮」的（彩色文字需要），
    /// 但按钮/FAB/Hero 这类填充底如果也用提亮版，白字压上去对比不足、
    /// 整块在近黑页面上像发光贴片。填充场景改用本函数的加深版。
    /// 注意：参数钳制按莫兰迪中饱和中亮度色调校；新增 Fill 色必须加进
    /// PaletteDeriverTests 的白字对比单测（低饱和亮色输入可能达不到 4.5:1）。
    static func darkAccentFill(fromLightHex hexString: ColorHex) -> ColorHex {
        guard let c = hsb(fromHex: hexString) else {
            // 非法输入若原样返回，深色下渲染的恰是本函数要防的「发光浅色块」。
            // 兜底给一个能承载白字的中性深灰（对比 ≈6.7:1），并在 debug 下即刻暴露。
            assertionFailure("darkAccentFill: 非法 hex '\(hexString)'")
            AppLogger.shared.error("PaletteDeriver", "dark_accent_fill_invalid_hex", metadata: ["hex": hexString])
            return "5C5C5C"
        }
        let s = min(c.s * 1.2, 0.75)
        let b = min(max(c.b * 0.58, 0.38), 0.50)
        return hex(fromH: c.h, s: s, b: b)
    }

    // MARK: - 纯 HSB 数学（不依赖 UIKit，便于单测）

    struct HSB: Equatable {
        let h: Double   // 0..<360，饱和度为 0 时无意义（置 0）
        let s: Double   // 0...1
        let b: Double   // 0...1
    }

    static func hsb(fromHex hexString: ColorHex) -> HSB? {
        let stripped = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        guard stripped.count == 6, let value = UInt32(stripped, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0

        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC

        var h: Double = 0
        if delta > 0 {
            if maxC == r {
                h = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == g {
                h = 60 * ((b - r) / delta + 2)
            } else {
                h = 60 * ((r - g) / delta + 4)
            }
            if h < 0 { h += 360 }
        }
        let s = maxC == 0 ? 0 : delta / maxC
        return HSB(h: h, s: s, b: maxC)
    }

    static func hex(fromH h: Double, s: Double, b: Double) -> ColorHex {
        // h 先归一到 [0, 360)：负 hue 若直接除 60 会静默落进错误分支
        var hNorm = h.truncatingRemainder(dividingBy: 360)
        if hNorm < 0 { hNorm += 360 }
        let s = min(max(s, 0), 1)
        let b = min(max(b, 0), 1)
        let c = b * s
        let hPrime = hNorm / 60
        let x = c * (1 - abs(hPrime.truncatingRemainder(dividingBy: 2) - 1))
        let m = b - c

        let (r1, g1, b1): (Double, Double, Double)
        switch hPrime {
        case ..<1: (r1, g1, b1) = (c, x, 0)
        case ..<2: (r1, g1, b1) = (x, c, 0)
        case ..<3: (r1, g1, b1) = (0, c, x)
        case ..<4: (r1, g1, b1) = (0, x, c)
        case ..<5: (r1, g1, b1) = (x, 0, c)
        default:   (r1, g1, b1) = (c, 0, x)
        }

        func channel(_ v: Double) -> String {
            String(format: "%02X", Int((min(max(v + m, 0), 1) * 255).rounded()))
        }
        return channel(r1) + channel(g1) + channel(b1)
    }
}
