import Foundation
import AppKit

enum CCSettings {
    static let defaultMode: PermissionMode = {
        let url = URL(fileURLWithPath: NSString(string: "~/.claude/settings.json").expandingTildeInPath)
        guard let d = try? Data(contentsOf: url),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let p = j["permissions"] as? [String: Any],
              let m = p["defaultMode"] as? String, let mode = PermissionMode(rawValue: m) else { return .default }
        return mode
    }()
}

struct HistoryEntry: Identifiable, Hashable {
    var id: String { sessionId }
    let sessionId: String
    let url: URL
    let cwd: String
    let title: String
    let modified: Date
    var continuesFrom: Set<String> = []   // 文件里复制过来的旧会话 ID（旧版 --resume 会新建文件并复制历史）
    var orphanParent: String?             // 第一条消息接在哪条「不在本文件里」的消息后面
    var tailUuids: Set<String> = []       // 文件末尾的消息 ID，用来认出谁接着它往下聊
    var mergedFiles: [URL] = []           // 被合并隐藏的旧文件（删除时要一起移走，否则旧的会重新冒出来）
    var folder: String { (cwd as NSString).lastPathComponent.isEmpty ? cwd : (cwd as NSString).lastPathComponent }
}

enum History {
    static let root = URL(fileURLWithPath: NSString(string: "~/.claude/projects").expandingTildeInPath)

