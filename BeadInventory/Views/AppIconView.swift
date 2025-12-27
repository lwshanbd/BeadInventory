//
//  AppIconView.swift
//  BeadInventory
//
//  App Logo 设计 - 用于生成 App Icon
//

import SwiftUI

struct AppIconView: View {
    let size: CGFloat

    init(size: CGFloat = 512) {
        self.size = size
    }

    var body: some View {
        ZStack {
            // 背景渐变
            LinearGradient(
                colors: [
                    Color(red: 0.4, green: 0.6, blue: 0.9),  // 柔和蓝色
                    Color(red: 0.6, green: 0.4, blue: 0.8)   // 柔和紫色
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // 珠子排列 - 3x3 网格
            VStack(spacing: size * 0.06) {
                ForEach(0..<3) { row in
                    HStack(spacing: size * 0.06) {
                        ForEach(0..<3) { col in
                            BeadShape(size: size * 0.22, row: row, col: col)
                        }
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
    }
}

struct BeadShape: View {
    let size: CGFloat
    let row: Int
    let col: Int

    // 不同位置的珠子颜色
    var beadColor: Color {
        let colors: [[Color]] = [
            [.red, .orange, .yellow],
            [.green, .cyan, .blue],
            [.purple, .pink, .white]
        ]
        return colors[row][col]
    }

    var body: some View {
        ZStack {
            // 珠子主体
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            beadColor.opacity(0.9),
                            beadColor,
                            beadColor.opacity(0.7)
                        ],
                        center: .init(x: 0.3, y: 0.3),
                        startRadius: 0,
                        endRadius: size * 0.6
                    )
                )
                .frame(width: size, height: size)

            // 高光效果
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            .white.opacity(0.8),
                            .white.opacity(0.0)
                        ],
                        center: .init(x: 0.3, y: 0.3),
                        startRadius: 0,
                        endRadius: size * 0.3
                    )
                )
                .frame(width: size * 0.6, height: size * 0.6)
                .offset(x: -size * 0.15, y: -size * 0.15)

            // 珠子孔
            Circle()
                .fill(Color.black.opacity(0.3))
                .frame(width: size * 0.15, height: size * 0.15)
        }
    }
}

// 用于预览和导出的视图
struct AppIconPreview: View {
    var body: some View {
        VStack(spacing: 30) {
            Text("App Icon Preview")
                .font(.title.bold())

            // 大尺寸预览
            AppIconView(size: 256)
                .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)

            // 不同尺寸预览
            HStack(spacing: 20) {
                VStack {
                    AppIconView(size: 60)
                    Text("60pt")
                        .font(.caption)
                }
                VStack {
                    AppIconView(size: 76)
                    Text("76pt")
                        .font(.caption)
                }
                VStack {
                    AppIconView(size: 120)
                    Text("120pt")
                        .font(.caption)
                }
            }

            Text("截图此视图或使用工具导出为PNG")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }
}

#Preview("App Icon") {
    AppIconPreview()
}

#Preview("Icon 1024") {
    AppIconView(size: 1024)
}

// MARK: - 导出工具

extension View {
    @MainActor
    func exportAsImage(size: CGSize) -> UIImage? {
        let controller = UIHostingController(rootView: self.frame(width: size.width, height: size.height))
        let view = controller.view

        view?.bounds = CGRect(origin: .zero, size: size)
        view?.backgroundColor = .clear

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            view?.drawHierarchy(in: view!.bounds, afterScreenUpdates: true)
        }
    }
}

struct IconExportButton: View {
    @State private var showingSaved = false

    var body: some View {
        VStack(spacing: 20) {
            AppIconView(size: 256)
                .shadow(color: .black.opacity(0.3), radius: 10)

            Button("保存 1024x1024 图标到相册") {
                saveIcon()
            }
            .buttonStyle(.borderedProminent)

            if showingSaved {
                Text("已保存到相册！")
                    .foregroundColor(.green)
            }
        }
        .padding()
    }

    @MainActor
    func saveIcon() {
        let iconView = AppIconView(size: 1024)
        if let image = iconView.exportAsImage(size: CGSize(width: 1024, height: 1024)) {
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            showingSaved = true
        }
    }
}

#Preview("Export") {
    IconExportButton()
}
