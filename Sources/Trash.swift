import Foundation
import AppKit

/// 废纸篓里的一条：被删掉的对话记录，带上恢复需要的信息
struct TrashEntry: Codable, Identifiable, Hashable {
    var id: String { sessionId }
    let sessionId: String
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

    func storedFile(_ e: TrashEntry) -> URL { dir.appendingPathComponent(e.sessionId + ".jsonl") }
    private func storedFolder(_ id: String) -> URL { dir.appendingPathComponent(id, isDirectory: true) }

    /// 这条还剩几天被自动清除（nil = 永久保留）
    func daysLeft(_ e: TrashEntry) -> Int? {
        guard retentionDays > 0 else { return nil }
        let expire = e.deletedAt.addingTimeInterval(Double(retentionDays) * 86400)
        return max(0, Int(ceil(expire.timeIntervalSinceNow / 86400)))
    }

    /// 移进废纸篓：会话记录文件，以及同名的子代理记录文件夹（如果有）
    func add(sessionId: String, file: URL, title: String, cwd: String, wasPinned: Bool, customTitle: String?) throws {
        let fm = FileManager.default
        let dst = dir.appendingPathComponent(sessionId + ".jsonl")
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.moveItem(at: file, to: dst)
        let sideFolder = file.deletingPathExtension()
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: sideFolder.path, isDirectory: &isDir), isDir.boolValue {
            let d2 = storedFolder(sessionId)
            try? fm.removeItem(at: d2)
            try? fm.moveItem(at: sideFolder, to: d2)
        }
        entries.removeAll { $0.sessionId == sessionId }
        entries.insert(TrashEntry(sessionId: sessionId, title: title, cwd: cwd, originalPath: file.path,
                                  deletedAt: Date(), wasPinned: wasPinned, customTitle: customTitle), at: 0)
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
        let side = storedFolder(e.sessionId)
        if fm.fileExists(atPath: side.path) { try? fm.moveItem(at: side, to: target.deletingPathExtension()) }
        entries.removeAll { $0.sessionId == e.sessionId }
        save()
    }

    /// 彻底删除（不可恢复）
    func purge(_ e: TrashEntry) {
        try? FileManager.default.removeItem(at: storedFile(e))
        try? FileManager.default.removeItem(at: storedFolder(e.sessionId))
        entries.removeAll { $0.sessionId == e.sessionId }
        save()
    }

    func emptyAll() {
        for e in entries {
            try? FileManager.default.removeItem(at: storedFile(e))
            try? FileManager.default.removeItem(at: storedFolder(e.sessionId))
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
