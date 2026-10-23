import Foundation
import AppKit

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
    @Published var streamTick = 0          // 流式输出时递增，用来让列表跟着滚动
    @Published var needsAttention = false  // 有等你回答/确认的卡片（侧栏蓝点）

    // 输入框草稿跟着对话走，切换对话不会丢；单独一个对象，打字不会刷新整段对话列表
    let draft = DraftState()

    static var cachedCommands: [SlashCommand] = []
    @Published var commands: [SlashCommand] = ChatSession.cachedCommands

    private var proc: ClaudeProcess?
    private var streamingItem: ChatItem?
    private var thinkingItem: ChatItem?
    private var toolItems: [String: ChatItem] = [:]
    private var bashItems: [(cmd: String, item: ChatItem)] = []
    private var reqSeq = 0
    private var turnStart = 0
    private(set) var extraDirs: [String] = []
    private(set) var initInfo: [String: Any]?      // 后台启动时报告的信息（版本、MCP 状态等），状态面板用
    var pid: Int32? { proc?.pid }   // /add-dir 加进来的额外文件夹          // 本轮回复从 items 的哪里开始，用来收集文件产物
    private var modeExplicit = false
    private var modeBeforePlan: PermissionMode?
    private var deltaBuf = ""
    private var flushScheduled = false

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
        p.onEvent = { [weak self] e in self?.handle(e) }
        p.onExit = { [weak self] code, tail in self?.processExited(code: code, output: tail) }
        do {
            // 用户手动选过模式才传参数，否则跟随各层 settings.json
            try p.start(cwd: cwd, resume: sessionId, model: model.rawValue,
                        permissionMode: modeExplicit ? mode.rawValue : nil, addDirs: extraDirs)
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
        let wasBusy = busy
        busy = false
        status = ""
        finishStreaming()
        cancelPending()
        for it in toolItems.values where it.toolState == .running { it.toolState = .stopped }
        if wasBusy || code != 0 {
            let tail = output.split(separator: "\n").suffix(8).joined(separator: "\n")
            items.append(ChatItem(.error, "后台进程退出了（代码 \(code)）。再发一条消息会自动接着这个对话重新启动。" + (tail.isEmpty ? "" : "\n\n" + tail)))
        }
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

    func shutdown() {
        guard let p = proc else { return }
        p.onExit = nil
        p.terminate()
        proc = nil
        busy = false
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

        let shown = ChatItem(.user, text)
        shown.images = images
        shown.files = files
        items.append(shown)
        turnStart = items.count
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
        var content: Any = prompt
        if !images.isEmpty {
            var blocks: [[String: Any]] = images.compactMap { img in
                guard let png = img.pngData else { return nil }
                return ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": png.base64EncodedString()]]
            }
            if !prompt.isEmpty { blocks.append(["type": "text", "text": prompt]) }
            content = blocks
        }
        guard ensureProcess() else { return }
        proc?.send(["type": "user", "message": ["role": "user", "content": content]])
        busy = true
        status = "等待回复"
        lastActive = Date()
    }

    func interrupt() {
        guard busy else { return }
        control(["subtype": "interrupt"])
        status = "正在停止"
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
        status = "继续中"
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
        streamTick += 1
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
        switch type {
        case "system": handleSystem(e)
        case "stream_event":
            guard parent == nil, let ev = e["event"] as? [String: Any] else { return }
            handleStream(ev)
        case "assistant":
            guard let msg = e["message"] as? [String: Any], let blocks = msg["content"] as? [[String: Any]] else { return }
            if let parent { subagentStep(parent: parent, blocks: blocks); return }
            if let m = msg["model"] as? String { activeModel = m }
            if let u = msg["usage"] as? [String: Any] {
                let n = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].reduce(0) { $0 + ((u[$1] as? Int) ?? 0) }
                if n > 0 { contextTokens = n }
            }
            for b in blocks { assistantBlock(b) }
        case "user":
            guard parent == nil, let msg = e["message"] as? [String: Any] else { return }
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
            if turnStart <= items.count {
                let arts = Artifacts.collect(items[turnStart...])
                if !arts.isEmpty {
                    let it = ChatItem(.artifacts)
                    it.artifacts = arts
                    items.append(it)
                }
                turnStart = items.count
            }
            busy = false
            status = ""
            lastActive = Date()
            if let c = e["total_cost_usd"] as? Double {
                UsageStore.shared.addCost(c - costUSD)
                costUSD = c
            }
            if (e["is_error"] as? Bool) == true {
                let r = (e["result"] as? String) ?? (e["subtype"] as? String ?? "出错了")
                items.append(ChatItem(.error, r))
            }
            for it in toolItems.values where it.toolState == .running { it.toolState = .stopped }
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest); NSSound(named: "Glass")?.play() }
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
                status = "回复中"
            case "thinking":
                finishStreaming()
                let it = ChatItem(.thinking)
                it.streaming = true
                items.append(it)
                thinkingItem = it
                status = "思考中"
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
                streamTick += 1
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
            status = ToolLabel.firstLine(it.text)
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
            status = "等你回答"
        } else {
            it = ChatItem(.permission, ToolLabel.summary(name: name, input: input))
            status = "等你确认"
        }
        it.requestId = rid
        it.toolName = name
        it.toolInput = input
        items.append(it)
        needsAttention = true
        if !NSApp.isActive { NSApp.requestUserAttention(.criticalRequest); NSSound(named: "Ping")?.play() }
    }

    static func resultText(_ c: Any?) -> String {
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
            DispatchQueue.main.async {
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
