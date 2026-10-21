import Foundation
import AppKit
import Combine

// 额度与花费：来自 claude 的 rate_limit_event / result
final class UsageStore: ObservableObject {
    static let shared = UsageStore()
    @Published var fiveHour: Double?
    @Published var sevenDay: Double?
    @Published var fiveHourReset: Date?
    @Published var todayCost: Double = UserDefaults.standard.double(forKey: "cost-" + UsageStore.dayKey)

    static var dayKey: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }

    func addCost(_ delta: Double) {
        guard delta > 0 else { return }
        let k = "cost-" + Self.dayKey
        let v = UserDefaults.standard.double(forKey: k) + delta
        UserDefaults.standard.set(v, forKey: k)
        todayCost = v
    }

    func update(_ info: [String: Any]) {
        guard let w = info["unifiedWindows"] as? [String: Any] else { return }
        if let f = w["five_hour"] as? [String: Any] {
            fiveHour = f["utilization"] as? Double
            if let r = f["resetsAt"] as? Double { fiveHourReset = Date(timeIntervalSince1970: r) }
        }
        if let s = w["seven_day"] as? [String: Any] { sevenDay = s["utilization"] as? Double }
    }
}

// 侧栏里的一行：可能是正在开着的对话，也可能是历史记录
struct SidebarRow: Identifiable {
    let id: String
    let title: String
    let date: Date
    let live: ChatSession?
    let entry: HistoryEntry?
    var busy: Bool { live?.busy ?? false }
    var sessionId: String? { live?.sessionId ?? entry?.sessionId }
    var cwd: String { live?.cwd ?? entry?.cwd ?? "" }
}

