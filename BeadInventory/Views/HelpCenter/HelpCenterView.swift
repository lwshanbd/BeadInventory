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
    @State private var didNavigateInitial = false

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
        .navigationTitle("help.center.title")
        .searchable(text: $searchText, prompt: Text("help.center.search.prompt"))
        .navigationDestination(isPresented: $didNavigateInitial) {
            if let dest = initialDestination {
                dest.targetView
            }
        }
        .onAppear {
            if initialDestination != nil && !didNavigateInitial {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    didNavigateInitial = true
                }
            }
        }
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
                        .foregroundColor(Theme.ColorToken.Morandi.latte)
                }
            }
        }

        Section {
            NavigationLink {
                FAQView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("help.center.faq.title")
                        Text("help.center.faq.subtitle")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } icon: {
                    Image(systemName: "questionmark.circle.fill")
                        .foregroundColor(Theme.ColorToken.Status.warning)
                }
            }
        }
    }

    // MARK: - 搜索结果

    @ViewBuilder
    private var searchResultsList: some View {
        if !searchResults.isEmpty {
            Section("help.center.section.tutorials") {
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
            Section("help.center.faq.title") {
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HelpCenterView(initialDestination: initialDestination)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("help.center.done") {
                            dismiss()
                        }
                    }
                }
        }
    }
}
