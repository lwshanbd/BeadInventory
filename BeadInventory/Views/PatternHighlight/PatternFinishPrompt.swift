//
//  PatternFinishPrompt.swift
//  BeadInventory
//

import Foundation

/// 「照着拼」最后一屏那个「完成」要不要先问一句，按项目记。
///
/// 那一下「完成」= 存盘 + 关掉整条流程。数据不会丢，但流程关掉了：用户得回去重新打开
/// 项目、等图纸重新载进来，中间那几秒并不知道刚才那一下按的是什么。而两屏的「完成」
/// 都紧挨着他真正想点的东西 —— 单图纸模式它跟「…」菜单同在导航栏右上角，想点菜单里的
/// 「清除高亮」手指偏一点就中招；多零件模式是下半屏一条通栏按钮，就压在他一直在动的
/// 拼板下面。
///
/// 所以还有颜色没标记完成时先问一句。全部标记完了不问 —— 那时候「完成」正是他要的。
///
/// **记在 `UserDefaults`，不写进项目数据。** 这是「别再拦我」，不是图纸的一部分：
/// 写进 `ProjectRecord` 要多一次模型迁移，而且会跟着 iCloud 同步过去 ——
/// 一个人在手机上嫌它烦，不代表他在 iPad 上也不想要这句提醒。
///
/// **`RawRepresentable` 而不是裸 String。** 视图里同时挂着好几个 `String` 型
/// `@AppStorage`（`PartsBoardStepView` 上就有一个存板子尺寸历史的），helper 要是收发
/// 裸 String，把结果赋错一个类型完全通过，编译器一声不吭，用户看到的是板子尺寸列表
/// 变成一串 UUID。包成独立类型之后那种写法直接编不过。
///
/// 落盘形态是一串逗号隔开的 id。不用 `Data` + `Codable Set` 是因为 `Set` 的编码顺序
/// 不保证稳定，同一份内容可能编出不同字节、白白触发写入和刷新；而且 `defaults read`
/// 出来是一坨 base64，出问题时看不出记的是哪几个项目。UUID 字符串里不会出现逗号，
/// 这个分隔符是安全的。
///
/// 项目删掉之后它的 id 还留在这串里，没有地方清。一条 37 字节，不值得为它挂个清理钩子。
struct PatternFinishPrompt: RawRepresentable, Equatable {
    static let storageKey = "patternFinishPromptSkippedProjects"

    /// 按过「不再询问」的那些项目。**记的是例外，不是全体** —— 没记过的一律要问，
    /// 所以新项目、以及这个功能上线之前就存在的项目，默认都有这道确认。
    private var skipped: Set<UUID>

    init(rawValue: String) {
        // 认不出的段直接丢掉，同 `BeadBoardSize.decodeList`：这份偏好坏了最多是少拦一次，
        // 不值得为它把整串作废，也不值得让脏数据一直跟着写回去。
        skipped = Set(rawValue.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    var rawValue: String {
        skipped.map(\.uuidString).sorted().joined(separator: ",")
    }

    func asksBeforeFinishing(_ projectId: UUID) -> Bool {
        !skipped.contains(projectId)
    }

    /// 只动这一个项目。别的项目照旧问 —— 用户嫌烦的是他已经拼了一半、心里有数的那张图，
    /// 不是以后每一张。
    mutating func setAsksBeforeFinishing(_ asks: Bool, for projectId: UUID) {
        if asks {
            skipped.remove(projectId)
        } else {
            skipped.insert(projectId)
        }
    }
}
