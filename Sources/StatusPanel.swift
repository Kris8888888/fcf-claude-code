import SwiftUI
import AppKit
import Charts

enum StatusTab: String, Identifiable, CaseIterable {
    case status, usage, stats
    var id: String { rawValue }
    var label: String { self == .status ? "状态" : self == .usage ? "用量" : "统计" }
}

// MARK: 后台探测：起一个不保存记录的 claude，只跑 /usage（本地命令，不调模型），顺带拿到启动信息和代理

final class StatusProbe: ObservableObject {
    @Published var initInfo: [String: Any]?
    @Published var usageText: String?
    @Published var proxy: String?
    @Published var loading = false
    @Published var error: String?
    private var proc: ClaudeProcess?

    func run(cwd: String) {
        guard !loading else { return }
        loading = true; error = nil
        let p = ClaudeProcess()
        proc = p
        p.onEvent = { [weak self] e in
            guard let self else { return }
            if e["type"] as? String == "system", e["subtype"] as? String == "init" {
                self.initInfo = e
                // 代理由 FCF 在启动时注入，只能从真正的 claude 进程环境里读
                if let pid = p.pid {
                    DispatchQueue.global().async {
                        let v = Self.proxy(under: pid)
                        DispatchQueue.main.async { self.proxy = v }
                    }
                }
            }
            if e["type"] as? String == "result" {
                self.usageText = (e["result"] as? String) ?? ""
                self.finish()
            }
        }
        p.onExit = { [weak self] code, out in
            guard let self, self.loading else { return }
            self.error = "读取失败（\(code)）" + (out.isEmpty ? "" : "：" + String(out.suffix(200)))
            self.loading = false
        }
        do {
            try p.start(cwd: cwd, resume: nil, model: nil, permissionMode: nil, extraArgs: ["--no-session-persistence"])
            p.send(["type": "user", "message": ["role": "user", "content": "/usage"]])
        } catch {
            self.error = error.localizedDescription
            loading = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) { [weak self] in
            guard let self, self.loading else { return }
            self.error = "等了 40 秒没有结果"
            self.finish()
        }
    }

    private func finish() {
        loading = false
        let p = proc
        proc = nil
        // 稍等一下再关，让读代理的那一步先完成
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { p?.onExit = nil; p?.terminate() }
    }

    static func proxy(under pid: Int32) -> String? {
        for k in [pid] + ClaudeProcess.descendants(of: pid) {
            let r = Shell.run("/bin/ps", ["eww", "-o", "command=", "-p", String(k)])
            for part in r.output.split(separator: " ") {
                for key in ["HTTPS_PROXY=", "https_proxy=", "HTTP_PROXY=", "http_proxy=", "ALL_PROXY="] where part.hasPrefix(key) {
                    let v = String(part.dropFirst(key.count))
                    if !v.isEmpty { return v }
                }
            }
        }
        return nil
    }
}

// MARK: 统计缓存（终端 /stats 同源：~/.claude/stats-cache.json）

struct StatsCache {
    struct Day { let date: Date; let messages: Int; let sessions: Int; let tools: Int }
    struct ModelTotals { let input, output, cacheRead, cacheWrite: Int; var total: Int { input + output + cacheRead + cacheWrite } }

    var days: [Day] = []
    var dailyModelTokens: [(date: Date, byModel: [String: Int])] = []
    var modelUsage: [String: ModelTotals] = [:]
    var totalSessions = 0
    var longestSessionMs: Double = 0
    var firstSession: Date?
    var computedDate = ""

    static let dayFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()

