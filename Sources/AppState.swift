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
    @Published var selected: UUID? {
        didSet {
            // 切走的旧对话如果只是点开看了看（没发消息、没在跑、没草稿），从内存里放掉；再点会从记录重新读
            guard oldValue != selected, let old = oldValue, let s = sessions.first(where: { $0.id == old }),
                  !s.started, !s.busy, s.sessionId != nil,
                  s.draft.text.isEmpty, s.draft.images.isEmpty, s.draft.files.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selected != old else { return }
                self.subs[old] = nil
                self.sessions.removeAll { $0.id == old }
            }
        }
    }
    @Published var history: [HistoryEntry] = []
    @Published var search = "" { didSet { if search != oldValue { scheduleContentSearch() } } }
    /// 内容里提到搜索词的对话（标题没对上也能搜到）
    @Published private(set) var contentMatches: Set<String> = []
    private var searchGen = 0
    @Published var searchFocusToken = 0
    @Published var statusPanel: StatusTab?      // 状态与统计面板
    @Published var showTrash = false
    @Published var showLogin = false            // 重新登录窗口
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
        // 登录成功：各对话换上新登录；因为登录过期没发出去的那条消息自动重发
        LoginController.shared.onSuccess = { [weak self] in
            self?.sessions.forEach { $0.resumeAfterLogin() }
        }
        // 微信 ClawBot：绑定过就自动开始收消息
        WeixinBridge.shared.app = self
        WeixinBridge.shared.startIfBound()
        // 网页远程：开启过就自动开始
        WebRemote.shared.app = self
        WebRemote.shared.startIfEnabled()
    }

    private var historyGen = 0
    private var deleting = Set<String>()     // 正在等进程退出再移进废纸篓的会话，刷新列表时先藏着
    func refreshHistory() {
        historyGen += 1
        let gen = historyGen
        DispatchQueue.global(qos: .userInitiated).async {
            let list = History.list()
            DispatchQueue.main.async {
                guard gen == self.historyGen else { return }     // 后发的刷新已经在路上，旧结果作废
                self.history = list.filter { !self.deleting.contains($0.sessionId) }
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

    /// 标题里有没有搜索词。英文按整词算（搜 TM 不命中 HTML），中文照常
    static func textHas(_ text: String, _ q: String) -> Bool {
        guard q.first?.isASCII == true && q.first?.isLetter == true || q.last?.isASCII == true && q.last?.isLetter == true else {
            return text.lowercased().contains(q)
        }
        let pattern = "(?<![A-Za-z])" + NSRegularExpression.escapedPattern(for: q) + "(?![A-Za-z])"
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// 标题、对话内容里有搜索词都算
    private func matches(_ r: SidebarRow, _ q: String) -> Bool {
        if q.isEmpty || Self.textHas(r.title, q) { return true }
        if let sid = r.sessionId, contentMatches.contains(sid) { return true }
        if let live = r.live { return live.items.contains { ($0.kind == .user || $0.kind == .assistant) && Self.textHas($0.text, q) } }
        return false
    }

    /// 搜索时这一行是靠内容（不是标题）搜到的
    func contentOnlyMatch(_ r: SidebarRow) -> Bool {
        let q = query
        guard !q.isEmpty, !Self.textHas(r.title, q) else { return false }
        // 文件夹名对上而整组列出的行不算
        return matches(r, q)
    }

    /// 打字停 0.3 秒后在后台翻一遍会话记录，不卡输入
    private func scheduleContentSearch() {
        searchGen += 1
        let gen = searchGen, q = query
        guard q.count >= 2 else { if !contentMatches.isEmpty { contentMatches = [] }; return }
        let files = history.flatMap { h in [(h.sessionId, h.url)] + h.mergedFiles.map { (h.sessionId, $0) } }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            var stale = false
            DispatchQueue.main.sync { stale = gen != self.searchGen }
            if stale { return }
            let found = History.search(q, in: files) { gen != self.currentSearchGen() }
            DispatchQueue.main.async { if gen == self.searchGen { self.contentMatches = found } }
        }
    }
    private func currentSearchGen() -> Int { var g = 0; DispatchQueue.main.sync { g = searchGen }; return g }

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
        return allRows.filter { isPinned($0) && matches($0, q) }
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
                let r = w.rows.filter { matches($0, q) }
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

    /// 网页远程用：全部对话（不受电脑上搜索框的影响）
    func remoteRows() -> [SidebarRow] { allRows }

    /// 网页远程打开一个对话：开着的直接用，历史的在后台载入（不切换你在电脑上正在看的对话）
    func openRemote(_ id: String) -> ChatSession? {
        if let s = sessions.first(where: { $0.id.uuidString == id }) { return s }
        if let s = sessions.first(where: { $0.sessionId == id }) { return s }
        guard let h = history.first(where: { $0.sessionId == id }) else { return nil }
        let s = ChatSession(cwd: h.cwd, title: title(for: h.sessionId, fallback: h.title), sessionId: h.sessionId)
        s.lastActive = h.modified
        s.loadHistory(from: h.url)
        addBackground(s)
        return s
    }

    /// 后台开的对话（比如微信远程）：放进列表，但不抢你正在看的对话
    func addBackground(_ s: ChatSession) { add(s, select: false) }

    private func add(_ s: ChatSession, select: Bool = true) {
        sessions.insert(s, at: 0)
        if select || selected == nil { selected = s.id }
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
        // 只是点开看：沿用记录文件的最后修改时间，列表里的位置不动；发了新消息才会更新
        s.lastActive = h.modified
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

    /// 删除 = 关掉后台进程 + 把会话记录移进 App 的废纸篓（可以恢复，到期自动清除）
    func delete(_ row: SidebarRow) {
        let sid = row.sessionId
        let live = row.live ?? sessions.first(where: { $0.sessionId != nil && $0.sessionId == sid })
        guard let sid else { if let live { close(live) } else { refreshHistory() }; return }     // 还没发过消息的空对话，关掉就行
        let wasPinned = pinned.contains(sid)
        let merged = history.first(where: { $0.sessionId == sid })?.mergedFiles ?? []
        // 先从列表拿掉，界面立刻有反应；等 claude 进程真正退出再挪文件，否则它还会往原位置写，删掉的对话又冒出来
        history.removeAll { $0.sessionId == sid }
        if wasPinned { pinned.removeAll { $0 == sid }; UserDefaults.standard.set(pinned, forKey: "pinnedSessions") }
        deleting.insert(sid)
        let moveToTrash = { [weak self] in
            guard let self else { return }
            self.deleting.remove(sid)
            if let url = self.fileURL(for: sid) {
                do {
                    try TrashStore.shared.add(sessionId: sid, file: url, title: row.title, cwd: row.cwd,
                                              wasPinned: wasPinned, customTitle: self.customTitles[sid], extraFiles: merged)
                    let key = TrashStore.shared.entries.first?.id
                    self.showToast("已移到废纸篓：\(row.title)", undo: { [weak self] in
                        if let e = TrashStore.shared.entries.first(where: { $0.id == key }) { self?.restore(e) }
                    })
                } catch {
                    if wasPinned { self.pinned.insert(sid, at: 0); UserDefaults.standard.set(self.pinned, forKey: "pinnedSessions") }
                    self.showToast("删除失败：\(error.localizedDescription)")
                }
            }
            self.refreshHistory()
        }
        if let live {
            live.shutdown(completion: moveToTrash)
            close(live, refresh: false)
        } else {
            moveToTrash()
        }
    }

    /// 从废纸篓恢复：放回原位置，原来置顶的恢复置顶
    @discardableResult
    func restore(_ e: TrashEntry) -> Bool {
        do {
            try TrashStore.shared.restore(e)
        } catch {
            showToast("恢复失败：\(error.localizedDescription)")
            return false
        }
        if e.wasPinned, !pinned.contains(e.sessionId) {
            pinned.insert(e.sessionId, at: 0)
            UserDefaults.standard.set(pinned, forKey: "pinnedSessions")
        }
        if let t = e.customTitle { customTitles[e.sessionId] = t; UserDefaults.standard.set(customTitles, forKey: "customTitles") }
        refreshHistory()
        showToast("已恢复：\(e.title)")
        return true
    }

    /// 彻底删除时顺手清掉它的自定义标题
    func purge(_ e: TrashEntry) {
        TrashStore.shared.purge(e)
        if customTitles[e.sessionId] != nil { customTitles[e.sessionId] = nil; UserDefaults.standard.set(customTitles, forKey: "customTitles") }
    }

    // MARK: 底部提示条（带撤销）

    struct Toast: Identifiable { let id = UUID(); let text: String; let undo: (() -> Void)? }
    @Published var toast: Toast?

    func showToast(_ text: String, undo: (() -> Void)? = nil) {
        let t = Toast(text: text, undo: undo)
        toast = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.toast?.id == t.id { self?.toast = nil }
        }
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

    func shutdownAll() { sessions.forEach { $0.shutdown(wait: true) } }
}
