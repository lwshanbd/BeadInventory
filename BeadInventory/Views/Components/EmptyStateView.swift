//
//  EmptyStateView.swift
//  BeadInventory
//
//  通用空状态视图组件
//

import SwiftUI

struct EmptyStateView: View {
    let icon: String
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    var actionLabel: LocalizedStringKey? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 60))
                .foregroundColor(.secondary.opacity(0.5))

            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)

            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if let actionLabel, let action {
                Button(action: action) {
                    Text(actionLabel)
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
