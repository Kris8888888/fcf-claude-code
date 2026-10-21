import Foundation

// 配置文件层级：跟终端里 Claude Code 的三层一致
enum ConfigScope: String, CaseIterable, Identifiable {
    case user, project, local
    var id: String { rawValue }
    var label: String {
        switch self {
        case .user: return "全局"
        case .project: return "项目（共享）"
        case .local: return "项目（仅自己）"
        }
    }
    func url(project: String) -> URL {
        switch self {
        case .user: return URL(fileURLWithPath: NSString(string: "~/.claude/settings.json").expandingTildeInPath)
        case .project: return URL(fileURLWithPath: project).appendingPathComponent(".claude/settings.json")
        case .local: return URL(fileURLWithPath: project).appendingPathComponent(".claude/settings.local.json")
        }
    }
}

/// 读写一个 settings.json。写入走 python3 的 json 模块，保留原有键的顺序；每个文件每次启动先备份一次
final class SettingsFile: ObservableObject {
    let url: URL
    @Published private(set) var json: [String: Any] = [:]
    @Published var lastError: String?
    private static var backedUp = Set<String>()

    init(url: URL) {
        self.url = url
        reload()
    }

    func reload() {
        guard let d = try? Data(contentsOf: url), !d.isEmpty else { json = [:]; return }
        json = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }

    func value(_ path: [String]) -> Any? {
        var cur: Any? = json
        for k in path { cur = (cur as? [String: Any])?[k] }
        return cur
    }

    /// value 为 nil 表示删除这个键
    func set(_ path: [String], _ value: Any?) {
        backup()
        let valueJSON: String
        if let value, let d = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) {
            valueJSON = String(decoding: d, as: UTF8.self)
        } else {
            valueJSON = "__DELETE__"
        }
        let pathJSON = String(decoding: try! JSONSerialization.data(withJSONObject: path), as: UTF8.self)
        let script = """
        import json, sys, os
        p, path, val = os.path.realpath(sys.argv[1]), json.loads(sys.argv[2]), sys.argv[3]
        try:
            d = json.load(open(p, encoding='utf-8'))
        except FileNotFoundError:
            d = {}
        cur = d
        for k in path[:-1]:
            if not isinstance(cur.get(k), dict): cur[k] = {}
            cur = cur[k]
        if val == '__DELETE__':
            cur.pop(path[-1], None)
        else:
            cur[path[-1]] = json.loads(val)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        tmp = p + '.tmp-gui'
        with open(tmp, 'w', encoding='utf-8') as f:
            json.dump(d, f, ensure_ascii=False, indent=2); f.write('\\n')
        if os.path.exists(p): os.chmod(tmp, os.stat(p).st_mode & 0o7777)
        os.replace(tmp, p)
        """
        let r = Shell.run("/usr/bin/python3", ["-c", script, url.path, pathJSON, valueJSON])
        lastError = r.code == 0 ? nil : "保存失败：\(r.output)"
        reload()
    }

    /// 整个文件替换（原始 JSON 编辑用），先校验
    func replaceAll(text: String) -> String? {
        guard let d = text.data(using: .utf8), (try? JSONSerialization.jsonObject(with: d)) is [String: Any] else {
            return "不是合法的 JSON 对象，没有保存。"
        }
        backup()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try d.write(to: url.resolvingSymlinksInPath(), options: .atomic)
        } catch { return "保存失败：\(error.localizedDescription)" }
        reload()
        return nil
    }

    var rawText: String { (try? String(contentsOf: url, encoding: .utf8)) ?? "{\n}\n" }

    private func backup() {
        guard FileManager.default.fileExists(atPath: url.path), !Self.backedUp.contains(url.path) else { return }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let dst = url.path + ".bak-gui-" + f.string(from: Date())
        try? FileManager.default.copyItem(atPath: url.path, toPath: dst)
        Self.backedUp.insert(url.path)
    }
}

enum Shell {
    struct Result { let code: Int32; let output: String }

