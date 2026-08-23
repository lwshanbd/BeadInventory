//
//  ProjectDetailView.swift
//  BeadInventory
//
//  项目详情视图 - 显示项目中各颜色的豆子用量
//

import SwiftUI
import PhotosUI

struct ProjectDetailView: View {
    let project: ProjectRecord
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var sortByQuantity = true
    @State private var showChildrenSection = true

    // 图片编辑相关状态
    @State private var showingThumbnailEditor = false
    @State private var showingFinishedImageEditor = false
    @State private var showingPatternModePicker = false
    /// 在模式选择页里选了哪种模式，等它收起后再进下一页（见 openPatternModeIfSelected）
    @State private var pendingSinglePatternMode = false
    @State private var pendingMultiPartMode = false
    @State private var showingSinglePatternFlow = false
    @State private var showingPartsSheetFlow = false

    /// 两种模式都只有一个入口：进去之后由流程页自己决定从第一屏开始，
    /// 还是接着上次的进度（对过网格的直接进「照着拼」）。
    private func openPatternModeIfSelected() {
        if pendingSinglePatternMode {
            pendingSinglePatternMode = false
            showingSinglePatternFlow = true
        } else if pendingMultiPartMode {
            pendingMultiPartMode = false
            showingPartsSheetFlow = true
        }
    }

    var isParentProject: Bool {
        inventoryManager.isParentProject(project.id)
    }

    var childProjects: [ProjectRecord] {
        inventoryManager.childProjects(of: project.id)
    }

    var brandName: String? {
        guard let brandId = project.brandId else { return nil }
        return inventoryManager.brands.first { $0.id == brandId }?.name
    }

    // 父项目显示汇总数据，普通项目显示自己的数据
    var displayUsage: [BeadUsage] {
        if isParentProject {
            return inventoryManager.aggregatedBeadUsage(for: project.id)
        }
        return project.beadUsage
    }

    var sortedUsage: [BeadUsage] {
        if sortByQuantity {
            return displayUsage.sorted { $0.quantity > $1.quantity }
        } else {
            return displayUsage.sorted { $0.colorCode < $1.colorCode }
        }
    }

    var colorCount: Int {
        if isParentProject {
            return inventoryManager.aggregatedColorCount(for: project.id)
        }
        return project.beadUsage.count
    }

    var totalBeads: Int {
        if isParentProject {
            return inventoryManager.aggregatedTotalBeads(for: project.id)
        }
        return project.totalBeads
    }

