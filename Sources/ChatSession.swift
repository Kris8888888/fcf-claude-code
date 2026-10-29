import Foundation
import AppKit
import Combine

final class ChatSession: ObservableObject, Identifiable {
    let id = UUID()
    @Published var title: String
    @Published var cwd: String
    @Published var sessionId: String?
    @Published var items: [ChatItem] = []
    @Published var busy = false
    @Published var loading = false
    @Published var status = ""
    @Published var model: ModelChoice = .inherit
    @Published var activeModel = ""
    @Published var mode: PermissionMode
    @Published var costUSD: Double = 0
    @Published var contextTokens = 0
    @Published var lastActive = Date()
    @Published var started = false
    /// 流式输出时发一下，只用来让列表跟着滚动（不触发整个对话页重算）
    let streamTicks = PassthroughSubject<Void, Never>()
    @Published var needsAttention = false  // 有等你回答/确认的卡片（侧栏蓝点）
    @Published var stalled = false         // 忙着但很久没收到任何消息，连接可能断了

    // 输入框草稿跟着对话走，切换对话不会丢；单独一个对象，打字不会刷新整段对话列表
    let draft = DraftState()

    static var cachedCommands: [SlashCommand] = []
    @Published var commands: [SlashCommand] = ChatSession.cachedCommands

    private var proc: ClaudeProcess?
    private var streamingItem: ChatItem?
    private var thinkingItem: ChatItem?
    private var startedDisplay: String?     // 后台进程启动时用的思考显示方式，设置改了就在空闲时重启
    private var toolItems: [String: ChatItem] = [:]
    private var bashItems: [(cmd: String, item: ChatItem)] = []
    private var reqSeq = 0
    /// 每发一条消息记下这一轮从 items 哪里开始；Claude 忙时也能继续发（排队），按先后对应各自的结果
    private var turnStarts: [Int] = []
    /// 还没收到结果的消息数：忙时又发了消息，第一条的结果回来时还不能算「空闲」
    /// 发出去、还没被 Claude 回传确认（replay）的消息条数。
    /// Claude 忙时你发的消息有时并进当前这轮，有时单独排成下一轮；回传确认能准确区分，不靠猜
    private var pendingTurns = 0
    /// 消息按顺序编码后再发（带图的消息在后台编码，不卡界面，也不会被后发的文字插队）
    private let sendQueue = DispatchQueue(label: "chat.send")
    private(set) var extraDirs: [String] = []
    /// 追加给 Claude 的背景说明（比如「这是微信远程对话」），启动后台时带上
    var contextNote: String?
    private(set) var initInfo: [String: Any]?      // 后台启动时报告的信息（版本、MCP 状态等），状态面板用
    var pid: Int32? { proc?.pid }   // /add-dir 加进来的额外文件夹          // 本轮回复从 items 的哪里开始，用来收集文件产物
    private var modeExplicit = false
    private var modeBeforePlan: PermissionMode?
    private var deltaBuf = ""
    private var flushScheduled = false
    private(set) var lastEventAt = Date()
    private var resultGen = 0
    /// 微信远程对话：需要你确认、一轮做完时通知它，转发到微信
    weak var remote: RemoteSink?
    private var lastInitAt = Date.distantPast
    private var interrupted = false        // 本轮是你手动停的，不发完成通知
    private var watchdog: Timer?
    /// 多久没消息算卡住（秒）；DUIHUATAI_STALL_SECONDS 仅用于测试
    private static let stallAfter = Double(ProcessInfo.processInfo.environment["DUIHUATAI_STALL_SECONDS"] ?? "") ?? 600

    init(cwd: String, title: String = "新对话", sessionId: String? = nil) {
        self.cwd = cwd
        self.title = title
        self.sessionId = sessionId
        self.mode = CCSettings.defaultMode
    }

    var folderName: String { (cwd as NSString).lastPathComponent.isEmpty ? cwd : (cwd as NSString).lastPathComponent }

    // MARK: 进程

