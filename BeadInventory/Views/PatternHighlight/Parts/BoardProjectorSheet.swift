//
//  BoardProjectorSheet.swift
//  BeadInventory
//
//  手机上这一屏：把投影仪投出来的画面，对到桌上那块拼豆板上
//
//  ## 用户在这一屏做的事
//
//  投影仪把画面照在桌上，人把豆板摆在画面里。要让投出来的一格正好盖住豆板上的一个孔，
//  只要**画面里那个方框的四个角，落在豆板的四个角上**就行 —— 中间的格子会自动对齐
//  （平面透视的性质，见 `ProjectorGeometry.swift`）。所以这一屏的动作只有一个：
//  拖四个角。投影仪那头实时跟着变，人站在桌边看着实物对，眼睛就是唯一的判据。
//
//  唯一要先说清楚的是**这块豆板多少格**：四个角是对着实物板的角放的，格数说错，
//  中间每一格都会错位。多零件模式知道答案（正在拼的就是那块板），直接填好；
//  单图纸模式的图纸大小跟实物板无关，得让用户点一下。
//
//  手指拖不准的最后一点点交给微调按钮，一下走四分之一格。另外给一组「整块挪」：
//  桌子被碰了一下、投影仪蹭歪了一点，形状没变、只是整体偏了，不该逼人四个角重对一遍。
//
//  ## 为什么一进来就切到投影仪模式
//
//  用户点进这一屏，就是因为「投出来的跟我的板子对不上」。这时候画面必须**立刻**变成
//  那个可以对齐的方框，他才有东西可拖。留在铺满状态、等他调完再切，等于让他对着一块
//  铺满的画面盲拖。
//
//  代价是「点进来看一眼」也会改掉外屏，所以这一屏必须有**取消**：进来时记一份快照，
//  取消、划走、以及中途拔线都整组还原。落盘只有两个入口：「完成」和「关掉投影仪模式」。
//  接电视的人手滑点开又划走，电视上不该留下任何变化。
//

import SwiftUI

struct BoardProjectorSheet: View {
    /// 这一屏正在拼的那块板 —— 多零件模式下它就是桌上那块实物豆板，拿来当默认格数。
    /// 单图纸模式送 nil：那边的「板」是整张图纸，跟实物板多少格没有关系，猜错了更糟。
    let suggestedBoard: BeadBoardSize?
    /// 外屏多大（点）。进来时就定下，中途拔线这一屏直接关掉（见 `onChange`）——
    /// 兜底一个假尺寸的话，用户会对着一块不存在的屏幕继续调，还把值改坏。
    let screen: CGSize

    @ObservedObject private var projector = BoardProjector.shared
    @ObservedObject private var session = BoardCastSession.shared
    @Environment(\.dismiss) private var dismiss

