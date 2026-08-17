//
//  BoardCastCalibrationSheet.swift
//  BeadInventory
//
//  手机上这一屏：把投影仪投出来的那块画面，对到桌上那块拼豆板上
//
//  ## 为什么是「一个角 + 一条边长」
//
//  投影仪把画面照在桌上，人把豆板摆在画面里。要让投出来的一格正好盖住豆板上的一个孔，
//  只需要两件事对上：**左上角在哪儿**、**一边有多长**。板子是正方形的，中间的格子
//  就自动对齐了 —— 不需要用户去理解缩放比例、分辨率、每格多少毫米这些东西。
//
//  所以这一屏只有两个动作：拖框（对左上角）、拖右下角那个把手（拉边长）。
//  投影仪那头实时跟着变，人站在桌边看着实物对，眼睛就是唯一的判据。
//
//  ## 为什么一进来就切到校准模式
//
//  用户点进这一屏，就是因为「投出来的跟我的板子对不上」。这时候画面必须**立刻**
//  变成那个可以对齐的方框，他才有东西可拖。留在铺满状态、等他调完再切，
//  等于让他对着一块铺满的画面盲拖。对完不满意的出路写在最下面（「恢复铺满」）。
//

import SwiftUI

struct BoardCastCalibrationSheet: View {
    @ObservedObject private var calibration = BoardCastCalibration.shared
    @ObservedObject private var session = BoardCastSession.shared
    @Environment(\.dismiss) private var dismiss

    /// 拖动开始那一刻的值。拖动过程中拿它加上位移算 —— 每帧在当前值上叠加的话，
    /// 手指没动的那几帧也会因为夹边界（`clampOrigin`）把值蹭走。
    @State private var dragOrigin: CGPoint?
    @State private var dragSide: CGFloat?

