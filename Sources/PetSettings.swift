import SwiftUI
import AppKit

/// 设置 → 桌面宠物
struct PetSettings: View {
    @ObservedObject var store = PetStore.shared
    @State private var on = PetStore.shared.data.enabled
    @State private var name = PetStore.shared.data.name

    var body: some View {
        Form {
            Section {
                Toggle("养一只桌面宠物", isOn: $on)
                    .onChange(of: on) { store.setEnabled(on) }
            } footer: {
                Text("它趴在客户端窗口上，吃你和 Claude 用掉的 token 长大，会撒娇、会生病、会自己出门玩，每天写一篇日记。关掉后不占任何资源。")
            }

            if on {
                Section {
                    Picker("角色", selection: Binding(get: { store.character }, set: { store.setCharacter($0); name = store.data.name })) {
                        ForEach(PetCharacter.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("名字") {
                        TextField("", text: $name).textFieldStyle(.roundedBorder).frame(width: 140)
                            .onSubmit { store.rename(name) }
                    }
                    Picker("大小", selection: Binding(get: { store.data.size }, set: { store.setSize($0) })) {
                        Text("小").tag(0.8)
                        Text("中").tag(1.0)
                        Text("大").tag(1.25)
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("现在") { Text(store.statusLine).foregroundStyle(T.muted) }
                    LabeledContent("在一起") { Text("\(store.daysTogether) 天，Lv\(store.level.n) \(store.level.title)").foregroundStyle(T.muted) }
                    HStack {
                        Button("打开日记") { PetDiaryWindow.show() }
                        Button("放回原位") { store.resetPosition() }
                        Spacer()
                    }
                }

                Section {
                    Toggle("没事就趴在窗口顶上", isOn: Binding(get: { store.data.perch }, set: { store.setPerch($0) }))
                    Toggle("跟着 Claude 的状态做动作", isOn: opt(\.reactToClaude))
                    Toggle("到点提醒吃饭、起来活动、早点下班", isOn: opt(\.care))
                    Toggle("你走开时自己出去玩", isOn: opt(\.wander))
                } footer: {
                    Text("单击头摸摸它，单击身子戳一下，在头上来回划也算摸头；双击看状态；右键喂零食、出门、看日记、让它提醒你、开专注钟。把文件拖给它，会开一个新对话把文件放进去。Claude 等你确认、或者某个对话做完时点它，直接带你过去。拖到桌面上它会待一会儿，闲下来再爬回窗口上；窗口贴着屏幕顶边时它就待在桌面上。")
                }

                Section {
                    Button("重新领养…", role: .destructive) { confirmReadopt() }
                } footer: {
                    Text("日记、明信片和亲密度会清空，从头开始。")
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { store.rename(name) }
    }

    private func opt(_ k: WritableKeyPath<PetData, Bool>) -> Binding<Bool> {
        Binding(get: { store.data[keyPath: k] }, set: { store.setOption(k, $0) })
    }

    private func confirmReadopt() {
        let a = NSAlert()
        a.messageText = "重新领养一只团子？"
        a.informativeText = "\(store.data.name)的日记、明信片和亲密度都会清空，没法恢复。"
        a.addButton(withTitle: "重新领养"); a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn { store.readopt(); name = store.data.name }
    }
}
