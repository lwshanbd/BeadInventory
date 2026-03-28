//
//  HelpCenterView.swift
//  BeadInventory
//
//  帮助中心主页面
//

import SwiftUI

struct HelpCenterView: View {
    var initialDestination: HelpDestination? = nil

    @State private var searchText = ""

    private var searchResults: [TutorialStep] {
        TutorialContent.search(query: searchText)
    }

    private var faqResults: [FAQItem] {
        TutorialContent.searchFAQ(query: searchText)
    }

    var body: some View {
        List {
            if searchText.isEmpty {
                sectionList
            } else {
                searchResultsList
            }
        }
        .navigationTitle("帮助与教程")
        .searchable(text: $searchText, prompt: "搜索帮助内容")
    }

    // MARK: - Section 列表

    @ViewBuilder
    private var sectionList: some View {
        ForEach(TutorialContent.sections) { section in
            NavigationLink {
                TutorialDetailView(section: section)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.localizedTitle)
                        Text(section.localizedSubtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } icon: {
                    Image(systemName: section.icon)
                        .foregroundColor(.accentColor)
                }
            }
        }

        Section {
            NavigationLink {
                FAQView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("常见问题")
                        Text("解答你的疑惑")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } icon: {
                    Image(systemName: "questionmark.circle.fill")
                        .foregroundColor(.orange)
                }
            }
        }
    }

    // MARK: - 搜索结果

    @ViewBuilder
    private var searchResultsList: some View {
        if !searchResults.isEmpty {
            Section("教程") {
                ForEach(searchResults) { step in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(step.localizedTitle)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(step.localizedDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 2)
                }
            }
        }

        if !faqResults.isEmpty {
            Section("常见问题") {
                ForEach(faqResults) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.localizedQuestion)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(item.localizedAnswer)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 2)
                }
            }
        }

        if searchResults.isEmpty && faqResults.isEmpty {
            ContentUnavailableView.search(text: searchText)
        }
    }
}

// MARK: - 帮助中心导航容器（用于 sheet 弹出场景）

struct HelpCenterNavigationView: View {
    var initialDestination: HelpDestination? = nil

    var body: some View {
        NavigationStack {
            HelpCenterView(initialDestination: initialDestination)
        }
    }
}
