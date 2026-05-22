//
//  CalendarView.swift
//  BeadInventory
//
//  成品日历 —— 二级页骨架（SecondaryNav + ScrollView + GroupCard）。
//  入口图标色 = sage，本页 flavor 跟随。
//

import SwiftUI

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
    private let weekdays = ["一", "二", "三", "四", "五", "六", "日"]

    /// 完成日期 -> 项目
    private var projectsByDate: [Date: [ProjectRecord]] {
        let projects = inventoryManager.projects.filter { $0.finishedImage != nil && $0.completedDate != nil }
        var grouped: [Date: [ProjectRecord]] = [:]
        for project in projects {
            if let completedDate = project.completedDate {
                let dayStart = calendar.startOfDay(for: completedDate)
                grouped[dayStart, default: []].append(project)
            }
        }
        return grouped
    }

    /// 本月所有项目（用于月度统计 hero）
    private var monthProjects: [ProjectRecord] {
        projectsByDate.compactMap { (key, value) -> [ProjectRecord]? in
            if calendar.isDate(key, equalTo: currentMonth, toGranularity: .month) { return value }
            return nil
        }.flatMap { $0 }
    }

    private var monthTotalBeads: Int {
        monthProjects.reduce(0) { $0 + $1.totalBeads }
    }

    private var monthRepresentativeColors: [Color] {
        var seen: Set<String> = []
        var result: [Color] = []
        for project in monthProjects {
            for usage in project.beadUsage {
                if seen.contains(usage.colorCode) { continue }
                seen.insert(usage.colorCode)
                if let color = inventoryManager.beadColors.first(where: { $0.mardCode == usage.colorCode }) {
                    result.append(color.color)
                    if result.count >= 4 { return result }
                }
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            BISecondaryNav(title: "成品日历")
            ScrollView {
                VStack(spacing: 14) {
                    monthNavBar
                    monthStatsHero
                    calendarBlock
                    tipPill
                }
                .padding(.bottom, 24)
            }
        }
        .background(Theme.ColorToken.Surface.background)
        .navigationBarHidden(true)
        .sheet(item: $selectedDay) { selection in
            DayDetailSheet(date: selection.date, projects: selection.projects)
        }
    }

    // MARK: - Month nav

    private var monthNavBar: some View {
        HStack {
            monthNavButton(systemImage: "chevron.left") {
                withAnimation {
                    currentMonth = calendar.date(byAdding: .month, value: -1, to: currentMonth) ?? currentMonth
                }
            }
            Spacer()
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(monthYearString(from: currentMonth))
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.ColorToken.Text.primary)
                Text("· 完成 \(monthProjects.count) 件")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
            }
            Spacer()
            monthNavButton(systemImage: "chevron.right") {
                withAnimation {
                    currentMonth = calendar.date(byAdding: .month, value: 1, to: currentMonth) ?? currentMonth
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.ColorToken.Surface.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
        )
        .padding(.horizontal, 18)
        .padding(.top, 4)
    }

    private func monthNavButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ColorToken.Morandi.sage)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Theme.ColorToken.Morandi.sage.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Monthly stats hero

    private var monthStatsHero: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("本月完成")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text("\(monthProjects.count)")
                        .font(.system(size: 22, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.ColorToken.Morandi.sage)
                    Text("件 · 共 \(monthTotalBeads.formatted(.number)) 颗")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                }
            }
            Spacer()
            miniBeadCluster(colors: monthRepresentativeColors)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(
                    LinearGradient(
                        colors: [
                            Theme.ColorToken.Morandi.sage.opacity(0.10),
                            Theme.ColorToken.Morandi.honey.opacity(0.10)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
        )
        .padding(.horizontal, 18)
    }

    private func miniBeadCluster(colors: [Color]) -> some View {
        HStack(spacing: -10) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                BeadView(color: color, size: 26)
                    .overlay(
                        Circle().strokeBorder(Theme.ColorToken.Surface.elevated, lineWidth: 2)
                    )
            }
            // 占位（少于 4 个时拿默认色补）
            if colors.isEmpty {
                ForEach(Array([Theme.ColorToken.Morandi.sage, Theme.ColorToken.Morandi.latte, Theme.ColorToken.Morandi.rose].enumerated()), id: \.offset) { _, color in
                    BeadView(color: color, size: 26)
                        .overlay(
                            Circle().strokeBorder(Theme.ColorToken.Surface.elevated, lineWidth: 2)
                        )
                        .opacity(0.4)
                }
            }
        }
    }

    // MARK: - Calendar grid

    private var calendarBlock: some View {
        VStack(spacing: 8) {
            // 周历头
            HStack(spacing: 4) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { idx, d in
                    Text(d)
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(idx >= 5 ? Theme.ColorToken.Text.tertiary : Theme.ColorToken.Text.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 0)

            // 网格卡
            VStack {
                let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(Array(generateDaysInMonth().enumerated()), id: \.offset) { _, date in
                        if let date {
                            DayCell(
                                date: date,
                                projects: projectsForDate(date),
                                isToday: calendar.isDateInToday(date),
                                isCurrentMonth: calendar.isDate(date, equalTo: currentMonth, toGranularity: .month),
                                inventoryManager: inventoryManager
                            )
                            .onTapGesture {
                                let dayProjects = projectsForDate(date)
                                if !dayProjects.isEmpty {
                                    selectedDay = DaySelection(date: date, projects: dayProjects)
                                }
                            }
                        } else {
                            Color.clear.frame(height: 44)
                        }
                    }
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Theme.ColorToken.Surface.elevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
            )
        }
        .padding(.horizontal, 18)
    }

    // MARK: - Tip

    private var tipPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12))
                .foregroundStyle(Theme.ColorToken.Morandi.honey)
            Text("点击日期查看当天完成的拼豆作品")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.ColorToken.Text.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.ColorToken.Surface.subtle)
        )
        .padding(.horizontal, 18)
    }

    // MARK: - Helpers

    private func monthYearString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy.MM"
        return formatter.string(from: date)
    }

    private func generateDaysInMonth() -> [Date?] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: currentMonth),
              let monthFirstWeek = calendar.dateInterval(of: .weekOfMonth, for: monthInterval.start)
        else { return [] }
        var days: [Date?] = []
        var currentDate = monthFirstWeek.start
        let weekday = calendar.component(.weekday, from: currentDate)
        let daysToMonday = (weekday == 1) ? -6 : (2 - weekday)
        currentDate = calendar.date(byAdding: .day, value: daysToMonday, to: currentDate) ?? currentDate
        for _ in 0..<42 {
            days.append(currentDate)
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate) ?? currentDate
        }
        return days
    }

    private func projectsForDate(_ date: Date) -> [ProjectRecord] {
        projectsByDate[calendar.startOfDay(for: date)] ?? []
    }
}

