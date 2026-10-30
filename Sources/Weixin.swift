import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

// MARK: - 微信 ClawBot 远程控制
//
// 协议照腾讯开源的 @tencent-weixin/openclaw-weixin（MIT）实现：
// 扫码绑定拿到 bot_token → 长轮询 getupdates 收消息 → sendmessage 回复。
// 只处理扫码绑定的那个微信号发来的消息；远程对话一律「每步询问」，授权推到微信里确认。

/// 扫码绑定后保存的账号信息（文件权限 600，只有你自己能读）
struct WeixinAccount: Codable {
    var token: String
    var baseUrl: String
    var botId: String
    var userId: String          // 扫码的那个微信号，只认它发来的消息
    var boundAt: Date
}

enum WeixinAPI {
    static let fixedBase = ProcessInfo.processInfo.environment["DUIHUATAI_WEIXIN_BASE"] ?? "https://ilinkai.weixin.qq.com"
    static let channelVersion = "2.4.10"
    static var botAgent: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "FCF-Claude-Code/\(v)"
    }
    /// iLink-App-ClientVersion：0x00MMNNPP
    static let clientVersion: Int = {
        let p = channelVersion.split(separator: ".").map { Int($0) ?? 0 }
        return ((p[0] & 0xff) << 16) | ((p[1] & 0xff) << 8) | (p[2] & 0xff)
    }()

    struct APIError: LocalizedError { let msg: String; var errorDescription: String? { msg } }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60
        c.connectionProxyDictionary = [:]       // 微信服务器在国内，直接连
        return URLSession(configuration: c)
    }()

    private static func url(_ base: String, _ endpoint: String) -> URL {
        URL(string: (base.hasSuffix("/") ? base : base + "/") + endpoint)!
    }

    private static func commonHeaders(_ r: inout URLRequest) {
        r.setValue("bot", forHTTPHeaderField: "iLink-App-Id")
        r.setValue(String(clientVersion), forHTTPHeaderField: "iLink-App-ClientVersion")
    }

    static var baseInfo: [String: Any] { ["channel_version": channelVersion, "bot_agent": botAgent] }

    static func post(_ base: String, _ endpoint: String, _ body: [String: Any], token: String?, timeout: TimeInterval) async throws -> [String: Any] {
        var r = URLRequest(url: url(base, endpoint))
        r.httpMethod = "POST"
        r.timeoutInterval = timeout
        commonHeaders(&r)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("ilink_bot_token", forHTTPHeaderField: "AuthorizationType")
        let uin = String(UInt32.random(in: 0...UInt32.max))
        r.setValue(Data(uin.utf8).base64EncodedString(), forHTTPHeaderField: "X-WECHAT-UIN")
        if let token, !token.isEmpty { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (d, resp) = try await session.data(for: r)
        guard let h = resp as? HTTPURLResponse, (200..<300).contains(h.statusCode) else {
            throw APIError(msg: "微信服务器返回 \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }

    static func get(_ base: String, _ endpoint: String, timeout: TimeInterval) async throws -> [String: Any] {
        var r = URLRequest(url: url(base, endpoint))
        r.timeoutInterval = timeout
        commonHeaders(&r)
        let (d, _) = try await session.data(for: r)
        return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }
}

/// 远程对话回传给微信：ChatSession 在这些时刻通知它
protocol RemoteSink: AnyObject {
    func remoteNeedsInput(_ s: ChatSession, item: ChatItem)
    func remoteTurnFinished(_ s: ChatSession, replies: [String], artifacts: [URL], error: String?)
}

final class WeixinBridge: ObservableObject, RemoteSink {
    static let shared = WeixinBridge()

    enum Phase: Equatable {
        case off                         // 没绑定
        case qr(String)                  // 二维码内容，等扫码
        case scanned                     // 已扫码，等手机上确认
        case needCode(retry: Bool)       // 手机上显示了数字，要输入
        case online                      // 已连接，正在收消息
        case expired(String)             // 连接失效，要重新扫码
    }
    @Published var phase: Phase = .off
    @Published var account: WeixinAccount?
    @Published var lastMessageAt: Date?
    @Published var note = ""             // 给设置页显示的一句状态说明
    /// 远程对话在哪个文件夹里工作
    var workFolder: String {
        get { UserDefaults.standard.string(forKey: "weixinCwd") ?? NSHomeDirectory() }
        set { objectWillChange.send(); UserDefaults.standard.set(newValue, forKey: "weixinCwd") }
    }

    weak var app: AppState?
    private(set) var remoteSession: ChatSession?
    private var loop: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var verifyCode: CheckedContinuation<String, Never>?
    private var contextToken: String?
    private var typingTicket: String?
    private var typingTimer: Timer?

    private let dir: URL = {
        // 仅用于测试：DUIHUATAI_WEIXIN_DIR 换一个目录，不碰真的绑定数据
        let d = ProcessInfo.processInfo.environment["DUIHUATAI_WEIXIN_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("com.likang.duihuatai/weixin", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private var accountFile: URL { dir.appendingPathComponent("account.json") }
    private var bufFile: URL { dir.appendingPathComponent("sync-buf.txt") }

    init() {
        if let d = try? Data(contentsOf: accountFile) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            account = try? dec.decode(WeixinAccount.self, from: d)
        }
    }

    /// App 启动时：绑定过就自动开始收消息
    func startIfBound() { if account != nil { startLoop() } }

    // MARK: 扫码绑定

    func beginLogin() {
        loginTask?.cancel()
        note = ""
        loginTask = Task { @MainActor in
            do {
                var base = WeixinAPI.fixedBase
                var qr = try await WeixinAPI.post(base, "ilink/bot/get_bot_qrcode?bot_type=3",
                                                  ["local_token_list": account.map { [$0.token] } ?? []], token: nil, timeout: 15)
                var code = qr["qrcode"] as? String ?? ""
                phase = .qr(qr["qrcode_img_content"] as? String ?? "")
                var refreshes = 1
                var pendingCode: String?
                let deadline = Date().addingTimeInterval(480)
                while !Task.isCancelled, Date() < deadline {
                    var ep = "ilink/bot/get_qrcode_status?qrcode=" + (code.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? code)
                    if let c = pendingCode { ep += "&verify_code=" + (c.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? c) }
                    let st = (try? await WeixinAPI.get(base, ep, timeout: 35)) ?? ["status": "wait"]
                    switch st["status"] as? String ?? "wait" {
                    case "scaned":
                        pendingCode = nil
                        phase = .scanned
                    case "need_verifycode":
                        phase = .needCode(retry: pendingCode != nil)
                        pendingCode = await withCheckedContinuation { verifyCode = $0 }
                        phase = .scanned
                        continue
                    case "scaned_but_redirect":
                        if let h = st["redirect_host"] as? String, !h.isEmpty { base = "https://\(h)" }
                    case "expired", "verify_code_blocked":
                        refreshes += 1
                        guard refreshes <= 3 else { phase = .off; note = "二维码多次过期，请重新点「连接微信」。"; return }
                        base = WeixinAPI.fixedBase
                        qr = try await WeixinAPI.post(base, "ilink/bot/get_bot_qrcode?bot_type=3", ["local_token_list": []], token: nil, timeout: 15)
                        code = qr["qrcode"] as? String ?? ""
                        phase = .qr(qr["qrcode_img_content"] as? String ?? "")
                        pendingCode = nil
                    case "binded_redirect":
                        phase = account == nil ? .off : .online
                        note = "这个微信已经连接过了。"
                        return
                    case "confirmed":
                        guard let token = st["bot_token"] as? String, let bot = st["ilink_bot_id"] as? String else {
                            phase = .off; note = "绑定失败：微信没有返回账号信息，请重试。"; return
                        }
                        let acc = WeixinAccount(token: token, baseUrl: (st["baseurl"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? base,
                                                botId: bot, userId: st["ilink_user_id"] as? String ?? "", boundAt: Date())
                        save(acc)
                        try? FileManager.default.removeItem(at: bufFile)
                        startLoop()
                        return
                    default: break
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                if !Task.isCancelled { phase = .off; note = "等待扫码超时，请重新点「连接微信」。" }
            } catch {
                phase = .off
                note = "连不上微信服务器：\(error.localizedDescription)"
            }
        }
    }

    /// 手机上显示的数字
    func submitVerifyCode(_ c: String) {
        verifyCode?.resume(returning: c.trimmingCharacters(in: .whitespaces))
        verifyCode = nil
    }

    func cancelLogin() {
        loginTask?.cancel(); loginTask = nil
        verifyCode?.resume(returning: ""); verifyCode = nil
        phase = account == nil ? .off : .online
    }

    func disconnect() {
        stopLoop()
        try? FileManager.default.removeItem(at: accountFile)
        try? FileManager.default.removeItem(at: bufFile)
        account = nil
        phase = .off
        note = "已断开。手机上的微信 ClawBot 不会再控制这台电脑。"
    }

    private func save(_ a: WeixinAccount) {
        account = a
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(a) {
            try? d.write(to: accountFile, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: accountFile.path)
        }
    }

    // MARK: 收消息

    private func startLoop() {
        guard let acc = account else { return }
        loop?.cancel()
        phase = .online
        note = ""
        loop = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            _ = try? await WeixinAPI.post(acc.baseUrl, "ilink/bot/msg/notifystart", ["base_info": WeixinAPI.baseInfo], token: acc.token, timeout: 10)
            var buf = (try? String(contentsOf: self.bufFile, encoding: .utf8)) ?? ""
            var wait: TimeInterval = 35
            var failures = 0
            while !Task.isCancelled {
                do {
                    let r = try await WeixinAPI.post(acc.baseUrl, "ilink/bot/getupdates",
                                                     ["get_updates_buf": buf, "base_info": WeixinAPI.baseInfo], token: acc.token, timeout: wait + 10)
                    if let t = r["longpolling_timeout_ms"] as? Double, t > 0 { wait = t / 1000 }
                    let ret = (r["ret"] as? Int) ?? 0, err = (r["errcode"] as? Int) ?? 0
                    if ret == -14 || err == -14 {
                        await MainActor.run { self.phase = .expired("微信连接已失效（可能在手机上停用了 ClawBot），请重新扫码连接。") }
                        return
                    }
                    if ret != 0 || err != 0 {
                        failures += 1
                        try? await Task.sleep(nanoseconds: UInt64(min(30, failures * 3)) * 1_000_000_000)
                        continue
                    }
                    failures = 0
                    if let nb = r["get_updates_buf"] as? String, !nb.isEmpty {
                        buf = nb
                        try? nb.write(to: self.bufFile, atomically: true, encoding: .utf8)
                    }
                    for m in (r["msgs"] as? [[String: Any]]) ?? [] {
                        await MainActor.run { self.handle(m) }
                    }
                } catch {
                    if Task.isCancelled { return }
                    failures += 1
                    try? await Task.sleep(nanoseconds: UInt64(min(30, failures * 3)) * 1_000_000_000)
                }
            }
        }
    }

    private func stopLoop() {
        loop?.cancel(); loop = nil
        if let acc = account {
            Task.detached { _ = try? await WeixinAPI.post(acc.baseUrl, "ilink/bot/msg/notifystop", ["base_info": WeixinAPI.baseInfo], token: acc.token, timeout: 5) }
        }
        stopTyping()
    }

    @MainActor private func handle(_ m: [String: Any]) {
        guard let acc = account else { return }
        // 只认绑定的那个微信号、只认人发的消息
        let from = m["from_user_id"] as? String ?? ""
        guard (m["message_type"] as? Int) == 1, acc.userId.isEmpty || from == acc.userId else { return }
        if let ct = m["context_token"] as? String, !ct.isEmpty { contextToken = ct }
        lastMessageAt = Date()
        var text = "", other = false
        for it in (m["item_list"] as? [[String: Any]]) ?? [] {
            switch it["type"] as? Int {
            case 1: text += ((it["text_item"] as? [String: Any])?["text"] as? String) ?? ""
            case 3: text += ((it["voice_item"] as? [String: Any])?["text"] as? String) ?? ""      // 语音转好的文字
            default: other = true
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            if other { reply("暂时只能处理文字和语音消息，图片和文件还不支持。") }
            return
        }
        incoming(text)
    }

    // MARK: 把微信消息交给 Claude

    @MainActor func incoming(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 正在等你确认或回答
        if let s = remoteSession, let pending = s.items.last(where: { ($0.kind == .permission || $0.kind == .question) && $0.resolved == nil }) {
            if pending.kind == .permission { answerPermission(s, pending, t) } else { answerQuestion(s, pending, t) }
            return
        }
        switch t.lowercased() {
        case "新对话", "/new", "/新对话":
            remoteSession = nil
            reply("好的，下一条消息会开一个新对话。")
            return
        case "停止", "/stop", "/停止":
            if let s = remoteSession, s.busy { s.interrupt(); reply("已让 Claude 停下。") } else { reply("现在没有在做的事。") }
            return
        case "状态", "/status", "/状态":
            reply(statusText())
            return
        case "帮助", "/help", "/帮助":
            reply(helpText)
            return
        default: break
        }
        let s = ensureSession()
        if s.busy {
            reply("Claude 还在做上一件事，这条消息会排在后面处理。回复「停止」可以打断它。")
        }
        // 中间在电脑上用过这个对话会换回原模式，这里再降一次
        s.enterRemoteMode(strict: true)
        s.send(text: t, images: [])
        startTyping()
    }

    private let helpText = """
    直接发消息，Claude 会在电脑上做事，做完把结果发回来。
    · 新对话：开一个新对话
    · 停止：打断正在做的事
    · 状态：看看电脑那边的情况
    需要授权时会先问你，回复「允许」或「拒绝」。
    """

    @MainActor private func statusText() -> String {
        guard let s = remoteSession else { return "电脑在线。还没有进行中的对话，直接发消息就会开始。\n工作文件夹：\(Self.friendlyFolder(workFolder))" }
        let state = s.busy ? "正在处理：\(s.status.isEmpty ? "工作中" : s.status)" : "空闲"
        return "电脑在线，\(state)。\n对话：\(s.title)\n工作文件夹：\(Self.friendlyFolder(s.cwd))"
    }

    @MainActor private func ensureSession() -> ChatSession {
        if let s = remoteSession, app?.sessions.contains(where: { $0 === s }) ?? true { return s }
        let s = ChatSession(cwd: workFolder, title: "微信远程")
        // 远程来的任务一律每步询问，需要授权的推到微信里确认（不管电脑上设的是什么）
        s.enterRemoteMode(strict: true)
        s.remote = self
        // 告诉 Claude 它在跟微信对话：不然它不知道回复会显示在哪，偶尔会自己脑补一段「输出格式要求」当成回复
        s.contextNote = "用户现在是在手机微信里通过「微信 ClawBot」给你发消息，你的回复会直接显示在微信聊天里。"
            + "请用简洁的中文回答，可以用列表和加粗，不要用表格和多级标题；需要用户确认的操作，客户端会另外发消息问他。"
        app?.addBackground(s)
        remoteSession = s
        return s
    }

    @MainActor private func answerPermission(_ s: ChatSession, _ item: ChatItem, _ t: String) {
        let yes = ["允许", "同意", "可以", "好", "好的", "行", "确认", "是", "y", "yes", "ok", "1"]
        let no = ["拒绝", "不", "不要", "不行", "否", "取消", "n", "no", "2"]
        if yes.contains(t.lowercased()) { s.allow(item); reply("已允许，继续。"); startTyping() }
        else if no.contains(t.lowercased()) { s.deny(item); reply("已拒绝。") }
        else { s.deny(item, reason: t); reply("已拒绝，并把你的话转告给 Claude。"); startTyping() }
    }

    @MainActor private func answerQuestion(_ s: ChatSession, _ item: ChatItem, _ t: String) {
        let qs = item.toolInput["questions"] as? [[String: Any]] ?? []
        let parts = qs.count > 1 ? t.components(separatedBy: CharacterSet(charactersIn: "\n；;")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } : [t]
        var answers: [String: String] = [:]
        for (i, q) in qs.enumerated() {
            let part = i < parts.count ? parts[i] : (parts.last ?? t)
            let opts = (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
            let nums = part.components(separatedBy: CharacterSet(charactersIn: ",，、 ")).compactMap { Int($0) }
            let picked = nums.compactMap { $0 >= 1 && $0 <= opts.count ? opts[$0 - 1] : nil }
            answers[q["question"] as? String ?? "\(i)"] = picked.isEmpty ? part : picked.joined(separator: ", ")
        }
        s.answerQuestion(item, answers: answers)
        reply("收到，继续。")
        startTyping()
    }

    // MARK: RemoteSink

    func remoteNeedsInput(_ s: ChatSession, item: ChatItem) {
        guard s === remoteSession else { return }
        stopTyping()
        if item.kind == .question {
            let qs = item.toolInput["questions"] as? [[String: Any]] ?? []
            var lines: [String] = ["Claude 想问你："]
            for (i, q) in qs.enumerated() {
                lines.append("")
                lines.append((qs.count > 1 ? "\(i + 1)) " : "") + (q["question"] as? String ?? ""))
                for (j, o) in ((q["options"] as? [[String: Any]]) ?? []).enumerated() {
                    let d = (o["description"] as? String).map { "（\($0)）" } ?? ""
                    lines.append("  \(j + 1). \(o["label"] as? String ?? "")\(d)")
                }
            }
            lines.append("")
            lines.append(qs.count > 1 ? "每个问题回复一行数字（多选用逗号隔开），也可以直接打字回答。" : "回复数字选择（多选用逗号隔开），也可以直接打字回答。")
            reply(lines.joined(separator: "\n"))
        } else {
            var detail = ""
            // 摘要里已经带上完整命令就不重复；命令太长摘要被截断时，才在下面完整列出
            if let c = item.toolInput["command"] as? String, !item.text.contains(c) { detail = "\n\n完整命令：\n" + String(c.prefix(400)) }
            else if let p = item.toolInput["file_path"] as? String { detail = "\n\n文件：" + Self.shortPath(p) }
            let what = item.toolName == "ExitPlanMode" ? "Claude 做好了计划，要开始执行吗？" : "Claude 想执行：\(item.text)"
            reply(what + detail + "\n\n回复「允许」继续，回复「拒绝」不做（也可以直接说为什么不行）。")
        }
    }

    func remoteTurnFinished(_ s: ChatSession, replies: [String], artifacts: [URL], error: String?) {
        guard s === remoteSession else { return }
        if !s.busy { stopTyping() }
        var text = replies.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        // 微信里不显示图片语法，去掉
        text = text.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
        if !artifacts.isEmpty {
            text += "\n\n做好的文件（在电脑上）：\n" + artifacts.prefix(8).map { "· " + Self.shortPath($0.path) }.joined(separator: "\n")
        }
        if let error { text += (text.isEmpty ? "" : "\n\n") + "出错了：" + error }
        if text.isEmpty { text = "做完了。" }
        reply(text)
    }

    // MARK: 发消息

    /// 回复你；太长就按段落切成几条（每条不超过 1800 字）
    func reply(_ text: String) {
        guard let acc = account, !acc.userId.isEmpty else { return }
        let ctx = contextToken
        for chunk in Self.split(text, limit: 1800) {
            var msg: [String: Any] = [
                "from_user_id": "", "to_user_id": acc.userId,
                "client_id": "fcf-claude-" + UUID().uuidString.lowercased(),
                "message_type": 2, "message_state": 2,
                "item_list": [["type": 1, "text_item": ["text": chunk]]],
            ]
            if let ctx { msg["context_token"] = ctx }
            let body: [String: Any] = ["msg": msg, "base_info": WeixinAPI.baseInfo]
            // 按顺序一条条发
            sendQueue.async {
                let sem = DispatchSemaphore(value: 0)
                Task.detached {
                    _ = try? await WeixinAPI.post(acc.baseUrl, "ilink/bot/sendmessage", body, token: acc.token, timeout: 15)
                    sem.signal()
                }
                _ = sem.wait(timeout: .now() + 20)
            }
        }
    }
    private let sendQueue = DispatchQueue(label: "weixin.send")

    static func split(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        var out: [String] = [], cur = ""
        for para in text.components(separatedBy: "\n\n") {
            if cur.count + para.count + 2 > limit, !cur.isEmpty { out.append(cur); cur = "" }
            if para.count > limit {
                var p = Substring(para)
                while p.count > limit { out.append(String(p.prefix(limit))); p = p.dropFirst(limit) }
                cur = String(p)
            } else {
                cur += (cur.isEmpty ? "" : "\n\n") + para
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    // MARK: 「对方正在输入」

    private func startTyping() {
        guard let acc = account, !acc.userId.isEmpty else { return }
        typingTimer?.invalidate()
        let ctx = contextToken
        let fire: () -> Void = { [weak self] in
            Task.detached {
                if self?.typingTicket == nil {
                    let r = try? await WeixinAPI.post(acc.baseUrl, "ilink/bot/getconfig",
                                                      ["ilink_user_id": acc.userId, "context_token": ctx ?? "", "base_info": WeixinAPI.baseInfo], token: acc.token, timeout: 10)
                    self?.typingTicket = r?["typing_ticket"] as? String
                }
                guard let ticket = self?.typingTicket else { return }
                _ = try? await WeixinAPI.post(acc.baseUrl, "ilink/bot/sendtyping",
                                              ["ilink_user_id": acc.userId, "typing_ticket": ticket, "status": 1, "base_info": WeixinAPI.baseInfo], token: acc.token, timeout: 10)
            }
        }
        fire()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.remoteSession?.busy == true, self.remoteSession?.needsAttention != true else { self?.stopTyping(); return }
            fire()
        }
        RunLoop.main.add(t, forMode: .common)
        typingTimer = t
    }

    private func stopTyping() {
        typingTimer?.invalidate(); typingTimer = nil
        guard let acc = account, let ticket = typingTicket else { return }
        Task.detached {
            _ = try? await WeixinAPI.post(acc.baseUrl, "ilink/bot/sendtyping",
                                          ["ilink_user_id": acc.userId, "typing_ticket": ticket, "status": 2, "base_info": WeixinAPI.baseInfo], token: acc.token, timeout: 10)
        }
    }

    static func shortPath(_ p: String) -> String { p.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    /// 给人看的文件夹名：个人文件夹（likang）/ 桌面 › 报价单
    static func friendlyFolder(_ p: String) -> String {
        let home = NSHomeDirectory()
        if p == home { return "个人文件夹（\((home as NSString).lastPathComponent)）" }
        let names = ["Desktop": "桌面", "Documents": "文稿", "Downloads": "下载"]
        let name = (p as NSString).lastPathComponent
        let parent = ((p as NSString).deletingLastPathComponent as NSString).lastPathComponent
        if p.hasPrefix(home + "/"), let n = names[name], (p as NSString).deletingLastPathComponent == home { return n }
        return (names[parent] ?? parent) + " › " + name
    }

    /// 二维码图片
    static func qrImage(_ s: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        f.correctionLevel = "M"
        guard let img = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: img)
        let n = NSImage(size: rep.size); n.addRepresentation(rep)
        return n
    }
}
