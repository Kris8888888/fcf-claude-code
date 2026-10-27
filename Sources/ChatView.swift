import SwiftUI
import AppKit
import Combine

struct ChatView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var session: ChatSession
    @State private var dropping = false

    static func folderLabel(_ cwd: String) -> String {
        let home = NSHomeDirectory()
        if cwd == home { return "在个人文件夹（\((home as NSString).lastPathComponent)）里工作" }
        let name = (cwd as NSString).lastPathComponent
        let parent = ((cwd as NSString).deletingLastPathComponent as NSString).lastPathComponent
        // 带上上一级，方便认出是哪里的同名文件夹，比如「桌面 › 报价单」
        let parentName = ["Desktop": "桌面", "Documents": "文稿", "Downloads": "下载"][parent] ?? parent
        return cwd.hasPrefix(home) && !parentName.isEmpty && parentName != (home as NSString).lastPathComponent
            ? "在「\(parentName) › \(name)」文件夹里工作" : "在「\(name)」文件夹里工作"
    }

    var body: some View {
        Group {
            if session.loading {
                ProgressView("正在载入对话记录…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.items.isEmpty {
                EmptyChat(session: session)
            } else {
                VStack(spacing: 0) {
                    Transcript(session: session)
                    Composer(session: session)
                        .frame(maxWidth: 800)
                        .padding(.horizontal, 24).padding(.bottom, 16).padding(.top, 4)
                }
            }
        }
        // 背景铺满整个右侧，窗口拉宽时两边不会露出系统默认灰
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(T.paper)
        .toolbarBackground(T.paper, for: .windowToolbar)
        // 文件拖到窗口任意位置都能加为附件
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            session.draft.add(files)
            return true
        } isTargeted: { dropping = $0 }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 14).stroke(T.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(RoundedRectangle(cornerRadius: 14).fill(T.accentSoft.opacity(0.5)))
                    .overlay(Label("松手添加为附件", systemImage: "paperclip").font(.system(size: fs(15), weight: .medium)).foregroundStyle(T.accent))
                    .padding(12).allowsHitTesting(false)
            }
        }
        .navigationTitle(app.title(for: session.sessionId, fallback: session.title))
        // 以前显示「~」这类路径简写，改成直白的说法；工具栏的文件夹按钮能直接在访达里打开
        .navigationSubtitle(Self.folderLabel(session.cwd))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd)) } label: {
                    Label("在访达中打开工作文件夹", systemImage: "folder")
                }
                .help("在访达中打开：" + session.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "个人文件夹"))
            }
        }
    }
}

// MARK: 空对话：输入框居中

struct EmptyChat: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var session: ChatSession
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("想让 Claude 做点什么？")
                .font(.system(size: fs(26), weight: .semibold))
                .foregroundStyle(T.ink)
            HStack(spacing: 10) {
                Button { app.pickFolder(for: session) } label: {
                    Chip(icon: "folder", text: session.folderName, tint: T.ink)
                }
                .buttonStyle(.plain)
                .help(session.cwd)
                Text("Claude 会在这个文件夹里读写文件").font(T.small).foregroundStyle(T.muted)
            }
            Composer(session: session, tall: true)
                .frame(maxWidth: 720)
            Text("回车发送，Shift+回车换行。输入 / 调用技能，! 开头直接运行命令，↑ 调出上一条消息。")
                .font(T.small).foregroundStyle(T.muted)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
    }
}

// MARK: 对话记录

struct Transcript: View {
    @ObservedObject var session: ChatSession
    @State private var atBottom = true
    @State private var viewport: CGFloat = 0
    @State private var openGroups: Set<UUID> = []
    /// 进对话时只先画最近这些段：几百条一起排，跳到底部时会先空白一阵
    @State private var shown = 60

    /// 连续 4 步以上的工具/思考折叠成一组，长任务不刷屏
    enum Row: Identifiable {
        case single(ChatItem)
        case group([ChatItem])
        case copy([ChatItem])       // 一轮回复结束后的「复制」按钮，带着这一轮所有的回复
        var id: String {
            switch self {
            case .single(let i): return i.id.uuidString
            case .group(let g): return g[0].id.uuidString
            case .copy(let r): return "copy-" + r[0].id.uuidString
            }
        }
    }

