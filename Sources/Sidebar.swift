import SwiftUI
import AppKit

struct Sidebar: View {
    @EnvironmentObject var app: AppState
    @State private var expanded: Set<String> = []
    @State private var collapsed: Set<String> = []
    @State private var renaming: SidebarRow?
    @State private var newName = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { app.newSession() } label: {
                Label("新会话", systemImage: "plus.bubble")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(T.ink)
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(T.paper))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(T.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)
            .padding(.horizontal, 12).padding(.top, 8)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(T.muted)
                TextField("搜索对话（⌘F）", text: $app.search).textFieldStyle(.plain).font(.system(size: 13))
                    .focused($searchFocused)
                    .onExitCommand { app.search = ""; searchFocused = false }
                if !app.search.isEmpty {
                    Button { app.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(T.muted) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(T.sunk.opacity(0.7)))
            .padding(.horizontal, 12).padding(.top, 10)

            HStack {
                Text("工作区").font(T.small).foregroundStyle(T.muted)
                Spacer()
                Button { app.refreshHistory() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(T.muted).help("刷新列表")
                Button {
                    if let p = app.chooseFolder(start: app.lastFolder) { app.newSession(cwd: p) }
                } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.plain).foregroundStyle(T.muted).help("在另一个文件夹开新会话")
            }
            .font(.system(size: 12))
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    let pins = app.pinnedRows
                    if !pins.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(T.accent).rotationEffect(.degrees(45))
                            Text("置顶").font(.system(size: 13, weight: .medium)).foregroundStyle(T.ink)
                            Spacer()
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6).padding(.top, 6)
                        // 置顶组单独的标识，避免和文件夹里同一会话共用、复用旧的右键菜单
                        ForEach(pins, id: \.pinKey) { r in row(r, pinned: true) }
                    }
                    ForEach(app.workspaces) { w in workspace(w) }
                }
                .padding(.horizontal, 8).padding(.bottom, 12)
            }

            ToastBar().padding(.horizontal, 10).padding(.top, 8)
                .animation(.easeOut(duration: 0.2), value: app.toast?.id)
            UpdateBanner().padding(.horizontal, 10).padding(.top, 8)
            UsageCard().padding(.horizontal, 10).padding(.top, 10)
                .contentShape(Rectangle())
                .onTapGesture { app.statusPanel = .usage }
                .help("点击查看用量与统计（⌘I）")
            HStack(spacing: 0) {
                SettingsLink {
                    Label("设置", systemImage: "gearshape").font(.system(size: 13)).foregroundStyle(T.ink)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("模型、权限、插件、MCP、技能、钩子等（⌘,）")
                TrashButton()
            }
        }
        .background(T.canvas)
        .onChange(of: app.searchFocusToken) { searchFocused = true }
        .sheet(item: $renaming) { row in
            VStack(alignment: .leading, spacing: 12) {
                Text("重命名对话").font(.system(size: 14, weight: .semibold))
                TextField("对话名称", text: $newName).textFieldStyle(.roundedBorder).frame(width: 300)
                    .onSubmit { app.rename(row, to: newName); renaming = nil }
                HStack {
                    Spacer()
                    Button("取消") { renaming = nil }.keyboardShortcut(.cancelAction)
                    Button("保存") { app.rename(row, to: newName); renaming = nil }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .sheet(isPresented: $app.showTrash) { TrashView().environmentObject(app) }
    }

    @ViewBuilder func workspace(_ w: Workspace) -> some View {
        let isCollapsed = collapsed.contains(w.cwd) && app.search.isEmpty
        let showAll = expanded.contains(w.cwd) || !app.search.isEmpty
        Button {
            if collapsed.contains(w.cwd) { collapsed.remove(w.cwd) } else { collapsed.insert(w.cwd) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed ? "folder" : "folder.fill").font(.system(size: 12)).foregroundStyle(T.accent)
                Text(w.name).font(.system(size: 13, weight: .medium)).foregroundStyle(T.ink).lineLimit(1)
                Spacer()
                Button { app.newSession(cwd: w.cwd) } label: { Image(systemName: "plus").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(T.muted).help("在这个文件夹开新会话")
            }
            .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(w.cwd)
        .padding(.top, 6)
        .contextMenu {
            Button("在这个文件夹开新会话") { app.newSession(cwd: w.cwd) }
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: w.cwd)]) }
        }

        if !isCollapsed {
            let rows = showAll ? w.rows : Array(w.rows.prefix(5))
            ForEach(rows) { r in row(r) }
            if w.rows.count > 5 && app.search.isEmpty {
                Button(showAll ? "收起" : "展开全部 \(w.rows.count) 个") {
                    if showAll { expanded.remove(w.cwd) } else { expanded.insert(w.cwd) }
                }
                .buttonStyle(.plain).font(T.small).foregroundStyle(T.muted)
                .padding(.leading, 28).padding(.vertical, 4)
            }
        }
    }

    func row(_ r: SidebarRow, pinned: Bool = false) -> some View {
        let sel = app.isSelected(r)
        return Button { app.select(r) } label: {
            SidebarRowLabel(title: r.title, time: pinned ? folderName(r.cwd) : relative(r.date), selected: sel,
                            dot: r.live?.needsAttention == true ? T.accent : r.busy ? T.run : nil)
        }
        .buttonStyle(.plain)
        .help(r.live?.needsAttention == true ? "Claude 在等你回答" : r.busy ? "Claude 正在处理" : r.title)
        .contextMenu {
            if r.sessionId != nil {
                if pinned {
                    Button("取消置顶") { withAnimation(.easeOut(duration: 0.15)) { app.togglePin(r) } }
                } else {
                    Button("置顶") { withAnimation(.easeOut(duration: 0.15)) { app.togglePin(r) } }
                }
            } else {
                Button("置顶（发出第一条消息后可用）") {}.disabled(true)
            }
            Button("重命名") { newName = r.title; renaming = r }
            if let s = r.live, s.started {
                Button("关闭（结束后台进程）") { app.close(s) }
            }
            if let sid = r.live?.sessionId ?? r.entry?.sessionId, let url = r.entry?.url ?? app.history.first(where: { $0.sessionId == sid })?.url {
                Button("在访达中显示记录文件") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("复制会话 ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sid, forType: .string)
                }
            }
            Divider()
            Button("移到废纸篓", role: .destructive) { withAnimation(.easeOut(duration: 0.15)) { app.delete(r) } }
        }
    }

    /// 置顶组里右侧显示所属文件夹，方便认出来自哪里
    func folderName(_ cwd: String) -> String {
        let n = (cwd as NSString).lastPathComponent
        return n.count > 10 ? String(n.prefix(9)) + "…" : n
    }

    func relative(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(Int(s / 60))分钟" }
        if s < 86400 { return "\(Int(s / 3600))小时" }
        if s < 86400 * 30 { return "\(Int(s / 86400))天" }
        return "\(Int(s / 86400 / 30))个月"
    }
}

