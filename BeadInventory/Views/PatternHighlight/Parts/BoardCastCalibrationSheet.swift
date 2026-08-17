//
//  BoardCastCalibrationSheet.swift
//  BeadInventory
//
//  手机上这一屏：把投影仪投出来的那块画面，对到桌上那块拼豆板上
//
//  ## 为什么是「一个角 + 一格多大」
//
//  投影仪把画面照在桌上，人把豆板摆在画面里。要让投出来的一格正好盖住豆板上的一个孔，
//  只需要两件事对上：**左上角在哪儿**、**一格多大**。中间的格子自然就跟着对齐了 ——
//  不需要用户去理解缩放比例、分辨率、每格多少毫米这些东西。
//
//  所以这一屏的动作就两个：拖那块矩形（对左上角）、拖右下角那个把手（改格子大小）。
//  投影仪那头实时跟着变，人站在桌边看着实物对，眼睛就是唯一的判据。
//  拖不准的最后那一点点交给微调按钮，一下走四分之一格。
//
//  ## 为什么一进来就切到校准模式
//
//  用户点进这一屏，就是因为「投出来的跟我的板子对不上」。这时候画面必须**立刻**
//  变成那块可以对齐的矩形，他才有东西可拖。留在铺满状态、等他调完再切，
//  等于让他对着一块铺满的画面盲拖。
//
//  代价是「点进来看一眼」也会改掉外屏，所以这一屏必须有**取消**：进来时记一份快照，
//  取消、划走、以及中途拔线都整组还原，只有「完成」才落盘。接电视的人手滑点开
//  又划走，电视上不该留下任何变化。
//

import SwiftUI

struct BoardCastCalibrationSheet: View {
    /// 正在对的那块板。校准框按它的 `cols × rows` 画，右下角就是最后一格的右下角。
    let board: PartsBoard
    /// 外屏多大（点）。进来时就定下，中途拔线这一屏直接关掉（见 `onChange`）——
    /// 兜底一个假尺寸的话，用户会对着一块不存在的屏幕继续调，还把值改坏。
    let screen: CGSize

    @ObservedObject private var calibration = BoardCastCalibration.shared
    @ObservedObject private var session = BoardCastSession.shared
    @Environment(\.dismiss) private var dismiss