    /// 只读每个文件的头尾各一段，几百个会话也很快
    static func list(limit: Int = 300) -> [HistoryEntry] {
        let fm = FileManager.default
        var files: [(URL, Date)] = []
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let fs = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for f in fs where f.pathExtension == "jsonl" {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                files.append((f, m))
            }
        }
        files.sort { $0.1 > $1.1 }
        return mergeContinuations(files.prefix(limit).compactMap { entry(url: $0.0, modified: $0.1) })
    }

    /// 同一段对话被拆成多个文件时（终端里续接旧对话会新建文件、把历史复制过去），只保留最新的那个文件：
    /// 它已经包含完整历史。被续接的旧文件从列表里隐藏。
    static func mergeContinuations(_ list: [HistoryEntry]) -> [HistoryEntry] {
        let byId = Dictionary(list.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        var ownerOfTail: [String: String] = [:]
        for e in list { for u in e.tailUuids { ownerOfTail[u] = e.sessionId } }
        var hidden = Set<String>()
        var predsOf: [String: Set<String>] = [:]
        for e in list {
            var preds = e.continuesFrom.filter { byId[$0] != nil }
            if let p = e.orphanParent, let owner = ownerOfTail[p], owner != e.sessionId { preds.insert(owner) }
            for p in preds where (byId[p]?.modified ?? .distantFuture) <= e.modified { hidden.insert(p); predsOf[e.sessionId, default: []].insert(p) }
        }
        return list.filter { !hidden.contains($0.sessionId) }.map { e in
            var out = e, seen: Set<String> = [e.sessionId], stack = Array(predsOf[e.sessionId] ?? [])
            while let p = stack.popLast() {
                guard seen.insert(p).inserted, let pe = byId[p] else { continue }
                out.mergedFiles.append(pe.url)
                stack.append(contentsOf: predsOf[p] ?? [])
            }
            return out
        }
    }

    static func entry(url: URL, modified: Date) -> HistoryEntry? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let head = h.readData(ofLength: 256 * 1024)
        let size = (try? h.seekToEnd()) ?? 0
        let tailStart = size > 128 * 1024 ? size - 128 * 1024 : 0
        try? h.seek(toOffset: tailStart)
        let tail = h.readDataToEndOfFile()

        let ownId = url.deletingPathExtension().lastPathComponent
        var cwd: String?, firstPrompt: String?, aiTitle: String?
        var foreign = Set<String>(), seen = Set<String>(), orphan: String?
        for line in head.split(separator: 0x0A) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let sid = o["sessionId"] as? String, sid != ownId { foreign.insert(sid) }
            if orphan == nil, let p = o["parentUuid"] as? String, !seen.contains(p) { orphan = p }
            if let u = o["uuid"] as? String { seen.insert(u) }
            if cwd == nil, let c = o["cwd"] as? String { cwd = c }
            if firstPrompt == nil, o["type"] as? String == "user", o["isMeta"] as? Bool != true,
               o["isCompactSummary"] as? Bool != true,
               o["isSidechain"] as? Bool != true,
               let m = o["message"] as? [String: Any], let raw = promptText(m["content"]), case let s = stripBashContext(raw), !s.hasPrefix("<") {
                let d = FileKind.decode(s)
                firstPrompt = d.text.isEmpty ? (d.files.first?.lastPathComponent ?? s) : d.text
            }
            if aiTitle == nil, o["type"] as? String == "ai-title" { aiTitle = o["aiTitle"] as? String }
        }
        var tailUuids = Set<String>(), tailTitle: String?
        for line in tail.split(separator: 0x0A).reversed() {
            if line.count < 4000, tailTitle == nil, let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
               o["type"] as? String == "ai-title", let t = o["aiTitle"] as? String { tailTitle = t }
            // 只取末尾这段消息的 ID（不完整解析大行，用字符串查找）
            if let r = line.range(of: Data("\"uuid\":\"".utf8)) {
                let rest = line[r.upperBound...]
                if let end = rest.firstIndex(of: UInt8(ascii: "\"")), let u = String(data: Data(rest[rest.startIndex..<end]), encoding: .utf8) { tailUuids.insert(u) }
            }
        }
        if let tailTitle { aiTitle = tailTitle }
        guard let cwd, firstPrompt != nil || aiTitle != nil else { return nil }
        let title = aiTitle ?? ToolLabel.firstLine(firstPrompt ?? "")
        return HistoryEntry(sessionId: ownId, url: url, cwd: cwd, title: title, modified: modified,
                            continuesFrom: foreign, orphanParent: orphan, tailUuids: tailUuids)
    }

    /// 客户端把「!命令」的输出作为上下文放在消息开头（<bash-input>…</bash-stdout>），读回来时去掉，只留你写的话
    static func stripBashContext(_ s: String) -> String {
        guard s.hasPrefix("<bash-input>") else { return s }
        var rest = Substring(s)
        while rest.hasPrefix("<bash-input>"), let r = rest.range(of: "</bash-stdout>") {
            rest = rest[r.upperBound...].drop(while: { $0 == "\n" })
        }
        return String(rest)
    }

    static func promptText(_ c: Any?) -> String? {
        if let s = c as? String { return s }
        if let arr = c as? [[String: Any]] {
            if arr.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
            let t = arr.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            return t.isEmpty ? nil : t
        }
        return nil
    }

    /// 把会话记录还原成界面条目（只取最近 400 条，避免超长会话卡顿）
    static func loadTranscript(_ url: URL) -> (items: [ChatItem], title: String?) {
        // 内存映射读取：几十 MB 的记录文件不用整份复制进内存，系统按需读、用完可回收
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return ([], nil) }
        var items: [ChatItem] = []
        var tools: [String: ChatItem] = [:]
        var title: String?
        var turnStart = 0
        // 一轮结束（下一条你的消息之前 / 文件末尾）把这一轮的产物补成卡片
        func flushArtifacts() {
            guard turnStart <= items.count else { return }
            let arts = Artifacts.collect(items[turnStart...])
            if !arts.isEmpty {
                let it = ChatItem(.artifacts)
                it.artifacts = arts
                items.append(it)
            }
        }
        // 不显示的记录（请求备份、文件快照、队列操作）往往占了记录文件的一大半，解析前先按开头跳过
        let skipPrefixes = ["{\"type\":\"api-request", "{\"type\":\"file-history", "{\"type\":\"queue-operation"].map { Data($0.utf8) }
        for line in data.split(separator: 0x0A) {
            if skipPrefixes.contains(where: { line.starts(with: $0) }) { continue }
            // 逐行释放解析时的临时内存，长对话打开时内存不会一下涨很多
            guard let o = autoreleasepool(invoking: { try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] }) else { continue }
            let type = o["type"] as? String
            if type == "ai-title" { title = o["aiTitle"] as? String; continue }
            guard type == "user" || type == "assistant", o["isSidechain"] as? Bool != true,
                  let m = o["message"] as? [String: Any] else { continue }
            if type == "user" {
                if let arr = m["content"] as? [[String: Any]], arr.contains(where: { $0["type"] as? String == "tool_result" }) {
                    for b in arr where b["type"] as? String == "tool_result" {
                        guard let id = b["tool_use_id"] as? String, let it = tools[id] else { continue }
                        it.toolResult = ChatSession.resultText(b["content"])
                        it.toolState = (b["is_error"] as? Bool) == true ? .failed : .done
                    }
                    continue
                }
                // 你发过的图片（截图、粘贴的图）也读回来，重新打开旧对话时能看能点
                let imgs: [NSImage] = ((m["content"] as? [[String: Any]]) ?? []).compactMap { b in
                    guard b["type"] as? String == "image", let src = b["source"] as? [String: Any],
                          let b64 = src["data"] as? String, let d = Data(base64Encoded: b64) else { return nil }
                    return NSImage(data: d)
                }
                guard let raw = promptText(m["content"]) ?? (imgs.isEmpty ? nil : "") else { continue }
                let s = o["isMeta"] as? Bool == true ? raw : stripBashContext(raw)
                if o["isMeta"] as? Bool == true {
                    if !s.hasPrefix("<") && !s.hasPrefix("[Image: source:") { items.append(ChatItem(.notice, s)) }
                    continue
                }
                if s.hasPrefix("<command-name>") {
                    let name = s.components(separatedBy: "<command-name>").last?.components(separatedBy: "</command-name>").first ?? s
                    items.append(ChatItem(.user, name))
                    continue
                }
                if o["isCompactSummary"] as? Bool == true {
                    items.append(ChatItem(.notice, "上下文已压缩，较早的内容已经整理成摘要。"))
                    continue
                }
                if s.hasPrefix("<") { continue }
                flushArtifacts()
                let d = FileKind.decode(s)
                // 终端里贴图会在文字里留「[Image #1]」占位，图片已经单独显示了，去掉占位
                let text = imgs.isEmpty ? d.text : d.text.replacingOccurrences(of: #"\[Image #\d+\]\s*"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let u = ChatItem(.user, text)
                u.files = d.files
                u.images = imgs
                items.append(u)
                turnStart = items.count
            } else {
                for b in (m["content"] as? [[String: Any]]) ?? [] {
                    switch b["type"] as? String {
                    case "text":
                        if let t = b["text"] as? String, !t.isEmpty { items.append(ChatItem(.assistant, t)) }
                    case "thinking":
                        if let t = b["thinking"] as? String, !t.isEmpty { items.append(ChatItem(.thinking, t)) }
                    case "tool_use":
                        let id = b["id"] as? String ?? UUID().uuidString
                        let it = ChatItem.tool(id: id, name: b["name"] as? String ?? "", input: b["input"] as? [String: Any] ?? [:])
                        it.toolState = .stopped
                        tools[id] = it
                        items.append(it)
                    default: break
                    }
                }
            }
        }
        flushArtifacts()
        if items.count > 400 {
            items = Array(items.suffix(400))
            items.insert(ChatItem(.notice, "更早的内容没有显示，对话本身是完整的。"), at: 0)
        }
        return (items, title)
    }
}
