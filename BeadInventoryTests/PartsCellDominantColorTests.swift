import XCTest
@testable import BeadInventory

/// 拼图模式里「一格是什么颜色」的取色。
///
/// 值得写测试：取错了不会崩，只会把一片黄豆子判成黑色色号。用户在核对页只看到
/// 「P49 底下全是黄格子」，看不出是取色错了还是色号匹配错了。
final class PartsCellDominantColorTests: XCTestCase {

    private func index(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Int32 {
        Int32(QuantizedRGB.index(r: r, g: g, b: b))
    }

    /// 实际踩到的那格「G5」：格子中间印着粗黑字，黑字占三分之一以上，
    /// 但挤在几个深色桶里；底色在 JPEG 里散进了很多桶，每桶都比黑字少。
    /// 单数哪个桶最多的话会取到黑字。
    func testThickLabelTextDoesNotWinOverSpreadBackground() throws {
        var histogram: [Int32: Int] = [:]
        // 黑字：3 个桶，共 360 像素
        histogram[index(20, 4, 4), default: 0] += 140
        histogram[index(28, 4, 4), default: 0] += 120
        histogram[index(28, 12, 4), default: 0] += 100
        // 底色（棕黄 C4945C 附近）：抖开成 64 个桶，每桶 10 像素，共 640 像素
        for dr in 0..<4 {
            for dg in 0..<4 {
                for db in 0..<4 {
                    let r = UInt8(184 + dr * 8), g = UInt8(136 + dg * 8), b = UInt8(80 + db * 8)
                    histogram[index(r, g, b), default: 0] += 10
                }
            }
        }

        let winner = try XCTUnwrap(PartsCellClassifier.dominantColor(histogram))
        let lab = QuantizedRGB.labTable[Int(winner)]
        XCTAssertGreaterThan(lab.l, 50, "取到了黑字：\(QuantizedRGB.hex(of: Int(winner)))")
    }

    /// 同一份输入每次必须得出同一个颜色。否则用户重进一次核对页，结果就变了。
    func testDeterministic() {
        var histogram: [Int32: Int] = [:]
        for i in 0..<50 { histogram[index(UInt8(100 + i), 120, 60)] = 5 + i % 7 }
        histogram[index(10, 10, 10)] = 40
        let first = PartsCellClassifier.dominantColor(histogram)
        for _ in 0..<5 {
            XCTAssertEqual(PartsCellClassifier.dominantColor(histogram), first)
        }
    }
}
