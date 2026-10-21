import SwiftUI
import AppKit
import Combine

// MARK: 配色方案

/// 一个颜色在浅色 / 深色外观下的取值；固定外观的主题两个值相同
struct Pair { let light: UInt32; let dark: UInt32
    init(_ l: UInt32, _ d: UInt32) { light = l; dark = d }
    init(_ v: UInt32) { light = v; dark = v }
}

struct Palette: Identifiable {
    let id: String
    let name: String
    let scheme: ColorScheme?        // nil = 跟随系统
    let canvas, paper, sunk, ink, muted, line, accent, run, ok, err: Pair

    var schemeLabel: String { scheme == nil ? "跟随系统" : scheme == .dark ? "深色" : "浅色" }

    /// 固定外观主题：一组十六进制直接建
    static func fixed(_ id: String, _ name: String, _ s: ColorScheme, _ v: [UInt32]) -> Palette {
        Palette(id: id, name: name, scheme: s, canvas: Pair(v[0]), paper: Pair(v[1]), sunk: Pair(v[2]), ink: Pair(v[3]),
                muted: Pair(v[4]), line: Pair(v[5]), accent: Pair(v[6]), run: Pair(v[7]), ok: Pair(v[8]), err: Pair(v[9]))
    }

    //                          canvas    paper     sunk      ink       muted     line      accent    run       ok        err
    static let all: [Palette] = [
        Palette(id: "system", name: "跟随系统", scheme: nil,
                canvas: Pair(0xEEF1F4, 0x14171B), paper: Pair(0xFFFFFF, 0x1B1F24), sunk: Pair(0xF5F7F9, 0x181B20),
                ink: Pair(0x1A2230, 0xE4E8EE), muted: Pair(0x697386, 0x8D96A6), line: Pair(0xDCE1E8, 0x2A3038),
                accent: Pair(0x3346B8, 0x8C9BFF), run: Pair(0xC27A12, 0xE3A440), ok: Pair(0x2E8B57, 0x5BC08A), err: Pair(0xC2412D, 0xF07A66)),
        fixed("slate-light", "石板浅色", .light, [0xEEF1F4, 0xFFFFFF, 0xF5F7F9, 0x1A2230, 0x697386, 0xDCE1E8, 0x3346B8, 0xC27A12, 0x2E8B57, 0xC2412D]),
        fixed("slate-dark", "石板深色", .dark, [0x14171B, 0x1B1F24, 0x181B20, 0xE4E8EE, 0x8D96A6, 0x2A3038, 0x8C9BFF, 0xE3A440, 0x5BC08A, 0xF07A66]),
        fixed("github-light", "GitHub Light", .light, [0xF6F8FA, 0xFFFFFF, 0xF6F8FA, 0x1F2328, 0x656D76, 0xD0D7DE, 0x0969DA, 0x9A6700, 0x1A7F37, 0xCF222E]),
        fixed("github-dark", "GitHub Dark", .dark, [0x010409, 0x0D1117, 0x161B22, 0xE6EDF3, 0x8D96A0, 0x30363D, 0x4493F8, 0xD29922, 0x3FB950, 0xF85149]),
        fixed("one-dark", "One Dark", .dark, [0x21252B, 0x282C34, 0x2C313A, 0xABB2BF, 0x7F848E, 0x3E4451, 0x61AFEF, 0xE5C07B, 0x98C379, 0xE06C75]),
        fixed("dracula", "Dracula", .dark, [0x21222C, 0x282A36, 0x343746, 0xF8F8F2, 0x9198BD, 0x44475A, 0xBD93F9, 0xFFB86C, 0x50FA7B, 0xFF5555]),
        fixed("nord", "Nord", .dark, [0x272C36, 0x2E3440, 0x3B4252, 0xECEFF4, 0x9AA5B8, 0x434C5E, 0x88C0D0, 0xEBCB8B, 0xA3BE8C, 0xBF616A]),
        fixed("solarized-light", "Solarized Light", .light, [0xEEE8D5, 0xFDF6E3, 0xF5EFDC, 0x2E3F45, 0x7B8D93, 0xDDD6C1, 0x268BD2, 0xB58900, 0x859900, 0xDC322F]),
        fixed("solarized-dark", "Solarized Dark", .dark, [0x00212B, 0x002B36, 0x073642, 0xCBD5D6, 0x7F9396, 0x0E4A57, 0x268BD2, 0xB58900, 0x859900, 0xDC322F]),
        fixed("monokai", "Monokai", .dark, [0x1E1F1C, 0x272822, 0x31322C, 0xF8F8F2, 0x90908A, 0x3E3D32, 0x66D9EF, 0xE6DB74, 0xA6E22E, 0xF92672]),
        fixed("tokyo-night", "Tokyo Night", .dark, [0x16161E, 0x1A1B26, 0x1F2335, 0xC0CAF5, 0x7A82A8, 0x292E42, 0x7AA2F7, 0xE0AF68, 0x9ECE6A, 0xF7768E]),
        fixed("catppuccin-latte", "Catppuccin Latte", .light, [0xE6E9EF, 0xEFF1F5, 0xDCE0E8, 0x4C4F69, 0x6C6F85, 0xCCD0DA, 0x8839EF, 0xDF8E1D, 0x40A02B, 0xD20F39]),
        fixed("catppuccin-mocha", "Catppuccin Mocha", .dark, [0x181825, 0x1E1E2E, 0x24243A, 0xCDD6F4, 0x9399B2, 0x45475A, 0xCBA6F7, 0xFAB387, 0xA6E3A1, 0xF38BA8]),
        fixed("gruvbox-dark", "Gruvbox Dark", .dark, [0x1D2021, 0x282828, 0x32302F, 0xEBDBB2, 0xA89984, 0x3C3836, 0x83A598, 0xFABD2F, 0xB8BB26, 0xFB4934]),
        fixed("rose-pine-dawn", "Rosé Pine Dawn", .light, [0xF2E9E1, 0xFAF4ED, 0xFFFAF3, 0x575279, 0x797593, 0xDFDAD9, 0x907AA9, 0xEA9D34, 0x56949F, 0xB4637A]),
    ]

