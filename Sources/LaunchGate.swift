import SwiftUI
import AppKit

// 启动检查：确认 Claude 走公司 FCF 中转；没就绪就在内置终端里跑 fcf，FCF 有新版本时由你决定升不升
final class LaunchGate: ObservableObject {
    enum State { case pending, running, ok, fail, warn }
    struct Check: Identifiable { let id: String; let title: String; var state: State = .pending; var detail = "" }
    enum Phase: Equatable { case checking, needsSetup, update(current: String, latest: String), ready, passed }

    @Published var phase: Phase = .checking
    @Published var checks: [Check] = []
    @Published var running = false
    @Published var lastExit: Int32?
    @Published var showTerminal = false
    let term = TerminalBuffer()
    private var pty: PtyProcess?
    private var declinedUpdate = false
    private var generation = 0          // 每轮检查一个编号，旧一轮的结果直接丢弃
    private var reloadEnvNext = false

    static let launcher = NSString(string: "~/.fcf/bin/claude").expandingTildeInPath

    init() { runChecks() }

    private func set(_ id: String, _ state: State, _ detail: String = "", gen: Int) {
        DispatchQueue.main.async {
            guard gen == self.generation, let i = self.checks.firstIndex(where: { $0.id == id }) else { return }
            self.checks[i].state = state
            self.checks[i].detail = detail
        }
    }

    func runChecks() {
        guard !running else { return }
        generation += 1
        let gen = generation
        let reload = reloadEnvNext
        reloadEnvNext = false
        phase = .checking
        checks = [
            Check(id: "fcf", title: "找到 fcf 命令"),
            Check(id: "login", title: "已登录 FCF"),
            Check(id: "launcher", title: "Claude 由 FCF 中转启动"),
            Check(id: "run", title: "启动器可以正常运行"),
            Check(id: "update", title: "检查 FCF 新版本"),
        ]
        DispatchQueue.global(qos: .userInitiated).async {
            if reload { LoginEnv.reload() }   // FCF / Node 可能刚升级，PATH 要重读（放后台，不卡界面）
            self.performChecks(gen)
        }
    }

