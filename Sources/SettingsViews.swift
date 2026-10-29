import SwiftUI
import AppKit

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, thinking, appearance, permissions, env, plugins, mcp, skills, agents, commands, hooks, memory, raw, diagnose, about
    var id: String { rawValue }
    var label: String {
        switch self {
        case .general: return "通用"
        case .thinking: return "思维链"
        case .about: return "关于与更新"
        case .appearance: return "外观主题"
        case .permissions: return "权限"
        case .env: return "环境变量"
        case .plugins: return "插件"
        case .mcp: return "MCP 服务器"
        case .skills: return "技能"
        case .agents: return "子代理"
        case .commands: return "自定义指令"
        case .hooks: return "钩子"
        case .memory: return "CLAUDE.md 与记忆"
        case .raw: return "配置文件原文"
        case .diagnose: return "运行诊断"
        }
    }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .thinking: return "brain"
        case .about: return "info.circle"
        case .appearance: return "paintpalette"
        case .permissions: return "checkmark.shield"
        case .env: return "terminal"
        case .plugins: return "puzzlepiece.extension"
        case .mcp: return "server.rack"
        case .skills: return "sparkles"
        case .agents: return "person.2"
        case .commands: return "slash.circle"
        case .hooks: return "link"
        case .memory: return "book.closed"
        case .raw: return "curlybraces"
        case .diagnose: return "stethoscope"
        }
    }
}

struct SettingsRoot: View {
    @EnvironmentObject var app: AppState
    // 仅用于截图验证：DUIHUATAI_SETTINGS_DEMO=<页面名> 直接打开那一页
    // 记住当前页：换主题时设置窗口会重建，不能跳回第一页
    @AppStorage("settingsSection") private var sectionRaw = SettingsSection.general.rawValue
    private var section: SettingsSection {
        get { SettingsSection(rawValue: ProcessInfo.processInfo.environment["DUIHUATAI_SETTINGS_DEMO"] ?? sectionRaw) ?? .general }
    }

    var project: String { app.current?.cwd ?? app.lastFolder }

    var body: some View {
        // 设置窗口里不用 NavigationSplitView（会把侧栏挤歪、内容溢出），改成固定两栏
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsSection.allCases) { s in
                    SettingsNavRow(section: s, selected: s == section) { sectionRaw = s.rawValue }
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.top, 14)
            .frame(width: 200)
            .frame(maxHeight: .infinity)
            .background(T.canvas)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(section.label).font(.system(size: fs(18), weight: .semibold)).foregroundStyle(T.ink)
                    Text("当前项目：" + project.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(T.small).foregroundStyle(T.muted).lineLimit(1).truncationMode(.middle)
                }
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)

                Group {
                    switch section {
                    case .general: GeneralSettings(project: project)
                    case .thinking: ThinkingSettings(project: project)
                    case .about: AboutSettings()
                    case .appearance: ThemeSettings()
                    case .permissions: PermissionSettings(project: project)
                    case .env: EnvSettings(project: project)
                    case .plugins: PluginSettings()
                    case .mcp: MCPSettings(project: project)
                    case .skills: SkillList(project: project)
                    case .agents: MarkdownFolder(kind: .agents, project: project)
                    case .commands: MarkdownFolder(kind: .commands, project: project)
                    case .hooks: HookSettings(project: project)
                    case .memory: MemoryFiles(project: project)
                    case .raw: RawSettings(project: project)
                    case .diagnose: DiagnoseView()
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .id(section.rawValue + project)

                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(T.muted)
                    Text("改动对新开的对话生效；进行中的对话点右边重启后生效，记录会接上。")
                        .font(T.small).foregroundStyle(T.muted).lineLimit(2)
                    Spacer(minLength: 8)
                    Button("重启全部对话") { app.sessions.forEach { $0.restart() } }.fixedSize()
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(T.paper)
        }
        .frame(minWidth: 900, idealWidth: 1040, minHeight: 620, idealHeight: 720)
    }
}

struct SettingsNavRow: View {
    let section: SettingsSection
    let selected: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.icon).font(.system(size: fs(13))).frame(width: 18)
                    .foregroundStyle(selected ? T.onAccent : T.muted)
                Text(section.label).font(.system(size: fs(13))).foregroundStyle(selected ? T.onAccent : T.ink).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? T.accent : hover ? T.line.opacity(0.5) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// 顶部的层级切换：全局 / 项目 / 项目本地
struct ScopePicker: View {
    @Binding var scope: ConfigScope
    let project: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("写入位置", selection: $scope) {
                ForEach(ConfigScope.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).frame(maxWidth: 420)
            Text(scope.url(project: project).path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(T.small).foregroundStyle(T.muted).textSelection(.enabled)
        }
    }
}

