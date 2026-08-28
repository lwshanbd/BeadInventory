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
//  这里拿当前 Unix 秒当初值，跟安卓端自带的模拟客户端一个路数。
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
        /// 连不上，等下一次重试。`reason` 只给排查用，不往界面上摆。
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
    /// 用户主动停止过。为真时不再自动重连 —— 否则用户点了「断开」它自己又连回来。
    private var stoppedByUser = true
    /// 这次是冷启动时的自动尝试。失败就安静收手，不进入「断了一直接」那套。
    private var isAutoAttempt = false
    private var sequence: UInt32 = UInt32(Date().timeIntervalSince1970)
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
        // 这是**长连接**，不能按「请求」的超时来管：投影仪模式下用户按十分钟豆子才切
        // 一次色号，中间本来就没有数据流动。设成 10 秒的话，系统会在一段安静之后把
        // 连接判成超时掐掉 —— 表现正是「投着投着自己断了」。
        // 存活由 5 秒一次的心跳保证（安卓端 15 秒收不到消息才断）。
        config.timeoutIntervalForRequest = 3600
        return URLSession(configuration: config)
    }()

    /// 多久收不到任何消息就判定对方没了。心跳 5 秒一次，留三次的余量 ——
    /// 短了会在网络抖一下时误判，长了用户会对着一个假的「已连接」发呆。
    private static let silenceTimeout: TimeInterval = 16

    private enum Key {
        static let pairing = "projectorLink.pairing"
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
        let payload = ProjectorBitmapFrame.encode(
            sequence: sequence, width: width, height: height, png: png
        )
        sendEncrypted(payload, as: .bitmap)
    }

    private func sendEncrypted(_ plaintext: Data, as type: ProjectorCipher.FrameType) {
        guard let task, cipher != nil else { return }
        do {
            // cipher 里有 nonce 计数器，必须原地改。安卓端会拒绝重复或倒退的 nonce。
            let packet = try cipher!.seal(plaintext, as: type)
            task.send(.data(packet)) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in self?.handleFailure("发送失败：\(error.localizedDescription)") }
            }
        } catch {
            handleFailure("加密失败：\(error)")
        }
    }

    // MARK: - 连接

    private func startConnecting() {
        guard let pairing,
              let url = pairing.webSocketURL,
              let credential = pairing.credential,
              let ikm = pairing.handshakeIKM else {
            state = .waiting(reason: "配对信息不完整")
            return
        }
        teardown(keepState: true)
        state = .connecting

        let task = urlSession.webSocketTask(with: url)
        self.task = task
        task.resume()

        Task { [weak self] in
            do {
                let (key, welcome) = try await Self.handshake(task: task, credential: credential, ikm: ikm)
                guard let self, self.task === task else { return }
                self.cipher = ProjectorCipher(sessionKey: key)
                self.retryCount = 0
                self.isAutoAttempt = false
                self.lastInboundAt = Date()
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

    /// 握手的两条消息是**明文文本帧**，之后每一条都必须是二进制帧 ——
    /// 安卓端收到握手后的文本帧会直接断开连接。
    private static func handshake(
        task: URLSessionWebSocketTask, credential: String, ikm: Data
    ) async throws -> (SymmetricKey, Welcome) {
        var salt = Data(count: 16)
        salt.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }

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
              let width = json["w"] as? Int, let height = json["h"] as? Int else {
            throw ProjectorLinkError.badHandshake("缺少 welcome 字段")
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
        guard cipher != nil else { return }
        do {
            let (type, plaintext) = try cipher!.open(packet)
            guard type == .control,
                  let json = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
                  let inbound = ProjectorInbound(json: json) else { return }
            if case .resize(let w, let h) = inbound, case .connected(_, let device) = state {
                state = .connected(size: CGSize(width: w, height: h), device: device)
            }
            onInbound?(inbound)
        } catch {
            handleFailure("解密失败：\(error)")
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
        teardown(keepState: true)
        guard !stoppedByUser else {
            state = .idle
            return
        }
        if isAutoAttempt {
            // 冷启动那一次没连上：投影仪多半没开机。安静收手，别让界面上出现
            // 一个用户没要求过的失败提示。
            isAutoAttempt = false
            stoppedByUser = true
            state = .idle
            return
        }
        state = .waiting(reason: reason)
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
                self.state = .waiting(reason: "App 进入后台")
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
