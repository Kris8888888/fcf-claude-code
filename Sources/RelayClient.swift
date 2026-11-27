import Foundation
import Network
import CryptoKit
import Security

/// 外网访问（经云服务器中转）：这台电脑主动连到云服务器，云服务器把外面浏览器的访问转回来。
///
/// 协议很简单（服务器端是 RelayServerScript 里那个 Python 脚本）：
/// - 控制连接：发「CTRL」→ 服务器回「NONCE 随机数」→ 回「AUTH hmac(口令, 随机数)」→ 服务器回「OK」。之后服务器有人访问就发「OPEN 编号」，每 20 秒发「PING」
/// - 数据连接：收到 OPEN 后另开一条，发「DATA 编号 hmac(口令, 编号)」，然后原样转发字节；本机这头接到网页远程的 HTTPS 入口（127.0.0.1:8849）
/// 口令本身不在网上传；浏览器到这台电脑全程 HTTPS，服务器只转密文
final class RelayClient: ObservableObject {
    static let shared = RelayClient()
    /// 端口都能在设置里改（每个人的服务器不一样）；默认值只是建议
    static let defaultCtrlPort = 21118
    static let defaultPublicPort = 8443

    enum State: Equatable { case off, connecting, connected, failed(String) }
    @Published private(set) var state: State = .off

    @Published var host: String {
        didSet { UserDefaults.standard.set(host, forKey: "relayHost") }
    }
    /// 这台电脑连服务器用的端口
    @Published var ctrlPort: Int {
        didSet { UserDefaults.standard.set(ctrlPort, forKey: "relayCtrlPort") }
    }
    /// 浏览器访问用的端口
    @Published var publicPort: Int {
        didSet { UserDefaults.standard.set(publicPort, forKey: "relayPublicPort") }
    }
    var enabled: Bool { UserDefaults.standard.bool(forKey: "relayOn") }

    /// 服务器和这台电脑之间的口令（装服务器时一起写进去）。用到时才读钥匙串：不用这个功能的人完全不碰钥匙串
    private(set) lazy var token: String = Self.keychain("token") ?? { let t = Self.randomHex(32); Self.setKeychain("token", t); return t }()
    /// 浏览器地址里的口令：不对就当这里什么都没有
    private(set) lazy var secret: String = Self.keychain("secret") ?? { let s = Self.randomHex(16); Self.setKeychain("secret", s); return s }()

    private let queue = DispatchQueue(label: "relay")
    private var ctrl: NWConnection?
    private var lineBuf = Data()
    private var retry: DispatchWorkItem?
    private var backoff: Double = 2
    private var lastPing = Date()
    private var watchdog: Timer?
    private var idleTimer: Timer?
    private var enabledAt = Date()

    /// 没人用多久后自动关掉外网访问（小时；0 = 不自动关）
    @Published var autoOffHours: Int {
        didSet { UserDefaults.standard.set(autoOffHours, forKey: "relayAutoOffHours") }
    }

    private init() {
        host = UserDefaults.standard.string(forKey: "relayHost") ?? ""
        ctrlPort = (UserDefaults.standard.object(forKey: "relayCtrlPort") as? Int) ?? Self.defaultCtrlPort
        publicPort = (UserDefaults.standard.object(forKey: "relayPublicPort") as? Int) ?? Self.defaultPublicPort
        autoOffHours = (UserDefaults.standard.object(forKey: "relayAutoOffHours") as? Int) ?? 8
    }

