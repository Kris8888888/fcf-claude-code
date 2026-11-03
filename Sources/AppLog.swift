import Foundation
import AppKit

/// 运行日志：~/Library/Logs/FCF启动claude code/app.log（超过 2MB 换新文件，旧的留一份 app.old.log）。
/// 另有一只「卡顿看门狗」：后台每秒看一眼主线程，超过 2 秒没响应就记下当时在看哪个对话。
enum AppLog {
    // 仅用于测试：DUIHUATAI_LOG_DIR 换个目录，不混进真的日志
    static let dir = ProcessInfo.processInfo.environment["DUIHUATAI_LOG_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/FCF启动claude code", isDirectory: true)
    private static let file = dir.appendingPathComponent("app.log")
    private static let queue = DispatchQueue(label: "app.log", qos: .utility)
    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss.SSS"; return f }()
    /// 主线程上最近一次报到的时间和「现在在看什么」（看门狗卡住时读它，不能等主线程）
    private static let lock = NSLock()
    private static var lastPing = Date()
    private static var context = ""

    static func write(_ s: String) {
        let line = "\(fmt.string(from: Date())) \(s)\n"
        queue.async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, size > 2_000_000 {
                let old = dir.appendingPathComponent("app.old.log")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: file, to: old)
            }
            if let h = try? FileHandle(forWritingTo: file) {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
            } else {
                try? line.data(using: .utf8)!.write(to: file)
            }
        }
    }

    /// 记下「现在在看什么」，卡住时写进日志
    static func setContext(_ s: String) { lock.lock(); context = s; lock.unlock() }

    static func start() {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        write("启动 版本 \(v) 系统 \(ProcessInfo.processInfo.operatingSystemVersionString)")
        // 主线程每 0.5 秒报到一次
        let t = Timer(timeInterval: 0.5, repeats: true) { _ in lock.lock(); lastPing = Date(); lock.unlock() }
        RunLoop.main.add(t, forMode: .common)
        // 看门狗在后台线程：主线程超过 2 秒没报到就记一笔，恢复后再记卡了多久
        // 仅用于测试：DUIHUATAI_TEST_STALL 让主线程故意卡 5 秒，看看看门狗记不记
        if ProcessInfo.processInfo.environment["DUIHUATAI_TEST_STALL"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { Thread.sleep(forTimeInterval: 5) }
        }
        Thread.detachNewThread {
            var stuckSince: Date?
            var reported = 0.0
            while true {
                Thread.sleep(forTimeInterval: 1)
                lock.lock(); let last = lastPing; let ctx = context; lock.unlock()
                let gap = Date().timeIntervalSince(last)
                if gap > 2 {
                    if stuckSince == nil { stuckSince = last; reported = 0 }
                    // 2 秒、10 秒、30 秒、60 秒…各记一次
                    if gap >= max(2, reported * 3) {
                        write("⚠️ 主线程无响应 \(Int(gap)) 秒 · \(ctx)")
                        reported = gap
                    }
                } else if let s = stuckSince {
                    write("主线程恢复，卡了 \(String(format: "%.1f", Date().timeIntervalSince(s))) 秒 · \(ctx)")
                    stuckSince = nil
                }
            }
        }
    }
}
