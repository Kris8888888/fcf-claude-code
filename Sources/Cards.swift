import SwiftUI

// Claude 向你提问（AskUserQuestion）
struct QuestionCard: View {
    @ObservedObject var item: ChatItem
    let session: ChatSession
    @State private var picks: [Int: Set<String>] = [:]
    @State private var other: [Int: String] = [:]

    var questions: [[String: Any]] { item.toolInput["questions"] as? [[String: Any]] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let r = item.resolved {
                Label("你的回答：\(r)", systemImage: "checkmark.circle").font(.system(size: fs(13))).foregroundStyle(T.muted)
            } else {
                ForEach(Array(questions.enumerated()), id: \.offset) { qi, q in question(qi, q) }
                HStack {
                    Spacer()
                    Button("跳过") { session.deny(item, reason: "用户没有回答，跳过了这个问题") }
                        .buttonStyle(.plain).foregroundStyle(T.muted).font(.system(size: fs(13)))
                    Button("提交回答") { submit() }
                        .buttonStyle(PrimaryButton())
                        .disabled(!complete)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(T.paper))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(item.resolved == nil ? T.accent.opacity(0.5) : T.line, lineWidth: 1))
    }

    @ViewBuilder func question(_ qi: Int, _ q: [String: Any]) -> some View {
        let multi = q["multiSelect"] as? Bool ?? false
        let opts = q["options"] as? [[String: Any]] ?? []
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let h = q["header"] as? String, !h.isEmpty {
                    Text(h).font(T.small).foregroundStyle(T.accent)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(T.accentSoft))
                }
                if multi { Text("可多选").font(T.small).foregroundStyle(T.muted) }
            }
            Text(q["question"] as? String ?? "").font(.system(size: fs(14), weight: .medium)).foregroundStyle(T.ink)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(opts.enumerated()), id: \.offset) { _, o in
                let label = o["label"] as? String ?? ""
                let on = picks[qi]?.contains(label) ?? false
                Button { toggle(qi, label, multi) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: multi ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle"))
                            .foregroundStyle(on ? T.accent : T.muted).font(.system(size: fs(14))).padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label).font(.system(size: fs(13), weight: .medium)).foregroundStyle(T.ink)
                            if let d = o["description"] as? String, !d.isEmpty {
                                Text(d).font(T.small).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(on ? T.accentSoft : T.sunk))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            TextField("其他（自己写）", text: Binding(get: { other[qi] ?? "" }, set: { other[qi] = $0; if !multi && !$0.isEmpty { picks[qi] = [] } }))
                .textFieldStyle(.roundedBorder).font(.system(size: fs(13)))
        }
    }

    func toggle(_ qi: Int, _ label: String, _ multi: Bool) {
        var s = picks[qi] ?? []
        if multi { if s.contains(label) { s.remove(label) } else { s.insert(label) } }
        else { s = [label]; other[qi] = "" }
        picks[qi] = s
    }

    var complete: Bool {
        questions.indices.allSatisfy { !(picks[$0] ?? []).isEmpty || !(other[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    func submit() {
        var answers: [String: String] = [:]
        for (qi, q) in questions.enumerated() {
            let opts = (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
            var vals = opts.filter { picks[qi]?.contains($0) ?? false }
            let o = (other[qi] ?? "").trimmingCharacters(in: .whitespaces)
            if !o.isEmpty { vals.append(o) }
            answers[q["question"] as? String ?? "\(qi)"] = vals.joined(separator: ", ")
        }
        session.answerQuestion(item, answers: answers)
    }
}

// 需要你确认的步骤（非「全部放行」模式下）
struct PermissionCard: View {
    @ObservedObject var item: ChatItem
    let session: ChatSession
    @State private var feedback = ""

    var isPlan: Bool { item.toolName == "ExitPlanMode" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let r = item.resolved {
                Label("\(item.text) — \(r)", systemImage: r.hasPrefix("已允许") ? "checkmark.circle" : "xmark.circle")
                    .font(.system(size: fs(13))).foregroundStyle(T.muted)
            } else {
                Text(isPlan ? "Claude 写好了计划，确认后开始动手" : "Claude 想要：\(item.text)")
                    .font(.system(size: fs(14), weight: .medium)).foregroundStyle(T.ink)
                if isPlan {
                    ScrollView { MarkdownView(text: item.toolInput["plan"] as? String ?? "").padding(4) }
                        .frame(maxHeight: 360).fixedSize(horizontal: false, vertical: true)
                } else if item.toolName == "Edit" {
                    DiffBox(old: item.toolInput["old_string"] as? String ?? "", new: item.toolInput["new_string"] as? String ?? "",
                            path: item.toolInput["file_path"] as? String ?? "")
                } else if item.toolName == "Bash" {
                    MonoBox(text: "$ " + (item.toolInput["command"] as? String ?? ""))
                } else {
                    MonoBox(text: item.inputJSON)
                }
                TextField(isPlan ? "想改哪里？写下来点「继续改计划」" : "不同意的话，可以告诉 Claude 怎么做（可不填）", text: $feedback)
                    .textFieldStyle(.roundedBorder).font(.system(size: fs(13)))
                HStack(spacing: 10) {
                    Spacer()
                    Button(isPlan ? "继续改计划" : "拒绝") { session.deny(item, reason: feedback) }
                        .buttonStyle(.plain).foregroundStyle(T.err).font(.system(size: fs(13)))
                    if !isPlan {
                        Button("本次对话都允许") { session.allow(item, always: true) }
                            .buttonStyle(.plain).foregroundStyle(T.accent).font(.system(size: fs(13)))
                    }
                    Button(isPlan ? "按计划执行" : "允许") { session.allow(item) }
                        .buttonStyle(PrimaryButton())
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(T.paper))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(item.resolved == nil ? T.accent.opacity(0.5) : T.line, lineWidth: 1))
    }
}

struct PrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fs(13), weight: .medium))
            .foregroundStyle(T.onAccent)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(enabled ? T.accent : T.muted.opacity(0.5)))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
