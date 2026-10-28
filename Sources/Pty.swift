import Foundation
import Darwin

/// 在伪终端（pty）里跑一条命令：fcf 的交互菜单、升级确认都要求真终端
final class PtyProcess {
    var onOutput: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?

    private var master: Int32 = -1
    private var proc: Process?
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "pty.io")

    var isRunning: Bool { proc?.isRunning ?? false }

    func start(command: String, cwd: String, cols: Int, rows: Int, extraEnv: [String: String] = [:]) throws {
        let m = posix_openpt(O_RDWR | O_NOCTTY)
        guard m >= 0, grantpt(m) == 0, unlockpt(m) == 0, let name = ptsname(m) else {
            throw NSError(domain: "pty", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建终端"])
        }
        let slavePath = String(cString: name)
        let slave = open(slavePath, O_RDWR)
        guard slave >= 0 else { close(m); throw NSError(domain: "pty", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法打开终端"]) }
        master = m
        resize(cols: cols, rows: rows)

        var env = LoginEnv.shared
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "zh_CN.UTF-8"
        for (k, v) in extraEnv { env[k] = v }

        // 用 script 再套一层：命令拿到自己的控制终端，Ctrl+C 能直接中断、/dev/tty 可用
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        p.arguments = ["-q", "/dev/null", "/bin/zsh", "-lc", command]
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.environment = env
        let fh = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        p.standardInput = fh
        p.standardOutput = fh
        p.standardError = fh
        p.terminationHandler = { [weak self] pr in
            // 等输出读完再报告退出
            self?.queue.asyncAfter(deadline: .now() + 0.15) {
                let code = pr.terminationStatus
                DispatchQueue.main.async { self?.onExit?(code) }
            }
        }
        do { try p.run() } catch { close(m); master = -1; throw error }
        proc = p

        let src = DispatchSource.makeReadSource(fileDescriptor: m, queue: queue)
        src.setEventHandler { [weak self, weak src] in
            var buf = [UInt8](repeating: 0, count: 8192)
            let n = read(m, &buf, buf.count)   // 用捕获的 fd，不读可能已被改掉的属性
            if n > 0 {
                let d = Data(buf[0..<n])
                DispatchQueue.main.async { self?.onOutput?(d) }
            } else {
                src?.cancel()
            }
        }
        // fd 只在读取源真正停下后再关，避免关早了读到别的文件
        src.setCancelHandler { close(m) }
        src.resume()
        source = src
    }

    func write(_ data: Data) {
        guard master >= 0 else { return }
        data.withUnsafeBytes { p in _ = Darwin.write(master, p.baseAddress, data.count) }
    }

    func write(_ s: String) { write(Data(s.utf8)) }

    func resize(cols: Int, rows: Int) {
        guard master >= 0 else { return }
        var ws = winsize(ws_row: UInt16(max(rows, 5)), ws_col: UInt16(max(cols, 20)), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &ws)
    }

    func terminate() {
        if let p = proc, p.isRunning {
            let kids = ClaudeProcess.descendants(of: p.processIdentifier)
            p.terminate()
            for k in kids { kill(k, SIGTERM) }
        }
        source?.cancel()      // 关闭 fd 由 cancel handler 负责
        source = nil
        master = -1
        proc = nil
    }

    deinit { terminate() }
}