    static func load() -> StatsCache? {
        let url = URL(fileURLWithPath: NSString(string: "~/.claude/stats-cache.json").expandingTildeInPath)
        guard let d = try? Data(contentsOf: url), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        var s = StatsCache()
        s.computedDate = j["lastComputedDate"] as? String ?? ""
        for a in (j["dailyActivity"] as? [[String: Any]]) ?? [] {
            guard let ds = a["date"] as? String, let date = dayFmt.date(from: ds) else { continue }
            s.days.append(Day(date: date, messages: a["messageCount"] as? Int ?? 0, sessions: a["sessionCount"] as? Int ?? 0, tools: a["toolCallCount"] as? Int ?? 0))
        }
        for a in (j["dailyModelTokens"] as? [[String: Any]]) ?? [] {
            guard let ds = a["date"] as? String, let date = dayFmt.date(from: ds) else { continue }
            s.dailyModelTokens.append((date, a["tokensByModel"] as? [String: Int] ?? [:]))
        }
        for (m, v) in (j["modelUsage"] as? [String: [String: Any]]) ?? [:] {
            s.modelUsage[m] = ModelTotals(input: v["inputTokens"] as? Int ?? 0, output: v["outputTokens"] as? Int ?? 0,
                                          cacheRead: v["cacheReadInputTokens"] as? Int ?? 0, cacheWrite: v["cacheCreationInputTokens"] as? Int ?? 0)
        }
        s.totalSessions = j["totalSessions"] as? Int ?? 0
        s.longestSessionMs = ((j["longestSession"] as? [String: Any])?["duration"] as? Double) ?? 0
        if let f = j["firstSessionDate"] as? String { s.firstSession = ISO8601DateFormatter.withFraction.date(from: f) ?? ISO8601DateFormatter().date(from: f) }
        return s
    }
}

extension ISO8601DateFormatter {
    static let withFraction: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
}

enum Fmt {
    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        if d >= 1e9 { return String(format: "%.1fb", d / 1e9) }
        if d >= 1e6 { return String(format: "%.1fm", d / 1e6) }
        if d >= 1e3 { return String(format: "%.1fk", d / 1e3) }
        return "\(n)"
    }
    static func duration(ms: Double) -> String {
        let m = Int(ms / 60000), d = m / 1440, h = (m % 1440) / 60, mm = m % 60
        return d > 0 ? "\(d) 天 \(h) 小时 \(mm) 分" : h > 0 ? "\(h) 小时 \(mm) 分" : "\(mm) 分钟"
    }
    static func model(_ id: String) -> String {
        // claude-opus-5-5 → Opus 5.5
        let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
        guard let name = parts.first else { return id }
        let ver = parts.dropFirst().prefix { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
        return name.prefix(1).uppercased() + name.dropFirst() + (ver.isEmpty ? "" : " " + ver)
    }
    static let md: DateFormatter = { let f = DateFormatter(); f.dateFormat = "M月d日"; return f }()
}

/// 模型系列色：固定顺序分配（按模型族），换筛选不会重新上色。已用 dataviz 校验脚本验证（浅色 / 深色）
enum SeriesColor {
    static func color(for model: String) -> Color {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua || ThemeStore.shared.palette.scheme == .dark
        let light: [UInt32] = [0x2A78D6, 0xEB6834, 0x1BAF7A, 0xEDA100], darkS: [UInt32] = [0x3987E5, 0xD95926, 0x199E70, 0xC98500]
        let slot: Int
        if model.contains("opus") { slot = 0 } else if model.contains("fable") { slot = 1 }
        else if model.contains("sonnet") { slot = 2 } else { slot = 3 }
        return Color(nsColor: Palette.rgb((ThemeStore.shared.palette.scheme == .light ? false : dark) ? darkS[slot] : light[slot]))
    }
}

// MARK: 面板

