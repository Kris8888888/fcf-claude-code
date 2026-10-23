import AppKit
import UserNotifications

/// 任务完成时发系统通知（屏幕右上角），点通知回到那个对话
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    weak var app: AppState?

    func start() {
        guard Bundle.main.bundleIdentifier != nil else { return }   // 不在 .app 里（测试程序）没有通知中心
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func taskDone(_ s: ChatSession) {
        // 正看着这个对话就不打扰
        if NSApp.isActive, app?.selected == s.id { return }
        guard Bundle.main.bundleIdentifier != nil else { print("[notify] \(s.title) 任务完成"); return }
        let content = UNMutableNotificationContent()
        // 标题：「对话名 任务完成」，下面一行是 Claude 回复的第一句
        let full = app?.title(for: s.sessionId, fallback: s.title) ?? s.title     // 你改过名就用你起的名字
        let name = full.count > 30 ? String(full.prefix(29)) + "…" : full
        content.title = "\(name) 任务完成"   // 不带声音：App 在后台时原本就会响一声，免得响两次
        if let reply = s.items.last(where: { $0.kind == .assistant && !$0.text.isEmpty })?.text {
            // 去掉 Markdown 记号（标题井号、加粗星号、反引号、列表符），通知里只留文字
            let first = reply.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? reply
            var line = first.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            line = line.replacingOccurrences(of: #"^\s*(#+|[-*+]|\d+\.)\s+"#, with: "", options: .regularExpression)
            content.body = line.count > 80 ? String(line.prefix(80)) + "…" : line
        }
        content.userInfo = ["session": s.id.uuidString]
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // App 在前台（但看的是别的对话）也显示横幅
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list])
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let id = r.notification.request.content.userInfo["session"] as? String
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            if let id, let s = self.app?.sessions.first(where: { $0.id.uuidString == id }) { self.app?.selected = s.id }
        }
        done()
    }
}