    var rows: [Row] {
        var out: [Row] = []
        var run: [ChatItem] = []
        func flush() {
            if run.filter({ $0.kind == .tool }).count >= 4 { out.append(.group(run)) } else { out += run.map { .single($0) } }
            run = []
        }
        var replies: [ChatItem] = []
        func endTurn() {
            if !replies.isEmpty { out.append(.copy(replies)) }
            replies = []
        }
        for it in session.items {
            if it.kind == .user { flush(); endTurn() }
            if it.kind == .assistant && !it.text.isEmpty { replies.append(it) }
            if it.kind == .tool || it.kind == .thinking { run.append(it) } else { flush(); out.append(.single(it)) }
        }
        flush()
        // 最后一轮还在回复时先不放复制按钮，答完再出现
        if !session.busy { endTurn() }
        return out
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let all = rows
                    if all.count > shown {
                        Button {
                            // 展开后停在原来看的位置，不跳走
                            let keep = all[all.count - shown].id
                            shown += 80
                            DispatchQueue.main.async { proxy.scrollTo(keep, anchor: .top) }
                        } label: {
                            Text("显示更早的内容（还有 \(all.count - shown) 段）")
                                .font(.system(size: fs(12))).foregroundStyle(T.muted)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Capsule().fill(T.line.opacity(0.5)))
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 16)
                    }
                    ForEach(all.suffix(shown)) { row in
                        switch row {
                        case .single(let item):
                            ItemRow(item: item, session: session).id(row.id)
                        case .group(let g):
                            StepGroup(items: g, open: Binding(
                                get: { openGroups.contains(g[0].id) },
                                set: { if $0 { openGroups.insert(g[0].id) } else { openGroups.remove(g[0].id) } }))
                            .id(row.id)
                        case .copy(let replies):
                            Rail { CopyReplyButton(replies: replies) }.id(row.id)
                        }
                    }
                    // 卡住时一定要显示提示：最容易卡住的就是「思考中」或回复写到一半，这时最后一条正在输出
                    if session.busy && (session.stalled || !(session.items.last?.streaming ?? false)) {
                        BusyRow(session: session).id("busy")
                    }
                }
                .frame(maxWidth: 800)
                // 底部标记放在懒加载列表之外，滚得再远也一直在，判断才准
                Color.clear.frame(height: 12).id("bottom")
                    .background(GeometryReader { g in
                        Color.clear.preference(key: BottomOffsetKey.self, value: g.frame(in: .named("transcript")).minY)
                    })
                }
                .padding(.horizontal, 24).padding(.top, 20)
                .frame(maxWidth: .infinity)
            }
            .coordinateSpace(name: "transcript")
            .background(GeometryReader { g in Color.clear.onAppear { viewport = g.size.height }.onChange(of: g.size.height) { viewport = g.size.height } })
            // 离底部 150pt 以内都算「在底部」，流式输出变长也不会误判成你在往上翻
            .onPreferenceChange(BottomOffsetKey.self) { y in
                let v = y - viewport < 150
                if v != atBottom { atBottom = v }
            }
            .overlay(alignment: .bottom) {
                if !atBottom {
                    Button { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } } label: {
                        Image(systemName: "arrow.down").font(.system(size: fs(13), weight: .bold)).foregroundStyle(T.ink)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(T.paper))
                            .overlay(Circle().stroke(T.line, lineWidth: 1))
                            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                    }
                    .buttonStyle(.plain).padding(.bottom, 10).help("回到最新")
                    .transition(.opacity)
                }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            // 只有停在底部时才跟随新内容；你往上翻看时不会被拽下去。自己发消息总会回到底部
            .onChange(of: session.items.count) {
                if atBottom || session.items.last?.kind == .user { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onReceive(session.streamTicks) { if atBottom { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: session.busy) { if atBottom { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
    }
}

struct BottomOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// 收起状态下也要跟着组里每一步的状态变（并行工具、中间某步出错）
final class GroupWatch: ObservableObject {
    private var subs: [AnyCancellable] = []
    private var ids: [UUID] = []
    func watch(_ items: [ChatItem]) {
        let newIds = items.map(\.id)
        guard newIds != ids else { return }
        ids = newIds
        subs = items.map { $0.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() } }
    }
}

struct StepGroup: View {
    let items: [ChatItem]
    @Binding var open: Bool
    @StateObject private var watch = GroupWatch()
    var last: ChatItem { items[items.count - 1] }

    init(items: [ChatItem], open: Binding<Bool>) {
        self.items = items
        self._open = open
    }

    var running: Bool { items.contains { $0.streaming || ($0.kind == .tool && $0.toolState == .running) } }
    var failed: Int { items.filter { $0.kind == .tool && $0.toolState == .failed }.count }
    var tools: Int { items.filter { $0.kind == .tool }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rail(node: failed > 0 ? T.err : T.muted, spinning: running) {
                Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                    HStack(spacing: 6) {
                        Text("执行了 \(tools) 个步骤").font(.system(size: fs(13), weight: .medium)).foregroundStyle(T.ink.opacity(0.78))
                        if failed > 0 { Text("\(failed) 个出错").font(T.small).foregroundStyle(T.err) }
                        if !open {
                            Text(running ? "正在：" + last.text : "最后：" + last.text).font(T.small).foregroundStyle(T.muted)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        Image(systemName: "chevron.right").font(.system(size: fs(9), weight: .semibold))
                            .foregroundStyle(T.muted).rotationEffect(.degrees(open ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(open ? "收起这些步骤" : "展开查看每一步")
            }
            .onAppear { watch.watch(items) }
            .onChange(of: items.count) { watch.watch(items) }
            if open {
                // 展开后的步骤挂在同一条活动轨上
                ForEach(items) { it in
                    if it.kind == .thinking { ThinkingRow(item: it) } else { ToolRow(item: it) }
                }
            }
        }
    }
}

/// 活动轨：Claude 一侧的所有内容挂在左侧一条细线上，工具步骤是线上的节点
struct Rail<Content: View>: View {
    var node: Color? = nil
    var spinning = false
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .top) {
                Rectangle().fill(T.line).frame(width: 1.5).frame(maxHeight: .infinity)
                if spinning {
                    ProgressView().controlSize(.mini).frame(width: 12, height: 12).padding(.top, 9)
                        .background(Circle().fill(T.paper))
                } else if let node {
                    Circle().fill(node).frame(width: 7, height: 7).padding(.top, 11)
                        .background(Circle().fill(T.paper).frame(width: 13, height: 13).padding(.top, 8))
                }
            }
            .frame(width: 14)
            content.padding(.vertical, 6)
            Spacer(minLength: 0)
        }
    }
}

/// 一轮回复末尾的「复制」：把这一轮 Claude 写的所有内容按 Markdown 原文复制，贴到别处格式不乱
struct CopyReplyButton: View {
    let replies: [ChatItem]
    @State private var copied = false
    @State private var hover = false

    var body: some View {
        Button {
            let md = replies.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(md, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: copied ? "checkmark" : "square.on.square")
                    .font(.system(size: fs(13), weight: .medium))
                if copied { Text("已复制").font(.system(size: fs(12))) }
            }
            .foregroundStyle(copied ? T.ok : (hover ? T.ink : T.muted))
            .padding(.horizontal, copied ? 9 : 0)
            .frame(minWidth: 28, minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(hover || copied ? T.line.opacity(0.6) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("复制（Markdown 格式）")
        .animation(.easeOut(duration: 0.15), value: copied)
        .padding(.leading, -7)      // 图标和上面的正文左边对齐
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BusyRow: View {
    @ObservedObject var session: ChatSession
    var body: some View {
        if session.stalled {
            // 卡住时转圈停下、节点变警示色：不再假装在工作
            Rail(node: T.err) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("已经 \(max(1, Int(Date().timeIntervalSince(session.lastEventAt) / 60))) 分钟没有任何动静，可能卡住了").font(T.small).foregroundStyle(T.ink)
                    Text("网络短暂断开时 Claude 会自己重试，不会走到这一步；等了这么久还没反应，建议重新连接，Claude 会接着刚才的进度做。")
                        .font(T.small).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 14) {
                        Button("重新连接并继续") { session.reconnect() }.buttonStyle(PrimaryButton())
                        Button("停止") { session.stopStalled() }
                            .buttonStyle(.plain).foregroundStyle(T.muted).font(.system(size: fs(13)))
                    }
                    .padding(.top, 2)
                }
                .padding(.top, 3)
            }
        } else {
            Rail(spinning: true) {
                // 超过 1 分钟没新消息时，显示等了多久，对话很长时说明为什么慢，免得以为卡死了
                TimelineView(.periodic(from: .now, by: 15)) { ctx in
                    let waited = Int(ctx.date.timeIntervalSince(session.lastEventAt) / 60)
                    let base = session.status.isEmpty ? "处理中" : session.status
                    let hint = waited < 1 ? "" : "  ·  已等 \(waited) 分钟" + (session.contextTokens > 300_000 ? "（这个对话很长，每次回复都要先读完全部内容，会慢一些）" : "")
                    Text(base + hint).font(T.small).foregroundStyle(T.run).padding(.top, 3)
                }
            }
        }
    }
}

struct ItemRow: View {
    @ObservedObject var item: ChatItem
    let session: ChatSession

    var body: some View {
        switch item.kind {
        case .user: UserBubble(item: item, session: session)
        case .assistant:
            Rail {
                MarkdownView(text: item.text.isEmpty && item.streaming ? "…" : item.text, streaming: item.streaming)
                    .foregroundStyle(T.ink)
                    .contextMenu {
                        Button("复制这段回复") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(item.text, forType: .string)
                        }
                    }
            }
        case .thinking: ThinkingRow(item: item)
        case .artifacts: Rail { ArtifactsBlock(item: item, session: session) }
        case .local: Rail(node: T.accent) { LocalCard(item: item) }
        case .tool: ToolRow(item: item)
        case .question: Rail(node: T.accent) { QuestionCard(item: item, session: session) }
        case .permission: Rail(node: T.accent) { PermissionCard(item: item, session: session) }
        case .notice:
            Rail {
                Text(item.text).font(T.small).foregroundStyle(T.muted).textSelection(.enabled)
                    .lineLimit(6)
            }
        case .error:
            Rail(node: T.err) {
                Text(item.text).font(T.small).foregroundStyle(T.err).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(T.err.opacity(0.08)))
            }
        }
    }
}

struct UserBubble: View {
    @ObservedObject var item: ChatItem
    let session: ChatSession
    var body: some View {
        HStack {
            Spacer(minLength: 80)
            VStack(alignment: .trailing, spacing: 6) {
                if !item.images.isEmpty || !item.files.isEmpty {
                    FlowRow(spacing: 8) {
                        ForEach(Array(item.images.enumerated()), id: \.offset) { _, img in ImageCard(image: img, size: 72) }
                        ForEach(item.files, id: \.self) { f in FileCard(url: f) }
                    }
                }
                if !item.text.isEmpty {
                    Text(item.text).font(T.body).foregroundStyle(T.ink).lineSpacing(3)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 14).fill(T.accentSoft))
                }
            }
        }
        .padding(.vertical, 12)
        .contextMenu {
            Button("复制") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.text, forType: .string)
            }
            Button("放回输入框修改后重发") {
                session.draft.text = item.text
                session.draft.files = item.files
                session.draft.images = item.images
            }
        }
    }
}

