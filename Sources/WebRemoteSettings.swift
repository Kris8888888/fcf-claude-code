import SwiftUI
import AppKit

/// 设置 → 网页远程：开关、访问地址、访问码
struct WebRemoteSettings: View {
    @ObservedObject var web = WebRemote.shared
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
                } header: {
                    Text("访问码")
                } footer: {
                    Text("为了安全：只有知道访问码的人能进；连续输错 5 次要等 1 分钟。从网页发出的消息不使用「全部放行」，改文件、跑命令前都要在网页上点确认。Claude 照样在这台电脑上通过 FCF 运行。")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
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
