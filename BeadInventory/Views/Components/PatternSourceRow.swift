//
//  PatternSourceRow.swift
//  BeadInventory
//
//  项目详情页里「图纸原图」那一行。
//
//  一个项目手上有**两张各自独立的图**，以前只有一张露过面：
//
//  - **封面**：列表里那张缩略图。压过的（预算见 `ProjectImageEncoder`），只管好看。
//  - **图纸原图**：拼图模式逐格对色号时读的那份（`PatternSourceStore`）。全分辨率、
//    存在本机、不进 iCloud 也不进备份。
//
//  在这一行出现之前，图纸原图是个隐身的东西：界面上没有名字、看不到是哪一张、
//  也没有单独换掉它的入口，用户能摸到的只有封面。于是所有人都以为封面就是那张图 ——
//  用户报的那个障（「改完封面进拼图模式，图纸变成了封面」）根子就在这儿。
//
//  所以这一行不是新概念，是把本来就存在的那一份摆到台面上：它是哪张、占多少、
//  怎么换、怎么删，四件事一眼看全。改封面从此一个字节都不碰它（见
//  `ProjectImageEditorSheet`）。
//

import SwiftUI
import PhotosUI

struct PatternSourceRow: View {
    let projectId: UUID

    @State private var exists = false
    @State private var byteCount = 0
    /// 预览图。图纸动辄几十 MB，这里只解一张小的出来 —— 用户要的只是
    /// 「一眼看出它跟封面是不是同一张」。
    @State private var preview: UIImage?
    @State private var pickedItem: PhotosPickerItem?
    @State private var loading = false
    @State private var failed = false
    @State private var confirmingRemove = false

    private static let previewMaxPixel = 240

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text("图纸原图")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()

                if loading {
                    ProgressView()
                } else {
                    // `.current`：这一整条路要的就是没被动过的原始字节，默认的
                    // `.automatic` 会把 HEIC 转码成 JPEG，等于白换一次。
                    PhotosPicker(selection: $pickedItem, matching: .images,
                                 preferredItemEncoding: .current) {
                        Label(exists ? "换一张" : "选一张", systemImage: "photo.badge.plus")
                            .font(.caption)
                            .foregroundColor(Theme.ColorToken.Morandi.mauve)
                    }

                    if exists {
                        Button {
                            confirmingRemove = true
                        } label: {
                            Label("删掉", systemImage: "trash")
                                .font(.caption)
                                .foregroundColor(Theme.ColorToken.Status.error)
                        }
                        .padding(.leading, Theme.Spacing.sm)
                    }
                }
            }

            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                thumbnail

                VStack(alignment: .leading, spacing: 4) {
                    if failed {
                        Text("这张图读不出来，换一张试试。")
                            .font(.caption)
                            .foregroundColor(Theme.ColorToken.Status.error)
                    } else if exists {
                        Text("拼图模式用的是这张")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)) · 存在本机，不占用 iCloud")
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.7))
                    } else {
                        Text("没有图纸原图")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("拼图模式会拿封面凑合，一格豆子的像素少一半。相册里还留着原图就选一下。")
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }
        }
        .padding()
        .background(Theme.ColorToken.Surface.elevated)
        .cornerRadius(Theme.Radius.md)
        .task { await reload() }
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            replaceSource(with: item)
        }
        // 删掉之后拼图模式还能用（退回封面），但这份原图找不回来了 —— 值得问一句。
        // 用 alert 不用 confirmationDialog：后者在这一屏被系统渲染成气泡，
        // 「取消」会被吞掉，一个破坏性操作只剩一个按钮。
        .alert("删掉这张图纸原图？", isPresented: $confirmingRemove) {
            Button("删掉", role: .destructive) {
                PatternSourceStore.remove(for: projectId)
                Task { await reload() }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("拼图模式仍然能用，但只能拿封面凑合，看格子会糊一些。它不进 iCloud、也不在备份里，删了要重新从相册选。")
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let preview {
            Image(uiImage: preview)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
                )
        } else {
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(Theme.ColorToken.Surface.subtle)
                .frame(width: 56, height: 56)
                .overlay(
                    Image(systemName: exists ? "photo" : "photo.badge.exclamationmark")
                        .foregroundColor(.secondary)
                )
        }
    }

    /// 读一遍当前状态和预览图。**解码放后台** —— 图纸是全分辨率的，
    /// 在主线程上解一张 6000 万像素的图就是一次可见的卡顿。
    private func reload() async {
        let id = projectId
        let (has, bytes) = await Task.detached(priority: .userInitiated) {
            (PatternSourceStore.exists(for: id), PatternSourceStore.byteSize(for: id))
        }.value
        exists = has
        byteCount = bytes
        guard has else {
            preview = nil
            return
        }
        preview = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let data = PatternSourceStore.data(for: id) else { return nil }
            return ImageDownsampler.downsampleToUIImage(data, maxPixelSize: Self.previewMaxPixel)
        }.value
    }

    private func replaceSource(with item: PhotosPickerItem) {
        loading = true
        failed = false
        Task {
            defer {
                loading = false
                pickedItem = nil
            }
            // 解一遍只是确认这确实是张能用的图 —— 存进去才发现读不出来，
            // 用户看到的会是「换完了拼图模式还是糊」，比直接说一声难受得多。
            guard let data = try? await item.loadTransferable(type: Data.self),
                  UIImage(data: data) != nil,
                  PatternSourceStore.save(data, for: projectId) else {
                failed = true
                return
            }
            await reload()
        }
    }
}