// MARK: - Day cell

private struct DayCell: View {
    let date: Date
    let projects: [ProjectRecord]
    let isToday: Bool
    let isCurrentMonth: Bool
    let inventoryManager: InventoryManager

    private let calendar = Calendar.current

    private var dayNumber: Int { calendar.component(.day, from: date) }
    private var hasProjects: Bool { !projects.isEmpty }

    /// 当天最多取 3 种代表色用作圆点
    private var dotColors: [Color] {
        var seen: Set<String> = []
        var result: [Color] = []
        for project in projects {
            for usage in project.beadUsage {
                if seen.contains(usage.colorCode) { continue }
                seen.insert(usage.colorCode)
                if let bc = inventoryManager.beadColors.first(where: { $0.mardCode == usage.colorCode }) {
                    result.append(bc.color)
                    if result.count >= 3 { return result }
                }
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 3) {
            Text("\(dayNumber)")
                .font(.system(size: 13, weight: isToday ? .bold : .medium, design: .monospaced))
                .foregroundStyle(numberColor)
            if hasProjects {
                HStack(spacing: 2) {
                    ForEach(Array(dotColors.enumerated()), id: \.offset) { _, color in
                        Circle()
                            .fill(color)
                            .frame(width: 5, height: 5)
                            .overlay(
                                Circle().strokeBorder(isToday ? Color.white.opacity(0.6) : Color.clear, lineWidth: 0.8)
                            )
                    }
                }
                .frame(height: 6)
            } else {
                Spacer().frame(height: 6)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(cellFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(cellStroke, lineWidth: hasProjects && !isToday ? 1 : 0)
        )
    }

    private var numberColor: Color {
        if !isCurrentMonth { return Theme.ColorToken.Text.tertiary.opacity(0.55) }
        if isToday { return .white }
        if hasProjects { return Theme.ColorToken.Text.primary }
        return Theme.ColorToken.Text.tertiary
    }

    private var cellFill: Color {
        if isToday { return Theme.ColorToken.Morandi.sage }
        if hasProjects { return Theme.ColorToken.Morandi.sage.opacity(0.10) }
        return .clear
    }

    private var cellStroke: Color {
        hasProjects && !isToday ? Theme.ColorToken.Morandi.sage.opacity(0.4) : .clear
    }
}

// MARK: - Day detail sheet

struct DayDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let date: Date
    let projects: [ProjectRecord]

    private let calendar = Calendar.current

    private var totalBeads: Int { projects.reduce(0) { $0 + $1.totalBeads } }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Theme.ColorToken.Border.default)
                .frame(width: 40, height: 4)
                .padding(.top, 6)
                .padding(.bottom, 14)

            headerCard
                .padding(.horizontal, 22)
                .padding(.bottom, 18)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(projects) { project in
                        DayProjectCard(project: project)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 30)
            }
        }
        .background(Theme.ColorToken.Surface.background)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }

    private var headerCard: some View {
        HStack(spacing: 14) {
            VStack(spacing: 0) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                Text(weekdayText)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.top, 1)
            }
            .frame(width: 56, height: 56)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            colors: [Theme.ColorToken.Morandi.sage, Theme.ColorToken.Morandi.honey],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(dateString)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.ColorToken.Text.primary)
                HStack(spacing: 2) {
                    Text("完成 ")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                    Text("\(projects.count)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.ColorToken.Text.primary)
                    Text(" 件 · 共 ")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                    Text("\(totalBeads.formatted(.number))")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.ColorToken.Text.primary)
                    Text(" 颗")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ColorToken.Text.secondary)
                }
            }
            Spacer()
        }
    }

    private var dateString: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy 年 M 月 d 日"
        return f.string(from: date)
    }

    private var weekdayText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "EEE"
        return f.string(from: date)
    }
}

// MARK: - Day project card

private struct DayProjectCard: View {
    let project: ProjectRecord
    @State private var showingFullImage = false

    var body: some View {
        HStack(spacing: 12) {
            if let imageData = project.finishedImage,
               let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onTapGesture { showingFullImage = true }
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.ColorToken.Surface.subtle)
                    .frame(width: 64, height: 64)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ColorToken.Text.primary)
                Text("\(project.totalBeads.formatted(.number)) 颗")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                if let completed = project.completedDate {
                    Text(timeString(completed))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.ColorToken.Text.tertiary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ColorToken.Text.tertiary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Theme.ColorToken.Surface.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Theme.ColorToken.Border.default, lineWidth: 1)
        )
        .fullScreenCover(isPresented: $showingFullImage) {
            FullImageView(imageData: project.finishedImage)
        }
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

// MARK: - Full image cover (preserved)

struct FullImageView: View {
    @Environment(\.dismiss) var dismiss
    let imageData: Data?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let imageData, let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage).resizable().scaledToFit()
            }
        }
        .onTapGesture { dismiss() }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding()
        }
    }
}

#Preview {
    NavigationStack {
        CalendarView().environmentObject(InventoryManager())
    }
}
