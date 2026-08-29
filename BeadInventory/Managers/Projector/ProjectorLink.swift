//
//  ProjectorLink.swift
//  BeadInventory
//
//  跟投影仪上那个安卓 App 的连接：握手、收发、断了自己接回来
//
//  ## 谁连谁
//
//  安卓端是服务端，这边是客户端。投影仪有一块大屏可以把自己的地址显示出来让人扫，
//  而 iPhone 一切后台连接就断 —— 服务端常驻在那边，这边回前台重连就行，
//  比反过来简单得多。
//
//  ## 断线是常态，不是异常
//
//  用户在拼豆时会切出去看图纸、会锁屏、会走开。每一次都会断。所以这里没有「连接失败」
//  这种终态：只要用户还没主动停止，就一直往回连。安卓端那边保持着最后一帧不动，
//  用户拼当前色号根本不需要新帧，多数时候他不会发现断过。
//
//  ## 帧序号要跨连接单调
//
//  安卓端只显示序号比当前更大的帧，而且**重连不会重置**它记住的那个值。所以序号不能
//  每次连接从 0 开始（那样重连之后推过去的帧会被全部丢掉，症状是「连上了但画面不更新」）。
//  光用 Unix 秒当初值也不够 —— 序号按帧递增，比墙钟快得多。见 `initialSequence()`。
//

import Combine
import CryptoKit
import Foundation
import UIKit

@MainActor
final class ProjectorLink: NSObject, ObservableObject {
    static let shared = ProjectorLink()

    enum State: Equatable {
        case idle
        /// 正在连（首次连接，或者断了之后往回连）
        case connecting
        /// 连上了。`size` 是那边的显示尺寸，渲染要按它出图。
        case connected(size: CGSize, device: String)
        /// 连不上。`reason` **会直接显示在「连接投影仪」那一屏上** ——
        /// 写进去之前先当成界面文案审一遍，别往里塞 `error.localizedDescription`
        /// （用户读不懂 "Socket is not connected"，也不需要知道「App 进入后台」）。
        /// 排查用的细节走 `AppLogger`。
        case waiting(reason: String)

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }

