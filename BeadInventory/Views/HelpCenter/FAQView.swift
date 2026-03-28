//
//  FAQView.swift
//  BeadInventory
//
//  常见问题页面
//

import SwiftUI

struct FAQView: View {
    @State private var expandedItems: Set<UUID> = []

    var body: some View {
        List {
            ForEach(TutorialContent.faqItems) { item in
                FAQItemRow(item: item, isExpanded: expandedItems.contains(item.id)) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if expandedItems.contains(item.id) {
                            expandedItems.remove(item.id)
                        } else {
                            expandedItems.insert(item.id)
                        }
                    }
                }
            }
        }
        .navigationTitle("help.center.faq.title")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct FAQItemRow: View {
    let item: FAQItem
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack {
                    Text(item.localizedQuestion)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(item.localizedAnswer)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 4)
    }
}
