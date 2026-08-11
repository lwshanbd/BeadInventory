//
//  PartsListStepView.swift
//  BeadInventory
//
//  多零件模式 · 第 ② 屏 - 零件清单
//
//  上一版立体拼豆被废掉的一条原因是：识别完只给了一句「找到 N 个零件」，
//  用户不知道结果对不对，也不知道下一步该干什么。所以这一屏的验收标准是两句话：
//
//    1. 一眼看得出**算法把哪块当成了一个零件** —— 图上有框有号，下面有对应缩略图；
//    2. 看出来不对时**当场能改** —— 删、合并、改名，或者拉灵敏度重拆。
//

import SwiftUI

struct PartsListStepView: View {
    let image: UIImage
    let roi: CGRect
    @Binding var parts: [BeadPart]
    @Binding var sensitivity: Double
    let onRedetect: () -> Void
    let onContinue: () -> Void

    @State private var selection: Set<UUID> = []
    @State private var thumbnails: [UUID: UIImage] = [:]
    @State private var roiImage: UIImage?
    @State private var renamingPart: BeadPart?
    @State private var renameText: String = ""
    @State private var showingSensitivity = false
    /// 最近一次是从图上点中的零件。用来驱动下面的缩略图滚过去；
    /// 单独一个 State 而不是复用 `selection`，是因为在缩略图里点选时不该再滚一次。
    @State private var lastTappedOnImage: UUID?
    @State private var splitting = false
    @State private var splitFailed = false

    private let columns = [GridItem(.adaptive(minimum: 86), spacing: Theme.Spacing.md)]

