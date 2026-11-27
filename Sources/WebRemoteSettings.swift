import SwiftUI
import AppKit

/// 设置 → 网页远程：开关、访问地址、访问码
struct WebRemoteSettings: View {
    @ObservedObject var web = WebRemote.shared
    @ObservedObject var relay = RelayClient.shared
    @State private var relayTick = false
    @State private var on = WebRemote.shared.enabled
    @State private var addrs: [String] = []
    @State private var copied = ""

    var body: some View {
        Form {
            Section {
                Toggle("开启网页远程", isOn: $on)
                    .onChange(of: on) { web.setEnabled(on); refresh() }
                if !web.error.isEmpty { Text(web.error).font(T.small).foregroundStyle(T.err) }
            } footer: {
                Text("开启后，同一个网络里的其他电脑（或手机）用浏览器打开下面的地址、输入访问码，就能看和继续这台电脑上的对话。这台电脑和这个 App 要开着。")
            }

            if on {
                Section {
                    ForEach(addrs, id: \.self) { a in
                        HStack {
                            Text(a).font(.system(size: fs(14), design: .monospaced)).textSelection(.enabled)
                            Spacer()
                            Button(copied == a ? "已复制" : "复制") { copy(a) }
                        }
                    }
                    if addrs.isEmpty { Text("没找到这台电脑的网络地址，确认已连上网络。").foregroundStyle(T.muted) }
                } header: {
                    Text("在另一台电脑的浏览器里打开")
                } footer: {
                    Text("两个地址都能用：带「.local」的那个换了网络也不用改；打不开时用数字那个。")
                }

                Section {
                    HStack(alignment: .center) {
                        Text(web.code).font(.system(size: fs(28), weight: .semibold, design: .monospaced)).kerning(6).textSelection(.enabled)
                        Spacer()
                        Button("换一个") { confirmRegenerate() }
                    }
                    LabeledContent("正在看的浏览器") { Text(web.clients == 0 ? "没有" : "\(web.clients) 个").foregroundStyle(T.muted) }
                    LabeledContent("已登录的浏览器") {
                        HStack {
                            Text(loginSummary).foregroundStyle(T.muted)
                            Button("全部退出") { web.kickAll() }.disabled(web.logins.isEmpty)
                        }
                    }
                } header: {
                    Text("访问码")
                } footer: {
                    Text("为了安全：只有知道访问码的人能进；连续输错 5 次要等 1 分钟。从网页发出的消息不使用「全部放行」，改文件、跑命令前都要在网页上点确认。Claude 照样在这台电脑上通过 FCF 运行。")
                }
            }
            if on { relaySection }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
    }

    // MARK: 外网访问（经云服务器）

    @ViewBuilder private var relaySection: some View {
        Section {
            Toggle("从外网访问", isOn: Binding(get: { relay.enabled }, set: { relay.setEnabled($0); relayTick.toggle() }))
                .disabled(relay.host.trimmingCharacters(in: .whitespaces).isEmpty)
            LabeledContent("云服务器地址") {
                TextField("", text: $relay.host, prompt: Text("公网 IP 或域名"))
                    .textFieldStyle(.roundedBorder).frame(width: 200)
                    .onSubmit { relay.reconnect() }
            }
            Picker("没人用时自动关闭", selection: $relay.autoOffHours) {
                Text("1 小时后").tag(1)
                Text("4 小时后").tag(4)
                Text("8 小时后").tag(8)
                Text("24 小时后").tag(24)
                Text("不自动关闭").tag(0)
            }
            LabeledContent("端口") {
                HStack(spacing: 6) {
                    TextField("", value: $relay.ctrlPort, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 70)
                        .onSubmit { relay.reconnect() }
                    Text("电脑连接").foregroundStyle(T.muted)
                    TextField("", value: $relay.publicPort, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 70)
                    Text("浏览器访问").foregroundStyle(T.muted)
                }
            }
            if relay.enabled {
                LabeledContent("状态") {
                    switch relay.state {
                    case .connected: Label("已连上云服务器", systemImage: "checkmark.circle.fill").foregroundStyle(T.ok)
                    case .connecting: Text("正在连接…").foregroundStyle(T.muted)
                    case .failed(let why): Text(why).foregroundStyle(T.err).lineLimit(2).frame(maxWidth: 360, alignment: .trailing)
                    case .off: Text("没开").foregroundStyle(T.muted)
                    }
                }
                if let url = relay.publicURL {
                    HStack(alignment: .top, spacing: 14) {
                        if let img = WeixinBridge.qrImage(url) {
                            Image(nsImage: img).interpolation(.none).resizable().frame(width: 96, height: 96)
                                .padding(6).background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text(url).font(.system(size: fs(12), design: .monospaced)).textSelection(.enabled).lineLimit(3)
                            HStack {
                                Button(copied == url ? "已复制" : "复制网址") { copy(url) }
                                Button("换一个网址口令") { confirmNewSecret() }
                            }
                        }
                    }
                }
            }
            HStack {
                Button("导出证书…") { exportCert() }
                    .disabled(!relay.enabled)
                    .help("在你的手机、电脑上信任一次，以后浏览器就不会再提示不安全；哪天又提示了，说明有人在冒充")
                Button(copied == "script" ? "已复制" : "复制服务器安装命令") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(relay.serverScript(), forType: .string)
                    copied = "script"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == "script" { copied = "" } }
                }
                Spacer()
            }
        } header: {
            Text("在家、在外面用（经云服务器中转）")
        } footer: {
            Text("第一次用：在云服务器的防火墙里放行上面两个 TCP 端口，再把安装命令粘到服务器上以 root 执行（阿里云在控制台「命令助手」里）。浏览器第一次打开会提示证书不受信任，选继续访问即可。Claude 仍在这台电脑上运行。")
        }
    }

    private var loginSummary: String {
        guard !web.logins.isEmpty else { return "没有" }
        let outside = web.logins.values.filter(\.viaRelay).count
        let last = web.logins.values.map(\.at).max()!.formatted(date: .abbreviated, time: .shortened)
        return "\(web.logins.count) 个" + (outside > 0 ? "（外网 \(outside) 个）" : "") + "，最近 \(last)"
    }

    private func exportCert() {
        guard let url = RelayTLS.export() else {
            let a = NSAlert(); a.messageText = "还没有证书"; a.informativeText = "先打开「从外网访问」，证书会自动生成。"; a.runModal(); return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        let a = NSAlert()
        a.messageText = "证书已放到「下载」文件夹"
        a.informativeText = """
        在你自己的设备上信任一次，以后打开外网网址就不会再提示「不安全」：

        Mac：双击证书 → 钥匙串访问里双击它 → 展开「信任」→「使用此证书时」选「始终信任」。
        iPhone：用 AirDrop 或微信传到手机并打开 → 设置里点「已下载描述文件」安装 → 设置 → 通用 → 关于本机 → 证书信任设置，打开它。

        换了服务器地址后证书会重新生成，要再导出信任一次。
        """
        a.runModal()
    }

    private func confirmNewSecret() {
        let a = NSAlert()
        a.messageText = "换一个网址口令？"
        a.informativeText = "之前发出去、存下来的网址都会失效，要用新网址重新打开。"
        a.addButton(withTitle: "换一个"); a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn { relay.regenerateSecret() }
    }

    private func refresh() {
        DispatchQueue.global().async {
            let a = WebRemote.addresses()
            DispatchQueue.main.async { addrs = a }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        copied = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == s { copied = "" } }
    }

    private func confirmRegenerate() {
        let a = NSAlert()
        a.messageText = "换一个访问码？"
        a.informativeText = "已经连着的浏览器会被退出，要用新的访问码重新进入。"
        a.addButton(withTitle: "换一个"); a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn { web.regenerateCode() }
    }
}
