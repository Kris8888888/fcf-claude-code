import Foundation
import Security

/// 模型服务商（参照 CC Switch）：默认走 FCF；也可以换成别家提供 Anthropic 兼容接口的服务（DeepSeek、Kimi、智谱…）。
/// 跟 CC Switch 不同：不改 ~/.claude/settings.json，只在客户端启动 Claude 时带上那家的地址和 Key，终端里的 Claude Code 不受影响
/// 模型映射里的一个角色：Claude Code 里叫 Sonnet / Opus…，实际请求那家的哪个模型
struct RoleMap: Codable, Hashable {
    var name = ""      // 显示名称（空 = 用实际模型名）
    var model = ""     // 实际请求模型（空 = 用默认兜底模型；子代理空 = 不单独指定）
    var oneM = false   // 声明支持 1M 上下文（模型名后加 [1m]）
}

enum ModelRole: String, CaseIterable, Identifiable {
    case sonnet, opus, fable, haiku, subagent
    var id: String { rawValue }
    var label: String { self == .subagent ? "Subagent" : rawValue.capitalized }
    /// Claude Code 认的环境变量
    var envModel: String { self == .subagent ? "CLAUDE_CODE_SUBAGENT_MODEL" : "ANTHROPIC_DEFAULT_\(rawValue.uppercased())_MODEL" }
    var envName: String? { self == .subagent ? nil : "ANTHROPIC_DEFAULT_\(rawValue.uppercased())_MODEL_NAME" }
}

struct ModelProvider: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var baseURL: String
    var model: String          // 默认兜底模型
    var fastModel: String = "" // 旧版的快速模型：没设映射时当 Haiku 用
    var website: String = ""
    var roles: [String: RoleMap]? = nil
    var defaultOneM: Bool? = nil

    var fast: String { fastModel.isEmpty ? model : fastModel }

    /// 某个角色的映射；没设过就用默认（Haiku 用快速模型，其余用兜底模型，子代理不单独指定）
    func role(_ r: ModelRole) -> RoleMap {
        if let m = roles?[r.rawValue] { return m }
        switch r {
        case .haiku: return RoleMap(model: fast)
        case .subagent: return RoleMap()
        default: return RoleMap(model: model)
        }
    }
    /// 实际发给那家的模型名（空 = 兜底模型），带 [1m]
    func actual(_ r: ModelRole) -> String {
        let m = role(r)
        let id = m.model.isEmpty ? (r == .subagent ? "" : model) : m.model
        return id.isEmpty ? "" : id + (m.oneM ? "[1m]" : "")
    }
    func display(_ r: ModelRole) -> String {
        let m = role(r); let a = m.model.isEmpty ? model : m.model
        return m.name.isEmpty ? a : m.name
    }
}

final class ProviderStore: ObservableObject {
    static let shared = ProviderStore()

    @Published private(set) var providers: [ModelProvider] = []
    /// 现在用哪家；nil = FCF
    @Published private(set) var currentId: String?

    var current: ModelProvider? { providers.first { $0.id == currentId } }

    /// 仅用于测试：DUIHUATAI_TEST_PROVIDER=接口地址（Key 用 DUIHUATAI_TEST_KEY），只放内存，不存设置、不碰钥匙串
    private let testMode = ProcessInfo.processInfo.environment["DUIHUATAI_TEST_PROVIDER"] != nil

    private init() {
        if let base = ProcessInfo.processInfo.environment["DUIHUATAI_TEST_PROVIDER"] {
            providers = [ModelProvider(id: "test", name: "测试服务", baseURL: base, model: "fake-pro", fastModel: "fake-flash",
                                       roles: ["opus": RoleMap(name: "大模型", model: "fake-opus", oneM: true), "haiku": RoleMap(model: "fake-flash")])]
            currentId = "test"
            return
        }
        if let d = UserDefaults.standard.data(forKey: "providers.list"), let l = try? JSONDecoder().decode([ModelProvider].self, from: d) { providers = l }
        currentId = UserDefaults.standard.string(forKey: "providers.current")
        if let c = currentId, !providers.contains(where: { $0.id == c }) { currentId = nil }
    }

