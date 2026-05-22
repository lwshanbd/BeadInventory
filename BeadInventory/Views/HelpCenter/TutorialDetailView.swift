//
//  TutorialDetailView.swift
//  BeadInventory
//
//  通用教程详情页
//

import SwiftUI

struct TutorialDetailView: View {
    let section: TutorialSection
    var highlightStep: HelpDestination? = nil

    @State private var highlightedStepId: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 12) {
                        Image(systemName: section.icon)
                            .font(.title)
                            .foregroundColor(Theme.ColorToken.Morandi.latte)
                            .frame(width: 44, height: 44)
                            .background(Theme.ColorToken.Morandi.latte.opacity(0.1))
                            .cornerRadius(Theme.Radius.md)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.localizedTitle)
                                .font(.title2)
                                .fontWeight(.bold)
                            Text(section.localizedSubtitle)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)

                    ForEach(Array(section.steps.enumerated()), id: \.element.id) { index, step in
                        StepCardView(step: step, index: index + 1, isHighlighted: step.id == highlightedStepId)
                            .id(step.id)
                    }
                }
                .padding(.bottom, 32)
            }
            .onAppear {
                scrollToHighlight(proxy: proxy)
            }
        }
        .navigationTitle(section.localizedTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func scrollToHighlight(proxy: ScrollViewProxy) {
        guard let highlight = highlightStep else { return }

        let targetStep = section.steps.first { $0.anchor == highlight }

        if let step = targetStep {
            highlightedStepId = step.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation {
                    proxy.scrollTo(step.id, anchor: .top)
                }
            }
        }
    }
}

// MARK: - 步骤卡片

struct StepCardView: View {
    let step: TutorialStep
    let index: Int
    var isHighlighted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text("\(index)")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .frame(width: 24, height: 24)
                    .background(Theme.ColorToken.Morandi.latte)
                    .cornerRadius(Theme.Radius.md)

                VStack(alignment: .leading, spacing: 6) {
                    Text(step.localizedTitle)
                        .font(.headline)

                    Text(step.localizedDescription)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let imageName = step.imageName {
                Image(imageName)
                    .resizable()
                    .scaledToFit()
                    .cornerRadius(Theme.Radius.md)
                    .padding(.leading, 36)
            }

            if let action = step.action {
                NavigationLink {
                    action.destination.targetView
                } label: {
                    HStack(spacing: 4) {
                        Text(String(localized: String.LocalizationValue(action.labelKey)))
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                    }
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(Theme.ColorToken.Morandi.latte)
                }
                .padding(.leading, 36)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(isHighlighted ? Theme.ColorToken.Morandi.latte.opacity(0.08) : Theme.ColorToken.Surface.subtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(isHighlighted ? Theme.ColorToken.Morandi.latte.opacity(0.3) : Color.clear, lineWidth: 1.5)
        )
        .padding(.horizontal)
    }

}
