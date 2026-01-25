//
//  CalendarView.swift
//  BeadInventory
//
//  日历视图 - 展示每天完成的成品图
//

import SwiftUI

// 用于传递给 sheet 的数据
struct DaySelection: Identifiable {
    let id = UUID()
    let date: Date
    let projects: [ProjectRecord]
}

struct CalendarView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @State private var currentMonth: Date = Date()
    @State private var selectedDay: DaySelection?

    private let calendar = Calendar.current
    private let weekdays = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    // 获取有成品图和完成日期的项目，按日期分组
    var projectsByDate: [Date: [ProjectRecord]] {
        let projects = inventoryManager.projects.filter { project in
            project.finishedImage != nil && project.completedDate != nil
        }

        var grouped: [Date: [ProjectRecord]] = [:]
        for project in projects {
            if let completedDate = project.completedDate {
                let dayStart = calendar.startOfDay(for: completedDate)
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
        ScrollView {
            VStack(spacing: 0) {
                // 月份导航
                monthHeader

                // 星期标题
                weekdayHeader

                // 日历网格
                calendarGrid
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("成品日历")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedDay) { selection in
            DayDetailSheet(date: selection.date, projects: selection.projects)
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

        return GeometryReader { geometry in
            let cellWidth = (geometry.size.width - 16 - 24) / 7  // 减去padding和间距
            let cellHeight = cellWidth  // 正方形格子

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(days, id: \.self) { date in
                    if let date = date {
                        DayCell(
                            date: date,
                            projects: projectsForDate(date),
                            isToday: calendar.isDateInToday(date),
                            isCurrentMonth: calendar.isDate(date, equalTo: currentMonth, toGranularity: .month)
                        )
                        .frame(width: cellWidth, height: cellHeight)
                        .onTapGesture {
                            let dayProjects = projectsForDate(date)
                            if !dayProjects.isEmpty {
                                selectedDay = DaySelection(date: date, projects: dayProjects)
                            }
                        }
                    } else {
                        Color.clear
                            .frame(width: cellWidth, height: cellHeight)
                    }
                }
            }
        }
        .frame(height: calculateGridHeight())
        .padding(.horizontal, 8)
    }

    // 计算日历网格高度
    private func calculateGridHeight() -> CGFloat {
        let screenWidth = UIScreen.main.bounds.width
        let cellWidth = (screenWidth - 16 - 24) / 7
        let numberOfRows: CGFloat = 6  // 固定6行
        let spacing: CGFloat = 4
        return (cellWidth * numberOfRows) + (spacing * (numberOfRows - 1))
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
            backgroundView
            dayNumberOverlay
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(cellBackground)
        .overlay(cellBorder)
        .cornerRadius(8)
    }

    // MARK: - 子视图

    @ViewBuilder
    private var backgroundView: some View {
        if let firstProject = projects.first,
           let imageData = firstProject.finishedImage,
           let uiImage = UIImage(data: imageData) {
            GeometryReader { geometry in
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            }
            .overlay(countBadge, alignment: .topTrailing)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var countBadge: some View {
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
    }

    @ViewBuilder
    private var dayNumberOverlay: some View {
        if hasFinishedImage {
            // 有图片时，数字显示在左下角
            VStack {
                Spacer()
                HStack {
                    dayNumberBadge
                    Spacer()
                }
            }
        } else {
            // 无图片时，数字居中显示
            centeredDayNumber
        }
    }

    private var dayNumberBadge: some View {
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

    private var centeredDayNumber: some View {
        let textColor: Color = {
            if !isCurrentMonth {
                return .secondary.opacity(0.5)
            }
            return isToday ? .green : .primary
        }()

        return Text("\(dayNumber)")
            .font(.callout)
            .fontWeight(isToday ? .bold : .regular)
            .foregroundColor(textColor)
    }

    private var cellBackground: some View {
        let fillColor: Color = {
            if hasFinishedImage {
                return .clear
            }
            return isToday ? Color.green.opacity(0.1) : .clear
        }()

        return RoundedRectangle(cornerRadius: 8)
            .fill(fillColor)
    }

    private var cellBorder: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(isToday ? Color.green : Color.clear, lineWidth: 2)
    }
}

// MARK: - 日期详情弹窗
struct DayDetailSheet: View {
    @Environment(\.dismiss) var dismiss
    let date: Date
    let projects: [ProjectRecord]

    var body: some View {
        NavigationStack {
            Group {
                if projects.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 50))
                            .foregroundColor(.secondary)
                        Text("当天没有成品图")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(projects) { project in
                                ProjectImageCard(project: project)
                            }
                        }
                        .padding()
                    }
                }
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
