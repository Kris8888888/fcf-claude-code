import SwiftUI
import AppKit

@main
struct DuihuataiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var app = AppState()
    @StateObject private var gate = LaunchGate()
    @ObservedObject private var providers = ProviderStore.shared   // 选了别家模型服务：启动检查马上放行

    init() {
        // 不恢复上次的窗口状态：上次关窗退出后，系统会记成「没有窗口」，导致再打开时一个窗口都没有
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true, "NSQuitAlwaysKeepsWindows": false])
    }

    var body: some Scene {
        WindowGroup {
            Themed {
                // 仅用于测试：DUIHUATAI_SKIP_GATE 跳过启动检查（配合 -claudePath 假 claude）
                // 选了别家模型服务时不需要 FCF，启动检查不拦
                if gate.phase == .passed || providers.currentId != nil || ProcessInfo.processInfo.environment["DUIHUATAI_SKIP_GATE"] != nil {
                    RootView()
                } else {
                    LaunchGateView(gate: gate)
                }
            }
                .environmentObject(app)
                .background(SettingsDemoOpener())
                .background(PetHostReader())
                .frame(minWidth: 820, minHeight: 560)
                .onAppear { delegate.app = app; Notifier.shared.app = app }
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新会话") { app.newSession() }.keyboardShortcut("n")
                Button("在其他文件夹开新会话…") {
                    if let p = app.chooseFolder(start: app.lastFolder) { app.newSession(cwd: p) }
                }
                .keyboardShortcut("o")
            }
            CommandGroup(after: .newItem) {
                Button("停止当前回复") { app.current?.interrupt() }.keyboardShortcut(".")
                Button("搜索对话") { app.searchFocusToken += 1 }.keyboardShortcut("f")
                Button("状态与统计") { app.statusPanel = .status }.keyboardShortcut("i")
                Divider()
                Button("重新进行启动检查（FCF）") { gate.runChecks() }
                Button("关闭当前对话") { if let s = app.current { app.close(s) } }.keyboardShortcut("w", modifiers: [.command, .shift])
                Button("废纸篓") { app.showTrash = true }
                Button("检查更新…") { Updater.shared.check(manual: true) }
            }
        }

        Settings {
            Themed { SettingsRoot() }.environmentObject(app)
        }
        .defaultSize(width: 1040, height: 720)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var app: AppState?
    func applicationDidFinishLaunching(_ n: Notification) {
        // 后台进程意外退出时写管道不能把整个 App 带崩
        signal(SIGPIPE, SIG_IGN)
        // 仅用于测试：跑一次插件自动更新，打印结果后退出
        if ProcessInfo.processInfo.environment["DUIHUATAI_TEST_PLUGIN_UPDATE"] != nil {
            func out(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
            for p in ConfigScan.plugins() { out("\(p.key)  能自动更新=\(PluginAutoUpdate.supported(p))") }
            let before = PluginAutoUpdate.keys
            PluginAutoUpdate.set("aise-plugin@cc-marketplace", true)      // 只为测试临时勾上（会马上检查这一个）
            PluginAutoUpdate.runIfDue(force: true) {                       // 正在检查：等它跑完一起回
                out("结果：" + PluginAutoUpdate.lastSummary)
                UserDefaults.standard.set(Array(before), forKey: "pluginAutoUpdate.keys")   // 还原
                UserDefaults.standard.removeObject(forKey: "pluginAutoUpdate.lastRun")
                exit(0)
            }
            return
        }
        // 仅用于测试：打印模型菜单会显示的版本后退出
        if ProcessInfo.processInfo.environment["DUIHUATAI_PRINT_MODELS"] != nil {
            UserDefaults.standard.removeObject(forKey: "modelScan.stamp")
            print("Claude Code 本体：", ModelCatalog.claudeBinary() ?? "没找到")
            ModelCatalog.shared.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                for m in ModelChoice.allCases { print(m.label, "→", m.modelId.isEmpty ? "（默认设置）" : m.modelId) }
                print("从本体读到：", ModelCatalog.shared.scanned.joined(separator: " "))
                print("报错识别：", ModelCatalog.unavailableModel(in: "There's an issue with the selected model (claude-opus-5-9). It may not exist or you may not have access to it.") ?? "nil")
                exit(0)
            }
            return
        }
        // 仅用于测试：打印左侧历史列表的顺序后退出
        if ProcessInfo.processInfo.environment["DUIHUATAI_PRINT_HISTORY"] != nil {
            let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
            for e in History.list().prefix(15) { print(f.string(from: e.modified), e.title.prefix(30)) }
            exit(0)
        }
        AppLog.start()
        // 仅用于测试：DUIHUATAI_TEST_CCS_IMPORT 试一次从 CC Switch 导入（配合 DUIHUATAI_TEST_PROVIDER，不落盘）后退出
        if ProcessInfo.processInfo.environment["DUIHUATAI_TEST_CCS_IMPORT"] != nil {
            let r = ProviderStore.shared.importFromCCSwitch()
            FileHandle.standardError.write("\(r.note)\n".data(using: .utf8)!)
            for p in ProviderStore.shared.providers {
                let line = "\(p.name) | \(p.baseURL) | 兜底 \(p.model) | " + ModelRole.allCases.map { "\($0.label)=\(p.actual($0))" }.joined(separator: " ") + "\n"
                FileHandle.standardError.write(line.data(using: .utf8)!)
            }
            let env = ProviderStore.shared.launch(for: "test").env
            for k in env.keys.sorted() where k.hasPrefix("ANTHROPIC_") || k.hasPrefix("CLAUDE_CODE_SUBAGENT") {
                FileHandle.standardError.write("  \(k)=\(k.contains("TOKEN") ? "***" : env[k]!)\n".data(using: .utf8)!)
            }
            ProviderStore.shared.fetchModels(ProviderStore.shared.providers[0], key: "x") { ids, err in
                FileHandle.standardError.write("模型列表：\(ids) \(err ?? "")\n".data(using: .utf8)!)
                exit(0)
            }
            return
        }
        // 仅用于测试：DUIHUATAI_TEST_RELAY=主机:控制端口:访问端口，连本机模拟的中转服务器（测完要清掉 relay 开头的设置）
        if let t = ProcessInfo.processInfo.environment["DUIHUATAI_TEST_RELAY"] {
            let p = t.split(separator: ":").map(String.init)
            let r = RelayClient.shared
            r.host = p[0]; r.ctrlPort = Int(p[1]) ?? 21118; r.publicPort = Int(p[2]) ?? 8443
            r.setEnabled(true)
            FileHandle.standardError.write("SECRET=\(r.secret)\nCODE=\(WebRemote.shared.code)\n".data(using: .utf8)!)
        }
        // 仅用于测试：DUIHUATAI_SHOT_WINDOWS=目录，5 秒后把每个窗口的画面存成图片
        if let dir = ProcessInfo.processInfo.environment["DUIHUATAI_SHOT_WINDOWS"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                for (i, w) in NSApp.windows.enumerated() where w.isVisible {
                    guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/win\(i).png"))
                    // 有的窗口内容在图层里，上面那种画不出来：再按图层画一份
                    if let layer = v.layer, let ctx = CGContext(data: nil, width: Int(v.bounds.width * 2), height: Int(v.bounds.height * 2), bitsPerComponent: 8, bytesPerRow: 0,
                                                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                        ctx.scaleBy(x: 2, y: 2)
                        layer.render(in: ctx)
                        if let img = ctx.makeImage() {
                            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/win\(i)-layer.png"))
                        }
                    }
                }
            }
        }
        // 仅用于测试：DUIHUATAI_TEST_CLOSE 3 秒后关掉主窗口，再过 3 秒看 App 还在不在，然后正常退出
        if ProcessInfo.processInfo.environment["DUIHUATAI_TEST_CLOSE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                NSApp.windows.filter { $0.canBecomeMain && !($0 is NSPanel) }.forEach { $0.performClose(nil) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    AppLog.write("测试：关窗 3 秒后 App 还在运行，窗口数 \(NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }.count)")
                }
                // 这期间外面会模拟点一次程序坞图标
                DispatchQueue.main.asyncAfter(deadline: .now() + 14) {
                    AppLog.write("测试：点程序坞图标后，窗口数 \(NSApp.windows.filter { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }.count)")
                    NSApp.terminate(nil)
                }
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { n in
            guard let w = n.object as? NSWindow, w.canBecomeMain, !(w is NSPanel) else { return }
            let others = NSApp.windows.filter { $0 !== w && $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }.count
            AppLog.write("关闭了窗口「\(w.title)」，还开着 \(others) 个窗口")
        }
        // 仅用于测试：把宠物每个姿势画成图片后退出
        if let dir = ProcessInfo.processInfo.environment["DUIHUATAI_PET_SNAPSHOT"] { PetSnapshot.run(dir); exit(0) }
        ThemeStore.shared.applyAppearance()
        Updater.shared.start()
        Notifier.shared.start()
        // 提前在后台取好登录环境，第一条消息不用等
        DispatchQueue.global().async { _ = LoginEnv.shared }
    }
    // 关掉主窗口不退出：正在回答的对话、微信、网页远程、宠物都还在跑；点程序坞图标把窗口找回来。只有 ⌘Q 才真退出
    // （以前关窗即退出，按 ⌘W 或点红点就整个 App 没了，用户以为是「莫名其妙自动退出」）
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    /// 记下是谁让 App 退出的：按键、程序坞、还是别的程序发来的退出指令
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        var why = "原因不明"
        if let ev = NSAppleEventManager.shared().currentAppleEvent {
            let pid = ev.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value ?? 0
            let who = NSRunningApplication(processIdentifier: pid)?.localizedName
                ?? (pid > 0 ? Shell.run("/bin/ps", ["-o", "comm=", "-p", "\(pid)"]).output.trimmingCharacters(in: .whitespacesAndNewlines) : "")
            why = pid == 0 ? "系统发来退出指令（关机、注销或重启）" : "\(who.isEmpty ? "进程 \(pid)" : who) 发来退出指令"
        } else if let e = NSApp.currentEvent, e.type == .keyDown, e.modifierFlags.contains(.command) {
            why = "按了 ⌘\(e.charactersIgnoringModifiers?.uppercased() ?? "")"
        } else if let e = NSApp.currentEvent, e.type == .leftMouseUp || e.type == .leftMouseDown {
            why = "点了菜单里的退出"
        }
        AppLog.write("要求退出：\(why)")
        return .terminateNow
    }

    /// 窗口都关了、再点程序坞图标：把主窗口开回来（SwiftUI 默认会新开一个）
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }
    func applicationWillTerminate(_ n: Notification) {
        AppLog.write("退出")
        app?.shutdownAll()
        if PetStore.isOn { PetStore.shared.saveNowSync() }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        NavigationSplitView {
            Sidebar().navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
        } detail: {
            if let s = app.current {
                ChatView(session: s).id(s.id)
            } else {
                T.paper
            }
        }
        .tint(T.accent)
        .sheet(item: $app.statusPanel) { tab in StatusPanel(tab: tab).environmentObject(app) }
        .sheet(isPresented: $app.showLogin) { Themed { LoginSheet() } }
        .onAppear {
            // 仅用于截图验证：DUIHUATAI_STATUS_DEMO=status|usage|stats
            if let t = ProcessInfo.processInfo.environment["DUIHUATAI_STATUS_DEMO"], let tab = StatusTab(rawValue: t) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { app.statusPanel = tab }
            }
            // 仅用于截图验证：DUIHUATAI_TRASH_DEMO=1 自动打开废纸篓
            if ProcessInfo.processInfo.environment["DUIHUATAI_TRASH_DEMO"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { app.showTrash = true }
            }
        }
    }
}

/// 仅用于截图验证：带 DUIHUATAI_SETTINGS_DEMO 启动时自动打开设置窗口
struct SettingsDemoOpener: View {
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Color.clear.onAppear {
            PetSettingsOpener.action = { openSettings() }
            if ProcessInfo.processInfo.environment["DUIHUATAI_SETTINGS_DEMO"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { openSettings() }
            }
        }
    }
}
