//
//  BoardCastSession.swift
//  BeadInventory
//
//  往外接屏幕上投的那份状态（多零件的拼豆板 / 单图纸的整张图纸都走这里）
//
//  ## 为什么要有它
//
//  用户是**对着大屏拼、低头看手机操作**的：一块 100×100 的板子在手机上一格只有三四个点，
//  拼的时候得凑到眼前一格一格数；投到电视上一格就有二十几个点，抬头就能看见「下一颗
//  红色在哪儿」。
//
//  但 AirPlay 默认是镜像 —— 电视上出现的是一台竖着的手机，板子仍然只占中间一小条，
//  两边全是黑边，等于没投。所以这里走 iOS 的**外接屏幕专用场景**
//  （`UIWindowSceneSessionRoleExternalDisplayNonInteractive`）：App 给外屏一份自己的画面，
//  横着铺满整块屏幕，而手机上该点什么还点什么。视频类 App 投屏时走的是类似的思路。
//
//  ## 它只是一块白板
//
//  这里刻意不放任何逻辑：手机上那一屏在显示的时候把「现在该画什么」写进来，
//  外屏那个窗口读出来画。谁都不知道对方存不存在 —— 没接外屏时这里的写入没人读，
//  手机上没打开对应那一屏时外屏显示一句话告诉用户去哪儿开。
//
//  ## 单图纸也是「一块板」
//
//  单图纸模式送过来的是**整张图纸当成一块板、一个占满全板的「零件」**。
//  形状上它跟拼豆板没有区别（都是「哪一格放哪个色号」），画法因此完全共用 ——
//  为它另写一套渲染，只会在改高亮规则时漏掉一边，而用户是对着电视拼的，一眼就看得出来。
//

import SwiftUI

@MainActor
final class BoardCastSession: ObservableObject {
    static let shared = BoardCastSession()

    /// 外屏现在该画的那块板。
    /// nil = 手机那边现在没有板子可给：要么没开着拼豆板那一屏，要么开着但一块板都还没有。
    @Published private(set) var content: Content?
    /// 外屏（电视 / 投影仪）连上了没有。
    ///
    /// 手机那一屏据此显示「投屏中」—— 用户接了 AirPlay 之后第一件想确认的就是
    /// 「到底投上了没有」，而他多半人在电视那头，手机屏幕上得有个准信。
    @Published var externalConnected = false
    /// 外屏有多大（点）。**校准页要靠它**：手机上那块预览得按外屏的长宽比画，
    /// 手指拖的那几十点也要按这个比例换算成外屏上的点数。
    /// nil = 没接外屏（校准页此时开不出来）。
    @Published var externalScreenSize: CGSize?

    struct Content {
        let board: PartsBoard
        let footprints: [UUID: PartFootprint]
        let colorCache: [String: Color]
        /// 手机上选了只看哪几个色号，外屏也只亮它们 —— 用户抬头找的就是它
        let highlightKeys: Set<String>
        /// 外屏底下那一行左边写什么。多零件是「第 3 / 7 块」，单图纸是图纸有多少格。
        /// 由手机那边给现成的句子：这里不知道自己在为哪种模式服务，也不该知道。
        let caption: String
        /// 板上每个零件写的编号。电视那头的人拼到一半抬头问的正是「这块是几号」，
        /// 手机上写了号、电视上不写，他就得低头再找一遍。
        /// 单图纸模式整张图只有一个「零件」，没有号，用默认的空表。
        var labels: [UUID: String] = [:]
        /// 跟旁边挨上了、又挪不开的那些摆放。电视上也要标红 ——
        /// 抬头照着电视摆豆子的人，正是会照着这两块摆成粘连的那个人。
        var invalid: Set<UUID> = []
    }

    private init() {}

    /// 这里不比「有没有变」—— 里面装着几十个零件的形状，比一遍比直接赋值还贵。
    /// 判断的责任在调用方（`PartsBoardStepView.castSignature` / `SinglePatternHighlightStepView`）。
    /// 改那个 signature 的时候记得，漏掉一项的代价是电视上停着一块过期的板。
    func update(_ content: Content) {
        self.content = content
    }

    func stop() {
        content = nil
    }
}
