//
//  ProjectorSession.swift
//  BeadInventory
//
//  把手机上这块板送到投影仪上那个安卓 App：什么时候推、推什么、遥控器改了怎么收回来
//
//  ## 它是 BoardCastSession 的第二个消费者
//
//  `BoardCastSession` 当初就是按「一块谁都不知道对方存不存在的白板」设计的：手机那一屏
//  把「现在该画什么」写进去，谁要谁读。外接屏幕场景是第一个读的人，这里是第二个。
//  两边并排挂着，互不知道对方在。
//
//  ## 画面直接拿外屏那套渲染出图
//
//  推过去的位图是 `BoardExternalDisplayView` 用 `ImageRenderer` 离屏渲染的结果 ——
//  跟接电视时外屏上显示的是**同一套画法**。不为安卓端另写一份：另写一份的下场是
//  改高亮规则时漏掉一边，而用户是抬头对着投影拼的，一眼就看得出来。
//
//  ## 校准态反过来，一个字节画面都不推
//
//  校准那一屏上只有四个角标和几个对齐十字，没有任何图纸内容，所以整屏交给安卓端
//  本地画，这边只发四个角、板子格数和高亮颜色。用户在投影仪上按一下遥控器，那边
//  立刻重画，不用等一个网络往返 —— 他是趴在桌边盯着投影调的，慢一点就跟不上手。
//
//  ## 回声
//
//  遥控器改了角 → 这边写进 `BoardProjector` → `quad` 变了 → 差点又发回去。
//  所以记着「两端最后一次一致的那套值」的指纹，一样就不发（见
//  `calibrationSignature`）。用户之后在手机上再拖，指纹就变了，恢复正常上报。
//
//  这不只是省流量：用户长按遥控器方向键连续移动时，回发过去的是一两百毫秒前的
//  旧位置，安卓端收到会当成新的 calib 覆盖自己 —— 角标会往回跳。
//

import Combine
import SwiftUI

@MainActor
final class ProjectorSession: ObservableObject {
    static let shared = ProjectorSession()

    private let link = ProjectorLink.shared
    private var cancellables: Set<AnyCancellable> = []
    private var renderTask: Task<Void, Never>?
    /// 断线之后、真正把「外屏没了」告诉 App 之前的宽限。
    ///
    /// 没有它的时候：用户正趴在桌边拖四个角，Wi-Fi 抖一下 → `externalConnected` 变 false
    /// → 校准页被关掉 → 呈现方的 `onDismiss` 判定「真被关掉了」→ `cancelCalibrating()`
    /// 整组回滚。五秒后重连上了，而他对了两分钟的四个角回到了原点，界面上一个字都没有。
    private var disconnectGrace: Task<Void, Never>?
    /// 连着几帧出不了图。一次可能是偶然，连着两次说明这个环境下就是画不出来，
    /// 得让投影仪那边黑屏 —— 留一张过期的、看起来完全正常的板，用户会照着它按豆子。
    private var renderFailures = 0

    /// 最后一次两端已经一致的那套校准参数。收到遥控器的改动、或者自己发出去之后
    /// 都会更新它，值没变就不发 —— 幂等去重，不用管这次变化是谁触发的。
    private var lastCalibrationSignature: String?
    /// 上一次真正发出去的模式。模式没变就不重发 —— 安卓端每收到一条 `mode` 都会
    /// 切一次显示状态，重复发会让画面闪。
    private var lastSentMode: ProjectorDisplayMode?

    private init() {}

    /// App 启动时挂一次。之后连接断了又接上、用户进出校准页，都由这里自己应对。
    func activate() {
        guard cancellables.isEmpty else { return }

        link.onInbound = { [weak self] inbound in
            self?.handle(inbound)
        }

        // 上次连过的那台，开 App 就试一次。投影仪那边一直在监听，用户不该每次
        // 打开 App 都要先去设置里点一下连接。
        link.attemptAutoConnect()

        // 连上 / 断开：接上之后把当前状态整个同步一遍，用户不用回到某一屏去「触发」它。
        link.$state
            .removeDuplicates()
            .sink { [weak self] state in self?.handle(state: state) }
            .store(in: &cancellables)

        // 板子内容变了（切色号、切零件、改布局）
        BoardCastSession.shared.$content
            .sink { [weak self] _ in self?.scheduleSync() }
            .store(in: &cancellables)

        // 校准态、四个角、选中角、板子格数、投什么颜色
        let projector = BoardProjector.shared
        projector.$isCalibrating
            .sink { [weak self] _ in self?.scheduleSync() }
            .store(in: &cancellables)
        projector.$quad
            .sink { [weak self] _ in self?.scheduleSync() }
            .store(in: &cancellables)
        projector.$activeCorner
            .sink { [weak self] _ in self?.scheduleSync() }
            .store(in: &cancellables)
        projector.$boardCols
            .sink { [weak self] _ in self?.scheduleSync() }
            .store(in: &cancellables)
        projector.$boardRows
            .sink { [weak self] _ in self?.scheduleSync() }
            .store(in: &cancellables)
        // 颜色也要订：它在 calibrationSignature 里，漏了的话用户在校准页换投影颜色
        // 得等下一次拖角才顺带发出去，而他正站在投影仪旁边照着实物挑颜色。
        projector.$highlight
            .sink { [weak self] _ in self?.scheduleSync() }
            .store(in: &cancellables)
    }

