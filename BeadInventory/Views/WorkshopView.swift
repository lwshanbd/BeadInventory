//
//  WorkshopView.swift
//  BeadInventory
//
//  工作台 Tab：正在做的事 —— 识别图纸、拼图模式。
//  「我的计划」已经搬出去成了独立的「计划」Tab（五栏：库存 / 计划 / 工作台 / 记录 / 更多）。
//

import SwiftUI
import UIKit

struct WorkshopView: View {
    @Binding var externalImage: UIImage?

    var body: some View {
        ScanView(externalImage: $externalImage)
    }
}
