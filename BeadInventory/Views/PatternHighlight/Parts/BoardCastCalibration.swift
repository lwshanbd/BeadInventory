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
//  能靠软件对上的只有两件事：画面里那块板的**左上角落在哪儿**、以及**一格多大**。
//  剩下的（歪、梯形）得在投影仪上调，App 管不了。
//
//  ## 为什么存的是「一格多大」，不是「整块板多大」
//
//  第一版存的是方框边长，错在**边长是跟着板子走的，格距才是跟着投影仪走的**：
//  同一台投影仪、同样的摆法，换一块 104×104 的板去拼，边长该变、格距一点都不该变。
//  存边长的话，为 50×50 对好的那组值用到 104×104 上，每格只剩孔距的一半，而用户
//  以为自己已经校准过了。
//
//  存格距还顺手解决了另一件事：板子不是正方形时（单图纸模式整张图纸当一块板），
//  画面里那块矩形按 `cols × rows` 自己算出来，右下角就是**最后一格的右下角**，
//  正是校准时让用户去对的那个点。存边长的话方框恒为正方形，右下角落在板子外面，
//  用户照着说明去对根本无从下手。
//
//  ## 为什么存的是比例不是点数
//
//  换一台投影仪、或者同一台换个分辨率输出，点数全变；比例还在。
//
//  `originX` / `originY` / `cell` **都以外屏宽度为单位**（包括 y）。用一套单位是为了
//  少一次换算、少一个出错的地方 —— 竖直方向的可用范围因此得单独算（见 `normalize`），
//  那是画面高度换算过来的，不是 1。
//

import SwiftUI

/// 校准时那两个角标的颜色。手机上和外屏上必须是同一个黄、同一个蓝 ——
/// 用户就是靠颜色认「我现在在调哪个角」。所以只有这一处定义。
///
/// 写死不走 Theme：这几道线要在**桌面和豆板**上看得见，跟 App 的色彩模式无关。
enum CalibrationMarkColor {
    static let topLeft = Color(red: 1.0, green: 0.83, blue: 0.0)
    static let bottomRight = Color(red: 0.2, green: 0.9, blue: 1.0)
}

@MainActor
final class BoardCastCalibration: ObservableObject {
    static let shared = BoardCastCalibration()

    /// 校准框生效中。false = 板子居中铺满外屏（接电视时要的就是这个）。
    ///
    /// 注意不是「校准过了没有」：进校准页就会打开它（不然没东西可拖），
    /// 取消或者「恢复铺满」会关掉。
    @Published private(set) var isEnabled: Bool
    /// 板子左上角的 x，单位是外屏宽度
    @Published private(set) var originX: CGFloat
    /// 板子左上角的 y，单位**也是外屏宽度**（理由见文件头）
    @Published private(set) var originY: CGFloat
    /// 一格多大，单位是外屏宽度。0 = 还没校准过。
    @Published private(set) var cell: CGFloat

    /// 用户正开着校准页。外屏据此把对齐用的角标画出来 ——
    /// 平时不画：拼的时候画面上多几道亮线，人照着按豆子会把它当成格线。
    @Published private(set) var isCalibrating = false

    /// 进校准页那一刻的值。取消时整组还原 —— 用户是对着实物量出来的这几个数，
    /// 手一滑就被覆盖、还没有退路，是这一屏最容易惹人恼火的地方。
    private var snapshot: (isEnabled: Bool, originX: CGFloat, originY: CGFloat, cell: CGFloat)?

