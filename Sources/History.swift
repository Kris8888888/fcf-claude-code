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

    /// 在会话记录里找搜索词（直接按字节查，几十 MB 的记录也很快）。英文不区分大小写。
    /// cancelled 返回 true 时提前停（你又改了搜索词）
    static func search(_ q: String, in files: [(String, URL)], cancelled: () -> Bool) -> Set<String> {
        var needles = [q, q.uppercased(), q.capitalized].map { Data($0.utf8) }
        // JSON 里换行、引号是转义过的，搜索词里一般没有，不额外处理
        needles = Array(Set(needles))
        var out = Set<String>()
        for (i, (sid, url)) in files.enumerated() {
            if out.contains(sid) { continue }
            if i % 8 == 0, cancelled() { return out }
            guard let d = try? Data(contentsOf: url, options: .alwaysMapped) else { continue }
            if needles.contains(where: { realHit($0, in: d) }) { out.insert(sid) }
        }
        return out
    }

    /// 命中要算数：在你或 Claude 的对话行里（不是系统附件、记忆注入），而且不是夹在图片编码这种长串字母数字中间
    private static func realHit(_ n: Data, in d: Data) -> Bool {
        let b64: (UInt8) -> Bool = { c in (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 43 || c == 47 || c == 61 }
        let userTag = Data("\"type\":\"user\"".utf8), aiTag = Data("\"type\":\"assistant\"".utf8), metaTag = Data("\"isMeta\":true".utf8)
        var from = d.startIndex
        var checked = 0
        while let r = d.range(of: n, in: from..<d.endIndex) {
            from = r.upperBound
            checked += 1
            if checked > 200 { return false }     // 同一个文件里命中太多次都不算数，多半是编码数据
            // 英文按整词算：搜 TM 不要命中 html、.tmp 这种单词中间
            let isLetter: (UInt8) -> Bool = { c in (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
            if let f = n.first, isLetter(f), r.lowerBound > d.startIndex, isLetter(d[r.lowerBound - 1]) { continue }
            if let l = n.last, isLetter(l), r.upperBound < d.endIndex, isLetter(d[r.upperBound]) { continue }
            // 前后各 16 个字节都是编码字符 → 在图片编码里
            let lo = max(d.startIndex, r.lowerBound - 16), hi = min(d.endIndex, r.upperBound + 16)
            if d[lo..<r.lowerBound].allSatisfy(b64) && d[r.upperBound..<hi].allSatisfy(b64) && r.lowerBound - lo == 16 { continue }
            // 找到这一行，看是不是对话行
            let ls = d[d.startIndex..<r.lowerBound].lastIndex(of: 0x0A).map { $0 + 1 } ?? d.startIndex
            let le = d[r.upperBound...].firstIndex(of: 0x0A) ?? d.endIndex
            let head = d[ls..<min(le, ls + 400)]
            if head.starts(with: Data("{\"type\":\"queue-operation".utf8)) { continue }
            let line = d[ls..<le]
            guard line.range(of: userTag) != nil || line.range(of: aiTag) != nil else { from = le; continue }
            if line.range(of: metaTag) != nil { from = le; continue }
            return true
        }
        return false
    }

    /// 粗查：这段开头里有没有一条完整的「你发的消息」（不解析 JSON，只找标记）
    static func hasUserPrompt(_ d: Data) -> Bool {
        d.range(of: Data("\"type\":\"user\"".utf8)) != nil
    }

    static func entry(url: URL, modified: Date) -> HistoryEntry? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        // 开头读 256KB 找标题。第一条消息带大截图时一行就有几百 KB，会被从中间截断、读不出内容，
        // 整个对话就从列表里消失了（重启后才暴露）。所以把截断的那一行读完整；还没找到第一条消息就继续往后读，最多 16MB
        var head = h.readData(ofLength: 256 * 1024)
        func readToLineEnd() {
            while head.last != 0x0A, head.count < 16 * 1024 * 1024 {
                let d = h.readData(ofLength: 1024 * 1024)
                if d.isEmpty { break }
                if let i = d.firstIndex(of: 0x0A) { head.append(d[d.startIndex...i]); break }
                head.append(d)
            }
        }
        readToLineEnd()
        while !Self.hasUserPrompt(head), head.count < 16 * 1024 * 1024 {
            let more = h.readData(ofLength: 512 * 1024)
            if more.isEmpty { break }
            head.append(more)
            readToLineEnd()
        }
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

    /// 对话最后一次回复时的上下文大小（从文件末尾找最后一条 usage），重新打开旧对话时就能知道它有多长
    static func lastContextTokens(_ url: URL) -> Int {
        guard let h = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 512 * 1024 ? size - 512 * 1024 : 0)
        let tail = h.readDataToEndOfFile()
        for line in tail.split(separator: 0x0A).reversed() where line.range(of: Data("\"usage\"".utf8)) != nil {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  o["type"] as? String == "assistant", o["isSidechain"] as? Bool != true,
                  let u = (o["message"] as? [String: Any])?["usage"] as? [String: Any] else { continue }
            let n = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].reduce(0) { $0 + ((u[$1] as? Int) ?? 0) }
            if n > 0 { return n }
        }
        return 0
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
        var turnTime: Date?             // 这一轮你发消息的时间，用来判断命令生成的文件是不是这一轮做的
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // 一轮结束（下一条你的消息之前 / 文件末尾）把这一轮的产物补成卡片
        func flushArtifacts() {
            guard turnStart <= items.count else { return }
            let arts = Artifacts.collect(items[turnStart...], since: turnTime)
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
                turnTime = (o["timestamp"] as? String).flatMap { iso.date(from: $0) }
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
