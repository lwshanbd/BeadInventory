//
//  PatternSourceBanner.swift
//  BeadInventory
//
//  「这张图纸还没有原图」的提示条
//
//  拼图模式要逐格看颜色，用的是 `PatternSourceStore` 里另存的那份原图。
//  但很多图纸没有：这个功能上线之前就存在的项目、从别的设备同步过来的、
//  用户点过「拼好了」的。这时候流程会退回用 SwiftData 里那份压缩图 ——
//  能用，但一格豆子只剩十来个像素，放大就是一片糊。
//
//  用户看到糊图是没法自己想明白原因的（「我不是传过图了吗」），
//  所以这里直接把出路摆在他面前：相册里还有原图就选一下，立刻变清楚。
//  没有也不拦着，提示条不挡路，流程照走。
//
//  开关关掉的用户不显示 —— 他已经明确说了不要留原图，再劝一次就是骚扰。
//

import SwiftUI
import PhotosUI

struct PatternSourceBanner: View {
    let projectId: UUID
    /// 原图存好了。调用方据此重新裁一次工作图。
    let onLoaded: () -> Void

    @State private var needsSource = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        Group {
            if needsSource {
                HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                    Image(systemName: "photo.badge.plus")
                        .foregroundStyle(Theme.ColorToken.Morandi.honey)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(failed
                             ? "这张图读不出来，换一张试试。"
                             : "现在用的是压缩过的副本，放大到一颗豆子会糊。相册里还留着这张图纸的原图吗？")
                            .font(.footnote)
                            .foregroundStyle(Theme.ColorToken.Text.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Theme.Spacing.sm)
                    if loading {
                        ProgressView()
                    } else {
                        // `.current`：这一整条路的意义就是拿到没被动过的原始字节，
                        // 默认的 `.automatic` 会把 HEIC 转码成 JPEG，等于白选一次。
                        PhotosPicker(selection: $pickedItem, matching: .images,
                                     preferredItemEncoding: .current) {
                            Text("选原图")
                                .font(.footnote.weight(.medium))
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .background(Theme.ColorToken.Surface.elevated)
            } else {
                // 占位的零高度实体节点。`if` 不成立时 Group 里什么都没有，
                // 下面那个 `.task`（判断到底要不要显示）就永远不会跑 —— 提示条也就永远不出现。
                Color.clear.frame(height: 0)
            }
        }
        .task {
            needsSource = PatternSourceStore.isEnabled && !PatternSourceStore.exists(for: projectId)
        }
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            loading = true
            failed = false
            Task {
                defer { loading = false }
                // UIImage 解一遍只是确认这确实是张能用的图 —— 存进去才发现读不出来，
                // 用户看到的会是「选完了还是糊」，比直接说一声难受得多。
                guard let data = try? await item.loadTransferable(type: Data.self),
                      UIImage(data: data) != nil else {
                    failed = true
                    pickedItem = nil
                    return
                }
                PatternSourceStore.save(data, for: projectId)
                guard PatternSourceStore.exists(for: projectId) else {
                    failed = true
                    pickedItem = nil
                    return
                }
                needsSource = false
                onLoaded()
            }
        }
    }
}
