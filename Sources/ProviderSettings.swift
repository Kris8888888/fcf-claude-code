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
                VStack(alignment: .leading, spacing: 6) {
                    if !store.providers.isEmpty && ModelCatalog.claudeBinary() == nil {
                        Text("这台电脑还没装 Claude Code，用别家服务也需要它。先在终端里运行 npm install -g @anthropic-ai/claude-code，装好后重开 App。")
                            .foregroundStyle(T.err)
                    }
                    Text("选中的服务商用于之后新开的对话，已经开始的对话不变。用别家服务时不经过 FCF，对话内容会直接发给那家。")
                }
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
    @State private var roles: [String: RoleMap] = [:]
    @State private var models: [String] = []
    @State private var fetching = false

    init(provider: ModelProvider, done: @escaping () -> Void) {
        _provider = State(initialValue: provider)
        _key = State(initialValue: ProviderStore.shared.key(for: provider.id) ?? "")
        var r: [String: RoleMap] = [:]
        for role in ModelRole.allCases { r[role.rawValue] = provider.role(role) }
        _roles = State(initialValue: r)
        self.done = done
    }

    private var canSave: Bool {
        !provider.name.trimmingCharacters(in: .whitespaces).isEmpty && provider.baseURL.hasPrefix("http") && !provider.model.isEmpty && !key.isEmpty
    }

    /// 存回去的服务商（带上映射）
    private var edited: ModelProvider {
        var p = provider
        p.name = p.name.trimmingCharacters(in: .whitespaces)
        p.roles = roles
        p.fastModel = ""
        return p
    }

    private func binding(_ r: ModelRole, _ kp: WritableKeyPath<RoleMap, String>) -> Binding<String> {
        Binding(get: { roles[r.rawValue]?[keyPath: kp] ?? "" }, set: { roles[r.rawValue, default: RoleMap()][keyPath: kp] = $0 })
    }
    private func oneM(_ r: ModelRole) -> Binding<Bool> {
        Binding(get: { roles[r.rawValue]?.oneM ?? false }, set: { roles[r.rawValue, default: RoleMap()].oneM = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("名称", text: $provider.name)
                    TextField("接口地址", text: $provider.baseURL, prompt: Text("https://…/anthropic"))
                    SecureField("API Key", text: $key)
                }
                Section {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow {
                            Text("模型角色"); Text("显示名称"); Text("实际请求模型"); Text("1M")
                        }
                        .font(T.small).foregroundStyle(T.muted)
                        ForEach(ModelRole.allCases) { r in
                            GridRow {
                                Text(r.label).font(.system(size: fs(13))).frame(width: 72, alignment: .leading)
                                if r == .subagent {
                                    Text("不显示在模型菜单").font(T.small).foregroundStyle(T.muted).frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    TextField("", text: binding(r, \.name), prompt: Text(provider.model.isEmpty ? "可不填" : "同实际模型")).labelsHidden()
                                }
                                modelField(binding(r, \.model), prompt: r == .subagent ? "可不填" : "空 = 用默认兜底模型")
                                Toggle("", isOn: oneM(r)).labelsHidden().toggleStyle(.checkbox)
                            }
                        }
                    }
                    HStack {
                        Text("默认兜底模型").font(.system(size: fs(13))).frame(width: 82, alignment: .leading)
                        modelField($provider.model, prompt: "这家的模型名（必填）")
                        Toggle("1M", isOn: Binding(get: { provider.defaultOneM ?? false }, set: { provider.defaultOneM = $0 ? true : nil })).toggleStyle(.checkbox)
                    }
                } header: {
                    HStack {
                        Text("模型映射")
                        Spacer()
                        Button("一键设置") {
                            // Sonnet / Opus / Fable 用兜底模型，Haiku 用列表里看起来最快的（flash / mini / turbo / haiku），没有就同兜底
                            let fast = models.first { m in ["flash", "mini", "turbo", "haiku", "lite"].contains { m.lowercased().contains($0) } } ?? provider.model
                            for r in [ModelRole.sonnet, .opus, .fable] { roles[r.rawValue] = RoleMap(model: provider.model) }
                            roles[ModelRole.haiku.rawValue] = RoleMap(model: fast)
                        }
                        .disabled(provider.model.isEmpty)
                        Button(fetching ? "获取中…" : "获取模型列表") {
                            fetching = true
                            ProviderStore.shared.fetchModels(edited, key: key) { ids, err in
                                fetching = false; models = ids
                                if provider.model.isEmpty, let f = ids.first { provider.model = f }
                                result = err.map { (false, $0) } ?? (true, "拿到 \(ids.count) 个模型，点模型名右边的箭头选")
                            }
                        }
                        .disabled(fetching || !provider.baseURL.hasPrefix("http") || key.isEmpty)
                    }
                }
                if let result {
                    Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(T.small).foregroundStyle(result.ok ? T.ok : T.err).fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            HStack {
                Button(testing ? "测试中…" : "测试连接") {
                    testing = true; result = nil
                    ProviderStore.shared.test(edited, key: key) { ok, text in testing = false; result = (ok, text) }
                }
                .disabled(testing || !canSave)
                if !provider.website.isEmpty, let u = URL(string: provider.website) {
                    Button("去官网拿 Key") { NSWorkspace.shared.open(u) }.buttonStyle(.link)
                }
                Spacer()
                Button("取消", action: done).keyboardShortcut(.cancelAction)
                Button("保存") {
                    ProviderStore.shared.upsert(edited, key: key)
                    done()
                }
                .buttonStyle(PrimaryButton()).disabled(!canSave).keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 640)
    }

    /// 模型名输入框：拿到模型列表后右边多一个下拉
    private func modelField(_ text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: 4) {
            TextField("", text: text, prompt: Text(prompt)).labelsHidden()
            if !models.isEmpty {
                Menu {
                    ForEach(models, id: \.self) { m in Button(m) { text.wrappedValue = m } }
                } label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
    }
}
