import SwiftUI
import AppKit

struct Composer: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var session: ChatSession
    @ObservedObject var draft: DraftState
    @Environment(\.openSettings) private var openSettings
    var tall = false

    init(session: ChatSession, tall: Bool = false) {
        self.session = session
        self.draft = session.draft
        self.tall = tall
    }

    @State private var height: CGFloat = 24
    /// 手动拖出来的输入区高度（0 = 跟着内容自动长高）；最高和自动长高的上限一样
    @AppStorage("composerManualHeight") private var manualHeight: Double = 0
    @State private var dragStart: Double?
    static let maxInputHeight: CGFloat = 220
    @State private var slashIndex = 0
    @State private var focusToken = 0
    @State private var historyIndex: Int?     // ↑↓ 翻之前发过的消息
    @State private var recalling = false

    // 草稿存在会话里，切换对话不丢
    var text: String { draft.text }

    // 只在输入「/xxx」且还没打空格时弹出指令菜单
    var slashMatches: [SlashCommand] {
        guard text.hasPrefix("/"), !text.contains(" "), !text.contains("\n") else { return [] }
        let q = text.dropFirst().lowercased()
        // 窗口版自己实现的命令排前面，同名的以本地为准
        let localNames = Set(LocalCommands.all.map(\.name))
        let builtins = LocalCommands.all.map { SlashCommand(name: $0.name, description: "（\(LocalCommands.tag)）" + $0.description) }
        let all = builtins + session.commands.filter { !localNames.contains($0.name) }
        return Array(all.filter { q.isEmpty || $0.name.lowercased().contains(q) }
            .sorted { ($0.name.lowercased().hasPrefix(q) ? 0 : 1) < ($1.name.lowercased().hasPrefix(q) ? 0 : 1) }
            .prefix(8))
    }

    var body: some View {
        VStack(spacing: 6) {
            if !slashMatches.isEmpty { slashMenu }
            VStack(alignment: .leading, spacing: 8) {
                if !draft.images.isEmpty || !draft.files.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(draft.images.enumerated()), id: \.offset) { i, img in
                                ImageCard(image: img) { if i < draft.images.count { draft.images.remove(at: i) } }
                            }
                            ForEach(draft.files, id: \.self) { f in
                                FileCard(url: f) { draft.files.removeAll { $0 == f } }
                            }
                        }
                        .padding(.top, 6).padding(.trailing, 8).padding(.leading, 2)
                    }
                }
                InputTextView(text: $draft.text, height: $height,
                              placeholder: session.busy ? "Claude 在忙，可以继续输入，会排在后面处理" : "描述你想做的事，/ 调用技能和指令，可粘贴或拖入图片、文件",
                              focusToken: focusToken,
                              onSubmit: submit,
                              onImages: { draft.images += $0 },
                              onFiles: addFiles,
                              onArrow: moveSlash,
                              onTab: completeSlash,
                              onEscape: { if session.busy { session.interrupt() } else if text.hasPrefix("/") { draft.text = "" } })
                    .frame(height: min(Self.maxInputHeight, max(height, CGFloat(manualHeight), tall ? 64 : 24)))
                bar
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            .background(RoundedRectangle(cornerRadius: 16).fill(T.paper))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(T.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
            .overlay(alignment: .top) { resizeGrip }
        }
        .onChange(of: draft.text) {
            slashIndex = 0
            if recalling { recalling = false } else { historyIndex = nil }
        }
        .onChange(of: session.id) { focusToken += 1 }
    }

    /// 输入框顶边的拖动条：往上拖变高，往下拖变矮；双击恢复自动高度
    var resizeGrip: some View {
        ResizeGrip()
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { v in
                    let start = dragStart ?? max(manualHeight, Double(height))
                    if dragStart == nil { dragStart = start }
                    manualHeight = min(Double(Self.maxInputHeight), max(24, start - Double(v.translation.height)))
                }
                .onEnded { _ in dragStart = nil })
            .onTapGesture(count: 2) { manualHeight = 0 }
            .help("拖动调整输入框高度，双击恢复自动")
    }

    var bar: some View {
        HStack(spacing: 8) {
            Button(action: attach) {
                Image(systemName: "plus").font(.system(size: fs(13), weight: .semibold)).foregroundStyle(T.ink)
                    .frame(width: 28, height: 28).background(Circle().fill(T.sunk))
            }
            .buttonStyle(.plain).help("添加图片或文件")

            Menu {
                ForEach(PermissionMode.allCases) { m in
                    Button { session.setMode(m) } label: {
                        if m == session.mode { Label(m.label, systemImage: "checkmark") } else { Text(m.label) }
                    }
                }
            } label: {
                Label(session.mode.label, systemImage: session.mode == .bypassPermissions ? "bolt.shield" : "checkmark.shield")
                    .font(.system(size: fs(12))).foregroundStyle(T.ink)
            }
            .menuStyle(.borderlessButton).fixedSize().help("Claude 做事前要不要先问你")

            if session.started {
                Text(session.folderName).font(T.small).foregroundStyle(T.muted).lineLimit(1).help(session.cwd)
            }

            Spacer()

            if session.contextTokens > 0 {
                Text("上下文 \(session.contextTokens / 1000)k").font(T.small).foregroundStyle(T.muted)
                    .help("当前对话占用的上下文长度")
            }

            Menu {
                ForEach(ModelChoice.allCases) { m in
                    Button { session.setModel(m) } label: {
                        if m == session.model { Label(m.label, systemImage: "checkmark") } else { Text(m.label) }
                    }
                }
            } label: {
                Text(modelLabel).font(.system(size: fs(12))).foregroundStyle(T.ink)
            }
            .menuStyle(.borderlessButton).fixedSize()

            Button(action: session.busy && !canSend ? session.interrupt : submit) {
                Image(systemName: session.busy && !canSend ? "stop.fill" : "arrow.up")
                    .font(.system(size: fs(13), weight: .bold)).foregroundStyle(canSend || session.busy ? T.onAccent : Color.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(canSend || session.busy ? T.accent : T.muted.opacity(0.4)))
            }
            .buttonStyle(.plain)
            .help(session.busy ? "停止（Esc）" : "发送（回车）")
        }
    }

    var modelLabel: String {
        if session.model != .inherit { return session.model.label }
        if session.activeModel.isEmpty { return ModelChoice.inherit.label }
        return session.activeModel.replacingOccurrences(of: "claude-", with: "").capitalized
    }

    var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.images.isEmpty || !draft.files.isEmpty
    }

    func addFiles(_ urls: [URL]) {
        draft.add(urls)
        focusToken += 1
    }

    /// 输入框为空时按 ↑ 调出上一条发过的消息，跟终端一样
    func recall(_ d: Int) -> Bool {
        let past = session.items.filter { $0.kind == .user && !$0.text.isEmpty }.map(\.text)
        guard !past.isEmpty else { return false }
        if historyIndex == nil {
            guard d == -1, text.isEmpty else { return false }
            historyIndex = past.count
        }
        let i = historyIndex! + d
        let next = i >= past.count ? "" : past[max(0, i)]
        historyIndex = i >= past.count ? nil : max(0, i)
        // 只有文字真的变了才标记，否则 onChange 不会触发、标记会卡住
        if next != draft.text { recalling = true; draft.text = next }
        return true
    }

    var slashMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(slashMatches.enumerated()), id: \.offset) { i, c in
                Button { pick(c) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("/" + c.name).font(.system(size: fs(13), weight: .medium)).foregroundStyle(T.ink)
                        Text(c.description).font(T.small).foregroundStyle(T.muted).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(i == slashIndex ? T.accentSoft : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 10).fill(T.paper))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(T.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }

    func moveSlash(_ d: Int) -> Bool {
        let n = slashMatches.count
        guard n > 0 else { return recall(d) }
        slashIndex = (slashIndex + d + n) % n
        return true
    }

    func completeSlash() -> Bool {
        let m = slashMatches
        guard !m.isEmpty else { return false }
        draft.text = "/" + m[min(slashIndex, m.count - 1)].name + " "
        return true
    }

    func pick(_ c: SlashCommand) {
        draft.text = "/" + c.name + " "
        focusToken += 1
    }

    func submit() {
        let m = slashMatches
        if !m.isEmpty {
            let c = m[min(slashIndex, m.count - 1)]
            // 菜单开着时回车 = 选中；已经完整输入的指令直接发送
            let typed = String(text.dropFirst())
            if !m.contains(where: { $0.name == typed }) && "/" + c.name != text { pick(c); return }
        }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.images.isEmpty && draft.files.isEmpty,
           LocalCommands.handle(t, session: session, app: app, openSettings: { page in
               UserDefaults.standard.set(page.rawValue, forKey: "settingsSection")
               openSettings()
           }) {
            draft.text = ""
            historyIndex = nil
            return
        }
        guard canSend else { return }
        session.send(text: text, images: draft.images, files: draft.files)
        draft.text = ""
        draft.images = []
        draft.files = []
        historyIndex = nil
    }

    func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.directoryURL = URL(fileURLWithPath: session.cwd)
        guard panel.runModal() == .OK else { return }
        addFiles(panel.urls)
    }
}

struct ResizeGrip: View {
    @State private var hover = false
    var body: some View {
        ZStack {
            Color.clear.frame(height: 12)
            Capsule().fill(hover ? T.muted : T.line).frame(width: 36, height: 4)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .offset(y: -6)
        .onHover { h in
            hover = h
            if h { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
    }
}