    private func performChecks(_ gen: Int) {
        var blocking = false
        var upgrading = false
        func set(_ id: String, _ state: State, _ detail: String = "") { self.set(id, state, detail, gen: gen) }

        set("fcf", .running)
        let which = Shell.run("/bin/zsh", ["-lc", "command -v fcf"])
        if which.code == 0 { set("fcf", .ok, which.output.replacingOccurrences(of: NSHomeDirectory(), with: "~")) }
        else { set("fcf", .fail, "没有找到，需要先安装 FCF"); blocking = true }

        set("login", .running)
        let cfgURL = URL(fileURLWithPath: NSString(string: "~/.fcf/config.json").expandingTildeInPath)
        if let d = try? Data(contentsOf: cfgURL), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let u = j["ssoUser"] as? [String: Any], let name = u["username"] as? String {
            set("login", .ok, name)
        } else {
            set("login", .fail, "还没登录，运行 fcf 选择登录"); blocking = true
        }

        set("launcher", .running)
        let script = (try? String(contentsOfFile: Self.launcher, encoding: .utf8)) ?? ""
        let managed = script.contains("FCF-MANAGED-LAUNCHER")
        let usingIt = LoginEnv.claudePath == Self.launcher
        if managed && usingIt { set("launcher", .ok, "~/.fcf/bin/claude") }
        else if !managed { set("launcher", .fail, "没有 FCF 启动器，运行 fcf 配置 Claude Code"); blocking = true }
        else { set("launcher", .fail, "设置里指定了别的启动程序：" + LoginEnv.claudePath); blocking = true }

        if !blocking {
            set("run", .running)
            let v = Shell.run(LoginEnv.claudePath, ["--version"], timeout: 15)
            if v.code == 0, v.output.contains("Claude Code") {
                set("run", .ok, v.output.split(separator: "\n").last.map(String.init) ?? "")
            } else if v.output.contains("正在自动升级") || v.output.contains("等待升级完成")
                        || v.output.contains("ENOEXEC") || v.output.contains("system error -88") || Self.claudeUpdating() {
                // Claude Code 正在升级（FCF 或终端里的自动更新在下载新版本，文件还没写完）：不算失败，过一会儿自动再查
                set("run", .warn, "Claude Code 正在升级，下载完会自动进入（20 秒后重新检查）")
                blocking = true
                upgrading = true
            } else {
                set("run", .fail, "运行失败：" + String(v.output.suffix(120))); blocking = true
            }
        } else {
            set("run", .warn, "先完成上面几项")
        }

        set("update", .running)
        let u = Shell.run("/bin/zsh", ["-lc", "fcf update --check"], timeout: 8)
        let cur = Self.field(u.output, "当前版本"), latest = Self.field(u.output, "最新版本")
        var update: (String, String)?
        if let cur, let latest {
            if Self.newer(latest, than: cur) { update = (cur, latest); set("update", .warn, "\(cur) → \(latest)") }
            else { set("update", .ok, "已是最新 \(cur)") }
        } else {
            set("update", .warn, "这次没检查成功，不影响使用")
        }

        // 仅用于截图验证界面：启动时带 DUIHUATAI_GATE_DEMO=setup / update
        let demo = ProcessInfo.processInfo.environment["DUIHUATAI_GATE_DEMO"]
        if demo == "setup" { blocking = true; set("login", .fail, "还没登录，运行 fcf 选择登录") }
        if demo == "update" { update = ("1.5.12", "1.6.0"); set("update", .warn, "1.5.12 → 1.6.0") }
        DispatchQueue.main.async {
            guard gen == self.generation, !self.running else { return }
            if upgrading {
                self.phase = .needsSetup
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                    guard let self, gen == self.generation, !self.running, self.phase == .needsSetup else { return }
                    self.runChecks()
                }
                return
            }
            if blocking {
                self.phase = .needsSetup
                self.showTerminal = true
            } else if let update, !self.declinedUpdate {
                self.phase = .update(current: update.0, latest: update.1)
            } else {
                self.phase = .ready
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { if self.phase == .ready { self.phase = .passed } }
            }
        }
    }

    /// 有没有 npm 正在安装 claude-code（自动更新进行中）
    static func claudeUpdating() -> Bool {
        let r = Shell.run("/bin/ps", ["-axo", "command="])
        return r.output.split(separator: "\n").contains { $0.contains("npm install") && $0.contains("@anthropic-ai/claude-code") }
    }

    static func field(_ text: String, _ key: String) -> String? {
        guard let r = text.range(of: key) else { return nil }
        let rest = text[r.upperBound...].drop { !$0.isNumber }
        let v = rest.prefix { $0.isNumber || $0 == "." || $0 == "-" || $0.isLetter }
        return v.isEmpty ? nil : String(v)
    }

    static func newer(_ a: String, than b: String) -> Bool {
        let pa = a.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        let pb = b.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: 内置终端

    func run(_ command: String, cols: Int) {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty, !running else { return }
        showTerminal = true
        term.cols = cols
        term.feed(Data("\u{1B}[1m$ \(cmd)\u{1B}[0m\r\n".utf8))
        let p = PtyProcess()
        p.onOutput = { [weak self] d in self?.term.feed(d) }
        p.onExit = { [weak self] code in
            guard let self else { return }
            self.running = false
            self.lastExit = code
            self.term.feed(Data("\r\n\u{1B}[90m[命令结束，退出码 \(code)] 正在重新检查…\u{1B}[0m\r\n\r\n".utf8))
            self.pty = nil
            self.reloadEnvNext = true
            self.runChecks()
        }
        do {
            try p.start(command: cmd, cwd: NSHomeDirectory(), cols: cols, rows: 24)
            pty = p
            running = true
            lastExit = nil
        } catch {
            term.feed(Data("启动失败：\(error.localizedDescription)\r\n".utf8))
        }
    }

    func send(_ s: String) { pty?.write(s) }
    func resize(cols: Int) { term.cols = cols; pty?.resize(cols: cols, rows: 24) }
    func stop() { pty?.write("\u{03}"); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in if self?.running == true { self?.pty?.terminate() } } }

    func upgrade(cols: Int) { run("fcf update", cols: cols) }
    func skipUpdate() { guard !running else { return }; declinedUpdate = true; phase = .passed }
    func copyOutput() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(term.plainText, forType: .string)
    }
    func enterNow() { phase = .passed }
}

