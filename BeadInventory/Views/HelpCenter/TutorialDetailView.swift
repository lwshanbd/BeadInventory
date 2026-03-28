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
                    // 标题区域
                    HStack(spacing: 12) {
                        Image(systemName: section.icon)
                            .font(.title)
                            .foregroundColor(.accentColor)
                            .frame(width: 44, height: 44)
                            .background(Color.accentColor.opacity(0.1))
                            .cornerRadius(10)

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

                    // 步骤列表
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

        var targetStep: TutorialStep?
        switch highlight {
        case .scanAPISetup:
            targetStep = section.steps.first { $0.searchKeywords.contains("API") }
        case .scanCrop:
            targetStep = section.steps.first { $0.searchKeywords.contains("裁切") }
        default:
            break
        }

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
            // 步骤编号 + 标题
            HStack(alignment: .top, spacing: 12) {
                Text("\(index)")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .frame(width: 24, height: 24)
                    .background(Color.accentColor)
                    .cornerRadius(12)

                VStack(alignment: .leading, spacing: 6) {
                    Text(step.localizedTitle)
                        .font(.headline)

                    Text(step.localizedDescription)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // 教程图片
            if let imageName = step.imageName {
                Image(imageName)
                    .resizable()
                    .scaledToFit()
                    .cornerRadius(12)
                    .padding(.leading, 36)
            }

            // 操作按钮
            if let actionLabel = step.actionLabel, let dest = step.actionDestination {
                NavigationLink(value: dest) {
                    Text(String(localized: String.LocalizationValue(actionLabel)))
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.accentColor)
                }
                .padding(.leading, 36)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isHighlighted ? Color.accentColor.opacity(0.08) : Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isHighlighted ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1.5)
        )
        .padding(.horizontal)
    }
}