struct StatusPanel: View {
    @EnvironmentObject var app: AppState
    @State var tab: StatusTab
    @StateObject private var probe = StatusProbe()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) { ForEach(StatusTab.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                Spacer()
                if probe.loading { ProgressView().controlSize(.small) }
                Button("刷新") { probe.run(cwd: cwd) }.disabled(probe.loading)
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            ScrollView {
                Group {
                    switch tab {
                    case .status: StatusTabView(session: app.current, probe: probe)
                    case .usage: UsageTabView(probe: probe)
                    case .stats: StatsTabView()
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 860, height: 660)
        .background(T.paper)
        .onAppear { probe.run(cwd: cwd) }
    }

    var cwd: String { app.current?.cwd ?? app.lastFolder }
}

struct KVRow: View {
    let k: String
    let v: String
    var tint: Color = T.ink
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(k).font(.system(size: 13)).foregroundStyle(T.muted).frame(width: 120, alignment: .leading)
            Text(v).font(.system(size: 13)).foregroundStyle(tint).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
    }
}

struct GroupBox2<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(T.ink).padding(.bottom, 4)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(T.sunk))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(T.line, lineWidth: 1))
    }
}

// MARK: 状态

struct StatusTabView: View {
    let session: ChatSession?
    @ObservedObject var probe: StatusProbe
    @EnvironmentObject var app: AppState

    var info: [String: Any]? { session?.initInfo ?? probe.initInfo }

    var account: [String: Any] {
        let url = URL(fileURLWithPath: NSString(string: "~/.claude.json").expandingTildeInPath)
        guard let d = try? Data(contentsOf: url), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return j["oauthAccount"] as? [String: Any] ?? [:]
    }

    var loginMethod: String {
        let a = account
        let t = ((a["organizationType"] as? String) ?? "") + " " + ((a["billingType"] as? String) ?? "") + " " + ((a["seatTier"] as? String) ?? "")
        let l = t.lowercased()
        if l.contains("enterprise") { return "Claude Enterprise 账号" }
        if l.contains("team") { return "Claude Team 账号" }
        if l.contains("max") { return "Claude Max 账号" }
        if l.contains("pro") { return "Claude Pro 账号" }
        if let k = info?["apiKeySource"] as? String, k != "none" { return "API Key（\(k)）" }
        return a.isEmpty ? "未知" : "Claude 账号"
    }

    var body: some View {
        let home = NSHomeDirectory()
        let i = info
        let cwd = (i?["cwd"] as? String) ?? session?.cwd ?? app.lastFolder
        VStack(alignment: .leading, spacing: 14) {
            GroupBox2(title: "会话") {
                KVRow(k: "版本", v: (i?["claude_code_version"] as? String) ?? (probe.loading ? "读取中…" : "—"))
                KVRow(k: "会话名称", v: session.map { app.title(for: $0.sessionId, fallback: $0.title) } ?? "—")
                KVRow(k: "会话 ID", v: session?.sessionId ?? "还没开始（发出第一条消息后生成）")
                KVRow(k: "会话类型", v: "窗口客户端（后台非交互模式）")
                KVRow(k: "工作文件夹", v: cwd.replacingOccurrences(of: home, with: "~"))
                if let dirs = i?["additional_directories"] as? [String], !dirs.isEmpty {
                    KVRow(k: "额外文件夹", v: dirs.map { $0.replacingOccurrences(of: home, with: "~") }.joined(separator: "、"))
                }
            }
            GroupBox2(title: "账号与网络") {
                KVRow(k: "登录方式", v: loginMethod)
                KVRow(k: "组织", v: account["organizationName"] as? String ?? "—")
                KVRow(k: "邮箱", v: account["emailAddress"] as? String ?? "—")
                KVRow(k: "启动方式", v: LoginEnv.claudePath.contains("/.fcf/") ? "FCF 中转（~/.fcf/bin/claude）" : LoginEnv.claudePath)
                KVRow(k: "代理", v: probe.proxy ?? (probe.loading ? "读取中…" : "未检测到"))
            }
            GroupBox2(title: "运行") {
                KVRow(k: "模型", v: model(i))
                mcpRow(i)
                KVRow(k: "配置来源", v: sources(cwd))
                KVRow(k: "权限模式", v: session?.mode.label ?? (i?["permissionMode"] as? String).flatMap { PermissionMode(rawValue: $0)?.label } ?? "—")
                KVRow(k: "输出风格", v: (i?["output_style"] as? String).map { $0 == "default" ? "默认" : $0 } ?? "—")
                KVRow(k: "快速模式", v: (i?["fast_mode_state"] as? String) == "on" ? "开" : "关")
            }
            if let e = probe.error { Text(e).font(T.small).foregroundStyle(T.err) }
        }
    }