// MARK: 通用

struct GeneralSettings: View {
    let project: String
    @State private var scope: ConfigScope = .user

    var body: some View {
        ScopedFile(scope: $scope, project: project) { f in
            Form {
                Section("模型") {
                    TextPicker(label: "默认模型", value: f.value(["model"]) as? String ?? "",
                               options: ["", "opus", "sonnet", "haiku", "opusplan"],
                               names: ["跟随默认", "Opus", "Sonnet", "Haiku", "计划用 Opus、执行用 Sonnet"]) { f.set(["model"], $0.isEmpty ? nil : $0) }
                    StringRow(label: "回复语言", hint: "例如：简体中文。留空跟随默认", key: ["language"], file: f)
                    TextPicker(label: "输出风格", value: f.value(["outputStyle"]) as? String ?? "",
                               options: [""] + OutputStyles.all, names: ["默认"] + OutputStyles.all) { f.set(["outputStyle"], $0.isEmpty ? nil : $0) }
                }
                Section("权限") {
                    TextPicker(label: "默认权限模式", value: f.value(["permissions", "defaultMode"]) as? String ?? "",
                               options: [""] + PermissionMode.allCases.map(\.rawValue),
                               names: ["跟随默认"] + PermissionMode.allCases.map(\.label)) { f.set(["permissions", "defaultMode"], $0.isEmpty ? nil : $0) }
                    BoolRow(label: "开「全部放行」时不再弹警告", key: ["skipDangerousModePermissionPrompt"], file: f)
                }
                Section("其他") {
                    BoolRow(label: "提交记录里署名 Claude", key: ["includeCoAuthoredBy"], file: f, defaultOn: true)
                    IntRow(label: "对话记录保留天数", key: ["cleanupPeriodDays"], file: f, placeholder: "默认 30")
                    TextPicker(label: "终端主题（只影响终端版）", value: f.value(["theme"]) as? String ?? "",
                               options: ["", "dark", "light", "dark-daltonized", "light-daltonized"],
                               names: ["跟随默认", "深色", "浅色", "深色（色弱友好）", "浅色（色弱友好）"]) { f.set(["theme"], $0.isEmpty ? nil : $0) }
                    if let sl = f.value(["statusLine", "command"]) as? String {
                        LabeledContent("终端状态栏命令") { Text(sl).font(T.mono).lineLimit(1).truncationMode(.middle).textSelection(.enabled) }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

enum OutputStyles {
    static var all: [String] {
        let custom = ConfigScan.markdownFiles(ConfigScan.home + "/output-styles").map { $0.deletingPathExtension().lastPathComponent }
        return ["Explanatory", "Learning"] + custom
    }
}

/// 按层级加载对应文件，切换层级时重新载入
struct ScopedFile<Content: View>: View {
    @Binding var scope: ConfigScope
    let project: String
    @ViewBuilder var content: (SettingsFile) -> Content
    @State private var file: SettingsFile?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScopePicker(scope: $scope, project: project).padding(.horizontal, 20).padding(.top, 14)
            if let file {
                FileHost(file: file, content: content).id(ObjectIdentifier(file))
            }
        }
        .onAppear { file = SettingsFile(url: scope.url(project: project)) }
        .onChange(of: scope) { file = SettingsFile(url: scope.url(project: project)) }
    }
}

struct FileHost<Content: View>: View {
    @ObservedObject var file: SettingsFile
    let content: (SettingsFile) -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let e = file.lastError { Text(e).font(T.small).foregroundStyle(T.err).padding(.horizontal, 20) }
            content(file)
        }
    }
}

struct BoolRow: View {
    let label: String
    let key: [String]
    @ObservedObject var file: SettingsFile
    var defaultOn = false
    var body: some View {
        Toggle(label, isOn: Binding(get: { file.value(key) as? Bool ?? defaultOn }, set: { file.set(key, $0) }))
    }
}

struct StringRow: View {
    let label: String
    let hint: String
    let key: [String]
    @ObservedObject var file: SettingsFile
    @State private var text = ""
    var body: some View {
        TextField(label, text: $text, prompt: Text(hint))
            .onAppear { text = file.value(key) as? String ?? "" }
            .onSubmit { file.set(key, text.isEmpty ? nil : text) }
            .help("回车保存")
    }
}

struct IntRow: View {
    let label: String
    let key: [String]
    @ObservedObject var file: SettingsFile
    let placeholder: String
    @State private var text = ""
    var body: some View {
        TextField(label, text: $text, prompt: Text(placeholder))
            .onAppear { text = (file.value(key) as? Int).map(String.init) ?? "" }
            .onSubmit {
                let t = text.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { file.set(key, nil) } else if let n = Int(t), n >= 0 { file.set(key, n) }
                else { text = (file.value(key) as? Int).map(String.init) ?? "" }   // 不是数字就还原，不删配置
            }
            .help("回车保存")
    }
}

struct TextPicker: View {
    let label: String
    let value: String
    let options: [String]
    let names: [String]
    let onChange: (String) -> Void
    var body: some View {
        let opts = options.contains(value) ? options : options + [value]
        Picker(label, selection: Binding(get: { value }, set: onChange)) {
            ForEach(Array(opts.enumerated()), id: \.offset) { i, o in
                Text(i < names.count ? names[i] : o).tag(o)
            }
        }
    }
}

// MARK: 权限规则

struct PermissionSettings: View {
    let project: String
    @State private var scope: ConfigScope = .user
    var body: some View {
        ScopedFile(scope: $scope, project: project) { f in
            Form {
                RuleList(title: "直接允许", hint: "例如 Bash(npm run *)、WebFetch(domain:github.com)、Read", key: ["permissions", "allow"], file: f)
                RuleList(title: "每次先问我", hint: "例如 Bash(git push *)", key: ["permissions", "ask"], file: f)
                RuleList(title: "禁止", hint: "例如 Read(./.env)、Bash(rm -rf *)", key: ["permissions", "deny"], file: f)
                RuleList(title: "额外可访问的文件夹", hint: "绝对路径，例如 ~/Desktop/素材", key: ["permissions", "additionalDirectories"], file: f)
            }
            .formStyle(.grouped)
        }
    }
}

struct RuleList: View {
    let title: String
    let hint: String
    let key: [String]
    @ObservedObject var file: SettingsFile
    @State private var draft = ""
    @State private var showAll = false

    var rules: [String] { file.value(key) as? [String] ?? [] }

    var body: some View {
        Section {
            let shown = showAll ? rules : Array(rules.prefix(12))
            ForEach(Array(shown.enumerated()), id: \.offset) { i, r in
                HStack {
                    Text(r).font(T.mono).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button { remove(r) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(T.err)
                }
            }
            if rules.count > 12 {
                Button(showAll ? "收起" : "显示全部 \(rules.count) 条") { showAll.toggle() }.buttonStyle(.link)
            }
            HStack {
                TextField("", text: $draft, prompt: Text(hint)).font(T.mono)
                        .labelsHidden().textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("添加", action: add).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("\(title)（\(rules.count)）")
        }
    }

    func add() {
        let t = draft.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !rules.contains(t) else { return }
        file.set(key, rules + [t])
        draft = ""
    }

    func remove(_ r: String) {
        let left = rules.filter { $0 != r }
        file.set(key, left.isEmpty ? nil : left)
    }
}

// MARK: 环境变量

struct EnvSettings: View {
    let project: String
    @State private var scope: ConfigScope = .user
    @State private var k = ""
    @State private var v = ""
    var body: some View {
        ScopedFile(scope: $scope, project: project) { f in
            let env = f.value(["env"]) as? [String: Any] ?? [:]
            Form {
                Section("每次启动 Claude 时带上的环境变量（\(env.count)）") {
                    ForEach(env.keys.sorted(), id: \.self) { key in
                        HStack {
                            Text(key).font(T.mono)
                            Spacer()
                            Text("\(env[key] ?? "")").font(T.mono).foregroundStyle(T.muted).lineLimit(1).textSelection(.enabled)
                            Button { var e = env; e[key] = nil; f.set(["env"], e.isEmpty ? nil : e) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).foregroundStyle(T.err)
                        }
                    }
                    HStack {
                        TextField("", text: $k, prompt: Text("名称，例如 BASH_DEFAULT_TIMEOUT_MS")).font(T.mono)
                        .labelsHidden().textFieldStyle(.roundedBorder)
                        TextField("", text: $v, prompt: Text("值")).font(T.mono)
                        .labelsHidden().textFieldStyle(.roundedBorder)
                        Button("添加") {
                            var e = env; e[k.trimmingCharacters(in: .whitespaces)] = v
                            f.set(["env"], e); k = ""; v = ""
                        }
                        .disabled(k.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section("常用") {
                    Text("MAX_THINKING_TOKENS（思考长度）、BASH_DEFAULT_TIMEOUT_MS（命令超时）、DISABLE_AUTOUPDATER=1（关自动更新）、HTTPS_PROXY（代理）")
                        .font(T.small).foregroundStyle(T.muted).textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
        }
    }
}

// MARK: 插件

struct PluginSettings: View {
    @StateObject private var file = SettingsFile(url: ConfigScope.user.url(project: ""))
    @State private var plugins = ConfigScan.plugins()
    @State private var markets = ConfigScan.marketplaces()
    @State private var installName = ""
    @State private var marketSrc = ""
    @State private var running = false
    @State private var log = ""

    var body: some View {
        Form {
            Section("已安装（\(plugins.count)）") {
                ForEach(plugins) { p in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).font(.system(size: fs(13), weight: .medium))
                            Text("\(p.marketplace) · \(p.version)").font(T.small).foregroundStyle(T.muted)
                        }
                        Spacer()
                        Menu {
                            Button("更新") { cli(["plugin", "update", p.key]) }
                            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.path)]) }
                            Divider()
                            Button("卸载", role: .destructive) { cli(["plugin", "uninstall", p.key]) }
                        } label: {
                            Image(systemName: "ellipsis.circle").font(.system(size: fs(14))).foregroundStyle(T.muted)
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("更新、查看或卸载")
                        Toggle("", isOn: Binding(
                            get: { file.value(["enabledPlugins", p.key]) as? Bool ?? false },
                            set: { file.set(["enabledPlugins", p.key], $0) }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                }
                HStack {
                    TextField("", text: $installName, prompt: Text("安装插件：名称 或 名称@市场"))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                    Button("安装") { cli(["plugin", "install", installName]); installName = "" }
                        .disabled(installName.isEmpty || running)
                }
            }
            Section("插件市场（\(markets.count)）") {
                ForEach(markets, id: \.name) { m in
                    HStack {
                        Text(m.name).font(.system(size: fs(13), weight: .medium))
                        Text(m.source).font(T.small).foregroundStyle(T.muted).lineLimit(1)
                        Spacer()
                        Button("更新") { cli(["plugin", "marketplace", "update", m.name]) }.disabled(running)
                        Button { cli(["plugin", "marketplace", "remove", m.name]) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(T.err)
                    }
                }
                HStack {
                    TextField("", text: $marketSrc, prompt: Text("添加市场：GitHub 仓库（owner/repo）、git 地址或本地路径"))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                    Button("添加") { cli(["plugin", "marketplace", "add", marketSrc]); marketSrc = "" }
                        .disabled(marketSrc.isEmpty || running)
                }
            }
            if running || !log.isEmpty {
                Section("执行结果") {
                    if running { ProgressView().controlSize(.small) }
                    Text(log).font(T.mono).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    func cli(_ args: [String]) {
        running = true
        log = "claude " + args.joined(separator: " ")
        DispatchQueue.global().async {
            let r = Shell.claude(args)
            DispatchQueue.main.async {
                running = false
                log = r.output.isEmpty ? (r.code == 0 ? "完成" : "失败（\(r.code)）") : r.output
                plugins = ConfigScan.plugins()
                markets = ConfigScan.marketplaces()
                file.reload()
            }
        }
    }
}

// MARK: MCP

struct MCPSettings: View {
    let project: String
    @State private var servers: [MCPServer] = []
    @State private var loading = true
    @State private var log = ""
    @State private var name = ""
    @State private var transport = "stdio"
    @State private var target = ""
    @State private var scope = "user"
    @State private var envText = ""

    var body: some View {
        Form {
            Section {
                if loading { HStack { ProgressView().controlSize(.small); Text("正在检查各服务器连接…").foregroundStyle(T.muted) } }
                ForEach(servers) { s in
                    HStack(alignment: .top) {
                        Circle().fill(s.status.contains("✔") ? T.ok : s.status.contains("!") ? T.run : T.err)
                            .frame(width: 7, height: 7).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).font(.system(size: fs(13), weight: .medium))
                            Text(s.target).font(T.small).foregroundStyle(T.muted).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                        Spacer()
                        Text(s.status.replacingOccurrences(of: "✔ ", with: "").replacingOccurrences(of: "✘ ", with: "").replacingOccurrences(of: "! ", with: ""))
                            .font(T.small).foregroundStyle(T.muted)
                        if s.removable {
                            Button { run(["mcp", "remove", s.name]) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).foregroundStyle(T.err).help("删除")
                        }
                    }
                }
            } header: {
                HStack { Text("已配置（\(servers.count)）"); Spacer(); Button("重新检查") { load() }.buttonStyle(.link) }
            } footer: {
                Text("插件自带的和 claude.ai 账号连接的服务器在这里不能删，去「插件」里停用对应插件。标「需要授权」的服务器要在终端里运行一次 claude，输入 /mcp 完成登录，之后这里就能用。")
                    .font(T.small).foregroundStyle(T.muted)
            }
            Section("添加服务器") {
                TextField("名称", text: $name, prompt: Text("例如 github"))
                Picker("连接方式", selection: $transport) {
                    Text("本地命令（stdio）").tag("stdio")
                    Text("网址（HTTP）").tag("http")
                    Text("网址（SSE）").tag("sse")
                }
                TextField(transport == "stdio" ? "命令" : "网址", text: $target,
                          prompt: Text(transport == "stdio" ? "例如 npx -y @modelcontextprotocol/server-github" : "https://…")).font(T.mono)
                TextField("环境变量", text: $envText, prompt: Text("可选，KEY=值，多个用空格分开")).font(T.mono)
                Picker("生效范围", selection: $scope) {
                    Text("所有项目").tag("user")
                    Text("只在当前项目（仅自己）").tag("local")
                    Text("当前项目（写进 .mcp.json 共享）").tag("project")
                }
                HStack { Spacer(); Button("添加") { add() }.disabled(name.isEmpty || target.isEmpty) }
            }
            if !log.isEmpty { Section("执行结果") { Text(log).font(T.mono).textSelection(.enabled) } }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    func load() {
        loading = true
        DispatchQueue.global().async {
            let r = Shell.claude(["mcp", "list"], cwd: project)
            DispatchQueue.main.async { servers = MCPList.parse(r.output); loading = false }
        }
    }

    func add() {
        var args = ["mcp", "add", "-s", scope, "-t", transport]
        for e in envText.split(separator: " ") where e.contains("=") { args += ["-e", String(e)] }
        args.append(name)
        if transport == "stdio" {
            args.append("--")
            args += target.split(separator: " ").map(String.init)
        } else {
            args.append(target)
        }
        run(args)
        name = ""; target = ""; envText = ""
    }

    func run(_ args: [String]) {
        log = "claude " + args.joined(separator: " ")
        DispatchQueue.global().async {
            let r = Shell.claude(args, cwd: project)
            DispatchQueue.main.async { log = r.output.isEmpty ? (r.code == 0 ? "完成" : "失败") : r.output; load() }
        }
    }
}

// MARK: 技能（只读）

struct SkillList: View {
    let project: String
    @State private var skills: [SkillInfo] = []
    @State private var q = ""
    var body: some View {
        let groups = Dictionary(grouping: skills.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) || $0.description.localizedCaseInsensitiveContains(q) }, by: \.source)
        Form {
            Section { TextField("", text: $q, prompt: Text("搜索技能名称或说明")).labelsHidden().textFieldStyle(.roundedBorder) } footer: {
                Text("技能由插件或 ~/.claude/skills 文件夹提供。对话里输入 / 可以直接调用。想新增技能可以在对话里让 Claude 帮你写。").font(T.small).foregroundStyle(T.muted)
            }
            ForEach(groups.keys.sorted(), id: \.self) { g in
                Section("\(g)（\(groups[g]!.count)）") {
                    ForEach(groups[g]!) { s in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name).font(.system(size: fs(13), weight: .medium))
                                Text(s.description).font(T.small).foregroundStyle(T.muted).lineLimit(2)
                            }
                            Spacer()
                            Button("打开") { NSWorkspace.shared.open(URL(fileURLWithPath: s.path)) }.buttonStyle(.link)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { DispatchQueue.global().async { let s = ConfigScan.skills(project: project); DispatchQueue.main.async { skills = s } } }
    }
}

// MARK: 子代理 / 自定义指令：一个文件夹里的 md 文件

struct MarkdownFolder: View {
    enum Kind { case agents, commands }
    let kind: Kind
    let project: String
    @State private var userLevel = true
    @State private var files: [URL] = []
    @State private var selected: URL?
    @State private var newName = ""

    var dir: String {
        let sub = kind == .agents ? "agents" : "commands"
        return userLevel ? ConfigScan.home + "/" + sub : project + "/.claude/" + sub
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $userLevel) {
                    Text("全局").tag(true)
                    Text("当前项目").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden()
                List(files, id: \.self, selection: $selected) { f in
                    Text(f.deletingPathExtension().lastPathComponent).tag(f)
                }
                HStack {
                    TextField("", text: $newName, prompt: Text(kind == .agents ? "新子代理名称" : "新指令名称"))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                        .onSubmit(create)
                    Button("新建", action: create).disabled(newName.isEmpty)
                }
                Text(kind == .agents ? "子代理是有固定分工的助手，Claude 会按描述自动派活。" : "文件名就是指令名，对话里输入 /名称 调用，$ARGUMENTS 代表后面跟的内容。")
                    .font(T.small).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12).frame(minWidth: 220, maxWidth: 280)
            Group {
                if let selected { FileEditor(url: selected, onDelete: { reload(); self.selected = nil }).id(selected) }
                else {
                    Text(files.isEmpty ? "这里还没有文件，左下角新建一个。" : "从左边选一个文件查看和编辑。")
                        .foregroundStyle(T.muted).multilineTextAlignment(.center).frame(maxWidth: 300)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 380)
        }
        .onAppear(perform: reload)
        .onChange(of: userLevel) { selected = nil; reload() }
    }

    func reload() { files = ConfigScan.markdownFiles(dir) }

    func create() {
        let n = newName.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
        guard !n.isEmpty else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(n + ".md")
        let tpl = kind == .agents
            ? "---\nname: \(n)\ndescription: 什么时候该派给它（Claude 靠这句判断）\ntools: Read, Grep, Glob\n---\n\n你是……（写清它的职责、做事方式、输出格式）\n"
            : "---\ndescription: 这个指令做什么\n---\n\n请帮我……\n\n$ARGUMENTS\n"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { try? tpl.write(to: url, atomically: true, encoding: .utf8) }
        newName = ""
        reload()
        selected = url
    }
}

/// 通用文本文件编辑器
struct FileEditor: View {
    let url: URL
    var onDelete: (() -> Void)? = nil
    @State private var text = ""
    @State private var saved = ""
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(T.small).foregroundStyle(T.muted)
                    .lineLimit(1).truncationMode(.head).textSelection(.enabled)
                Spacer()
                if text != saved { Text("未保存").font(T.small).foregroundStyle(T.run) }
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.link)
                if onDelete != nil {
                    Button("删除") { confirm = true }.buttonStyle(.link).foregroundStyle(T.err)
                }
                Button("保存") { save() }.keyboardShortcut("s").disabled(text == saved)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            TextEditor(text: $text).font(.system(size: fs(13), design: .monospaced)).scrollContentBackground(.hidden)
                .padding(8).background(T.paper)
        }
        .onAppear {
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            saved = text
        }
        .alert("删除 \(url.lastPathComponent)？", isPresented: $confirm) {
            Button("删除", role: .destructive) { try? FileManager.default.trashItem(at: url, resultingItemURL: nil); onDelete?() }
            Button("取消", role: .cancel) {}
        } message: { Text("文件会移到废纸篓。") }
    }

    func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil { saved = text }
    }
}

// MARK: 钩子

struct HookSettings: View {
    let project: String
    @State private var scope: ConfigScope = .user
    @State private var event = "PreToolUse"
    @State private var matcher = ""
    @State private var command = ""
    static let events = ["PreToolUse", "PostToolUse", "UserPromptSubmit", "Stop", "SubagentStop", "SessionStart", "SessionEnd", "Notification", "PreCompact"]
    static let eventNames = ["PreToolUse": "工具执行前", "PostToolUse": "工具执行后", "UserPromptSubmit": "你发消息时", "Stop": "Claude 回复结束时",
                             "SubagentStop": "子代理结束时", "SessionStart": "对话开始时", "SessionEnd": "对话结束时", "Notification": "发通知时", "PreCompact": "压缩上下文前"]

    var body: some View {
        ScopedFile(scope: $scope, project: project) { f in
            let hooks = f.value(["hooks"]) as? [String: Any] ?? [:]
            Form {
                Section {
                    Toggle("暂停所有钩子", isOn: Binding(get: { f.value(["disableAllHooks"]) as? Bool ?? false },
                                                    set: { f.set(["disableAllHooks"], $0 ? true : nil) }))
                }
                ForEach(eventKeys(hooks), id: \.self) { ev in
                    HookEventSection(title: "\(Self.eventNames[ev] ?? ev)（\(ev)）",
                                     groups: hooks[ev] as? [[String: Any]] ?? []) { gi, hi in remove(f, hooks, ev, gi, hi) }
                }
                Section("添加钩子") {
                    Picker("时机", selection: $event) {
                        ForEach(Self.events, id: \.self) { Text("\(Self.eventNames[$0] ?? $0)（\($0)）").tag($0) }
                    }
                    if event == "PreToolUse" || event == "PostToolUse" {
                        TextField("匹配工具", text: $matcher, prompt: Text("例如 Bash 或 Edit|Write，留空匹配全部")).font(T.mono)
                    }
                    TextField("执行命令", text: $command, prompt: Text("例如 python3 ~/.claude/hooks/check.py")).font(T.mono)
                    HStack { Spacer(); Button("添加") { add(f, hooks) }.disabled(command.isEmpty) }
                }
            }
            .formStyle(.grouped)
        }
    }

    func eventKeys(_ hooks: [String: Any]) -> [String] {
        Self.events.filter { hooks[$0] != nil } + hooks.keys.filter { !Self.events.contains($0) }.sorted()
    }

    func remove(_ f: SettingsFile, _ hooks: [String: Any], _ ev: String, _ gi: Int, _ hi: Int) {
        var all = hooks
        var groups = all[ev] as? [[String: Any]] ?? []
        guard gi < groups.count else { return }
        var hs = groups[gi]["hooks"] as? [[String: Any]] ?? []
        guard hi < hs.count else { return }
        hs.remove(at: hi)
        if hs.isEmpty { groups.remove(at: gi) } else { groups[gi]["hooks"] = hs }
        all[ev] = groups.isEmpty ? nil : groups
        f.set(["hooks"], all.isEmpty ? nil : all)
    }

    func add(_ f: SettingsFile, _ hooks: [String: Any]) {
        var all = hooks
        var groups = all[event] as? [[String: Any]] ?? []
        var g: [String: Any] = ["hooks": [["type": "command", "command": command]]]
        if event == "PreToolUse" || event == "PostToolUse" { g["matcher"] = matcher }
        groups.append(g)
        all[event] = groups
        f.set(["hooks"], all)
        command = ""; matcher = ""
    }
}

struct HookEventSection: View {
    let title: String
    let groups: [[String: Any]]
    let onRemove: (Int, Int) -> Void

    struct Entry: Identifiable { let id: String; let gi: Int; let hi: Int; let hook: [String: Any]; let matcher: String }
    var entries: [Entry] {
        var out: [Entry] = []
        for (gi, g) in groups.enumerated() {
            let m = g["matcher"] as? String ?? ""
            for (hi, h) in ((g["hooks"] as? [[String: Any]]) ?? []).enumerated() {
                out.append(Entry(id: "\(gi)-\(hi)", gi: gi, hi: hi, hook: h, matcher: m))
            }
        }
        return out
    }
    var body: some View {
        Section(title) {
            ForEach(entries) { e in HookRow(hook: e.hook, matcher: e.matcher) { onRemove(e.gi, e.hi) } }
        }
    }
}

struct HookRow: View {
    let hook: [String: Any]
    let matcher: String
    let onRemove: () -> Void
    var text: String {
        if let c = hook["command"] as? String { return c }
        if let p = hook["prompt"] as? String { return p }
        return "\(hook)"
    }
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(T.mono).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                if !matcher.isEmpty { Text("匹配：" + matcher).font(T.small).foregroundStyle(T.muted) }
            }
            Spacer()
            Button(action: onRemove) { Image(systemName: "minus.circle") }
                .buttonStyle(.plain).foregroundStyle(T.err)
        }
    }
}

// MARK: CLAUDE.md 与记忆

struct MemoryFiles: View {
    let project: String
    @State private var selected: URL?
    var entries: [(String, URL)] {
        var out: [(String, URL)] = [
            ("全局 CLAUDE.md（所有项目都读）", URL(fileURLWithPath: ConfigScan.home + "/CLAUDE.md")),
            ("项目 CLAUDE.md（共享）", URL(fileURLWithPath: project + "/CLAUDE.md")),
            ("项目 CLAUDE.local.md（仅自己）", URL(fileURLWithPath: project + "/CLAUDE.local.md")),
        ]
        let mem = ConfigScan.projectDir(project) + "/memory"
        for f in ConfigScan.markdownFiles(mem) { out.append(("记忆 · " + f.deletingPathExtension().lastPathComponent, f)) }
        return out
    }
    var body: some View {
        HSplitView {
            List(entries, id: \.1, selection: $selected) { e in
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.0).lineLimit(1)
                    if !FileManager.default.fileExists(atPath: e.1.path) { Text("还没有，编辑后保存即创建").font(.system(size: fs(10))).foregroundStyle(T.muted) }
                }
                .tag(e.1)
            }
            .frame(minWidth: 240, maxWidth: 320)
            Group {
                if let selected { FileEditor(url: selected).id(selected) }
                else {
                    Text("CLAUDE.md 是每次对话都会读的长期说明；记忆是 Claude 自己记下的要点。从左边选一个查看和编辑。")
                        .foregroundStyle(T.muted).multilineTextAlignment(.center).frame(maxWidth: 320)
                        .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 380)
        }
    }
}

// MARK: 原文

struct RawSettings: View {
    let project: String
    @State private var scope: ConfigScope = .user
    @State private var text = ""
    @State private var msg = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScopePicker(scope: $scope, project: project)
            Text("所有配置项都能在这里直接改。保存前会检查格式，并自动备份原文件。").font(T.small).foregroundStyle(T.muted)
            TextEditor(text: $text).font(.system(size: fs(12), design: .monospaced)).scrollContentBackground(.hidden)
                .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(T.sunk))
            HStack {
                Text(msg).font(T.small).foregroundStyle(msg.hasPrefix("已") ? T.ok : T.err)
                Spacer()
                Button("还原") { load() }
                Button("保存") {
                    msg = SettingsFile(url: scope.url(project: project)).replaceAll(text: text) ?? "已保存"
                }
                .keyboardShortcut("s")
            }
        }
        .padding(16)
        .onAppear(perform: load)
        .onChange(of: scope) { load() }
    }
    func load() { text = SettingsFile(url: scope.url(project: project)).rawText; msg = "" }
}