    private enum Key {
        static let enabled = "boardCast.calibration.enabled"
        static let originX = "boardCast.calibration.originX"
        static let originY = "boardCast.calibration.originY"
        static let cell = "boardCast.calibration.cell"
    }

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Key.enabled)
        originX = defaults.double(forKey: Key.originX)
        originY = defaults.double(forKey: Key.originY)
        cell = defaults.double(forKey: Key.cell)
    }

    /// 只在「完成」和「恢复铺满」时落盘。
    ///
    /// 拖动过程中不存：一次拖动几百帧，每帧写四个 key 是白写的，而且中途每一个
    /// 中间值都会变成「用户的校准值」—— 取消就没得取消了。
    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(isEnabled, forKey: Key.enabled)
        defaults.set(originX, forKey: Key.originX)
        defaults.set(originY, forKey: Key.originY)
        defaults.set(cell, forKey: Key.cell)
    }

    // MARK: - 给渲染用

    /// 这块板在外屏上占哪一块。nil = 没校准，照旧铺满。
    ///
    /// 矩形按板子自己的 `cols × rows` 算，所以它的右下角就是**最后一格的右下角**：
    /// 校准时画角标、拼的时候画板子，用的是同一个矩形，用户对齐的就是他将来看到的。
    func frame(for board: PartsBoard, in screen: CGSize) -> CGRect? {
        guard isEnabled, cell > 0, screen.width > 0 else { return nil }
        return CGRect(x: originX * screen.width,
                      y: originY * screen.width,
                      width: cell * CGFloat(max(board.cols, 1)) * screen.width,
                      height: cell * CGFloat(max(board.rows, 1)) * screen.width)
    }

    // MARK: - 给校准页用

    /// 进校准页：记下现在的值，把校准框打开。第一次进来时按这块板和这块屏幕
    /// 算一个看得见的起点（高度九成、横向居中），用户一进来就该有东西可拖。
    func beginCalibrating(board: PartsBoard, screen: CGSize) {
        snapshot = (isEnabled, originX, originY, cell)
        if cell <= 0 {
            let rows = CGFloat(max(board.rows, 1))
            let cols = CGFloat(max(board.cols, 1))
            cell = min(screen.height * 0.9 / rows, screen.width * 0.9 / cols) / screen.width
            originX = (1 - cell * cols) / 2
            originY = (screen.height / screen.width - cell * rows) / 2
        }
        isEnabled = true
        isCalibrating = true
    }

    /// 「完成」：留下现在的值。
    func finishCalibrating() {
        snapshot = nil
        isCalibrating = false
        save()
    }

    /// 「取消」，以及从校准页划走、校准中途拔线 —— 都还原到进来之前。
    func cancelCalibrating() {
        if let snapshot {
            isEnabled = snapshot.isEnabled
            originX = snapshot.originX
            originY = snapshot.originY
            cell = snapshot.cell
        }
        snapshot = nil
        isCalibrating = false
    }

    /// 挪左上角。`dx`/`dy` 是**外屏上的点数**（手机上拖多远换算过来）。
    /// 格距不动 —— 这一步用户在对左上角，格子大小这时候变了他会以为自己拖错了。
    func move(dx: CGFloat, dy: CGFloat, board: PartsBoard, screen: CGSize) {
        originX += dx / screen.width
        originY += dy / screen.width
        normalize(board: board, screen: screen)
    }

    func setOrigin(x: CGFloat, y: CGFloat, board: PartsBoard, screen: CGSize) {
        originX = x / screen.width
        originY = y / screen.width
        normalize(board: board, screen: screen)
    }

    /// 改格距（左上角钉住不动，右下角跟着走 —— 这正是用户在做的事）。
    /// `delta` 是**一格**变大/变小多少点。
    func resize(cellDelta delta: CGFloat, board: PartsBoard, screen: CGSize) {
        cell += delta / screen.width
        normalize(board: board, screen: screen)
    }

    /// 拖右下角把手。`startCell` 是按下那一刻的格距，`translation` 是从那一刻起
    /// 累计的位移（外屏点数）—— 累计量得配一个固定的起点算，不能每帧往当前值上加。
    ///
    /// 横竖各自算出「一格该变多少」再取平均：板子不是正方形时只认一个方向的话，
    /// 顺手斜着一拖会觉得跟不上手。
    func resizeCorner(from startCell: CGFloat, translation: CGSize,
                      board: PartsBoard, screen: CGSize) {
        let perCol = translation.width / CGFloat(max(board.cols, 1))
        let perRow = translation.height / CGFloat(max(board.rows, 1))
        cell = startCell + (perCol + perRow) / 2 / screen.width
        normalize(board: board, screen: screen)
    }

    /// 回到「铺满」。用户换了地方摆投影仪、或者干脆接的是电视时的出路。
    ///
    /// 校准值一并清掉（不只是关开关）：投影仪挪过之后那组数已经不作数了，
    /// 留着只会让下次进来时对着一堆错的数字微调。
    func resetToFilling() {
        snapshot = nil
        isCalibrating = false
        isEnabled = false
        originX = 0
        originY = 0
        cell = 0
        save()
    }

    /// 每次改完都走一遍：格子不能小到看不见、板子不能整块拖出画面。
    ///
    /// **改格距之后也必须重来一遍** —— 「板子还剩多少在画面里」是拿板子的尺寸算的，
    /// 而板子的尺寸跟着格距变。只夹格距不夹左上角的话，先把板子拖到左边缘外、
    /// 再把格子调小，整块板就滑出画面了，而画面外的东西在手机预览上也点不到，
    /// 用户再也拖不回来。
    private func normalize(board: PartsBoard, screen: CGSize) {
        guard screen.width > 0 else { return }
        let cols = CGFloat(max(board.cols, 1))
        let rows = CGFloat(max(board.rows, 1))
        // 一格小于画面宽度的千分之一就什么都看不清了；大到一格占半屏也没意义。
        cell = min(max(cell, 0.001), 0.5)
        let width = cell * cols
        let height = cell * rows
        // 至少留 5% 屏宽在画面里，不然用户就再也找不回这块板了
        originX = min(max(originX, -width + 0.05), 1 - 0.05)
        let bottom = screen.height / screen.width
        originY = min(max(originY, -height + 0.05), bottom - 0.05)
    }
}
