import SwiftUI
import AppKit

@main
struct DuihuataiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var app = AppState()
    @StateObject private var gate = LaunchGate()

    init() {
        // 不恢复上次的窗口状态：上次关窗退出后，系统会记成「没有窗口」，导致再打开时一个窗口都没有
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true, "NSQuitAlwaysKeepsWindows": false])
    }

    var body: some Scene {
        WindowGroup {
            Themed {
                if gate.phase == .passed {
                    RootView()
                } else {
                    LaunchGateView(gate: gate)
                }
            }
                .environmentObject(app)
                .background(SettingsDemoOpener())
                .frame(minWidth: 820, minHeight: 560)
                .onAppear { delegate.app = app }
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
        ThemeStore.shared.applyAppearance()
        Updater.shared.start()
        // 提前在后台取好登录环境，第一条消息不用等
        DispatchQueue.global().async { _ = LoginEnv.shared }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ n: Notification) { app?.shutdownAll() }
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
            if ProcessInfo.processInfo.environment["DUIHUATAI_SETTINGS_DEMO"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { openSettings() }
            }
        }
    }
}