// MARK: 运行诊断：确认走的是哪个 claude、FCF 版本，升级后一键测试

struct DiagnoseView: View {
    @State private var path = UserDefaults.standard.string(forKey: "claudePath") ?? ""
    @State private var info: [(String, String)] = []
    @State private var checking = false
    @State private var testResult = ""
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                ForEach(info, id: \.0) { row in
                    LabeledContent(row.0) { Text(row.1).font(T.mono).textSelection(.enabled).lineLimit(2).truncationMode(.middle) }
                }
                if checking { HStack { ProgressView().controlSize(.small); Text("正在检查…").foregroundStyle(T.muted) } }
            } header: {
                HStack { Text("当前使用"); Spacer(); Button("重新检查") { check() }.buttonStyle(.link) }
            } footer: {
                Text("每次新开对话都会现读这里的 claude 和 FCF，所以 FCF / Claude Code 升级后不用改这个 App。如果升级了 Node，点「重新读取环境」。")
                    .font(T.small).foregroundStyle(T.muted)
            }
            Section("测试") {
                HStack {
                    Button(testing ? "测试中…" : "测试启动（发一条极短的消息）") { test() }.disabled(testing)
                    Button("重新读取环境") { LoginEnv.reload(); check() }
                }
                if !testResult.isEmpty { Text(testResult).font(T.mono).textSelection(.enabled) }
            }
            Section {
                TextField("claude 路径", text: $path, prompt: Text("留空自动使用 ~/.fcf/bin/claude"))
                    .font(T.mono)
                    .onSubmit { UserDefaults.standard.set(path.trimmingCharacters(in: .whitespaces), forKey: "claudePath"); check() }
            } header: { Text("自定义启动程序") } footer: {
                Text("一般不用填。回车保存，对新开的对话生效。").font(T.small).foregroundStyle(T.muted)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: check)
    }

    func check() {
        checking = true
        DispatchQueue.global().async {
            var rows: [(String, String)] = []
            let p = LoginEnv.claudePath
            rows.append(("启动程序", p.replacingOccurrences(of: NSHomeDirectory(), with: "~")))
            rows.append(("经过 FCF 代理", p.contains("/.fcf/") ? "是" : "否"))
            let v = Shell.claude(["--version"])
            rows.append(("Claude Code 版本", v.code == 0 ? v.output : "读取失败：" + v.output))
            let fcf = Shell.run("/bin/zsh", ["-lc", "cat \"$(npm root -g)/@rdc/fcf/package.json\""])
            if let d = fcf.output.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let ver = j["version"] as? String {
                rows.append(("FCF 版本", ver))
            } else {
                rows.append(("FCF 版本", "未找到"))
            }
            let node = Shell.run("/bin/zsh", ["-lc", "command -v node && node --version"])
            rows.append(("Node", node.output.replacingOccurrences(of: "\n", with: "  ").replacingOccurrences(of: NSHomeDirectory(), with: "~")))
            DispatchQueue.main.async { info = rows; checking = false }
        }
    }

    func test() {
        testing = true
        testResult = ""
        DispatchQueue.global().async {
            let start = Date()
            let r = Shell.claude(["-p", "只回复两个字：正常", "--output-format", "json", "--max-turns", "1", "--no-session-persistence"], cwd: NSTemporaryDirectory())
            var msg = "失败（\(r.code)）：" + String(r.output.suffix(400))
            if let line = r.output.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
               let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                let ok = (j["is_error"] as? Bool) != true
                msg = (ok ? "✓ 正常，" : "✗ 出错，") + String(format: "用时 %.1f 秒，回复：", Date().timeIntervalSince(start)) + ((j["result"] as? String) ?? "")
            }
            DispatchQueue.main.async { testResult = msg; testing = false }
        }
    }
}
