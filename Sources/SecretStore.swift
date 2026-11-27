import Foundation
import Security

/// 客户端自己的密钥（外网访问口令、别家模型服务的 Key）存在本机文件里，只有当前用户能读（权限 600）。
/// 以前放钥匙串：客户端没有苹果开发者签名，钥匙串按每个版本的程序指纹记授权，
/// 所以每次更新后都会弹「想要访问钥匙串」。改成文件后不再弹；旧版存进钥匙串的会在第一次用到时搬过来并删掉
enum SecretStore {
    private static let lock = NSLock()
    /// 仅用于测试：DUIHUATAI_SECRETS_FILE 指定别的文件，测试不碰真实数据
    static let url: URL = {
        if let p = ProcessInfo.processInfo.environment["DUIHUATAI_SECRETS_FILE"] { return URL(fileURLWithPath: p) }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("com.likang.duihuatai")
        return dir.appendingPathComponent("secrets.json")
    }()
    private static var isTest: Bool { ProcessInfo.processInfo.environment["DUIHUATAI_SECRETS_FILE"] != nil }

    private static func load() -> [String: String] {
        guard let d = try? Data(contentsOf: url), let j = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return [:] }
        return j
    }
    private static func save(_ all: [String: String]) {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let d = try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys]) else { return }
        // 先建好 600 权限的空文件再写，写的过程中别人也读不到
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        if let h = try? FileHandle(forWritingTo: url) { h.truncateFile(atOffset: 0); h.write(d); try? h.close() }
    }

    static func get(_ service: String, _ account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let k = service + "/" + account
        var all = load()
        if let v = all[k] { return v }
        // 旧版存在钥匙串里的：搬过来（最后一次可能弹钥匙串提示），然后从钥匙串删掉
        guard !isTest, let v = keychainTake(service, account) else { return nil }
        all[k] = v; save(all)
        return v
    }

    static func set(_ service: String, _ account: String, _ value: String?) {
        lock.lock(); defer { lock.unlock() }
        var all = load()
        all[service + "/" + account] = (value?.isEmpty ?? true) ? nil : value
        save(all)
    }

    private static func keychainTake(_ service: String, _ account: String) -> String? {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        var q = base; q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data, let s = String(data: d, encoding: .utf8) else { return nil }
        SecItemDelete(base as CFDictionary)
        return s
    }
}