    func model(_ i: [String: Any]?) -> String {
        guard let m = (session?.activeModel.isEmpty == false ? session?.activeModel : nil) ?? i?["model"] as? String else { return probe.loading ? "读取中…" : "—" }
        let setting = SettingsFile(url: ConfigScope.user.url(project: "")).value(["model"]) as? String
        return (setting.map { "\($0)（\(m)）" } ?? m)
    }

    @ViewBuilder func mcpRow(_ i: [String: Any]?) -> some View {
        let list = (i?["mcp_servers"] as? [[String: Any]]) ?? []
        if list.isEmpty {
            KVRow(k: "MCP 服务器", v: probe.loading ? "读取中…" : "没有")
        } else {
            let st = list.map { $0["status"] as? String ?? "" }
            let ok = st.filter { $0 == "connected" }.count, auth = st.filter { $0 == "needs-auth" }.count
            let pending = st.filter { $0 == "pending" }.count, failed = st.count - ok - auth - pending
            let summary = ["\(ok) 个已连接", auth > 0 ? "\(auth) 个需要授权" : nil, pending > 0 ? "\(pending) 个连接中" : nil, failed > 0 ? "\(failed) 个失败" : nil]
                .compactMap { $0 }.joined(separator: "，")
            VStack(alignment: .leading, spacing: 2) {
                KVRow(k: "MCP 服务器", v: summary, tint: auth > 0 || failed > 0 ? T.run : T.ink)
                ForEach(Array(list.enumerated()), id: \.offset) { _, m in
                    let s = m["status"] as? String ?? ""
                    HStack(spacing: 6) {
                        Image(systemName: s == "connected" ? "checkmark.circle.fill" : s == "needs-auth" ? "key.fill" : s == "pending" ? "clock" : "xmark.circle.fill")
                            .font(.system(size: 11)).foregroundStyle(s == "connected" ? T.ok : s == "pending" ? T.muted : T.run)
                        Text(m["name"] as? String ?? "").font(.system(size: 12)).foregroundStyle(T.ink)
                        Text(s == "connected" ? "已连接" : s == "needs-auth" ? "需要授权" : s == "pending" ? "连接中" : "失败")
                            .font(.system(size: 11)).foregroundStyle(T.muted)
                    }
                    .padding(.leading, 136)
                }
            }
        }
    }

    func sources(_ cwd: String) -> String {
        var s: [String] = []
        if FileManager.default.fileExists(atPath: ConfigScope.user.url(project: cwd).path) { s.append("用户配置") }
        if FileManager.default.fileExists(atPath: ConfigScope.project.url(project: cwd).path) { s.append("项目共享配置") }
        if FileManager.default.fileExists(atPath: ConfigScope.local.url(project: cwd).path) { s.append("项目本地配置") }
        return s.isEmpty ? "无" : s.joined(separator: "、")
    }
}

// MARK: 用量（/usage 的真实结果）

struct UsageTabView: View {
    @ObservedObject var probe: StatusProbe

    struct Meter: Identifiable { let id = UUID(); let label: String; let pct: Int; let reset: String }

