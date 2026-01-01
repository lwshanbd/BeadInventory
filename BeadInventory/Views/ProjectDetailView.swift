//
//  ProjectDetailView.swift
//  BeadInventory
//
//  项目详情视图 - 显示项目中各颜色的豆子用量
//

import SwiftUI

struct ProjectDetailView: View {
    let project: ProjectRecord
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var sortByQuantity = true
    @State private var showChildrenSection = true

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

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 项目信息卡片
                ProjectInfoCardEnhanced(
                    project: project,
                    brandName: brandName,
                    isParent: isParentProject,
                    colorCount: colorCount,
                    totalBeads: totalBeads,
                    childCount: childProjects.count
                )

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
    }
}

// MARK: - 子项目行
struct ChildProjectRow: View {
    let project: ProjectRecord

    var body: some View {
        HStack {
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

    var body: some View {
        HStack {
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

    var body: some View {
        VStack(spacing: 16) {
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
        inventoryManager.beadColors.first { $0.mardCode == usage.colorCode }
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
