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
//  第 2 条要求这一屏必须覆盖算法出错的全部四种形态，缺一种用户就卡死：
//
//    多了（水印、文字被当成零件）  → 选中删除
//    粘了（两个零件一个框）        → 拆开；实在分不开就删掉重画
//    漏了（图上有块，压根没有框）  → **点「补一个」，在它上面拖一个框**
//    歪了（框太大压到邻居 / 偏了）  → 选中后拖边上的把手改大小、拖框内挪位置
//
//  「漏了」是最初漏掉的：删除 / 合并 / 拆开 / 改名全都要求先有一个框才能操作，
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
    @State private var roiImageRegion: CGRect = .zero
    @State private var renamingPart: BeadPart?
    @State private var renameText: String = ""
    /// 最近一次是从图上点中的零件。用来驱动下面的缩略图滚过去；
    /// 单独一个 State 而不是复用 `selection`，是因为在缩略图里点选时不该再滚一次。
    @State private var lastTappedOnImage: UUID?
    @State private var splitting = false
    @State private var splitFailed = false
    /// 正在图上拖出来的那个新框（屏幕坐标）。松手即清空。
    @State private var draftRect: CGRect?
    /// 选中零件正在被拖的框（归一化）。拖动中只改它，松手才写进零件，理由见 `PartEditHandles`。
    @State private var boxPreview: CGRect?
    /// 松手后等用户确认的新框。零件已经对好网格或核对过颜色时才会有，见 `commitBounds`。
    @State private var pendingBounds: PendingBoundsChange?
    /// 图上的缩放和平移。小零件在整张零件区里只有几个点大，不放大根本框不住；
    /// 放大之后不能平移又等于没放大。
    ///
    /// 缩放锚点固定在**中心**，「捏哪儿放大哪儿」靠同步改 `pan` 实现（见 `pinchGesture`）。
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
        .alert("重命名零件", isPresented: Binding(
            get: { renamingPart != nil },
            set: { if !$0 { renamingPart = nil } }
        )) {
            TextField("名字", text: $renameText)
            Button("取消", role: .cancel) { renamingPart = nil }
            Button("保存") { commitRename() }
        } message: {
            Text("留空则使用默认编号。")
        }
        .alert("无法拆分此零件", isPresented: $splitFailed) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("该区域在图上连成一片，无法自动拆分。如果确实是两个零件，可先将其删除，再分别框选出两个区域。")
        }
        .alert("调整零件范围？", isPresented: Binding(
            get: { pendingBounds != nil },
            set: { if !$0 { pendingBounds = nil } }
        )) {
            Button("调整", role: .destructive) {
                if let change = pendingBounds { applyBounds(change.bounds, to: change.partId) }
                pendingBounds = nil
            }
            Button("取消", role: .cancel) { pendingBounds = nil }
        } message: {
            Text("此零件已对齐的网格和核对过的颜色将被清除。")
        }
        // 换了选中就丢掉上一个零件没提交的预览，免得套到新零件头上。
        .onChange(of: selection) { _, _ in boxPreview = nil }
        .task { sourceBytes = PatternSourceStore.byteSize(for: projectId) }
        .alert("确认已完成拼装？", isPresented: $showingFinishedConfirm) {
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
                 crop: PartsThumbnailMaker.cropExact(source, normalized: region))
            }.value
            thumbnails = built.thumbs
            roiImage = built.crop?.image
            roiImageRegion = built.crop?.rect ?? .zero
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
            let imageRegion = roiImageRegion.width > 0 && roiImageRegion.height > 0
                ? roiImageRegion : roi
            let display = PartsRegionStepView.aspectFitRect(
                imageSize: roiImage?.size ?? CGSize(width: 1, height: 1),
                in: geo.size
            )
            let transform = PartsCanvasTransform(region: imageRegion, display: display,
                                                 size: geo.size, zoom: zoom, pan: pan)
            ZStack(alignment: .topLeading) {
                if let roiImage {
                    // 按放大后的**最终尺寸**摆图，不用 scaleEffect（同「量格子」那屏）。
                    // scaleEffect 是图层变换：图先按画布大小栅格化，再整层拉大 8 倍 ——
                    // 放大的是那张已经缩小过的栅格，用户特地留的原图一个像素都用不上。
                    let box = transform.screenRect(imageRegion)
                    Image(uiImage: roiImage)
                        .resizable()
                        // 放大到超过原图分辨率时用最近邻，豆子边界是硬的；
                        // 缩小时用默认插值，否则 1 像素的格线会抖成摩尔纹。
                        .interpolation(box.width >= roiImage.size.width ? .none : .high)
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)
                }
                PartsBoxOverlay(parts: parts, selection: selection, transform: transform,
                                override: shownOverride)

                if let draftRect {
                    Rectangle()
                        .strokeBorder(Theme.ColorToken.Morandi.honey, lineWidth: 1.5)
                        .background(Rectangle().fill(Theme.ColorToken.Morandi.honey.opacity(0.2)))
                        .frame(width: draftRect.width, height: draftRect.height)
                        .position(x: draftRect.midX, y: draftRect.midY)
                        .allowsHitTesting(false)
                }

                gestureCatcher(in: geo.size, transform: transform)

                // 正好选中一个零件时，露出编辑把手：四条边中点各一个改大小，框内单指拖挪位置。
                // 压在手势层之上，所以拖把手不会连带平移画布。
                // 补零件时不出现：那会儿单指拖是画框，把手会抢走这个手势。
                if !addingPart, selection.count == 1,
                   let selected = parts.first(where: { selection.contains($0.id) }) {
                    PartEditHandles(
                        bounds: selected.bounds,
                        shownBounds: shownOverride?.bounds ?? selected.bounds,
                        roi: roi,
                        transform: transform,
                        isPinching: pinchContentAnchor != nil,
                        preview: $boxPreview,
                        onCommit: { commitBounds($0, to: selected.id) },
                        onTap: { point in
                            let n = transform.normalized(point)
                            // 落在这个框里就是取消选中它。不走 toggleHit：那边取的是
                            // 「面积最小」的命中框，框里套着更小的零件时（补框时框大了一圈、
                            // 或者合并出来的大框），点框身会把里面那个小的选进来变成「已选 2 个」，
                            // 跟用户点下去的意思正好相反。
                            if selected.bounds.contains(n) { toggle(selected.id) }
                            else { toggleHit(atNormalized: n) }
                        }
                    )
                    // 换一个零件就是一套新的拖动状态。系统中途打断手势时不会回调 onEnded，
                    // 没有这一行的话，残留的拖动状态会带到下一个选中的零件上。
                    .id(selected.id)
                }
            }
            // 捏合挂在**画布这一层**，不挂在手势层或把手层上：两根手指一根落在选中框里、
            // 一根落在框外时，分属两个兄弟视图，各挂各的就合不成一次捏合 ——
            // 实测是框被拖走、图没放大。挂在共同的父级上，两根手指落在哪儿都算。
            // ZStack 铺满画布，所以 `startLocation` 是画布坐标。
            .simultaneousGesture(pinchGesture(in: geo.size))
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
        // 必须裁：图是按放大后的**最终尺寸** `.frame` + `.position` 摆的，本来就会超出这
        // 340pt 的框 —— 少了这一行，放大后的图会盖到导航栏和下面的缩略图上。
        .clipped()
    }

    /// 手势层。触点永远是**真实屏幕点**，靠 `transform` 换成图纸上的归一化坐标。
    ///
    /// 一开始是把手势挂在 `.scaleEffect` 之后的视图上，指望 SwiftUI 把触点映射回
    /// 内容坐标系 —— 实测不是：放大到 4 倍再拖框，框会落到别的零件上。
    /// 现在整层都不用 scaleEffect 了，画和摸在同一套坐标里，不需要再猜。
    private func gestureCatcher(in size: CGSize, transform: PartsCanvasTransform) -> some View {
        // 点选和单指拖必须并进同一个 SimultaneousGesture：分开挂的话
        // DragGesture 会把 tap 整个吃掉，点零件变成没反应。捏合挂在外面画布那一层（见 `preview`）。
        Color.clear
            .contentShape(Rectangle())
            .gesture(
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
                )
            )
    }

    /// 两指捏合缩放。挂在画布那一层的 ZStack 上，理由见 `preview`。
    private func pinchGesture(in size: CGSize) -> some Gesture {
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
                    "未找到任何零件",
                    systemImage: "square.dashed",
                    description: Text("可能是上一步的框选范围未覆盖到零件。请返回上一步调整框选后重试，或点击下方「补一个」在图上手动框选。")
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
                Text("在遗漏的区域拖拽绘制一个框；完成后会自动退出，以便移动图片继续添加")
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
                        Label("拆分", systemImage: "square.split.2x1").frame(maxWidth: .infinity)
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
                Label(addingPart ? "暂不添加" : "有零件没框住？补一个",
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
        // 合并后网格信息全部作废（框变了，行列数和格子内容都得重算）。
        // **「已对齐」这个标记必须跟着一起清**：它是沿用 chosen[0] 来的，而合并出来的是
        // 一个全新的框，从来没人对过。留着的话「量格子」那屏会把它当成用户确认过的锁住，
        // 自动对齐一律绕开 —— 它就永远停在 0×0 格，而屏幕上还打着一个绿勾。
        merged.gridRect = nil
        merged.rows = 0
        merged.cols = 0
        merged.cells = []
        merged.gridConfirmed = nil
        // `isConnector` 刻意不清：它说的是「这块零件是干什么用的」，不是网格的一个状态
        // —— 两块插件合成一块还是插件。混着选的沿用第一块，用户在「量格子」那屏一眼
        // 就看得见，也改得掉。

        var remaining = parts.filter { !selection.contains($0.id) }
        remaining.append(merged)
        parts = remaining.sorted {
            $0.rowBand != $1.rowBand ? $0.rowBand < $1.rowBand : $0.bounds.minX < $1.bounds.minX
        }
        selection = [merged.id]
    }

    /// 在图上拖一个框 = 补一个算法漏掉的零件。
    ///
    /// **用户拖个大概就行：框先按拖出来的样子进清单，再在框里跑一次连通域收到零件边上。**
    /// 手指划出来的框总比零件大一圈，留着它，「量格子」那步这个零件就多出一圈空格子，
    /// 排到拼豆板上也白占地方。收完不对，选中拖把手改就是了（见 `PartEditHandles`）——
    /// 自动收紧和手动微调是接力，不是二选一。
    ///
    /// **框里什么都没找到就保持用户画的那个框**：算法认不出的零件正是用户要自己框的，
    /// 这时候不能因为「没找到」就把框改掉或者丢掉。
    ///
    /// 两个角点（整张图纸的归一化坐标）→ 一个新零件。夹在零件区里：
    /// 框外面本来就不该有零件，手指滑出去也不算数。
    private func addPart(from a: CGPoint, to b: CGPoint) {
        let inImage = CGRect(corner: a, to: b).intersection(roi)
        // 这里只挡退化矩形；「是不是误触」由调用方按屏幕位移判断。
        guard inImage.width > 0, inImage.height > 0 else { return }

        let newPart = BeadPart(rowBand: rowBand(forMidY: inImage.midY), bounds: inImage)
        insertSorted(newPart)
        // 画完**选中它**，边把手立刻出现。手指拖出来的框很少一次到位，
        // 下一步几乎总是微调这一个；早先画完不选中，是因为那时选中只能删除 / 合并，
        // 用不上还挡着看。现在要取消，点一下框内或底部的「取消选择」。
        selection = [newPart.id]
        lastTappedOnImage = newPart.id
        // **画完一个就退出补零件状态。**
        //
        // 上一版是「画完不退出，接着画下一个」——那是在电脑上想出来的。真在手机上补零件，
        // 得先放大才框得住小零件，而放大之后下一个零件多半不在屏幕里，非得先挪图不可；
        // 可补零件状态下单指拖是画框，图根本挪不动。于是「不退出」反而把人锁死在原地。
        // 现在画完立刻交还单指（=挪图），要补下一个再点一次按钮，多一次点击换回自由移动。
        addingPart = false

        // 后台把框收紧到零件的实际边界
        let id = newPart.id
        let drawn = inImage
        Task.detached(priority: .userInitiated) {
            var options = PartsDetectionOptions()
            options.minAreaRatio = 0.01        // 相对这个小框
            options.maxWorkingPixels = 250_000
            // 检测范围就是用户画的那个框，取里面**面积最大**的那块连通域 ——
            // 这段跟多零件模式一路用下来的版本一字不差，用户反馈就是好用。
            //
            // 中间试过「往外放一圈再检测 + 取所有块的并集」，想挡住两种理论上的翻车
            // （框贴得太紧时零件被当成图纸边框滤掉、零件描边断了被切成两块只收到一半）。
            // 实测是把好用的功能改坏了：并集会把框里的碎块全包进去，收出来跟用户画的
            // 差不多大，用户的感受是「几乎不识别了」。那两种情况本来就少见，真碰上了
            // 拖把手改一下就是了 —— 宁可偶尔收歪，也不要每次都收不动。
            let found = PartsDetector.detect(in: work, roi: drawn, options: options)
            guard let biggest = found.max(by: {
                $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height
            }) else { return }
            await MainActor.run {
                // 检测跑在后台，这期间用户照样能删零件、拖把手改这个框，甚至已经翻到下一屏
                // 把格子量好了。所以三道门：按 id 重新定位（下标早就不是当初那个）；
                // 框已经不是画出来的那个就不动它（用户抢先改过的比这个结果新）；
                // 已经量过格子的也不动 —— 这一步是后台悄悄发生的，不能让它把框换掉、
                // 留下一套按老框算的网格。
                guard let index = parts.firstIndex(where: { $0.id == id }),
                      sameRect(parts[index].bounds, drawn),
                      parts[index].gridRect == nil else { return }
                // 走统一入口：改框就得清掉派生的网格数据，这条规则只该有一处实现。
                applyBounds(biggest.bounds, to: id)
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
                // 下标早就不是当初那个了 —— 必须按 id 重新定位。
                guard let index = parts.firstIndex(where: { $0.id == id }) else { return }
                // 插件标记跟着拆出来的每一块走（同合并那条）：一块插件拆成两块，
                // 两块都还是插件。不带的话用户得回「量格子」逐块重标，而他记得自己标过。
                let replacements = mine.map {
                    BeadPart(rowBand: target.rowBand, bounds: $0.bounds,
                             isConnector: target.isConnector)
                }
                var next = parts
                next.remove(at: index)
                next.append(contentsOf: replacements)
                parts = next.sorted {
                    $0.rowBand != $1.rowBand ? $0.rowBand < $1.rowBand : $0.bounds.minX < $1.bounds.minX
                }
                // 拆完不选中拆出来的那几个（跟 addPart 相反，那边选中是为了接着微调）：拆开是为了「这两块本来就是两个」，
                // 不是为了接着对它们动手，而多选着好几个反而挡住了看拆得对不对。
                selection.removeAll()
                lastTappedOnImage = replacements.first?.id
            }
        }
    }

    /// 图上要替换显示的那个框：正在拖的预览，或者松手后等确认的新框。
    private var shownOverride: PendingBoundsChange? {
        if let pendingBounds { return pendingBounds }
        guard let boxPreview, selection.count == 1, let id = selection.first else { return nil }
        return PendingBoundsChange(partId: id, bounds: boxPreview)
    }

    /// 拖完一次把手 / 框身，松手时到这里。
    ///
    /// 零件已经对好网格或核对过颜色时先问一句：框一改这些全得重来，
    /// 而用户在这一屏看不到「已对齐」的绿勾，不问的话他根本不知道自己丢了什么。
    /// 还没划过网格的零件没什么可丢的，直接改。
    private func commitBounds(_ newBounds: CGRect, to id: UUID) {
        guard let part = parts.first(where: { $0.id == id }) else { return }
        if part.hasCells || part.isGridConfirmed {
            pendingBounds = PendingBoundsChange(partId: id, bounds: newBounds)
        } else {
            applyBounds(newBounds, to: id)
        }
    }

    /// 框一变，之前算出来的网格信息就作废（下一步「量格子」会按新框重算）——
    /// 同 mergeSelected：框都换了，行列数和格子内容不可能还对得上，「已对齐」也得跟着清。
    ///
    /// 不重排，`rowBand` 也不动：这还是同一个零件，编号跟着跳来跳去反而认不出改的是哪个。
    /// 挪到别的行去的零件，要等下次合并 / 补零件 / 拆开触发排序时才按老行号归位，可以接受。
    private func applyBounds(_ newBounds: CGRect, to id: UUID) {
        guard let index = parts.firstIndex(where: { $0.id == id }) else { return }
        parts[index].bounds = newBounds
        parts[index].gridRect = nil
        parts[index].rows = 0
        parts[index].cols = 0
        parts[index].cells = []
        parts[index].gridConfirmed = nil
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

private struct PendingBoundsChange: Equatable {
    let partId: UUID
    let bounds: CGRect
}

private struct PartsBoxOverlay: View {
    let parts: [BeadPart]
    let selection: Set<UUID>
    /// 归一化坐标 → 真实屏幕点。整层不再走 scaleEffect，所以线宽、字号都是
    /// **屏幕上的实际大小**，不用再除以缩放。
    let transform: PartsCanvasTransform
    /// 这个零件先按这个框画（拖动中的预览 / 等确认的新框），零件本身还没改。
    let override: PendingBoundsChange?

    var body: some View {
        Canvas { context, _ in
            for (index, part) in parts.enumerated() {
                let bounds = override?.partId == part.id ? override!.bounds : part.bounds
                let r = transform.screenRect(bounds)
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

/// 四条边都差不到 1e-9 就算同一个框。不用 `==`：重新拼一个矩形时
/// `(minY + h) - minY` 常常不等于 `h`，逐位比较会把「没动」判成「改了」。
private func sameRect(_ a: CGRect, _ b: CGRect) -> Bool {
    let eps: CGFloat = 1e-9
    return abs(a.minX - b.minX) < eps && abs(a.minY - b.minY) < eps
        && abs(a.maxX - b.maxX) < eps && abs(a.maxY - b.maxY) < eps
}

// MARK: - 选中零件后的编辑把手（改大小 / 挪位置）

/// 只在「正好选中一个零件」时出现：算法框歪了（框太大压到邻居、偏了一点），
/// 或者用户自己画的框没画准，都在这里修。
///
/// 交互刻意分两种，别互相打架：
///   · **四条边中点各一个橙色把手**：拖哪条边动哪条边，对侧固定 —— 精确改大小；
///   · **框内单指拖**：整块平移，位置对不准时挪一下。
///
/// ## 松手才提交
///
/// 拖动过程中只改 `preview`（画面上跟手的那个框），零件本身一动不动；松手时才交给
/// `onCommit`。零件的框一改，它对好的网格和核对过的颜色就作废，所以「改没改」
/// 必须在手指离开之后、按整次拖动来判断，不能每一帧都写：
///   · 手指按上把手时哪怕没挪，也会回调一次；逐帧写的话，重新拼出来的矩形跟原来
///     差最后一位浮点数，就被当成「改了」，格子悄悄清空；
///   · 两指捏合时第一根手指往往先被认成拖框，逐帧写的话数据在捏合认出来之前就已经清了，
///     之后把框放回去也补不回来。
private struct PartEditHandles: View {
    /// 零件现在的框（归一化坐标，相对整张图纸，和 BeadPart.bounds 同一套）。
    /// 拖动全程都从它算起。
    let bounds: CGRect
    /// 画面上显示的框。平时等于 `bounds`；拖动中是 `preview`，等用户确认时是待确认的框。
    let shownBounds: CGRect
    /// 零件区。改大小 / 挪位置都夹在这里面，框外本来就不该有零件。
    let roi: CGRect
    let transform: PartsCanvasTransform
    /// 画布正在两指缩放。这次拖动里只要撞上一次，整次拖动作废（见 `DragSession.cancelled`）。
    let isPinching: Bool
    @Binding var preview: CGRect?
    let onCommit: (CGRect) -> Void
    /// 在把手层上轻点一下（没拖动）。**把手不吃点按**：这一层盖住了选中的框和它四周
    /// 一圈热区，自己把点按吞掉的话，那一圈里的邻居零件就点不中了 —— 图纸上零件挨得近，
    /// 想选的下一个往往正好落在这圈里，用户看到的就是「点哪儿都没反应」。
    /// 交给上层按画布坐标去命中，点框身还是取消选中，点到邻居就选邻居。
    let onTap: (CGPoint) -> Void

    /// 框的最小边长（归一化）。只用来挡「把边拖过了对侧」；已经比它还窄的框
    /// （一颗豆宽的边条）不会因为按一下把手就被撑开，见 `resized`。
    private let minSide: CGFloat = 0.006
    /// 手指在屏幕上挪不到这么远，就当没拖，按下的那一点交回上层去命中零件。
    /// 落在框外的把手热区上才交：那一圈正是「邻居点不中」要救的地方；
    /// 落在框里的那半边算摸把手没摸准，什么都不做 —— 转发过去就成了取消选中，
    /// 用户想捏把手，手一抖，选中和把手一起没了。
    private let dragSlop: CGFloat = 4

    private enum Edge { case top, bottom, left, right }
    private enum DragKind: Equatable {
        case move
        case edge(Edge)
    }

    /// 一次拖动。同一时刻只认一个：两根手指分别按在把手和框身上时，后来的那个不理，
    /// 免得两边各从自己的起点算、互相覆盖。
    private struct DragSession {
        let kind: DragKind
        /// 这次拖动撞上过捏合。之后一律不跟手，松手也不提交。
        var cancelled = false
    }

    @State private var session: DragSession?

    var body: some View {
        let r = transform.screenRect(shownBounds)
        ZStack {
            // 框内：单指拖 = 挪动整个框；轻点 = 取消选中（沿用「点框身取消」的老行为，
            // 不然把手盖住框身后，想取消这个选中反而没地方点了）。轻点同样交给上层，
            // 由它按落点决定是取消选中还是选别的零件。
            //
            // 拖动和轻点并进同一个 DragGesture，按松手时挪了多远区分：两个手势 Simultaneous
            // 挂着的话，拖完松手会连带触发一次轻点（见 gestureCatcher 里的实测）。
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: max(r.width, 1), height: max(r.height, 1))
                // contentShape 必须在 position **之前**：position 会把视图撑满整个画布，
                // 挂在它后面的话热区也跟着铺满 —— 框外随手一拖，挪走的是框而不是图。
                .contentShape(Rectangle())
                .position(x: r.midX, y: r.midY)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in dragChanged(.move, value.translation) }
                        .onEnded { value in
                            dragEnded(.move, value.translation, at: value.startLocation)
                        }
                )
                // 放大到框盖住大半个画布时，框身不再接手势，单指拖交还给画布挪图。
                // 否则放大之后手指落在哪儿都是框，想把图挪到某条边附近去调它都做不到。
                // 这时要挪框先缩小；轻点落到手势层上，点中的还是这个框，照样取消选中。
                .allowsHitTesting(!coversMostOfCanvas(r))

            // 边把手写在框身后面，画在上层：两者重叠的地方归把手。
            edgeHandle(.top, in: r)
            edgeHandle(.bottom, in: r)
            edgeHandle(.left, in: r)
            edgeHandle(.right, in: r)
        }
    }

    private func coversMostOfCanvas(_ r: CGRect) -> Bool {
        let canvas = CGRect(origin: .zero, size: transform.size)
        let visible = r.intersection(canvas)
        guard !visible.isNull, canvas.width > 0, canvas.height > 0 else { return false }
        return visible.width * visible.height >= canvas.width * canvas.height * 0.7
    }

    private func edgeHandle(_ edge: Edge, in r: CGRect) -> some View {
        let horizontal = (edge == .top || edge == .bottom)
        let side = horizontal ? r.height : r.width
        // 热区厚 28pt，**大半压在框外**，伸进框里的那部分最多是边长的四分之一。
        // 这张图纸上大半零件在屏幕上只有三四十 pt 高，热区要是以边线为中心，
        // 上下两块一叠，框身就一点不剩，「按住框内挪位置」和「点框身取消选中」都摸不到了。
        // 框中间一半始终留给框身。
        let across: CGFloat = 28
        let inside = min(across / 2, side / 4)
        let outward = across / 2 - inside
        let along = min(44, max(24, horizontal ? r.width : r.height))
        let edgePoint: CGPoint
        let hotCenter: CGPoint
        switch edge {
        case .top:
            edgePoint = CGPoint(x: r.midX, y: r.minY)
            hotCenter = CGPoint(x: r.midX, y: r.minY - outward)
        case .bottom:
            edgePoint = CGPoint(x: r.midX, y: r.maxY)
            hotCenter = CGPoint(x: r.midX, y: r.maxY + outward)
        case .left:
            edgePoint = CGPoint(x: r.minX, y: r.midY)
            hotCenter = CGPoint(x: r.minX - outward, y: r.midY)
        case .right:
            edgePoint = CGPoint(x: r.maxX, y: r.midY)
            hotCenter = CGPoint(x: r.maxX + outward, y: r.midY)
        }
        return ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: horizontal ? along : across,
                       height: horizontal ? across : along)
                .contentShape(Rectangle())
                .position(hotCenter)
                .gesture(
                    // 改大小只认 translation：整次拖动按「相对起点挪了多少」算，起点就是
                    // 零件现在的框，跟手指按在热区的哪一点无关。按下的位置只在判成轻点时用，
                    // 交给上层去命中零件。
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in dragChanged(.edge(edge), value.translation) }
                        .onEnded { value in
                            dragEnded(.edge(edge), value.translation, at: value.startLocation)
                        }
                )
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.orange)
                .frame(width: horizontal ? 26 : 9, height: horizontal ? 9 : 26)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.white, lineWidth: 1.5)
                )
                .position(edgePoint)
                .allowsHitTesting(false)
        }
    }

    private func dragChanged(_ kind: DragKind, _ translation: CGSize) {
        if session == nil { session = DragSession(kind: kind) }
        guard session?.kind == kind else { return }
        if isPinching { session?.cancelled = true }
        guard session?.cancelled == false else {
            preview = nil
            return
        }
        switch kind {
        case .move:
            preview = moved(bounds, by: transform.normalizedDelta(translation))
        case .edge(let edge):
            preview = resized(edge, from: bounds, by: transform.normalizedDelta(translation))
        }
    }

    /// - Parameter start: 手指按下的位置。两处手势都挂在 `.position` **之后**的视图上，
    ///   那个视图铺满画布，所以这个点就是画布坐标，可以直接交给上层去命中零件。
    private func dragEnded(_ kind: DragKind, _ translation: CGSize, at start: CGPoint) {
        guard let ended = session, ended.kind == kind else { return }
        let final = preview
        session = nil
        preview = nil
        guard !ended.cancelled else { return }

        let distance = hypot(translation.width, translation.height)
        if distance < dragSlop {
            if kind == .move || !transform.screenRect(bounds).contains(start) { onTap(start) }
            return
        }
        guard let final, !sameRect(final, bounds) else { return }
        onCommit(final)
    }

    /// 整体平移，夹住四边别拖出零件区。
    ///
    /// 夹的是**这次挪动的量**，不是框本身：框原来就有一点越出零件区的（拆分出来的零件
    /// 只夹在整张图里），不能一挪就先被拽回来一截。
    private func moved(_ start: CGRect, by d: CGSize) -> CGRect {
        let dx = max(min(0, roi.minX - start.minX), min(max(0, roi.maxX - start.maxX), d.width))
        let dy = max(min(0, roi.minY - start.minY), min(max(0, roi.maxY - start.maxY), d.height))
        return start.offsetBy(dx: dx, dy: dy)
    }

    /// 把某条边从零件现在的位置挪 d：只动那条边，对侧固定，夹在零件区内并保底最小边长。
    ///
    /// 两条规则都只管「往外 / 往里拖了多少」，不去纠正框原来的样子：
    ///   · 这个方向没挪（d 为 0）直接原样返回，不重新拼矩形；
    ///   · 最小边长取 `minSide` 和框原来边长里小的那个 —— 一颗豆宽的边条按一下不会被撑开；
    ///   · 零件区边界放宽到框原来的边 —— 原来就越出去一点的框，按一下不会被拽回来。
    private func resized(_ edge: Edge, from start: CGRect, by d: CGSize) -> CGRect {
        switch edge {
        case .top:
            guard d.height != 0 else { return start }
            let floor = min(roi.minY, start.minY)
            let y = min(max(start.minY + d.height, floor), start.maxY - min(minSide, start.height))
            return CGRect(x: start.minX, y: y, width: start.width, height: start.maxY - y)
        case .bottom:
            guard d.height != 0 else { return start }
            let ceil = max(roi.maxY, start.maxY)
            let y = max(min(start.maxY + d.height, ceil), start.minY + min(minSide, start.height))
            return CGRect(x: start.minX, y: start.minY, width: start.width, height: y - start.minY)
        case .left:
            guard d.width != 0 else { return start }
            let floor = min(roi.minX, start.minX)
            let x = min(max(start.minX + d.width, floor), start.maxX - min(minSide, start.width))
            return CGRect(x: x, y: start.minY, width: start.maxX - x, height: start.height)
        case .right:
            guard d.width != 0 else { return start }
            let ceil = max(roi.maxX, start.maxX)
            let x = max(min(start.maxX + d.width, ceil), start.minX + min(minSide, start.width))
            return CGRect(x: start.minX, y: start.minY, width: x - start.minX, height: start.height)
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
        cropExact(work, normalized: rect)?.image
    }

    /// 同 `crop`，另外把**真正裁到的那一块**（同样是相对整张图纸的归一化矩形）一起交回来。
    ///
    /// 为什么要这个：裁的时候会把像素矩形取整（`.integral`，向外扩到整像素），
    /// 所以裁出来的图往往比要的那块**大一点点**，每边最多一个源像素。谁只是拿它当缩略图
    /// 谁就不用管；而「擦掉 / 补上」那一屏要把这张图铺回格子上跟格线对齐，
    /// 按要的那块铺就会整体拉伸一点点，格线跟豆子对不上 —— 而用户只会以为网格没量准。
    static func cropExact(_ work: PartsWorkImage, normalized rect: CGRect) -> (image: UIImage, rect: CGRect)? {
        guard let cg = work.image.cgImage, cg.width > 0, cg.height > 0 else { return nil }
        let local = work.localRect(rect)
        let pixels = CGRect(
            x: local.minX * CGFloat(cg.width),
            y: local.minY * CGFloat(cg.height),
            width: local.width * CGFloat(cg.width),
            height: local.height * CGFloat(cg.height)
        ).intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height)).integral
        guard pixels.width >= 1, pixels.height >= 1,
              let cropped = cg.cropping(to: pixels) else { return nil }
        let image = UIImage(cgImage: cropped, scale: work.image.scale,
                            orientation: work.image.imageOrientation)
        let exact = CGRect(x: pixels.minX / CGFloat(cg.width),
                           y: pixels.minY / CGFloat(cg.height),
                           width: pixels.width / CGFloat(cg.width),
                           height: pixels.height / CGFloat(cg.height))
        return (image, work.wholeRect(exact))
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
