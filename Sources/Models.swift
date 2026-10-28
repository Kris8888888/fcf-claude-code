import Foundation
import AppKit

enum ItemKind { case user, assistant, thinking, tool, question, permission, notice, error, artifacts, local, login }
enum ToolState { case running, done, failed, stopped }

final class ChatItem: ObservableObject, Identifiable {
    let id = UUID()
    let kind: ItemKind
    @Published var text: String
    @Published var streaming = false
    var images: [NSImage] = []
    var files: [URL] = []
    var artifacts: [Artifact] = []
    let startedAt = Date()
    @Published var duration: TimeInterval?

    // 工具步骤
    var toolUseId = ""
    var toolName = ""
    var toolInput: [String: Any] = [:]
    @Published var toolResult: String?
    @Published var toolState: ToolState = .running
    @Published var subSteps = 0
    @Published var subLatest = ""

    // 待用户处理的请求（选择题 / 权限）
    var requestId = ""
    @Published var resolved: String?

    init(_ kind: ItemKind, _ text: String = "") {
        self.kind = kind
        self.text = text
    }

    static func tool(id: String, name: String, input: [String: Any]) -> ChatItem {
        let it = ChatItem(.tool, ToolLabel.summary(name: name, input: input))
        it.toolUseId = id
        it.toolName = name
        // 只用来显示：写大文件、大段替换时别把整份内容一直留在内存里（权限确认卡片要原样回传，不走这里）
        it.toolInput = input.mapValues { v in
            if let s = v as? String, s.count > 20000 { return String(s.prefix(20000)) + "\n…（后面还有 \(s.count - 20000) 字，没有显示）" }
            return v
        }
        return it
    }

    var inputJSON: String {
        guard let d = try? JSONSerialization.data(withJSONObject: toolInput, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "" }
        return s.replacingOccurrences(of: "\\/", with: "/")
    }
}

enum ToolLabel {
    static func summary(name: String, input: [String: Any]) -> String {
        func s(_ k: String) -> String { (input[k] as? String) ?? "" }
        func file(_ k: String) -> String { (s(k) as NSString).lastPathComponent }
        switch name {
        case "Bash":
            let d = s("description")
            return "运行：" + (d.isEmpty ? firstLine(s("command")) : d)
        case "Read": return "读取 " + file("file_path")
        case "Write": return "写入 " + file("file_path")
        case "Edit", "MultiEdit": return "修改 " + file("file_path")
        case "NotebookEdit": return "修改 " + file("notebook_path")
        case "Grep": return "搜索内容 " + s("pattern")
        case "Glob": return "查找文件 " + s("pattern")
        case "WebFetch": return "打开网页 " + s("url")
        case "WebSearch": return "搜索网页 " + s("query")
        case "Task", "Agent": return "子任务：" + s("description")
        case "Skill": return "加载技能 " + s("skill")
        case "TodoWrite", "TaskCreate", "TaskUpdate": return "更新待办"
        case "ToolSearch": return "加载工具 " + s("query")
        case "AskUserQuestion": return "向你提问"
        case "ExitPlanMode": return "提交计划"
        default:
            if name.hasPrefix("mcp__") {
                let parts = name.split(separator: "_", omittingEmptySubsequences: true)
                return "调用 " + (parts.last.map(String.init) ?? name)
            }
            return name
        }
    }

    static func firstLine(_ t: String) -> String {
        let l = t.split(separator: "\n").first.map(String.init) ?? t
        return l.count > 90 ? String(l.prefix(90)) + "…" : l
    }
}

struct SlashCommand: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let description: String
}

enum PermissionMode: String, CaseIterable, Identifiable {
    case `default`, acceptEdits, plan, bypassPermissions
    var id: String { rawValue }
    var label: String {
        switch self {
        case .default: return "每步询问"
        case .acceptEdits: return "自动改文件"
        case .plan: return "只做计划"
        case .bypassPermissions: return "全部放行"
        }
    }
}

enum ModelChoice: String, CaseIterable, Identifiable {
    case inherit = "", opus, sonnet, haiku
    var id: String { rawValue }
    var label: String {
        switch self {
        case .inherit: return "默认模型"
        case .opus: return "Opus"
        case .sonnet: return "Sonnet"
        case .haiku: return "Haiku"
        }
    }
}
