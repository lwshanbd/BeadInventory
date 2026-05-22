//
//  InventoryManagerStockIndexTests.swift
//  BeadInventoryTests
//
//  覆盖 InventoryManager.stockPositionIndex 与 getStock 的核心不变量：
//  - 索引在 append / removeAll / 元素改写 / 整行替换 / 整体重赋值后都与 brandStocks 一致
//  - 多品牌同 mardCode 不串色
//  - 重复 (brandId, mardCode) 行返回 first-match（与 mutator 的 firstIndex(where:) 语义一致）
//

import XCTest
@testable import BeadInventory

@MainActor
final class InventoryManagerStockIndexTests: XCTestCase {
    private let brandA = UUID()
    private let brandB = UUID()

    private func makeManager() -> InventoryManager {
        let m = InventoryManager()
        m.brandStocks = []
        return m
    }

    // MARK: - 基本查表

    func test_getStock_returns_existing_row_via_index() {
        let m = makeManager()
        m.brandStocks = [
            BrandStock(brandId: brandA, mardCode: "H01", stock: 100),
            BrandStock(brandId: brandA, mardCode: "H02", stock: 200),
        ]
        XCTAssertEqual(m.getStock(brandId: brandA, mardCode: "H01")?.stock, 100)
        XCTAssertEqual(m.getStock(brandId: brandA, mardCode: "H02")?.stock, 200)
    }

    func test_getStock_returns_nil_for_unknown_brand() {
        let m = makeManager()
        m.brandStocks = [BrandStock(brandId: brandA, mardCode: "H01")]
        XCTAssertNil(m.getStock(brandId: UUID(), mardCode: "H01"))
    }

    func test_getStock_returns_nil_for_unknown_mardCode() {
        let m = makeManager()
        m.brandStocks = [BrandStock(brandId: brandA, mardCode: "H01")]
        XCTAssertNil(m.getStock(brandId: brandA, mardCode: "DOES_NOT_EXIST"))
    }

    // MARK: - 跨品牌隔离

    func test_multi_brand_same_mardCode_does_not_cross() {
        let m = makeManager()
        m.brandStocks = [
            BrandStock(brandId: brandA, mardCode: "H01", stock: 100),
            BrandStock(brandId: brandB, mardCode: "H01", stock: 300),
        ]
        XCTAssertEqual(m.getStock(brandId: brandA, mardCode: "H01")?.stock, 100)
        XCTAssertEqual(m.getStock(brandId: brandB, mardCode: "H01")?.stock, 300)
    }

    // MARK: - 写后即读

    func test_element_mutation_visible_to_subsequent_get() {
        // brandStocks[i].stock = x 会触发 didSet → mark dirty → 下一次读时 rebuild。
        let m = makeManager()
        m.brandStocks = [BrandStock(brandId: brandA, mardCode: "H01", stock: 100)]
        m.brandStocks[0].stock = 500
        XCTAssertEqual(m.getStock(brandId: brandA, mardCode: "H01")?.stock, 500)
    }

    func test_append_visible_to_subsequent_get() {
        let m = makeManager()
        m.brandStocks = []
        m.brandStocks.append(BrandStock(brandId: brandA, mardCode: "H01", stock: 50))
        XCTAssertEqual(m.getStock(brandId: brandA, mardCode: "H01")?.stock, 50)
    }

    // MARK: - 删除无幽灵

    func test_removeAll_by_brand_leaves_no_ghost() {
        let m = makeManager()
        m.brandStocks = [
            BrandStock(brandId: brandA, mardCode: "H01"),
            BrandStock(brandId: brandA, mardCode: "H02"),
            BrandStock(brandId: brandB, mardCode: "H03"),
        ]
        XCTAssertNotNil(m.getStock(brandId: brandA, mardCode: "H01"))
        m.brandStocks.removeAll { $0.brandId == brandA }
        XCTAssertNil(m.getStock(brandId: brandA, mardCode: "H01"))
        XCTAssertNil(m.getStock(brandId: brandA, mardCode: "H02"))
        XCTAssertNotNil(m.getStock(brandId: brandB, mardCode: "H03"))
    }