struct SidebarRowLabel: View {
    let title: String
    let time: String
    let selected: Bool
    let dot: Color?
    @State private var hover = false
    var body: some View {
        HStack(spacing: 6) {
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            Text(title).font(.system(size: 13, weight: selected ? .medium : .regular)).foregroundStyle(T.ink).lineLimit(1)
            Spacer(minLength: 4)
            Text(time).font(.system(size: 11)).foregroundStyle(T.muted)
        }
        .padding(.leading, 28).padding(.trailing, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? T.line.opacity(0.9) : hover ? T.line.opacity(0.45) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

extension SidebarRow {
    var pinKey: String { "pin-" + id }
}

extension SidebarRow: Hashable {
    static func == (a: SidebarRow, b: SidebarRow) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct UsageCard: View {
    @ObservedObject var usage = UsageStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("今日花费").font(.system(size: 12, weight: .medium)).foregroundStyle(T.ink)
                Spacer()
                Text(String(format: "$%.2f", usage.todayCost)).font(.system(size: 12, weight: .medium)).foregroundStyle(T.ink)
            }
            meter("5 小时额度", usage.fiveHour)
            meter("本周额度", usage.sevenDay)
            if let r = usage.fiveHourReset, r > Date() {
                Text("5 小时额度 \(r.formatted(date: .omitted, time: .shortened)) 重置").font(.system(size: 11)).foregroundStyle(T.muted)
            }
            if usage.fiveHour == nil {
                Text("发出第一条消息后显示额度").font(.system(size: 11)).foregroundStyle(T.muted)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(T.paper))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(T.line, lineWidth: 1))
    }

    @ViewBuilder func meter(_ label: String, _ v: Double?) -> some View {
        if let v {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(label).font(.system(size: 11)).foregroundStyle(T.muted)
                    Spacer()
                    Text("已用 \(Int((v * 100).rounded()))%").font(.system(size: 11)).foregroundStyle(v > 0.8 ? T.err : T.muted)
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(T.sunk)
                        Capsule().fill(v > 0.8 ? T.err : T.accent).frame(width: max(3, g.size.width * min(v, 1)))
                    }
                }
                .frame(height: 4)
            }
        }
    }
}

/// 设置旁边的废纸篓入口，带数量
struct TrashButton: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var store = TrashStore.shared
    var body: some View {
        Button { app.showTrash = true } label: {
            HStack(spacing: 4) {
                Image(systemName: store.entries.isEmpty ? "trash" : "trash.fill").font(.system(size: 12))
                if !store.entries.isEmpty { Text("\(store.entries.count)").font(.system(size: 11)) }
            }
            .foregroundStyle(T.muted)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("废纸篓：删除的对话可以在这里恢复")
    }
}
