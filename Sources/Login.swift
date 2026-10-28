import SwiftUI
import AppKit

/// 重新登录 Claude：在内置终端里跑 `claude auth login`，和终端里 /login 是同一套流程
/// （验证码登录：不自动弹浏览器，你打开登录页拿到验证码再粘贴回来）
final class LoginController: ObservableObject {
    static let shared = LoginController()

    enum State: Equatable { case idle, running, checking, success(String), failed(String) }
    @Published var state: State = .idle
    @Published var loginURL: URL?
    let term = TerminalBuffer()
    private var pty: PtyProcess?
    /// 登录成功后要做的事（重启后台、重发刚才那条消息），由 AppState 设置
    var onSuccess: (() -> Void)?

    var running: Bool { state == .running }

    func start() {
        guard state != .running, state != .checking else { return }
        loginURL = nil
        term.cols = 1000            // 不让登录链接被折行，方便识别和复制
        term.feed(Data("\u{1B}[1m$ claude auth login\u{1B}[0m\r\n".utf8))
        let p = PtyProcess()
        p.onOutput = { [weak self] d in
            guard let self else { return }
            self.term.feed(d)
            if self.loginURL == nil, let u = Self.findURL(self.term.plainText) { self.loginURL = u }
        }
        p.onExit = { [weak self] code in
            self?.pty = nil
            self?.term.feed(Data("\r\n\u{1B}[90m[登录程序结束，退出码 \(code)]\u{1B}[0m\r\n".utf8))
            self?.checkStatus()
        }
        let q = "'" + LoginEnv.claudePath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        do {
            // 不让它自动弹浏览器：Claude 打开网页前会先看 BROWSER，指向一个什么都不做的命令。
            // 这样走的就是终端里的「验证码登录」：你自己打开登录页，网页给验证码，粘贴回来
            try p.start(command: q + " auth login", cwd: NSHomeDirectory(), cols: 1000, rows: 30, extraEnv: ["BROWSER": "/usr/bin/true"])
            pty = p
            state = .running
        } catch {
            state = .failed("登录程序启动失败：\(error.localizedDescription)")
        }
    }

    /// 把浏览器里拿到的验证码贴进去并回车
    func pasteCode() {
        guard let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return }
        pty?.write(s + "\r")
    }

    func send(_ s: String) { pty?.write(s) }

    func cancel() {
        pty?.write("\u{1B}")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.pty?.terminate(); self?.pty = nil }
        state = .idle
    }

    /// 登录程序结束后，用 `claude auth status` 确认是不是真的登上了
    func checkStatus() {
        state = .checking
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Shell.run(LoginEnv.claudePath, ["auth", "status", "--json"], timeout: 30)
            let t = r.output
            var ok = false, who = ""
            if let i = t.firstIndex(of: "{"), let d = String(t[i...]).data(using: .utf8),
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                ok = j["loggedIn"] as? Bool == true
                who = (j["email"] as? String) ?? ""
            }
            DispatchQueue.main.async {
                if ok {
                    self.state = .success(who)
                    self.onSuccess?()
                } else {
                    self.state = .failed("还没有登录成功。点「再试一次」，打开登录页拿到新的验证码再粘贴。")
                }
            }
        }
    }

    func reset() { if state != .running { state = .idle; loginURL = nil } }

    static func findURL(_ text: String) -> URL? {
        guard let r = text.range(of: #"https://[^\s]*oauth/authorize[^\s]*"#, options: .regularExpression) else { return nil }
        return URL(string: String(text[r]))
    }

    /// Claude 发回来的一条回复是不是它自己的「登录过期」提示（只认这几句固定开头的短消息，
    /// 正常回答里聊到 /login 不算）
    static func isAuthNotice(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard t.count < 300 else { return false }
        return ["login expired", "please run /login", "failed to authenticate", "invalid api key", "oauth token has expired", "not logged in"]
            .contains { t.hasPrefix($0) }
    }

    /// 报错里是不是「登录过期 / 认证失败」
    static func isAuthError(_ s: String) -> Bool {
        let t = s.lowercased()
        return t.contains("please run /login") || t.contains("oauth session expired") || t.contains("failed to authenticate")
            || t.contains("oauth token has expired") || t.contains("authentication_error") || t.contains("login expired")
            || t.contains("invalid api key") || t.contains("not logged in")
    }
}

