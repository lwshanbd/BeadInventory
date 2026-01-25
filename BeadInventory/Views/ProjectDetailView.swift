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
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
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
                        .foregroundColor(.accentColor)
                    }
                }
                .padding(.horizontal)

                // 颜色用量列表
                LazyVStack(spacing: 8) {
                    ForEach(sortedUsage) { usage in
                        BeadUsageRow(usage: usage)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingThumbnailEditor) {
            ProjectImageEditorSheet(
                projectId: project.id,
                title: "项目封面",
                currentImage: (currentProject ?? project).thumbnail.flatMap { UIImage(data: $0) },
                onSave: { imageData in
                    inventoryManager.updateProjectThumbnail(project.id, thumbnail: imageData)
                }
            )
            .environmentObject(inventoryManager)
        }
        .sheet(isPresented: $showingFinishedImageEditor) {
            ProjectImageEditorSheet(
                projectId: project.id,
                title: "成品图",
                currentImage: (currentProject ?? project).finishedImage.flatMap { UIImage(data: $0) },
                maxImageSize: 400, // 成品图使用更大尺寸
                onSave: { imageData in
                    inventoryManager.updateProjectFinishedImage(project.id, finishedImage: imageData)
                }
            )
            .environmentObject(inventoryManager)
        }
    }
}

// MARK: - 子项目行
struct ChildProjectRow: View {
    let project: ProjectRecord

    // 从 thumbnail Data 创建 UIImage
    var thumbnailImage: UIImage? {
        guard let data = project.thumbnail else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        HStack(spacing: 12) {
            // 缩略图（如果有）
            if let image = thumbnailImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
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
                    .foregroundColor(.accentColor)
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }
}

// MARK: - 带操作的子项目行
struct ChildProjectRowWithActions: View {
    let project: ProjectRecord
    let onDelete: () -> Void
    let onDetach: () -> Void

    // 从 thumbnail Data 创建 UIImage
    var thumbnailImage: UIImage? {
        guard let data = project.thumbnail else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        HStack(spacing: 12) {
            // 缩略图（如果有）
            if let image = thumbnailImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
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
                            .foregroundColor(.accentColor)
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
        .background(Color(.systemGray6))
        .cornerRadius(8)
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

    // 从 thumbnail Data 创建 UIImage
    var thumbnailImage: UIImage? {
        guard let data = project.thumbnail else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        VStack(spacing: 16) {
            // 缩略图区域
            ZStack(alignment: .topTrailing) {
                if let image = thumbnailImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                } else if onEditThumbnail != nil {
                    // 无图片时的占位符
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.1))
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
                if onEditThumbnail != nil && thumbnailImage != nil {
                    Button {
                        onEditThumbnail?()
                    } label: {
                        Image(systemName: "pencil.circle.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                            .background(Circle().fill(Color.accentColor))
                    }
                    .padding(8)
                }
            }

            // 日期和状态
            HStack {
                if isParent {
                    Label("父项目", systemImage: "folder.fill")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.1))
                        .cornerRadius(6)
                }

                Label(project.date.formatted(date: .long, time: .omitted), systemImage: "calendar")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()

                if project.isArchived {
                    Label("已归档", systemImage: "archivebox.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(6)
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
                            .foregroundColor(.orange)
                        Text("子项目")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                VStack(spacing: 4) {
                    Text("\(colorCount)")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.purple)
                    Text(isParent ? "总颜色" : "颜色数")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                VStack(spacing: 4) {
                    Text("\(totalBeads)")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.blue)
                    Text("总颗数")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let brandName = brandName {
                    VStack(spacing: 4) {
                        Text(brandName)
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.green)
                        Text("品牌")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }
}

// MARK: - 颜色用量行
struct BeadUsageRow: View {
    let usage: BeadUsage
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

    var body: some View {
        HStack(spacing: 12) {
            // 颜色预览
            RoundedRectangle(cornerRadius: 8)
                .fill(displayColor)
                .frame(width: 44, height: 44)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )

            // 色号和名称
            VStack(alignment: .leading, spacing: 4) {
                Text(usage.colorCode)
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
                    .foregroundColor(.green)
                    .font(.title3)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(10)
    }
}

// MARK: - 成品图展示区域
struct FinishedImageSection: View {
    let project: ProjectRecord
    let onEditFinishedImage: () -> Void
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var showingDatePicker = false
    @State private var selectedDate: Date = Date()

    var finishedImage: UIImage? {
        guard let data = project.finishedImage else { return nil }
        return UIImage(data: data)
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
                        Image(systemName: finishedImage == nil ? "photo.badge.plus" : "pencil")
                        Text(finishedImage == nil ? "上传成品图" : "修改")
                    }
                    .font(.caption)
                    .foregroundColor(.accentColor)
                }
            }

            if let image = finishedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
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
                                .foregroundColor(.accentColor)
                        } else {
                            Text("选择日期")
                                .foregroundColor(.accentColor)
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
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.1))
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
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .padding(.horizontal)
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
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                        .padding(.horizontal)
                } else {
                    // 空状态
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.1))
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
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(12)
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
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(12)
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
                                .background(Color.blue.opacity(0.1))
                                .foregroundColor(.blue)
                                .cornerRadius(12)
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
                                .background(Color.orange.opacity(0.1))
                                .foregroundColor(.orange)
                                .cornerRadius(12)
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
                            .foregroundColor(.red)
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
                            let imageData = generateImageData(from: image)
                            onSave(imageData)
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
        .presentationDetents([.medium, .large])
    }

    /// 生成压缩的图片数据
    func generateImageData(from image: UIImage) -> Data? {
        let scale = min(maxImageSize / image.size.width, maxImageSize / image.size.height, 1.0)
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return resizedImage?.jpegData(compressionQuality: 0.7)
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
