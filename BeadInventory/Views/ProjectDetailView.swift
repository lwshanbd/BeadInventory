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
    /// 在模式选择页里选了「单图纸模式」，等它收起后再进下一页（见 openSinglePatternModeIfSelected）
    @State private var pendingSinglePatternMode = false
    @State private var showingPatternCalibration = false
    @State private var showingPatternHighlight = false

    /// 单图纸模式沿用原来的分支：已标定过网格直接进高亮页，没标定先去标定页。
    private func openSinglePatternModeIfSelected() {
        guard pendingSinglePatternMode else { return }
        pendingSinglePatternMode = false
        let projectId = (currentProject ?? project).id
        if inventoryManager.projectIDsWithPatternGrid.contains(projectId) {
            showingPatternHighlight = true
        } else {
            showingPatternCalibration = true
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
        .sheet(isPresented: $showingPatternModePicker, onDismiss: openSinglePatternModeIfSelected) {
            PatternModeSelectionSheet(onSelectSinglePattern: { pendingSinglePatternMode = true })
        }
        .sheet(isPresented: $showingPatternCalibration) {
            PatternCalibrationView(
                project: currentProject ?? project,
                onComplete: { showingPatternHighlight = true }
            )
            .environmentObject(inventoryManager)
        }
        .fullScreenCover(isPresented: $showingPatternHighlight) {
            if let p = inventoryManager.projects.first(where: { $0.id == project.id }) {
                PatternHighlightView(project: p)
                    .environmentObject(inventoryManager)
            }
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
    let onSave: (Data?) -> Void

    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var inventoryManager: InventoryManager

    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var editedImage: UIImage?
    @State private var isLoadingImage = false
    @State private var showingCropView = false
    @State private var imageToCrop: UIImage?
    @State private var showingCamera = false
    @State private var pendingCropAfterCamera = false  // 相机关闭后需要打开裁切
    @State private var saveSuccessAt: Date = .distantPast
    /// 编码失败时置位。失败必须可见 —— 静默失败会让用户以为图存上了。
    @State private var encodeFailed = false

    var displayImage: UIImage? {
        editedImage ?? currentImage
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
                        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
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
                                editedImage = nil
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

                    // 移除按钮（仅当有当前图片时显示）
                    if currentImage != nil || editedImage != nil {
                        Button {
                            onSave(nil)
                            dismiss()
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
                        if let image = displayImage {
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
                            saveSuccessAt = Date()
                        }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(editedImage == nil && currentImage == displayImage)
                }
            }
            .onChange(of: selectedPhotoItem) { _, newItem in
                if let newItem = newItem {
                    isLoadingImage = true
                    Task {
                        if let data = try? await newItem.loadTransferable(type: Data.self),
                           let image = UIImage(data: data) {
                            await MainActor.run {
                                imageToCrop = image
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
                    ImageCropView(image: image) { croppedImage in
                        editedImage = croppedImage
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
        .presentationDetents([.medium, .large])
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
