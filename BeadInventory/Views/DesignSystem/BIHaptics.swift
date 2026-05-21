//
//  BIHaptics.swift
//  BeadInventory
//
//  统一封装 SwiftUI 17+ 的 `.sensoryFeedback` 触发器。
//  三档语义：选择切换 / 操作成功 / 操作失败。普通点击不加触觉。
//

import SwiftUI

/// 统一封装 SwiftUI 17+ 的 `.sensoryFeedback` 触发器。
/// 三档语义：选择切换 / 操作成功 / 操作失败。普通点击不加触觉。
enum BIHaptics {
    enum Event {
        case selection   // 多选切换、长按进入选择模式
        case success     // 扣减成功、保存项目、计划完成、回滚成功
        case error       // 库存不足、识别失败、网络错误、删除失败
    }

    static func feedback(for event: Event) -> SensoryFeedback {
        switch event {
        case .selection: return .selection
        case .success:   return .success
        case .error:     return .error
        }
    }
}

/// 视图层语法糖：
///   `.haptic(.success, trigger: deductSuccessAt)`
extension View {
    func haptic<V: Equatable>(_ event: BIHaptics.Event, trigger: V) -> some View {
        self.sensoryFeedback(BIHaptics.feedback(for: event), trigger: trigger)
    }
}
