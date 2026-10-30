import Foundation

// 从登录 shell 取一次环境变量：Finder 启动的 App 没有 nvm 的 PATH，FCF 包装脚本要靠它找 node / npm
enum LoginEnv {
    private static var cached: [String: String]?
    private static let lock = NSLock()
    static var shared: [String: String] {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let env = load()
        cached = env
        return env
    }
    /// FCF / Node 升级后重新读一次登录环境（PATH 可能变了）
    static func reload() { lock.lock(); cached = nil; lock.unlock(); _ = shared }

    private static func load() -> [String: String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lic", "env -0"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        do {
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            for chunk in data.split(separator: 0) {
                guard let s = String(data: Data(chunk), encoding: .utf8), let eq = s.firstIndex(of: "=") else { continue }
                env[String(s[..<eq])] = String(s[s.index(after: eq)...])
            }
        } catch {}
        // 避免被识别为「在 Claude Code 里套娃启动」
        for k in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT"] { env.removeValue(forKey: k) }
        return env
    }

    static var claudePath: String {
        if let custom = UserDefaults.standard.string(forKey: "claudePath"), !custom.isEmpty { return custom }
        let fcf = NSString(string: "~/.fcf/bin/claude").expandingTildeInPath
        if FileManager.default.isExecutableFile(atPath: fcf) { return fcf }
        for dir in (shared["PATH"] ?? "").split(separator: ":") {
            let c = "\(dir)/claude"
            if FileManager.default.isExecutableFile(atPath: c) { return c }
        }
        return "claude"
    }
}

// 一个后台 claude 进程：stream-json 进、stream-json 出
/// 较新的 claude 才有的参数：旧版本不认识会直接启动失败，记下来以后不再传
enum OptionalFlags {
    static func unsupported(_ flag: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: "unsupportedCLIFlags") ?? []).contains(flag)
    }
    /// 从启动失败的输出里认出「不认识的参数」，记下来；返回记下的参数
    static func noteUnknown(in output: String) -> String? {
        for flag in ["--replay-user-messages", "--thinking-display", "--allow-dangerously-skip-permissions"] where output.contains(flag) && output.lowercased().contains("unknown option") {
            var list = UserDefaults.standard.stringArray(forKey: "unsupportedCLIFlags") ?? []
            if !list.contains(flag) { list.append(flag); UserDefaults.standard.set(list, forKey: "unsupportedCLIFlags") }
            return flag
        }
        return nil
    }
}

final class ClaudeProcess {
    var onEvent: (([String: Any]) -> Void)?
    var onExit: ((Int32, String) -> Void)?

    private var proc: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var stderrTail = ""
    private var stdoutTail = ""   // 非 JSON 的输出（例如 FCF 报错），退出时一起展示
    private let queue = DispatchQueue(label: "claude.io")

    var isRunning: Bool { proc?.isRunning ?? false }
    var pid: Int32? { proc?.processIdentifier }

    func start(cwd: String, resume: String?, model: String?, permissionMode: String?, addDirs: [String] = [], extraArgs: [String] = []) throws {
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                    "--verbose", "--include-partial-messages", "--permission-prompt-tool", "stdio"]
        // 回传确认：你在 Claude 忙时发的消息什么时候被收下，靠它判断还要不要继续转圈
        if !OptionalFlags.unsupported("--replay-user-messages") { args.append("--replay-user-messages") }
        // 让对话中途能切到「全部放行」：不加的话，以每步询问启动的对话切过去会被 CLI 拒绝。只是允许切换，不改变启动时的模式
        if !OptionalFlags.unsupported("--allow-dangerously-skip-permissions") { args.append("--allow-dangerously-skip-permissions") }
        if let resume { args += ["--resume", resume] }
        if let model, !model.isEmpty { args += ["--model", model] }
        if let permissionMode, !permissionMode.isEmpty { args += ["--permission-mode", permissionMode] }
        for d in addDirs { args += ["--add-dir", d] }
        args += extraArgs

        let p = Process()
        p.executableURL = URL(fileURLWithPath: LoginEnv.claudePath)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.environment = LoginEnv.shared
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            self?.queue.async { self?.consume(d) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            self?.queue.async {
                guard let self else { return }
                self.stderrTail = String((self.stderrTail + s).suffix(4000))
            }
        }
        p.terminationHandler = { [weak self] pr in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            self?.queue.async {
                guard let self else { return }
                let code = pr.terminationStatus
                let tail = [Shell.clean(self.stdoutTail), self.stderrTail].filter { !$0.isEmpty }.joined(separator: "\n")
                DispatchQueue.main.async { self.onExit?(code, tail) }
            }
        }
        try p.run()
        proc = p
        input = inPipe.fileHandleForWriting
    }

    private func consume(_ d: Data) {
        buffer.append(d)
        // 按位置往后读，一块数据处理完再统一丢掉已读部分（以前每读一行就把剩下的数据整体挪一次）
        var start = buffer.startIndex
        defer { if start > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<start) } }
        while let nl = buffer[start...].firstIndex(of: 0x0A) {
            let line = Data(buffer[start..<nl])
            start = buffer.index(after: nl)
            // FCF 会先打印一段横幅，非 JSON 行直接跳过
            guard line.first == UInt8(ascii: "{"),
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                if let s = String(data: line, encoding: .utf8) { stdoutTail = String((stdoutTail + s + "\n").suffix(2000)) }
                continue
            }
            DispatchQueue.main.async { [weak self] in self?.onEvent?(obj) }
        }
    }

    func send(_ obj: [String: Any]) {
        guard let input, var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        queue.async { try? input.write(contentsOf: data) }
    }

    /// FCF 包装脚本不会把信号转给真正的 claude，所以要把整棵进程树一起结束
    /// 结束整棵进程树。默认在后台做（查子进程要跑 pgrep，放界面线程会卡一下）；
    /// 退出 App 时用 wait: true 同步做完；completion 在进程真正退出后回到主线程调用
    func terminate(wait: Bool = false, completion: (() -> Void)? = nil) {
        try? input?.close()
        let p = proc
        proc = nil
        input = nil
        let work = {
            if let p, p.isRunning {
                let pids = Self.descendants(of: p.processIdentifier)
                p.terminate()
                for pid in pids { kill(pid, SIGTERM) }
                // 最多等 3 秒确认退出，还在就强制结束
                let deadline = Date().addingTimeInterval(3)
                while p.isRunning && Date() < deadline { usleep(50_000) }
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            }
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
        if wait { work() } else { DispatchQueue.global(qos: .utility).async(execute: work) }
    }

    static func descendants(of pid: Int32) -> [Int32] {
        let r = Shell.run("/usr/bin/pgrep", ["-P", String(pid)])
        let kids = r.output.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        return kids + kids.flatMap { descendants(of: $0) }
    }
}
