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
//  ## 顺带在这儿挑「亮的格子什么颜色」
//
//  跟对齐是两回事，但摆在同一屏：两样都是**站在投影仪旁边、看着桌上那块板**才能定的，
//  而这一屏是唯一一个「人在桌边、外屏实时跟着变」的地方 —— 挑颜色跟拖角一样，
//  判据是抬头看一眼板子。埋进设置页的话，他得来回跑两趟。
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

    /// 自己填过的板子格数。跟多零件模式那一屏读的是同一份偏好 ——
    /// 桌上那块板就一块，在哪儿填的不该影响另一处点不点得到。
    @AppStorage("boardCustomSizes") private var customSizes = ""
    /// 开着「自定义尺寸」那一屏
    @State private var showingCustomSize = false

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
                    highlightColorRow
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
        // 格数是即时生效的（外屏跟着重新分格），没有「等确认」这一步，
        // 所以不用像板子那一屏那样推到 onDismiss。
        .sheet(isPresented: $showingCustomSize) {
            BoardSizeCustomSheet(
                initial: BeadBoardSize(cols: projector.boardCols, rows: projector.boardRows)
            ) { size in
                customSizes = BeadBoardSize.remember(size, in: customSizes)
                projector.setBoardSize(size)
            }
        }
        .onAppear { projector.beginCalibrating(suggestedBoard: suggestedBoard, screen: screen) }
        // 划走（没点「完成」）跟点「取消」是同一件事。角标也在这里收掉 ——
        // 留着的话，人照着画面按豆子会把那些彩色亮块当成图纸的一部分。
        // 换成格子画之后更要紧了：角标跟真正要按豆子的格子长得一模一样，只有颜色不同。
        // （点「完成」时 `finishCalibrating` 已经收掉了，下面这个 if 不成立。）
        .onDisappear {
            // 「自定义尺寸」那一屏盖在上面时不算划走 —— 底下这一屏还在，用户只是去填个数。
            // 真在那时候还原，他对了半天的四个角就没了，而且回来也不会重新 beginCalibrating。
            guard !showingCustomSize else { return }
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
                    BoardSizePicker(
                        current: BeadBoardSize(cols: projector.boardCols, rows: projector.boardRows),
                        recents: BeadBoardSize.decodeList(customSizes),
                        onPick: { projector.setBoardSize($0) },
                        onCustom: { showingCustomSize = true }
                    )
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
            // 「对准了」得有个用户自己看得出来的判据，所以两条胳膊要跟箭尖写在一句话里：
            // 光看箭尖那一格，差半格是看不出来的；顺着板边亮的那几个孔歪没歪，一眼就是一眼。
            Text("投影里四个角上各有一个直角记号。把拐角那个亮块，拖到豆板同一个角最角上的那个孔里 —— 两条胳膊会顺着板边再亮几个孔，这几个孔都照上了，这个角就对准了。")
                .font(.subheadline)
                .foregroundColor(Theme.ColorToken.Text.primary)
                .fixedSize(horizontal: false, vertical: true)
            // 四个角对上、中间却偏了，是用户自己发现不了的一类错（镜头畸变、桌面不平）。
            // 记号画在畸变最大的几处，把这件事变成「看那几块光有没有照进孔里」。
            // 不提「格数选错」：正中间恰好是常见错法的零点，查不出来（见 `ProjectorAlignmentMarks`）。
            Text("四条边的正中间还各有一个白色的 T，板子正中间是一个白十字。这几处也照进孔里，中间就没有偏。")
                .font(.caption)
                .foregroundColor(Theme.ColorToken.Text.tertiary)
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
                alignmentMarks(scale: scale)

                ForEach(Array(ProjectorCorner.allCases.enumerated()), id: \.element) { index, corner in
                    // 把手上那个直角要顺着板子的两条边画，所以得知道左右两个邻角在哪儿。
                    // 顺时针存的（见 `ProjectorCorner` 的顺序警告），所以 +1 / +3 就是邻角。
                    handle(corner: corner, at: points[index],
                           toward: points[(index + 1) % 4], and: points[(index + 3) % 4],
                           scale: scale)
                        // 选中的那个画在最上层。四个把手的命中区挨得近时，压在底下的
                        // 那个按不着 —— 而「先在下面点一下这个角、再回预览里拖」正是
                        // 用户会做的事。
                        .zIndex(projector.activeCorner == corner ? 1 : 0)
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

    /// 四条边正中 + 板子正中那几个十字，跟投影里是同一批位置。
    ///
    /// 这里画的是固定大小的十字，不是按格子画：这块预览才三百多点宽，一格常常不到两个点，
    /// 照着格子画等于什么都没画。用户在这块预览上要认的是「有这么几个记号、在这几个位置」，
    /// 至于每个记号盖住几个孔，那是抬头看投影的事。
    ///
    /// 所以边上那四个在外屏是缺一笔的「T」、这里画的是完整的十字 —— 形状对不上是故意的，
    /// 两三个点大的地方缺不缺一笔看不出来，硬裁只会变成一个更难认的小点。
    @ViewBuilder
    private func alignmentMarks(scale: CGFloat) -> some View {
        if let mapping = projector.mapping(in: screen) {
            Path { path in
                let marks = ProjectorAlignmentMarks(cols: mapping.boardCols, rows: mapping.boardRows)
                for center in marks.centers {
                    guard let point = mapping.point(col: CGFloat(center.col) + 0.5,
                                                    row: CGFloat(center.row) + 0.5) else { continue }
                    let at = scaled(point, scale)
                    path.move(to: CGPoint(x: at.x - 4, y: at.y))
                    path.addLine(to: CGPoint(x: at.x + 4, y: at.y))
                    path.move(to: CGPoint(x: at.x, y: at.y - 4))
                    path.addLine(to: CGPoint(x: at.x, y: at.y + 4))
                }
            }
            .stroke(Color.white.opacity(0.85), lineWidth: 1.5)
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

    /// 一个角的把手：一个直角 + 顶点上一个点，跟投影里那个箭头同一个形状。
    ///
    /// 之前这儿是个圆点。圆点说不清「对准的到底是圆心还是圆边」，也说不出这是哪个角 ——
    /// 用户对着投影拖了半天，回头问「四个角到底怎么定义的」。换成直角之后，两条胳膊
    /// 指着板子的两条边，跟投影里那个箭头一一对上，顶点就是要落到角上那个孔的位置。
    ///
    /// 胳膊的方向照着相邻两个角算，不是写死的上下左右：投影仪斜着照的时候这个方框是
    /// 梯形，写死方向的话把手会指到板子外面去。
    ///
    /// 命中区最大 60 点：这几个角常常挨着预览的边缘，手指按下去的位置本来就偏，
    /// 把手再小就只能靠微调按钮一格一格挪了。
    ///
    /// 但**不能一律 60**：投影仪打三米宽的画面、桌上一块 25cm 的豆板只占画面宽的 8%
    /// （`ProjectorQuad.isUsable` 那段有这个实测数），换算到这块预览上，相邻两个角
    /// 只隔三十来点。命中区是整块方的，一超过角距，后画的那个就把前一个的中心盖住了，
    /// 用户按在 ① 上拖走的是 ④。所以按角距夹一下：只要不超过角距，
    /// 相邻把手就永远盖不住对方的中心。
    private func handle(corner: ProjectorCorner, at point: CGPoint,
                        toward next: CGPoint, and previous: CGPoint,
                        scale: CGFloat) -> some View {
        let isActive = projector.activeCorner == corner
        let spacing = min(hypot(next.x - point.x, next.y - point.y),
                          hypot(previous.x - point.x, previous.y - point.y))
        // 下限 28 点：再小就真的按不着了，这时候靠下面那排选角按钮 + 微调兜底。
        let box = min(60, max(28, spacing))
        let center = CGPoint(x: box / 2, y: box / 2)
        let arm = box * 0.28
        let a = unitVector(from: point, to: next)
        let b = unitVector(from: point, to: previous)
        let bisector = unitVector(dx: a.dx + b.dx, dy: a.dy + b.dy)

        return ZStack {
            Color.clear
            Path { path in
                path.move(to: CGPoint(x: center.x + a.dx * arm, y: center.y + a.dy * arm))
                path.addLine(to: center)
                path.addLine(to: CGPoint(x: center.x + b.dx * arm, y: center.y + b.dy * arm))
            }
            .stroke(corner.markColor.opacity(isActive ? 1 : 0.7),
                    style: StrokeStyle(lineWidth: isActive ? 4 : 2.5,
                                       lineCap: .round, lineJoin: .round))
            Circle()
                .fill(corner.markColor)
                .frame(width: isActive ? 11 : 8, height: isActive ? 11 : 8)
                .position(center)
            // 号写在直角里面（两条胳膊的角平分线上），跟投影里的位置一致
            Text(corner.number)
                .font(.system(size: 12, weight: .bold))
                // 跟胳膊一起变淡：外屏那边序号也是跟着淡的，两边得是同一个信号
                .foregroundColor(corner.markColor.opacity(isActive ? 1 : 0.7))
                .position(x: center.x + bisector.dx * box * 0.35,
                          y: center.y + bisector.dy * box * 0.35)
        }
        .frame(width: box, height: box)
        .contentShape(Rectangle())
        .position(point)
        .gesture(dragGesture(corner: corner, scale: scale))
    }

    private func unitVector(from: CGPoint, to: CGPoint) -> CGVector {
        unitVector(dx: to.x - from.x, dy: to.y - from.y)
    }

    /// 长度归一。**这个兜底真的会走到**：全新安装、还没存过校准值时 `quad` 是四个 `.zero`，
    /// 而 SwiftUI 先求 body 再调 `onAppear`，所以把 quad 换成可用值的 `beginCalibrating`
    /// 慢一帧 —— 那一帧四个角重合，算出来就是零向量。兜住之后只是四个把手叠在左上角
    /// 一帧，不兜就是 NaN 画飞。别因为「`isUsable` 挡着呢」把它删了。
    private func unitVector(dx: CGFloat, dy: CGFloat) -> CGVector {
        let length = hypot(dx, dy)
        guard length > 0.0001 else { return CGVector(dx: 0, dy: 0) }
        return CGVector(dx: dx / length, dy: dy / length)
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

    // MARK: - 亮的格子什么颜色

    /// 三选一 + 一条「投出来大概是这样」的样例。
    ///
    /// 样例那一条是这一段里最要紧的东西：三种投法的差别不在名字上，在
    /// **「黑豆子投出来是什么样」** 上 —— 「跟着图纸」下黑和白都是白光，用户光看
    /// 「跟着图纸」四个字是想不到这件事的。所以左边摆色号本来的颜色、右边摆投出来的，
    /// 中间一个箭头，切一下模式那三个点当场就变。
    ///
    /// 外屏这时候也在实时跟着变（这一屏开着的时候投影仪照样在投），
    /// 所以真正的判据仍然是抬头看板子；手机上这三个点只是让他知道该看什么。
    ///
    /// **除非一个色号都没点** —— 那时候板子上本来就一格不亮，怎么切都没有变化，
    /// 而手机上这三个点照样在变，等于告诉他「已经生效了」。所以那种情况直接说出来。
    private var highlightColorRow: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("亮的格子什么颜色")
                .font(.subheadline.weight(.medium))
                .foregroundColor(Theme.ColorToken.Text.primary)

            BISegmented(
                selection: styleBinding,
                segments: ProjectorHighlightStyle.allCases.map { (value: $0, label: $0.label) },
                fillWidth: true
            )

            sampleStrip

            Text(projector.highlight.style.explanation)
                .font(.caption)
                .foregroundColor(Theme.ColorToken.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if session.content?.highlightKeys.isEmpty ?? true {
                Text("现在一个色号都没点，板子上一格都不亮 —— 回上一屏点一个色号，才看得出这几种颜色的差别。")
                    .font(.caption)
                    .foregroundColor(Theme.ColorToken.Status.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if projector.highlight.style == .custom {
                ColorPicker("挑一个颜色", selection: customColorBinding, supportsOpacity: false)
                    .font(.subheadline)
                // 挑了个暗色只说一句，不替他改掉 —— 屋里很黑、板子反光的时候，
                // 压暗可能正是他要的。但「投出来一格都不亮」看着就是投屏坏了，
                // 不说的话他会回去查校准。
                if ProjectorHighlightPaint.isTooDarkToProject(projector.highlight.custom) {
                    Text("这个颜色偏暗，投影仪打出来的格子可能不太看得清。")
                        .font(.caption)
                        .foregroundColor(Theme.ColorToken.Status.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Theme.ColorToken.Surface.elevated)
        )
    }

    /// 三个常见色号（黑、深蓝、大红）在当前这种投法下投出来是什么样。
    /// 底色画成黑的：投影仪不出光的地方就是黑的，白点摆在 App 的浅色底上会看不见。
    private var sampleStrip: some View {
        HStack(spacing: Theme.Spacing.md) {
            ForEach(Self.sampleBeadHexes, id: \.self) { hex in
                let bead = Color(uiColor: UIColor(themeHex: hex, fallback: .black))
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(bead)
                        .frame(width: 13, height: 13)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .stroke(.white.opacity(0.35), lineWidth: 0.5)
                        )
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                    Circle()
                        .fill(projector.highlight.color(for: bead))
                        .frame(width: 13, height: 13)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .fill(Color.black)
        )
        .accessibilityHidden(true)   // 三个色块讲的是「看着什么样」，念出来没有意义
    }

    /// 样例用的三个色号：黑（最常用、也最说明问题）、深蓝（暗色但有色相）、大红（本来就亮）。
    private static let sampleBeadHexes = ["000000", "1F3A93", "D0021B"]

    private var styleBinding: Binding<ProjectorHighlightStyle> {
        Binding(get: { projector.highlight.style },
                set: { projector.setHighlightStyle($0) })
    }

    private var customColorBinding: Binding<Color> {
        Binding(get: { projector.highlight.custom },
                set: { projector.setCustomHighlightColor($0) })
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
