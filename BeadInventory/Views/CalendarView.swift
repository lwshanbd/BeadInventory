//
//  CalendarView.swift
//  BeadInventory
//
//  日历视图 - 展示每天完成的成品图
//

import SwiftUI

struct CalendarView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var currentMonth: Date = Date()
    @State private var selectedDate: Date?
    @State private var showingDayDetail = false

    private let calendar = Calendar.current
    private let weekdays = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    // 获取当月有成品图的项目，按日期分组
    var projectsByDate: [Date: [ProjectRecord]] {
        let projects = inventoryManager.projects.filter { project in
            project.finishedImage != nil && project.executedDate != nil
        }

        var grouped: [Date: [ProjectRecord]] = [:]
        for project in projects {
            if let executedDate = project.executedDate {
                let dayStart = calendar.startOfDay(for: executedDate)
                if grouped[dayStart] != nil {
                    grouped[dayStart]?.append(project)
                } else {
                    grouped[dayStart] = [project]
                }
            }
        }
        return grouped
    }

    var body: some View {
        VStack(spacing: 0) {
            // 月份导航
            monthHeader

            // 星期标题
            weekdayHeader

            // 日历网格
            calendarGrid

            Spacer()
        }
        .navigationTitle("成品日历")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingDayDetail) {
            if let date = selectedDate {
                DayDetailSheet(date: date, projects: projectsForDate(date))
            }
        }
    }

    // MARK: - 月份导航
    private var monthHeader: some View {
        HStack {
            Button {
                withAnimation {
                    currentMonth = calendar.date(byAdding: .month, value: -1, to: currentMonth) ?? currentMonth
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title2)
                    .foregroundColor(.accentColor)
            }

            Spacer()

            Text(monthYearString(from: currentMonth))
                .font(.title2)
                .fontWeight(.bold)

            Spacer()

            Button {
                withAnimation {
                    currentMonth = calendar.date(byAdding: .month, value: 1, to: currentMonth) ?? currentMonth
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.title2)
                    .foregroundColor(.accentColor)
            }
        }
        .padding()
    }

    // MARK: - 星期标题
    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(weekdays, id: \.self) { day in
                Text(day)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    // MARK: - 日历网格
    private var calendarGrid: some View {
        let days = generateDaysInMonth()
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(days, id: \.self) { date in
                if let date = date {
                    DayCell(
                        date: date,
                        projects: projectsForDate(date),
                        isToday: calendar.isDateInToday(date),
                        isCurrentMonth: calendar.isDate(date, equalTo: currentMonth, toGranularity: .month)
                    )
                    .onTapGesture {
                        let dayProjects = projectsForDate(date)
                        if !dayProjects.isEmpty {
                            selectedDate = date
                            showingDayDetail = true
                        }
                    }
                } else {
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                }
            }
        }
        .padding(.horizontal, 8)
    }

    // MARK: - 辅助方法

    private func monthYearString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月"
        return formatter.string(from: date)
    }

    private func generateDaysInMonth() -> [Date?] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: currentMonth),
              let monthFirstWeek = calendar.dateInterval(of: .weekOfMonth, for: monthInterval.start)
        else { return [] }

        var days: [Date?] = []
        var currentDate = monthFirstWeek.start

        // 调整到周一开始
        let weekday = calendar.component(.weekday, from: currentDate)
        let daysToMonday = (weekday == 1) ? -6 : (2 - weekday)
        currentDate = calendar.date(byAdding: .day, value: daysToMonday, to: currentDate) ?? currentDate

        // 生成6周的日期（42天）
        for _ in 0..<42 {
            days.append(currentDate)
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate) ?? currentDate
        }

        return days
    }

    private func projectsForDate(_ date: Date) -> [ProjectRecord] {
        let dayStart = calendar.startOfDay(for: date)
        return projectsByDate[dayStart] ?? []
    }
}

// MARK: - 日期格子
struct DayCell: View {
    let date: Date
    let projects: [ProjectRecord]
    let isToday: Bool
    let isCurrentMonth: Bool

    private let calendar = Calendar.current

    var dayNumber: Int {
        calendar.component(.day, from: date)
    }

    var hasFinishedImage: Bool {
        !projects.isEmpty && projects.first?.finishedImage != nil
    }

    var body: some View {
        ZStack {
            // 背景：成品图或空白
            if let firstProject = projects.first,
               let imageData = firstProject.finishedImage,
               let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .clipped()
                    .overlay(
                        // 多个项目时显示数量角标
                        Group {
                            if projects.count > 1 {
                                Text("+\(projects.count - 1)")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundColor(.white)
                                    .padding(3)
                                    .background(Color.red)
                                    .cornerRadius(4)
                                    .padding(2)
                            }
                        },
                        alignment: .topTrailing
                    )
            } else {
                Color.clear
            }

            // 日期数字
            VStack {
                Spacer()
                HStack {
                    if hasFinishedImage {
                        // 有图片时，数字显示在左下角带背景
                        Text("\(dayNumber)")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(4)
                            .background(
                                Circle()
                                    .fill(isToday ? Color.green : Color.black.opacity(0.6))
                            )
                            .padding(2)
                    }
                    Spacer()
                }
            }

            // 无图片时，数字居中显示
            if !hasFinishedImage {
                Text("\(dayNumber)")
                    .font(.callout)
                    .fontWeight(isToday ? .bold : .regular)
                    .foregroundColor(isCurrentMonth ? (isToday ? .green : .primary) : .secondary.opacity(0.5))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hasFinishedImage ? Color.clear : (isToday ? Color.green.opacity(0.1) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isToday ? Color.green : Color.clear, lineWidth: 2)
        )
        .cornerRadius(8)
    }
}

// MARK: - 日期详情弹窗
struct DayDetailSheet: View {
    @Environment(\.dismiss) var dismiss
    let date: Date
    let projects: [ProjectRecord]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(projects) { project in
                        ProjectImageCard(project: project)
                    }
                }
                .padding()
            }
            .navigationTitle(dateString(from: date))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func dateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }
}

// MARK: - 项目图片卡片
struct ProjectImageCard: View {
    let project: ProjectRecord
    @State private var showingFullImage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 成品图
            if let imageData = project.finishedImage,
               let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .cornerRadius(12)
                    .onTapGesture {
                        showingFullImage = true
                    }
            }

            // 项目名称
            HStack {
                Text(project.name)
                    .font(.headline)

                Spacer()

                Text("\(project.totalBeads) 颗")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
        .fullScreenCover(isPresented: $showingFullImage) {
            FullImageView(imageData: project.finishedImage)
        }
    }
}

// MARK: - 全屏图片查看
struct FullImageView: View {
    @Environment(\.dismiss) var dismiss
    let imageData: Data?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let imageData = imageData,
               let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
            }
        }
        .onTapGesture {
            dismiss()
        }
        .overlay(
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundColor(.white.opacity(0.8))
            }
            .padding(),
            alignment: .topTrailing
        )
    }
}

#Preview {
    NavigationStack {
        CalendarView()
            .environmentObject(InventoryManager())
    }
}
