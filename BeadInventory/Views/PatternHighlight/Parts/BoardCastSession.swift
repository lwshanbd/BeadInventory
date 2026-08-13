//
//  BoardCastSession.swift
//  BeadInventory
//
//  拼豆板往外接屏幕上投的那份状态
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
//  横着铺满整块屏幕，而手机上该点什么还点什么。YouTube 投视频是同一套机制。
//
//  ## 它只是一块白板
//
//  这里刻意不放任何逻辑：拼豆板那一屏在显示的时候把「现在该画什么」写进来，
//  外屏那个窗口读出来画。谁都不知道对方存不存在 —— 没接外屏时这里的写入没人读，
//  没打开拼豆板时外屏显示一句「在手机上打开拼豆板」。
//

import SwiftUI

@MainActor
final class BoardCastSession: ObservableObject {
    static let shared = BoardCastSession()

    /// 外屏现在该画的那块板。nil = 手机上没开着拼豆板。
    @Published private(set) var content: Content?
    /// 外屏（电视 / 投影仪）连上了没有。
    ///
    /// 拼豆板那一屏据此显示「投屏中」—— 用户接了 AirPlay 之后第一件想确认的就是
    /// 「到底投上了没有」，而他多半人在电视那头，手机屏幕上得有个准信。
    @Published var externalConnected = false

    struct Content {
        let board: PartsBoard
        let footprints: [UUID: PartFootprint]
        let colorCache: [String: Color]
        /// 手机上选了只看某个色号时，外屏也只亮那个 —— 用户抬头找的就是它
        let highlightKey: String?
        /// 第几块 / 共几块。拼的人需要知道自己在哪一块上。
        let boardIndex: Int
        let boardCount: Int
    }

    private init() {}

    /// 调用方（拼豆板那一屏）自己判断「有没有变」再调，所以这里不再比一次 ——
    /// 里面装着几十个零件的形状，比一遍比直接赋值还贵。
    func update(_ content: Content) {
        self.content = content
    }

    func stop() {
        content = nil
    }
}
