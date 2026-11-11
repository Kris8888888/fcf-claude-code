import Foundation
import Combine

/// 模型菜单里每个系列用哪个版本——自动跟最新，用的人不用管：
/// 1. Claude Code 升级后，从它本体里读出它认识的模型，取每个系列最新的版本
/// 2. 客户端自带「已确认可用」名单：补上 Claude Code 还没认识、但公司后台已经能用的（比如 Fable 5.2）
/// 3. 某个版本调用报「没有这个模型」，记下来以后不再用，自动退回上一个能用的版本
enum ModelFamily: String, CaseIterable {
    case fable, opus, sonnet, haiku
    var name: String { rawValue.capitalized }
}

final class ModelCatalog: ObservableObject {
    static let shared = ModelCatalog()

    /// 已确认公司后台能用的版本（发版时更新）。Claude Code 认识更新的版本时以它为准
    static let known: [String] = ["claude-fable-5-2", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]

    @Published private(set) var scanned: [String] = UserDefaults.standard.stringArray(forKey: "modelScan.ids") ?? []
    private var bad: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "modelScan.bad") ?? [])

    /// 这个系列现在用哪个完整模型名
    func id(for f: ModelFamily) -> String {
        let all = (Self.known + scanned).filter { Self.family(of: $0) == f && !bad.contains($0) }
        return all.max { Self.version($0) < Self.version($1) } ?? f.rawValue
    }

    func label(for f: ModelFamily) -> String { Self.pretty(id(for: f)) }

    /// 调用报「没有这个模型」：以后不再用它，返回退回去的那个
    @discardableResult
    func markUnavailable(_ id: String) -> String? {
        guard let f = Self.family(of: id), !bad.contains(id) else { return nil }
        bad.insert(id)
        UserDefaults.standard.set(Array(bad), forKey: "modelScan.bad")
        objectWillChange.send()
        let back = self.id(for: f)
        AppLog.write("模型 \(id) 用不了，换成 \(back)")
        upgradeDefaultSetting()
        return back
    }

    /// 设置里选的默认模型（存在 ~/.claude/settings.json）有更新的版本、或者那个版本用不了时，自动换成现在该用的版本
    func upgradeDefaultSetting() {
        let url = URL(fileURLWithPath: NSString(string: "~/.claude/settings.json").expandingTildeInPath)
        guard let d = try? Data(contentsOf: url), var j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let cur = j["model"] as? String, cur.hasPrefix("claude-"), let f = Self.family(of: cur) else { return }
        let want = id(for: f)
        guard want != cur, want.hasPrefix("claude-"), bad.contains(cur) || Self.version(want) > Self.version(cur) else { return }
        j["model"] = want
        guard let out = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        try? out.write(to: url, options: .atomic)
        AppLog.write("默认模型 \(cur) 自动换成 \(want)")
    }

    /// Claude 报「没有这个模型」时的那句话里找出模型名
    static func unavailableModel(in text: String) -> String? {
        let t = text.lowercased()
        guard t.contains("issue with the selected model") || t.contains("not_found_error") || t.contains("model_not_found")
                || (t.contains("model") && (t.contains("may not exist") || t.contains("does not exist") || t.contains("not found"))) else { return nil }
        guard let r = text.range(of: #"claude-[a-z]+-\d-\d{1,2}"#, options: .regularExpression) else { return nil }
        return String(text[r])
    }

    /// 后台读 Claude Code 本体（只在它升级后读一次，几百 MB 的文件也就零点几秒）
    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            guard let bin = Self.claudeBinary(),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: bin) else { return }
            let stamp = "\(bin)|\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(attrs[.size] ?? 0)"
            if UserDefaults.standard.string(forKey: "modelScan.stamp") == stamp { return }
            guard let d = try? Data(contentsOf: URL(fileURLWithPath: bin), options: .alwaysMapped) else { return }
            var found = Set<String>()
            for f in ModelFamily.allCases {
                let needle = Data("claude-\(f.rawValue)-".utf8)
                var from = d.startIndex
                while let r = d.range(of: needle, in: from..<d.endIndex) {
                    // 读后面的「5-5」：一位数字、横杠、一到两位数字
                    var i = r.upperBound, s = ""
                    while i < d.endIndex, s.count < 5 {
                        let c = d[i]
                        guard (c >= 48 && c <= 57) || c == 45 else { break }
                        s.append(Character(UnicodeScalar(c))); i += 1
                    }
                    let parts = s.split(separator: "-")
                    if parts.count >= 2, parts[0].count == 1, (1...2).contains(parts[1].count) {
                        found.insert("claude-\(f.rawValue)-\(parts[0])-\(parts[1])")
                    }
                    from = r.upperBound
                }
            }
            let ids = Array(found).sorted()
            DispatchQueue.main.async {
                UserDefaults.standard.set(stamp, forKey: "modelScan.stamp")
                UserDefaults.standard.set(ids, forKey: "modelScan.ids")
                self.scanned = ids
                self.upgradeDefaultSetting()
                AppLog.write("读到 Claude Code 认识的最新模型：" + ModelFamily.allCases.map { self.label(for: $0) }.joined(separator: "、"))
            }
        }
    }

    // MARK: 工具

    /// FCF 启动器最后跑的那个 Claude Code 本体：PATH 里的 claude（跳过 FCF 自己的启动器），顺着链接找到真文件
    static func claudeBinary() -> String? {
        let fcf = NSString(string: "~/.fcf/bin").expandingTildeInPath
        for dir in (LoginEnv.shared["PATH"] ?? "").split(separator: ":").map(String.init) where dir != fcf {
            let p = dir + "/claude"
            guard FileManager.default.isExecutableFile(atPath: p) else { continue }
            let real = URL(fileURLWithPath: p).resolvingSymlinksInPath().path
            // 启动脚本只有几 KB，本体至少几 MB
            if let size = (try? FileManager.default.attributesOfItem(atPath: real))?[.size] as? Int, size > 5_000_000 { return real }
        }
        return nil
    }

    static func family(of id: String) -> ModelFamily? {
        ModelFamily.allCases.first { id.hasPrefix("claude-\($0.rawValue)-") || id == $0.rawValue }
    }

    static func version(_ id: String) -> Int {
        let p = id.split(separator: "-").compactMap { Int($0) }
        guard p.count >= 2 else { return 0 }
        return p[0] * 100 + p[1]
    }

    /// claude-opus-5-5 → Opus 5.5
    static func pretty(_ id: String) -> String {
        let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-").map(String.init)
        guard let name = parts.first else { return id }
        let ver = parts.dropFirst().prefix { $0.count <= 2 && Int($0) != nil }
        return name.capitalized + (ver.isEmpty ? "" : " " + ver.joined(separator: "."))
    }
}
