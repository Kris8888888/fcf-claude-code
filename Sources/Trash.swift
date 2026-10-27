import Foundation
import AppKit

/// 废纸篓里的一条：被删掉的对话记录，带上恢复需要的信息
struct TrashEntry: Codable, Identifiable, Hashable {
    var id: String { storeKey ?? sessionId }
    let sessionId: String
    var storeKey: String? = nil        // 废纸篓里的文件名（同一会话删多次也不互相覆盖）；旧数据为 nil = sessionId
    var extraPaths: [String]? = nil    // 一起移进来的、被合并隐藏的旧会话文件原位置
    let title: String
    let cwd: String
    let originalPath: String       // 原来的会话记录文件位置（恢复时放回这里）
    let deletedAt: Date
    let wasPinned: Bool
    let customTitle: String?

    var folder: String { (cwd as NSString).lastPathComponent.isEmpty ? cwd : (cwd as NSString).lastPathComponent }
}

/// 对话废纸篓：删除先移到 App 自己的废纸篓目录，可恢复、可彻底删除、到期自动清除
final class TrashStore: ObservableObject {
    static let shared = TrashStore()

    @Published private(set) var entries: [TrashEntry] = []
    /// 自动清除天数，0 = 永久保留
    @Published var retentionDays: Int = UserDefaults.standard.object(forKey: "trashRetentionDays") as? Int ?? 30 {
        didSet { UserDefaults.standard.set(retentionDays, forKey: "trashRetentionDays"); purgeExpired() }
    }

    let dir: URL = {
        // 仅用于测试：DUIHUATAI_TRASH_DIR 换一个目录，不碰真的废纸篓
        if let t = ProcessInfo.processInfo.environment["DUIHUATAI_TRASH_DIR"] { return URL(fileURLWithPath: t, isDirectory: true) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("com.likang.duihuatai/Trash", isDirectory: true)
    }()
    private var index: URL { dir.appendingPathComponent("index.json") }

    private init() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
        purgeExpired()
    }

    private func load() {
        guard let d = try? Data(contentsOf: index) else { entries = []; return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        entries = ((try? dec.decode([TrashEntry].self, from: d)) ?? [])
            .filter { FileManager.default.fileExists(atPath: storedFile($0).path) }
            .sorted { $0.deletedAt > $1.deletedAt }
    }

    private func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted]
        if let d = try? enc.encode(entries) { try? d.write(to: index, options: .atomic) }
    }

    func storedFile(_ e: TrashEntry) -> URL { dir.appendingPathComponent(e.id + ".jsonl") }
    private func storedFolder(_ id: String) -> URL { dir.appendingPathComponent(id, isDirectory: true) }
    private func partsFolder(_ e: TrashEntry) -> URL { dir.appendingPathComponent(e.id + ".parts", isDirectory: true) }

    /// 文件和它同名的子代理文件夹一起挪
    private static func moveWithSide(_ src: URL, to dst: URL) throws {
        let fm = FileManager.default
        try fm.moveItem(at: src, to: dst)
        let side = src.deletingPathExtension(), dside = dst.deletingPathExtension()
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: side.path, isDirectory: &isDir), isDir.boolValue, !fm.fileExists(atPath: dside.path) {
            try? fm.moveItem(at: side, to: dside)
        }
    }

    /// 这条还剩几天被自动清除（nil = 永久保留）
    func daysLeft(_ e: TrashEntry) -> Int? {
        guard retentionDays > 0 else { return nil }
        let expire = e.deletedAt.addingTimeInterval(Double(retentionDays) * 86400)
        return max(0, Int(ceil(expire.timeIntervalSinceNow / 86400)))
    }

    /// 移进废纸篓：会话记录文件，以及同名的子代理记录文件夹（如果有）
    func add(sessionId: String, file: URL, title: String, cwd: String, wasPinned: Bool, customTitle: String?, extraFiles: [URL] = []) throws {
        let fm = FileManager.default
        let key = sessionId + "-" + String(Int(Date().timeIntervalSince1970 * 1000))
        var e = TrashEntry(sessionId: sessionId, storeKey: key, title: title, cwd: cwd, originalPath: file.path,
                           deletedAt: Date(), wasPinned: wasPinned, customTitle: customTitle)
        try fm.moveItem(at: file, to: storedFile(e))
        let side = file.deletingPathExtension()
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: side.path, isDirectory: &isDir), isDir.boolValue {
            try? fm.moveItem(at: side, to: storedFolder(key))
        }
        var moved: [String] = []
        for (i, f) in extraFiles.enumerated() where fm.fileExists(atPath: f.path) {
            try? fm.createDirectory(at: partsFolder(e), withIntermediateDirectories: true)
            let d = partsFolder(e).appendingPathComponent("\(i)").appendingPathExtension("jsonl")
            if (try? Self.moveWithSide(f, to: d)) != nil { moved.append(f.path) }
        }
        if !moved.isEmpty { e.extraPaths = moved }
        entries.insert(e, at: 0)
        save()
    }

    enum RestoreError: LocalizedError {
        case exists(String)
        var errorDescription: String? {
            switch self { case .exists(let p): return "原位置已经有同名的会话记录：\(p)" }
        }
    }

    /// 放回原位置
    func restore(_ e: TrashEntry) throws {
        let fm = FileManager.default
        let target = URL(fileURLWithPath: e.originalPath)
        if fm.fileExists(atPath: target.path) { throw RestoreError.exists(target.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: storedFile(e), to: target)
        let side = storedFolder(e.id)
        if fm.fileExists(atPath: side.path) { try? fm.moveItem(at: side, to: target.deletingPathExtension()) }
        var allBack = true
        for (i, p) in (e.extraPaths ?? []).enumerated() {
            let src = partsFolder(e).appendingPathComponent("\(i)").appendingPathExtension("jsonl")
            let dst = URL(fileURLWithPath: p)
            if !fm.fileExists(atPath: dst.path) {
                try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? Self.moveWithSide(src, to: dst)) == nil { allBack = false }
            } else if fm.fileExists(atPath: src.path) {
                allBack = false     // 原位置已经有同名文件：这份旧记录留在废纸篓，不直接删掉
            }
        }
        if allBack { try? fm.removeItem(at: partsFolder(e)) }
        entries.removeAll { $0.id == e.id }
        save()
    }

    /// 彻底删除（不可恢复）
    func purge(_ e: TrashEntry) {
        try? FileManager.default.removeItem(at: storedFile(e))
        try? FileManager.default.removeItem(at: storedFolder(e.id))
        try? FileManager.default.removeItem(at: partsFolder(e))
        entries.removeAll { $0.id == e.id }
        save()
    }

    func emptyAll() {
        for e in entries {
            try? FileManager.default.removeItem(at: storedFile(e))
            try? FileManager.default.removeItem(at: storedFolder(e.id))
            try? FileManager.default.removeItem(at: partsFolder(e))
        }
        entries = []
        save()
    }

    func purgeExpired() {
        guard retentionDays > 0 else { return }
        let expired = entries.filter { $0.deletedAt.addingTimeInterval(Double(retentionDays) * 86400) < Date() }
        guard !expired.isEmpty else { return }
        expired.forEach { purge($0) }
    }
}