// MARK: 界面

struct LaunchGateView: View {
    @ObservedObject var gate: LaunchGate
    @State private var command = ""
    @State private var cols = 96
    @FocusState private var inputFocused: Bool

    var body: some View {
        ScrollViewReader { page in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("启动检查").font(.system(size: 24, weight: .semibold)).foregroundStyle(T.ink)
                    Text("确认 Claude 通过公司 FCF 中转运行，通过后进入对话界面。").font(.system(size: 13)).foregroundStyle(T.muted)
                }
                checklist
                switch gate.phase {
                case .update(let cur, let latest): updateCard(cur, latest)
                case .needsSetup: setupHint
                case .ready: Label("全部就绪，正在进入…", systemImage: "checkmark.seal.fill").foregroundStyle(T.ok).font(.system(size: 14, weight: .medium))
                default: EmptyView()
                }
                if gate.phase != .checking && gate.phase != .ready && !gate.running {
                    Button("重新检查") { gate.runChecks() }.buttonStyle(.link).font(.system(size: 13))
                }
                if gate.showTerminal { terminal.id("terminal") }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 32).padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(T.canvas)
        .onChange(of: gate.phase) {
            if gate.phase == .needsSetup {
                inputFocused = true
                withAnimation { page.scrollTo("terminal", anchor: .bottom) }
            }
        }
        // 开始跑命令时把终端滚进视野
        .onChange(of: gate.running) { if gate.running { withAnimation { page.scrollTo("terminal", anchor: .bottom) } } }
        }
    }

    var checklist: some View {
        VStack(spacing: 0) {
            ForEach(Array(gate.checks.enumerated()), id: \.element.id) { i, c in
                HStack(spacing: 10) {
                    Group {
                        switch c.state {
                        case .pending: Image(systemName: "circle").foregroundStyle(T.line)
                        case .running: ProgressView().controlSize(.small)
                        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(T.ok)
                        case .fail: Image(systemName: "xmark.circle.fill").foregroundStyle(T.err)
                        case .warn: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(T.run)
                        }
                    }
                    .font(.system(size: 15)).frame(width: 20, height: 20)
                    Text(c.title).font(.system(size: 13.5)).foregroundStyle(T.ink)
                    Spacer()
                    Text(c.detail).font(.system(size: 12)).foregroundStyle(c.state == .fail ? T.err : T.muted)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                if i < gate.checks.count - 1 { Divider().padding(.leading, 44) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(T.paper))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(T.line, lineWidth: 1))
    }

    func updateCard(_ cur: String, _ latest: String) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "arrow.up.circle.fill").font(.system(size: 26)).foregroundStyle(T.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("FCF 有新版本 \(cur) → \(latest)").font(.system(size: 14, weight: .semibold)).foregroundStyle(T.ink)
                Text("升级会在下面的终端里运行 fcf update，过程中需要确认的地方由你来按。").font(.system(size: 12)).foregroundStyle(T.muted)
            }
            Spacer()
            Button("这次不升级") { gate.skipUpdate() }.buttonStyle(.plain).foregroundStyle(T.muted).font(.system(size: 13))
                .disabled(gate.running)
            Button("升级") { gate.upgrade(cols: cols) }.buttonStyle(PrimaryButton()).disabled(gate.running)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(T.paper))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(T.accent.opacity(0.5), lineWidth: 1))
    }

    var setupHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("还没通过 FCF 中转").font(.system(size: 14, weight: .semibold)).foregroundStyle(T.ink)
            Text("在下面输入 fcf 回车，按菜单完成登录和 Claude Code 配置。命令结束后会自动重新检查，全部通过就进入对话界面。")
                .font(.system(size: 12.5)).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    var terminal: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(gate.running ? T.run : Color(white: 0.4)).frame(width: 7, height: 7)
                Text(gate.running ? "运行中，直接在终端里按键操作" : "终端").font(.system(size: 12)).foregroundStyle(Color(white: 0.7))
                Spacer()
                Button("复制输出") { gate.copyOutput() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color(white: 0.7))
                    .help("⌘C 也可以")
                if gate.running {
                    Button("停止") { gate.stop() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color(white: 0.8))
                        .help("相当于 Ctrl+C")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(white: 0.13))

            if !gate.running {
                HStack(spacing: 8) {
                    Text("$").font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(Color(red: 0.45, green: 0.80, blue: 0.50))
                    TextField("", text: $command, prompt: Text("输入 fcf 后回车").foregroundColor(Color(white: 0.58)))
                        .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced)).foregroundStyle(Color(white: 0.92))
                        .focused($inputFocused)
                        .onSubmit(submit)
                    Button("运行", action: submit).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color(white: 0.8))
                        .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color(white: 0.11))
            }

            if gate.term.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !gate.running {
                Text("命令的输出会显示在这里。运行中可以直接按方向键、回车、y / n 操作菜单。")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Color(white: 0.45))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            } else {
                TerminalScreen(buf: gate.term, active: gate.running, onKey: gate.send, onCopy: gate.copyOutput)
                    .frame(height: 320)
            }
        }
        .background(GeometryReader { g in
            Color.clear.onAppear { updateCols(g.size.width) }.onChange(of: g.size.width) { updateCols(g.size.width) }
        })
        .background(Color(white: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.black.opacity(0.25), lineWidth: 1))
    }

    func submit() {
        let c = command
        command = ""
        gate.run(c, cols: cols)
    }

    func updateCols(_ w: CGFloat) {
        let charW = ("M" as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)]).width
        let c = max(40, Int((w - 24) / charW))
        if c != cols { cols = c; gate.resize(cols: c) }
    }
}