    /// 外屏多大（点）。没接外屏时这一屏本来就开不出来，兜底给个 16:9 免得除零。
    private var screen: CGSize {
        let size = session.externalScreenSize ?? CGSize(width: 1920, height: 1080)
        return size.width > 0 && size.height > 0 ? size : CGSize(width: 1920, height: 1080)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    steps
                    preview
                    nudgePad
                    resetRow
                }
                .padding()
            }
            .background(Theme.ColorToken.Surface.background)
            .navigationTitle("对准豆板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .onAppear {
            calibration.isEnabled = true
            calibration.isCalibrating = true
        }
        // 角标只在这一屏开着的时候画。离开还留着的话，人照着画面按豆子时
        // 会把那两道粗角标当成图纸的一部分。
        .onDisappear { calibration.isCalibrating = false }
    }

    // MARK: - 两步说明

    private var steps: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            step(number: "①", color: Self.topLeftColor,
                 text: String(localized: "把豆板挪一挪，让它的左上角对上投影里那个黄色的角"))
            step(number: "②", color: Self.bottomRightColor,
                 text: String(localized: "拖下面那个蓝色把手改边长，直到投影的右下角也落在豆板的右下角"))
            Text("对好之后，投影里的一格就正好是豆板上的一个孔。换个地方摆投影仪要重对一次。")
                .font(.caption)
                .foregroundColor(Theme.ColorToken.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func step(number: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Text(number)
                .font(.headline)
                .foregroundColor(color)
            Text(text)
                .font(.subheadline)
                .foregroundColor(Theme.ColorToken.Text.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 缩小版的投影画面

    /// 手机上这块黑底就是投影仪那块画面的等比缩小版：投影仪多宽多高，这里就多宽多高。
    /// 拖它 = 拖投影里那个框，位置一一对应 —— 人低头拖、抬头看实物，不用换算。
    private var preview: some View {
        GeometryReader { geo in
            let scale = geo.size.width / screen.width
            let rect = calibration.previewRect(in: screen)

            ZStack(alignment: .topLeading) {
                Color.black

                Rectangle()
                    .fill(Self.topLeftColor.opacity(0.10))
                    .overlay(Rectangle().stroke(Color.white.opacity(0.5), lineWidth: 1))
                    .overlay(alignment: .topLeading) { cornerBracket(color: Self.topLeftColor) }
                    .overlay(alignment: .bottomTrailing) {
                        cornerBracket(color: Self.bottomRightColor)
                            .rotationEffect(.degrees(180))
                    }
                    .frame(width: max(rect.width * scale, 1), height: max(rect.height * scale, 1))
                    // 用 position 不用 offset：offset 之后这块的点击区不跟着走，
                    // 手指拖的位置和框的位置会对不上（仓库里踩过这个坑）。
                    .position(x: rect.midX * scale, y: rect.midY * scale)
                    .gesture(moveGesture(scale: scale, rect: rect))

                Circle()
                    .fill(Self.bottomRightColor)
                    .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1))
                    .frame(width: 30, height: 30)
                    .position(x: rect.maxX * scale, y: rect.maxY * scale)
                    .gesture(resizeGesture(scale: scale))
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .aspectRatio(screen.width / screen.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
        )
    }

    private func cornerBracket(color: Color) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 18))
            path.addLine(to: .zero)
            path.addLine(to: CGPoint(x: 18, y: 0))
        }
        .stroke(color, lineWidth: 4)
        .frame(width: 18, height: 18)
    }

    private func moveGesture(scale: CGFloat, rect: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let start = dragOrigin ?? rect.origin
                dragOrigin = start
                calibration.setOrigin(
                    x: start.x + value.translation.width / scale,
                    y: start.y + value.translation.height / scale,
                    screen: screen
                )
            }
            .onEnded { _ in dragOrigin = nil }
    }

    /// 把手只改边长，左上角钉住 —— 用户这一步已经把左上角对好了，
    /// 拉边长时它再动一下，前一步就白做了。
    ///
    /// 斜着拖，取横竖位移的平均：框是正方形的，只认一个方向的话，
    /// 顺手斜着一拖会觉得「跟不上手」。
    private func resizeGesture(scale: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let start = dragSide ?? calibration.previewRect(in: screen).width
                dragSide = start
                let delta = (value.translation.width + value.translation.height) / 2 / scale
                calibration.setSide(start + delta, screen: screen)
            }
            .onEnded { _ in dragSide = nil }
    }

    // MARK: - 微调

    /// 手指拖得再稳也只能到「差不多」，而差半格就是每颗豆子都压在孔的边上。
    /// 所以再给一组按钮，一下走四分之一格 —— 单位用格不用点：
    /// 用户眼里的单位就是格，「一次 3 个点」他没法判断该按几下。
    private var nudgePad: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack {
                Text("微调")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(Theme.ColorToken.Text.primary)
                Spacer()
                Text("一下走 ¼ 格")
                    .font(.caption)
                    .foregroundColor(Theme.ColorToken.Text.tertiary)
            }

            HStack(spacing: Theme.Spacing.lg) {
                VStack(spacing: Theme.Spacing.xs) {
                    nudgeButton("chevron.up") { calibration.move(dx: 0, dy: -step, screen: screen) }
                    HStack(spacing: Theme.Spacing.xs) {
                        nudgeButton("chevron.left") { calibration.move(dx: -step, dy: 0, screen: screen) }
                        nudgeButton("chevron.right") { calibration.move(dx: step, dy: 0, screen: screen) }
                    }
                    nudgeButton("chevron.down") { calibration.move(dx: 0, dy: step, screen: screen) }
                    Text("挪左上角")
                        .font(.caption2)
                        .foregroundColor(Theme.ColorToken.Text.secondary)
                }

                VStack(spacing: Theme.Spacing.xs) {
                    nudgeButton("plus") { calibration.resize(by: step, screen: screen) }
                    nudgeButton("minus") { calibration.resize(by: -step, screen: screen) }
                    Text("改边长")
                        .font(.caption2)
                        .foregroundColor(Theme.ColorToken.Text.secondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Theme.ColorToken.Surface.elevated)
        )
    }

    private func nudgeButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 52, height: 40)
        }
        .buttonStyle(.bordered)
    }

    /// 一下挪多少（外屏上的点）。按**当前这块板一格有多大**算，所以不管投影仪多大、
    /// 板子是 50 格还是 104 格，按一下的手感都是「四分之一格」。
    private var step: CGFloat {
        let cols = session.content?.board.cols ?? 50
        let cell = calibration.previewRect(in: screen).width / CGFloat(max(cols, 1))
        return max(1, cell / 4)
    }

    // MARK: - 出路

    private var resetRow: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Button {
                calibration.reset()
                dismiss()
            } label: {
                Label("恢复铺满", systemImage: "arrow.counterclockwise")
            }
            Text("接的是电视、不是投影仪时用这个：画面回到自动铺满整块屏幕。")
                .font(.caption)
                .foregroundColor(Theme.ColorToken.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // 跟外屏角标同一套颜色（`CalibrationMarksCanvas`）。两块屏幕上的黄和蓝必须是
    // 同一个黄和蓝 —— 用户就是靠颜色认「我现在在调哪个角」。
    private static let topLeftColor = Color(red: 1.0, green: 0.83, blue: 0.0)
    private static let bottomRightColor = Color(red: 0.2, green: 0.9, blue: 1.0)
}
