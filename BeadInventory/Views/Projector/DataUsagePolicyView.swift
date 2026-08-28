//
//  DataUsagePolicyView.swift
//  BeadInventory
//
//  数据使用声明：图纸和零件只在啃豆小仓里用
//
//  ## 为什么要写出来
//
//  一张图纸从照片到能拼，中间隔着对网格、判色、跨品牌换算、拆零件、排板 —— 这些
//  结果是在这个 App 里一步步做出来的，不是原图自带的。声明把「能不能带走」这件事
//  摆到明面上，用户就不用自己猜。
//
//  技术上也是按这个方向做的：投影时推给投影仪的是**渲染好的位图**，不是格点数据
//  （见 `ProjectorProtocol`），接收端因此复原不出图纸。声明和实现是一回事的两面。
//

import SwiftUI

struct DataUsagePolicyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    section(
                        "适用范围",
                        "本声明适用于您在「啃豆小仓」内生成的图纸数据，包括网格对齐结果、"
                        + "逐格色号判定、跨品牌色号换算、零件拆分与排板方案，以及与之关联的"
                        + "库存、计划和统计记录。"
                    )
                    section(
                        "仅限本应用内使用",
                        "上述数据仅供您在「啃豆小仓」内查看与拼装使用。"
                        + "未经授权，不得导出、复制、转移或同步至其他应用程序、网站或服务，"
                        + "亦不得用于生成可供第三方应用识别的图纸文件。"
                    )
                    section(
                        "投影功能",
                        "投影时传输至接收端的是渲染完成的画面，不包含可用于还原图纸的格点数据。"
                        + "接收端不写入存储、不提供导出入口；断开连接后仅在屏幕上保留最后一帧，"
                        + "退出应用即消失。"
                    )
                    section(
                        "您的作品",
                        "您拍摄或导入的原始图片，以及您完成的实物作品，其权利归您所有，"
                        + "本声明不作限制。"
                    )
                }
                .padding(Theme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.ColorToken.Surface.background)
            .navigationTitle("数据使用声明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title)
                .font(.headline)
                .foregroundColor(Theme.ColorToken.Text.primary)
            Text(body)
                .font(.subheadline)
                .foregroundColor(Theme.ColorToken.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
