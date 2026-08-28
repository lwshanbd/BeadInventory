//
//  ProjectorProtocol.swift
//  BeadInventory
//
//  跟安卓投影接收端之间那套线协议：配对凭据、加密帧、控制消息
//
//  ## 为什么要有一个安卓 App
//
//  投影仪模式原本靠 iOS 系统屏幕镜像把画面送到投影仪上。低价投影仪自带的投屏接收
//  模块很不稳定，连着连着就断；而且手机竖屏画面被缩放旋转成投影仪的横屏，格子边缘
//  全是插值糊出来的，用户照着按豆子会按错孔。
//
//  改成往装在投影仪上的安卓 App 直接推画面之后，连接归我们自己管，画面按投影仪的
//  原生分辨率 1:1 出图，而且**断线时安卓端保持最后一帧不动** —— 镜像一断画面就没了，
//  而用户手上正抓着一把豆子。
//
//  ## 传的是像素，不是图纸
//
//  推过去的是**渲染好的位图**，不是「哪一格是什么色号」的数据结构。安卓端因此只是
//  一块屏幕，拿到的东西跟用户举起手机拍投影没有区别，落不成一份能导进别家 App 的图纸。
//
//  唯一的例外是**校准态**：那一屏上只有四个角标和几个对齐十字，没有任何图纸内容，
//  所以整屏交给安卓端本地画，这边只传四个角的八个浮点数。这样遥控器按一下，那边
//  立刻重画，不用等一个网络往返 —— 用户是趴在桌边盯着投影调的，慢一点就跟不上手。
//
//  ## 协议本身
//
//  完整规格见安卓仓库的 `PROTOCOL.md`。这边只实现客户端一侧，字段名、单位、顺序
//  都是契约的一部分，**改这里之前先确认安卓端跟着改**。
//

import CryptoKit
import Foundation

// MARK: - 连一台投影仪需要的东西

/// 扫码或手输得到的一台投影仪的地址和凭据。
///
/// 两条认证路径：扫码拿到 32 字节 `secret`，手输只有 6 位 `shortCode`。
/// 会话密钥由用上的那一条派生（见 `handshakeIKM`）—— 短码那条明显更弱，
/// 是给「二维码扫不动」和「模拟器没有摄像头」兜底用的，不要试图加强它。
struct ProjectorPairing: Equatable, Codable, Sendable {
    var host: String
    var port: Int
    /// 32 字节完整密钥。只手输短码时为 nil。
    var secret: Data?
    var shortCode: String?
    var deviceId: String?
    var deviceName: String?

    var displayName: String {
        if let name = deviceName, !name.isEmpty { return name }
        return "\(host):\(port)"
    }

    var webSocketURL: URL? { URL(string: "ws://\(host):\(port)/") }

    /// 握手时写进 `hello.cred` 的那一串。安卓端拿它判断走哪条路径。
    var credential: String? {
        if let secret { return secret.base64URLEncodedString() }
        return shortCode
    }

    /// 派生会话密钥的输入材料。**必须跟 `credential` 选的是同一条路径** ——
    /// 两边不一致的话握手会过，之后第一条加密消息就解不开，症状是「连上了立刻断」。
    var handshakeIKM: Data? {
        if let secret { return secret }
        return shortCode?.data(using: .utf8)
    }

    /// 解析二维码里那个 URI：
    /// `beadprojector://<ip>:<port>/?s=<密钥>&c=<短码>&d=<设备id>&n=<设备名>`
    init?(uri: String) {
        guard let components = URLComponents(string: uri),
              components.scheme == "beadprojector",
              let host = components.host,
              let port = components.port else { return nil }
        self.host = host
        self.port = port
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        // 密钥解不出来或长度不对就当没有，退回短码那条路 —— 总比整个二维码作废好。
        self.secret = value("s").flatMap { Data(base64URLEncoded: $0) }.flatMap { $0.count == 32 ? $0 : nil }
        self.shortCode = value("c")
        self.deviceId = value("d")
        self.deviceName = value("n")
        guard secret != nil || shortCode != nil else { return nil }
    }