// MARK: 文件产物

struct ArtifactsBlock: View {
    @ObservedObject var item: ChatItem
    let session: ChatSession
    @State private var showAll = false

    /// 整个对话里的所有产物（同一文件只算一次，以最后一次为准）
    var all: [Artifact] {
        var seen = Set<String>(), out: [Artifact] = []
        for it in session.items.reversed() where it.kind == .artifacts {
            for a in it.artifacts.reversed() where seen.insert(a.url.path).inserted { out.append(a) }
        }
        return out
    }

    var body: some View {
        let arts = item.artifacts
        let everything = all
        let total = everything.count
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(arts.prefix(3)), id: \.self) { a in ArtifactCard(artifact: a) }
            if arts.count > 3 || total > arts.count {
                Button { showAll = true } label: {
                    HStack(spacing: 4) {
                        Text(arts.count > 3 && total == arts.count ? "还有 \(arts.count - 3) 个，查看全部产物（\(total)）" : "查看所有产物（\(total)）")
                        Image(systemName: "chevron.right").font(.system(size: fs(10), weight: .semibold))
                    }
                    .font(.system(size: fs(13))).foregroundStyle(T.muted).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showAll, arrowEdge: .bottom) { AllArtifacts(artifacts: everything) }
            }
        }
        .padding(.vertical, 4)
    }
}

