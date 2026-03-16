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
}