    // 获取当前项目的最新状态
    var currentProject: ProjectRecord? {
        inventoryManager.projects.first { $0.id == project.id }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 项目信息卡片
                ProjectInfoCardEnhanced(
                    project: currentProject ?? project,
                    brandName: brandName,
                    isParent: isParentProject,
                    colorCount: colorCount,
                    totalBeads: totalBeads,
                    childCount: childProjects.count,
                    onEditThumbnail: { showingThumbnailEditor = true }
                )

                // 成品图展示区域（仅已执行项目显示）
                if !project.isPlanned {
                    FinishedImageSection(
                        project: currentProject ?? project,
                        onEditFinishedImage: { showingFinishedImageEditor = true }
                    )
                }

                // 子项目列表（仅父项目显示）
                if isParentProject && !childProjects.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Button {
                            withAnimation { showChildrenSection.toggle() }
                        } label: {
                            HStack {
                                Text("子项目 (\(childProjects.count))")
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Spacer()
                                Image(systemName: showChildrenSection ? "chevron.up" : "chevron.down")
                                    .foregroundColor(.secondary)
                            }
                        }

                        if showChildrenSection {
                            ForEach(childProjects) { child in
                                ChildProjectRowWithActions(
                                    project: child,
                                    onDelete: {
                                        inventoryManager.deleteProject(id: child.id)
                                    },
                                    onDetach: {
                                        inventoryManager.detachProject(child.id)
                                    }
                                )
                            }
                        }
                    }
                    .padding()
                    .background(Theme.ColorToken.Surface.elevated)
                    .cornerRadius(Theme.Radius.md)
                    .padding(.horizontal)
                }

                // 排序选择
                HStack {
                    Text(isParentProject ? "汇总颜色用量" : "颜色用量")
                        .font(.headline)

                    Spacer()

                    Menu {
                        Button {
                            sortByQuantity = true
                        } label: {
                            Label("按用量排序", systemImage: sortByQuantity ? "checkmark" : "")
                        }

                        Button {
                            sortByQuantity = false
                        } label: {
                            Label("按色号排序", systemImage: sortByQuantity ? "" : "checkmark")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(sortByQuantity ? "按用量" : "按色号")
                                .font(.subheadline)
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.caption)
                        }
                        .foregroundColor(Theme.ColorToken.Morandi.latte)
                    }
                }
                .padding(.horizontal)

                // 颜色用量列表
                LazyVStack(spacing: 8) {
                    ForEach(sortedUsage) { usage in
                        BeadUsageRow(usage: usage, colorSystem: project.colorSystem)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .background(Theme.ColorToken.Surface.background)
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if (currentProject ?? project).isPlanned {
                let projectId = (currentProject ?? project).id
                let hasThumbnail = inventoryManager.projectIDsWithThumbnail.contains(projectId)
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingPatternModePicker = true
                    } label: {
                        Label("拼图模式", systemImage: "square.grid.3x3.square")
                    }
                    .disabled(!hasThumbnail)
                }
            }
        }
        .sheet(isPresented: $showingPatternModePicker, onDismiss: openPatternModeIfSelected) {
            PatternModeSelectionSheet(
                onSelectSinglePattern: { pendingSinglePatternMode = true },
                onSelectMultiPart: { pendingMultiPartMode = true }
            )
        }
        .fullScreenCover(isPresented: $showingPartsSheetFlow) {
            PartsSheetFlowView(project: currentProject ?? project)
                .environmentObject(inventoryManager)
        }
        .fullScreenCover(isPresented: $showingSinglePatternFlow) {
            SinglePatternFlowView(project: currentProject ?? project)
                .environmentObject(inventoryManager)
        }
        .sheet(isPresented: $showingThumbnailEditor) {
            let projectId = (currentProject ?? project).id
            let data = inventoryManager.fetchProjectThumbnailData(for: projectId)
            ProjectImageEditorSheet(
                projectId: projectId,
                title: "项目封面",
                currentImage: data.flatMap { UIImage(data: $0) },
                onSave: { imageData in
                    inventoryManager.updateProjectThumbnail(projectId, thumbnail: imageData)
                }
            )
            .environmentObject(inventoryManager)
        }
        .sheet(isPresented: $showingFinishedImageEditor) {
            let projectId = (currentProject ?? project).id
            let data = inventoryManager.fetchProjectFinishedImageData(for: projectId)
            ProjectImageEditorSheet(
                projectId: projectId,
                title: "成品图",
                currentImage: data.flatMap { UIImage(data: $0) },
                maxImageSize: 400, // 成品图使用更大尺寸
                savesPatternSource: false, // 成品图是实物照片，不是图纸，别覆盖拼图模式的原图
                onSave: { imageData in
                    inventoryManager.updateProjectFinishedImage(projectId, finishedImage: imageData)
                }
            )
            .environmentObject(inventoryManager)
        }
    }
}

// MARK: - 子项目行
struct ChildProjectRow: View {
    let project: ProjectRecord

    var body: some View {
        HStack(spacing: 12) {
            // 缩略图（异步加载，没图时不渲染占位 —— 保持原行为）
            ProjectThumbnailImage(projectId: project.id) {
                EmptyView()
            } content: { uiImage in
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)

                Text(project.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("\(project.beadUsage.count) 色")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("\(project.totalBeads) 颗")
                    .font(.caption)
                    .foregroundColor(Theme.ColorToken.Morandi.latte)
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Theme.ColorToken.Surface.subtle)
        .cornerRadius(Theme.Radius.sm)
    }
}

// MARK: - 带操作的子项目行
struct ChildProjectRowWithActions: View {
    let project: ProjectRecord
    let onDelete: () -> Void
    let onDetach: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // 缩略图（异步加载，没图时不渲染占位）
            ProjectThumbnailImage(projectId: project.id) {
                EmptyView()
            } content: { uiImage in
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
                    )
            }

            NavigationLink(destination: ProjectDetailView(project: project)) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)

                    HStack {
                        Text(project.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Spacer()

                        Text("\(project.beadUsage.count) 色")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text("\(project.totalBeads) 颗")
                            .font(.caption)
                            .foregroundColor(Theme.ColorToken.Morandi.latte)
                    }
                }
            }

            // 操作按钮
            Menu {
                Button {
                    onDetach()
                } label: {
                    Label("独立为顶级项目", systemImage: "arrow.up.forward.square")
                }

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("删除子项目", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Theme.ColorToken.Surface.subtle)
        .cornerRadius(Theme.Radius.sm)
    }
}

// MARK: - 项目信息卡片（增强版）
struct ProjectInfoCardEnhanced: View {
    let project: ProjectRecord
    let brandName: String?
    let isParent: Bool
    let colorCount: Int
    let totalBeads: Int
    let childCount: Int
    var onEditThumbnail: (() -> Void)? = nil

    @EnvironmentObject private var inventoryManager: InventoryManager
    @State private var loadedThumbnail: UIImage?