    var publicURL: String? {
        let h = host.trimmingCharacters(in: .whitespaces)
        return h.isEmpty ? nil : "https://\(h):\(publicPort)/?k=\(secret)"
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "relayOn")
        if on {
            _ = token; _ = secret          // 先在主线程读好，后台线程直接用
            if !WebRemote.shared.enabled { WebRemote.shared.setEnabled(true) }
            WebRemote.shared.startRelayEntrance(host: host)
            enabledAt = Date()
            connect()
            startIdleCheck()
        } else {
            disconnect()
            idleTimer?.invalidate(); idleTimer = nil
            WebRemote.shared.stopRelayEntrance()
        }
    }

    func startIfEnabled() { if enabled { setEnabled(true) } }

    /// 改了服务器地址或端口：开着的话重新连（证书按新地址重新生成）
    func reconnect() {
        guard enabled else { return }
        backoff = 2
        disconnect()
        WebRemote.shared.stopRelayEntrance()
        WebRemote.shared.startRelayEntrance(host: host)
        connect()
    }

    /// 每 5 分钟看一眼：超过设定时间没人用（没有浏览器开着、也没有新的访问），自动关掉
    private func startIdleCheck() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard let self, self.enabled, self.autoOffHours > 0 else { return }
            if WebRemote.shared.clients > 0 { return }
            let last = max(self.enabledAt, WebRemote.shared.lastRelayActivity)
            guard Date().timeIntervalSince(last) > Double(self.autoOffHours) * 3600 else { return }
            self.setEnabled(false)
            AppLog.write("外网访问：\(self.autoOffHours) 小时没人用，自动关闭")
            Notifier.shared.remind(title: "外网访问已自动关闭", body: "已经 \(self.autoOffHours) 小时没人用了。要用时在设置 → 网页远程里再打开。")
        }
    }

    /// 换一个网址口令：已经存的网址都失效
    func regenerateSecret() {
        secret = Self.randomHex(16)
        Self.setKeychain("secret", secret)
        objectWillChange.send()
        AppLog.write("外网访问：换了网址口令")
    }

    // MARK: 控制连接

    private func connect() {
        retry?.cancel()
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { state = .failed("先填服务器地址"); return }
        ctrl?.cancel()
        state = .connecting
        let c = NWConnection(host: NWEndpoint.Host(h), port: NWEndpoint.Port(rawValue: UInt16(clamping: ctrlPort))!, using: .tcp)
        ctrl = c
        lineBuf = Data()
        c.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                c.send(content: Data("CTRL\n".utf8), completion: .contentProcessed { _ in })
                self.readCtrl(c)
            case .failed(let e), .waiting(let e):
                self.lost(c, "连不上服务器：\(e.localizedDescription)")
            case .cancelled: break
            default: break
            }
        }
        c.start(queue: queue)
        DispatchQueue.main.async { self.startWatchdog() }
    }

    private func disconnect() {
        retry?.cancel()
        watchdog?.invalidate(); watchdog = nil
        ctrl?.cancel(); ctrl = nil
        state = .off
    }

    /// 断了：几秒后重连（2、4、8…最多 60 秒）
    private func lost(_ c: NWConnection, _ why: String) {
        guard c === ctrl else { return }
        c.cancel(); ctrl = nil
        DispatchQueue.main.async {
            guard self.enabled else { return }
            if self.state != .failed(why) { AppLog.write("外网访问：\(why)") }
            self.state = .failed(why)
            let w = DispatchWorkItem { [weak self] in self?.connect() }
            self.retry = w
            DispatchQueue.main.asyncAfter(deadline: .now() + self.backoff, execute: w)
            self.backoff = min(60, self.backoff * 2)
        }
    }

    /// 服务器每 20 秒发一次 PING；超过 70 秒没收到，当成断了重连
    private func startWatchdog() {
        watchdog?.invalidate()
        lastPing = Date()
        watchdog = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self, let c = self.ctrl, self.state == .connected else { return }
            if Date().timeIntervalSince(self.lastPing) > 70 { self.queue.async { self.lost(c, "和服务器的连接断了") } }
        }
    }

    private func readCtrl(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, err in
            guard let self, c === self.ctrl else { return }
            if let data { self.lineBuf.append(data) }
            while let nl = self.lineBuf.firstIndex(of: 0x0A) {
                let line = String(data: self.lineBuf[self.lineBuf.startIndex..<nl], encoding: .utf8) ?? ""
                self.lineBuf.removeSubrange(self.lineBuf.startIndex...nl)
                self.handle(line.trimmingCharacters(in: .whitespacesAndNewlines), c)
            }
            if done || err != nil { self.lost(c, "服务器断开了连接（口令不对，或服务器上的中转程序没在运行）"); return }
            self.readCtrl(c)
        }
    }

    private func handle(_ line: String, _ c: NWConnection) {
        let parts = line.split(separator: " ").map(String.init)
        switch parts.first {
        case "NONCE" where parts.count == 2:
            c.send(content: Data("AUTH \(Self.hmac(token, parts[1]))\n".utf8), completion: .contentProcessed { _ in })
        case "OK":
            DispatchQueue.main.async {
                self.backoff = 2
                self.lastPing = Date()
                if self.state != .connected { AppLog.write("外网访问：已连上中转服务器 \(self.host)") }
                self.state = .connected
            }
        case "PING":
            DispatchQueue.main.async { self.lastPing = Date() }
            c.send(content: Data("PONG\n".utf8), completion: .contentProcessed { _ in })
        case "OPEN" where parts.count == 2:
            openData(parts[1])
        default: break
        }
    }

    // MARK: 数据连接：一头连服务器，一头连本机的 HTTPS 入口，原样互相转

    private func openData(_ id: String) {
        let h = host.trimmingCharacters(in: .whitespaces)
        let remote = NWConnection(host: NWEndpoint.Host(h), port: NWEndpoint.Port(rawValue: UInt16(clamping: ctrlPort))!, using: .tcp)
        let local = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: WebRemote.relayPort)!, using: .tcp)
        remote.stateUpdateHandler = { st in
            switch st {
            case .ready:
                remote.send(content: Data("DATA \(id) \(Self.hmac(self.token, id))\n".utf8), completion: .contentProcessed { _ in })
                local.start(queue: self.queue)
            case .failed, .cancelled: local.cancel()
            default: break
            }
        }
        local.stateUpdateHandler = { st in
            switch st {
            case .ready:
                Self.pipe(remote, local)
                Self.pipe(local, remote)
            case .failed, .cancelled: remote.cancel()
            default: break
            }
        }
        remote.start(queue: queue)
    }

    private static func pipe(_ from: NWConnection, _ to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, done, err in
            if let data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { e in
                    if e != nil { from.cancel(); to.cancel() } else if !done && err == nil { pipe(from, to) }
                })
                if done || err != nil { to.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in to.cancel() }) }
                return
            }
            if done || err != nil { to.cancel(); from.cancel(); return }
            pipe(from, to)
        }
    }

    // MARK: 工具

    static func hmac(_ key: String, _ msg: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(msg.utf8), using: SymmetricKey(data: Data(key.utf8))).map { String(format: "%02x", $0) }.joined()
    }

    static func randomHex(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return b.map { String(format: "%02x", $0) }.joined()
    }

    private static let service = "com.likang.duihuatai.relay"
    /// 仅用于测试：DUIHUATAI_TEST_RELAY 时口令只放内存（DUIHUATAI_TEST_RELAY_TOKEN 指定服务器口令），不碰钥匙串
    private static var testStore: [String: String]? = ProcessInfo.processInfo.environment["DUIHUATAI_TEST_RELAY"] == nil ? nil
        : ["token": ProcessInfo.processInfo.environment["DUIHUATAI_TEST_RELAY_TOKEN"] ?? "test-token", "secret": "test-secret"]
    static func keychain(_ account: String) -> String? {
        if let t = testStore { return t[account] }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func setKeychain(_ account: String, _ value: String) {
        if testStore != nil { testStore?[account] = value; return }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base; add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    /// 服务器上要执行的安装命令（带上口令）：贴到阿里云控制台「命令助手」里运行
    func serverScript() -> String { RelayServerScript.make(token: token, ctrlPort: ctrlPort, publicPort: publicPort) }
}

/// 外网入口的 HTTPS 证书：每台电脑第一次用时用系统自带 openssl 生成一张自签证书（10 年），存在 App 的资料夹里
enum RelayTLS {
    private static let pass = "fcf-relay"
    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("com.likang.duihuatai/relay", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static var certFile: URL { dir.appendingPathComponent("cert.pem") }

    /// host：云服务器的 IP 或域名，写进证书（不写的话，就算信任了证书 Chrome 也会报错）。换了地址就重新生成
    static func identity(host: String) -> sec_identity_t? {
        let p12 = dir.appendingPathComponent("id.p12")
        let mark = dir.appendingPathComponent("host.txt")
        let h = host.trimmingCharacters(in: .whitespaces)
        if (try? String(contentsOf: mark, encoding: .utf8)) != h { try? FileManager.default.removeItem(at: p12) }
        if !FileManager.default.fileExists(atPath: p12.path) {
            let key = dir.appendingPathComponent("key.pem").path, cert = certFile.path
            let isIP = h.split(separator: ".").count == 4 && h.allSatisfy { $0.isNumber || $0 == "." }
            let san = h.isEmpty ? "DNS:localhost" : (isIP ? "IP:\(h)" : "DNS:\(h)")
            let a = Shell.run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-days", "825",
                                                   "-subj", "/CN=FCF Claude Code \(h)", "-addext", "subjectAltName=\(san)"])
            guard a.code == 0 else { AppLog.write("生成证书失败：\(a.output.prefix(200))"); return nil }
            let b = Shell.run("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", key, "-in", cert, "-out", p12.path, "-passout", "pass:\(pass)"])
            try? FileManager.default.removeItem(atPath: key)
            guard b.code == 0 else { AppLog.write("打包证书失败：\(b.output.prefix(200))"); return nil }
            try? h.write(to: mark, atomically: true, encoding: .utf8)
        }
        guard let data = try? Data(contentsOf: p12) else { return nil }
        var items: CFArray?
        let st = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: pass] as CFDictionary, &items)
        guard st == errSecSuccess, let arr = items as? [[String: Any]], let first = arr.first,
              let idRef = first[kSecImportItemIdentity as String] else { AppLog.write("读取证书失败：\(st)"); return nil }
        return sec_identity_create(idRef as! SecIdentity)
    }

    /// 导出证书（DER 格式 .cer，Mac 和 iPhone 都认），放到「下载」文件夹
    static func export() -> URL? {
        guard FileManager.default.fileExists(atPath: certFile.path) else { return nil }
        let out = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("FCF网页远程证书.cer")
        try? FileManager.default.removeItem(at: out)
        let r = Shell.run("/usr/bin/openssl", ["x509", "-in", certFile.path, "-outform", "der", "-out", out.path])
        return r.code == 0 ? out : nil
    }
}
