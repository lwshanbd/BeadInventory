//
//  BoardProjector.swift
//  BeadInventory
//
//  投影仪模式：把投出来的画面对到桌上那块拼豆板上，然后只亮当前色号的那些格子
//
//  ## 这个模式在解决什么
//
//  投影仪不认识拼豆板。它把画面投在桌面上，画面多大、落在哪儿、歪成什么样，取决于
//  机器摆在哪儿、镜头怎么调 —— 跟豆板的位置和大小没有任何关系。默认那套「板子居中
//  铺满整块屏幕」是给电视看的（人抬头看图），投影仪上却是要**照着投影往豆板上按豆子**：
//  投出来的一格没落在豆板的一个孔上，这个功能就等于没有。
//
//  ## 为什么是四个角，不是「一个角 + 一格多大」
//
//  投影仪很少正对着桌面，多半架在旁边斜着照 —— 投在桌上的正方形画面因此是个梯形。
//  「一个角 + 格距」只能表达平移和等比缩放，对上了左上角，右下角必然差出去；
//  四个角把梯形也包含进来了，中间的格子自动就对上（平面透视的性质，见
//  `ProjectorGeometry.swift`）。用户要做的仍然只是「把方框的角拖到板子的角上」，
//  从两个角变成四个角，不需要理解多一个概念。
//
//  ## 存的是「豆板的四个角在画面里的位置」+「这块豆板多少格」
//
//  两样都是**桌上那套摆法**的属性，跟正在拼的图纸没关系：换一张图纸、换一块图纸更大的
//  项目，投影仪没挪、豆板没挪，这组值就还作数。图纸比豆板大的时候，超出豆板的那些格子
//  按同一个变换往外延伸（`ProjectorMapping` 会自己判断哪些格子已经翻到透视中心背后，
//  那些不画）。
//
//  角的坐标以**外屏宽度**为单位（x 和 y 都是）：换投影仪、换输出分辨率，点数全变、
//  比例还在。
//
//  ## 还存了「亮的格子投什么颜色」
//
//  同样是桌上那套摆法的属性：白板子、暖光台灯、投影仪偏色，只有站在那儿的人知道
//  哪个颜色看得清。三种投法见 `ProjectorHighlightStyle`，跟四个角一起存、一起还原。
//

import Combine
import SwiftUI

/// 四个角标各自的颜色。手机上和外屏上必须是同一套 —— 用户就是靠颜色认
/// 「我现在在调哪个角」。所以只有这一处定义。
///
/// 写死不走 Theme：这几道线要在**桌面和豆板**上看得见，跟 App 的色彩模式无关。
/// 四个颜色分得很开（黄 / 青 / 绿 / 品红），投在白板子上隔着一米也不会认错。
extension ProjectorCorner {
    var markColor: Color {
        switch self {
        case .topLeft: return Color(red: 1.0, green: 0.83, blue: 0.0)
        case .topRight: return Color(red: 0.2, green: 0.9, blue: 1.0)
        case .bottomRight: return Color(red: 0.35, green: 1.0, blue: 0.45)
        case .bottomLeft: return Color(red: 1.0, green: 0.4, blue: 0.85)
        }
    }
}

@MainActor
final class BoardProjector: ObservableObject {
    static let shared = BoardProjector()

    /// 投影仪模式开着。false = 板子居中铺满外屏（接电视时要的就是这个）。
    ///
    /// 注意它不是「校准过了没有」：进校准页就会打开它（不然没东西可拖）。
    /// 「取消」是**整组还原到进来之前**（本来就开着就还开着），只有
    /// 「关掉投影仪模式」一定关。
    @Published private(set) var isOn: Bool
    /// 桌上那块豆板的四个角，在外屏画面里的位置（单位：外屏宽度）
    @Published private(set) var quad: ProjectorQuad
    /// 那块豆板多少格。**必须是实物板的格数** —— 四个角是对着实物板的四个角放的，
    /// 格数说错，中间每一格就都错位（说成一半格数，一格就差一倍）。
    @Published private(set) var boardCols: Int
    @Published private(set) var boardRows: Int