    var parsed: (meters: [Meter], rest: String) {
        guard let t = probe.usageText else { return ([], "") }
        var meters: [Meter] = [], rest: [String] = []
        let re = try! NSRegularExpression(pattern: #"^(.+?):\s*(\d+)% used(?:\s*·\s*resets\s*(.+))?$"#)
        for line in t.components(separatedBy: "\n") {
            let ns = line as NSString
            if let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let label = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let pct = Int(ns.substring(with: m.range(at: 2))) ?? 0
                let reset = m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)) : ""
                meters.append(Meter(label: zh(label), pct: pct, reset: reset))
            } else if meters.isEmpty && !line.isEmpty {
                continue   // 第一行「正在用订阅」之类的说明
            } else {
                rest.append(line)
            }
        }
        return (meters, rest.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func zh(_ s: String) -> String {
        switch s {
        case "Current session": return "当前 5 小时窗口"
        case "Current week (all models)": return "本周（全部模型）"
        default:
            if s.hasPrefix("Current week (") { return "本周（" + s.dropFirst(14).dropLast() + "）" }
            return s
        }
    }

    var body: some View {
        let p = parsed
        VStack(alignment: .leading, spacing: 14) {
            if probe.usageText == nil {
                HStack { ProgressView().controlSize(.small); Text(probe.loading ? "正在读取用量…" : (probe.error ?? "没有数据")).foregroundStyle(T.muted) }
            }
            if !p.meters.isEmpty {
                GroupBox2(title: "额度") {
                    ForEach(p.meters) { m in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(m.label).font(.system(size: 13)).foregroundStyle(T.ink)
                                Spacer()
                                Text("已用 \(m.pct)%").font(.system(size: 13, weight: .medium)).foregroundStyle(m.pct >= 80 ? T.err : T.ink)
                            }
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(T.line)
                                    Capsule().fill(m.pct >= 80 ? T.err : T.accent).frame(width: max(4, g.size.width * CGFloat(min(m.pct, 100)) / 100))
                                }
                            }
                            .frame(height: 6)
                            if !m.reset.isEmpty { Text("重置时间：" + m.reset).font(.system(size: 11)).foregroundStyle(T.muted) }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            if !p.rest.isEmpty {
                GroupBox2(title: "用量构成（Claude Code 原文）") {
                    Text(p.rest).font(.system(size: 12, design: .monospaced)).foregroundStyle(T.ink).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: 统计

struct StatsTabView: View {
    enum Range: String, CaseIterable, Identifiable { case all = "全部", d7 = "最近 7 天", d30 = "最近 30 天"; var id: String { rawValue } }
    @State private var range: Range = .all
    @State private var view = ProcessInfo.processInfo.environment["DUIHUATAI_STATS_VIEW"] == "models" ? 1 : 0
    @State private var stats = StatsCache.load()

    var body: some View {
        if let s = stats {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Picker("", selection: $view) { Text("总览").tag(0); Text("模型").tag(1) }.pickerStyle(.segmented).labelsHidden().frame(width: 160)
                    Spacer()
                    Picker("", selection: $range) { ForEach(Range.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 280)
                }
                if view == 0 { overview(s) } else { models(s) }
                Text("数据来自 Claude Code 自己的统计缓存（和终端 /stats 同一份），统计到 \(s.computedDate)。")
                    .font(.system(size: 11)).foregroundStyle(T.muted)
            }
        } else {
            Text("还没有统计数据：Claude Code 用过一段时间后会生成。").foregroundStyle(T.muted)
        }
    }

    var cutoff: Date? {
        let cal = Calendar.current, today = cal.startOfDay(for: Date())
        switch range {
        case .all: return nil
        case .d7: return cal.date(byAdding: .day, value: -6, to: today)
        case .d30: return cal.date(byAdding: .day, value: -29, to: today)
        }
    }

    func inRange(_ d: Date) -> Bool { cutoff.map { d >= $0 } ?? true }

    // MARK: 总览

    @ViewBuilder func overview(_ s: StatsCache) -> some View {
        let days = s.days.filter { inRange($0.date) }
        let tok = s.dailyModelTokens.filter { inRange($0.date) }
        var byModel: [String: Int] = [:]
        let _ = tok.forEach { for (m, n) in $0.byModel { byModel[m, default: 0] += n } }
        let fav = byModel.max { $0.value < $1.value }?.key
        let allTotal = s.modelUsage.values.reduce(0) { $0 + $1.total }
        let total = range == .all ? allTotal : byModel.values.reduce(0, +)
        let cal = Calendar.current
        let startDay = cutoff ?? cal.startOfDay(for: s.firstSession ?? days.first?.date ?? Date())
        let span = max(1, (cal.dateComponents([.day], from: startDay, to: cal.startOfDay(for: Date())).day ?? 0) + 1)
        let busiest = days.max { $0.messages < $1.messages }
        let streaks = Self.streaks(s.days.map(\.date))

        Heatmap(days: s.days)
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 12) {
            Metric(label: "最常用模型", value: fav.map(Fmt.model) ?? "—")
            Metric(label: "总 tokens", value: Fmt.tokens(total))
            Metric(label: "会话数", value: "\(range == .all ? s.totalSessions : days.reduce(0) { $0 + $1.sessions })")
            Metric(label: "活跃天数", value: "\(days.count) / \(span)")
            Metric(label: "最活跃的一天", value: busiest.map { Fmt.md.string(from: $0.date) + "（\($0.messages) 条消息）" } ?? "—")
            Metric(label: "最长会话", value: Fmt.duration(ms: s.longestSessionMs))
            Metric(label: "最长连续使用", value: "\(streaks.longest) 天")
            Metric(label: "当前连续使用", value: "\(streaks.current) 天")
        }
        if range == .all {
            let t = s.modelUsage.values
            Text("输入 \(Fmt.tokens(t.reduce(0) { $0 + $1.input }))，输出 \(Fmt.tokens(t.reduce(0) { $0 + $1.output }))，缓存读取 \(Fmt.tokens(t.reduce(0) { $0 + $1.cacheRead }))，缓存写入 \(Fmt.tokens(t.reduce(0) { $0 + $1.cacheWrite }))")
                .font(.system(size: 12)).foregroundStyle(T.muted)
        }
    }

    static func streaks(_ dates: [Date]) -> (longest: Int, current: Int) {
        let cal = Calendar.current
        let set = Set(dates.map { cal.startOfDay(for: $0) })
        var longest = 0
        for d in set where !set.contains(cal.date(byAdding: .day, value: -1, to: d)!) {
            var n = 1, x = d
            while let next = cal.date(byAdding: .day, value: 1, to: x), set.contains(next) { n += 1; x = next }
            longest = max(longest, n)
        }
        var current = 0, x = cal.startOfDay(for: Date())
        if !set.contains(x) { x = cal.date(byAdding: .day, value: -1, to: x)! }
        while set.contains(x) { current += 1; x = cal.date(byAdding: .day, value: -1, to: x)! }
        return (longest, current)
    }

    // MARK: 模型

    struct Point: Identifiable { let id = UUID(); let date: Date; let model: String; let tokens: Int }

    @ViewBuilder func models(_ s: StatsCache) -> some View {
        let rows = s.dailyModelTokens.filter { inRange($0.date) }
        let modelsSeen = Array(Set(rows.flatMap { $0.byModel.keys })).sorted { a, b in
            rows.reduce(0) { $0 + ($1.byModel[a] ?? 0) } > rows.reduce(0) { $0 + ($1.byModel[b] ?? 0) }
        }
        // 区间内每一天、每个模型都有点：没用的天记 0，线不会把空档连成「一直在用」
        let cal = Calendar.current
        let byDay = Dictionary(rows.map { (cal.startOfDay(for: $0.date), $0.byModel) }, uniquingKeysWith: { a, _ in a })
        let first = cutoff ?? rows.map(\.date).min().map { cal.startOfDay(for: $0) } ?? cal.startOfDay(for: Date())
        let dayCount = max(1, (cal.dateComponents([.day], from: first, to: cal.startOfDay(for: Date())).day ?? 0) + 1)
        let allDays = (0..<dayCount).compactMap { cal.date(byAdding: .day, value: $0, to: first) }
        let points = allDays.flatMap { d in modelsSeen.map { Point(date: d, model: $0, tokens: byDay[d]?[$0] ?? 0) } }
        TokenChart(points: points, models: modelsSeen)
        let sums = modelsSeen.map { m in (m, rows.reduce(0) { $0 + ($1.byModel[m] ?? 0) }) }
        let all = max(1, sums.reduce(0) { $0 + $1.1 })
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)], alignment: .leading, spacing: 12) {
            ForEach(sums, id: \.0) { m, n in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(SeriesColor.color(for: m)).frame(width: 8, height: 8)
                        Text(Fmt.model(m)).font(.system(size: 14, weight: .semibold)).foregroundStyle(T.ink)
                        Text(String(format: "%.1f%%", Double(n) * 100 / Double(all))).font(.system(size: 12)).foregroundStyle(T.muted)
                    }
                    Text("这段时间 \(Fmt.tokens(n)) tokens").font(.system(size: 12)).foregroundStyle(T.ink)
                    if range == .all, let u = s.modelUsage[m] {
                        Text("输入 \(Fmt.tokens(u.input))，输出 \(Fmt.tokens(u.output))").font(.system(size: 12)).foregroundStyle(T.muted)
                        Text("缓存读取 \(Fmt.tokens(u.cacheRead))，写入 \(Fmt.tokens(u.cacheWrite))").font(.system(size: 12)).foregroundStyle(T.muted)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(T.sunk))
            }
        }
    }
}

