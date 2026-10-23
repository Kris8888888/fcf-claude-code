import SwiftUI
import AppKit

/// 从 GitHub Release 检查新版本、下载并替换自己，然后重启
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "Kris8888888/fcf-claude-code"

    struct Release: Equatable {
        let tag: String
        let version: String
        let notes: String
        let zipName: String
        let zipURL: String
        let page: String

        /// 从更新说明里挑出最多 3 条很短的要点（取每条的加粗标题，没有就取第一句）
        var highlights: [String] {
            notes.components(separatedBy: "\n").compactMap { raw -> String? in
                let l = raw.trimmingCharacters(in: .whitespaces)
                guard l.hasPrefix("- ") || l.hasPrefix("* ") else { return nil }
                let body = String(l.dropFirst(2))
                if let a = body.range(of: "**"), let b = body.range(of: "**", range: a.upperBound..<body.endIndex) {
                    return String(body[a.upperBound..<b.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "：: "))
                }
                let first = body.components(separatedBy: CharacterSet(charactersIn: "：:。，,")).first ?? body
                return first.count > 18 ? String(first.prefix(17)) + "…" : first
            }
            .filter { !$0.isEmpty }
            .prefix(3).map { $0 }
        }
    }

    /// 最近一次读到的新版本（失败引导里用它的下载页）
    @Published var lastRelease: Release?
    static var releasesPage: String { "https://github.com/\(repo)/releases/latest" }

    enum State: Equatable {
        case idle, checking, upToDate, available(Release), downloading(Release), installing, failed(String)
    }

    @Published var state: State = .idle
    @Published var dismissedVersion = UserDefaults.standard.string(forKey: "dismissedUpdate")
    private var timer: Timer?

    var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// 启动后 5 秒查一次，之后每 6 小时查一次
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.check(manual: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.check(manual: false) }
    }

    static var ghPath: String? {
        // 仅用于测试：DUIHUATAI_NO_GH=1 假装本机没有 gh，走匿名下载
        if ProcessInfo.processInfo.environment["DUIHUATAI_NO_GH"] != nil { return nil }
        let candidates = [NSString(string: "~/.local/bin/gh").expandingTildeInPath, "/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
            + (LoginEnv.shared["PATH"] ?? "").split(separator: ":").map { "\($0)/gh" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func check(manual: Bool) {
        switch state { case .checking, .downloading, .installing: return; default: break }
        state = .checking
        DispatchQueue.global(qos: .utility).async {
            let result = Self.fetchLatest()
            DispatchQueue.main.async {
                switch result {
                case .success(let r):
                    if Self.newer(r.version, than: self.current) {
                        self.lastRelease = r
                        // 自动检查时，用户点过「这个版本先不更新」就不再打扰；手动检查总是显示
                        self.state = (!manual && self.dismissedVersion == r.version) ? .idle : .available(r)
                        // 仅用于测试更新流程：DUIHUATAI_AUTOUPDATE=1 发现新版直接装
                        if ProcessInfo.processInfo.environment["DUIHUATAI_AUTOUPDATE"] != nil { self.install(r, app: nil) }
                    } else {
                        self.state = manual ? .upToDate : .idle
                        if manual { DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if self.state == .upToDate { self.state = .idle } } }
                    }
                case .failure(let e):
                    self.state = manual ? .failed(e.localizedDescription) : .idle
                }
            }
        }
    }

    struct UpdateError: LocalizedError { let msg: String; var errorDescription: String? { msg } }

    /// 私有仓库用本机已登录的 gh 读；没有 gh 时按公开仓库匿名读
    static func fetchLatest() -> Result<Release, Error> {
        var json: [String: Any]?
        if let gh = ghPath {
            let r = Shell.run(gh, ["api", "repos/\(repo)/releases/latest"], timeout: 20)
            if r.code == 0, let d = r.output.data(using: .utf8) { json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] }
        }
        if json == nil {
            // 匿名读公开仓库。用 curl + 登录环境：终端里配的代理（HTTPS_PROXY 等）也会生效，直连 GitHub 常常连不上
            let r = Shell.run("/usr/bin/curl", ["-fsSL", "--connect-timeout", "10", "--max-time", "25",
                                                "-H", "Accept: application/vnd.github+json",
                                                "https://api.github.com/repos/\(repo)/releases/latest"], timeout: 30)
            if r.code == 0, let d = r.output.data(using: .utf8) { json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] }
        }
        guard let j = json, let tag = j["tag_name"] as? String else {
            return .failure(UpdateError(msg: ghPath == nil ? "读不到版本信息：仓库是私有的，需要本机装好并登录 gh" : "读不到版本信息，检查网络或 gh 登录状态"))
        }
        let assets = (j["assets"] as? [[String: Any]]) ?? []
        guard let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let name = zip["name"] as? String else {
            return .failure(UpdateError(msg: "新版本 \(tag) 里没有安装包"))
        }
        let ver = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return .success(Release(tag: tag, version: ver, notes: j["body"] as? String ?? "", zipName: name,
                                zipURL: zip["browser_download_url"] as? String ?? "", page: j["html_url"] as? String ?? ""))
    }

    static func newer(_ a: String, than b: String) -> Bool { LaunchGate.newer(a, than: b) }

    func skip(_ r: Release) {
        dismissedVersion = r.version
        UserDefaults.standard.set(r.version, forKey: "dismissedUpdate")
        state = .idle
    }

    // MARK: 下载 → 校验 → 替换 → 重启

    func install(_ r: Release, app: AppState?) {
        state = .downloading(r)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let newApp = try Self.download(r)
                DispatchQueue.main.async {
                    self.state = .installing
                    do {
                        try Self.replaceAndRelaunch(with: newApp)
                        app?.shutdownAll()
                        NSApp.terminate(nil)
                    } catch {
                        self.state = .failed(error.localizedDescription)
                    }
                }
            } catch {
                DispatchQueue.main.async { self.state = .failed(error.localizedDescription) }
            }
        }
    }

    static func download(_ r: Release) throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("duihuatai-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent(r.zipName)
        if let gh = ghPath {
            let res = Shell.run(gh, ["release", "download", r.tag, "--repo", repo, "--pattern", r.zipName, "--dir", work.path, "--clobber"], timeout: 300)
            if res.code != 0 { try? fm.removeItem(at: zip) }
        }
        if !fm.fileExists(atPath: zip.path), !r.zipURL.isEmpty {
            // 同样走 curl + 登录环境里的代理；最多 5 分钟，失败重试 2 次，不会一直卡在「正在下载」
            let res = Shell.run("/usr/bin/curl", ["-fL", "--retry", "2", "--connect-timeout", "15", "--max-time", "300",
                                                  "-o", zip.path, r.zipURL], timeout: 320)
            if res.code != 0 { try? fm.removeItem(at: zip) }
        }
        guard fm.fileExists(atPath: zip.path) else { throw UpdateError(msg: "下载超时，连不上 GitHub（可能需要开代理）") }
        let out = work.appendingPathComponent("unzipped")
        let unzip = Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path], timeout: 120)
        guard unzip.code == 0 else { throw UpdateError(msg: "解压失败：\(unzip.output)") }
        guard let appName = (try fm.contentsOfDirectory(atPath: out.path)).first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError(msg: "安装包里没有找到 App")
        }
        let newApp = out.appendingPathComponent(appName)
        // 必须是同一个 App，版本号也要对得上，防止装错
        let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else { throw UpdateError(msg: "安装包不是这个 App，已停止") }
        guard info?["CFBundleShortVersionString"] as? String == r.version else { throw UpdateError(msg: "安装包版本和发布版本不一致，已停止") }
        let sig = Shell.run("/usr/bin/codesign", ["--verify", "--deep", newApp.path], timeout: 60)
        guard sig.code == 0 else { throw UpdateError(msg: "安装包签名校验没通过：\(sig.output)") }
        _ = Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path], timeout: 30)
        return newApp
    }

    /// 写一个小脚本：等当前 App 退出 → 换上新版（失败就还原旧版）→ 重新打开
    /// 是不是从只读位置运行：直接在 dmg 安装盘里打开，或从「下载」里打开被系统挪到临时位置
    static var runningFromReadOnlyLocation: Bool {
        let p = Bundle.main.bundlePath
        return p.hasPrefix("/Volumes/") || p.contains("/AppTranslocation/")
    }

    /// 新版装到哪：正常情况替换自己；从只读位置运行时装进「应用程序」
    static var installTarget: String {
        // 仅用于测试：DUIHUATAI_INSTALL_DIR 把「应用程序」换成别的目录
        let apps = ProcessInfo.processInfo.environment["DUIHUATAI_INSTALL_DIR"] ?? "/Applications"
        return runningFromReadOnlyLocation ? apps + "/" + (Bundle.main.bundlePath as NSString).lastPathComponent : Bundle.main.bundlePath
    }

    /// 写一个小脚本：等当前 App 退出 → 换上新版（失败就还原旧版）→ 重新打开
    static func replaceAndRelaunch(with newApp: URL) throws {
        let target = installTarget
        let parent = (target as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: parent) else {
            throw UpdateError(msg: "没有权限写入「\(parent == "/Applications" ? "应用程序" : parent)」")
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("duihuatai-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let script = work.appendingPathComponent("install.sh")
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let body = """
        #!/bin/bash
        for i in $(seq 1 100); do kill -0 \(pid) 2>/dev/null || break; sleep 0.2; done
        T=\(q(target))
        rm -rf "$T.old"
        if [ -e "$T" ]; then mv "$T" "$T.old" || exit 1; fi
        if /usr/bin/ditto \(q(newApp.path)) "$T"; then
          rm -rf "$T.old"
          /usr/bin/xattr -dr com.apple.quarantine "$T" 2>/dev/null
        else
          rm -rf "$T"; [ -e "$T.old" ] && mv "$T.old" "$T"
        fi
        open "$T"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "nohup /bin/bash \(q(script.path)) >/dev/null 2>&1 &"]
        try p.run()
        p.waitUntilExit()
    }

    /// 从安装盘里直接打开时：把自己装进「应用程序」并从那里重新打开
    func moveToApplications(app: AppState?) {
        do {
            try Self.replaceAndRelaunch(with: Bundle.main.bundleURL)
            app?.shutdownAll()
            NSApp.terminate(nil)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

// MARK: 侧栏里的更新卡片（只在有事可说时出现）

struct UpdateBanner: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var up = Updater.shared
    @State private var showNotes = false
    @State private var showGuide = false
    @State private var confirmBusy = false

    var body: some View {
        switch up.state {
        case .available(let r):
            card {
                HStack(alignment: .firstTextBaseline) {
                    Text("新版本 \(r.version)").font(.system(size: fs(13), weight: .semibold)).foregroundStyle(T.ink)
                    Text("当前 \(up.current)").font(.system(size: fs(11))).foregroundStyle(T.muted)
                    Spacer()
                    Button { up.skip(r) } label: { Image(systemName: "xmark").font(.system(size: fs(10), weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(T.muted).help("这个版本先不更新")
                }
                // 这次改了什么：最多 3 条，一行一条
                if !r.highlights.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(r.highlights, id: \.self) { h in
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Circle().fill(T.accent).frame(width: 4, height: 4).offset(y: -2)
                                Text(h).font(.system(size: fs(12))).foregroundStyle(T.ink.opacity(0.8)).lineLimit(1)
                            }
                        }
                    }
                }
                HStack(spacing: 10) {
                    Button("更新内容") { showNotes = true }.buttonStyle(.plain).font(.system(size: fs(12))).foregroundStyle(T.accent)
                        .popover(isPresented: $showNotes) { notes(r) }
                    Spacer()
                    Button("更新并重启") {
                        if app.sessions.contains(where: { $0.busy }) { confirmBusy = true } else { up.install(r, app: app) }
                    }
                    .buttonStyle(PrimaryButton())
                }
            }
            .alert("有对话正在进行", isPresented: $confirmBusy) {
                Button("仍然更新") { up.install(r, app: app) }
                Button("稍后", role: .cancel) {}
            } message: { Text("更新会重启 App，进行中的回复会被中断，对话记录都会保留。") }
        case .downloading(let r):
            card {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在下载 \(r.version)…").font(.system(size: fs(12))).foregroundStyle(T.ink)
                }
            }
        case .installing:
            card { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在安装，马上重启…").font(.system(size: fs(12))).foregroundStyle(T.ink) } }
        case .checking:
            EmptyView()
        case .upToDate:
            card { Label("已经是最新版本 \(up.current)", systemImage: "checkmark.circle").font(.system(size: fs(12))).foregroundStyle(T.ok) }
        case .failed(let msg):
            failedCard(msg)
        case .idle:
            EmptyView()
        }
    }

    /// 自动更新失败：说明原因 + 去 GitHub 手动下载 + 三步引导（教大家下对安装包）
    func failedCard(_ msg: String) -> some View {
        card {
            HStack(alignment: .firstTextBaseline) {
                Text("自动更新没成功").font(.system(size: fs(13), weight: .semibold)).foregroundStyle(T.ink)
                Spacer()
                Button { up.state = .idle } label: { Image(systemName: "xmark").font(.system(size: fs(10), weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(T.muted)
            }
            Text(msg).font(.system(size: fs(11))).foregroundStyle(T.err).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("重试") { up.check(manual: true) }.buttonStyle(.plain).font(.system(size: fs(12))).foregroundStyle(T.accent)
                Spacer()
                Button("去 GitHub 下载") {
                    NSWorkspace.shared.open(URL(string: up.lastRelease?.page ?? Updater.releasesPage)!)
                    showGuide = true
                }
                .buttonStyle(PrimaryButton())
            }
            DisclosureGroup(isExpanded: $showGuide) {
                VStack(alignment: .leading, spacing: 6) {
                    guideStep(1, "在打开的网页里往下找到「Assets」")
                    guideStep(2, "点名字带「dmg 安装包」的那个下载。不要下 zip 和 Source code")
                    guideStep(3, "打开下载的 dmg，把 App 拖进「应用程序」，提示已存在时选「替换」")
                }
                .padding(.top, 4)
            } label: {
                Text("怎么下载新版").font(.system(size: fs(12))).foregroundStyle(T.muted)
            }
        }
    }

    func guideStep(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(n)").font(.system(size: fs(11), weight: .semibold)).foregroundStyle(T.onAccent)
                .frame(width: 16, height: 16).background(Circle().fill(T.accent))
            Text(text).font(.system(size: fs(12))).foregroundStyle(T.ink).fixedSize(horizontal: false, vertical: true)
        }
    }

    func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) { c() }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(T.accentSoft))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(T.accent.opacity(0.35), lineWidth: 1))
    }

    func notes(_ r: Updater.Release) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(r.version) 更新内容").font(.system(size: fs(14), weight: .semibold)).foregroundStyle(T.ink)
            ScrollView { MarkdownView(text: r.notes.isEmpty ? "这个版本没有写更新说明。" : r.notes) }.frame(maxHeight: 320)
        }
        .padding(16).frame(width: 380)
    }
}