    /// 手输那条路：IP、端口、6 位码。
    init(host: String, port: Int, shortCode: String) {
        self.host = host
        self.port = port
        self.secret = nil
        self.shortCode = shortCode
        self.deviceId = nil
        self.deviceName = nil
    }
}

// MARK: - 加密通道

/// 握手之后每条消息的封装：`[1 字节 type][12 字节 nonce][AES-256-GCM 密文 + tag]`。
///
/// nonce 是「4 字节会话随机前缀 + 8 字节大端递增计数器」。安卓端会**拒绝**前缀中途
/// 变化、计数器重复或倒退的包，所以这个类型必须是连接级唯一的一份，
/// 不要为了图省事在每次发送时新建。
struct ProjectorCipher {
    enum FrameType: UInt8 {
        case control = 0x01
        case bitmap = 0x02
    }

    enum Failure: Error {
        case packetTooShort
        case unknownFrameType(UInt8)
        case noncePrefixChanged
        case nonceReplayed
    }

    private let key: SymmetricKey
    private let sendPrefix: Data
    private var sendCounter: UInt64 = 0
    private var receivePrefix: Data?
    private var lastReceiveCounter: UInt64?

    init(sessionKey: SymmetricKey) {
        self.key = sessionKey
        var prefix = Data(count: 4)
        prefix.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
        self.sendPrefix = prefix
    }

    /// 按协议派生会话密钥。info 串是契约的一部分，两端必须逐字一致。
    static func deriveSessionKey(ikm: Data, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: Data("beadprojector-v1".utf8),
            outputByteCount: 32
        )
    }

    mutating func seal(_ plaintext: Data, as type: FrameType) throws -> Data {
        var nonceData = sendPrefix
        nonceData.append(contentsOf: withUnsafeBytes(of: sendCounter.bigEndian) { Data($0) })
        sendCounter += 1

        let box = try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: try AES.GCM.Nonce(data: nonceData),
            authenticating: Data([type.rawValue])
        )
        var packet = Data([type.rawValue])
        packet.append(nonceData)
        packet.append(box.ciphertext)
        packet.append(box.tag)
        return packet
    }

    mutating func open(_ packet: Data) throws -> (type: FrameType, plaintext: Data) {
        guard packet.count >= 1 + 12 + 16 else { throw Failure.packetTooShort }
        let raw = packet[packet.startIndex]
        guard let type = FrameType(rawValue: raw) else { throw Failure.unknownFrameType(raw) }

        let nonceData = packet.subdata(in: packet.startIndex + 1 ..< packet.startIndex + 13)
        let prefix = nonceData.prefix(4)
        let counter = nonceData.suffix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        if let known = receivePrefix {
            guard known == prefix else { throw Failure.noncePrefixChanged }
        } else {
            receivePrefix = Data(prefix)
        }
        if let last = lastReceiveCounter, counter <= last { throw Failure.nonceReplayed }

        let body = packet.subdata(in: packet.startIndex + 13 ..< packet.endIndex)
        let box = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: nonceData),
            ciphertext: body.dropLast(16),
            tag: body.suffix(16)
        )
        let plaintext = try AES.GCM.open(box, using: key, authenticating: Data([raw]))
        lastReceiveCounter = counter
        return (type, plaintext)
    }
}

// MARK: - 位图帧

enum ProjectorBitmapFrame {
    /// `[4 字节 seq][2 字节 宽][2 字节 高][1 字节 格式][PNG 字节]`，整数全是大端。
    ///
    /// 安卓端会校验声明的宽高跟 PNG 解出来的是否一致，对不上整帧丢弃 —— 所以宽高
    /// 必须来自真正编码出来的那张图，不能拿「我打算渲染多大」去填。
    static func encode(sequence: UInt32, width: Int, height: Int, png: Data) -> Data {
        var data = Data(capacity: 9 + png.count)
        data.append(contentsOf: withUnsafeBytes(of: sequence.bigEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(width).bigEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(height).bigEndian) { Data($0) })
        data.append(1)   // 1 = PNG
        data.append(png)
        return data
    }
}

// MARK: - 控制消息