    /// 拖动开始那一刻的值。`DragGesture` 的 `translation` 是**从按下那一刻累计**的，
    /// 每帧拿它去加当前值就会越加越远，框直接飞出画面。
    @State private var dragOrigin: CGPoint?
    @State private var dragCell: CGFloat?

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
            // 拖框的时候别让页面跟着滚：这一屏的全部价值就是这两个拖动，
            // 竖着拖和斜着拖正好跟 ScrollView 抢手势。
            .scrollDisabled(dragOrigin != nil || dragCell != nil)
            .background(Theme.ColorToken.Surface.background)
            .navigationTitle("对准豆板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        calibration.cancelCalibrating()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        calibration.finishCalibrating()
                        dismiss()
                    }
                }
            }
        }
        .onAppear { calibration.beginCalibrating(board: board, screen: screen) }
        // 划走（没点「完成」）跟点「取消」是同一件事。角标也在这里收掉 ——
        // 留着的话，人照着画面按豆子会把那两道粗角标当成图纸的一部分。
        .onDisappear {
            if calibration.isCalibrating { calibration.cancelCalibrating() }
        }
        // 中途拔线：这一屏已经没有可对的东西了，关掉（`onDisappear` 顺手还原）。
        .onChange(of: session.externalConnected) { _, connected in
            if !connected { dismiss() }
        }
    }

    // MARK: - 两步说明

    private var steps: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            step(number: "①", color: CalibrationMarkColor.topLeft,
                 text: String(localized: "拖下面那块矩形，让投影里的黄色角落在豆板的左上角（挪豆板也行）"))
            step(number: "②", color: CalibrationMarkColor.bottomRight,
                 text: String(localized: "拖右下角那个蓝色把手改格子大小，直到投影里最后一格正好压在豆板对应的孔上"))
            // 图纸比豆板大是常事（单图纸模式整张图纸就是一块板），这时候第二步的
            // 蓝角标压根落不到豆板上。与其让他对着一句对不上的说明反复重对，
            // 不如把这件事直接说了。
            Text("投影里这块是 \(board.cols) × \(board.rows) 格。比你的豆板大的话，先对上左上角这一块，拼完挪豆板再对一次。")
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
    /// 拖它 = 拖投影里那块矩形，位置一一对应 —— 人低头拖、抬头看实物，不用换算。
    private var preview: some View {
        GeometryReader { geo in
            let scale = geo.size.width / screen.width
            let rect = calibration.frame(for: board, in: screen) ?? .zero

            ZStack(alignment: .topLeading) {
                Color.black

                Rectangle()
                    .fill(CalibrationMarkColor.topLeft.opacity(0.10))
                    .overlay(Rectangle().stroke(Color.white.opacity(0.5), lineWidth: 1))
                    .overlay(alignment: .topLeading) {
                        cornerBracket(color: CalibrationMarkColor.topLeft)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        cornerBracket(color: CalibrationMarkColor.bottomRight)
                            .rotationEffect(.degrees(180))
                    }
                    .frame(width: max(rect.width * scale, 1), height: max(rect.height * scale, 1))
                    // 用 `.position` 是因为 `rect` 本来就是这块预览坐标系里的绝对位置，
                    // 直接给中心点最省事；`.offset` 还得先算出「相对布局位置差多少」。
                    .position(x: rect.midX * scale, y: rect.midY * scale)
                    .gesture(moveGesture(scale: scale, rect: rect))

                Circle()
                    .fill(CalibrationMarkColor.bottomRight)
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
                    board: board, screen: screen
                )
            }
            .onEnded { _ in dragOrigin = nil }
    }

    /// 把手只改格子大小，左上角钉住 —— 用户这一步已经把左上角对好了，
    /// 拉格子时它再动一下，前一步就白做了。
    private func resizeGesture(scale: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let start = dragCell ?? calibration.cell
                dragCell = start
                calibration.resizeCorner(
                    from: start,
                    translation: CGSize(width: value.translation.width / scale,
                                        height: value.translation.height / scale),
                    board: board, screen: screen
                )
            }
            .onEnded { _ in dragCell = nil }
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
                    nudgeButton("chevron.up") { nudge(dx: 0, dy: -1) }
                    HStack(spacing: Theme.Spacing.xs) {
                        nudgeButton("chevron.left") { nudge(dx: -1, dy: 0) }
                        nudgeButton("chevron.right") { nudge(dx: 1, dy: 0) }
                    }
                    nudgeButton("chevron.down") { nudge(dx: 0, dy: 1) }
                    Text("挪左上角")
                        .font(.caption2)
                        .foregroundColor(Theme.ColorToken.Text.secondary)
                }

                VStack(spacing: Theme.Spacing.xs) {
                    nudgeButton("plus") {
                        calibration.resize(cellDelta: step, board: board, screen: screen)
                    }
                    nudgeButton("minus") {
                        calibration.resize(cellDelta: -step, board: board, screen: screen)
                    }
                    Text("改格子大小")
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

    private func nudge(dx: CGFloat, dy: CGFloat) {
        calibration.move(dx: dx * step, dy: dy * step, board: board, screen: screen)
    }

    private func nudgeButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 52, height: 40)
        }
        .buttonStyle(.bordered)
    }

    /// 一下挪多少（外屏上的点）。直接按格距算，所以不管投影仪多大、板子多少格，
    /// 按一下永远是「四分之一格」，跟旁边写的那句话一致。
    private var step: CGFloat {
        max(1, calibration.cell * screen.width / 4)
    }

    // MARK: - 出路

    private var resetRow: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Button {
                calibration.resetToFilling()
                dismiss()
            } label: {
                Label("恢复铺满", systemImage: "arrow.counterclockwise")
            }
            Text("接的是电视、不是投影仪时用这个：画面回到自动铺满整块屏幕，这组对好的位置也一并清掉。")
                .font(.caption)
                .foregroundColor(Theme.ColorToken.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