struct AllArtifacts: View {
    let artifacts: [Artifact]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("这个对话的所有产物（\(artifacts.count)）").font(.system(size: fs(14), weight: .semibold)).foregroundStyle(T.ink)
            ScrollView {
                VStack(spacing: 8) { ForEach(artifacts, id: \.self) { ArtifactCard(artifact: $0) } }
            }
            .frame(maxHeight: 420)
        }
        .padding(16)
        .frame(width: 520)
        .background(T.paper)
    }
}

// MARK: 思考过程（可折叠）

struct ThinkingRow: View {
    @ObservedObject var item: ChatItem
    @State private var open: Bool?

    var hasText: Bool { !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    // 没手动点过时：思考中展开，结束后自动收起
    @AppStorage("thinkingExpand") private var expand = "auto"
    var isOpen: Bool {
        if let open { return open }
        switch expand { case "collapsed": return false; case "expanded": return true; default: return item.streaming }
    }

    var label: String {
        if item.streaming { return "思考中…" }
        if let d = item.duration { return d < 1 ? "思考了不到 1 秒" : "思考了 \(Int(d.rounded())) 秒" }
        return "思考过程"
    }

    var body: some View {
        Rail(node: T.muted.opacity(0.6), spinning: item.streaming) {
            VStack(alignment: .leading, spacing: 6) {
                Button { withAnimation(.easeOut(duration: 0.15)) { open = !isOpen } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "brain").font(.system(size: fs(11))).foregroundStyle(T.muted)
                        Text(label).font(.system(size: fs(13))).foregroundStyle(T.muted)
                        Image(systemName: "chevron.right").font(.system(size: fs(9), weight: .semibold))
                            .foregroundStyle(T.muted).rotationEffect(.degrees(isOpen ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isOpen ? "收起思考过程" : "展开思考过程")
                if isOpen {
                    Group {
                        if hasText {
                            Text(item.text).font(.system(size: fs(13))).foregroundStyle(T.muted).lineSpacing(3)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(item.streaming ? "Claude 正在想……" : "这次的思考内容没有显示，只记录了用时。想看思考内容，到「设置 → 思维链」选「显示思考摘要」。")
                                .font(T.small).foregroundStyle(T.muted.opacity(0.8))
                        }
                    }
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(T.line).frame(width: 2) }
                }
            }
        }
    }
}

/// 自动换行的横排（附件卡片用）
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { y += rowH + spacing; x = 0; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: widest, height: y + rowH)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > b.minX && x + s.width > b.maxX { y += rowH + spacing; x = b.minX; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

// MARK: 工具步骤

struct ToolRow: View {
    @ObservedObject var item: ChatItem
    @State private var open = false

    var color: Color {
        switch item.toolState {
        case .running: return T.run
        case .done: return T.muted
        case .failed: return T.err
        case .stopped: return T.line
        }
    }

    var body: some View {
        Rail(node: color, spinning: item.toolState == .running) {
            VStack(alignment: .leading, spacing: 6) {
                Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                    HStack(spacing: 6) {
                        Text(item.text).font(.system(size: fs(13))).foregroundStyle(item.toolState == .failed ? T.err : T.ink.opacity(0.78))
                            .lineLimit(1).truncationMode(.middle)
                        if item.subSteps > 0 {
                            Text("\(item.subSteps) 步" + (item.subLatest.isEmpty ? "" : "，最近：\(item.subLatest)"))
                                .font(T.small).foregroundStyle(T.muted).lineLimit(1)
                        }
                        Image(systemName: "chevron.right").font(.system(size: fs(9), weight: .semibold))
                            .foregroundStyle(T.muted).rotationEffect(.degrees(open ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open { ToolDetail(item: item) }
            }
        }
    }
}

struct ToolDetail: View {
    @ObservedObject var item: ChatItem
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch item.toolName {
            case "Bash":
                MonoBox(text: "$ " + ((item.toolInput["command"] as? String) ?? ""))
            case "Edit":
                DiffBox(old: item.toolInput["old_string"] as? String ?? "", new: item.toolInput["new_string"] as? String ?? "",
                        path: item.toolInput["file_path"] as? String ?? "")
            case "Write":
                Text(item.toolInput["file_path"] as? String ?? "").font(T.small).foregroundStyle(T.muted).textSelection(.enabled)
                MonoBox(text: String((item.toolInput["content"] as? String ?? "").prefix(6000)))
            default:
                MonoBox(text: item.inputJSON)
            }
            if let r = item.toolResult, !r.isEmpty {
                Text(item.toolState == .failed ? "出错" : "结果").font(T.small).foregroundStyle(item.toolState == .failed ? T.err : T.muted)
                MonoBox(text: String(r.prefix(20000)))
            }
        }
    }
}

struct MonoBox: View {
    let text: String
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text).font(T.mono).foregroundStyle(T.ink).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
        .frame(maxHeight: 240)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 8).fill(T.sunk))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.line, lineWidth: 1))
    }
}

struct DiffBox: View {
    let old: String, new: String, path: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(path).font(T.small).foregroundStyle(T.muted).textSelection(.enabled)
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(old.components(separatedBy: "\n").enumerated()), id: \.offset) { _, l in
                        Text("− " + l).font(T.mono).foregroundStyle(T.err)
                    }
                    ForEach(Array(new.components(separatedBy: "\n").enumerated()), id: \.offset) { _, l in
                        Text("+ " + l).font(T.mono).foregroundStyle(T.ok)
                    }
                }
                .textSelection(.enabled).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240).fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 8).fill(T.sunk))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.line, lineWidth: 1))
        }
    }
}
