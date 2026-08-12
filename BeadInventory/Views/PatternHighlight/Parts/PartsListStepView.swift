//
//  PartsListStepView.swift
//  BeadInventory
//
//  多零件模式 · 第二屏；屏序见 PartsSheetFlowView 头注释 - 零件清单
//
//  这一屏的验收标准只有两句话：
//
//    1. 一眼看得出**算法把哪块当成了一个零件** —— 图上有框有号，下面有对应缩略图；
//    2. 看出来不对时**当场能改回来**。
//
//  第 2 条要求这一屏必须覆盖算法出错的全部三种形态，缺一种用户就卡死：
//
//    多了（水印、文字被当成零件）  → 选中删除
//    粘了（两个零件一个框）        → 拆开；实在分不开就删掉重画
//    漏了（图上有块，压根没有框）  → **直接在它上面拖一个框**
//
//  第三种是最初漏掉的：删除 / 合并 / 拆开 / 改名全都要求先有一个框才能操作，
//  于是「图上明明有一块但没框住」时用户什么都做不了 —— 只能退出去重来，
//  而重来大概率还是漏同一块。所以「拖一下补一个」是这屏的地基，不是锦上添花。
//

import SwiftUI

struct PartsListStepView: View {
    let work: PartsWorkImage
    let roi: CGRect
    @Binding var parts: [BeadPart]
    let onContinue: () -> Void
    /// 这张图纸对应的项目。只用来找它的原图副本（「拼好了」要删的就是那个）。
    let projectId: UUID
    /// 用户在这一屏补了张原图。调用方据此重新裁一次工作图。
    let onSourceLoaded: () -> Void

    @State private var selection: Set<UUID> = []
    @State private var thumbnails: [UUID: UIImage] = [:]
    @State private var roiImage: UIImage?
    @State private var renamingPart: BeadPart?
    @State private var renameText: String = ""
    /// 最近一次是从图上点中的零件。用来驱动下面的缩略图滚过去；
    /// 单独一个 State 而不是复用 `selection`，是因为在缩略图里点选时不该再滚一次。
    @State private var lastTappedOnImage: UUID?
    @State private var splitting = false
    @State private var splitFailed = false
    /// 正在图上拖出来的那个新框（屏幕坐标）。松手即清空。
    @State private var draftRect: CGRect?
    /// 图上的缩放和平移。小零件在整张零件区里只有几个点大，不放大根本框不住；
    /// 放大之后不能平移又等于没放大。
    ///
    /// 缩放锚点固定在**中心**，「捏哪儿放大哪儿」靠同步改 `pan` 实现（见 magnify 手势）。
    /// 这么绕一下是为了让平移有确定的边界可以夹 —— 锚点跟着手指跑的话，
    /// 「图不能被拖出屏幕」这条约束就没有简单解。
    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var lastPan: CGSize = .zero
    /// 捏合开始时手指下面是内容的哪一点（内容坐标）+ 它当时在屏幕的哪儿。
    /// 用来在缩放过程中把这一点钉在原地。
    @State private var pinchContentAnchor: CGPoint?
    @State private var pinchScreenPoint: CGPoint = .zero

    /// 是不是正处于「补一个零件」的状态。
    ///
    /// **默认是关的，单指拖 = 移动图片。** 早先没有这个状态，单指拖一律新建框 ——
    /// 放大之后想挪一下看别处，手指一落就啪地多出一个零件框，而且根本挪不了。
    /// 新建框是低频动作，不该占着默认手势。
    @State private var addingPart = false
    @State private var showingFinishedConfirm = false
    /// 原图副本还在不在。拼好了删掉之后这一行就消失。
    @State private var sourceBytes = 0

    private let columns = [GridItem(.adaptive(minimum: 86), spacing: Theme.Spacing.md)]

