//
//  PageBreadcrumbs.swift
//  BeadInventory
//
//  长列表页面的诊断面包屑：进了哪页、列表多少条、手机还剩多少内存
//

import SwiftUI
import os

/// TestFlight 上有一类闪退（Organizer 里叫 `Array._reserveCapacityImpl`）：
/// 滚长列表滚了几分钟后，SwiftUI 给 `LazyVStack` 排版时申请内存失败、自己 abort。
/// 栈里一帧 App 代码都没有，看不出是哪一页，也分不清是内存真被用光了还是 SwiftUI 算错了行数。
///
/// 这里把两件事写进 `AppLogger`：
/// - 每个长列表出现 / 消失 / 条数变化时记一行；
/// - 前台每 60 秒记一次剩余内存和当前页面。
/// 崩完让测试的人在「更多 → 诊断」里导出日志，最后几行就是崩溃前停在哪、内存还剩多少。
///
/// 剩余内存用 `os_proc_available_memory()`：离被系统杀掉还差多少，真机上准；模拟器上恒为 0。
@MainActor
enum PageBreadcrumbs {
    private static var currentPage = "-"
    private static var currentCount = 0
    private static var heartbeat: Timer?

    static func record(_ event: String, page: String, count: Int) {
        if event == "page_disappear" {
            // 新页面的 onAppear 可能先于旧页面的 onDisappear 到达，别把新页面冲掉。
            if currentPage == page { currentPage = "-" }
        } else {
            currentPage = page
            currentCount = count
        }
        AppLogger.shared.info("Page", event, metadata: [
            "page": page,
            "count": count,
            "availMB": availableMB()
        ])
        startHeartbeatIfNeeded()
    }

    private static func startHeartbeatIfNeeded() {
        guard heartbeat == nil else { return }
        // 挂在主 RunLoop 上：App 进后台被挂起时自然不跑，回前台接着跑。
        heartbeat = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                AppLogger.shared.info("Page", "memory", metadata: [
                    "page": currentPage,
                    "count": currentCount,
                    "availMB": availableMB()
                ])
            }
        }
    }

    private static func availableMB() -> Int {
        Int(os_proc_available_memory() / 1_048_576)
    }
}

private struct PageBreadcrumbModifier: ViewModifier {
    let page: String
    let count: Int

    func body(content: Content) -> some View {
        content
            .onAppear { PageBreadcrumbs.record("page_appear", page: page, count: count) }
            .onDisappear { PageBreadcrumbs.record("page_disappear", page: page, count: count) }
            .onChange(of: count) { _, newCount in
                PageBreadcrumbs.record("page_count_changed", page: page, count: newCount)
            }
    }
}

extension View {
    /// 给长列表打诊断标记，见 `PageBreadcrumbs`。`page` 只进日志，不显示在界面上。
    func pageBreadcrumb(_ page: String, count: Int) -> some View {
        modifier(PageBreadcrumbModifier(page: page, count: count))
    }
}