    private func save() {
        if testMode { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(providers), forKey: "providers.list")
        UserDefaults.standard.set(currentId, forKey: "providers.current")
    }

    func select(_ id: String?) {
        currentId = id
        save()
        AppLog.write("模型服务换成：" + (current?.name ?? "FCF"))
    }

    func upsert(_ p: ModelProvider, key: String?) {
        if let i = providers.firstIndex(where: { $0.id == p.id }) { providers[i] = p } else { providers.append(p) }
        if let key { setKey(key, for: p.id) }
        save()
    }

    func remove(_ p: ModelProvider) {
        providers.removeAll { $0.id == p.id }
        deleteKey(p.id)
        if currentId == p.id { currentId = nil }
        save()
    }

    // MARK: 启动 Claude 用的程序和环境

    /// FCF：照旧走 FCF 启动器。别家：直接用 Claude Code 本体，带上那家的地址、Key、模型
    func launch(for id: String?) -> (exe: String, env: [String: String], name: String?) {
        var env = LoginEnv.shared
        guard let id, let p = providers.first(where: { $0.id == id }), let bin = ModelCatalog.claudeBinary() else {
            return (LoginEnv.claudePath, env, nil)
        }
        for k in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL"] { env.removeValue(forKey: k) }
        env["ANTHROPIC_BASE_URL"] = p.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        env["ANTHROPIC_AUTH_TOKEN"] = key(for: p.id) ?? ""
        env["ANTHROPIC_MODEL"] = p.model + ((p.defaultOneM ?? false) ? "[1m]" : "")
        // 模型映射：Claude Code 里的 Sonnet / Opus / Fable / Haiku / 子代理 各自请求那家的哪个模型
        for r in ModelRole.allCases {
            let a = p.actual(r)
            if !a.isEmpty { env[r.envModel] = a }
            if let n = r.envName, !p.role(r).name.isEmpty { env[n] = p.role(r).name }
        }
        env["ANTHROPIC_SMALL_FAST_MODEL"] = p.actual(.haiku)
        env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"   // 不往 Anthropic 发统计
        env["API_TIMEOUT_MS"] = env["API_TIMEOUT_MS"] ?? "600000"
        return (bin, env, p.name)
    }

    // MARK: 测试连接：发一个最小的请求

