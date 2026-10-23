import SwiftUI
import AppKit

// 废纸篓面板：左边删除的对话，右边只读预览
struct TrashView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var store = TrashStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selected: TrashEntry?
    @State private var query = ""
    @State private var confirmPurge: TrashEntry?
    @State private var confirmEmpty = false
    @State private var pendingRetention: (days: Int, count: Int)?

    var filtered: [TrashEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return store.entries.filter { q.isEmpty || $0.title.lowercased().contains(q) || $0.folder.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "trash").foregroundStyle(T.muted)
                Text("废纸篓").font(.system(size: fs(15), weight: .semibold)).foregroundStyle(T.ink)
                Text("\(store.entries.count) 个对话").font(.system(size: fs(12))).foregroundStyle(T.muted)
                Spacer()
                Button("清空废纸篓…") { confirmEmpty = true }.disabled(store.entries.isEmpty)
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()

            if store.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "trash").font(.system(size: fs(30))).foregroundStyle(T.line)
                    Text("废纸篓是空的").font(.system(size: fs(14), weight: .medium)).foregroundStyle(T.ink)
                    Text("删除的对话会先放在这里，随时可以恢复。").font(.system(size: fs(12))).foregroundStyle(T.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    list.frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
                    preview.frame(minWidth: 380)
                }
            }

            Divider()
            HStack(spacing: 8) {
                Text("删除的对话保留").font(.system(size: fs(12))).foregroundStyle(T.muted)
                Picker("", selection: Binding(get: { store.retentionDays }, set: { v in
                    // 改短会马上清掉已经过期的，先问一句
                    let n = v > 0 ? store.entries.filter { $0.deletedAt.addingTimeInterval(Double(v) * 86400) < Date() }.count : 0
                    if n > 0 { pendingRetention = (v, n) } else { store.retentionDays = v }
                })) {
                    Text("7 天").tag(7); Text("30 天").tag(30); Text("90 天").tag(90); Text("永久").tag(0)
                }
                .labelsHidden().fixedSize()
                Text(store.retentionDays == 0 ? "，不会自动清除" : "，到期自动彻底删除").font(.system(size: fs(12))).foregroundStyle(T.muted)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 900, height: 620)
        .background(T.paper)
        .onAppear {
            store.purgeExpired()
            selected = store.entries.first
        }
        .alert("彻底删除「\(confirmPurge?.title ?? "")」？", isPresented: Binding(get: { confirmPurge != nil }, set: { if !$0 { confirmPurge = nil } })) {
            Button("彻底删除", role: .destructive) {
                if let e = confirmPurge { app.purge(e); if selected == e { selected = store.entries.first } }
                confirmPurge = nil
            }
            Button("取消", role: .cancel) { confirmPurge = nil }
        } message: { Text("删除后不能恢复。") }
        .alert("清空废纸篓？", isPresented: $confirmEmpty) {
            Button("清空 \(store.entries.count) 个对话", role: .destructive) {
                store.entries.forEach { app.purge($0) }
                selected = nil
            }
            Button("取消", role: .cancel) {}
        } message: { Text("里面的对话会被彻底删除，不能恢复。") }
        .alert("改成保留 \(pendingRetention?.days ?? 0) 天？", isPresented: Binding(get: { pendingRetention != nil }, set: { if !$0 { pendingRetention = nil } })) {
            Button("改，并删除 \(pendingRetention?.count ?? 0) 个", role: .destructive) {
                if let r = pendingRetention { store.retentionDays = r.days; if let s = selected, !store.entries.contains(s) { selected = store.entries.first } }
                pendingRetention = nil
            }
            Button("取消", role: .cancel) { pendingRetention = nil }
        } message: { Text("废纸篓里有 \(pendingRetention?.count ?? 0) 个对话已经超过这个天数，会马上被彻底删除，不能恢复。") }
    }

    var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: fs(11))).foregroundStyle(T.muted)
                TextField("搜索废纸篓", text: $query).textFieldStyle(.plain).font(.system(size: fs(13)))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(T.sunk))
            .padding(10)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filtered) { e in row(e) }
                    if filtered.isEmpty {
                        Text("没有找到「\(query)」").font(.system(size: fs(12))).foregroundStyle(T.muted).padding(.top, 20)
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
            }
        }
        .background(T.canvas)
    }

    func row(_ e: TrashEntry) -> some View {
        let sel = selected == e
        return Button { selected = e } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(e.title).font(.system(size: fs(13), weight: sel ? .medium : .regular)).foregroundStyle(T.ink).lineLimit(1)
                HStack(spacing: 6) {
                    Text(e.folder).lineLimit(1)
                    Text(Self.relative(e.deletedAt) + "删除")
                    if let d = store.daysLeft(e) { Text(d <= 3 ? "\(d) 天后清除" : "保留 \(d) 天").foregroundStyle(d <= 3 ? T.err : T.muted) }
                }
                .font(.system(size: fs(11))).foregroundStyle(T.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(sel ? T.line.opacity(0.9) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("恢复") { restore(e) }
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([store.storedFile(e)]) }
            Divider()
            Button("彻底删除…", role: .destructive) { confirmPurge = e }
        }
    }

    @ViewBuilder var preview: some View {
        if let e = selected, store.entries.contains(e) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.title).font(.system(size: fs(14), weight: .semibold)).foregroundStyle(T.ink).lineLimit(1)
                        Text(e.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: fs(11))).foregroundStyle(T.muted).lineLimit(1)
                    }
                    Spacer()
                    Button("彻底删除…") { confirmPurge = e }
                    Button("恢复") { restore(e) }.buttonStyle(PrimaryButton())
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                Divider()
                TrashPreview(entry: e).id(e.id)
            }
        } else {
            Text("选一个对话预览").foregroundStyle(T.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func restore(_ e: TrashEntry) {
        if app.restore(e) {
            selected = store.entries.first
        }
    }

    static func relative(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(Int(s / 60)) 分钟前" }
        if s < 86400 { return "\(Int(s / 3600)) 小时前" }
        return "\(Int(s / 86400)) 天前"
    }
}

/// 只读预览：后台解析记录文件，复用对话视图
struct TrashPreview: View {
    let entry: TrashEntry
    @StateObject private var session = ChatSession(cwd: NSHomeDirectory())
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded {
                if session.items.isEmpty { Text("这个对话没有可显示的内容").foregroundStyle(T.muted).frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { Transcript(session: session) }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            let url = TrashStore.shared.storedFile(entry)
            DispatchQueue.global(qos: .userInitiated).async {
                let parsed = History.loadTranscript(url)
                DispatchQueue.main.async { session.items = parsed.items; loaded = true }
            }
        }
    }
}

/// 侧栏底部的提示条（删除后可撤销）
struct ToastBar: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        if let t = app.toast {
            HStack(spacing: 8) {
                Text(t.text).font(.system(size: fs(12))).foregroundStyle(T.ink).lineLimit(2)
                Spacer(minLength: 4)
                if let undo = t.undo {
                    Button("撤销") { undo(); app.toast = nil }.buttonStyle(.plain).font(.system(size: fs(12), weight: .semibold)).foregroundStyle(T.accent)
                }
                Button { app.toast = nil } label: { Image(systemName: "xmark").font(.system(size: fs(10), weight: .semibold)).foregroundStyle(T.muted) }
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(T.paper))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(T.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
