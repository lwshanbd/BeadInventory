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
//  **这一行才是真正决定拼图模式读哪张图的地方**，所以封面编辑器为「改这张图会让
//  对好的格子作废」准备的那道确认，这里一条都不能少 —— 补、换、删三个动作都会让
//  已经对好的作废（判据见 `InventoryManager.hasStoredPatternWork(for:)`）。
//

import SwiftUI
import PhotosUI

struct PatternSourceRow: View {
    let projectId: UUID

    /// 这个项目还用得上图纸吗 —— 也就是它进不进得去拼图模式。
    ///
    /// 已执行的项目进不去（两个详情页的入口都是 `if isPlanned`），所以不劝他补一张：
    /// 没有图纸时这一行整个不出现，已经留着的那份仍然看得见、能删掉腾空间。
    var allowsPicking = true

    /// 外面动过这份文件之后，把这个值 +1 就能让这一行重读。
    ///
    /// 必须有：拼图模式是 `fullScreenCover`，关掉它详情页不会重建，`.task` 也就不会
    /// 重跑。而那里面有两条路会改这份文件 —— 零件清单页的「拼好了，删掉原图」和缺图
    /// 提示条的「选原图」。不重读的话，用户回到详情页看到的是一份已经不存在的文件。
    var refreshToken = 0

    @EnvironmentObject private var inventoryManager: InventoryManager

    /// 磁盘上那份图纸原图。nil = 没有。
    ///
    /// 用一个 optional 取代原来的 `exists` + `byteCount` 两个 `@State` —— 那两个能互相
    /// 矛盾（`exists == true` 而 `byteCount == 0`，界面上就是「零字节 · 存在本机」）。
    @State private var stored: Stored?
    @State private var pickedItem: PhotosPickerItem?
    @State private var loading = false
    @State private var pickFailure: PickFailure?
    @State private var confirmingRemove = false
    /// 选好了、但还没写进去的那一张。等用户在确认弹窗上点头才落盘。
    @State private var pendingPick: PhotosPickerItem?

    struct Stored {
        let bytes: Int
        /// 240px 预览。**nil 说明这份文件读不出来**（截断、IO 错误、锁屏下的文件保护）。
        /// 这不是显示问题：拼图模式读的是同一个 `PatternSourceStore.data(for:)`，
        /// 它进去也会静默退回封面。所以这一格灰方块是「你接下来会看到糊图」的唯一预兆，
        /// 界面必须照实说，不能继续写「拼图模式用的是这张」。
        var preview: UIImage?
    }

    enum PickFailure {
        /// 这张图取不出来或打不开（还在 iCloud 没下完、RAW、解码失败）。
        case unreadable
        /// 写不进去（多半是空间不够）。**跟用户挑的那张图没关系**，
        /// 混成同一句「换一张试试」，磁盘满的用户会把整个相册试一遍。
        case saveFailed
        /// 删不掉。
        case removeFailed
    }

    private static let previewMaxPixel = 240

    /// 有对好的格子 / 零件摆位。补、换、删都会让它作废，所以三个动作都得先问一句。
    private var hasPatternWork: Bool {
        inventoryManager.hasStoredPatternWork(for: projectId)
    }

    private var isVisible: Bool {
        stored != nil || allowsPicking
    }