    func color(_ p: Pair) -> Color { Palette.color(p, scheme: scheme) }

    static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static func color(_ p: Pair, scheme: ColorScheme?) -> Color {
        if scheme != nil || p.light == p.dark { return Color(nsColor: rgb(p.light)) }
        return Color(nsColor: NSColor(name: nil) { ap in
            rgb(ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? p.dark : p.light)
        })
    }

    /// 两色混合（强调色浅底、自定义强调色用）
    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func ch(_ v: UInt32, _ s: UInt32) -> Double { Double((v >> s) & 0xFF) }
        func m(_ s: UInt32) -> UInt32 { UInt32((ch(a, s) * t + ch(b, s) * (1 - t)).rounded()) << s }
        return m(16) | m(8) | m(0)
    }

    static func luminance(_ hex: UInt32) -> Double {
        let r = Double((hex >> 16) & 0xFF) / 255, g = Double((hex >> 8) & 0xFF) / 255, b = Double(hex & 0xFF) / 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}

// MARK: 当前主题

final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    @Published private(set) var palette: Palette
    @Published private(set) var accentOverride: UInt32?
    @Published private(set) var revision = 0
    private(set) var colors: Colors

    struct Colors {
        let canvas, paper, sunk, ink, muted, line, accent, accentSoft, run, ok, err, onAccent: Color
    }

    private init() {
        // 仅用于截图验证：DUIHUATAI_THEME_DEMO=<主题 id> 临时套用，不保存
        let id = ProcessInfo.processInfo.environment["DUIHUATAI_THEME_DEMO"] ?? UserDefaults.standard.string(forKey: "themeID") ?? "system"
        let p = Palette.all.first { $0.id == id } ?? Palette.all[0]
        let o = UserDefaults.standard.object(forKey: "accentOverride") as? Int
        palette = p
        accentOverride = o.map { UInt32($0) }
        colors = Self.build(p, accentOverride: o.map { UInt32($0) })
    }

    func select(_ p: Palette) {
        palette = p
        UserDefaults.standard.set(p.id, forKey: "themeID")
        apply()
    }

    func setAccent(_ hex: UInt32?) {
        accentOverride = hex
        if let hex { UserDefaults.standard.set(Int(hex), forKey: "accentOverride") }
        else { UserDefaults.standard.removeObject(forKey: "accentOverride") }
        apply()
    }

    private func apply() {
        colors = Self.build(palette, accentOverride: accentOverride)
        applyAppearance()
        revision += 1
    }

    /// 系统控件（菜单、输入框、滚动条）跟着主题的深浅走
    func applyAppearance() {
        switch palette.scheme {
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        default: NSApp.appearance = nil
        }
    }

    private static func build(_ p: Palette, accentOverride: UInt32?) -> Colors {
        let accent = accentOverride.map { Pair($0) } ?? p.accent
        // 强调色浅底：强调色和纸色按比例混合，深色主题混得多一点
        let soft = Pair(Palette.mix(accent.light, p.paper.light, 0.14), Palette.mix(accent.dark, p.paper.dark, 0.24))
        let onAccentLight: UInt32 = Palette.luminance(accent.light) > 0.55 ? 0x15171C : 0xFFFFFF
        let onAccentDark: UInt32 = Palette.luminance(accent.dark) > 0.55 ? 0x15171C : 0xFFFFFF
        return Colors(canvas: p.color(p.canvas), paper: p.color(p.paper), sunk: p.color(p.sunk), ink: p.color(p.ink),
                      muted: p.color(p.muted), line: p.color(p.line), accent: p.color(accent), accentSoft: p.color(soft),
                      run: p.color(p.run), ok: p.color(p.ok), err: p.color(p.err),
                      onAccent: p.color(Pair(onAccentLight, onAccentDark)))
    }
}

/// 窗口根视图套一层：主题变了整棵视图用新颜色重建
struct Themed<Content: View>: View {
    @ObservedObject var store = ThemeStore.shared
    @ViewBuilder var content: Content
    var body: some View {
        content
            .id(store.revision)
            .preferredColorScheme(store.palette.scheme)
            .tint(T.accent)
    }
}

// 颜色 token：从当前主题取
enum T {
    static var canvas: Color { ThemeStore.shared.colors.canvas }
    static var paper: Color { ThemeStore.shared.colors.paper }
    static var sunk: Color { ThemeStore.shared.colors.sunk }
    static var ink: Color { ThemeStore.shared.colors.ink }
    static var muted: Color { ThemeStore.shared.colors.muted }
    static var line: Color { ThemeStore.shared.colors.line }
    static var accent: Color { ThemeStore.shared.colors.accent }
    static var accentSoft: Color { ThemeStore.shared.colors.accentSoft }
    static var onAccent: Color { ThemeStore.shared.colors.onAccent }   // 强调色上的文字/图标
    static var run: Color { ThemeStore.shared.colors.run }
    static var ok: Color { ThemeStore.shared.colors.ok }
    static var err: Color { ThemeStore.shared.colors.err }

    static let mono = Font.system(size: 12, design: .monospaced)
    static let body = Font.system(size: 14)
    static let small = Font.system(size: 12)
}

struct Chip: View {
    let icon: String
    let text: String
    var tint: Color = T.muted
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(text).font(T.small).lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(T.sunk))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.line, lineWidth: 1))
    }
}