struct Metric: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 12)).foregroundStyle(T.muted)
            Text(value).font(.system(size: 16, weight: .semibold)).foregroundStyle(T.ink)
        }
    }
}

/// 活动热力图：近一年，每列一周；颜色只用强调色一个色相由浅到深
struct Heatmap: View {
    let days: [StatsCache.Day]

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let byDay = Dictionary(days.map { (cal.startOfDay(for: $0.date), $0) }, uniquingKeysWith: { a, _ in a })
        let counts = days.map(\.messages).filter { $0 > 0 }.sorted()
        let thresholds = [0.25, 0.5, 0.75].map { p in counts.isEmpty ? 1 : counts[min(counts.count - 1, Int(Double(counts.count) * p))] }
        // 从 52 周前的周一开始
        let weekday = (cal.component(.weekday, from: today) + 5) % 7     // 周一 = 0
        let start = cal.date(byAdding: .day, value: -(weekday + 52 * 7), to: today)!
        let cell: CGFloat = 11, gap: CGFloat = 2.5

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .trailing, spacing: gap) {
                    ForEach(0..<7, id: \.self) { r in
                        Text(r == 0 ? "一" : r == 2 ? "三" : r == 4 ? "五" : "").font(.system(size: 9)).foregroundStyle(T.muted).frame(height: cell)
                    }
                }
                .padding(.top, 16)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: gap) {
                        ForEach(0..<53, id: \.self) { w in
                            let d = cal.date(byAdding: .day, value: w * 7, to: start)!
                            let first = cal.component(.day, from: d) <= 7
                            // 月份标签悬浮在格子上方，不占宽度，不会被挤成两行
                            Color.clear.frame(width: cell, height: 12).overlay(alignment: .leading) {
                                if first { Text("\(cal.component(.month, from: d))月").font(.system(size: 9)).foregroundStyle(T.muted).fixedSize() }
                            }
                        }
                    }
                    .frame(height: 12)
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(0..<53, id: \.self) { w in
                            VStack(spacing: gap) {
                                ForEach(0..<7, id: \.self) { r in
                                    let d = cal.date(byAdding: .day, value: w * 7 + r, to: start)!
                                    let n = byDay[d]?.messages ?? 0
                                    let lvl = n == 0 ? 0 : n <= thresholds[0] ? 1 : n <= thresholds[1] ? 2 : n <= thresholds[2] ? 3 : 4
                                    RoundedRectangle(cornerRadius: 2.5)
                                        .fill(d > today ? Color.clear : lvl == 0 ? T.line.opacity(0.6) : T.accent.opacity([0, 0.3, 0.52, 0.76, 1][lvl]))
                                        .frame(width: cell, height: cell)
                                        .help(d > today ? "" : Fmt.md.string(from: d) + (n == 0 ? "：没有使用" : "：\(n) 条消息，\(byDay[d]?.sessions ?? 0) 个会话"))
                                }
                            }
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Text("少").font(.system(size: 10)).foregroundStyle(T.muted)
                ForEach(0..<5, id: \.self) { l in
                    RoundedRectangle(cornerRadius: 2.5).fill(l == 0 ? T.line.opacity(0.6) : T.accent.opacity([0, 0.3, 0.52, 0.76, 1][l])).frame(width: cell, height: cell)
                }
                Text("多").font(.system(size: 10)).foregroundStyle(T.muted)
            }
            .padding(.leading, 20)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(T.sunk))
    }
}