struct Workspace: Identifiable {
    var id: String { cwd }
    let cwd: String
    var rows: [SidebarRow]
    var duplicateName = false
    var baseName: String { (cwd as NSString).lastPathComponent.isEmpty ? cwd : (cwd as NSString).lastPathComponent }
    /// 同名文件夹带上上一级目录名区分
    var name: String {
        guard duplicateName else { return baseName }
        let parent = ((cwd as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return baseName + "（" + (parent.count > 12 ? String(parent.prefix(8)) + "…" : parent) + "）"
    }
}

final class AppState: ObservableObject {
    @Published var sessions: [ChatSession] = []
    @Published var selected: UUID?
    @Published var history: [HistoryEntry] = []
    @Published var search = ""
    @Published var searchFocusToken = 0
    @Published var statusPanel: StatusTab?      // 状态与统计面板
    /// 置顶的会话 ID，先置顶的在前
    @Published var pinned: [String] = UserDefaults.standard.stringArray(forKey: "pinnedSessions") ?? []
    @Published var customTitles: [String: String] = UserDefaults.standard.dictionary(forKey: "customTitles") as? [String: String] ?? [:]
    private var subs: [UUID: AnyCancellable] = [:]

    var lastFolder: String {
        get { UserDefaults.standard.string(forKey: "lastFolder") ?? NSHomeDirectory() }
        set { UserDefaults.standard.set(newValue, forKey: "lastFolder") }
    }

    var current: ChatSession? { sessions.first { $0.id == selected } }

    init() {
        refreshHistory()
        newSession()
    }

    func refreshHistory() {
        DispatchQueue.global(qos: .userInitiated).async {
            let list = History.list()
            DispatchQueue.main.async {
                self.history = list
                // 仅用于截图验证：DUIHUATAI_PIN_DEMO=1 临时置顶最近两个（不保存）
                if ProcessInfo.processInfo.environment["DUIHUATAI_PIN_DEMO"] != nil, self.pinned.isEmpty {
                    self.pinned = list.prefix(2).map(\.sessionId)
                }
            }
        }
    }

    // MARK: 侧栏数据

    func title(for sessionId: String?, fallback: String) -> String {
        guard let sessionId, let t = customTitles[sessionId], !t.isEmpty else { return fallback }
        return t
    }

    /// 所有会话行（开着的 + 历史），不分组
    private var allRows: [SidebarRow] {
        var out: [SidebarRow] = []
        var seen = Set<String>()
        for s in sessions where s.started || !s.items.isEmpty {
            if let sid = s.sessionId { seen.insert(sid) }
            out.append(SidebarRow(id: s.id.uuidString, title: title(for: s.sessionId, fallback: s.title),
                                  date: s.lastActive, live: s, entry: nil))
        }
        for h in history where !seen.contains(h.sessionId) {
            out.append(SidebarRow(id: h.sessionId, title: title(for: h.sessionId, fallback: h.title),
                                  date: h.modified, live: nil, entry: h))
        }
        return out
    }

    private var query: String { search.trimmingCharacters(in: .whitespaces).lowercased() }

    func isPinned(_ r: SidebarRow) -> Bool { r.sessionId.map { pinned.contains($0) } ?? false }

    func togglePin(_ r: SidebarRow) {
        guard let sid = r.sessionId else { return }
        if pinned.contains(sid) { pinned.removeAll { $0 == sid } } else { pinned.insert(sid, at: 0) }
        UserDefaults.standard.set(pinned, forKey: "pinnedSessions")
    }

    /// 置顶组：按置顶先后排，搜索时也一起过滤
    var pinnedRows: [SidebarRow] {
        let order = Dictionary(pinned.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let q = query
        return allRows.filter { isPinned($0) && (q.isEmpty || $0.title.lowercased().contains(q)) }
            .sorted { (order[$0.sessionId ?? ""] ?? 0) < (order[$1.sessionId ?? ""] ?? 0) }
    }

    var workspaces: [Workspace] {
        // 置顶的会话只出现在置顶组，不在文件夹里重复
        let rows = Dictionary(grouping: allRows.filter { !isPinned($0) }, by: \.cwd)
        let q = query
        var list = rows.map { Workspace(cwd: $0.key, rows: $0.value.sorted { $0.date > $1.date }) }
        if !q.isEmpty {
            list = list.compactMap { w in
                if w.baseName.lowercased().contains(q) { return w }
                let r = w.rows.filter { $0.title.lowercased().contains(q) }
                return r.isEmpty ? nil : Workspace(cwd: w.cwd, rows: r)
            }
        }
        let counts = Dictionary(grouping: list, by: \.baseName).mapValues(\.count)
        for i in list.indices { list[i].duplicateName = (counts[list[i].baseName] ?? 0) > 1 }
        return list.sorted { ($0.rows.first?.date ?? .distantPast) > ($1.rows.first?.date ?? .distantPast) }
    }

    // MARK: 对话管理

    @discardableResult
    func newSession(cwd: String? = nil) -> ChatSession {
        // 已有一个还没开始的空对话就直接复用
        if let blank = sessions.first(where: { !$0.started && $0.items.isEmpty && $0.sessionId == nil }) {
            if let cwd { blank.changeFolder(cwd) }
            selected = blank.id
            return blank
        }
        let s = ChatSession(cwd: cwd ?? lastFolder)
        add(s)
        return s
    }

    private func add(_ s: ChatSession) {
        sessions.insert(s, at: 0)
        selected = s.id
        // 只在侧栏关心的字段变化时刷新（打字、流式输出不触发），并合并 0.15 秒内的连续变化
        let signals: [AnyPublisher<Void, Never>] = [
            s.$title.map { _ in () }.eraseToAnyPublisher(),
            s.$busy.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            s.$sessionId.map { _ in () }.eraseToAnyPublisher(),
            s.$started.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            s.$lastActive.map { _ in () }.eraseToAnyPublisher(),
            s.$needsAttention.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            s.$items.map(\.isEmpty).removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
        ]
        subs[s.id] = Publishers.MergeMany(signals)
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.objectWillChange.send() }
    }

    func select(_ row: SidebarRow) {
        if let s = row.live { selected = s.id; return }
        guard let h = row.entry else { return }
        if let s = sessions.first(where: { $0.sessionId == h.sessionId }) { selected = s.id; return }
        let s = ChatSession(cwd: h.cwd, title: title(for: h.sessionId, fallback: h.title), sessionId: h.sessionId)
        s.loadHistory(from: h.url)
        add(s)
    }

    func isSelected(_ row: SidebarRow) -> Bool {
        guard let cur = current else { return false }
        if let s = row.live { return s.id == cur.id }
        return cur.sessionId != nil && cur.sessionId == row.entry?.sessionId
    }

    func rename(_ row: SidebarRow, to name: String) {
        let sid = row.live?.sessionId ?? row.entry?.sessionId
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        row.live?.title = t.isEmpty ? row.title : t
        guard let sid else { return }
        customTitles[sid] = t.isEmpty ? nil : t
        UserDefaults.standard.set(customTitles, forKey: "customTitles")
    }

    /// 删除 = 关掉进程 + 把会话记录文件移到废纸篓（可以从废纸篓找回）
    func delete(_ row: SidebarRow) {
        let sid = row.live?.sessionId ?? row.entry?.sessionId
        if let s = row.live ?? sessions.first(where: { $0.sessionId != nil && $0.sessionId == sid }) { close(s, refresh: false) }
        if let sid, let url = fileURL(for: sid) { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        if let sid { history.removeAll { $0.sessionId == sid } }
        if let sid, pinned.contains(sid) { pinned.removeAll { $0 == sid }; UserDefaults.standard.set(pinned, forKey: "pinnedSessions") }
        refreshHistory()
    }

    func fileURL(for sessionId: String) -> URL? {
        if let h = history.first(where: { $0.sessionId == sessionId }) { return h.url }
        let dirs = (try? FileManager.default.contentsOfDirectory(at: History.root, includingPropertiesForKeys: nil)) ?? []
        return dirs.map { $0.appendingPathComponent(sessionId + ".jsonl") }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func close(_ s: ChatSession, refresh: Bool = true) {
        s.shutdown()
        subs[s.id] = nil
        sessions.removeAll { $0.id == s.id }
        if selected == s.id { selected = sessions.first?.id }
        if sessions.isEmpty { newSession() }
        if refresh { refreshHistory() }
    }

    func chooseFolder(start: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: start)
        panel.prompt = "在这里工作"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        lastFolder = url.path
        return url.path
    }

    func pickFolder(for s: ChatSession) {
        guard let path = chooseFolder(start: s.cwd) else { return }
        if s.started { newSession(cwd: path) } else { s.changeFolder(path) }
    }

    func shutdownAll() { sessions.forEach { $0.shutdown() } }
}
