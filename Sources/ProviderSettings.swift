import SwiftUI
import AppKit

/// 设置 → 模型服务：参照 CC Switch，存几家服务商，选一家给之后新开的对话用
struct ProviderSettings: View {
    @ObservedObject var store = ProviderStore.shared
    @State private var editing: ModelProvider?
    @State private var importNote = ""

    var body: some View {
        Form {
            Section {
                row(name: "FCF（公司）", detail: "Fable、Opus、Sonnet、Haiku", selected: store.currentId == nil) { store.select(nil) }
                ForEach(store.providers) { p in
                    row(name: p.name, detail: p.model.isEmpty ? p.baseURL : "\(p.model) · \(p.baseURL)", selected: store.currentId == p.id) {
                        store.select(p.id)
                    } menu: {
                        Button("编辑") { editing = p }
                        if !p.website.isEmpty, let u = URL(string: p.website) { Button("打开官网") { NSWorkspace.shared.open(u) } }
                        Divider()
                        Button("删除", role: .destructive) { confirmRemove(p) }
                    }
                }
                HStack {
                    Menu("添加服务商") {
                        ForEach(ProviderStore.presets, id: \.name) { pre in
                            Button(pre.name) { var p = pre; p.id = UUID().uuidString; editing = p }
                        }
                        Divider()
                        Button("自定义") { editing = ModelProvider(name: "", baseURL: "", model: "") }
                    }
                    .fixedSize()
                    Button("从 CC Switch 导入") { importNote = store.importFromCCSwitch().note }
                    Spacer()
                    if !importNote.isEmpty { Text(importNote).font(T.small).foregroundStyle(T.muted) }
                }
            } footer: {
                Text("选中的服务商用于之后新开的对话，已经开始的对话不变。用别家服务时不经过 FCF，对话内容会直接发给那家。")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { p in
            Themed { ProviderEditor(provider: p) { editing = nil } }
        }
    }

    private func row(name: String, detail: String, selected: Bool, pick: @escaping () -> Void) -> some View {
        row(name: name, detail: detail, selected: selected, pick: pick) { EmptyView() }
    }

    private func row<M: View>(name: String, detail: String, selected: Bool, pick: @escaping () -> Void, @ViewBuilder menu: () -> M) -> some View {
        HStack(spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: fs(15))).foregroundStyle(selected ? T.accent : T.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: fs(13), weight: .medium)).foregroundStyle(T.ink)
                Text(detail).font(T.small).foregroundStyle(T.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            let m = menu()
            if !(m is EmptyView) {
                Menu { m } label: { Image(systemName: "ellipsis.circle").font(.system(size: fs(14))).foregroundStyle(T.muted) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: pick)
    }

    private func confirmRemove(_ p: ModelProvider) {
        let a = NSAlert()
        a.messageText = "删除「\(p.name)」？"
        a.informativeText = "地址和 Key 一起删掉。正在用它的对话下次会回到 FCF。"
        a.addButton(withTitle: "删除"); a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn { ProviderStore.shared.remove(p) }
    }
}

/// 添加 / 编辑一家服务商
struct ProviderEditor: View {
    @State var provider: ModelProvider
    var done: () -> Void
    @State private var key = ""
    @State private var testing = false
    @State private var result: (ok: Bool, text: String)?

    init(provider: ModelProvider, done: @escaping () -> Void) {
        _provider = State(initialValue: provider)
        _key = State(initialValue: ProviderStore.shared.key(for: provider.id) ?? "")
        self.done = done
    }

    private var canSave: Bool {
        !provider.name.trimmingCharacters(in: .whitespaces).isEmpty && provider.baseURL.hasPrefix("http") && !provider.model.isEmpty && !key.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("名称", text: $provider.name)
                TextField("接口地址", text: $provider.baseURL, prompt: Text("https://…/anthropic"))
                SecureField("API Key", text: $key)
                TextField("主模型", text: $provider.model, prompt: Text("这家的模型名"))
                TextField("快速模型", text: $provider.fastModel, prompt: Text("可不填，同主模型"))
                if let result {
                    Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(T.small).foregroundStyle(result.ok ? T.ok : T.err).fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            HStack {
                Button(testing ? "测试中…" : "测试连接") {
                    testing = true; result = nil
                    ProviderStore.shared.test(provider, key: key) { ok, text in testing = false; result = (ok, text) }
                }
                .disabled(testing || !canSave)
                if !provider.website.isEmpty, let u = URL(string: provider.website) {
                    Button("去官网拿 Key") { NSWorkspace.shared.open(u) }.buttonStyle(.link)
                }
                Spacer()
                Button("取消", action: done).keyboardShortcut(.cancelAction)
                Button("保存") {
                    provider.name = provider.name.trimmingCharacters(in: .whitespaces)
                    ProviderStore.shared.upsert(provider, key: key)
                    done()
                }
                .buttonStyle(PrimaryButton()).disabled(!canSave).keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 460)
    }
}