/// 对话里的「登录已过期」卡片
struct LoginCard: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("登录已过期，需要重新登录 Claude").font(.system(size: fs(14), weight: .semibold)).foregroundStyle(T.ink)
            Text("重新登录后，刚才那条消息会自动再发一次。").font(T.small).foregroundStyle(T.muted)
            Button("重新登录") { app.showLogin = true }.buttonStyle(PrimaryButton()).padding(.top, 2)
        }
        .padding(.top, 3)
    }
}

/// 登录窗口：三步说明 + 内置终端
struct LoginSheet: View {
    @ObservedObject var login = LoginController.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("重新登录 Claude").font(.system(size: fs(18), weight: .semibold)).foregroundStyle(T.ink)
                Text("和终端里的 /login 是同一个流程，登录信息终端和这里通用。").font(T.small).foregroundStyle(T.muted)
            }
            .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 14)

            // 这三步确实有先后顺序，所以用编号
            VStack(alignment: .leading, spacing: 8) {
                step(1, "点「开始登录」，等下面出现登录链接后，点「打开登录页」。")
                step(2, "在网页上登录并确认授权，页面会显示一串验证码。")
                step(3, "复制这串验证码，回到这里点「粘贴验证码」。")
            }
            .padding(.horizontal, 22).padding(.bottom, 14)

            TerminalScreen(buf: login.term, active: login.running, onKey: { login.send($0) })
                .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
                .background(T.sunk)
                .overlay(alignment: .center) {
                    if login.state == .idle && login.term.plainText.isEmpty {
                        Text("登录过程会显示在这里").font(T.small).foregroundStyle(T.muted)
                    }
                }

            footer.padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(width: 640, height: 520)
        .background(T.paper)
        .onAppear { login.reset() }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.system(size: fs(11), weight: .semibold)).foregroundStyle(T.onAccent)
                .frame(width: 18, height: 18).background(Circle().fill(T.accent))
            Text(text).font(.system(size: fs(13))).foregroundStyle(T.ink).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 10) {
            switch login.state {
            case .success(let who):
                Label(who.isEmpty ? "已登录" : "已登录：\(who)", systemImage: "checkmark.circle.fill")
                    .font(.system(size: fs(13), weight: .medium)).foregroundStyle(T.ok)
                Spacer()
                Button("继续对话") { dismiss() }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
            case .failed(let msg):
                Text(msg).font(T.small).foregroundStyle(T.err).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("关闭") { dismiss() }.buttonStyle(.plain).foregroundStyle(T.muted)
                Button("再试一次") { login.start() }.buttonStyle(PrimaryButton())
            case .checking:
                ProgressView().controlSize(.small)
                Text("正在确认登录状态…").font(T.small).foregroundStyle(T.muted)
                Spacer()
            case .running:
                if login.loginURL == nil {
                    ProgressView().controlSize(.small)
                    Text("正在生成登录链接…").font(T.small).foregroundStyle(T.muted)
                }
                Spacer()
                Button("取消") { login.cancel() }.buttonStyle(.plain).foregroundStyle(T.muted)
                if let u = login.loginURL {
                    Button("打开登录页") { NSWorkspace.shared.open(u) }.buttonStyle(.bordered)
                    Button("粘贴验证码") { login.pasteCode() }.buttonStyle(PrimaryButton())
                }
            case .idle:
                Spacer()
                Button("关闭") { dismiss() }.buttonStyle(.plain).foregroundStyle(T.muted)
                Button("开始登录") { login.start() }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
            }
        }
        .font(.system(size: fs(13)))
    }
}
