import SwiftUI
import AppKit

/// 终端版才有、后台（非交互模式）不认识的斜杠命令，由客户端自己实现
enum LocalCommands {
    static let tag = "本地"

    static let all: [SlashCommand] = [
        SlashCommand(name: "status", description: "状态：版本、会话、账号、代理、模型、MCP、配置来源"),
        SlashCommand(name: "usage", description: "用量：5 小时 / 本周额度和用量构成"),
        SlashCommand(name: "stats", description: "统计：活跃热力图、常用模型、每天 tokens"),
        SlashCommand(name: "cost", description: "这个对话和今天的花费"),
        SlashCommand(name: "help", description: "快捷键和可用命令"),
        SlashCommand(name: "clear", description: "开一个新对话（同一个文件夹）"),
        SlashCommand(name: "resume", description: "找回以前的对话（跳到对话搜索）"),
        SlashCommand(name: "export", description: "把这个对话导出成 Markdown 文件"),
        SlashCommand(name: "add-dir", description: "让 Claude 也能访问另一个文件夹：/add-dir 路径"),
        SlashCommand(name: "permissions", description: "打开设置 → 权限"),
        SlashCommand(name: "hooks", description: "打开设置 → 钩子"),
        SlashCommand(name: "memory", description: "打开设置 → CLAUDE.md 与记忆"),
        SlashCommand(name: "plugin", description: "打开设置 → 插件"),
        SlashCommand(name: "theme", description: "打开设置 → 外观主题"),
        SlashCommand(name: "exit", description: "关闭这个对话"),
    ]

    /// 终端界面专用、在窗口版里没有意义的命令
    static let terminalOnly: Set<String> = ["login", "logout", "vim", "terminal-setup", "ide", "bug", "release-notes",
                                            "upgrade", "privacy-settings", "statusline", "bashes", "install-github-app", "keybindings"]

    static let settingsPages: [String: SettingsSection] = [
        "permissions": .permissions, "hooks": .hooks, "memory": .memory, "plugin": .plugins, "plugins": .plugins, "theme": .appearance,
    ]

    /// 处理成功返回 true（不再发给 Claude）
    static func handle(_ raw: String, session: ChatSession, app: AppState, openSettings: (SettingsSection) -> Void) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("/") else { return false }
        let parts = t.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
        guard let name = parts.first?.lowercased() else { return false }
        let args = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""