    var body: some View {
        VStack(spacing: 0) {
            PatternSourceBanner(projectId: projectId) {
                sourceBytes = PatternSourceStore.byteSize(for: projectId)
                onSourceLoaded()
            }
            preview
            Divider()
            partGrid
            footer
        }
        .navigationTitle("零件清单")
        .navigationBarTitleDisplayMode(.inline)
        .alert("零件改名", isPresented: Binding(
            get: { renamingPart != nil },
            set: { if !$0 { renamingPart = nil } }
        )) {
            TextField("名字", text: $renameText)
            Button("取消", role: .cancel) { renamingPart = nil }
            Button("保存") { commitRename() }
        } message: {
            Text("留空就用默认的编号。")
        }
        .alert("这块分不开", isPresented: $splitFailed) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("在图上它是连成一整片的，找不到下刀的地方。如果确实是两个零件，可以先把它删掉，再在两块上各拖一个框出来。")
        }
        .task { sourceBytes = PatternSourceStore.byteSize(for: projectId) }
        .alert("这套拼好了？", isPresented: $showingFinishedConfirm) {
            Button("拼好了，删掉原图", role: .destructive) {
                PatternSourceStore.remove(for: projectId)
                sourceBytes = 0
            }
            Button("还没有", role: .cancel) {}
        } message: {
            Text("会删掉这张图纸的原图副本，腾出 \(byteText(sourceBytes))。\n零件、格子、色号这些都会留着，高亮照常能用；只是「核对颜色」里的小图会变糊一点。")
        }
        .task(id: partsSignature) {
            let snapshot = parts
            let source = work
            let region = roi
            let built = await Task.detached(priority: .userInitiated) {
                (thumbs: PartsThumbnailMaker.make(for: snapshot, from: source),
                 crop: PartsThumbnailMaker.crop(source, normalized: region))
            }.value
            thumbnails = built.thumbs
            roiImage = built.crop
        }
    }

    /// 缩略图只在「零件集合真的变了」时重建 —— 选中态变化不该触发一次全量裁图。
    /// 工作图本身也算：用户中途补了张原图，图换成高清的了，小图得跟着重裁，
    /// 否则他选完原图看到的还是原来那些糊图，只会以为没生效。
    private var partsSignature: String {
        "\(work.image.size)" + parts.map { "\($0.id.uuidString)\($0.bounds)" }.joined()
    }

    // MARK: - 上半：图上的框

    private var preview: some View {
        GeometryReader { geo in
            let display = PartsRegionStepView.aspectFitRect(
                imageSize: roiImage?.size ?? CGSize(width: 1, height: 1),
                in: geo.size
            )
            let transform = PartsCanvasTransform(region: roi, display: display,
                                                 size: geo.size, zoom: zoom, pan: pan)
            ZStack(alignment: .topLeading) {
                if let roiImage {
                    // 按放大后的**最终尺寸**摆图，不用 scaleEffect（同「量格子」那屏）。
                    // scaleEffect 是图层变换：图先按画布大小栅格化，再整层拉大 8 倍 ——
                    // 放大的是那张已经缩小过的栅格，用户特地留的原图一个像素都用不上。
                    let box = transform.screenRect(roi)
                    Image(uiImage: roiImage)
                        .resizable()
                        // 放大到超过原图分辨率时用最近邻，豆子边界是硬的；
                        // 缩小时用默认插值，否则 1 像素的格线会抖成摩尔纹。
                        .interpolation(box.width >= roiImage.size.width ? .none : .high)
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)
                }
                PartsBoxOverlay(parts: parts, selection: selection, transform: transform)

                if let draftRect {
                    Rectangle()
                        .strokeBorder(Theme.ColorToken.Morandi.honey, lineWidth: 1.5)
                        .background(Rectangle().fill(Theme.ColorToken.Morandi.honey.opacity(0.2)))
                        .frame(width: draftRect.width, height: draftRect.height)
                        .position(x: draftRect.midX, y: draftRect.midY)
                        .allowsHitTesting(false)
                }

                gestureCatcher(in: geo.size, transform: transform)
            }
        }
        // 图纸是竖长的，240pt 高只剩不到 180pt 宽，五十几个框挤成一团看不清谁是谁。
        // 340pt 是「图上看得清 + 下面还能露出两行缩略图」的折中。
        .frame(height: 340)
        .background(Theme.ColorToken.Surface.subtle)
        // 处于补零件状态时给画布描一圈 —— 让「现在单指拖会画框」这件事看得见
        .overlay(
            Rectangle()
                .stroke(Theme.ColorToken.Morandi.honey, lineWidth: addingPart ? 3 : 0)
                .allowsHitTesting(false)
        )
        // 必须裁：`scaleEffect` 只是画得更大，不会自己留在框里 ——
        // 少了这一行，放大后的图会盖到导航栏和下面的缩略图上。
        .clipped()
    }

    /// 手势层。触点永远是**真实屏幕点**，靠 `transform` 换成图纸上的归一化坐标。
    ///
    /// 一开始是把手势挂在 `.scaleEffect` 之后的视图上，指望 SwiftUI 把触点映射回
    /// 内容坐标系 —— 实测不是：放大到 4 倍再拖框，框会落到别的零件上。
    /// 现在整层都不用 scaleEffect 了，画和摸在同一套坐标里，不需要再猜。
    private func gestureCatcher(in size: CGSize, transform: PartsCanvasTransform) -> some View {
        // 点选、单指拖、捏合必须并进同一个 SimultaneousGesture：分开挂的话
        // DragGesture 会把 tap 整个吃掉，点零件变成没反应。
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                SimultaneousGesture(
                    SimultaneousGesture(
                        SpatialTapGesture()
                            .onEnded { value in
                                // 补零件时不响应点选：一次拖动结束时点选手势也会跟着触发，
                                // 于是画完一个框会连带选中旁边一个（实测「已选 2 个」）。
                                guard !addingPart else { return }
                                toggleHit(atNormalized: transform.normalized(value.location))
                            },
                        DragGesture(minimumDistance: addingPart ? 12 : 4)
                            .onChanged { value in
                                if addingPart {
                                    draftRect = CGRect(corner: value.startLocation, to: value.location)
                                } else {
                                    pan = clampPan(CGSize(
                                        width: lastPan.width + value.translation.width,
                                        height: lastPan.height + value.translation.height
                                    ), in: size)
                                }
                            }
                            .onEnded { value in
                                guard addingPart else {
                                    lastPan = pan
                                    return
                                }
                                draftRect = nil
                                // 「够不够大」按**手指在屏幕上划了多远**算：那个门槛是拿来挡
                                // 误触的。不要求两个方向都够远 —— 只有一颗豆高的扁长零件
                                // （一条边框、一行字）是真实存在的形状，拿「宽和高都得 ≥10」
                                // 去卡，这种框会连个提示都没有地被丢掉。
                                let movedFar = hypot(value.translation.width,
                                                     value.translation.height) >= 10
                                guard movedFar else { return }
                                addPart(from: transform.normalized(value.startLocation),
                                        to: transform.normalized(value.location))
                            }
                    ),
                    MagnifyGesture()
                        .onChanged { value in
                            if pinchContentAnchor == nil {
                                pinchScreenPoint = value.startLocation
                                pinchContentAnchor = unzoomed(value.startLocation, in: size)
                            }
                            guard let anchor = pinchContentAnchor else { return }
                            zoom = max(1, min(8, lastZoom * value.magnification))
                            // 把捏合开始时手指下的那一点钉回原处
                            let center = CGPoint(x: size.width / 2, y: size.height / 2)
                            pan = clampPan(CGSize(
                                width: pinchScreenPoint.x - center.x - (anchor.x - center.x) * zoom,
                                height: pinchScreenPoint.y - center.y - (anchor.y - center.y) * zoom
                            ), in: size)
                        }
                        .onEnded { _ in
                            lastZoom = zoom
                            lastPan = pan
                            pinchContentAnchor = nil
                        }
                )
            )
    }

    /// 屏幕点 → 缩放前的画布点。只给捏合用：捏合要把手指底下那一点钉在原地，
    /// 得先知道它在「没缩放的画布」上是哪儿。
    private func unzoomed(_ point: CGPoint, in size: CGSize) -> CGPoint {
        guard zoom > 0 else { return point }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        return CGPoint(x: center.x + (point.x - pan.width - center.x) / zoom,
                       y: center.y + (point.y - pan.height - center.y) / zoom)
    }

    /// 夹住平移，别让图被拖出容器（放大 z 倍后，最多能挪出去半个「多出来的部分」）。
    private func clampPan(_ offset: CGSize, in size: CGSize) -> CGSize {
        let limitX = max(0, (zoom - 1) * size.width / 2)
        let limitY = max(0, (zoom - 1) * size.height / 2)
        return CGSize(width: min(max(offset.width, -limitX), limitX),
                      height: min(max(offset.height, -limitY), limitY))
    }

    /// - Parameter n: 点在整张图纸上的归一化坐标（零件的 bounds 也是这套坐标）
    private func toggleHit(atNormalized n: CGPoint) {
        // 命中多个（框互相重叠）时取面积最小的那个 —— 用户点的多半是压在上面的小零件。
        let hits = parts.filter { $0.bounds.contains(n) }
        guard let hit = hits.min(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
        else { return }
        toggle(hit.id)
        lastTappedOnImage = selection.contains(hit.id) ? hit.id : nil
    }

    // MARK: - 下半：缩略图清单

    private var partGrid: some View {
        ScrollViewReader { proxy in
            partGridContent
                // 在图上点了一个框，下面的缩略图要自己滚过来 —— 否则「我点的是哪个」
                // 还是得用户自己在五十几个格子里找。
                .onChange(of: lastTappedOnImage) { _, id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
        }
    }

    private var partGridContent: some View {
        ScrollView {
            if parts.isEmpty {
                ContentUnavailableView(
                    "一个零件也没找到",
                    systemImage: "square.dashed",
                    description: Text("多半是上一步的框没圈到零件。回上一步把框挪一下再试；或者直接在图上拖出零件的位置，自己补一个。")
                )
                .padding(.top, Theme.Spacing.xxl)
            } else {
                LazyVGrid(columns: columns, spacing: Theme.Spacing.md) {
                    ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                        PartThumbnailCell(
                            title: part.displayName(order: index),
                            order: index + 1,
                            image: thumbnails[part.id],
                            isSelected: selection.contains(part.id)
                        )
                        .id(part.id)
                        .onTapGesture { toggle(part.id) }
                    }
                }
                .padding(Theme.Spacing.lg)
            }
        }
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(spacing: Theme.Spacing.md) {
            if addingPart {
                Text("在漏掉的那块上拖一个框出来。画完这一个就退出来，方便你挪动图片再补下一个。")
                    .font(.footnote)
                    .foregroundStyle(Theme.ColorToken.Morandi.honey)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else if selection.isEmpty {
                Text("找到 \(parts.count) 个零件。点一下选中它，然后可以删除、合并、拆开或改名。\n两指捏合放大，单指拖动移动图片。")
                    .font(.footnote)
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // 四个操作 + 计数挤一行会换行成两层（实测在默认字号下就会），
                // 所以计数单独一行，按钮那行只放动词。
                HStack {
                    Text("已选 \(selection.count) 个")
                        .font(.footnote)
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                    Spacer()
                    Button("取消选择") { selection.removeAll() }
                        .font(.footnote)
                }

                HStack(spacing: Theme.Spacing.sm) {
                    Button(role: .destructive) { deleteSelected() } label: {
                        Label("删除", systemImage: "trash").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button { mergeSelected() } label: {
                        Label("合并", systemImage: "square.on.square").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(selection.count < 2)

                    Button { splitSelected() } label: {
                        Label("拆开", systemImage: "square.split.2x1").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(selection.count != 1 || splitting)

                    Button { beginRename() } label: {
                        Label("改名", systemImage: "pencil").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(selection.count != 1)
                }
                .font(.footnote)
                .lineLimit(1)
            }

            // **这个按钮任何时候都在。** 以前它藏在「没选中任何零件」那一支里：
            // 补完一个零件之后它是选中状态，按钮就消失了，用户必须先点「取消选择」
            // 才能再补下一个 —— 而他压根不知道自己进了选中态，只看到按钮没了。
            Button {
                addingPart.toggle()
                if addingPart { selection.removeAll() }
            } label: {
                Label(addingPart ? "先不补了" : "有零件没框住？补一个",
                      systemImage: addingPart ? "xmark" : "plus.viewfinder")
                    .font(.footnote.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(addingPart ? Theme.ColorToken.Morandi.honey : nil)

            if sourceBytes > 0 {
                HStack {
                    Text("这张图纸留了一份原图，占 \(byteText(sourceBytes))")
                        .font(.caption2)
                        .foregroundStyle(Theme.ColorToken.Text.tertiary)
                    Spacer()
                    Button("拼好了") { showingFinishedConfirm = true }
                        .font(.caption2)
                }
            }

            Button(action: onContinue) {
                Label("下一步：量格子", systemImage: "grid")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(parts.isEmpty)
        }
        .padding()
        .background(.regularMaterial)
    }

    private func byteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: - 编辑

    private func toggle(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func deleteSelected() {
        parts.removeAll { selection.contains($0.id) }
        selection.removeAll()
    }

    /// 合并 = 取所有选中框的外接矩形，其余属性沿用最靠前的那个。
    /// 用于算法把一个零件切成了两半（描边断了、或者中间镂空太大）的情况。
    private func mergeSelected() {
        let chosen = parts.filter { selection.contains($0.id) }
        guard chosen.count >= 2 else { return }
        let union = chosen.dropFirst().reduce(chosen[0].bounds) { $0.union($1.bounds) }
        var merged = chosen[0]
        merged.bounds = union
        merged.rowBand = chosen.map(\.rowBand).min() ?? merged.rowBand
        // 合并后网格信息全部作废（框变了，行列数和格子内容都得重算）
        merged.gridRect = nil
        merged.rows = 0
        merged.cols = 0
        merged.cells = []

        var remaining = parts.filter { !selection.contains($0.id) }
        remaining.append(merged)
        parts = remaining.sorted {
            $0.rowBand != $1.rowBand ? $0.rowBand < $1.rowBand : $0.bounds.minX < $1.bounds.minX
        }
        selection = [merged.id]
    }

    /// 在图上拖一个框 = 补一个算法漏掉的零件。
    ///
    /// 用户拖个大概就行：先按拖出来的框立刻插进清单（马上看得见，不用等），
    /// 再在后台于这个框里跑一次连通域，把框收缩到那块零件的实际边界。
    /// 框里什么都没有（拖到空白处）就保持原样，不弹错——用户自己看得见框住了什么。
    /// 两个角点（整张图纸的归一化坐标）→ 一个新零件。夹在零件区里：
    /// 框外面本来就不该有零件，手指滑出去也不算数。
    private func addPart(from a: CGPoint, to b: CGPoint) {
        let inImage = CGRect(corner: a, to: b).intersection(roi)
        // 这里只挡退化矩形；「是不是误触」由调用方按屏幕位移判断。
        guard inImage.width > 0, inImage.height > 0 else { return }

        let newPart = BeadPart(rowBand: rowBand(forMidY: inImage.midY), bounds: inImage)
        insertSorted(newPart)
        // 只留刚画的这一个高亮：图上五十几个框，用橙色标出「这个是我刚补的」才有意义，
        // 一路累加下去到第三个就分不清哪个是新的了。
        selection = [newPart.id]
        lastTappedOnImage = newPart.id
        // **画完一个就退出补零件状态。**
        //
        // 上一版是「画完不退出，接着画下一个」——那是在电脑上想出来的。真在手机上补零件，
        // 得先放大才框得住小零件，而放大之后下一个零件多半不在屏幕里，非得先挪图不可；
        // 可补零件状态下单指拖是画框，图根本挪不动。于是「不退出」反而把人锁死在原地。
        // 现在画完立刻交还单指（=挪图），要补下一个再点一次按钮，多一次点击换回自由移动。
        addingPart = false

        // 后台收缩到实际边界
        let id = newPart.id
        Task.detached(priority: .userInitiated) {
            var options = PartsDetectionOptions()
            options.minAreaRatio = 0.01        // 相对这个小框
            options.maxWorkingPixels = 250_000
            let found = PartsDetector.detect(in: work, roi: inImage, options: options)
            guard let biggest = found.max(by: {
                $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height
            }) else { return }
            await MainActor.run {
                guard let index = parts.firstIndex(where: { $0.id == id }) else { return }
                parts[index].bounds = biggest.bounds
            }
        }
    }

    /// 新零件归到哪一行：取竖直方向上离它最近的那个已有零件的行号。
    /// 补进来的零件多半就在某一行里漏掉的那个位置，跟着邻居走比重新聚类稳。
    private func rowBand(forMidY midY: CGFloat) -> Int {
        guard let nearest = parts.min(by: {
            abs($0.bounds.midY - midY) < abs($1.bounds.midY - midY)
        }) else { return 0 }
        return nearest.rowBand
    }

    private func insertSorted(_ part: BeadPart) {
        var next = parts
        next.append(part)
        parts = next.sorted {
            $0.rowBand != $1.rowBand ? $0.rowBand < $1.rowBand : $0.bounds.minX < $1.bounds.minX
        }
    }

    /// 拆开 = 只在这一个框里重跑一次检测，并且**关掉闭运算** ——
    /// 把两块粘成一块的正是那一步（它为了补描边上的缺口，会顺手桥接靠得很近的两个零件）。
    ///
    /// 框要先往外放一圈再检测：背景色是靠「区域四周一圈的众数」估的，
    /// 贴着零件边缘去取，取到的全是描边的黑色，整块就会被判成背景。
    private func splitSelected() {
        guard selection.count == 1, let id = selection.first,
              let target = parts.first(where: { $0.id == id }) else { return }
        let padded = target.bounds
            .insetBy(dx: -target.bounds.width * 0.12, dy: -target.bounds.height * 0.12)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        var options = PartsDetectionOptions()
        options.closingRadius = 0
        options.minAreaRatio = 0.015          // 相对这个小框，不是整张图
        options.maxWorkingPixels = 250_000
        splitting = true

        Task.detached(priority: .userInitiated) {
            let sub = PartsDetector.detect(in: work, roi: padded, options: options)
            // 放大过的框会把邻居蹭进来，只保留主体落在原框里的
            let mine = sub.filter { candidate in
                let overlap = candidate.bounds.intersection(target.bounds)
                guard !overlap.isNull else { return false }
                let overlapArea = overlap.width * overlap.height
                let own = candidate.bounds.width * candidate.bounds.height
                return own > 0 && overlapArea > own * 0.5
            }
            await MainActor.run {
                splitting = false
                guard mine.count >= 2 else {
                    splitFailed = true
                    return
                }
                // 检测跑在后台，这期间用户照样能删零件、合并、点别的框，
                // 下标早就不是当初那个了 —— 必须按 id 重新定位（同 addPart）。
                guard let index = parts.firstIndex(where: { $0.id == id }) else { return }
                let replacements = mine.map {
                    BeadPart(rowBand: target.rowBand, bounds: $0.bounds)
                }
                var next = parts
                next.remove(at: index)
                next.append(contentsOf: replacements)
                parts = next.sorted {
                    $0.rowBand != $1.rowBand ? $0.rowBand < $1.rowBand : $0.bounds.minX < $1.bounds.minX
                }
                selection = Set(replacements.map(\.id))
            }
        }
    }

    private func beginRename() {
        guard let id = selection.first, let part = parts.first(where: { $0.id == id }) else { return }
        renameText = part.customName ?? ""
        renamingPart = part
    }

    private func commitRename() {
        guard let target = renamingPart, let index = parts.firstIndex(where: { $0.id == target.id }) else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        parts[index].customName = trimmed.isEmpty ? nil : trimmed
        renamingPart = nil
    }
}

// MARK: - 图上的框

private struct PartsBoxOverlay: View {
    let parts: [BeadPart]
    let selection: Set<UUID>
    /// 归一化坐标 → 真实屏幕点。整层不再走 scaleEffect，所以线宽、字号都是
    /// **屏幕上的实际大小**，不用再除以缩放。
    let transform: PartsCanvasTransform

    var body: some View {
        Canvas { context, _ in
            for (index, part) in parts.enumerated() {
                let r = transform.screenRect(part.bounds)
                // 选中的框换个颜色，不是加粗。图纸底色是浅粉、豆子里又有大片白，
                // 原先「选中 = 白框 + 白色蒙版」在上面几乎看不出来 ——
                // 用户补完一个零件，界面上没有任何地方告诉他「刚画的是这个、它选中了」。
                // 橙色和这张图上的任何颜色都不撞，一眼就能找到。
                let selected = selection.contains(part.id)
                let stroke: Color = selected ? .orange : .cyan
                if selected {
                    context.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(.orange.opacity(0.3)))
                }
                context.stroke(Path(roundedRect: r, cornerRadius: 2),
                               with: .color(stroke),
                               lineWidth: selected ? 2.5 : 1)

                // 序号贴在框的左上角外侧；框太靠上时贴内侧，免得跑出画面。
                //
                // 小框不画号：一张图上五十几个零件，全画出来数字会叠成一团反而谁都看不清。
                // 小零件靠「点一下高亮」认领 —— 点图上的框或点下面的缩略图，两边同时高亮。
                let bigEnough = min(r.width, r.height) >= 16
                guard bigEnough || selected else { continue }
                let badge = Text("\(index + 1)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.black)
                let badgeY = r.minY > 8 ? r.minY - 5 : r.minY + 5
                context.fill(
                    Path(ellipseIn: CGRect(x: r.minX - 6, y: badgeY - 6, width: 13, height: 13)),
                    with: .color(selected ? .orange : .cyan)
                )
                context.draw(badge, at: CGPoint(x: r.minX + 0.5, y: badgeY))
            }
        }
    }
}

// MARK: - 缩略图格

private struct PartThumbnailCell: View {
    let title: String
    let order: Int
    let image: UIImage?
    let isSelected: Bool

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .fill(Theme.ColorToken.Surface.elevated)
                    .frame(height: 78)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 70)
                        .frame(maxWidth: .infinity)
                }
                Text("\(order)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.ColorToken.Text.onAccent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.ColorToken.Morandi.mauve))
                    .padding(4)
            }
            .overlay(
                // 跟图上的框用同一个橙色：上下两处同时亮起来，才看得出「图上那个 = 这个」
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .stroke(isSelected ? Color.orange : Theme.ColorToken.Border.default,
                            lineWidth: isSelected ? 2.5 : 1)
            )

            Text(title)
                .font(.caption2)
                .foregroundStyle(Theme.ColorToken.Text.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

extension CGRect {
    /// 由拖动的起点和当前点构造矩形（两点顺序任意）
    init(corner a: CGPoint, to b: CGPoint) {
        self.init(x: Swift.min(a.x, b.x), y: Swift.min(a.y, b.y),
                  width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}

// MARK: - 裁图

enum PartsThumbnailMaker {
    /// 按零件 bbox 从整图上裁小图。四周留 6% 余量，免得描边紧贴缩略图边缘看不清。
    static func make(for parts: [BeadPart], from work: PartsWorkImage) -> [UUID: UIImage] {
        var result: [UUID: UIImage] = [:]
        for part in parts {
            let padded = part.bounds.insetBy(dx: -part.bounds.width * 0.06,
                                             dy: -part.bounds.height * 0.06)
            if let cropped = crop(work, normalized: padded) {
                result[part.id] = cropped
            }
        }
        return result
    }

    /// `rect` 是**相对整张图纸**的归一化矩形，由工作图自己翻译到它手里那块图上。
    static func crop(_ work: PartsWorkImage, normalized rect: CGRect) -> UIImage? {
        guard let cg = work.image.cgImage else { return nil }
        return crop(cg, normalized: work.localRect(rect),
                    scale: work.image.scale, orientation: work.image.imageOrientation)
    }

    private static func crop(
        _ cg: CGImage,
        normalized rect: CGRect,
        scale: CGFloat,
        orientation: UIImage.Orientation
    ) -> UIImage? {
        let pixels = CGRect(
            x: rect.minX * CGFloat(cg.width),
            y: rect.minY * CGFloat(cg.height),
            width: rect.width * CGFloat(cg.width),
            height: rect.height * CGFloat(cg.height)
        ).intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height)).integral
        guard pixels.width >= 1, pixels.height >= 1,
              let cropped = cg.cropping(to: pixels) else { return nil }
        return UIImage(cgImage: cropped, scale: scale, orientation: orientation)
    }
}