    func test(_ p: ModelProvider, key: String, done: @escaping (Bool, String) -> Void) {
        let base = p.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + "/v1/messages") else { done(false, "接口地址不对"); return }
        var r = URLRequest(url: url, timeoutInterval: 30)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        r.setValue(key, forHTTPHeaderField: "x-api-key")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["model": p.model, "max_tokens": 16, "messages": [["role": "user", "content": "回复：好"]]])
        URLSession(configuration: .ephemeral).dataTask(with: r) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            var msg: String
            if let err { msg = "连不上：\(err.localizedDescription)" }
            else if code == 200 { msg = "连接正常，\(p.model) 有回复" }
            else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let detail = (try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? String(body.prefix(160))
                msg = "失败（\(code)）：\(detail)"
            }
            DispatchQueue.main.async { done(err == nil && code == 200, msg) }
        }.resume()
    }

    /// 获取模型列表：GET {地址}/v1/models
    func fetchModels(_ p: ModelProvider, key: String, done: @escaping ([String], String?) -> Void) {
        let base = p.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + "/v1/models") else { done([], "接口地址不对"); return }
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        r.setValue(key, forHTTPHeaderField: "x-api-key")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        URLSession(configuration: .ephemeral).dataTask(with: r) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let ids = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["data"] as? [[String: Any]])?
                .compactMap { $0["id"] as? String }.sorted() ?? []
            let msg: String? = err.map { "连不上：\($0.localizedDescription)" } ?? (ids.isEmpty ? "这家没返回模型列表（\(code)），直接手填模型名" : nil)
            DispatchQueue.main.async { done(ids, msg) }
        }.resume()
    }

    // MARK: 模板和从 CC Switch 导入

    /// 常用几家的接口地址（模型名以各家文档为准，填好后点「测试连接」确认）
    static let presets: [ModelProvider] = [
        ModelProvider(name: "DeepSeek", baseURL: "https://api.deepseek.com/anthropic", model: "deepseek-v4-pro", fastModel: "deepseek-flash", website: "https://platform.deepseek.com"),
        ModelProvider(name: "Kimi", baseURL: "https://api.moonshot.cn/anthropic", model: "", website: "https://platform.moonshot.cn"),
        ModelProvider(name: "智谱 GLM", baseURL: "https://open.bigmodel.cn/api/anthropic", model: "", website: "https://open.bigmodel.cn"),
        ModelProvider(name: "通义千问", baseURL: "https://dashscope.aliyuncs.com/apps/anthropic", model: "", website: "https://bailian.console.aliyun.com"),
        ModelProvider(name: "MiniMax", baseURL: "https://api.minimaxi.com/anthropic", model: "", website: "https://platform.minimaxi.com"),
    ]

    /// 把 CC Switch 里给 Claude Code 配的服务商搬过来（地址、模型、Key）；同名的跳过。返回导入了几个
    func importFromCCSwitch() -> (count: Int, note: String) {
        let db = NSString(string: "~/.cc-switch/cc-switch.db").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: db) else { return (0, "没找到 CC Switch 的配置") }
        let r = Shell.run("/usr/bin/sqlite3", ["-readonly", "-json", db, "select name, settings_config, website_url from providers where app_type='claude'"])
        guard let d = r.output.data(using: .utf8), let rows = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else {
            return (0, "读不了 CC Switch 的配置")
        }
        var n = 0
        for row in rows {
            guard let name = row["name"] as? String, let cfgS = row["settings_config"] as? String,
                  let cfg = try? JSONSerialization.jsonObject(with: Data(cfgS.utf8)) as? [String: Any],
                  let env = cfg["env"] as? [String: Any], let base = env["ANTHROPIC_BASE_URL"] as? String, !base.isEmpty,
                  !providers.contains(where: { $0.name == name }) else { continue }
            func split(_ v: Any?) -> (String, Bool) {
                let s = (v as? String) ?? ""
                return s.hasSuffix("[1m]") ? (String(s.dropLast(4)), true) : (s, false)
            }
            let (model, model1M) = split(env["ANTHROPIC_MODEL"] ?? env["ANTHROPIC_DEFAULT_SONNET_MODEL"])
            var roles: [String: RoleMap] = [:]
            for r in ModelRole.allCases {
                let (m, one) = split(env[r.envModel])
                let n = r.envName.flatMap { env[$0] as? String } ?? ""
                if !m.isEmpty || !n.isEmpty { roles[r.rawValue] = RoleMap(name: n, model: m, oneM: one) }
            }
            let key = (env["ANTHROPIC_AUTH_TOKEN"] as? String) ?? (env["ANTHROPIC_API_KEY"] as? String) ?? ""
            upsert(ModelProvider(name: name, baseURL: base, model: model, website: row["website_url"] as? String ?? "",
                                 roles: roles.isEmpty ? nil : roles, defaultOneM: model1M ? true : nil),
                   key: key.isEmpty ? nil : key)
            n += 1
        }
        return (n, n == 0 ? "CC Switch 里没有新的可导入服务商（官方的不需要导）" : "从 CC Switch 导入了 \(n) 个")
    }

    // MARK: Key 存钥匙串

    private static let service = "com.likang.duihuatai.provider"

    func key(for id: String) -> String? {
        if testMode { return ProcessInfo.processInfo.environment["DUIHUATAI_TEST_KEY"] }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                kSecAttrAccount as String: id, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    func setKey(_ key: String, for id: String) {
        deleteKey(id)
        guard !key.isEmpty else { return }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                kSecAttrAccount as String: id, kSecValueData as String: Data(key.utf8)]
        SecItemAdd(q as CFDictionary, nil)
    }

    private func deleteKey(_ id: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: id]
        SecItemDelete(q as CFDictionary)
    }
}
