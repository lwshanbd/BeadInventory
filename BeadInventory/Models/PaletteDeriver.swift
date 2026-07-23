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
    var n50: ColorHex
    var n100: ColorHex
    var n200: ColorHex
    var n400: ColorHex
    var n600: ColorHex
    var n900: ColorHex
    var surfaceStrong: ColorHex
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

    /// 从主题 bg 派生中性阶。bg 非法时按对应模式的参考 bg 处理（即返回原 Asset 阶梯）。
    static func neutrals(forBg bgHex: ColorHex, isDark: Bool) -> DerivedNeutrals {
        let ref = isDark ? darkRef : lightRef
        let refBg = hsb(fromHex: ref.bg)!   // 参考色为内部常量，必定合法
        let themeBg = hsb(fromHex: bgHex) ?? refBg

        // 饱和度按「目标 bg 相对参考 bg」的比例缩放；参考 bg 有固定饱和度，分母安全。
        // 比例夹在 [0, 2.5]：高饱和自定义 bg 不至于把文字灰阶推成荧光色。
        let satRatio = min(themeBg.s / refBg.s, 2.5)

        func derive(_ stepHex: ColorHex) -> ColorHex {
            let step = hsb(fromHex: stepHex)!
            // 保留每一档相对参考 bg 的 hue 偏移（参考阶梯各档并非同一 hue，
            // 直接替换成主题 hue 会丢掉这层微差，恒等派生就不再精确）。
            var h = (themeBg.h + (step.h - refBg.h)).truncatingRemainder(dividingBy: 360)
            if h < 0 { h += 360 }
            let s = min(step.s * satRatio, 0.9)
            let b = min(max(step.b + (themeBg.b - refBg.b), 0), 1)
            return hex(fromH: h, s: s, b: b)
        }

        return DerivedNeutrals(
            n50: derive(ref.n50),
            n100: derive(ref.n100),
            n200: derive(ref.n200),
            n400: derive(ref.n400),
            n600: derive(ref.n600),
            n900: derive(ref.n900),
            surfaceStrong: derive(ref.surfaceStrong)
        )
    }

    // MARK: - 纯 HSB 数学（不依赖 UIKit，便于单测）

    struct HSB: Equatable {
        var h: Double   // 0..<360，饱和度为 0 时无意义（置 0）
        var s: Double   // 0...1
        var b: Double   // 0...1
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
        let c = b * s
        let hPrime = (h.truncatingRemainder(dividingBy: 360)) / 60
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