    var body: some View {
        VStack(spacing: 0) {
            preview
            Divider()
            partGrid
            footer
        }
        .navigationTitle("零件清单")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingSensitivity = true
                } label: {
                    Label("重新拆分", systemImage: "slider.horizontal.3")
                }
            }
        }
        .sheet(isPresented: $showingSensitivity) {
            SensitivitySheet(sensitivity: $sensitivity, partCount: parts.count) {
                selection.removeAll()
                onRedetect()
            }
        }
        .alert("零件改名", isPresented: Binding(
            get: { renamingPart != nil },
            set: { if !$0 { renamingPart = nil } }
        )) {
            TextField("名字", text: $renameText)
            Button("取消", role: .cancel) { renamingPart = nil }
            Button("保存") { commitRename() }
        } message: {
            Text("留空就用自动编号。")
        }
        .alert("这块拆不开", isPresented: $splitFailed) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("它在图上本来就是连成一整片的。如果确实是两个零件，先删掉它，再用右上角的「重新拆分」把灵敏度往左调一点试试。")
        }
        .task(id: partsSignature) {
            let snapshot = parts
            let img = image
            let region = roi
            let built = await Task.detached(priority: .userInitiated) {
                (thumbs: PartsThumbnailMaker.make(for: snapshot, from: img),
                 crop: PartsThumbnailMaker.crop(img, normalized: region))
            }.value
            thumbnails = built.thumbs
            roiImage = built.crop
        }
    }

    /// 缩略图只在「零件集合真的变了」时重建 —— 选中态变化不该触发一次全量裁图。
    private var partsSignature: String {
        parts.map { "\($0.id.uuidString)\($0.bounds)" }.joined()
    }

    // MARK: - 上半：图上的框

    private var preview: some View {
        GeometryReader { geo in
            let display = PartsRegionStepView.aspectFitRect(
                imageSize: roiImage?.size ?? CGSize(width: 1, height: 1),
                in: geo.size
            )
            ZStack(alignment: .topLeading) {
                if let roiImage {
                    Image(uiImage: roiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                PartsBoxOverlay(
                    parts: parts,
                    roi: roi,
                    selection: selection,
                    displayRect: display
                )
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture()
                    .onEnded { value in toggleHit(at: value.location, displayRect: display) }
            )
        }
        // 图纸是竖长的，240pt 高只剩不到 180pt 宽，五十几个框挤成一团看不清谁是谁。
        // 340pt 是「图上看得清 + 下面还能露出两行缩略图」的折中。
        .frame(height: 340)
        .background(Theme.ColorToken.Surface.subtle)
    }

    private func toggleHit(at point: CGPoint, displayRect: CGRect) {
        guard displayRect.width > 0, displayRect.height > 0 else { return }
        let n = CGPoint(
            x: (point.x - displayRect.minX) / displayRect.width,
            y: (point.y - displayRect.minY) / displayRect.height
        )
        // 命中多个（框互相重叠）时取面积最小的那个 —— 用户点的多半是压在上面的小零件。
        let hits = parts.filter { relative($0.bounds).contains(n) }
        guard let hit = hits.min(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
        else { return }
        toggle(hit.id)
        lastTappedOnImage = selection.contains(hit.id) ? hit.id : nil
    }

    private func relative(_ bounds: CGRect) -> CGRect {
        guard roi.width > 0, roi.height > 0 else { return .zero }
        return CGRect(
            x: (bounds.minX - roi.minX) / roi.width,
            y: (bounds.minY - roi.minY) / roi.height,
            width: bounds.width / roi.width,
            height: bounds.height / roi.height
        )
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
                    "没拆出零件",
                    systemImage: "square.dashed",
                    description: Text("框可能没圈住零件，或者灵敏度太低。点右上角「重新拆分」调一下。")
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
            if selection.isEmpty {
                Text("共 \(parts.count) 个零件。点图上的框或下面的缩略图选中，选中后能删除、合并、拆开或改名。")
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

            Button(action: onContinue) {
                Label("下一步：确认图纸配色", systemImage: "paintpalette")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(parts.isEmpty)
        }
        .padding()
        .background(.regularMaterial)
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
        merged.gridOrigin = nil
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

    /// 拆开 = 只在这一个框里重跑一次检测，并且**关掉闭运算** ——
    /// 把两块粘成一块的正是那一步（它为了补描边上的缺口，会顺手桥接靠得很近的两个零件）。
    ///
    /// 框要先往外放一圈再检测：背景色是靠「区域四周一圈的众数」估的，
    /// 贴着零件边缘去取，取到的全是描边的黑色，整块就会被判成背景。
    private func splitSelected() {
        guard selection.count == 1, let id = selection.first,
              let index = parts.firstIndex(where: { $0.id == id }) else { return }
        let target = parts[index]
        let padded = target.bounds
            .insetBy(dx: -target.bounds.width * 0.12, dy: -target.bounds.height * 0.12)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        var options = PartsDetectionOptions()
        options.closingRadius = 0
        options.minAreaRatio = 0.015          // 相对这个小框，不是整张图
        options.maxWorkingPixels = 250_000
        splitting = true

        Task.detached(priority: .userInitiated) {
            let sub = PartsDetector.detect(in: image, roi: padded, options: options)
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
    let roi: CGRect
    let selection: Set<UUID>
    let displayRect: CGRect

    var body: some View {
        Canvas { context, _ in
            guard roi.width > 0, roi.height > 0 else { return }
            for (index, part) in parts.enumerated() {
                let rel = CGRect(
                    x: (part.bounds.minX - roi.minX) / roi.width,
                    y: (part.bounds.minY - roi.minY) / roi.height,
                    width: part.bounds.width / roi.width,
                    height: part.bounds.height / roi.height
                )
                let r = CGRect(
                    x: displayRect.minX + rel.minX * displayRect.width,
                    y: displayRect.minY + rel.minY * displayRect.height,
                    width: rel.width * displayRect.width,
                    height: rel.height * displayRect.height
                )
                let selected = selection.contains(part.id)
                let stroke: Color = selected ? .white : .cyan
                if selected {
                    context.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(.white.opacity(0.28)))
                }
                context.stroke(Path(roundedRect: r, cornerRadius: 2),
                               with: .color(stroke),
                               lineWidth: selected ? 2 : 1)

                // 序号贴在框的左上角外侧；框太靠上时贴内侧，免得跑出画面。
                //
                // 小框不画号：一张图上五十几个零件，全画出来数字会叠成一团反而谁都看不清。
                // 小零件靠「点一下高亮」认领 —— 点图上的框或点下面的缩略图，两边同时高亮。
                let bigEnough = min(r.width, r.height) >= 16
                guard bigEnough || selected else { continue }
                let badge = Text("\(index + 1)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.black)
                let badgeY = r.minY > displayRect.minY + 8 ? r.minY - 5 : r.minY + 5
                context.fill(
                    Path(ellipseIn: CGRect(x: r.minX - 6, y: badgeY - 6, width: 13, height: 13)),
                    with: .color(selected ? .white : .cyan)
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
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .stroke(isSelected ? Theme.ColorToken.Morandi.mauve : Theme.ColorToken.Border.default,
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

// MARK: - 灵敏度

private struct SensitivitySheet: View {
    @Binding var sensitivity: Double
    let partCount: Int
    let onApply: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Text("现在拆出 \(partCount) 个零件。")
                    .font(.subheadline)
                    .foregroundStyle(Theme.ColorToken.Text.secondary)

                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Slider(value: $sensitivity, in: 0...1)
                    HStack {
                        Text("拆得少 · 只认颜色重的")
                        Spacer()
                        Text("拆得多 · 浅色也认")
                    }
                    .font(.caption2)
                    .foregroundStyle(Theme.ColorToken.Text.tertiary)
                }

                Text("零件被切成好几块 → 往左调；水印、色号表的碎片也被当成零件 → 往左调。\n浅色零件整个没被认出来 → 往右调。")
                    .font(.footnote)
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    onApply()
                    dismiss()
                } label: {
                    Label("按这个灵敏度重拆", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Spacer(minLength: 0)
            }
            .padding(Theme.Spacing.lg)
            .background(Theme.ColorToken.Surface.background)
            .navigationTitle("重新拆分")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - 裁图

enum PartsThumbnailMaker {
    /// 按零件 bbox 从整图上裁小图。四周留 6% 余量，免得描边紧贴缩略图边缘看不清。
    static func make(for parts: [BeadPart], from image: UIImage) -> [UUID: UIImage] {
        guard let cg = image.cgImage else { return [:] }
        var result: [UUID: UIImage] = [:]
        for part in parts {
            let padded = part.bounds.insetBy(dx: -part.bounds.width * 0.06,
                                             dy: -part.bounds.height * 0.06)
            if let cropped = crop(cg, normalized: padded, scale: image.scale, orientation: image.imageOrientation) {
                result[part.id] = cropped
            }
        }
        return result
    }

    static func crop(_ image: UIImage, normalized rect: CGRect) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        return crop(cg, normalized: rect, scale: image.scale, orientation: image.imageOrientation)
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