    var body: some View {
        Group {
            if isVisible {
                card
            } else {
                // 零高度的实体节点。`if` 不成立时 Group 里什么都没有，下面那个 `.task`
                // 就永远不会跑 —— 也就永远判断不出这一行到底该不该出现。
                Color.clear.frame(height: 0)
            }
        }
        .task(id: refreshToken) { await reload() }
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            pickedItem = nil
            // 已经有一份、或者已经对好了格子 —— 两种情况都不能说换就换。
            if stored != nil || hasPatternWork {
                pendingPick = item
            } else {
                save(item)
            }
        }
        // 换掉 = 覆盖一份找不回来的文件；补上/换掉同样会让已经对好的格子作废。
        // 用 alert 不用 confirmationDialog：后者在这一屏被系统渲染成气泡，
        // 「取消」会被吞掉，一个破坏性操作只剩一个按钮。
        .alert(stored == nil ? "换成这张图纸？" : "换掉这张图纸原图？",
               isPresented: Binding(get: { pendingPick != nil },
                                    set: { if !$0 { pendingPick = nil } })) {
            Button("换掉", role: .destructive) {
                if let item = pendingPick { save(item) }
                pendingPick = nil
            }
            Button("取消", role: .cancel) { pendingPick = nil }
        } message: {
            Text(replaceMessage)
        }
        .alert("删掉这张图纸原图？", isPresented: $confirmingRemove) {
            Button("删掉", role: .destructive) { remove() }
            Button("取消", role: .cancel) { }
        } message: {
            Text(removeMessage)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text("图纸原图")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()

                if loading {
                    ProgressView()
                } else {
                    if allowsPicking {
                        // `.current`：这一整条路要的就是没被动过的原始字节，默认的
                        // `.automatic` 可能把 HEIC 转码成 JPEG，那就等于白换一次。
                        PhotosPicker(selection: $pickedItem, matching: .images,
                                     preferredItemEncoding: .current) {
                            Label(stored == nil ? "选一张" : "换一张", systemImage: "photo.badge.plus")
                                .font(.caption)
                                .foregroundColor(Theme.ColorToken.Morandi.mauve)
                        }
                    }

                    if stored != nil {
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
                    status

                    // 挑图失败只说这一次的事，不去动上面那两行 —— 上面描述的是**库里那份**，
                    // 它好好的。混在一起说，用户读出来的是「我的图纸坏了」。
                    if let pickFailure {
                        Text(failureText(pickFailure))
                            .font(.caption2)
                            .foregroundColor(Theme.ColorToken.Status.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }
        }
        .padding()
        .background(Theme.ColorToken.Surface.elevated)
        .cornerRadius(Theme.Radius.md)
    }

    @ViewBuilder
    private var status: some View {
        if let stored {
            if stored.preview == nil {
                Text("这份图纸读不出来了")
                    .font(.caption)
                    .foregroundColor(Theme.ColorToken.Status.error)
                Text("拼图模式会退回用封面。重新选一张就好。")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("拼图模式用的是这张")
                    .font(.caption)
                    .foregroundColor(.secondary)
                // 量不出大小时就不写 —— 「零字节」比不说更糟。
                if stored.bytes > 0 {
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(stored.bytes), countStyle: .file)) · 存在本机，不占用 iCloud")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.7))
                } else {
                    Text("存在本机，不占用 iCloud")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }
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

    @ViewBuilder
    private var thumbnail: some View {
        if let preview = stored?.preview {
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
                    // 惊叹号留给「有文件但读不出来」——「没有图纸」是完全正常的状态，
                    // 不该长得像出了错。
                    Image(systemName: stored == nil ? "photo" : "photo.badge.exclamationmark")
                        .foregroundColor(.secondary)
                )
        }
    }

    private func failureText(_ failure: PickFailure) -> String {
        switch failure {
        case .unreadable: return "这张图取不出来。如果它还在 iCloud 里，等下载完再试。"
        case .saveFailed: return "没存进去，可能是手机空间不够。原来那张还在。"
        case .removeFailed: return "没删掉，稍后再试。"
        }
    }

    private var replaceMessage: String {
        let base = stored == nil
            ? "拼图模式以后就用这张来看每一格的颜色。"
            : "现在这张会被盖掉。它不进 iCloud、也不在备份里，换掉就找不回来了。"
        guard hasPatternWork else { return base }
        return base + "\n\n这个项目在拼图模式里已经对好了格子，换了图纸就对不上了，得重新对一遍。"
    }

    private var removeMessage: String {
        let base = "拼图模式仍然能用，但只能拿封面凑合，看格子会糊一些。它不进 iCloud、也不在备份里，删了要重新从相册选。"
        guard hasPatternWork else { return base }
        return base + "\n\n而且这个项目已经对好了格子 —— 退回用封面之后多半对不上，得重新对一遍。"
    }

    /// 读一遍当前状态和预览图。**解码放后台** —— 图纸是全分辨率的，
    /// 在主线程上解一张 6000 万像素的图就是一次可见的卡顿。
    private func reload() async {
        let id = projectId
        let bytes = await Task.detached(priority: .userInitiated) { () -> Int? in
            PatternSourceStore.exists(for: id) ? PatternSourceStore.byteSize(for: id) : nil
        }.value
        guard let bytes else {
            stored = nil
            return
        }
        let preview = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let data = PatternSourceStore.data(for: id) else { return nil }
            return ImageDownsampler.downsampleToUIImage(data, maxPixelSize: Self.previewMaxPixel)
        }.value
        if preview == nil {
            AppLogger.shared.error("PatternSource", "row_stored_source_unreadable", metadata: [
                "projectId": id.uuidString, "bytes": "\(bytes)"
            ])
        }
        stored = Stored(bytes: bytes, preview: preview)
    }

    private func save(_ item: PhotosPickerItem) {
        loading = true
        pickFailure = nil
        let id = projectId
        Task {
            defer { loading = false }
            // 取字节 + 解一遍验证 + 写盘**全部放后台**：图纸动辄几十 MB，
            // `Task {}` 本身继承 MainActor，不 detach 的话上面那个 ProgressView
            // 该转的时候正好是主线程卡住的时候。
            //
            // 解一遍是为了确认这确实是张能用的图 —— 存进去才发现读不出来，
            // 用户看到的会是「换完了拼图模式还是糊」，比直接说一声难受得多。
            let data = try? await item.loadTransferable(type: Data.self)
            guard let data else {
                AppLogger.shared.error("PatternSource", "row_load_transferable_failed", metadata: [
                    "projectId": id.uuidString
                ])
                pickFailure = .unreadable
                return
            }
            let saved = await Task.detached(priority: .userInitiated) { () -> Bool? in
                guard UIImage(data: data) != nil else { return nil }
                return PatternSourceStore.save(data, for: id)
            }.value
            switch saved {
            case nil:
                AppLogger.shared.error("PatternSource", "row_decode_failed", metadata: [
                    "projectId": id.uuidString, "bytes": "\(data.count)"
                ])
                pickFailure = .unreadable
            case false:
                // 写失败旧文件完好 —— `PatternSourceStore.save` 走的是 `.atomic`
                // （先写临时文件再 rename）。文案敢说「原来那张还在」全靠这一条，
                // 那边一旦改成非原子写，这里就是句谎话。
                AppLogger.shared.error("PatternSource", "row_save_failed", metadata: [
                    "projectId": id.uuidString, "bytes": "\(data.count)"
                ])
                pickFailure = .saveFailed
            default:
                await reload()
            }
        }
    }

    private func remove() {
        guard PatternSourceStore.remove(for: projectId) else {
            // 删失败还照原样显示的话，用户点完那个红色的「删掉」会看到东西原封不动
            // 回来了，再点还是一样 —— 加了确认的破坏性操作静默失败，比不加确认更糟。
            pickFailure = .removeFailed
            Task { await reload() }
            return
        }
        pickFailure = nil
        Task { await reload() }
    }
}