        var screenSize: CGSize? {
            if case .connected(let size, _) = self { return size }
            return nil
        }
    }

    @Published private(set) var state: State = .idle
    /// 用户配过的那台。存着下次自动连，也是「忘记这台投影仪」要清掉的东西。
    @Published private(set) var pairing: ProjectorPairing? {
        didSet { persistPairing() }
    }

    /// 收到安卓端的消息。业务侧（`ProjectorSession`）挂在这上面。
    var onInbound: ((ProjectorInbound) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var cipher: ProjectorCipher?
    private var heartbeat: Task<Void, Never>?
    private var receiveLoop: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?
    private var retryCount = 0
    /// 不处于自动重连模式。**初值为真**（还没开始过），另外用户点「断开」、凭据被拒、
    /// 冷启动那次静默失败都会置真 —— 名字里的 byUser 只覆盖其中一种情况。
    private var stoppedByUser = true
    /// 这次是冷启动时的自动尝试。失败就安静收手，不进入「断了一直接」那套。
    private var isAutoAttempt = false
    /// 握手之后解不开包的次数。密钥路径对不上时每次重连都会走到这里，
    /// 无限重连是白转 —— 连着几次就该停下来让用户重新配对。
    private var decryptFailures = 0
    private var sequence: UInt32 = ProjectorLink.initialSequence()
    /// 最后一次收到对方任何一条消息的时刻。**判断连接死没死靠它，不靠「发送有没有报错」**。
    ///
    /// 投影仪那头的 App 被系统回收、或者用户重启了它，TCP 这边可能一点动静都没有：
    /// 内核照收不误，要等重传耗尽才报错，那是几分钟。这期间手机上一直写着「已连接」，
    /// 而投影仪早就回到配对屏了 —— 用户两边看着自相矛盾，还不知道该点什么。
    private var lastInboundAt = Date()
    private var lifecycleObservers: [NSObjectProtocol] = []

    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        // 这是**长连接**，不能按「请求」的超时来管。
        //
        // 实测：即使有 5 秒一次的心跳，这个值设成 10 秒仍然会「投着投着自己断」——
        // 说明 URLSession 并不把我们的收发当成这条 WebSocket 的活动来重置它。
        // 所以只能放大到远超一次使用时长的量级，存活交给心跳（安卓端 15 秒收不到消息才断）。
        // 代价是握手也失去了时限，那一段单独用 `handshakeWithTimeout` 兜。
        config.timeoutIntervalForRequest = 3600
        return URLSession(configuration: config)
    }()

    /// 多久收不到任何消息就判定对方没了。心跳 5 秒一次，留三次的余量 ——
    /// 短了会在网络抖一下时误判，长了用户会对着一个假的「已连接」发呆。
    private static let silenceTimeout: TimeInterval = 16

    private enum Key {
        static let pairing = "projectorLink.pairing"
        static let sequence = "projectorLink.lastSequence"
    }

    /// 帧序号的起点。
    ///
    /// 安卓端只显示序号更大的帧，而且**重连不会重置**它记住的值。光拿 Unix 秒当初值
    /// 不够：序号是按帧递增的（去抖 120ms，最快约 8 帧/秒），比墙钟快得多，连投一阵子
    /// 之后重启 App，新的初值完全可能落在上次的末值之下 —— 症状是「连上了但画面再也
    /// 不更新」。所以把末值也存下来，取两者的大者。
    private static func initialSequence() -> UInt32 {
        let saved = UInt32(UserDefaults.standard.integer(forKey: Key.sequence))
        let now = UInt32(max(0, Date().timeIntervalSince1970))
        return max(now, saved &+ 1)
    }

    private override init() {
        super.init()
        pairing = Self.loadPairing()
        observeLifecycle()
    }

    // MARK: - 开关

    /// 配一台新的（扫码或手输之后）。会立刻连上去。
    func connect(to pairing: ProjectorPairing) {
        self.pairing = pairing
        stoppedByUser = false
        isAutoAttempt = false
        retryCount = 0
        startConnecting()
    }

    /// 冷启动时拿存着的那台试一次。
    ///
    /// **只试一次**：投影仪没开机时无限重连纯粹是耗电，而用户此刻大概率根本没打算
    /// 投屏。他真要用的时候会去点「连接」，那之后才进入「断了就一直往回接」的模式。
    func attemptAutoConnect() {
        guard pairing != nil, stoppedByUser else { return }
        stoppedByUser = false
        isAutoAttempt = true
        retryCount = 0
        startConnecting()
    }

    /// 用上次配过的那台再连一次。没配过就什么都不做。
    func reconnectSaved() {
        guard pairing != nil else { return }
        stoppedByUser = false
        isAutoAttempt = false
        retryCount = 0
        startConnecting()
    }

    /// 用户主动断开。不清掉配对信息，下次还能一键连回来。
    func disconnect() {
        stoppedByUser = true
        teardown()
        state = .idle
    }

    /// 忘记这台投影仪，连配对信息一起清掉。
    func forgetDevice() {
        disconnect()
        pairing = nil
    }

    // MARK: - 发消息

    func send(_ message: ProjectorOutbound) {
        guard let data = try? JSONSerialization.data(withJSONObject: message.json) else { return }
        sendEncrypted(data, as: .control)
    }

    /// 推一帧画面。宽高必须是这张 PNG 真正的尺寸 —— 安卓端会拿它跟解码结果比对，
    /// 对不上整帧丢弃。
    func sendFrame(png: Data, width: Int, height: Int) {
        sequence &+= 1
        UserDefaults.standard.set(Int(sequence), forKey: Key.sequence)
        let payload = ProjectorBitmapFrame.encode(
            sequence: sequence, width: width, height: height, png: png
        )
        sendEncrypted(payload, as: .bitmap)
    }

    private func sendEncrypted(_ plaintext: Data, as type: ProjectorCipher.FrameType) {
        guard let task, let cipher else { return }
        do {
            let packet = try cipher.seal(plaintext, as: type)
            task.send(.data(packet)) { [weak self, weak task] error in
                guard let error else { return }
                Task { @MainActor in
                    // 认一下这条回调是不是当前连接的。URLSession 的发送回调可以在任务
                    // cancel 之后才送达，而最短重连间隔只有 1 秒 —— 旧连接的迟到错误
                    // 会掐掉刚接好的新连接，表现是「刚连上又断了，来回抖」。
                    guard let self, let task, self.task === task else { return }
                    self.handleFailure("发送失败：\(error.localizedDescription)")
                }
            }
        } catch {
            handleFailure("加密失败：\(error)")
        }
    }

    // MARK: - 连接

    private func startConnecting() {
        guard let pairing, let credential = pairing.credential, let ikm = pairing.handshakeIKM else {
            state = .waiting(reason: String(localized: "配对信息已失效，请重新扫码或输入配对码"))
            return
        }
        // 用户把地址抄错（多打一个空格、少一位）时，说「配对信息不完整」是误导 ——
        // 他的配对信息很完整，是地址不合法。
        guard let url = pairing.webSocketURL else {
            state = .waiting(reason: String(localized: "投影仪地址格式不正确，请核对屏幕上显示的地址"))
            return
        }
        teardown(keepState: true)
        state = .connecting

        let task = urlSession.webSocketTask(with: url)
        self.task = task
        task.resume()

        Task { [weak self] in
            do {
                let (key, welcome) = try await Self.handshakeWithTimeout(
                    task: task, credential: credential, ikm: ikm)
                guard let self, self.task === task else { return }
                guard let cipher = ProjectorCipher(sessionKey: key) else {
                    self.handleFailure("随机数生成失败")
                    return
                }
                self.cipher = cipher
                self.retryCount = 0
                self.isAutoAttempt = false
                self.decryptFailures = 0
                self.lastInboundAt = Date()
                AppLogger.shared.info("Projector", "connected", metadata: [
                    "device": welcome.device,
                    "size": "\(welcome.width)x\(welcome.height)"
                ])
                self.state = .connected(
                    size: CGSize(width: welcome.width, height: welcome.height),
                    device: welcome.device
                )
                self.startReceiving(on: task)
                self.startHeartbeat()
            } catch {
                guard let self, self.task === task else { return }
                // 凭据被拒是**终态**，不能进重试循环。
                //
                // 6 位短码在投影仪那边每次开 App 都会换一个新的，旧码重试一万次也进不去；
                // 更糟的是安卓端数到 5 次失败就会把屏幕上那个码整个换掉 —— 于是用户照着
                // 屏幕抄的码刚输进来就被自己后台的重试顶失效了，表现是「明明照着抄的却
                // 一直连不上」。密钥被轮换掉时同理，重试也没有意义。
                if case ProjectorLinkError.denied = error {
                    AppLogger.shared.info("Projector", "pairing_denied")
                    self.stoppedByUser = true
                    self.isAutoAttempt = false
                    self.teardown(keepState: true)
                    self.state = .waiting(reason: String(
                        localized: "配对码不对。投影仪重启后会换一个新码，请照屏幕上显示的重新输入。"))
                    return
                }
                self.handleFailure("握手失败：\(error.localizedDescription)")
            }
        }
    }

    private struct Welcome {
        let width: Int
        let height: Int
        let device: String
    }

    /// 给握手加个时限。
    ///
    /// `timeoutIntervalForRequest` 为了长连接被放到了 3600 秒，于是握手这一步也没了
    /// 时限：对方接受了 TCP 却不回 `welcome`（安卓端卡死、端口填错连到别的服务上、
    /// 本地网络权限还没批），这个 await 就一直挂着 —— 心跳还没起来，重连也排不上，
    /// 用户看到的是一个转不完的圈。
    ///
    /// **握手是整条链路上唯一没有看门狗的一段。** 连上之后有心跳兜着：16 秒收不到
    /// 回音就 `handleFailure` → `teardown` → 掐 socket，自己能爬出来。而心跳是握手
    /// 成功之后才起的，所以卡在这一段就只能靠这里自己了断。
    private static func handshakeWithTimeout(
        task: URLSessionWebSocketTask, credential: String, ikm: Data
    ) async throws -> (SymmetricKey, Welcome) {
        try await withThrowingTaskGroup(of: (SymmetricKey, Welcome).self) { group in
            group.addTask { try await handshake(task: task, credential: credential, ikm: ikm) }
            group.addTask {
                try await Task.sleep(for: .seconds(8))
                // 这一句不能省，`cancelAll()` 代替不了它。
                //
                // 超时分支抛错之后，task group 还要等另一个分支结束才返回，而那个分支
                // 卡在 `URLSessionWebSocketTask.receive()` 里 —— 这个调用**不理会 Swift
                // 的任务取消**（实测：只 cancelAll 的话 20 秒后仍然没返回）。能把它放
                // 出来的只有掐掉 socket 本身，而 `teardown()` 里那句 cancel 要等这里先
                // 返回才轮得到 —— 绕成一个圈，谁也等不到谁。
                //
                // 症状：iOS 永远停在「正在连接」，不重试也不报错，手机上做什么投影仪
                // 都没反应，只有重启 App 能解开。而每次断线重连都会走这里一遍。
                task.cancel(with: .goingAway, reason: nil)
                throw ProjectorLinkError.badHandshake("投影仪没有回应")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// 握手的两条消息是**明文文本帧**，之后每一条都必须是二进制帧 ——
    /// 安卓端收到握手后的文本帧会直接断开连接。
    private static func handshake(
        task: URLSessionWebSocketTask, credential: String, ikm: Data
    ) async throws -> (SymmetricKey, Welcome) {
        var salt = Data(count: 16)
        // 失败时 salt 会保持全零，而会话密钥就由它派生 —— 短码路径下 IKM 只有 6 位数字，
        // salt 一固定，离线把整张表算出来是分钟级的事。不能当没发生。
        let saltStatus = salt.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        guard saltStatus == errSecSuccess else {
            throw ProjectorLinkError.badHandshake("随机数生成失败(\(saltStatus))")
        }

        let hello: [String: Any] = [
            "t": "hello",
            "proto": 1,
            "cred": credential,
            "salt": salt.base64URLEncodedString(),
            "device": UIDevice.current.name
        ]
        let helloData = try JSONSerialization.data(withJSONObject: hello)
        try await task.send(.string(String(decoding: helloData, as: UTF8.self)))

        let response = try await task.receive()
        guard case .string(let text) = response,
              let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw ProjectorLinkError.badHandshake("回应不是文本 JSON")
        }
        if json["t"] as? String == "denied" {
            throw ProjectorLinkError.denied
        }
        guard json["t"] as? String == "welcome",
              let width = (json["w"] as? NSNumber)?.intValue,
              let height = (json["h"] as? NSNumber)?.intValue else {
            throw ProjectorLinkError.badHandshake("缺少 welcome 字段")
        }
        // 安卓端在拿到 display metrics 之前会报 0×0。放过去的话：握手成功、chip 亮起
        // 「投影中」、而每一帧都在 pushFrame 的尺寸检查处被丢掉，投影永远是黑的。
        guard (1...16384).contains(width), (1...16384).contains(height) else {
            throw ProjectorLinkError.badHandshake("投影仪报告的画面尺寸无效")
        }
        let key = ProjectorCipher.deriveSessionKey(ikm: ikm, salt: salt)
        return (key, Welcome(width: width, height: height, device: json["device"] as? String ?? ""))
    }

    private func startReceiving(on task: URLSessionWebSocketTask) {
        receiveLoop?.cancel()
        receiveLoop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    guard let self, self.task === task else { return }
                    guard case .data(let packet) = message else {
                        // 握手之后只可能是二进制。收到别的说明两端对协议的理解已经不一致了。
                        self.handleFailure("握手后收到非二进制消息")
                        return
                    }
                    self.handle(packet: packet)
                } catch {
                    guard let self, self.task === task else { return }
                    self.handleFailure("连接中断：\(error.localizedDescription)")
                    return
                }
            }
        }
    }

    private func handle(packet: Data) {
        lastInboundAt = Date()
        guard let cipher else { return }
        do {
            let (type, plaintext) = try cipher.open(packet)
            guard type == .control,
                  let json = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
                  let inbound = ProjectorInbound(json: json) else { return }
            if case .resize(let w, let h) = inbound, case .connected(_, let device) = state {
                state = .connected(size: CGSize(width: w, height: h), device: device)
            }
            decryptFailures = 0
            onInbound?(inbound)
        } catch {
            AppLogger.shared.error("Projector", "decrypt_failed",
                                   metadata: ["error": "\(error)"])
            decryptFailures += 1
            // 握手过了却解不开包，最常见的原因是两端的密钥路径没选到同一条
            // （见 `ProjectorPairing.handshakeIKM`）。那种情况下重连一万次也是同样的结果，
            // 用户看到的是一个永远在「正在连接 / 连接中断」之间跳的界面。
            if decryptFailures >= 3 {
                stoppedByUser = true
                teardown(keepState: true)
                state = .waiting(reason: String(
                    localized: "与投影仪的加密通道校验失败，请重新扫码或输入配对码。"))
                return
            }
            handleFailure("解密失败")
        }
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            var id = 0
            while !Task.isCancelled {
                // 安卓端 15 秒收不到任何消息就断开，5 秒一次留足余量。
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                id += 1
                guard let self else { return }
                // 安卓端每条 ping 都会立刻回 pong。连着几次一点回音都没有，
                // 说明那头已经不在了，别再干等 TCP 自己超时。
                if Date().timeIntervalSince(self.lastInboundAt) > Self.silenceTimeout {
                    self.handleFailure("投影仪没有回应")
                    return
                }
                self.send(.ping(id))
            }
        }
    }

    // MARK: - 断线与重连

    private func handleFailure(_ reason: String) {
        AppLogger.shared.error("Projector", "connection_failed", metadata: [
            "reason": reason, "retry": "\(retryCount)"
        ])
        teardown(keepState: true)
        guard !stoppedByUser else {
            state = .idle
            return
        }
        if isAutoAttempt {
            // 冷启动那一次没连上：投影仪多半没开机。安静收手，别让界面上出现
            // 一个用户没要求过的失败提示。
            AppLogger.shared.info("Projector", "auto_connect_gave_up",
                                  metadata: ["reason": reason])
            isAutoAttempt = false
            stoppedByUser = true
            state = .idle
            return
        }
        // 界面上只说「在重连」。具体是超时、被重置还是解密失败，用户既看不懂也
        // 帮不上忙 —— 那些已经进日志了。
        state = .waiting(reason: String(localized: "与投影仪的连接中断，正在重新连接"))
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnect?.cancel()
        // 头几次很快，之后退到 5 秒一次：投影仪那边一直在监听，用户回到 App 时
        // 最多等 5 秒就自己接上了，不需要他去点任何东西。
        let delay = min(pow(2.0, Double(retryCount)), 5.0)
        retryCount += 1
        reconnect = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            guard let self, !self.stoppedByUser else { return }
            self.startConnecting()
        }
    }

    private func teardown(keepState: Bool = false) {
        heartbeat?.cancel(); heartbeat = nil
        receiveLoop?.cancel(); receiveLoop = nil
        reconnect?.cancel(); reconnect = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        cipher = nil
        if !keepState { state = .idle }
    }

    // MARK: - 前后台

    /// 切后台连接必断，回前台立刻接回来。
    ///
    /// 不做「后台保活」：那要么被系统掐掉，要么要申请一个我们并不需要的后台模式，
    /// 审核也过不去。反正安卓端那边画面停在最后一帧，用户拼当前色号不需要新帧。
    private func observeLifecycle() {
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.stoppedByUser else { return }
                self.teardown(keepState: true)
                self.state = .waiting(reason: String(localized: "回到 App 后会自动重新连接"))
            }
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.stoppedByUser else { return }
                self.retryCount = 0
                self.startConnecting()
            }
        })
    }

    // MARK: - 存档

    private func persistPairing() {
        let defaults = UserDefaults.standard
        guard let pairing, let data = try? JSONEncoder().encode(pairing) else {
            defaults.removeObject(forKey: Key.pairing)
            return
        }
        defaults.set(data, forKey: Key.pairing)
    }

    private static func loadPairing() -> ProjectorPairing? {
        guard let data = UserDefaults.standard.data(forKey: Key.pairing) else { return nil }
        return try? JSONDecoder().decode(ProjectorPairing.self, from: data)
    }
}

enum ProjectorLinkError: LocalizedError {
    case denied
    case badHandshake(String)

    var errorDescription: String? {
        switch self {
        case .denied: return String(localized: "投影仪拒绝了这个配对码")
        case .badHandshake(let detail): return detail
        }
    }
}