    private func ensureProcess() -> Bool {
        if let proc, proc.isRunning { return true }
        let p = ClaudeProcess()
        p.onEvent = { [weak self] e in
            guard let self else { return }
            self.lastEventAt = Date()
            if self.stalled { self.stalled = false }
            self.handle(e)
        }
        p.onExit = { [weak self] code, tail in self?.processExited(code: code, output: tail) }
        do {
            // 用户手动选过模式才传参数，否则跟随各层 settings.json
            // 后台模式默认不返回思考内容，按「设置 → 思维链」决定要不要
            let disp = ThinkingPrefs.cliDisplay(cwd: cwd)
            try p.start(cwd: cwd, resume: sessionId, model: model.rawValue,
                        permissionMode: modeExplicit ? mode.rawValue : nil, addDirs: extraDirs,
                        extraArgs: (disp.map { ["--thinking-display", $0] } ?? [])
                            + (contextNote.map { ["--append-system-prompt", $0] } ?? []))
            startedDisplay = disp
            proc = p
            started = true
            costUSD = 0   // 新进程的花费从零累计
            control(["subtype": "initialize"])
            return true
        } catch {
            items.append(ChatItem(.error, "启动 claude 失败：\(error.localizedDescription)\n路径：\(LoginEnv.claudePath)\n文件夹：\(cwd)"))
            return false
        }
    }

    private func processExited(code: Int32, output: String) {
        proc = nil
        pendingTurns = 0
        turnStarts.removeAll()
        let wasBusy = busy
        busy = false
        setStatus("")
        finishStreaming()
        cancelPending()
        for it in toolItems.values where it.toolState == .running { it.toolState = .stopped }
        // 本机 claude 版本较旧、不认识某个新参数：记下来以后不再传，并把刚才那条消息重新发一次
        if code != 0, let flag = OptionalFlags.noteUnknown(in: output),
           let last = items.last(where: { $0.kind == .user }) {
            items.removeAll { $0 === last }
            items.append(ChatItem(.notice, "本机的 Claude 版本较旧，不支持 \(flag)，已自动关掉这个功能并重新发送。"))
            send(text: last.text, images: last.images, files: last.files)
            return
        }
        if LoginController.isAuthError(output) { showLoginCard(); return }
        if wasBusy || code != 0 {
            let tail = output.split(separator: "\n").suffix(8).joined(separator: "\n")
            items.append(ChatItem(.error, "后台进程退出了（代码 \(code)）。再发一条消息会自动接着这个对话重新启动。" + (tail.isEmpty ? "" : "\n\n" + tail)))
        }
    }

    /// 登录过期：放一张「重新登录」卡片（同一时间只留一张），记下要在登录后重发
    private(set) var needsResendAfterLogin = false
    private func showLoginCard() {
        needsResendAfterLogin = true
        items.removeAll { $0.kind == .login }
        items.append(ChatItem(.login))
    }

    /// 重新登录成功后：重启后台进程换上新登录；刚才因为登录过期没成功的那条消息自动再发一次
    func resumeAfterLogin() {
        let resend = needsResendAfterLogin
        needsResendAfterLogin = false
        items.removeAll { $0.kind == .login }
        guard !busy else { return }
        restart()
        guard resend, let last = items.last(where: { $0.kind == .user }) else { return }
        items.removeAll { $0 === last }
        items.append(ChatItem(.notice, "已重新登录，正在重新发送刚才的消息。"))
        send(text: last.text, images: last.images, files: last.files)
    }

    /// 让配置改动生效：结束空闲中的后台进程，下一条消息会带着 --resume 重新启动
    func restart() {
        guard let p = proc, !busy else { return }
        p.onExit = nil
        p.terminate()
        proc = nil
    }

    /// 本地命令的结果卡片（不发给 Claude）
    @discardableResult
    func addLocal(_ command: String, _ text: String) -> ChatItem {
        let it = ChatItem(.local, text)
        it.toolName = command
        items.append(it)
        return it
    }