/// 每天 tokens 折线：一条线一个模型，悬停显示当天各模型数值
struct TokenChart: View {
    let points: [StatsTabView.Point]
    let models: [String]
    @State private var hoverDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("每天 tokens").font(.system(size: 13, weight: .semibold)).foregroundStyle(T.ink)
            Chart {
                ForEach(points) { p in
                    LineMark(x: .value("日期", p.date, unit: .day), y: .value("tokens", p.tokens))
                        .foregroundStyle(by: .value("模型", Fmt.model(p.model)))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.linear)
                }
                if let h = hoverDate {
                    RuleMark(x: .value("日期", h, unit: .day)).foregroundStyle(T.muted.opacity(0.4))
                    ForEach(points.filter { Calendar.current.isDate($0.date, inSameDayAs: h) }) { p in
                        PointMark(x: .value("日期", p.date, unit: .day), y: .value("tokens", p.tokens))
                            .foregroundStyle(SeriesColor.color(for: p.model)).symbolSize(50)
                    }
                }
            }
            .chartForegroundStyleScale(domain: models.map(Fmt.model), range: models.map { SeriesColor.color(for: $0) })
            .chartYAxis { AxisMarks { v in
                AxisGridLine().foregroundStyle(T.line.opacity(0.6))
                AxisValueLabel { if let n = v.as(Int.self) { Text(Fmt.tokens(n)).font(.system(size: 10)).foregroundStyle(T.muted) } }
            } }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { v in
                AxisValueLabel { if let d = v.as(Date.self) { Text(Fmt.md.string(from: d)).font(.system(size: 10)).foregroundStyle(T.muted) } }
            } }
            .chartLegend(position: .bottom, alignment: .leading)
            .chartOverlay { proxy in
                GeometryReader { g in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let loc):
                                let x = loc.x - g[proxy.plotAreaFrame].origin.x
                                hoverDate = proxy.value(atX: x, as: Date.self)
                            case .ended: hoverDate = nil
                            }
                        }
                }
            }
            .frame(height: 220)
            // 悬停时的数值读数（文字用正文色，不用系列色）
            Group {
                if let h = hoverDate {
                    let day = points.filter { Calendar.current.isDate($0.date, inSameDayAs: h) }
                    Text(Fmt.md.string(from: h) + "：" + (day.isEmpty ? "没有数据" : day.map { "\(Fmt.model($0.model)) \(Fmt.tokens($0.tokens))" }.joined(separator: "，")))
                } else {
                    Text("把鼠标移到图上看当天的数值")
                }
            }
            .font(.system(size: 12)).foregroundStyle(T.muted)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(T.sunk))
    }
}
