import SwiftUI
import AppKit

/// 设置 → 关于与更新：版本信息、检查更新、更新走哪条线路
struct AboutSettings: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var up = Updater.shared
    @State private var proxy: String?
    @State private var proxyLoaded = false

    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }

    var body: some View {
        Form {
            // 顶部：像「关于本机」那样，一眼看到是哪个 App、哪个版本
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("FCF启动claude code").font(.system(size: fs(17), weight: .semibold)).foregroundStyle(T.ink)
                        Text("版本 \(up.current)" + (build.isEmpty ? "" : "（\(build)）")).font(.system(size: fs(13))).foregroundStyle(T.muted)
                            .textSelection(.enabled)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Section {
                statusRow
            } header: {
                Text("更新")
            } footer: {
                Text("每次打开 App 和之后每 6 小时会自动检查一次，有新版本时左下角会出现更新卡片。")
            }

            Section {
                LabeledContent("线路") {
                    Text(proxyLoaded ? (proxy.map { "经 FCF 代理（\($0)）" } ?? "没找到 FCF 代理，直接连接") : "正在读取…")
                        .foregroundStyle(T.muted).textSelection(.enabled)
                }
                if !up.route.isEmpty {
                    LabeledContent("上次实际使用") { Text(up.route).foregroundStyle(T.muted) }
                }
                Button("在 GitHub 查看所有版本和更新说明") { NSWorkspace.shared.open(URL(string: Updater.releasesPage)!) }
                    .buttonStyle(.link)
            } header: {
                Text("下载")
            } footer: {
                Text("检查更新和下载安装包都优先走 FCF 的代理，公司网络直连 GitHub 常常连不上；代理不通时才直接连接。")
            }
        }
        .formStyle(.grouped)
        .task {
            let v = await Task.detached { Updater.fcfProxy() }.value
            proxy = v; proxyLoaded = true
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch up.state {
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在检查…").foregroundStyle(T.muted)
                Spacer()
            }
        case .available(let r):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("有新版本 \(r.version)").font(.system(size: fs(14), weight: .semibold)).foregroundStyle(T.ink)
                    Spacer()
                    Button("立即更新") { confirmAndInstall(r) }.buttonStyle(PrimaryButton())
                }
                ForEach(r.highlights, id: \.self) { h in
                    Label(h, systemImage: "sparkle").font(.system(size: fs(12))).foregroundStyle(T.muted)
                }
            }
        case .downloading(let r):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在下载 \(r.version)（经 FCF 代理，几十秒）…").foregroundStyle(T.muted)
                Spacer()
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在安装，马上自动重新打开…").foregroundStyle(T.muted)
                Spacer()
            }
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 8) {
                Text(msg).font(.system(size: fs(13))).foregroundStyle(T.err).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("去 GitHub 下载") { NSWorkspace.shared.open(URL(string: up.lastRelease?.page ?? Updater.releasesPage)!) }
                    Spacer()
                    Button("重新检查") { up.state = .idle; up.check(manual: true) }.buttonStyle(PrimaryButton())
                }
            }
        case .idle, .upToDate:
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(upToDateText).foregroundStyle(T.ink)
                    if let t = up.lastChecked {
                        Text("上次检查：" + t.formatted(date: .omitted, time: .shortened)).font(T.small).foregroundStyle(T.muted)
                    }
                }
                Spacer()
                Button("检查更新") { up.check(manual: true) }.buttonStyle(PrimaryButton())
            }
        }
    }

    private var upToDateText: String {
        guard let latest = up.latestKnown else { return "还没检查过" }
        return Updater.newer(latest, than: up.current) ? "有新版本 \(latest)（之前选了先不更新）" : "已是最新版本"
    }

    /// 有对话正在进行时提醒一下：更新会重启 App
    private func confirmAndInstall(_ r: Updater.Release) {
        if app.sessions.contains(where: \.busy) {
            let a = NSAlert()
            a.messageText = "Claude 还在工作，现在更新会打断它"
            a.informativeText = "更新会关闭并重新打开 App。可以等它做完再更新。"
            a.addButton(withTitle: "仍然更新"); a.addButton(withTitle: "稍后")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        up.install(r, app: app)
    }
}