    /// /add-dir：记下来，后台空闲时重启一次让它生效（对话记录会接上）
    func addDirectory(_ path: String) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            addLocal("/add-dir", "找不到这个文件夹：`\(path)`"); return
        }
        guard !extraDirs.contains(path) else { addLocal("/add-dir", "已经加过了：`\(path)`"); return }
        if busy { addLocal("/add-dir", "Claude 正在处理，等这一轮结束后再加。"); return }
        extraDirs.append(path)
        restart()
        addLocal("/add-dir", "已添加 `\(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))`，从下一条消息开始 Claude 可以读写这个文件夹。")
    }

    /// 状态文字没变就不赋值，免得每个事件都让界面重算
    private func setStatus(_ v: String) { if status != v { status = v } }

    /// wait: 退出 App 时同步结束；completion: 后台进程真正退出后调用（删除对话要等它停稳再挪文件）
    func shutdown(wait: Bool = false, completion: (() -> Void)? = nil) {
        guard let p = proc else { completion?(); return }
        p.onExit = nil
        p.terminate(wait: wait, completion: completion)
        proc = nil
        busy = false
        pendingTurns = 0
        turnStarts.removeAll()
        cancelPending()
    }

    @discardableResult
    private func control(_ request: [String: Any]) -> String {
        reqSeq += 1
        let rid = "gui-\(reqSeq)"
        proc?.send(["type": "control_request", "request_id": rid, "request": request])
        return rid
    }

    // MARK: 用户操作

    func send(text raw: String, images: [NSImage], files: [URL] = []) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty || !files.isEmpty else { return }

        if text.hasPrefix("!") && images.isEmpty && files.isEmpty {
            runBash(String(text.dropFirst()).trimmingCharacters(in: .whitespaces))
            return
        }

        // 「思维链」设置改过：后台空闲时先重启（带 --resume 接着这个对话），新设置才生效
        if proc != nil, !busy, sessionId != nil, ThinkingPrefs.cliDisplay(cwd: cwd) != startedDisplay { restart() }

        let shown = ChatItem(.user, text)
        shown.images = images
        shown.files = files
        items.append(shown)
        turnStarts.append(items.count)
        if title == "新对话" {
            title = ToolLabel.firstLine(text.isEmpty ? (files.first?.lastPathComponent ?? "图片") : text)
        }

        var prompt = text
        if !files.isEmpty {
            if prompt.isEmpty { prompt = "请查看这些附件。" }
            prompt += FileKind.encode(files)
        }
        // 已经跑完的「!命令」输出作为上下文带上，没跑完的留给下一条
        let doneBash = bashItems.filter { $0.item.toolResult != nil }
        bashItems.removeAll { $0.item.toolResult != nil }
        if !doneBash.isEmpty {
            let ctx = doneBash.map { "<bash-input>\($0.cmd)</bash-input>\n<bash-stdout>\(String(($0.item.toolResult ?? "").suffix(20000)))</bash-stdout>" }
            prompt = ctx.joined(separator: "\n") + "\n\n" + prompt
        }
        guard ensureProcess() else { turnStarts.removeLast(); return }
        let imgs = images
        sendQueue.async { [weak self] in
            var content: Any = prompt
            if !imgs.isEmpty {
                // 大截图转 PNG 要几百毫秒，放在后台做
                var blocks: [[String: Any]] = imgs.compactMap { img in
                    guard let png = img.pngData else { return nil }
                    return ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": png.base64EncodedString()]]
                }
                if !prompt.isEmpty { blocks.append(["type": "text", "text": prompt]) }
                content = blocks
            }
            DispatchQueue.main.async { self?.proc?.send(["type": "user", "message": ["role": "user", "content": content]]) }
        }
        // 斜杠命令（/compact 等）不会回传确认，只按「完成」判断
        if !text.hasPrefix("/") && !OptionalFlags.unsupported("--replay-user-messages") { pendingTurns += 1 }
        if !busy { interrupted = false }
        busy = true
        setStatus("等待回复")
        lastActive = Date()
        startWatchdog()
    }

    // MARK: 看门狗：网络掉线后后台可能一直干等，不报错也不断开

    private func startWatchdog() {
        lastEventAt = Date()
        stalled = false
        guard watchdog == nil else { return }
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.checkStall() }
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    private func checkStall() {
        guard busy else { watchdog?.invalidate(); watchdog = nil; stalled = false; return }
        // 等你回答、或工具（比如长时间跑的命令）还在执行时没消息是正常的
        // 子代理（Task/Agent）跑着时网络照样可能断，不能无限期豁免，只放宽时间
        let running = toolItems.values.filter { $0.toolState == .running }
        let agentOnly = !running.isEmpty && running.allSatisfy { ["Task", "Agent"].contains($0.toolName) }
        if needsAttention || (!running.isEmpty && !agentOnly) {
            lastEventAt = Date(); return
        }
        // 正在思考时后端不返回思考内容，给更长的时间
        // Claude 自己遇到断网会自动重试（会发 api_retry 消息过来），这里只兜底「彻底没动静」的情况。
        // 对话很长（几十万字上下文）时，代理处理一次请求、出第一个字就要好几分钟，阈值也要跟着放宽
        var limit = Self.stallAfter
        if contextTokens > 300_000 { limit *= 1.5 }
        if agentOnly { limit *= 3 } else if thinkingItem != nil { limit *= 1.5 }
        let s = Date().timeIntervalSince(lastEventAt) > limit
        if s != stalled { stalled = s }
    }

    /// 卡住后：结束后台进程，接着这个对话重新启动，让 Claude 从刚才的进度继续
    func reconnect() {
        abandonProcess()
        items.append(ChatItem(.notice, "连接中断，已重新连接。"))
        if sessionId != nil {
            send(text: "刚才连接中断了，请接着刚才的进度继续。", images: [])
        } else if let last = items.last(where: { $0.kind == .user }) {
            // 对话还没真正开始就断了（没有会话编号，接不上），把你刚才那条原样重发
            send(text: last.text, images: last.images, files: last.files)
        }
    }

    /// 卡住后只停止，不重发
    func stopStalled() {
        abandonProcess()
        items.append(ChatItem(.notice, "已停止。再发一条消息会接着这个对话继续。"))
    }

    private func abandonProcess() {
        shutdown()
        finishStreaming()
        for it in toolItems.values where it.toolState == .running { it.toolState = .stopped }
        setStatus("")
        stalled = false
    }

    func interrupt() {
        guard busy else { return }
        control(["subtype": "interrupt"])
        interrupted = true
        setStatus("正在停止")
    }

    func setMode(_ m: PermissionMode) {
        if m == .plan && mode != .plan { modeBeforePlan = mode }
        mode = m
        modeExplicit = true
        if proc?.isRunning == true { control(["subtype": "set_permission_mode", "mode": m.rawValue]) }
    }

    func setModel(_ m: ModelChoice) {
        model = m
        if proc?.isRunning == true { control(["subtype": "set_model", "model": m.rawValue.isEmpty ? "default" : m.rawValue]) }
    }

    func changeFolder(_ path: String) {
        guard !started else { return }
        cwd = path
    }

    /// 「!命令」：在本地跑 shell，输出留给下一条消息作为上下文（跟终端里的 bash 模式一致）
    private func runBash(_ cmd: String) {
        guard !cmd.isEmpty else { return }
        let item = ChatItem.tool(id: UUID().uuidString, name: "Bash", input: ["command": cmd])
        item.text = "本地运行：" + ToolLabel.firstLine(cmd)
        items.append(item)
        bashItems.append((cmd, item))
        let cwd = self.cwd
        DispatchQueue.global().async {
            let r = Shell.run("/bin/zsh", ["-lc", cmd], cwd: cwd)
            DispatchQueue.main.async {
                item.toolResult = r.output
                item.toolState = r.code == 0 ? .done : .failed
            }
        }
    }

    // MARK: 回应选择题 / 权限

    func answerQuestion(_ item: ChatItem, answers: [String: String]) {
        guard item.resolved == nil else { return }
        var input = item.toolInput
        input["answers"] = answers
        respond(item.requestId, ["behavior": "allow", "updatedInput": input])
        item.resolved = answers.values.joined(separator: "；")
        refreshAttention()
    }

    func allow(_ item: ChatItem, always: Bool = false) {
        guard item.resolved == nil else { return }
        var resp: [String: Any] = ["behavior": "allow", "updatedInput": item.toolInput]
        if always {
            resp["updatedPermissions"] = [["type": "addRules", "rules": [["toolName": item.toolName]],
                                           "behavior": "allow", "destination": "session"]]
        }
        respond(item.requestId, resp)
        item.resolved = always ? "已允许（本次对话不再询问）" : "已允许"
        refreshAttention()
        if item.toolName == "ExitPlanMode" {
            // 计划通过后回到进入计划前的模式
            let back = modeBeforePlan ?? (CCSettings.defaultMode == .plan ? .default : CCSettings.defaultMode)
            modeBeforePlan = nil
            mode = back
            modeExplicit = true
            control(["subtype": "set_permission_mode", "mode": back.rawValue])
        }
    }

    func deny(_ item: ChatItem, reason: String = "") {
        guard item.resolved == nil else { return }
        let msg = reason.isEmpty ? "用户拒绝了这一步。" : "用户拒绝了这一步，反馈：\(reason)"
        respond(item.requestId, ["behavior": "deny", "message": msg])
        item.resolved = reason.isEmpty ? "已拒绝" : "已拒绝：\(reason)"
        refreshAttention()
    }

    private func respond(_ requestId: String, _ response: [String: Any]) {
        proc?.send(["type": "control_response",
                    "response": ["subtype": "success", "request_id": requestId, "response": response]])
        setStatus("继续中")
    }

    /// 回合结束或进程退出后，还没处理的提问/确认都作废，避免点了发给不存在的请求
    private func cancelPending() {
        for it in items where (it.kind == .question || it.kind == .permission) && it.resolved == nil {
            it.resolved = "已取消"
        }
        needsAttention = false
    }

    private func refreshAttention() {
        needsAttention = items.contains { ($0.kind == .question || $0.kind == .permission) && $0.resolved == nil }
    }

    // MARK: 事件处理

    private func flushDelta() {
        flushScheduled = false
        guard !deltaBuf.isEmpty else { return }
        streamingItem?.text += deltaBuf
        deltaBuf = ""
        streamTicks.send()
    }

    private func finishStreaming() {
        flushDelta()
        streamingItem?.streaming = false
        streamingItem = nil
        finishThinking()
    }

    private func finishThinking() {
        guard let it = thinkingItem else { return }
        it.streaming = false
        it.duration = Date().timeIntervalSince(it.startedAt)
        thinkingItem = nil
    }

    private func handle(_ e: [String: Any]) {
        let type = e["type"] as? String ?? ""
        let parent = e["parent_tool_use_id"] as? String
        // 兜底：已经算空闲了，Claude 主线程又开始一条新回复（不是子代理的），重新算「忙」
        if !busy, parent == nil, type == "stream_event",
           ((e["event"] as? [String: Any])?["type"] as? String) == "message_start" {
            busy = true
            interrupted = false
            turnStarts.append(items.count)
            setStatus("回复中")
            startWatchdog()
        }
        switch type {
        case "system": handleSystem(e)
        case "stream_event":
            guard parent == nil, let ev = e["event"] as? [String: Any] else { return }
            handleStream(ev)
        case "assistant":
            guard let msg = e["message"] as? [String: Any], let blocks = msg["content"] as? [[String: Any]] else { return }
            if let parent { subagentStep(parent: parent, blocks: blocks); return }
            if let m = msg["model"] as? String, m != activeModel { activeModel = m }
            if let u = msg["usage"] as? [String: Any] {
                let n = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].reduce(0) { $0 + ((u[$1] as? Int) ?? 0) }
                if n > 0 && n != contextTokens { contextTokens = n }
            }
            for b in blocks { assistantBlock(b) }
        case "user":
            guard parent == nil, let msg = e["message"] as? [String: Any] else { return }
            // 你发的消息被 Claude 收下了（回传确认），不用再显示一遍
            if e["isReplay"] as? Bool == true { pendingTurns = max(0, pendingTurns - 1); return }
            if let s = msg["content"] as? String {
                if !s.isEmpty { items.append(ChatItem(.notice, s)) }
                return
            }
            for b in (msg["content"] as? [[String: Any]]) ?? [] where b["type"] as? String == "tool_result" {
                guard let tid = b["tool_use_id"] as? String, let it = toolItems[tid] else { continue }
                it.toolResult = Self.resultText(b["content"])
                it.toolState = (b["is_error"] as? Bool) == true ? .failed : .done
            }
        case "result":
            finishStreaming()
            cancelPending()
            // 这一轮里新建 / 修改的文件，作为产物卡片放在回复末尾
            let start = turnStarts.first ?? items.count
            turnStarts.removeAll()
            if start <= items.count {
                let arts = Artifacts.collect(items[start...], since: items.indices.contains(start - 1) ? items[start - 1].startedAt : Date().addingTimeInterval(-3600), cwd: cwd)
                if !arts.isEmpty {
                    let it = ChatItem(.artifacts)
                    it.artifacts = arts
                    items.append(it)
                }
            }
            // 以 Claude 的「本轮结束」为准：你在它忙时发的消息常被并进同一轮回答，只会回来一次结束信号，
            // 按发送条数计数会一直转圈。如果确实还有单独排队的一轮，它开始输出时会重新进入「忙」
            // 手动停止：排队的也一起作废；否则还有没被收下的消息，就继续算「忙」等下一轮
            if interrupted { pendingTurns = 0 }
            busy = pendingTurns > 0
            setStatus(busy ? "接着处理你补充的消息" : "")
            lastActive = Date()
            if let c = e["total_cost_usd"] as? Double {
                UsageStore.shared.addCost(c - costUSD)
                costUSD = c
            }
            if (e["is_error"] as? Bool) == true {
                let r = (e["result"] as? String) ?? (e["subtype"] as? String ?? "出错了")
                if LoginController.isAuthError(r) { showLoginCard() } else { items.append(ChatItem(.error, r)) }
            }
            // 登录过期时 Claude 会把「Please run /login」当成一条回复发回来：换成登录卡片
            if start <= items.count, items[start...].contains(where: { $0.kind == .assistant && LoginController.isAuthNotice($0.text) }) {
                items.removeAll { $0.kind == .assistant && LoginController.isAuthNotice($0.text) }
                showLoginCard()
            }
            for it in toolItems.values where it.toolState == .running { it.toolState = .stopped }
            if let remote {
                let replies = start <= items.count ? items[start...].filter { $0.kind == .assistant }.map(\.text) : []
                let arts = start <= items.count ? (items[start...].last(where: { $0.kind == .artifacts })?.artifacts.map(\.url) ?? []) : []
                let err: String? = (e["is_error"] as? Bool) == true
                    ? (LoginController.isAuthError((e["result"] as? String) ?? "") ? "电脑上的 Claude 登录已过期，需要在电脑上重新登录。" : ((e["result"] as? String) ?? "出错了"))
                    : (interrupted ? "已停止。" : nil)
                remote.remoteTurnFinished(self, replies: replies, artifacts: arts, error: err)
            }
            // 完成提醒稍等一下：排队的下一轮马上开始的话就不算完成
            let ok = (e["is_error"] as? Bool) != true && !interrupted
            resultGen += 1
            let gen = resultGen
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, gen == self.resultGen, !self.busy else { return }
                if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest); NSSound(named: "Glass")?.play() }
                if ok { Notifier.shared.taskDone(self) }
                self.interrupted = false     // 手动停止只对这一批消息有效
            }
            // 保险：还有没收下的消息时，Claude 会马上开始下一轮（先发一个 init）。
            // 20 秒都没开始，说明那条消息不会再处理了，别一直转圈（等回复本身可能很久，所以只看「开没开始」）
            if busy {
                let endedAt = Date()
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                    guard let self, gen == self.resultGen, self.busy, self.lastInitAt < endedAt else { return }
                    self.pendingTurns = 0
                    self.busy = false
                    self.setStatus("")
                }
            }
        case "rate_limit_event":
            if let info = e["rate_limit_info"] as? [String: Any] { UsageStore.shared.update(info) }
        case "control_request":
            handleControl(e)
        case "control_response":
            guard let r = e["response"] as? [String: Any], let inner = r["response"] as? [String: Any],
                  let cmds = inner["commands"] as? [[String: Any]] else { return }
            let list = cmds.compactMap { c -> SlashCommand? in
                guard let n = c["name"] as? String else { return nil }
                return SlashCommand(name: n, description: (c["description"] as? String) ?? "")
            }
            commands = list
            ChatSession.cachedCommands = list
        default: break
        }
    }

    private func handleSystem(_ e: [String: Any]) {
        switch e["subtype"] as? String {
        case "init":
            lastInitAt = Date()
            // 记下 FCF 给 Claude 用的代理：检查/下载更新时走同一条线路
            if let pid = proc?.pid, UserDefaults.standard.string(forKey: "fcfProxy") == nil {
                DispatchQueue.global(qos: .utility).async {
                    if let v = StatusProbe.proxy(under: pid) { UserDefaults.standard.set(v, forKey: "fcfProxy") }
                }
            }
            if let s = e["session_id"] as? String { sessionId = s }
            if let m = e["model"] as? String { activeModel = m }
            if let pm = e["permissionMode"] as? String, let m = PermissionMode(rawValue: pm) { mode = m }
            initInfo = e
        case "status":
            switch e["status"] as? String {
            case "requesting": status = "思考中"
            case "compacting": status = "正在压缩上下文"
            default: break
            }
        case "api_retry":
            // 连接断了，Claude 正在自动重试：如实告诉你，不用你操作
            let n = e["attempt"] as? Int ?? 0, total = e["max_retries"] as? Int ?? 0
            let why = (e["error_status"] as? Int) == 429 ? "请求太频繁" : (e["error_status"] as? Int).map { $0 >= 500 ? "服务繁忙" : "请求出错" } ?? "网络连接断了"
            setStatus("\(why)，正在自动重试（第 \(n)/\(total) 次）")
        case "compact_boundary":
            items.append(ChatItem(.notice, "上下文已压缩，较早的内容已经整理成摘要。"))
        default: break
        }
    }

    private func handleStream(_ ev: [String: Any]) {
        switch ev["type"] as? String {
        case "content_block_start":
            let cb = ev["content_block"] as? [String: Any]
            switch cb?["type"] as? String {
            case "text":
                finishStreaming()
                let it = ChatItem(.assistant)
                it.streaming = true
                items.append(it)
                streamingItem = it
                setStatus("回复中")
            case "thinking":
                finishStreaming()
                let it = ChatItem(.thinking)
                it.streaming = true
                items.append(it)
                thinkingItem = it
                setStatus("思考中")
            case "tool_use": status = "准备工具"
            default: break
            }
        case "content_block_delta":
            guard let d = ev["delta"] as? [String: Any] else { return }
            if d["type"] as? String == "text_delta", let t = d["text"] as? String, streamingItem != nil {
                // 合并约 60ms 内的片段再刷新，长回复也不卡
                deltaBuf += t
                if !flushScheduled {
                    flushScheduled = true
                    // 长回复每次重排更费时，放宽刷新间隔，给输入框留出响应时间
                    let interval = (streamingItem?.text.count ?? 0) > 3000 ? 0.15 : 0.06
                    DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in self?.flushDelta() }
                }
            } else if d["type"] as? String == "thinking_delta", let t = d["thinking"] as? String, let it = thinkingItem {
                it.text += t
            }
        case "content_block_stop":
            finishThinking()
        default: break
        }
    }

    private func assistantBlock(_ b: [String: Any]) {
        switch b["type"] as? String {
        case "thinking":
            // 完整思考内容（如果后端返回了）覆盖流式累积的
            if let t = b["thinking"] as? String, !t.isEmpty,
               let it = thinkingItem ?? items.last(where: { $0.kind == .thinking }) { it.text = t }
        case "text":
            let t = b["text"] as? String ?? ""
            if let it = streamingItem {
                deltaBuf = ""
                it.text = t
                finishStreaming()
                streamTicks.send()
            } else if !t.isEmpty {
                items.append(ChatItem(.assistant, t))
            }
        case "tool_use":
            finishStreaming()
            let id = b["id"] as? String ?? UUID().uuidString
            let name = b["name"] as? String ?? "工具"
            if name == "AskUserQuestion" { return }   // 由选择题卡片展示
            let it = ChatItem.tool(id: id, name: name, input: b["input"] as? [String: Any] ?? [:])
            toolItems[id] = it
            items.append(it)
            setStatus(ToolLabel.firstLine(it.text))
        default: break
        }
    }

    private func subagentStep(parent: String, blocks: [[String: Any]]) {
        guard let it = toolItems[parent] else { return }
        for b in blocks where b["type"] as? String == "tool_use" {
            it.subSteps += 1
            it.subLatest = ToolLabel.summary(name: b["name"] as? String ?? "", input: b["input"] as? [String: Any] ?? [:])
        }
    }

    private func handleControl(_ e: [String: Any]) {
        guard let rid = e["request_id"] as? String, let req = e["request"] as? [String: Any] else { return }
        guard req["subtype"] as? String == "can_use_tool" else {
            proc?.send(["type": "control_response",
                        "response": ["subtype": "error", "request_id": rid, "error": "客户端不支持该请求"]])
            return
        }
        finishStreaming()
        let name = req["tool_name"] as? String ?? ""
        let input = req["input"] as? [String: Any] ?? [:]
        let it: ChatItem
        if name == "AskUserQuestion" {
            it = ChatItem(.question, "")
            setStatus("等你回答")
        } else {
            it = ChatItem(.permission, ToolLabel.summary(name: name, input: input))
            setStatus("等你确认")
        }
        it.requestId = rid
        it.toolName = name
        it.toolInput = input
        items.append(it)
        needsAttention = true
        remote?.remoteNeedsInput(self, item: it)
        if !NSApp.isActive { NSApp.requestUserAttention(.criticalRequest); NSSound(named: "Ping")?.play() }
    }

    /// 工具结果只保留界面会显示的前 2 万字，读大文件、长命令输出时不把整份留在内存里
    static func resultText(_ c: Any?) -> String {
        let full = rawResultText(c)
        return full.count > 20000 ? String(full.prefix(20000)) + "\n…（还有 \(full.count - 20000) 字没有显示）" : full
    }

    static func rawResultText(_ c: Any?) -> String {
        if let s = c as? String { return s }
        if let arr = c as? [[String: Any]] {
            return arr.map { b in
                if b["type"] as? String == "text" { return b["text"] as? String ?? "" }
                if b["type"] as? String == "image" { return "［图片］" }
                return ""
            }.joined(separator: "\n")
        }
        return ""
    }

    // MARK: 从历史记录恢复（后台解析，大文件不卡界面）

    func loadHistory(from url: URL) {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let parsed = History.loadTranscript(url)
            let ctx = History.lastContextTokens(url)
            DispatchQueue.main.async {
                if self.contextTokens == 0 { self.contextTokens = ctx }
                self.loading = false
                guard self.items.isEmpty else { return }
                self.items = parsed.items
                for it in parsed.items where it.kind == .tool { self.toolItems[it.toolUseId] = it }
                if let t = parsed.title { self.title = t }
            }
        }
    }
}

extension NSImage {
    var pngData: Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

final class DraftState: ObservableObject {
    @Published var text = ""
    @Published var images: [NSImage] = []
    @Published var files: [URL] = []

    func add(_ urls: [URL]) {
        for u in urls {
            if FileKind.imageExts.contains(u.pathExtension.lowercased()), let img = NSImage(contentsOf: u) {
                images.append(img)
            } else if !files.contains(u) {
                files.append(u)
            }
        }
    }
}