        if let page = settingsPages[name] { openSettings(page); return true }
        if terminalOnly.contains(name) {
            let extra = name == "login" || name == "logout" ? "账号由 FCF 管理：菜单栏「文件 → 重新进行启动检查（FCF）」里运行 fcf 处理。" : "这个命令只在终端版里有用，窗口版不需要。"
            session.addLocal("/\(name)", extra)
            return true
        }
        switch name {
        case "clear": app.newSession(cwd: session.cwd)
        case "exit": app.close(session)
        case "resume": app.searchFocusToken += 1
        case "status": app.statusPanel = .status
        case "usage": app.statusPanel = .usage
        case "stats": app.statusPanel = .stats
        case "cost": cost(session)
        case "help": help(session)
        case "export": export(session, app: app)
        case "add-dir":
            if args.isEmpty { session.addLocal("/add-dir", "用法：/add-dir 文件夹路径，例如 /add-dir ~/Desktop/素材") }
            else { session.addDirectory((args as NSString).expandingTildeInPath) }
        default: return false
        }
        return true
    }

    static func status(_ s: ChatSession) {
        let u = UsageStore.shared
        var account = "未登录"
        if let d = try? Data(contentsOf: URL(fileURLWithPath: NSString(string: "~/.fcf/config.json").expandingTildeInPath)),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let su = j["ssoUser"] as? [String: Any], let name = su["username"] as? String { account = name }
        let home = NSHomeDirectory()
        let item = s.addLocal("/status", "正在读取版本…")
        DispatchQueue.global().async {
            let v = Shell.run(LoginEnv.claudePath, ["--version"], timeout: 10)
            let path = LoginEnv.claudePath
            DispatchQueue.main.async {
                var rows: [(String, String)] = [
                    ("Claude Code 版本", v.code == 0 ? v.output : "读取失败"),
                    ("启动方式", path.contains("/.fcf/") ? "FCF 中转（\(path.replacingOccurrences(of: home, with: "~"))）" : path),
                    ("FCF 账号", account),
                    ("模型", s.activeModel.isEmpty ? "还没开始（默认模型）" : s.activeModel),
                    ("权限模式", s.mode.label),
                    ("工作文件夹", s.cwd.replacingOccurrences(of: home, with: "~")),
                ]
                if !s.extraDirs.isEmpty { rows.append(("额外文件夹", s.extraDirs.map { $0.replacingOccurrences(of: home, with: "~") }.joined(separator: "、"))) }
                rows.append(("会话 ID", s.sessionId ?? "还没开始"))
                rows.append(("上下文", s.contextTokens > 0 ? "\(s.contextTokens / 1000)k tokens" : "—"))
                rows.append(("本对话花费", String(format: "$%.2f", s.costUSD)))
                if let f = u.fiveHour { rows.append(("5 小时额度", "已用 \(Int((f * 100).rounded()))%")) }
                if let w = u.sevenDay { rows.append(("本周额度", "已用 \(Int((w * 100).rounded()))%")) }
                item.text = table(rows)
            }
        }
    }

    static func cost(_ s: ChatSession) {
        s.addLocal("/cost", table([
            ("本对话花费", String(format: "$%.2f", s.costUSD)),
            ("今日花费（全部对话）", String(format: "$%.2f", UsageStore.shared.todayCost)),
            ("当前上下文", s.contextTokens > 0 ? "\(s.contextTokens / 1000)k tokens" : "—"),
        ]))
    }

    static func help(_ s: ChatSession) {
        let local = all.map { "| `/\($0.name)` | \($0.description) |" }.joined(separator: "\n")
        s.addLocal("/help", """
        **快捷键**

        | 按键 | 作用 |
        |---|---|
        | 回车 / Shift+回车 | 发送 / 换行 |
        | ↑（输入框为空时） | 调出上一条消息 |
        | Esc / ⌘. | 停止当前回复 |
        | ⌘N / ⌘O | 新会话 / 在其他文件夹开新会话 |
        | ⌘F | 搜索对话 |
        | ⌘, | 设置 |
        | `!命令` | 在本地直接运行命令，输出作为下一条消息的上下文 |

        **窗口版自带的命令**

        | 命令 | 作用 |
        |---|---|
        \(local)

        其余命令（技能、/compact、/model、/context、/init 等）照常发给 Claude，输入 / 就能在菜单里看到。
        """)
    }

    static func export(_ s: ChatSession, app: AppState) {
        let panel = NSSavePanel()
        let title = app.title(for: s.sessionId, fallback: s.title)
        panel.nameFieldStringValue = title.replacingOccurrences(of: "/", with: "-").prefix(40) + ".md"
        panel.directoryURL = URL(fileURLWithPath: s.cwd)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var md = "# \(title)\n\n"
        for it in s.items {
            switch it.kind {
            case .user:
                md += "## 你\n\n\(it.text)\n"
                for f in it.files { md += "\n- 附件：`\(f.path)`" }
                md += "\n\n"
            case .assistant: md += "## Claude\n\n\(it.text)\n\n"
            case .tool: md += "- \(it.text)\n"
            case .artifacts: md += it.artifacts.map { "- 产物：`\($0.url.path)`\n" }.joined() + "\n"
            case .question, .permission: if let r = it.resolved { md += "- \(it.text.isEmpty ? "提问" : it.text)：\(r)\n" }
            default: break
            }
        }
        do {
            try md.write(to: url, atomically: true, encoding: .utf8)
            s.addLocal("/export", "已导出到 `\(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))`")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            s.addLocal("/export", "导出失败：\(error.localizedDescription)")
        }
    }

    static func table(_ rows: [(String, String)]) -> String {
        "| 项目 | 内容 |\n|---|---|\n" + rows.map { "| \($0.0) | \($0.1.replacingOccurrences(of: "|", with: "\\|")) |" }.joined(separator: "\n")
    }
}

/// 本地命令的结果卡片：明确标出「没有发给 Claude」
struct LocalCard: View {
    @ObservedObject var item: ChatItem
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(T.accent)
                Text(item.toolName).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(T.ink)
                Text("本地命令，没有发给 Claude").font(.system(size: 11)).foregroundStyle(T.muted)
            }
            MarkdownView(text: item.text).foregroundStyle(T.ink)
        }
        .padding(12)
        .frame(maxWidth: 640, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(T.sunk))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(T.line, lineWidth: 1))
    }
}
