//
//  BoardCastCalibration.swift
//  BeadInventory
//
//  投影仪投出来的那块画面，跟桌上那块拼豆板对齐
//
//  ## 为什么需要校准
//
//  投影仪不认识拼豆板。它把画面投在桌面上，画面多大、落在哪儿，取决于机器摆多远、
//  镜头怎么调 —— 跟豆板的位置和大小没有任何关系。默认那套「板子居中铺满整块屏幕」
//  是给电视看的（人抬头看图），投影仪上却是要**照着投影往豆板上按豆子**的：
//  投出来的一格没对准豆板的一个孔，这个功能就等于没有。
//
//  能靠软件对上的只有两件事：画面里那块板的**左上角落在哪儿**、以及它的**边长多长**。
//  剩下的（歪、梯形）得在投影仪上调，App 管不了。所以校准就是这两个数：
//  用户把投出来的方框左上角对到豆板左上角，再把边长拉到右下角也对上 —— 中间的格子
//  自然就一格对一个孔（板子是正方形的，见 `BeadBoardSize.presets`）。
//
//  ## 为什么存的是比例不是点数
//
//  换一台投影仪、或者同一台换个分辨率输出，点数全变；比例还在。校准值的意义是
//  「画面上从左边数百分之多少的位置」，跟外屏多少点无关。
//
//  三个数**都以外屏宽度为单位**（包括 y）：像素是方的，宽高各用各的单位的话，
//  一个正方形存进去、取出来就不是正方形了。
//

import SwiftUI

@MainActor
final class BoardCastCalibration: ObservableObject {
    static let shared = BoardCastCalibration()

    /// 校准过了没有。false = 老行为：板子居中铺满外屏（接电视时要的就是这个）。
    @Published var isEnabled: Bool { didSet { save() } }
    /// 方框左上角的 x，单位是外屏宽度
    @Published var originX: CGFloat { didSet { save() } }
    /// 方框左上角的 y，单位**也是外屏宽度**（理由见文件头）
    @Published var originY: CGFloat { didSet { save() } }
    /// 方框边长，单位是外屏宽度
    @Published var side: CGFloat { didSet { save() } }

    /// 用户正开着校准页。外屏据此把对齐用的角标画出来 ——
    /// 平时不画：拼的时候画面上多几道亮线，人照着按豆子会把它当成格线。
    @Published var isCalibrating = false

    private enum Key {
        static let enabled = "boardCast.calibration.enabled"
        static let originX = "boardCast.calibration.originX"
        static let originY = "boardCast.calibration.originY"
        static let side = "boardCast.calibration.side"
    }

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Key.enabled)
        // 没存过时给一个能看见的方框（16:9 上高度撑满九成、横向居中），
        // 用户一进校准页就该看见东西可拖，而不是自己先找那个 0×0 的框。
        let storedSide = defaults.double(forKey: Key.side)
        side = storedSide > 0 ? storedSide : BoardCastCalibration.defaultSide
        originX = defaults.object(forKey: Key.originX) as? Double
            ?? (1 - BoardCastCalibration.defaultSide) / 2
        originY = defaults.object(forKey: Key.originY) as? Double
            ?? BoardCastCalibration.defaultOriginY
    }

    /// 16:9 上高度的九成 ≈ 宽度的一半
    private static let defaultSide: CGFloat = 0.5
    private static let defaultOriginY: CGFloat = (9.0 / 16.0 - 0.5) / 2

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(isEnabled, forKey: Key.enabled)
        defaults.set(originX, forKey: Key.originX)
        defaults.set(originY, forKey: Key.originY)
        defaults.set(side, forKey: Key.side)
    }

    // MARK: - 给渲染用

    /// 这一屏上板子该画在哪块方框里。nil = 没校准过，照旧铺满。
    func rect(in screen: CGSize) -> CGRect? {
        guard isEnabled, screen.width > 0 else { return nil }
        return CGRect(x: originX * screen.width,
                      y: originY * screen.width,
                      width: side * screen.width,
                      height: side * screen.width)
    }

    /// 校准页要画的那个框：不管开没开都给，用户正在调的就是它。
    func previewRect(in screen: CGSize) -> CGRect {
        CGRect(x: originX * screen.width,
               y: originY * screen.width,
               width: side * screen.width,
               height: side * screen.width)
    }

    // MARK: - 给校准页用

    /// 挪左上角。`dx`/`dy` 是**外屏上的点数**（手机上拖多远换算过来）。
    ///
    /// 边长不动 —— 这一步用户在对左上角，方框大小这时候变了他会以为自己拖错了。
    func move(dx: CGFloat, dy: CGFloat, screen: CGSize) {
        guard screen.width > 0 else { return }
        originX = clampX(originX + dx / screen.width)
        originY = clampY(originY + dy / screen.width, screen: screen)
    }

    /// 改边长（左上角钉住不动，右下角跟着走 —— 这正是用户在做的事）。
    func resize(by delta: CGFloat, screen: CGSize) {
        guard screen.width > 0 else { return }
        side = clampSide(side + delta / screen.width)
    }

    func setOrigin(x: CGFloat, y: CGFloat, screen: CGSize) {
        guard screen.width > 0 else { return }
        originX = clampX(x / screen.width)
        originY = clampY(y / screen.width, screen: screen)
    }

    func setSide(_ points: CGFloat, screen: CGSize) {
        guard screen.width > 0 else { return }
        side = clampSide(points / screen.width)
    }

    /// 回到「铺满」。用户换了地方摆投影仪、或者干脆接的是电视时的出路。
    func reset() {
        isEnabled = false
        side = BoardCastCalibration.defaultSide
        originX = (1 - BoardCastCalibration.defaultSide) / 2
        originY = BoardCastCalibration.defaultOriginY
    }

    /// 左上角可以拖到画面外一点（投影仪的画面常常比豆板大，豆板左上角落在画面外是可能的），
    /// 但不能拖到整块方框都不见了 —— 那样用户就再也找不回它。
    ///
    /// 横竖必须分开夹：竖着的范围是**画面高度**（换算成宽度单位），不是宽度。
    /// 共用一个上界的话，16:9 上方框能一路拖到画面下边以外，用户眼里就是「框没了」。
    private func clampX(_ value: CGFloat) -> CGFloat {
        min(max(value, -side + 0.05), 1 - 0.05)
    }

    private func clampY(_ value: CGFloat, screen: CGSize) -> CGFloat {
        let bottom = screen.height / max(screen.width, 1)
        return min(max(value, -side + 0.05), bottom - 0.05)
    }

    private func clampSide(_ value: CGFloat) -> CGFloat {
        min(max(value, 0.05), 3)
    }
}