    // MARK: - 连接状态

    private func handle(state: ProjectorLink.State) {
        switch state {
        case .connected(let size, _):
            disconnectGrace?.cancel()
            disconnectGrace = nil
            renderFailures = 0
            // 让现有的那套外屏逻辑认这台安卓投影仪：手机上那句「投屏中」、
            // 校准页开不开得出来，判据都是这两个值。
            BoardCastSession.shared.externalScreenSize = size
            BoardCastSession.shared.externalConnected = true
            lastSentMode = nil          // 新连接，模式和校准参数都要重发一遍
            lastCalibrationSignature = nil
            // 把 size 直接传下去，不能让 syncNow 自己去读 `link.state`。
            //
            // `@Published` 是在 **willSet** 里发出去的：这个回调跑的时候，`link.state`
            // 读出来还是上一个值（`.connecting`），`screenSize` 是 nil —— syncNow 会在
            // 第一行就掉头走人，一个字节都不发。表现是每次断线重连之后投影仪停在旧画面
            // 不动，直到用户在手机上碰点什么才恢复。
            syncNow(screen: size)
        case .idle:
            // 用户主动断开，没什么好等的。
            disconnectGrace?.cancel()
            disconnectGrace = nil
            clearExternalIfNoRealScreen()
        case .waiting, .connecting:
            // 断一下就重连上是常态（切个后台、Wi-Fi 抖一下）。这段时间里
            // 校准页要保持开着 —— 关掉它等于把用户对了一半的角丢掉。
            guard disconnectGrace == nil else { return }
            disconnectGrace = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                self?.disconnectGrace = nil
                self?.clearExternalIfNoRealScreen()
            }
        }
    }

    /// 只在没有真外接屏时才收回来。同时接着 HDMI 和投影仪 App 的人极少，
    /// 但要是有，不该因为网络断了就把外屏那份也判成没接。
    private func clearExternalIfNoRealScreen() {
        guard UIScreen.screens.count <= 1 else { return }
        BoardCastSession.shared.externalConnected = false
        BoardCastSession.shared.externalScreenSize = nil
    }

    // MARK: - 收遥控器

    private func handle(_ inbound: ProjectorInbound) {
        let projector = BoardProjector.shared
        switch inbound {
        case .quad(let values):
            guard let quad = ProjectorQuad(wireValues: values) else { return }
            if projector.applyRemoteQuad(quad) {
                // 两端此刻已经一致，记下来，别再把同一组值回发过去。
                //
                // 回发不只是浪费流量：用户长按方向键连续移动时，回发的是一两百毫秒前的
                // 旧位置，安卓端收到会当成新的 calib 覆盖自己 —— 角标会往回跳。
                lastCalibrationSignature = calibrationSignature()
            } else {
                // 拧成「8」字被本地丢掉了。此刻投影仪画的是这组被拒的角，
                // 这边是另一组 —— 必须立刻把正确的顶回去，不然用户在投影仪跟前
                // 怎么按都拉不回来。
                AppLogger.shared.warning("Projector", "remote_quad_rejected",
                                         metadata: ["quad": "\(values)"])
                lastCalibrationSignature = nil
                syncNow()
            }
        case .active(let corner):
            projector.activeCorner = corner
            lastCalibrationSignature = calibrationSignature()
        case .exit:
            // 用户在投影仪上按了返回。跟手机上点「完成」一样收尾：存下来、退出校准。
            if projector.isCalibrating { projector.finishCalibrating() }
        case .calibrationRequest:
            // 遥控器要求进校准。格数沿用上次存的那套（`suggestedBoard: nil`）——
            // 用户此刻在投影仪那头，手机上弹个选单让他回来挑是最糟的做法。
            guard !projector.isCalibrating, let screen = link.state.screenSize else { return }
            projector.beginCalibrating(suggestedBoard: nil, screen: screen)
        case .resize:
            // 尺寸变了要按新尺寸重新出图，否则安卓端会把旧图最近邻拉伸。
            syncNow()
        case .pong:
            break
        }
    }

    // MARK: - 往外发

    /// 合并一小段时间内的连续变化。用户拖角、快速滑色号列表时一秒能触发几十次，
    /// 每次都渲染一张 1920×1080 是白费的 —— 而渲染在主线程上，白费就是卡顿。
    private func scheduleSync() {
        guard link.state.isConnected else { return }
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.syncNow()
        }
    }

    /// `screen` 由调用方给的时候用给的那份。连上那一刻必须这么传，原因见
    /// `handle(state:)` 里的注释。
    private func syncNow(screen: CGSize? = nil) {
        guard let screen = screen ?? link.state.screenSize else { return }
        let projector = BoardProjector.shared
        let content = BoardCastSession.shared.content

        if projector.isCalibrating {
            send(mode: .calibrate)
            sendCalibrationIfNeeded()
            return
        }
        guard let content else {
            send(mode: .blank)
            return
        }
        send(mode: .image)
        // 不发 caption：推过去的位图里 `BoardExternalDisplayView` 已经画好了那行图例
        // （「整张图纸 · 46 × 34 格 ● B8」）。安卓端再画一遍 caption，投影上就是
        // 上下两行一模一样的字。协议里的 caption 留着不用。
        pushFrame(screen: screen)
    }

    private func send(mode: ProjectorDisplayMode) {
        guard lastSentMode != mode else { return }
        lastSentMode = mode
        link.send(.mode(mode))
    }

    /// 一套校准参数的指纹。两端一致时不重发，靠的就是它。
    private func calibrationSignature() -> String {
        let p = BoardProjector.shared
        return "\(p.quad.wireValues)|\(p.activeCorner.wireValue)"
            + "|\(p.boardCols)x\(p.boardRows)"
            + "|\(p.highlight.style.rawValue)|\(p.highlight.custom.toThemeHex())"
    }

    private func sendCalibrationIfNeeded() {
        let projector = BoardProjector.shared
        let signature = calibrationSignature()
        guard signature != lastCalibrationSignature else { return }
        lastCalibrationSignature = signature
        link.send(.calibration(
            quad: projector.quad.wireValues,
            active: projector.activeCorner,
            cols: projector.boardCols,
            rows: projector.boardRows,
            paintStyle: projector.highlight.style.rawValue,
            paintHex: "#" + projector.highlight.custom.toThemeHex()
        ))
    }

    /// 按安卓端报上来的尺寸 1:1 离屏渲染一张 PNG。
    ///
    /// `scale` 必须显式设成 1：默认跟着手机屏幕走（3 倍），出来的图会是 5760×3240 ——
    /// 安卓端只能把它缩回去，而缩放正是这个功能要避免的东西，顺带还白编码了九倍面积的 PNG。
    private func pushFrame(screen: CGSize) {
        let width = Int(screen.width.rounded())
        let height = Int(screen.height.rounded())
        guard width > 0, height > 0, width <= 65535, height <= 65535 else {
            AppLogger.shared.error("Projector", "frame_size_invalid",
                                   metadata: ["size": "\(width)x\(height)"])
            return
        }

        let renderer = ImageRenderer(
            content: BoardExternalDisplayView()
                .frame(width: screen.width, height: screen.height)
                // 离屏渲染默认走浅色，那样图例文字会整个反过来。投影画面是黑底的，
                // 必须钉死深色。
                .environment(\.colorScheme, .dark)
        )
        renderer.scale = 1
        renderer.isOpaque = true
        guard let image = renderer.uiImage else {
            handleRenderFailure(stage: "uiImage", screen: screen)
            return
        }
        renderFailures = 0

        // 出图必须在主线程（ImageRenderer 的要求），但 PNG 编码是这一串里最贵的一步
        // —— 一张 1920×1080 编下来几十上百毫秒。留在主线程的话，用户每切一次色号
        // 手机就顿一下，而他正在那块屏上滑色号列表。
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let png = image.pngData() else {
                await MainActor.run { self?.handleRenderFailure(stage: "pngData", screen: screen) }
                return
            }
            let w = Int(image.size.width.rounded())
            let h = Int(image.size.height.rounded())
            await MainActor.run { self?.link.sendFrame(png: png, width: w, height: h) }
        }
    }

    /// 出不了图时别装作没事。
    ///
    /// 安卓端按设计**保持最后一帧不动**，所以这里悄悄返回的后果是：链路活着、心跳正常、
    /// 手机上写着「投影仪模式」，而墙上还亮着上一块板 —— 用户抬头照着它把豆子按进错的
    /// 孔位，按几十颗才发现。宁可让那边黑屏。
    private func handleRenderFailure(stage: String, screen: CGSize) {
        renderFailures += 1
        AppLogger.shared.error("Projector", "render_frame_failed", metadata: [
            "stage": stage,
            "screen": "\(Int(screen.width))x\(Int(screen.height))",
            "count": "\(renderFailures)"
        ])
        guard renderFailures >= 2 else { return }
        send(mode: .blank)
    }
}
