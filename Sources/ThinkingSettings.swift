import SwiftUI

/// 思维链偏好：客户端里怎么显示思考过程
enum ThinkingPrefs {
    /// 思考内容：follow = 跟终端一样（读 settings.json 的 showThinkingSummaries）；summarized = 显示摘要；omitted = 只显示用时
    static var display: String { UserDefaults.standard.string(forKey: "thinkingDisplay") ?? "follow" }
    /// 展开方式：auto = 思考时展开、结束后收起；collapsed = 一直收起；expanded = 一直展开
    static var expand: String { UserDefaults.standard.string(forKey: "thinkingExpand") ?? "auto" }

    /// 终端里的设置（项目本地 > 项目 > 全局），没设置返回 nil
    static func terminalSummaries(cwd: String) -> Bool? {
        for scope in [ConfigScope.local, .project, .user] {
            if let v = SettingsFile(url: scope.url(project: cwd)).value(["showThinkingSummaries"]) as? Bool { return v }
        }
        return nil
    }

    /// 传给后台 claude 的 --thinking-display。
    /// 后台模式（-p）不读 showThinkingSummaries，不传就拿不到思考内容，这是和终端显示不一样的原因
    static func cliDisplay(cwd: String) -> String? {
        if OptionalFlags.unsupported("--thinking-display") { return nil }
        switch display {
        case "summarized", "omitted": return display
        default:
            guard let v = terminalSummaries(cwd: cwd) else { return nil }
            return v ? "summarized" : "omitted"
        }
    }
}

struct ThinkingSettings: View {
    let project: String
    @AppStorage("thinkingDisplay") private var display = "follow"
    @AppStorage("thinkingExpand") private var expand = "auto"
    @State private var global = SettingsFile(url: ConfigScope.user.url(project: NSHomeDirectory()))

    private var showsText: Bool { ThinkingPrefs.cliDisplay(cwd: project) == "summarized" }

    var body: some View {
        FileHost(file: global) { f in
            Form {
                Section {
                    Picker("思考内容", selection: $display) {
                        Text("跟终端一样").tag("follow")
                        Text("显示思考摘要").tag("summarized")
                        Text("只显示思考用时").tag("omitted")
                    }
                    if display == "follow" {
                        Text(followNote(f)).font(T.small).foregroundStyle(T.muted)
                    }
                    Picker("展开方式", selection: $expand) {
                        Text("思考时展开，想完自动收起").tag("auto")
                        Text("一直收起，点开再看").tag("collapsed")
                        Text("一直展开").tag("expanded")
                    }
                    ThinkingPreview(showsText: showsText, expanded: expand != "collapsed")
                } header: {
                    Text("对话里怎么显示")
                } footer: {
                    Text("只影响这个客户端。改完从下一条消息开始生效。")
                }

                Section {
                    Toggle("让 Claude 先思考再回答", isOn: Binding(get: { f.value(["alwaysThinkingEnabled"]) as? Bool ?? true },
                                                          set: { f.set(["alwaysThinkingEnabled"], $0 ? nil : false) }))
                    TextPicker(label: "思考深度", value: f.value(["effortLevel"]) as? String ?? "",
                               options: ["", "low", "medium", "high", "xhigh"],
                               names: ["跟随默认", "浅（更快）", "适中", "深", "很深（最慢）"]) { f.set(["effortLevel"], $0.isEmpty ? nil : $0) }
                    BoolRow(label: "终端里也显示思考摘要", key: ["showThinkingSummaries"], file: f)
                } header: {
                    Text("Claude 怎么思考")
                } footer: {
                    Text("写进全局配置 ~/.claude/settings.json，终端里的 Claude Code 也会按这里来。思考越深回答越慢、花费越多。")
                }
            }
            .formStyle(.grouped)
        }
    }

    private func followNote(_ f: SettingsFile) -> String {
        switch ThinkingPrefs.terminalSummaries(cwd: project) {
        case true?: return "你的终端设置是显示思考摘要，这里也会显示。"
        case false?: return "你的终端设置是不显示思考内容，这里也只显示用时。"
        case nil: return "终端里没有设置过，所以和终端一样只显示用时。想看思考内容，选「显示思考摘要」。"
        }
    }
}

/// 预览：选完马上看到对话里的思考行长什么样
private struct ThinkingPreview: View {
    let showsText: Bool
    let expanded: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("预览").font(T.small).foregroundStyle(T.muted)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "brain").font(.system(size: fs(11))).foregroundStyle(T.muted).padding(.top, 2)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("思考了 12 秒").font(.system(size: fs(13))).foregroundStyle(T.muted)
                        Image(systemName: "chevron.right").font(.system(size: fs(9), weight: .semibold))
                            .foregroundStyle(T.muted).rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    if expanded {
                        Text(showsText ? "先确认报价单里的币种，再按数量阶梯算出单价，最后核对合计。"
                                       : "这次的思考内容没有显示，只记录了用时。")
                            .font(.system(size: fs(13))).foregroundStyle(T.muted.opacity(showsText ? 1 : 0.8))
                            .padding(.leading, 10)
                            .overlay(alignment: .leading) { Rectangle().fill(T.line).frame(width: 2) }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(T.canvas, in: RoundedRectangle(cornerRadius: 8))
            .animation(.easeOut(duration: 0.15), value: expanded)
            .animation(.easeOut(duration: 0.15), value: showsText)
        }
        .padding(.vertical, 2)
    }
}