    var body: some View {
        VStack(spacing: 16) {
            // 缩略图区域
            ZStack(alignment: .topTrailing) {
                if let image = loadedThumbnail {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 150)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.md)
                                .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
                        )
                } else if onEditThumbnail != nil {
                    // 无图片时的占位符
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .fill(Theme.ColorToken.Surface.subtle)
                        .frame(height: 100)
                        .overlay(
                            VStack(spacing: 8) {
                                Image(systemName: "photo.badge.plus")
                                    .font(.title2)
                                    .foregroundColor(.secondary)
                                Text("添加封面")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        )
                        .onTapGesture {
                            onEditThumbnail?()
                        }
                }

                // 编辑按钮
                if onEditThumbnail != nil && loadedThumbnail != nil {
                    Button {
                        onEditThumbnail?()
                    } label: {
                        Image(systemName: "pencil.circle.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                            .background(Circle().fill(Theme.ColorToken.Fill.latte))
                    }
                    .padding(8)
                }
            }
            .task(id: "\(project.id.uuidString)-\(inventoryManager.projectBlobsRevision)") {
                let id = project.id
                // 走后台 actor —— 主线程同步 fetch 是用户 .ips 里那条崩溃栈的来源
                let data = await inventoryManager.imageLoader?.thumbnail(for: id)
                guard !Task.isCancelled, id == project.id else { return }
                self.loadedThumbnail = data.flatMap { UIImage(data: $0) }
            }

            // 日期和状态
            HStack {
                if isParent {
                    Label("父项目", systemImage: "folder.fill")
                        .font(.caption)
                        .foregroundColor(Theme.ColorToken.Morandi.latte)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.ColorToken.Morandi.latte.opacity(0.1))
                        .cornerRadius(Theme.Radius.sm)
                }

                Label(project.date.formatted(date: .long, time: .omitted), systemImage: "calendar")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()

                if project.isArchived {
                    Label("已归档", systemImage: "archivebox.fill")
                        .font(.caption)
                        .foregroundColor(Theme.ColorToken.Status.warning)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.ColorToken.Status.warning.opacity(0.1))
                        .cornerRadius(Theme.Radius.sm)
                }
            }

            Divider()

            // 统计信息
            HStack(spacing: 20) {
                if isParent {
                    VStack(spacing: 4) {
                        Text("\(childCount)")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(Theme.ColorToken.Decorative.lemon)
                        Text("子项目")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                VStack(spacing: 4) {
                    Text("\(colorCount)")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(Theme.ColorToken.Decorative.lavender)
                    Text(isParent ? "总颜色" : "颜色数")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                VStack(spacing: 4) {
                    Text("\(totalBeads)")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(Theme.ColorToken.Decorative.sky)
                    Text("总颗数")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let brandName = brandName {
                    VStack(spacing: 4) {
                        Text(brandName)
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(Theme.ColorToken.Decorative.mint)
                        Text("品牌")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(Theme.ColorToken.Surface.elevated)
        .cornerRadius(Theme.Radius.md)
        .padding(.horizontal)
    }
}

// MARK: - 颜色用量行
struct BeadUsageRow: View {
    let usage: BeadUsage
    var colorSystem: ColorSystem = .mard
    @EnvironmentObject var inventoryManager: InventoryManager

    var beadColor: BeadColor? {
        inventoryManager.findColor(byCode: usage.colorCode)
    }

    var displayColor: Color {
        beadColor?.color ?? .gray
    }

    var colorName: String {
        beadColor?.colorName ?? ""
    }

    /// 根据项目色号体系显示对应的色号
    var displayCodeText: String {
        beadColor?.displayCode(for: colorSystem) ?? usage.colorCode
    }

    var body: some View {
        HStack(spacing: 12) {
            // 颜色预览
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(displayColor)
                .frame(width: 44, height: 44)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
                )

            // 色号和名称
            VStack(alignment: .leading, spacing: 4) {
                Text(displayCodeText)
                    .font(.system(.headline, design: .monospaced))

                if !colorName.isEmpty {
                    Text(colorName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // 用量
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(usage.quantity)")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)

                Text("颗")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // 扣减状态
            if usage.isDeducted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(Theme.ColorToken.Status.success)
                    .font(.title3)
            }
        }
        .padding()
        .background(Theme.ColorToken.Surface.elevated)
        .cornerRadius(Theme.Radius.md)
    }
}

// MARK: - 成品图展示区域
struct FinishedImageSection: View {
    let project: ProjectRecord
    let onEditFinishedImage: () -> Void
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var showingDatePicker = false
    @State private var selectedDate: Date = Date()
    @State private var loadedFinishedImage: UIImage?

    /// 用集合做存在性检查（不加载 Data）—— 决定按钮文案 / 占位还是图。
    private var hasFinishedImage: Bool {
        inventoryManager.projectIDsWithFinishedImage.contains(project.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("成品展示", systemImage: "star.fill")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                Button {
                    onEditFinishedImage()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: hasFinishedImage ? "pencil" : "photo.badge.plus")
                        Text(hasFinishedImage ? "修改" : "上传成品图")
                    }
                    .font(.caption)
                    .foregroundColor(Theme.ColorToken.Morandi.latte)
                }
            }

            if let image = loadedFinishedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.md)
                            .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
                    )

                // 完成日期选择
                HStack {
                    Image(systemName: "calendar")
                        .foregroundColor(.secondary)
                    Text("完成日期")
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        selectedDate = project.completedDate ?? Date()
                        showingDatePicker = true
                    } label: {
                        if let date = project.completedDate {
                            Text(formatDate(date))
                                .foregroundColor(Theme.ColorToken.Morandi.latte)
                        } else {
                            Text("选择日期")
                                .foregroundColor(Theme.ColorToken.Morandi.latte)
                        }
                    }

                    if project.completedDate != nil {
                        Button {
                            inventoryManager.updateProjectCompletedDate(project.id, completedDate: nil)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .font(.subheadline)
                .padding(.top, 8)
            } else {
                // 空状态占位符
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(Theme.ColorToken.Surface.subtle)
                    .frame(height: 150)
                    .overlay(
                        VStack(spacing: 12) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary.opacity(0.5))
                            Text("上传成品图展示你的作品")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    )
                    .onTapGesture {
                        onEditFinishedImage()
                    }
            }
        }
        .padding()
        .background(Theme.ColorToken.Surface.elevated)
        .cornerRadius(Theme.Radius.md)
        .padding(.horizontal)
        .task(id: "\(project.id.uuidString)-\(inventoryManager.projectBlobsRevision)") {
            let id = project.id
            let data = await inventoryManager.imageLoader?.finishedImage(for: id)
            guard !Task.isCancelled, id == project.id else { return }
            self.loadedFinishedImage = data.flatMap { UIImage(data: $0) }
        }
        .sheet(isPresented: $showingDatePicker) {
            CompletedDatePickerSheet(
                selectedDate: $selectedDate,
                onSave: { date in
                    inventoryManager.updateProjectCompletedDate(project.id, completedDate: date)
                }
            )
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: date)
    }
}

// MARK: - 完成日期选择弹窗
struct CompletedDatePickerSheet: View {
    @Environment(\.dismiss) var dismiss
    @Binding var selectedDate: Date
    let onSave: (Date) -> Void

    var body: some View {
        NavigationStack {
            VStack {
                DatePicker(
                    "选择完成日期",
                    selection: $selectedDate,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .padding()

                Spacer()
            }
            .navigationTitle("完成日期")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") {
                        onSave(selectedDate)
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - 项目图片编辑弹窗
struct ProjectImageEditorSheet: View {
    let projectId: UUID
    let title: String
    let currentImage: UIImage?
    var maxImageSize: CGFloat = 200
    /// 这张图是不是「项目封面」——只有封面才该另存一份原图给拼图 / 多零件模式
    /// （`PatternSourceStore`）。成品图是拼完的实物照片，跟图纸没有任何关系，存进去会被
    /// 多零件模式当成图纸原图读出来，把已经标好的零件框和格子套到一张不相干的图上。
    /// 默认 true：封面编辑器有好几个入口（详情页、计划项目页），漏传时保持原有行为。
    var savesPatternSource: Bool = true
    let onSave: (Data?) -> Void

    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var inventoryManager: InventoryManager

    @State private var selectedPhotoItem: PhotosPickerItem?
    /// 这一张要不要留原图。是每张图各自的决定，设置里那个开关只给初值
    /// （同 `ScanView.keepPatternSource`）。打开这一屏时会按库里到底有没有那份文件校正 ——
    /// 不校正的话，一个存着 20 MB 原图的项目可能显示「关」，反过来也一样。
    @State private var keepPatternSource = PatternSourceStore.keepsSourceByDefault
    /// 库里已经有这个项目的原图。决定开关的初值，也决定要不要显示这一行。
    @State private var storedSourceExists = false
    /// 库里那份原图多大。开关那一行显示给用户看 —— 「要不要删掉」得知道删的是多少东西。
    @State private var storedSourceBytes = 0
    /// 打开这一屏时「保留原图」是什么样。用来判断用户有没有拨过它 ——
    /// 只拨开关不改图也是一次真的改动（把库里那份删掉），保存键得亮。
    @State private var initialKeepPatternSource = false
    /// 用户在这一屏**真的换了一张图**（相册选的 / 相机拍的），不是只把现有封面裁了一下。
    ///
    /// 这两件事必须分开，否则就是用户报的那个障：只裁一下封面，`editedImage` 就非 nil，
    /// 被当成「有新图」，于是拿**压缩封面的裁切结果**去覆盖 `PatternSourceStore` 里那份
    /// 全分辨率原图 —— 拼图模式从此只剩封面那点分辨率，而且不可逆（原图不进 iCloud、
    /// 不进备份）。`editedImage != nil` 只说明「图被改过」，不说明「换了一张图」。
    ///
    /// **只在裁切确认时置位**（见 `imageToCrop` / `pendingCropIsNewImage`）：选图那一刻就置位的话，
    /// 用户在裁切页点「取消」会把它留在 true —— 接着去裁现有封面，写进去的又是压缩封面了。
    @State private var pickedNewImage = false
    /// 正在裁的这张是不是新选的图。裁切确认时才交给 `pickedNewImage`；
    /// 用户点「取消」就随 `imageToCrop` 一起作废，什么都不留下。
    @State private var pendingCropIsNewImage = false
    @State private var editedImage: UIImage?
    @State private var isLoadingImage = false
    @State private var showingCropView = false
    @State private var imageToCrop: UIImage?
    @State private var showingCamera = false
    @State private var pendingCropAfterCamera = false  // 相机关闭后需要打开裁切
    @State private var saveSuccessAt: Date = .distantPast
    /// 编码失败时置位。失败必须可见 —— 静默失败会让用户以为图存上了。
    @State private var encodeFailed = false
    /// 正在等用户确认的那次写入 —— 它会让拼图 / 多零件模式里已经对好的图纸对不上。
    /// nil = 没有待确认的。
    @State private var pendingWrite: PendingWrite?

    private enum PendingWrite { case save, removeImage }

    var displayImage: UIImage? {
        editedImage ?? currentImage
    }

    private var confirmingPatternWorkLoss: Binding<Bool> {
        Binding(get: { pendingWrite != nil }, set: { if !$0 { pendingWrite = nil } })
    }

    /// 确认弹窗的正文。说「图纸」不说「网格」—— 多零件模式存的是零件摆位，
    /// 那些用户从没「对过网格」，照着网格说话他会以为弹错了。
    private var patternWorkLossMessage: String {
        if pendingWrite == .removeImage {
            return "这个项目在拼图模式里已经对好了图纸，而它就是照着这张封面对的。封面移除之后没有图可以对照，得重新来一遍。"
        }
        return pickedNewImage
            ? "这个项目在拼图模式里已经对好了图纸。换成新图之后，格子和判过的颜色都对不上了，得重新对一遍。"
            : "这个项目在拼图模式里已经对好了图纸，而它是照着现在这张图对的。改完取景就对不上了，得重新对一遍。"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // 图片预览区域
                if isLoadingImage {
                    ProgressView("加载中...")
                        .frame(height: 200)
                } else if let image = displayImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 250)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.md)
                                .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
                        )
                        .padding(.horizontal)
                } else {
                    // 空状态
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .fill(Theme.ColorToken.Surface.subtle)
                        .frame(height: 200)
                        .overlay(
                            VStack(spacing: 12) {
                                Image(systemName: "photo.badge.plus")
                                    .font(.system(size: 40))
                                    .foregroundColor(.secondary)
                                Text("选择图片或拍照")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        )
                        .padding(.horizontal)
                }

                // 操作按钮
                VStack(spacing: 12) {
                    // 相册和拍照按钮
                    HStack(spacing: 12) {
                        // 从相册选择
                        // `.current`：相册存的是什么就给什么字节，别把 HEIC 转码成 JPEG
                        // （同 ScanView，理由见那边的注释）。
                        PhotosPicker(selection: $selectedPhotoItem, matching: .images,
                                     preferredItemEncoding: .current) {
                            HStack {
                                Image(systemName: "photo.on.rectangle")
                                Text("相册")
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Theme.ColorToken.Fill.latte)
                            .foregroundColor(.white)
                            .cornerRadius(Theme.Radius.md)
                        }

                        // 拍照按钮
                        Button {
                            showingCamera = true
                        } label: {
                            HStack {
                                Image(systemName: "camera")
                                Text("拍照")
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Theme.ColorToken.Fill.success)
                            .foregroundColor(.white)
                            .cornerRadius(Theme.Radius.md)
                        }
                    }
                    .padding(.horizontal)

                    // 裁切按钮（仅当有图片时显示）
                    if let currentDisplayImage = displayImage {
                        HStack(spacing: 12) {
                            Button {
                                // 重裁一张「新选的图」仍然算换图；裁的是库里那张封面就不算。
                                pendingCropIsNewImage = pickedNewImage
                                imageToCrop = currentDisplayImage
                            } label: {
                                HStack {
                                    Image(systemName: "crop")
                                    Text("裁切")
                                }
                                .font(.subheadline)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Theme.ColorToken.Status.info.opacity(0.1))
                                .foregroundColor(Theme.ColorToken.Status.info)
                                .cornerRadius(Theme.Radius.md)
                            }

                            Button {
                                // 「重置」是把这一屏对封面的改动全撤掉，回到库里那张 ——
                                // 那就包括「我刚选的那张新图」，不然撤完还留着一个
                                // pickedNewImage=true，保存时会去写一份属于已经不要了的图的原图。
                                editedImage = nil
                                pickedNewImage = false
                                imageToCrop = nil
                            } label: {
                                HStack {
                                    Image(systemName: "arrow.uturn.backward")
                                    Text("重置")
                                }
                                .font(.subheadline)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Theme.ColorToken.Status.warning.opacity(0.1))
                                .foregroundColor(Theme.ColorToken.Status.warning)
                                .cornerRadius(Theme.Radius.md)
                            }
                            .disabled(editedImage == nil)
                        }
                        .padding(.horizontal)
                    }

                    // 「这张要不要留原图」。跟识别图纸那一屏同一个决定、同一句话 ——
                    // 只在那边有、这边没有的话，从详情页换封面就会又悄悄留下一份几十 MB。
                    // 成品图不涉及拼图模式（savesPatternSource == false），不显示。
                    //
                    // 只在**真的有得选**的时候才出现：换了一张新图（要不要留这张新的），
                    // 或者库里已经有一份（要不要删掉）。**只是裁一下现有封面不算** ——
                    // 那条路根本不会写原图（见 `applyPatternSourceDecision`），开关摆在那儿唯一能做的
                    // 就是删，写着「保留原图」却只会删，是个骗人的开关。
                    if savesPatternSource, displayImage != nil,
                       pickedNewImage || storedSourceExists {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(isOn: $keepPatternSource) {
                                HStack(spacing: 6) {
                                    Text("保留原图")
                                        .font(.caption)
                                    // 库里那份多大。**只在没换新图时显示**：换了新图的话，
                                    // 这个数字是上一张图的，而真正要写进去的那份还没编码出来，
                                    // 拿旧数字冒充新的比不显示更糟。
                                    if !pickedNewImage, storedSourceExists, storedSourceBytes > 0 {
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(storedSourceBytes), countStyle: .file))
                                            .font(.caption2.monospacedDigit())
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .toggleStyle(.switch)
                            .tint(Theme.ColorToken.Morandi.mauve)

                            Text(keepPatternSourceHint)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal)
                    }

                    // 移除按钮（仅当有当前图片时显示）
                    if currentImage != nil || editedImage != nil {
                        Button {
                            attemptRemoveImage()
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text("移除图片")
                            }
                            .font(.subheadline)
                            .foregroundColor(Theme.ColorToken.Status.error)
                        }
                        .padding(.top, 8)
                    }
                }

                Spacer()
            }
            .padding(.vertical)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        // 会让已经对好的图纸作废时，先问一句 —— 重新对一遍是几十分钟的活，
                        // 不能因为用户只是想换张好看点的封面就悄悄作废掉。
                        if patternWorkWouldBreak() {
                            pendingWrite = .save
                        } else {
                            performSave()
                        }
                    }
                    .fontWeight(.semibold)
                    // 「图没变」不等于「没改动」：只拨了「保留原图」开关同样是一次要落盘的决定。
                    .disabled(editedImage == nil && currentImage == displayImage
                              && keepPatternSource == initialKeepPatternSource)
                }
            }
            .alert("已经对好的图纸会对不上", isPresented: confirmingPatternWorkLoss) {
                Button("取消", role: .cancel) { pendingWrite = nil }
                Button(pendingWrite == .removeImage ? "仍要移除" : "仍要保存", role: .destructive) {
                    let action = pendingWrite
                    pendingWrite = nil
                    if action == .removeImage { performRemoveImage() } else { performSave() }
                }
            } message: {
                Text(patternWorkLossMessage)
            }
            .onChange(of: selectedPhotoItem) { _, newItem in
                if let newItem = newItem {
                    isLoadingImage = true
                    Task {
                        if let data = try? await newItem.loadTransferable(type: Data.self),
                           let image = UIImage(data: data) {
                            await MainActor.run {
                                imageToCrop = image
                                pendingCropIsNewImage = true
                                isLoadingImage = false
                            }
                        } else {
                            await MainActor.run {
                                isLoadingImage = false
                            }
                        }
                    }
                    selectedPhotoItem = nil
                }
            }
            // 监听 imageToCrop 变化，自动打开裁切视图
            .onChange(of: imageToCrop) { _, newImage in
                if newImage != nil && !showingCropView && !showingCamera {
                    // 延迟打开，确保状态稳定
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        if imageToCrop != nil {
                            showingCropView = true
                        }
                    }
                }
            }
            // 相机关闭后检查是否需要打开裁切
            .onChange(of: showingCamera) { _, isShowing in
                if !isShowing && pendingCropAfterCamera && imageToCrop != nil {
                    pendingCropAfterCamera = false
                    // 等待相机完全关闭后再打开裁切
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if imageToCrop != nil {
                            showingCropView = true
                        }
                    }
                }
            }
            .fullScreenCover(isPresented: $showingCropView) {
                if let image = imageToCrop {
                    // 这里是 `pickedNewImage` 唯一的写入点。裁切页的「取消」不回调，
                    // 于是「选了图又反悔」什么都不会留下 —— 用户接着去裁现有封面时，
                    // 那仍然是一次「只裁封面」，碰不到 PatternSourceStore 里那份原图。
                    ImageCropView(image: image) { croppedImage in
                        editedImage = croppedImage
                        pickedNewImage = pendingCropIsNewImage
                        imageToCrop = nil
                    }
                } else {
                    // 如果没有图片，立即关闭
                    Color.black.onAppear {
                        showingCropView = false
                    }
                }
            }
            .fullScreenCover(isPresented: $showingCamera) {
                CameraView { capturedImage in
                    if let image = capturedImage {
                        imageToCrop = image
                        // 拍照同样是**换了一张图**：拍完这张，库里那份属于上一张图的原图就作废了。
                        pendingCropIsNewImage = true
                        pendingCropAfterCamera = true
                    }
                }
            }
        }
        .haptic(.success, trigger: saveSuccessAt)
        .alert("图片处理失败", isPresented: $encodeFailed) {
            Button("好", role: .cancel) { }
        } message: {
            Text("这张图片无法处理，原有图片已保留。请重试或换一张图片。")
        }
        .task {
            storedSourceExists = PatternSourceStore.exists(for: projectId)
            storedSourceBytes = PatternSourceStore.byteSize(for: projectId)
            if storedSourceExists { keepPatternSource = true }
            initialKeepPatternSource = keepPatternSource
        }
        .presentationDetents([.medium, .large])
    }

    /// 这次保存对 `PatternSourceStore` 里那份原图做什么。
    ///
    /// **只裁了封面就一个字节都不动。** 这一屏手上那张封面是**压缩过的**（预算见
    /// `ProjectImageEncoder`），拿它的裁切结果去覆盖那份全分辨率原图，等于把用户的原图
    /// 降一档画质，而且不可逆（原图不进 iCloud、不进备份，覆盖了就没了）。
    /// 用户报的就是这个：改完封面进拼图模式，图糊成了封面那样。
    private func applyPatternSourceDecision() {
        guard pickedNewImage else {
            // 库里那份仍然是这张图纸的原图 —— 除非用户明说不留，那删掉正是他的意思。
            if !keepPatternSource { PatternSourceStore.remove(for: projectId) }
            return
        }
        // 换了图：库里那份是**上一张**图的。要么被新的盖掉，要么必须删 ——
        // 留着比没有更糟：拼图模式优先读它，用户换完封面进去看到的还是上一张照片，
        // 而且尺寸没变，那边「换过图就作废网格」的检查（宽高比）也拦不住。
        let wroteNewSource = keepPatternSource
            && PatternSourceStore.lossless(editedImage).map { PatternSourceStore.save($0, for: projectId) } == true
        if !wroteNewSource { PatternSourceStore.remove(for: projectId) }
    }

    /// 「保留原图」那一行的说明文字。三种处境说三句不同的话 ——
    /// 同一句「这张图纸将无法使用拼图模式」套在「删掉已有原图」上是不对的：
    /// 删掉之后拼图模式照样能用，只是退回用封面、看格子糊一些。
    private var keepPatternSourceHint: String {
        if keepPatternSource {
            return "拼图模式需要原图才能看清每一格的颜色。原图保存在本机，不占用 iCloud，拼完后可以删除。"
        }
        if storedSourceExists && !pickedNewImage {
            return "会删掉本机存的这份原图。拼图模式仍然能用，但只能用封面，一格豆子的像素少一半。"
        }
        return "这张图纸将无法使用拼图模式。以后需要时，可以在拼图模式里重新选择原图。"
    }

    /// 这个项目在拼图 / 多零件模式里已经有对好的东西（网格，或者零件摆位）。
    ///
    /// 单列取字节、不解码（两列都是 blob，不限定单列会把同行的封面也一起物化）。
    /// **读不出来按「有」算**：`fetchProject*Data` 那两个便利版把读失败和「本来就没有」
    /// 混成同一个 nil（见 `InventoryManager.BlobFetchFailure`），而这里拿它决定要不要
    /// 拦下一次不可逆的写入 —— 猜错只多问一句，猜反了是用户几十分钟的标定无声作废。
    private func hasStoredPatternWork() -> Bool {
        hasBlob(inventoryManager.fetchProjectPatternGridDataResult(for: projectId))
            || hasBlob(inventoryManager.fetchProjectPartsSheetDataResult(for: projectId))
    }

    private func hasBlob(_ result: Result<Data?, InventoryManager.BlobFetchFailure>) -> Bool {
        switch result {
        case .success(let data): return data != nil
        case .failure: return true
        }
    }

    /// 这次保存会不会让已经对好的图纸对不上。
    ///
    /// 判据只有一个：**存完之后拼图模式手上那张图，还是不是当初对格子的那张。**
    /// 两种模式都是原图优先、没有才退回封面（`SinglePatternFlowView.load`、
    /// `PartsSheetFlowView.load`），所以：
    ///   - 换了新图                → 图纸都换了，一定对不上
    ///   - 只裁封面 + 原图原样留着   → 读的还是那份原图，**完全不受影响**（PR #81 修的就是这条）
    ///   - 只裁封面 + 这次要删掉原图 → 存完只剩裁过的封面，坐标全偏
    ///   - 只裁封面 + 本来就没有原图 → 坐标是相对封面的，取景一改就废
    private func patternWorkWouldBreak() -> Bool {
        guard savesPatternSource, editedImage != nil else { return false }
        if !pickedNewImage, keepPatternSource, storedSourceExists { return false }
        return hasStoredPatternWork()
    }

    /// 「移除图片」按下去。移除封面之后这个项目可能连一张图都不剩，
    /// 那已经对好的图纸就没有任何东西可以对照了 —— 这种时候先问一句。
    /// 原图还在的话不问：拼图模式读的是它，封面没了也照样能用。
    private func attemptRemoveImage() {
        if savesPatternSource, !storedSourceExists, hasStoredPatternWork() {
            pendingWrite = .removeImage
        } else {
            performRemoveImage()
        }
    }

    private func performRemoveImage() {
        onSave(nil)
        dismiss()
    }

    /// 真正落盘。从「保存」按钮里拆出来，是因为它前面多了一道确认。
    private func performSave() {
        // 图没改就不重写封面 —— 用户只拨了「保留原图」开关时，把同一张图重编码再写回去
        // 是白写一整行（inline blob，改一列 SQLite 要重写整条记录）。
        if editedImage != nil, let image = displayImage {
            // **编码失败绝不能落到 onSave**。`onSave` 的参数是 `Data?`，而
            // `nil` 已经被上面的「移除图片」按钮占用了含义（`onSave(nil)`
            // → `_setProjectBlobsDirectly(.some(nil))` → `sd.thumbnail = nil`）。
            // 也就是说「编码失败」和「用户要求删图」在这条链路上无法区分：
            // 用户给一个已有照片的项目换图、编码失败 → 现存照片被清空，
            // 而下一行还会放成功反馈。用户看到「已保存」，照片没了。
            //
            // 这正是归档分支被双审否掉的那个形状（写入层知道自己失败了，
            // 上面每一层硬编码成功），所以这里必须挡住。
            guard let imageData = generateImageData(from: image) else {
                AppLogger.shared.error("ProjectImageEditor", "encode_failed_keeping_existing", metadata: [
                    "pixelSize": "\(image.size)"
                ])
                encodeFailed = true
                return   // 不写库、不放成功反馈、不关闭 sheet
            }
            onSave(imageData)
        }
        // 放在封面之后：封面存成功才动原图，避免留下对不上号的孤儿文件。
        if savesPatternSource { applyPatternSourceDecision() }
        saveSuccessAt = Date()
        dismiss()
    }

    /// 生成落盘用的图片数据。
    ///
    /// **分辨率原样保留**（拼图模式需要它做网格识别），只把编码从无损 PNG 换成高质量 JPEG。
    /// 理由同 `ScanView.generateThumbnailData` —— 无损 PNG 是把 SQLite 库撑到 GB 级、
    /// 进而触发 scene-create 看门狗的根因。细节见 `ProjectImageEncoder` 头注释。
    func generateImageData(from image: UIImage) -> Data? {
        return ProjectImageEncoder.encode(image)
    }
}

// MARK: - 相机视图
struct CameraView: UIViewControllerRepresentable {
    let onCapture: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage?) -> Void

        init(onCapture: @escaping (UIImage?) -> Void) {
            self.onCapture = onCapture
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            picker.dismiss(animated: true) {
                self.onCapture(image)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true) {
                self.onCapture(nil)
            }
        }
    }
}

#Preview {
    NavigationStack {
        ProjectDetailView(
            project: ProjectRecord(
                name: "测试项目",
                date: Date(),
                beadUsage: [
                    BeadUsage(colorCode: "A01", quantity: 100, isDeducted: true),
                    BeadUsage(colorCode: "B02", quantity: 50, isDeducted: false),
                    BeadUsage(colorCode: "C03", quantity: 200, isDeducted: true)
                ],
                brandId: nil
            )
        )
        .environmentObject(InventoryManager())
    }
}