    /// 用户正开着校准页。外屏据此把四个角标和辅助线画出来 ——
    /// 平时一道都不画：拼的时候画面上多几条亮线，人照着按豆子会把它当成格线数进去。
    @Published private(set) var isCalibrating = false
    /// 手机上选中的那个角（微调按钮作用在它身上，外屏上它更亮、拐角那格还描一圈白）。
    @Published var activeCorner: ProjectorCorner = .topLeft

    /// 亮的格子投什么颜色。外屏画格子、外屏图例、手机上那条样例条都读它
    /// （见 `ProjectorHighlightPaint`）。
    @Published private(set) var highlight: ProjectorHighlightPaint

    /// 用户在投影仪跟前长按了遥控器的确定键。手机上正显示着板子的那一屏收到之后
    /// **把校准页弹出来**，由那一页的 `onAppear` 去调 `beginCalibrating`。
    ///
    /// 绕这一圈是必须的：`isCalibrating` 的开和关得始终绑在同一页的生死上。
    /// 从网络那头直接把它置真的话，手机上不会出现任何界面，而推流从此只走校准分支
    /// —— 投影仪停在原地，用户手上没有任何能退出它的东西，只能重启 App。
    ///
    /// 是 `PassthroughSubject` 不是 `@Published`：它表示「刚刚按了一下」这个事件，
    /// 不是一个状态。用 `@Published` 的话，之后每次进板子那一屏都会在订阅的一瞬间
    /// 收到上一次的值 —— 用户什么都没按，校准页自己弹出来。
    let remoteCalibrationRequest = PassthroughSubject<Void, Never>()

    /// 进校准页那一刻的整组值。取消时全组还原 —— 用户是趴在桌上对着实物拖出来的，
    /// 手一滑就被覆盖、还没有退路，是这一屏最容易惹人恼火的地方。
    ///
    /// 颜色也在这一组里：那一屏上所有能改的东西，「取消」都得能收回去。
    /// 少还原一样，就得让用户自己记住「哪些改动会留下」。
    private struct Snapshot {
        let isOn: Bool
        let quad: ProjectorQuad
        let cols: Int
        let rows: Int
        let highlight: ProjectorHighlightPaint
    }
    private var snapshot: Snapshot?

    private enum Key {
        static let on = "boardProjector.on"
        static let corners = "boardProjector.corners"      // 8 个数：TL TR BR BL
        static let cols = "boardProjector.boardCols"
        static let rows = "boardProjector.boardRows"
        static let highlightStyle = "boardProjector.highlightStyle"
        static let highlightCustomHex = "boardProjector.highlightCustomHex"
        /// 老版本（一个角 + 格距）的值搬过来一次就够了，见 `migrateFromPitchCalibration`
        static let migrated = "boardProjector.migratedFromPitch"
    }

    /// 老版本那四个 key。只在迁移时读一次，读完不再维护。
    private enum LegacyKey {
        static let enabled = "boardCast.calibration.enabled"
        static let originX = "boardCast.calibration.originX"
        static let originY = "boardCast.calibration.originY"
        static let cell = "boardCast.calibration.cell"
    }

    private init() {
        let defaults = UserDefaults.standard
        isOn = defaults.bool(forKey: Key.on)
        boardCols = defaults.integer(forKey: Key.cols)
        boardRows = defaults.integer(forKey: Key.rows)
        quad = Self.decodeQuad(defaults.array(forKey: Key.corners) as? [Double])
            ?? ProjectorQuad(topLeft: .zero, topRight: .zero, bottomRight: .zero, bottomLeft: .zero)
        highlight = ProjectorHighlightPaint(
            // 没存过就跟着图纸走 —— 老用户升上来，投出来的画面跟升级前一模一样。
            style: ProjectorHighlightStyle(rawValue: defaults.string(forKey: Key.highlightStyle) ?? "")
                ?? .pattern,
            // 存坏了退回这个亮黄，不退回白：白是另一个合法选项，
            // 退成白的话用户看到的是「我选的自定义，颜色却跟白色那一项一模一样」。
            custom: Color(uiColor: UIColor(themeHex: defaults.string(forKey: Key.highlightCustomHex)
                                           ?? Self.defaultCustomHex,
                                           fallback: UIColor(themeHex: Self.defaultCustomHex)))
        )
        if boardCols <= 0 || boardRows <= 0 {
            boardCols = Self.defaultBoardSize.cols
            boardRows = Self.defaultBoardSize.rows
        }
        migrateFromPitchCalibration()
        // 开着投影仪模式、四个角却不可用，是唯一一种「手机说一套、外屏演一套」的状态：
        // chip 读 `isOn` 写着「只亮当前色号」，而 `mapping(in:)` 返回 nil，外屏其实在铺满。
        // 存坏了、或者从老版本一个极小的格距搬过来，都会落到这儿。关掉它，
        // 用户看到的至少是同一句话，重新对一次就好了。
        if isOn, !quad.isUsable {
            AppLogger.shared.error("BoardProjector", "calibration_unusable_reset", metadata: [
                "quad": "\(quad.clockwise)", "board": "\(boardCols)x\(boardRows)"
            ])
            isOn = false
            save()
        }
    }

