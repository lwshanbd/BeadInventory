//
//  AppBackgroundTaskManager.swift
//  BeadInventory
//
//  Wraps short persistence operations in an iOS background task so the app
//  can finish ongoing SQLite/CloudKit work when it is moving to the background.
//

import Foundation

#if canImport(UIKit)
import UIKit
#endif

final class AppBackgroundTaskManager {
    static let shared = AppBackgroundTaskManager()

    private init() {}

    func perform(named taskName: String, _ operation: () -> Void) {
        #if canImport(UIKit)
        let application = UIApplication.shared
        var taskID: UIBackgroundTaskIdentifier = .invalid

        func endTask() {
            guard taskID != .invalid else { return }
            application.endBackgroundTask(taskID)
            taskID = .invalid
        }

        taskID = application.beginBackgroundTask(withName: taskName) {
            endTask()
        }
        defer { endTask() }
        #endif

        operation()
    }

    /// `perform` 的异步版本。
    ///
    /// `perform` 只能包住同步闭包 —— 它申请的是后台执行时间、**不切线程**，所以一旦把活儿
    /// 挪进 `Task.detached`，同步版本就再也保护不到了。首次启动的持久层读取（含老版本
    /// UserDefaults → SwiftData 的一次性迁移写库）需要在整个 `await` 期间持续持有断言，
    /// 否则用户在迁移写库途中切后台，进程被挂起会让 `context.save()` 半途而废。
    @MainActor
    func performAsync<T>(named taskName: String, _ operation: () async -> T) async -> T {
        #if canImport(UIKit)
        let application = UIApplication.shared
        var taskID: UIBackgroundTaskIdentifier = .invalid

        func endTask() {
            guard taskID != .invalid else { return }
            application.endBackgroundTask(taskID)
            taskID = .invalid
        }

        taskID = application.beginBackgroundTask(withName: taskName) {
            endTask()
        }
        defer { endTask() }
        #endif

        return await operation()
    }
}
