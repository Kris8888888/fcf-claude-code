import SwiftUI
import AppKit

// 外观主题：每个主题是一张这个 App 自己的缩略界面，点一下整个窗口立即换上
struct ThemeSettings: View {
    @ObservedObject var store = ThemeStore.shared
    @State private var custom = Color.accentColor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                FontSizePicker(store: store)

                Text("选一套配色，对话窗口和设置窗口立即换上。启动检查里的终端框始终保持深色。")
                    .font(.system(size: fs(12.5))).foregroundStyle(T.muted)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 14)], alignment: .leading, spacing: 16) {
                    ForEach(Palette.all) { p in
                        ThemeCard(palette: p, selected: p.id == store.palette.id) { store.select(p) }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("强调色").font(.system(size: fs(14), weight: .semibold)).foregroundStyle(T.ink)
                    HStack(spacing: 12) {
                        Toggle("使用自定义强调色", isOn: Binding(
                            get: { store.accentOverride != nil },
                            set: { on in store.setAccent(on ? hex(of: custom) : nil) }))
                        ColorPicker("", selection: Binding(
                            get: { custom },
                            set: { c in custom = c; if store.accentOverride != nil { store.setAccent(hex(of: c)) } }),
                            supportsOpacity: false)
                            .labelsHidden()
                            .disabled(store.accentOverride == nil)
                        Spacer()
                    }
                    Text("按钮、选中状态、你的消息气泡都会用这个颜色。按钮上的字会自动选黑或白，保证看得清。")
                        .font(T.small).foregroundStyle(T.muted)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(T.sunk))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(T.line, lineWidth: 1))
            }
            .padding(.horizontal, 20).padding(.bottom, 20).padding(.top, 4)
        }
        .onAppear {
            if let o = store.accentOverride { custom = Color(nsColor: Palette.rgb(o)) }
            else { custom = T.accent }
        }
    }

    func hex(of c: Color) -> UInt32 {
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? .systemBlue
        return UInt32((ns.redComponent * 255).rounded()) << 16 | UInt32((ns.greenComponent * 255).rounded()) << 8 | UInt32((ns.blueComponent * 255).rounded())
    }
}

/// 主题缩略图：侧栏 + 你的气泡 + 活动轨上的步骤点 + 回复文字 + 发送按钮
struct ThemeCard: View {
    let palette: Palette
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let p = palette
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                preview(p)
                    .frame(height: 118)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(p.color(p.line), lineWidth: 1))
                HStack(spacing: 6) {
                    Text(p.name).font(.system(size: fs(13), weight: selected ? .semibold : .regular)).foregroundStyle(T.ink)
                    if p.scheme != nil { Text(p.schemeLabel).font(.system(size: fs(11))).foregroundStyle(T.muted) }
                    else { Text("浅色 / 深色自动").font(.system(size: fs(11))).foregroundStyle(T.muted) }
                    Spacer()
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(T.accent) }
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12).fill(hover || selected ? T.sunk : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? T.accent : Color.clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("换成「\(p.name)」")
    }

    @ViewBuilder func preview(_ p: Palette) -> some View {
        let accent = p.color(p.accent)
        let soft = Palette.color(Pair(Palette.mix(p.accent.light, p.paper.light, 0.14), Palette.mix(p.accent.dark, p.paper.dark, 0.24)), scheme: p.scheme)
        HStack(spacing: 0) {
            // 侧栏
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 3).fill(p.color(p.paper)).frame(height: 12)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(p.color(p.line), lineWidth: 0.5))
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2).fill(i == 1 ? p.color(p.line) : Color.clear)
                        .frame(height: 9)
                        .overlay(alignment: .leading) {
                            Capsule().fill(p.color(p.muted).opacity(0.7)).frame(width: CGFloat(30 - i * 4), height: 3).padding(.leading, 4)
                        }
                }
                Spacer()
            }
            .padding(6)
            .frame(width: 54)
            .background(p.color(p.canvas))

            // 对话区
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Spacer()
                    Capsule().fill(soft).frame(width: 64, height: 12)
                }
                HStack(alignment: .top, spacing: 6) {
                    VStack(spacing: 9) {
                        Circle().fill(p.color(p.muted)).frame(width: 4, height: 4)
                        Circle().fill(p.color(p.run)).frame(width: 4, height: 4)
                        Circle().fill(p.color(p.ok)).frame(width: 4, height: 4)
                    }
                    .padding(.top, 2)
                    .background(Rectangle().fill(p.color(p.line)).frame(width: 1))
                    VStack(alignment: .leading, spacing: 5) {
                        Capsule().fill(p.color(p.muted)).frame(width: 52, height: 3)
                        Capsule().fill(p.color(p.ink)).frame(width: 78, height: 3)
                        Capsule().fill(p.color(p.ink)).frame(width: 64, height: 3)
                        Capsule().fill(p.color(p.ink).opacity(0.6)).frame(width: 40, height: 3)
                    }
                }
                Spacer(minLength: 0)
                // 输入框 + 发送键
                RoundedRectangle(cornerRadius: 5).fill(p.color(p.paper))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.color(p.line), lineWidth: 0.8))
                    .overlay(alignment: .trailing) { Circle().fill(accent).frame(width: 10, height: 10).padding(.trailing, 4) }
                    .frame(height: 18)
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(p.color(p.paper))
        }
    }
}

/// 字号：四档，选了整个界面立即按新字号重排（对话内容、侧栏、设置都跟着变）
struct FontSizePicker: View {
    @ObservedObject var store: ThemeStore
    static let options: [(String, Double)] = [("小", 0.9), ("标准", 1.0), ("大", 1.12), ("特大", 1.25)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("字号").font(.system(size: fs(14), weight: .semibold)).foregroundStyle(T.ink)
                Spacer()
                Picker("", selection: Binding(get: { store.fontScale }, set: { store.setFontScale($0) })) {
                    ForEach(Self.options, id: \.1) { Text($0.0).tag($0.1) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 260)
            }
            Text("Claude 的回复、侧栏和设置里的文字都会按这个大小显示。")
                .font(.system(size: fs(14))).foregroundStyle(T.ink.opacity(0.85))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(T.sunk))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(T.line, lineWidth: 1))
    }
}