    /// 没别的信息时按最常见的那块板算（拼豆板 52×52）。
    private static let defaultBoardSize = BeadBoardSize(cols: 52, rows: 52)

    /// 刚点开「自定义」时给的那个颜色：亮黄。白光之外最扎眼的一个，
    /// 而且跟白色一眼能分开 —— 点开自定义却发现「跟刚才没区别」是最糟的第一印象。
    private static let defaultCustomHex = "FFD400"

    /// 上一版存的是「左上角 + 一格多大」。那组值只表达了平移和缩放，正好等于
    /// 「四个角围成一个正矩形」这种特例，所以能一比一搬过来：**投出来的画面跟升级前
    /// 一模一样**，用户不会因为升级发现自己对好的位置没了。斜投带来的那点梯形，
    /// 等他下次进校准页拖两个角就补上了。
    ///
    /// 搬的时候必须用同一个格数去反推四个角，得到的格距才跟原来相等（原来那组值
    /// 里没有「实物板多少格」这件事，所以只能按最常见的 52×52 算）。
    private func migrateFromPitchCalibration() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Key.migrated) else { return }
        defaults.set(true, forKey: Key.migrated)

        guard defaults.bool(forKey: LegacyKey.enabled) else { return }
        let cell = CGFloat(defaults.double(forKey: LegacyKey.cell))
        guard cell > 0 else { return }
        let x = CGFloat(defaults.double(forKey: LegacyKey.originX))
        let y = CGFloat(defaults.double(forKey: LegacyKey.originY))
        let width = cell * CGFloat(boardCols)
        let height = cell * CGFloat(boardRows)
        quad = ProjectorQuad(
            topLeft: CGPoint(x: x, y: y),
            topRight: CGPoint(x: x + width, y: y),
            bottomRight: CGPoint(x: x + width, y: y + height),
            bottomLeft: CGPoint(x: x, y: y + height)
        )
        isOn = true
        save()
    }

    /// 只在「完成」「恢复铺满」和迁移时落盘。
    ///
    /// 拖动过程中不存：一次拖动几百帧，每帧写一遍是白写的，而且中途每一个中间值
    /// 都会变成「用户的校准值」—— 取消就没得取消了。
    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(isOn, forKey: Key.on)
        defaults.set(boardCols, forKey: Key.cols)
        defaults.set(boardRows, forKey: Key.rows)
        defaults.set(Self.encodeQuad(quad), forKey: Key.corners)
        defaults.set(highlight.style.rawValue, forKey: Key.highlightStyle)
        defaults.set(highlight.custom.toThemeHex(), forKey: Key.highlightCustomHex)
    }

    private static func encodeQuad(_ quad: ProjectorQuad) -> [Double] {
        quad.clockwise.flatMap { [Double($0.x), Double($0.y)] }
    }

    private static func decodeQuad(_ values: [Double]?) -> ProjectorQuad? {
        guard let values, values.count == 8 else { return nil }
        return ProjectorQuad(
            topLeft: CGPoint(x: values[0], y: values[1]),
            topRight: CGPoint(x: values[2], y: values[3]),
            bottomRight: CGPoint(x: values[4], y: values[5]),
            bottomLeft: CGPoint(x: values[6], y: values[7])
        )
    }

    // MARK: - 给渲染用

    /// 「板上第几行第几列」→「外屏上哪一点」。nil = 没开投影仪模式、或者这四个角
    /// 围不成一块正经地方，调用方据此退回铺满。
    func mapping(in screen: CGSize) -> ProjectorMapping? {
        guard isOn else { return nil }
        return ProjectorMapping(quad: quad, screen: screen, cols: boardCols, rows: boardRows)
    }

    // MARK: - 给校准页用

    /// 进校准页：记一份快照，把投影仪模式打开。
    ///
    /// `suggestedBoard` 是这一屏正在拼的那块板 —— 多零件模式下它就是实物豆板，
    /// 直接拿来当默认格数，用户少答一个问题。单图纸模式送 nil（图纸大小跟实物板无关，
    /// 猜错了比不猜更糟），沿用上次存的格数。
    func beginCalibrating(suggestedBoard: BeadBoardSize?, screen: CGSize) {
        // `onAppear` 不保证只跑一次。跑第二次时快照会变成「已经拖到一半的值」，
        // 那之后「取消」还原到的是中间态，用户对了半天的原始校准无声消失。
        guard !isCalibrating else { return }
        snapshot = Snapshot(isOn: isOn, quad: quad, cols: boardCols, rows: boardRows,
                            highlight: highlight)
        if let suggestedBoard, !isOn {
            // 只在还没开着投影仪模式时才采纳：已经对好的用户换张图纸再进来，
            // 格数不该被这张图纸的尺寸改掉 —— 桌上那块板并没有变。
            boardCols = suggestedBoard.cols
            boardRows = suggestedBoard.rows
        }
        if !quad.isUsable {
            quad = ProjectorQuad.centered(cols: boardCols, rows: boardRows, in: screen)
        }
        isOn = true
        isCalibrating = true
    }

    func finishCalibrating() {
        snapshot = nil
        isCalibrating = false
        save()
    }

    /// 「取消」、从校准页划走、校准中途拔线 —— 都还原到进来之前。
    func cancelCalibrating() {
        if let snapshot {
            isOn = snapshot.isOn
            quad = snapshot.quad
            boardCols = snapshot.cols
            boardRows = snapshot.rows
            highlight = snapshot.highlight
        }
        snapshot = nil
        isCalibrating = false
    }

    /// 换一块实物豆板（或者纠正格数）。四个角不动 —— 角是对着实物板的角放的，
    /// 板子没挪，角就不该动；变的只是这个框里分成多少格。
    func setBoardSize(_ size: BeadBoardSize) {
        boardCols = max(size.cols, 1)
        boardRows = max(size.rows, 1)
    }

    /// 换一种投法（跟着图纸 / 白色 / 自定义）。外屏立刻跟着变 ——
    /// 用户就是站在投影仪旁边照着实物挑的，这一眼就是他的判据。
    func setHighlightStyle(_ style: ProjectorHighlightStyle) {
        highlight.style = style
    }

    /// 换自定义的那个颜色，顺带切到「自定义」这一项。
    /// 不夹亮度：他可能就是要压暗（屋里很黑、板子反光）。挑得太暗时手机上提醒一句，
    /// 改不改由他。
    func setCustomHighlightColor(_ color: Color) {
        highlight.custom = color
        highlight.style = .custom
    }

    /// 拖一个角。`point` 是**外屏上的点数**（手机预览上拖到哪儿换算过来）。
    ///
    /// 拖成「8」字、拧成一条线的时候直接不采纳这一帧：那种四边形算出来的映射
    /// 是乱的（格子翻面、飞出画面），画出来用户只会以为投屏坏了。
    func setCorner(_ corner: ProjectorCorner, to point: CGPoint, screen: CGSize) {
        guard screen.width > 0 else { return }
        var next = quad
        next[corner] = CGPoint(
            x: min(max(point.x / screen.width, 0), 1),
            y: min(max(point.y / screen.width, 0), screen.height / screen.width)
        )
        guard next.isUsable else { return }
        quad = next
        activeCorner = corner
    }

    /// 投影仪上的遥控器把四个角挪了，整组搬过来。
    ///
    /// 值已经是归一化的（安卓端跟这边用同一套单位），所以不再换算，只做跟
    /// `setCorner` 一样的可用性检查 —— 拧成「8」字的四边形算出来的映射是乱的，
    /// 而这一份是从网络来的，本地拦不住就只能画出一团乱纹。
    /// 返回值是**采纳了没有**。调用方必须看：拒绝时两端已经不一致了，
    /// 得把这边正确的那组顶回去，否则投影仪拿着一组被丢掉的角在画，
    /// 而手机这边以为「两端一致」再也不发校准 —— 用户按遥控器角标乱跑，拉不回来。
    @discardableResult
    func applyRemoteQuad(_ next: ProjectorQuad) -> Bool {
        guard next.isUsable else { return false }
        quad = next
        return true
    }

    /// 微调选中的那个角。`dx`/`dy` 是外屏上的点数。
    func nudgeActiveCorner(dx: CGFloat, dy: CGFloat, screen: CGSize) {
        let current = quad.point(activeCorner, in: screen)
        setCorner(activeCorner, to: CGPoint(x: current.x + dx, y: current.y + dy), screen: screen)
    }

    /// 整块框一起挪（四个角同时走）。豆板在桌上被碰了一下、或者投影仪轻微挪位时，
    /// 一个角一个角重对是没必要的 —— 形状没变，位置变了。
    func nudgeWholeQuad(dx: CGFloat, dy: CGFloat, screen: CGSize) {
        guard screen.width > 0 else { return }
        var next = quad
        for corner in ProjectorCorner.allCases {
            next[corner] = CGPoint(x: next[corner].x + dx / screen.width,
                                   y: next[corner].y + dy / screen.width)
        }
        // 整块拖出画面就再也拖不回来了（画面外的东西手机预览上也点不到），所以要拦。
        //
        // **拦法是夹到边上，不是整帧丢掉**：丢掉的话，一旦这块框已经越界
        // （换一台长宽比不同的投影仪、或者从老版本搬过来的值本来就超出画面），
        // 这个按钮就**任何方向都按不动了，包括往回挪的那个方向** —— 一个看着能按、
        // 按了什么都不发生的按钮。
        let bottom = screen.height / screen.width
        let xs = next.clockwise.map(\.x), ys = next.clockwise.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return }
        // 只往「把越界量变小」的方向让步：本来就越界的，这一下至少能把它拉回来一点
        var fixX: CGFloat = 0, fixY: CGFloat = 0
        if minX < -0.05 { fixX = min(-0.05 - minX, max(0, -dx / screen.width)) }
        if maxX > 1.05 { fixX = max(1.05 - maxX, min(0, -dx / screen.width)) }
        if minY < -0.05 { fixY = min(-0.05 - minY, max(0, -dy / screen.width)) }
        if maxY > bottom + 0.05 { fixY = max(bottom + 0.05 - maxY, min(0, -dy / screen.width)) }
        if fixX != 0 || fixY != 0 {
            for corner in ProjectorCorner.allCases {
                next[corner] = CGPoint(x: next[corner].x + fixX, y: next[corner].y + fixY)
            }
        }
        quad = next
    }

    /// 一格在外屏上大概多少点。微调按钮的步长按它算，所以按一下永远是「四分之一格」，
    /// 跟界面上写的那句话一致 —— 用户眼里的单位是格，「一次 3 个点」他没法判断按几下。
    func cellSize(in screen: CGSize) -> CGFloat {
        mapping(in: screen)?.averageCellSize ?? 0
    }

    /// 回到铺满。用户换了地方摆投影仪、或者干脆接的是电视时的出路。
    ///
    /// 四个角一并清掉（不只是关开关）：投影仪挪过之后那组数已经不作数了，
    /// 留着只会让下次进来时对着一堆错的数字微调。
    func resetToFilling() {
        // 这一屏改过的颜色跟「取消」一样收回去：用户点的是「关掉」，
        // 没道理把他随手试的那个颜色顺手存下来。
        if let snapshot { highlight = snapshot.highlight }
        snapshot = nil
        isCalibrating = false
        isOn = false
        quad = ProjectorQuad(topLeft: .zero, topRight: .zero, bottomRight: .zero, bottomLeft: .zero)
        save()
    }
}
