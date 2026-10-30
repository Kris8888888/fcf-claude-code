import Foundation
import Network
import AppKit
import Combine

// MARK: - 网页远程：同一个网络里的其他电脑，用浏览器打开地址、输入访问码，就能看和继续这台电脑上的对话
//
// 只在设置里开启后才监听端口。所有操作都走客户端现有的对话（ChatSession），两边看到的是同一份。
// 网页发来的消息：如果那个对话是「全部放行」，先切回「每步询问」，改文件、跑命令都要在网页上点确认。

final class WebRemote: ObservableObject {
    static let shared = WebRemote()
    static let port: UInt16 = 8848

    @Published private(set) var running = false
    @Published private(set) var clients = 0          // 正在看的浏览器数
    @Published var error = ""
    @Published private(set) var code: String

    weak var app: AppState?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "webremote")
    private var tokens = Set<String>()
    private var failures: [String: (count: Int, until: Date)] = [:]
    private var streams: [ObjectIdentifier: NWConnection] = [:]
    private var pollTimer: Timer?
    private var lastSigs: [String: Int] = [:]
    private var lastListSig = 0

    var enabled: Bool { UserDefaults.standard.bool(forKey: "webRemoteOn") }

    init() {
        if let c = UserDefaults.standard.string(forKey: "webRemoteCode"), c.count == 6 { code = c }
        else { code = Self.newCode(); UserDefaults.standard.set(code, forKey: "webRemoteCode") }
    }

    static func newCode() -> String { String(format: "%06d", Int.random(in: 0...999_999)) }

    /// 换一个访问码：已经登录的浏览器都要重新输入
    func regenerateCode() {
        code = Self.newCode()
        UserDefaults.standard.set(code, forKey: "webRemoteCode")
        queue.async { self.tokens.removeAll() }
        broadcast("logout")
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "webRemoteOn")
        on ? start() : stop()
    }

    func startIfEnabled() { if enabled { start() } }

    // MARK: 监听

    func start() {
        guard listener == nil else { return }
        error = ""
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
            l.stateUpdateHandler = { [weak self] st in
                DispatchQueue.main.async {
                    switch st {
                    case .ready: self?.running = true
                    case .failed(let e):
                        self?.running = false
                        self?.error = "启动失败：\(e.localizedDescription)。可能 \(Self.port) 端口被别的程序占用了。"
                        self?.listener = nil
                    case .cancelled: self?.running = false
                    default: break
                    }
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.start(queue: queue)
            listener = l
            startPolling()
        } catch {
            self.error = "启动失败：\(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel(); listener = nil
        queue.async {
            for c in self.streams.values { c.cancel() }
            self.streams.removeAll()
            self.tokens.removeAll()
        }
        pollTimer?.invalidate(); pollTimer = nil
        running = false
        clients = 0
    }

    /// 这台电脑在网络里的地址（给另一台电脑用）
    static func addresses() -> [String] {
        var out: [String] = []
        // 电脑名.local：换了网络、IP 变了也能用
        let r = Shell.run("/usr/sbin/scutil", ["--get", "LocalHostName"], timeout: 3)
        let name = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.code == 0, !name.isEmpty, !name.contains(" ") { out.append("http://\(name).local:\(port)") }
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return out }
        defer { freeifaddrs(ifaddr) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (Int32(a.ifa_flags) & IFF_LOOPBACK) == 0, (Int32(a.ifa_flags) & IFF_UP) != 0 else { continue }
            let name = String(cString: a.ifa_name)
            guard name.hasPrefix("en") else { continue }       // 只要有线/无线网卡，不要虚拟网卡
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
            out.append("http://\(String(cString: buf)):\(port)")
        }
        return out
    }

    // MARK: HTTP

    private struct Request {
        var method = "", path = "", query: [String: String] = [:]
        var headers: [String: String] = [:]
        var body = Data()
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:] }
        var token: String? {
            for part in (headers["cookie"] ?? "").split(separator: ";") {
                let kv = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
                if kv.count == 2, kv[0] == "fcfrc" { return String(kv[1]) }
            }
            return nil
        }
        var remote = ""
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ acc: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = acc
            if let data { buf.append(data) }
            if let r = self.parse(buf, c) { self.route(r, c); return }
            if done || err != nil || buf.count > 2_000_000 { c.cancel(); return }
            self.read(c, buf)
        }
    }

    private func parse(_ d: Data, _ c: NWConnection) -> Request? {
        guard let end = d.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: d[d.startIndex..<end.lowerBound], encoding: .utf8) else { return nil }
        var r = Request()
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        r.method = String(first[0])
        let target = String(first[1])
        let comps = URLComponents(string: target)
        r.path = comps?.path ?? target
        for q in comps?.queryItems ?? [] { r.query[q.name] = q.value ?? "" }
        for l in lines.dropFirst() {
            if let i = l.firstIndex(of: ":") {
                r.headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let len = Int(r.headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard d.count - (bodyStart - d.startIndex) >= len else { return nil }
        r.body = d[bodyStart..<(bodyStart + len)]
        if case .hostPort(let h, _) = c.endpoint { r.remote = "\(h)" }
        return r
    }

    private func send(_ c: NWConnection, _ status: String, _ type: String, _ body: Data, extra: [String] = []) {
        var h = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n"
        for e in extra { h += e + "\r\n" }
        h += "\r\n"
        var out = Data(h.utf8); out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    private func json(_ c: NWConnection, _ obj: Any, status: String = "200 OK", extra: [String] = []) {
        let d = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        send(c, status, "application/json; charset=utf-8", d, extra: extra)
    }

    private func route(_ r: Request, _ c: NWConnection) {
        if r.method == "GET" && (r.path == "/" || r.path == "/index.html") {
            send(c, "200 OK", "text/html; charset=utf-8", Data(WebRemotePage.html.utf8)); return
        }
        if r.path == "/api/login" && r.method == "POST" { login(r, c); return }
        // 主题只是几个颜色值：登录页也要用，不需要访问码
        if r.path == "/api/theme" { DispatchQueue.main.async { let t = Self.theme(); self.queue.async { self.json(c, t) } }; return }
        guard let t = r.token, tokens.contains(t) else { json(c, ["error": "需要访问码"], status: "401 Unauthorized"); return }
        if r.path == "/api/events" { openStream(c); return }
        // 其余都在主线程读写客户端的数据
        DispatchQueue.main.async {
            let (status, obj) = self.handle(r)
            self.queue.async { self.json(c, obj, status: status) }
        }
    }

    private func login(_ r: Request, _ c: NWConnection) {
        let who = r.remote
        if let f = failures[who], f.until > Date() {
            json(c, ["error": "输错太多次，请 1 分钟后再试"], status: "429 Too Many Requests"); return
        }
        let given = (r.json["code"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let current = DispatchQueue.main.sync { code }
        guard given == current else {
            var f = failures[who] ?? (0, .distantPast)
            f.count += 1
            if f.count >= 5 { f = (0, Date().addingTimeInterval(60)) }
            failures[who] = f
            json(c, ["error": "访问码不对"], status: "403 Forbidden"); return
        }
        failures[who] = nil
        let t = UUID().uuidString + UUID().uuidString
        tokens.insert(t)
        json(c, ["ok": true], extra: ["Set-Cookie: fcfrc=\(t); Path=/; HttpOnly; SameSite=Strict; Max-Age=2592000"])
    }

    // MARK: 实时推送（Server-Sent Events）

    private func openStream(_ c: NWConnection) {
        let h = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: keep-alive\r\nX-Accel-Buffering: no\r\n\r\nretry: 2000\n\nevent: hello\ndata: {}\n\n"
        c.send(content: Data(h.utf8), completion: .contentProcessed { _ in })
        let id = ObjectIdentifier(c)
        streams[id] = c
        c.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .cancelled: self?.queue.async { self?.streams[id] = nil; self?.updateClients() }
            default: break
            }
        }
        updateClients()
    }

    private func updateClients() {
        let n = streams.count
        DispatchQueue.main.async { self.clients = n }
    }

    private func broadcast(_ event: String, _ data: String = "{}") {
        queue.async {
            let msg = Data("event: \(event)\ndata: \(data)\n\n".utf8)
            for (id, c) in self.streams {
                c.send(content: msg, completion: .contentProcessed { [weak self] e in
                    if e != nil { self?.queue.async { self?.streams[id] = nil; c.cancel(); self?.updateClients() } }
                })
            }
        }
    }

    /// 每 0.3 秒比对一次：列表或某个对话有变化就通知网页去取（有人在看时才比对）
    private func startPolling() {
        pollTimer?.invalidate()
        var ticks = 0
        let t = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self, self.clients > 0, let app = self.app else { return }
            ticks += 1
            if ticks % 50 == 0 { self.broadcast("ping") }       // 15 秒一次心跳，防止中间设备断开空闲连接
            var listSig = Hasher()
            for r in app.remoteRows() { listSig.combine(r.id); listSig.combine(r.title); listSig.combine(r.busy); listSig.combine(r.live?.needsAttention ?? false) }
            let ls = listSig.finalize()
            if ls != self.lastListSig { self.lastListSig = ls; self.broadcast("list") }
            for s in app.sessions {
                var h = Hasher()
                h.combine(s.items.count); h.combine(s.busy); h.combine(s.status); h.combine(s.needsAttention); h.combine(s.title)
                if let last = s.items.last { h.combine(last.text.utf16.count); h.combine(last.streaming); h.combine(last.resolved); h.combine("\(last.toolState)") }
                h.combine(s.items.filter { $0.kind == .tool && $0.toolState == .running }.count)
                let sig = h.finalize(), key = s.id.uuidString
                if self.lastSigs[key] != sig { self.lastSigs[key] = sig; self.broadcast("session", "{\"id\":\"\(key)\"}") }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    // MARK: 接口（主线程）

    private func handle(_ r: Request) -> (String, Any) {
        guard let app else { return ("503 Service Unavailable", ["error": "客户端还没准备好"]) }
        let b = r.json
        switch (r.method, r.path) {
        case ("GET", "/api/me"):
            return ("200 OK", ["ok": true, "host": Host.current().localizedName ?? "这台电脑"])
        case ("GET", "/api/theme"):
            return ("200 OK", Self.theme())
        case ("GET", "/api/list"):
            return ("200 OK", list(app))
        case ("GET", "/api/session"):
            guard let s = app.openRemote(r.query["id"] ?? "") else { return ("404 Not Found", ["error": "找不到这个对话"]) }
            return ("200 OK", snapshot(s, limit: Int(r.query["limit"] ?? "") ?? 160))
        case ("POST", "/api/new"):
            let s = ChatSession(cwd: app.lastFolder)
            s.setMode(.default)
            app.addBackground(s)
            return ("200 OK", ["id": s.id.uuidString])
        default: break
        }
        guard r.method == "POST", let s = app.openRemote(b["id"] as? String ?? "") else { return ("404 Not Found", ["error": "找不到这个对话"]) }
        let item = (b["item"] as? String).flatMap { iid in s.items.first { $0.id.uuidString == iid } }
        switch r.path {
        case "/api/send":
            let text = (b["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return ("400 Bad Request", ["error": "消息是空的"]) }
            // 远程来的消息不用「全部放行」：改文件、跑命令都要在网页上确认
            if s.mode == .bypassPermissions { s.setMode(.default) }
            s.send(text: text, images: [])
        case "/api/stop": s.interrupt()
        case "/api/allow":
            guard let item else { return ("404 Not Found", ["error": "这一步已经处理过了"]) }
            s.allow(item, always: b["always"] as? Bool ?? false)
        case "/api/deny":
            guard let item else { return ("404 Not Found", ["error": "这一步已经处理过了"]) }
            s.deny(item, reason: b["reason"] as? String ?? "")
        case "/api/answer":
            guard let item, let answers = b["answers"] as? [String: String] else { return ("400 Bad Request", ["error": "回答不完整"]) }
            s.answerQuestion(item, answers: answers)
        default:
            return ("404 Not Found", ["error": "没有这个接口"])
        }
        return ("200 OK", ["ok": true])
    }

    private func list(_ app: AppState) -> [String: Any] {
        let rows = app.remoteRows()
        func rowJSON(_ r: SidebarRow) -> [String: Any] {
            ["id": r.live?.id.uuidString ?? r.id, "title": r.title, "date": r.date.timeIntervalSince1970,
             "busy": r.busy, "attention": r.live?.needsAttention ?? false, "pinned": app.isPinned(r)]
        }
        let pinned = rows.filter { app.isPinned($0) }
        let groups = Dictionary(grouping: rows.filter { !app.isPinned($0) }, by: \.cwd)
            .map { (cwd, rs) in (cwd, rs.sorted { $0.date > $1.date }) }
            .sorted { ($0.1.first?.date ?? .distantPast) > ($1.1.first?.date ?? .distantPast) }
        return ["pinned": pinned.map(rowJSON),
                "groups": groups.map { ["name": WeixinBridge.friendlyFolder($0.0), "rows": $0.1.map(rowJSON)] }]
    }

    private func snapshot(_ s: ChatSession, limit: Int) -> [String: Any] {
        let all = s.items
        let items = all.suffix(max(20, limit))
        return ["id": s.id.uuidString, "title": app?.title(for: s.sessionId, fallback: s.title) ?? s.title,
                "folder": WeixinBridge.friendlyFolder(s.cwd), "busy": s.busy, "status": s.status,
                "loading": s.loading, "mode": s.mode.label, "hidden": all.count - items.count,
                "items": items.map(Self.itemJSON)]
    }

    static func itemJSON(_ it: ChatItem) -> [String: Any] {
        var o: [String: Any] = ["id": it.id.uuidString, "kind": "\(it.kind)", "text": it.text, "streaming": it.streaming]
        switch it.kind {
        case .tool:
            o["tool"] = it.toolName
            o["state"] = "\(it.toolState)"
            if let r = it.toolResult { o["result"] = String(r.prefix(3000)) }
            if let c = it.toolInput["command"] as? String { o["detail"] = String(c.prefix(2000)) }
            if it.subSteps > 0 { o["sub"] = "\(it.subSteps) 步 · \(it.subLatest)" }
        case .thinking:
            if let d = it.duration { o["duration"] = d }
        case .permission:
            o["tool"] = it.toolName
            if let c = it.toolInput["command"] as? String { o["detail"] = String(c.prefix(2000)) }
            else if let p = it.toolInput["file_path"] as? String { o["detail"] = WeixinBridge.shortPath(p) }
            if it.toolName == "ExitPlanMode", let plan = it.toolInput["plan"] as? String { o["plan"] = plan }
            if let r = it.resolved { o["resolved"] = r }
        case .question:
            o["questions"] = (it.toolInput["questions"] as? [[String: Any]] ?? []).map { q in
                ["question": q["question"] as? String ?? "", "multi": q["multiSelect"] as? Bool ?? false,
                 "options": (q["options"] as? [[String: Any]] ?? []).map { ["label": $0["label"] as? String ?? "", "description": $0["description"] as? String ?? ""] }]
            }
            if let r = it.resolved { o["resolved"] = r }
        case .artifacts:
            o["files"] = it.artifacts.map { ["name": $0.url.lastPathComponent, "path": WeixinBridge.shortPath($0.url.path), "created": $0.created] }
        case .user:
            o["files"] = it.files.map { ["name": $0.lastPathComponent, "path": WeixinBridge.shortPath($0.path)] }
            o["images"] = it.images.count
        default: break
        }
        return o
    }

    /// 网页用和客户端一样的主题配色
    static func theme() -> [String: Any] {
        let st = ThemeStore.shared
        let p = st.palette
        func hex(_ v: UInt32) -> String { String(format: "#%06X", v) }
        var light: [String: String] = [:], dark: [String: String] = [:]
        for (k, pair) in [("canvas", p.canvas), ("paper", p.paper), ("sunk", p.sunk), ("ink", p.ink), ("muted", p.muted),
                          ("line", p.line), ("accent", p.accent), ("run", p.run), ("ok", p.ok), ("err", p.err)] {
            light[k] = hex(pair.light); dark[k] = hex(pair.dark)
        }
        if let a = st.accentOverride { light["accent"] = hex(a); dark["accent"] = hex(a) }
        let scheme = p.scheme == nil ? "auto" : (p.scheme == .dark ? "dark" : "light")
        return ["scheme": scheme, "light": light, "dark": dark, "fontScale": st.fontScale]
    }
}