/// 终端画面 + 键盘输入（运行中时按键直接发给程序）
struct TerminalScreen: View {
    @ObservedObject var buf: TerminalBuffer
    let active: Bool
    let onKey: (String) -> Void
    var onCopy: () -> Void = {}

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(0..<buf.lines.count, id: \.self) { r in
                        Text(buf.attributed(r, showCursor: active && r == buf.row))
                            .font(.system(size: 12.5, design: .monospaced))
                            .frame(maxWidth: .infinity, minHeight: 15, alignment: .leading)
                            .id(r)
                    }
                }
                .textSelection(.enabled)
                .padding(12)
            }
            .onChange(of: buf.version) { proxy.scrollTo(buf.lines.count - 1, anchor: .bottom) }
        }
        .background(KeyCatcher(active: active, onKey: onKey, onCopy: onCopy))
    }
}

struct KeyCatcher: NSViewRepresentable {
    let active: Bool
    let onKey: (String) -> Void
    var onCopy: () -> Void = {}

    final class V: NSView {
        var onKey: ((String) -> Void)?
        var onCopy: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with e: NSEvent) {
            let map: [UInt16: String] = [36: "\r", 76: "\r", 51: "\u{7F}", 117: "\u{1B}[3~", 48: "\t", 53: "\u{1B}",
                                         126: "\u{1B}[A", 125: "\u{1B}[B", 124: "\u{1B}[C", 123: "\u{1B}[D"]
            if e.modifierFlags.contains(.command) {
                if e.charactersIgnoringModifiers == "v", let s = NSPasteboard.general.string(forType: .string) { onKey?(s); return }
                if e.charactersIgnoringModifiers == "c" { onCopy?(); return }
                super.keyDown(with: e)   // 其他 ⌘ 快捷键交还给菜单
                return
            }
            if let s = map[e.keyCode] { onKey?(s); return }
            if e.modifierFlags.contains(.control), let c = e.charactersIgnoringModifiers?.lowercased().unicodeScalars.first,
               c.value >= 97 && c.value <= 122 {
                onKey?(String(UnicodeScalar(UInt8(c.value - 96)))); return
            }
            if let s = e.characters, !s.isEmpty { onKey?(s) }
        }
    }

    func makeNSView(context: Context) -> V { V() }
    func updateNSView(_ v: V, context: Context) {
        v.onKey = onKey
        v.onCopy = onCopy
        if active { DispatchQueue.main.async { if v.window?.firstResponder !== v { v.window?.makeFirstResponder(v) } } }
    }
}
