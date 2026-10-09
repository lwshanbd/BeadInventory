import XCTest
@testable import BeadInventory

/// 拼图模式判「空」时，哪些格子是被线围死的浅色豆子。
///
/// 值得写测试：错了不会崩。往一边错，白豆子、米色豆子整片被判成空，用户只看到
/// 「零件缺了一块」；往另一边错，零件外面的白纸被当成豆子，颗数凭空多出几百。
final class PartsCellEnclosureTests: XCTestCase {

    private let white = Int32(QuantizedRGB.index(r: 255, g: 255, b: 255))
    private let black = Int32(QuantizedRGB.index(r: 0, g: 0, b: 0))
    private let paper = LabColor(l: 100, a: 0, b: 0)

    /// 3 行 6 列、每格 10 像素的白纸，按要求画黑线
    private func bitmap(draw: (inout [Int32], Int) -> Void) -> PartsBitmap {
        let w = 60, h = 30
        var px = [Int32](repeating: white, count: w * h)
        draw(&px, w)
        return PartsBitmap(width: w, height: h, quantized: px,
                           roi: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// 画一个矩形框（1 像素宽），格子坐标
    private func box(_ px: inout [Int32], _ w: Int, row: Int, col: Int, cols: Int) {
        let x0 = col * 10, x1 = (col + cols) * 10 - 1
        let y0 = row * 10, y1 = row * 10 + 9
        for x in x0...x1 { px[y0 * w + x] = black; px[y1 * w + x] = black }
        for y in y0...y1 { px[y * w + x0] = black; px[y * w + x1] = black }
    }

    func testWalledCellsAreBeadsOpenPaperIsNot() {
        let bmp = bitmap { px, w in
            // 两颗白豆子，各自一个框
            box(&px, w, row: 1, col: 1, cols: 1)
            box(&px, w, row: 1, col: 2, cols: 1)
            // 一颗豆子中间印着一大坨字，把格子中间整个盖住
            for y in 14...15 { for x in 13...16 { px[y * w + x] = black } }
        }
        let result = PartsCellEnclosure.enclosedCells(bitmap: bmp, rows: 3, cols: 6, backgroundLab: paper)
        XCTAssertTrue(result[1][1], "印着字的白豆子")
        XCTAssertTrue(result[1][2], "白豆子")
        XCTAssertFalse(result[0][0], "零件外面的白纸")
        XCTAssertFalse(result[1][4], "零件外面的白纸")
    }

    /// 两格大的镂空：一个框围住两格，中间没有格线。它是空，不是豆子。
    func testMultiCellHoleIsNotBead() {
        let bmp = bitmap { px, w in
            box(&px, w, row: 1, col: 2, cols: 2)
        }
        let result = PartsCellEnclosure.enclosedCells(bitmap: bmp, rows: 3, cols: 6, backgroundLab: paper)
        XCTAssertFalse(result[1][2])
        XCTAssertFalse(result[1][3])
    }
}
