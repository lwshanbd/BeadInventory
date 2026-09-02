//
//  PatternFinishPrompt.swift
//  BeadInventory
//
//  「照着拼」最后一屏那个「完成」按下去之前问一句，以及「本项目不再询问」记在哪儿。
//

import Foundation

/// 「完成」的二次确认要不要弹，按项目记。
///
/// 那一下「完成」= 存盘 + 关掉整条流程。而用户按到它的时候，手里正抓着一把豆子、
/// 眼睛在板子上 —— 单图纸模式它在导航栏右上角，多零件模式是下半屏一条通栏按钮，
/// 两个都在拇指顺手扫过的地方。数据不会丢，但流程关掉了：他得回去重新打开项目、
/// 等图纸重新载进来，中间那几秒并不知道刚才那一下按的是什么。
///
/// 所以还有颜色没标记完成时先问一句。全部标记完了不问 —— 那时候「完成」正是他要的。
///
/// **记在 `UserDefaults`，不写进项目数据。** 这是「别再拦我」，不是图纸的一部分：
/// 写进 `ProjectRecord` 要多一次模型迁移，而且会跟着 iCloud 同步过去 ——
/// 一个人在手机上嫌它烦，不代表他在 iPad 上也不想要这句提醒。
///
/// **存成一串逗号隔开的 id，不存数组**：这样视图能直接 `@AppStorage` 它，
/// 「…」菜单里那个勾才会跟着变。`@AppStorage` 认不了 `[String]`。
enum PatternFinishPrompt {
    static let storageKey = "patternFinishPromptSkippedProjects"

    /// 这个项目按过「不再询问」没有。
    static func isSkipped(_ projectId: UUID, in raw: String) -> Bool {
        ids(in: raw).contains(projectId.uuidString)
    }

    /// 改完之后该写回 `@AppStorage` 的那串。
    ///
    /// 只动这一个项目。别的项目照旧问 —— 用户嫌烦的是他已经拼了一半、心里有数的那张图，
    /// 不是以后每一张。
    static func setting(_ skipped: Bool, for projectId: UUID, in raw: String) -> String {
        var list = ids(in: raw)
        if skipped {
            list.insert(projectId.uuidString)
        } else {
            list.remove(projectId.uuidString)
        }
        return list.sorted().joined(separator: ",")
    }

    private static func ids(in raw: String) -> Set<String> {
        Set(raw.split(separator: ",").map(String.init))
    }
}