    func test_removeAll_by_mardCode_leaves_no_ghost() {
        let m = makeManager()
        m.brandStocks = [
            BrandStock(brandId: brandA, mardCode: "H01"),
            BrandStock(brandId: brandB, mardCode: "H01"),
        ]
        m.brandStocks.removeAll { $0.mardCode == "H01" }
        XCTAssertNil(m.getStock(brandId: brandA, mardCode: "H01"))
        XCTAssertNil(m.getStock(brandId: brandB, mardCode: "H01"))
    }

    // MARK: - 整行替换（mardCode 重命名）

    func test_row_replacement_updates_index_for_new_mardCode() {
        let m = makeManager()
        m.brandStocks = [BrandStock(brandId: brandA, mardCode: "OLD", stock: 100)]
        XCTAssertNotNil(m.getStock(brandId: brandA, mardCode: "OLD"))
        m.brandStocks[0] = BrandStock(brandId: brandA, mardCode: "NEW", stock: 100)
        XCTAssertNotNil(m.getStock(brandId: brandA, mardCode: "NEW"))
        XCTAssertNil(m.getStock(brandId: brandA, mardCode: "OLD"))
    }

    // MARK: - 整体重赋值

    func test_bulk_reassignment_rebuilds_index() {
        let m = makeManager()
        m.brandStocks = [BrandStock(brandId: brandA, mardCode: "H01")]
        XCTAssertNotNil(m.getStock(brandId: brandA, mardCode: "H01"))
        m.brandStocks = [BrandStock(brandId: brandB, mardCode: "H02")]
        XCTAssertNil(m.getStock(brandId: brandA, mardCode: "H01"))
        XCTAssertNotNil(m.getStock(brandId: brandB, mardCode: "H02"))
    }

    // MARK: - 重复行 first-match 兼容

    func test_duplicate_rows_return_first_match() {
        // 历史/iCloud 同步可能在极少数情况下产生重复 (brandId, mardCode) 行。
        // 所有 mutator 都用 firstIndex(where:) 改第一条，索引必须保留 first-match
        // 语义，否则 getStock 看到的是 last-write、写路径改的是 first-write，读写错位。
        let m = makeManager()
        m.brandStocks = [
            BrandStock(brandId: brandA, mardCode: "H01", stock: 100),
            BrandStock(brandId: brandA, mardCode: "H01", stock: 999),
        ]
        XCTAssertEqual(m.getStock(brandId: brandA, mardCode: "H01")?.stock, 100)
    }

    // MARK: - lazy rebuild 时序

    func test_multiple_writes_before_single_read_all_visible() {
        // dirty-flag 模式最常见 bug 模式：「第二次 / 第三次写后忘了 mark dirty」。
        // 多次连续写之间不读，最后一次读必须能看到所有写的累积结果。
        let m = makeManager()
        m.brandStocks = [BrandStock(brandId: brandA, mardCode: "H01", stock: 100)]
        m.brandStocks[0].stock = 200
        m.brandStocks[0].stock = 300
        m.brandStocks.append(BrandStock(brandId: brandA, mardCode: "H02", stock: 50))
        XCTAssertEqual(m.getStock(brandId: brandA, mardCode: "H01")?.stock, 300)
        XCTAssertEqual(m.getStock(brandId: brandA, mardCode: "H02")?.stock, 50)
    }

    func test_write_read_write_read_stays_consistent() {
        // 「第一次读把 dirty 清零后，第二次写没 mark dirty」是 lazy rebuild
        // 模式的另一典型回归。这条用例专门钉住"读后再写仍能感知到新值"。
        let m = makeManager()
        m.brandStocks = [BrandStock(brandId: brandA, mardCode: "H01", stock: 100)]
        XCTAssertEqual(m.getStock(brandId: brandA, mardCode: "H01")?.stock, 100)
        m.brandStocks[0].stock = 999
        XCTAssertEqual(m.getStock(brandId: brandA, mardCode: "H01")?.stock, 999)
    }
}