    static func run(_ exe: String, _ args: [String], cwd: String? = nil, timeout: TimeInterval? = nil) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = LoginEnv.shared
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return Result(code: -1, output: error.localizedDescription) }

        // 后台读输出；有超时就最多等这么久，到点结束整棵进程树并放弃读取，绝不卡死调用方
        var data = Data()
        let lock = NSLock()
        let done = DispatchSemaphore(value: 0)
        let reader = out.fileHandleForReading
        DispatchQueue.global().async {
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                lock.lock(); data.append(chunk); lock.unlock()
            }
            done.signal()
        }
        if let timeout, done.wait(timeout: .now() + timeout) == .timedOut {
            let kids = ClaudeProcess.descendants(of: p.processIdentifier)
            p.terminate()
            for k in kids { kill(k, SIGTERM) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                for k in kids { kill(k, SIGKILL) }
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
            lock.lock(); let partial = data; lock.unlock()
            return Result(code: -2, output: clean(String(decoding: partial, as: UTF8.self)) + "\n（超时）")
        }
        if timeout == nil { done.wait() }
        p.waitUntilExit()
        lock.lock(); let all = data; lock.unlock()
        return Result(code: p.terminationStatus, output: clean(String(decoding: all, as: UTF8.self)))
    }

    /// 调 claude 子命令（mcp / plugin 等），去掉颜色码和 FCF 横幅
    static func claude(_ args: [String], cwd: String? = nil) -> Result {
        run(LoginEnv.claudePath, args, cwd: cwd)
    }

    static func clean(_ s: String) -> String {
        let noAnsi = s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        return noAnsi.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { l in
                let t = l.trimmingCharacters(in: .whitespaces)
                return !(t.hasPrefix("+---") || t.contains("FCF Proxy"))
            }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: 只读扫描：技能 / 子代理 / 指令 / 插件

struct SkillInfo: Identifiable {
    var id: String { path }
    let name: String
    let description: String
    let source: String
    let path: String
}

struct PluginInfo: Identifiable {
    var id: String { key }
    let key: String          // name@marketplace
    let version: String
    let path: String
    var name: String { String(key.split(separator: "@").first ?? Substring(key)) }
    var marketplace: String { key.contains("@") ? String(key.split(separator: "@").last!) : "" }
}

enum ConfigScan {
    static let home = NSString(string: "~/.claude").expandingTildeInPath

    /// 读 YAML 头部的简单键值，支持 `key: |` / `key: >` 这种多行写法
    static func frontmatter(_ text: String) -> [String: String] {
        guard text.hasPrefix("---") else { return [:] }
        var out: [String: String] = [:]
        let lines = text.components(separatedBy: "\n").dropFirst()
        var blockKey: String?
        var block: [String] = []
        func endBlock() {
            if let k = blockKey { out[k] = block.joined(separator: " ").trimmingCharacters(in: .whitespaces) }
            blockKey = nil; block = []
        }
        for line in lines {
            if line.hasPrefix("---") { break }
            if blockKey != nil {
                if line.hasPrefix(" ") || line.hasPrefix("\t") || line.trimmingCharacters(in: .whitespaces).isEmpty {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { block.append(t) }
                    continue
                }
                endBlock()
            }
            guard let c = line.firstIndex(of: ":") else { continue }
            let k = line[..<c].trimmingCharacters(in: .whitespaces)
            var v = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
            if ["|", ">", "|-", ">-", "|+", ">+"].contains(v) { blockKey = k; continue }
            if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) { v = String(v.dropFirst().dropLast()) }
            out[k] = v
        }
        endBlock()
        return out
    }

    static func plugins() -> [PluginInfo] {
        let url = URL(fileURLWithPath: home + "/plugins/installed_plugins.json")
        guard let d = try? Data(contentsOf: url), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let ps = j["plugins"] as? [String: Any] else { return [] }
        return ps.compactMap { k, v in
            guard let first = (v as? [[String: Any]])?.first else { return nil }
            return PluginInfo(key: k, version: first["version"] as? String ?? "", path: first["installPath"] as? String ?? "")
        }.sorted { $0.key < $1.key }
    }

    static func marketplaces() -> [(name: String, source: String)] {
        let url = URL(fileURLWithPath: home + "/plugins/known_marketplaces.json")
        guard let d = try? Data(contentsOf: url), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
        return j.map { k, v in
            let src = (v as? [String: Any])?["source"] as? [String: Any]
            let s = (src?["repo"] ?? src?["url"] ?? src?["path"]) as? String ?? ""
            return (k, s)
        }.sorted { $0.name < $1.name }
    }

    static func skills(project: String) -> [SkillInfo] {
        var out: [SkillInfo] = []
        func scan(_ dir: String, source: String) {
            let fm = FileManager.default
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                let p = dir + "/" + name + "/SKILL.md"
                guard let t = try? String(contentsOfFile: p, encoding: .utf8) else { continue }
                let fmd = frontmatter(t)
                out.append(SkillInfo(name: fmd["name"] ?? name, description: fmd["description"] ?? "", source: source, path: p))
            }
        }
        scan(home + "/skills", source: "个人技能")
        scan(project + "/.claude/skills", source: "项目技能")
        for p in plugins() { scan(p.path + "/skills", source: "插件 " + p.name) }
        return out
    }

    static func markdownFiles(_ dir: String) -> [URL] {
        let u = URL(fileURLWithPath: dir)
        let fs = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? []
        return fs.filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Claude Code 存项目数据的目录名：路径里非字母数字都换成 -
    static func projectDir(_ path: String) -> String {
        home + "/projects/" + String(path.map { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII ? $0 : "-" })
    }
}

struct MCPServer: Identifiable {
    var id: String { name }
    let name: String
    let target: String
    let status: String
    var removable: Bool { !name.hasPrefix("plugin:") && !name.hasPrefix("claude.ai ") }
}

enum MCPList {
    static func parse(_ out: String) -> [MCPServer] {
        out.split(separator: "\n").compactMap { l in
            let line = String(l)
            guard let sep = line.range(of: ": "), let dash = line.range(of: " - ", options: .backwards) , dash.lowerBound > sep.upperBound else { return nil }
            return MCPServer(name: String(line[..<sep.lowerBound]),
                             target: String(line[sep.upperBound..<dash.lowerBound]),
                             status: String(line[dash.upperBound...]))
        }
    }
}
