//
//  ColorSimilarityService.swift
//  BeadInventory
//
//  相似色查找服务：基于 CIE76 Delta E 算法
//

import Foundation

struct SimilarColor {
    let beadColor: BeadColor
    let deltaE: Double
    let availableStock: Int
}

class ColorSimilarityService {

    private struct RGB {
        let r: Double, g: Double, b: Double
    }

    private struct LAB {
        let l: Double, a: Double, b: Double
    }

    private static func hexToRGB(_ hex: String) -> RGB? {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        h = h.replacingOccurrences(of: "#", with: "")
        guard h.count == 6, let n = UInt64(h, radix: 16) else { return nil }
        return RGB(
            r: Double((n >> 16) & 0xFF) / 255.0,
            g: Double((n >> 8) & 0xFF) / 255.0,
            b: Double(n & 0xFF) / 255.0
        )
    }

    private static func rgbToLAB(_ rgb: RGB) -> LAB {
        func linearize(_ c: Double) -> Double {
            c > 0.04045 ? pow((c + 0.055) / 1.055, 2.4) : c / 12.92
        }
        let lr = linearize(rgb.r)
        let lg = linearize(rgb.g)
        let lb = linearize(rgb.b)

        let x = (lr * 0.4124564 + lg * 0.3575761 + lb * 0.1804375) / 0.95047
        let y = (lr * 0.2126729 + lg * 0.7151522 + lb * 0.0721750)
        let z = (lr * 0.0193339 + lg * 0.1191920 + lb * 0.9503041) / 1.08883

        func f(_ t: Double) -> Double {
            t > 0.008856 ? pow(t, 1.0 / 3.0) : (7.787 * t + 16.0 / 116.0)
        }
        return LAB(
            l: 116.0 * f(y) - 16.0,
            a: 500.0 * (f(x) - f(y)),
            b: 200.0 * (f(y) - f(z))
        )
    }

    private static func deltaE(_ a: LAB, _ b: LAB) -> Double {
        let dl = a.l - b.l
        let da = a.a - b.a
        let db = a.b - b.b
        return sqrt(dl * dl + da * da + db * db)
    }

    func findSimilarColors(
        for mardCode: String,
        brandId: UUID,
        allColors: [BeadColor],
        brandStocks: [BrandStock],
        maxResults: Int = 5,
        maxDeltaE: Double = 20.0
    ) -> [SimilarColor] {
        guard let target = allColors.first(where: { $0.mardCode == mardCode }),
              let targetRGB = Self.hexToRGB(target.colorHex) else {
            return []
        }
        let targetLAB = Self.rgbToLAB(targetRGB)

        var results: [SimilarColor] = []
        for color in allColors {
            guard color.mardCode != mardCode else { continue }
            guard let rgb = Self.hexToRGB(color.colorHex) else { continue }

            let de = Self.deltaE(targetLAB, Self.rgbToLAB(rgb))
            guard de <= maxDeltaE else { continue }

            let stock = brandStocks.first(where: {
                $0.brandId == brandId && $0.mardCode == color.mardCode
            })
            let available = stock?.available ?? 0
            guard available > 0 else { continue }

            results.append(SimilarColor(beadColor: color, deltaE: de, availableStock: available))
        }

        results.sort { $0.deltaE < $1.deltaE }
        return Array(results.prefix(maxResults))
    }
}