/// 安卓端发过来的。
enum ProjectorInbound {
    /// 那边的显示尺寸变了。渲染尺寸要跟着改，不然推过去的图会被最近邻拉伸。
    case resize(width: Int, height: Int)
    /// 遥控器把四个角挪了。八个数，顺序 TL TR BR BL，x 和 y 都以画面宽度为单位。
    case quad([Double])
    /// 遥控器切了当前调整的角。
    case active(ProjectorCorner)
    /// 用户在投影仪上按了返回键，要求退出校准。
    case exit
    /// 用户在投影仪上长按了确定键，要求**进入**校准。
    ///
    /// 人是站在投影仪跟前拿着遥控器的，要他为了「开始校准」走回去摸手机，这个功能
    /// 就等于没有。
    case calibrationRequest
    case pong

    init?(json: [String: Any]) {
        switch json["t"] as? String {
        case "resize":
            guard let w = json["w"] as? Int, let h = json["h"] as? Int else { return nil }
            self = .resize(width: w, height: h)
        case "quad":
            guard let q = json["q"] as? [Double], q.count == 8 else { return nil }
            self = .quad(q)
        case "active":
            guard let c = json["c"] as? String, let corner = ProjectorCorner(wireValue: c) else { return nil }
            self = .active(corner)
        case "exit":
            self = .exit
        case "calibRequest":
            self = .calibrationRequest
        case "pong":
            self = .pong
        default:
            return nil
        }
    }
}

/// 这边发过去的。
enum ProjectorOutbound {
    /// 那边现在该显示什么。
    case mode(ProjectorDisplayMode)
    /// 校准参数。安卓端拿它本地画角标，这边不推位图。
    case calibration(quad: [Double], active: ProjectorCorner, cols: Int, rows: Int, paintStyle: String, paintHex: String)
    /// 画面底部那行字。**是拼好的完整句子** —— 安卓端不知道自己在为哪种模式服务，
    /// 也不该知道，跟外屏那份 caption 的约定一致。
    case caption(String)
    case ping(Int)

    var json: [String: Any] {
        switch self {
        case .mode(let mode):
            return ["t": "mode", "m": mode.rawValue]
        case .calibration(let quad, let active, let cols, let rows, let style, let hex):
            return ["t": "calib", "q": quad, "c": active.wireValue,
                    "cols": cols, "rows": rows,
                    "paint": ["style": style, "hex": hex]]
        case .caption(let text):
            return ["t": "caption", "text": text]
        case .ping(let id):
            return ["t": "ping", "id": id]
        }
    }
}

enum ProjectorDisplayMode: String {
    /// 黑屏。手机上没有板子可给的时候。
    case blank
    /// 显示推过去的位图。
    case image
    /// 安卓端本地画校准图形，忽略位图。
    case calibrate
}

// MARK: - 四个角在协议里怎么写

extension ProjectorCorner {
    var wireValue: String {
        switch self {
        case .topLeft: return "tl"
        case .topRight: return "tr"
        case .bottomRight: return "br"
        case .bottomLeft: return "bl"
        }
    }

    init?(wireValue: String) {
        switch wireValue {
        case "tl": self = .topLeft
        case "tr": self = .topRight
        case "br": self = .bottomRight
        case "bl": self = .bottomLeft
        default: return nil
        }
    }
}

extension ProjectorQuad {
    /// 协议里那八个数，顺序 TL TR BR BL。**别重排** —— 这个顺序在两端的
    /// 单应变换、角标绘制和存档里都写死了，换一下不会报错，表现是画面拧成麻花。
    var wireValues: [Double] {
        [topLeft.x, topLeft.y, topRight.x, topRight.y,
         bottomRight.x, bottomRight.y, bottomLeft.x, bottomLeft.y]
    }

    init?(wireValues values: [Double]) {
        guard values.count == 8 else { return nil }
        self.init(
            topLeft: CGPoint(x: values[0], y: values[1]),
            topRight: CGPoint(x: values[2], y: values[3]),
            bottomRight: CGPoint(x: values[4], y: values[5]),
            bottomLeft: CGPoint(x: values[6], y: values[7])
        )
    }
}

// MARK: - base64url

extension Data {
    /// RFC 4648 URL-safe，且**不带 `=` 填充** —— 安卓端是按无填充解的，
    /// 带上填充会当成凭据不匹配直接拒绝。
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var padded = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        self.init(base64Encoded: padded)
    }
}