    /// 按下那一刻，被拖的那个角在外屏上的位置。`DragGesture` 的 `translation` 是
    /// **从按下那一刻累计**的，每帧拿它去加当前值就会越加越远，角直接飞出画面。
    ///
    /// 用 `@GestureState` 不用 `@State`：手势被 ScrollView 抢走、或者被来电打断时
    /// **不保证走 `onEnded`**（这一版 `minimumDistance` 是 0，按下那一刻就跟 ScrollView
    /// 抢，抢输是常事）。用 `@State` 的话那次就永远清不掉：`scrollDisabled` 卡死、
    /// 下次再拖同一个角还会拿上次的旧锚点当起点，角先跳一下再跟手。
    /// `@GestureState` 在手势结束或取消时由系统自动复位，正是为这种情况存在的。
    @GestureState private var dragAnchor: (corner: ProjectorCorner, point: CGPoint)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    boardSizeRow
                    steps
                    preview
                    cornerPicker
                    nudgePad
                    resetRow
                }
                .padding()
            }
            // 拖角的时候别让页面跟着滚：这一屏的全部价值就是这几个拖动，
            // 竖着拖和斜着拖正好跟 ScrollView 抢手势。
            .scrollDisabled(dragAnchor != nil)
            .background(Theme.ColorToken.Surface.background)
            .navigationTitle("投影仪模式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        projector.cancelCalibrating()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        projector.finishCalibrating()
                        dismiss()
                    }
                }
            }
        }
        .onAppear { projector.beginCalibrating(suggestedBoard: suggestedBoard, screen: screen) }
        // 划走（没点「完成」）跟点「取消」是同一件事。角标也在这里收掉 ——
        // 留着的话，人照着画面按豆子会把那四个粗角标当成图纸的一部分。
        // （点「完成」时 `finishCalibrating` 已经收掉了，下面这个 if 不成立。）
        .onDisappear {
            if projector.isCalibrating { projector.cancelCalibrating() }
        }
        // 中途拔线：这一屏已经没有可对的东西了，关掉。
        // 还原不在这儿做 —— `sceneDidDisconnect` 里已经同步调过 `cancelCalibrating()`，
        // 等这个 onChange 派发到时 `isCalibrating` 早就是 false 了。
        .onChange(of: session.externalConnected) { _, connected in
            if !connected { dismiss() }
        }
    }

    // MARK: - 你的豆板多少格

    private var boardSizeRow: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text("你手上那块豆板")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(Theme.ColorToken.Text.primary)
                Spacer()
                Menu {
                    ForEach(BeadBoardSize.presets) { size in
                        Button {
                            projector.setBoardSize(size)
                        } label: {
                            if size.cols == projector.boardCols, size.rows == projector.boardRows {
                                Label(size.label, systemImage: "checkmark")
                            } else {
                                Text(size.label)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("\(projector.boardCols) × \(projector.boardRows)")
                            .font(.body.monospacedDigit())
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                }
            }
            Text("投影里那个方框会分成这么多格，四个角对到板子四个角上之后，一格正好一个孔。格数说错，中间就会越偏越多。")
                .font(.caption)
                .foregroundColor(Theme.ColorToken.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            mismatchNote
        }
    }

    /// 这一屏摆的板跟这里存的格数对不上时说一声。
    ///
    /// 这种情况用户自己发现不了：投出来的画面看着「差不多」，一格却不是一个孔，
    /// 越往右下越偏 —— 而他会以为是自己四个角没对准，反复重对。上次是拿 52 × 52
    /// 对的、这次换了块 100 × 100 的板，就是这么来的。
    ///
    /// 不自动改：那四个角是对着上一块板的角放的，格数一改，用户眼前的画面会突然变样，
    /// 而他并没有要求任何东西改变。所以说清楚 + 一下点过去。
    @ViewBuilder
    private var mismatchNote: some View {
        if let suggestedBoard,
           suggestedBoard.cols != projector.boardCols || suggestedBoard.rows != projector.boardRows {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("这一屏摆的是 \(suggestedBoard.label) 的板，跟上面对不上。")
                    .font(.caption)
                    .foregroundColor(Theme.ColorToken.Status.warning)
                    .fixedSize(horizontal: false, vertical: true)
                // 单独一行、描个边：跟在一句话后面的纯文字按钮看着就是那句话的一部分，
                // 而这一下是要改掉一个会影响每一格的数。
                Button("改成 \(suggestedBoard.label)") {
                    projector.setBoardSize(suggestedBoard)
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - 说明

    private var steps: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("把投影里那个方框的四个角，分别拖到豆板的四个角上。角上的颜色和号跟下面预览里的一一对应。")
                .font(.subheadline)
                .foregroundColor(Theme.ColorToken.Text.primary)
                .fixedSize(horizontal: false, vertical: true)
            // 斜着投是常态，而这正是四个角要分别拖的原因 —— 说一句，用户才不会以为
            // 「投出来是梯形」是自己没摆正。
            Text("投影仪斜着照没关系：四个角对上之后，App 会把画面掰回正方形，中间的格子自动就对齐了。")
                .font(.caption)
                .foregroundColor(Theme.ColorToken.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            // 图纸比豆板大是单图纸模式的常态（整张图纸就是一块「板」），超出板子的格子
            // 会投到桌面上。多零件模式不会遇到（那块板就是实物板），那边不说这句 ——
            // 这一屏本来就已经三段字了。
            if suggestedBoard == nil {
                Text("图纸比豆板大的时候，超出板子的格子会投到桌面上：先拼板子上这一块，拼完把豆板挪到下一块位置再拼。")
                    .font(.caption)
                    .foregroundColor(Theme.ColorToken.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 缩小版的投影画面

    /// 手机上这块黑底就是投影仪那块画面的等比缩小版：投影仪多宽多高，这里就多宽多高。
    /// 拖它 = 拖投影里那个角，位置一一对应 —— 人低头拖、抬头看实物，不用换算。
    private var preview: some View {
        GeometryReader { geo in
            let scale = geo.size.width / screen.width
            let points = projector.quad.points(in: screen).map {
                CGPoint(x: $0.x * scale, y: $0.y * scale)
            }

            ZStack(alignment: .topLeading) {
                Color.black

                quadShape(points)
                // 投影里画的是同一组线（每 10 格一条）。手机上不画的话，用户在这块
                // 预览里看到的是个空框，跟他抬头看到的画面对不上号。
                guideLines(scale: scale)

                ForEach(Array(ProjectorCorner.allCases.enumerated()), id: \.element) { index, corner in
                    handle(corner: corner, at: points[index], scale: scale)
                }
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

    /// 每 10 格一条，跟外屏校准时画的是同一组线（见 `ProjectorCalibrationMarks`）。
    @ViewBuilder
    private func guideLines(scale: CGFloat) -> some View {
        if let mapping = projector.mapping(in: screen) {
            Path { path in
                let cols = mapping.boardCols, rows = mapping.boardRows
                for c in stride(from: 10, to: cols, by: 10) {
                    if let a = mapping.point(col: CGFloat(c), row: 0),
                       let b = mapping.point(col: CGFloat(c), row: CGFloat(rows)) {
                        path.move(to: scaled(a, scale)); path.addLine(to: scaled(b, scale))
                    }
                }
                for r in stride(from: 10, to: rows, by: 10) {
                    if let a = mapping.point(col: 0, row: CGFloat(r)),
                       let b = mapping.point(col: CGFloat(cols), row: CGFloat(r)) {
                        path.move(to: scaled(a, scale)); path.addLine(to: scaled(b, scale))
                    }
                }
            }
            .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
        }
    }

    private func scaled(_ point: CGPoint, _ scale: CGFloat) -> CGPoint {
        CGPoint(x: point.x * scale, y: point.y * scale)
    }

    private func quadShape(_ points: [CGPoint]) -> some View {
        Path { path in
            path.move(to: points[0])
            for point in points.dropFirst() { path.addLine(to: point) }
            path.closeSubpath()
        }
        .fill(Color.white.opacity(0.10))
        .overlay(
            Path { path in
                path.move(to: points[0])
                for point in points.dropFirst() { path.addLine(to: point) }
                path.closeSubpath()
            }
            .stroke(Color.white.opacity(0.5), lineWidth: 1)
        )
    }

    /// 一个角的把手。
    ///
    /// 圆点画 26 点，命中区垫到 44 点：这几个角常常挨着预览的边缘，手指按下去的位置
    /// 本来就偏，把手再小就只能靠微调按钮一格一格挪了。
    private func handle(corner: ProjectorCorner, at point: CGPoint, scale: CGFloat) -> some View {
        let isActive = projector.activeCorner == corner
        return ZStack {
            Circle()
                .fill(corner.markColor)
                .frame(width: isActive ? 26 : 20, height: isActive ? 26 : 20)
                .overlay(
                    Circle().stroke(Color.white.opacity(isActive ? 0.9 : 0.4),
                                    lineWidth: isActive ? 2 : 1)
                )
            Text(corner.number)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.black.opacity(0.7))
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .position(point)
        .gesture(dragGesture(corner: corner, scale: scale))
    }

    /// `minimumDistance: 0` 是为了「点一下就选中这个角」：微调按钮作用在选中的那个角上，
    /// 而用户在实物旁边最常做的事就是「先点这个角、再按几下微调」，不该被迫先拖动一下。
    private func dragGesture(corner: ProjectorCorner, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($dragAnchor) { _, anchor, _ in
                // 第一帧记下这个角的起点，后面每帧都以它为基准加累计位移
                if anchor == nil || anchor?.corner != corner {
                    anchor = (corner, projector.quad.point(corner, in: screen))
                }
            }
            .onChanged { value in
                let anchor = dragAnchor?.corner == corner
                    ? dragAnchor!.point
                    : projector.quad.point(corner, in: screen)
                projector.setCorner(
                    corner,
                    to: CGPoint(x: anchor.x + value.translation.width / scale,
                                y: anchor.y + value.translation.height / scale),
                    screen: screen
                )
            }
    }

    // MARK: - 选中哪个角

    private var cornerPicker: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ForEach(ProjectorCorner.allCases) { corner in
                Button {
                    projector.activeCorner = corner
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(corner.markColor)
                            .frame(width: 10, height: 10)
                        Text(corner.number)
                    }
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                            .fill(projector.activeCorner == corner
                                  ? Theme.ColorToken.Surface.strong
                                  : Theme.ColorToken.Surface.elevated)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 微调

    /// 手指拖得再稳也只能到「差不多」，而差半格就是每颗豆子都压在孔的边上。
    /// 所以再给一组按钮，一下走四分之一格 —— 单位用格不用点：用户眼里的单位就是格，
    /// 「一次 3 个点」他没法判断该按几下。
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
                arrowPad(caption: String(localized: "挪 \(projector.activeCorner.number) 这个角")) { dx, dy in
                    projector.nudgeActiveCorner(dx: dx * step, dy: dy * step, screen: screen)
                }
                // 桌子被碰一下、投影仪蹭歪一点，形状没变、整体偏了。四个角重对一遍
                // 是没必要的，而这恰恰是拼到一半最常发生的事。
                arrowPad(caption: String(localized: "整块一起挪")) { dx, dy in
                    projector.nudgeWholeQuad(dx: dx * step, dy: dy * step, screen: screen)
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

    private func arrowPad(caption: String, move: @escaping (CGFloat, CGFloat) -> Void) -> some View {
        VStack(spacing: Theme.Spacing.xs) {
            nudgeButton("chevron.up") { move(0, -1) }
            HStack(spacing: Theme.Spacing.xs) {
                nudgeButton("chevron.left") { move(-1, 0) }
                nudgeButton("chevron.right") { move(1, 0) }
            }
            nudgeButton("chevron.down") { move(0, 1) }
            Text(caption)
                .font(.caption2)
                .foregroundColor(Theme.ColorToken.Text.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func nudgeButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 52, height: 40)
        }
        .buttonStyle(.bordered)
    }

    /// 一下挪多少（外屏上的点）。按当前的格距算，所以不管投影仪多大、板子多少格，
    /// 按一下永远是「四分之一格」，跟旁边写的那句话一致。
    private var step: CGFloat {
        max(1, projector.cellSize(in: screen) / 4)
    }

    // MARK: - 出路

    private var resetRow: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Button {
                projector.resetToFilling()
                dismiss()
            } label: {
                Label("关掉投影仪模式", systemImage: "arrow.counterclockwise")
            }
            Text("接的是电视、不是投影仪时用这个：画面回到整块板铺满屏幕，这组对好的四个角也一并清掉。")
                .font(.caption)
                .foregroundColor(Theme.ColorToken.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 手机上那个「投屏中」标记

/// 接了外屏之后，手机那一屏上的状态标记 + 投影仪模式的入口。
///
/// 用户接上 AirPlay 之后第一件想确认的就是「到底投上了没有」，而他多半人在电视 /
/// 投影仪那头，手机屏幕上得有个准信。顺手就是投影仪模式的入口：投出来的画面跟豆板
/// 对不对得上，是接上之后立刻会发现的事，而这个标记正是他这时候在看的东西 ——
/// 单独加一个按钮的话，接电视的人也得多看一个跟自己无关的东西。
///
/// 两种模式下写的话不一样：还没开投影仪模式的人需要知道「有这么个东西」，
/// 已经开着的人需要知道「点这儿能重新对」。
struct ProjectorStatusChip: View {
    @ObservedObject private var projector = BoardProjector.shared
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                if projector.isOn {
                    Label("投影仪模式 · 只亮当前色号，点这里重新对板", systemImage: "videoprojector")
                } else {
                    Label("投屏中 · 投到豆板上？点这里开投影仪模式", systemImage: "tv")
                }
                // 光把文字变成按钮，用户看不出它可以点（改之前那儿就是一个纯状态标记，
                // 长得一模一样）。
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
            }
            .font(.caption2.weight(.medium))
            .foregroundColor(Theme.ColorToken.Morandi.mauve)
            .frame(maxWidth: .infinity, alignment: .leading)
            // 十几点高的一行字太难点了，垫出一块像样的触摸区
            .padding(.vertical, Theme.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
