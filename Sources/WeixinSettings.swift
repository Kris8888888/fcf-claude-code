import SwiftUI
import AppKit

/// 设置 → 微信 ClawBot：扫码绑定、连接状态、远程对话的工作文件夹
struct WeixinSettings: View {
    @ObservedObject var wx = WeixinBridge.shared
    @State private var code = ""

    var body: some View {
        Form {
            Section {
                content
            } header: {
                Text("用微信远程使唤 Claude")
            } footer: {
                Text("在微信里给 ClawBot 发消息，Claude 会在这台电脑上做事，做完把结果发回微信。电脑和这个 App 都要开着。")
            }

            if wx.account != nil {
                Section {
                    LabeledContent("工作文件夹") {
                        HStack(spacing: 8) {
                            Text(WeixinBridge.friendlyFolder(wx.workFolder)).help(wx.workFolder).foregroundStyle(T.muted).lineLimit(1).truncationMode(.middle)
                            Button("更改…") { pickFolder() }
                        }
                    }
                    LabeledContent("微信里能用的指令") {
                        Text("新对话 · 停止 · 状态 · 帮助").foregroundStyle(T.muted)
                    }
                } header: {
                    Text("远程对话")
                } footer: {
                    Text("为了安全：只有扫码绑定的这个微信号能下指令；远程对话不使用「全部放行」，改文件、跑命令前都会先发到微信里问你，回复「允许」或「拒绝」。")
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var content: some View {
        switch wx.phase {
        case .off:
            VStack(alignment: .leading, spacing: 10) {
                // 绑定确实有先后顺序，用编号
                step(1, "在手机微信里打开「我 → 设置 → 插件」，启用「微信 ClawBot」。")
                step(2, "点下面的「连接微信」，用手机微信扫出现的二维码。")
                step(3, "在手机上确认连接；如果手机上显示一个数字，把它输入到这里。")
                if !wx.note.isEmpty { Text(wx.note).font(T.small).foregroundStyle(T.muted) }
                HStack { Spacer(); Button("连接微信") { wx.beginLogin() }.buttonStyle(PrimaryButton()) }
            }
            .padding(.vertical, 4)
        case .qr(let content):
            qrBlock(content, caption: "用手机微信扫一扫")
        case .scanned:
            waiting("已扫码，请在手机上确认连接…")
        case .needCode(let retry):
            VStack(alignment: .leading, spacing: 10) {
                Text(retry ? "数字不对，请重新输入手机微信上显示的数字：" : "输入手机微信上显示的数字：").foregroundStyle(retry ? T.err : T.ink)
                HStack {
                    TextField("数字", text: $code).textFieldStyle(.roundedBorder).frame(width: 140)
                        .onSubmit { submitCode() }
                    Button("确认") { submitCode() }.buttonStyle(PrimaryButton()).disabled(code.isEmpty)
                    Spacer()
                    Button("取消") { wx.cancelLogin() }.buttonStyle(.plain).foregroundStyle(T.muted)
                }
            }
            .padding(.vertical, 4)
        case .online:
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: fs(20))).foregroundStyle(T.ok)
                VStack(alignment: .leading, spacing: 2) {
                    Text("已连接，正在等你在微信里发消息").foregroundStyle(T.ink)
                    Text(subline).font(T.small).foregroundStyle(T.muted)
                }
                Spacer()
                Button("断开") { confirmDisconnect() }
            }
            .padding(.vertical, 4)
        case .expired(let msg):
            VStack(alignment: .leading, spacing: 10) {
                Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(T.err)
                HStack { Spacer(); Button("重新扫码连接") { wx.beginLogin() }.buttonStyle(PrimaryButton()) }
            }
            .padding(.vertical, 4)
        }
    }

    private var subline: String {
        var s = "绑定于 " + (wx.account?.boundAt.formatted(date: .abbreviated, time: .shortened) ?? "")
        if let t = wx.lastMessageAt { s += "，最近一条消息 " + t.formatted(date: .omitted, time: .shortened) }
        return s
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.system(size: fs(11), weight: .semibold)).foregroundStyle(T.onAccent)
                .frame(width: 18, height: 18).background(Circle().fill(T.accent))
            Text(text).font(.system(size: fs(13))).foregroundStyle(T.ink).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func qrBlock(_ content: String, caption: String) -> some View {
        HStack(alignment: .center, spacing: 18) {
            Group {
                if let img = WeixinBridge.qrImage(content) {
                    Image(nsImage: img).interpolation(.none).resizable().frame(width: 168, height: 168)
                } else {
                    Text("二维码生成失败").foregroundStyle(T.err).frame(width: 168, height: 168)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
            VStack(alignment: .leading, spacing: 8) {
                Text(caption).font(.system(size: fs(15), weight: .semibold)).foregroundStyle(T.ink)
                Text("扫码后在手机上确认。二维码几分钟后会过期，过期会自动换新的。").font(T.small).foregroundStyle(T.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("取消") { wx.cancelLogin() }.buttonStyle(.plain).foregroundStyle(T.muted).padding(.top, 4)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }

    private func waiting(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(T.muted)
            Spacer()
            Button("取消") { wx.cancelLogin() }.buttonStyle(.plain).foregroundStyle(T.muted)
        }
        .padding(.vertical, 4)
    }

    private func submitCode() {
        guard !code.isEmpty else { return }
        wx.submitVerifyCode(code)
        code = ""
    }

    private func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.directoryURL = URL(fileURLWithPath: wx.workFolder)
        p.prompt = "用这个文件夹"
        if p.runModal() == .OK, let u = p.url { wx.workFolder = u.path }
    }

    private func confirmDisconnect() {
        let a = NSAlert()
        a.messageText = "断开微信 ClawBot？"
        a.informativeText = "断开后，手机微信就不能再控制这台电脑了。之后想用要重新扫码。"
        a.addButton(withTitle: "断开"); a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn { wx.disconnect() }
    }
}
