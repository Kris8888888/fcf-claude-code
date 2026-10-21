import SwiftUI
import AppKit

/// 极简终端屏幕：够 fcf 的菜单 / 进度条 / 确认提示正常显示（光标移动、清行、颜色）
final class TerminalBuffer: ObservableObject {
    struct Cell { var ch: Character; var fg: Int?; var bold: Bool }
    struct Style { var fg: Int?; var bold = false }

    @Published private(set) var version = 0
    private(set) var lines: [[Cell]] = [[]]
    private(set) var row = 0
    private(set) var col = 0
    var cols = 100
    var rows = 24
    private var style = Style()
    private var saved = (0, 0)
    private var pending = Data()
    private var esc: [UInt8]? = nil       // 正在解析的转义序列
    private var flushScheduled = false

    var screenTop: Int { max(0, lines.count - rows) }

    func reset() {
        lines = [[]]; row = 0; col = 0; style = Style(); esc = nil; pending = Data()
        bump()
    }

    func feed(_ data: Data) {
        pending.append(data)
        let bytes = [UInt8](pending)
        // 末尾可能是被截断的多字节字符，留到下一块再解码
        var keep = 0
        var i = bytes.count - 1, back = 0
        while i >= 0 && back < 4 {
            let b = bytes[i]
            if b & 0xC0 == 0x80 { i -= 1; back += 1; continue }
            if b & 0x80 != 0 {
                let need = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : 2
                if bytes.count - i < need { keep = bytes.count - i }
            }
            break
        }
        pending = Data(bytes[(bytes.count - keep)...])
        let chunk = bytes[0..<(bytes.count - keep)]
        for scalar in String(decoding: chunk, as: UTF8.self).unicodeScalars { process(scalar) }
        bump()
    }

    /// 合并 30ms 内的刷新
    private func bump() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.flushScheduled = false
            self?.version += 1
        }
    }

    /// 只保留最近 2000 行
    private func trimHistory() {
        let extra = lines.count - 2000
        guard extra > 200 else { return }
        lines.removeFirst(extra)
        row = max(0, row - extra)
        saved.0 = max(0, saved.0 - extra)
    }

    private func ensureRow(_ r: Int) {
        while lines.count <= r { lines.append([]) }
    }

    private static func width(_ s: Unicode.Scalar) -> Int {
        let v = s.value
        if (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v)
            || (0xFFE0...0xFFE6).contains(v) || (0x1F300...0x1FAFF).contains(v) { return 2 }
        return 1
    }

    private func put(_ s: Unicode.Scalar) {
        if col >= cols { col = 0; row += 1 }
        ensureRow(row)
        var line = lines[row]
        while line.count < col { line.append(Cell(ch: " ", fg: nil, bold: false)) }
        let cell = Cell(ch: Character(s), fg: style.fg, bold: style.bold)
        let w = Self.width(s)
        if col < line.count { line[col] = cell } else { line.append(cell) }
        if w == 2 {
            // 宽字符占两格，第二格放一个空的占位
            let filler = Cell(ch: "\u{0}", fg: nil, bold: false)
            if col + 1 < line.count { line[col + 1] = filler } else { line.append(filler) }
        }
        lines[row] = line
        col += w
    }

    private func process(_ s: Unicode.Scalar) {
        if var seq = esc {
            seq.append(UInt8(truncatingIfNeeded: s.value))
            esc = seq
            if seq.count == 2 {
                switch seq[1] {
                case UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "("), UInt8(ascii: ")"): return
                case UInt8(ascii: "7"): saved = (row, col); esc = nil; return
                case UInt8(ascii: "8"): (row, col) = saved; esc = nil; return
                default: esc = nil; return
                }
            }
            if seq[1] == UInt8(ascii: "]") {
                // OSC：到 BEL 或 ESC \ 结束，内容忽略
                if s.value == 7 || (seq.count >= 2 && seq[seq.count - 2] == 0x1B && s == "\\") { esc = nil }
                return
            }
            if seq[1] == UInt8(ascii: "(") || seq[1] == UInt8(ascii: ")") { esc = nil; return }
            if (0x40...0x7E).contains(s.value) { csi(Array(seq.dropFirst(2).dropLast()), final: s); esc = nil }
            return
        }
        switch s.value {
        case 0x1B: esc = [0x1B]
        case 0x0D: col = 0
        case 0x0A: row += 1; ensureRow(row); trimHistory()
        case 0x08: col = max(0, col - 1)
        case 0x09: col = min(cols - 1, (col / 8 + 1) * 8)
        case 0x07, 0x00: break
        default:
            if s.value >= 0x20 { put(s) }
        }
    }

    private func csi(_ raw: [UInt8], final: Unicode.Scalar) {
        let str = String(decoding: raw, as: UTF8.self)
        let priv = str.hasPrefix("?")
        let nums = str.trimmingCharacters(in: CharacterSet(charactersIn: "?>=")).split(separator: ";", omittingEmptySubsequences: false).map { Int($0) }
        func n(_ i: Int, _ d: Int = 1) -> Int { (i < nums.count ? nums[i] : nil) ?? d }
        if priv { return }   // 显示/隐藏光标、备用屏等，忽略
        switch final {
        case "A": row = max(screenTop, row - n(0))
        case "B": row = min(screenTop + rows - 1, row + n(0)); ensureRow(row)
        case "C": col = min(cols - 1, col + n(0))
        case "D": col = max(0, col - n(0))
        case "E": row = min(screenTop + rows - 1, row + n(0)); col = 0; ensureRow(row)
        case "F": row = max(screenTop, row - n(0)); col = 0
        case "G": col = max(0, min(cols - 1, n(0) - 1))
        case "H", "f":
            // 限制在屏幕内：程序常用 ESC[999;999H 探测右下角
            row = screenTop + min(rows - 1, max(0, n(0) - 1)); col = min(cols - 1, max(0, n(1) - 1)); ensureRow(row)
        case "J":
            ensureRow(row)
            switch n(0, 0) {
            case 0:
                lines[row] = Array(lines[row].prefix(col))
                if row + 1 < lines.count { lines.removeSubrange((row + 1)...) }
            case 1:
                for r in screenTop..<row { lines[r] = [] }
                for i in 0..<min(col + 1, lines[row].count) { lines[row][i] = Cell(ch: " ", fg: nil, bold: false) }
            default:
                lines.removeSubrange(screenTop...)
                lines.append([]); row = lines.count - 1; col = 0
            }
        case "K":
            ensureRow(row)
            switch n(0, 0) {
            case 0: lines[row] = Array(lines[row].prefix(col))
            case 1: for i in 0..<min(col + 1, lines[row].count) { lines[row][i] = Cell(ch: " ", fg: nil, bold: false) }
            default: lines[row] = []
            }
        case "m": sgr(nums.map { $0 ?? 0 })
        case "s": saved = (row, col)
        case "u": (row, col) = saved
        default: break
        }
    }

    private func sgr(_ codes: [Int]) {
        let cs = codes.isEmpty ? [0] : codes
        var i = 0
        while i < cs.count {
            let c = cs[i]
            switch c {
            case 0: style = Style()
            case 1: style.bold = true
            case 22: style.bold = false
            case 30...37: style.fg = c - 30
            case 90...97: style.fg = c - 90 + 8
            case 39: style.fg = nil
            case 38:
                // 256 色 / 真彩，取近似
                if i + 2 < cs.count, cs[i + 1] == 5 { style.fg = cs[i + 2] < 16 ? cs[i + 2] : 6; i += 2 }
                else if i + 4 < cs.count, cs[i + 1] == 2 { style.fg = 6; i += 4 }
            default: break
            }
            i += 1
        }
    }

    // MARK: 渲染

    static let palette: [Color] = [
        Color(white: 0.35), Color(red: 0.94, green: 0.42, blue: 0.40), Color(red: 0.45, green: 0.80, blue: 0.50), Color(red: 0.92, green: 0.78, blue: 0.38),
        Color(red: 0.48, green: 0.62, blue: 1.0), Color(red: 0.80, green: 0.55, blue: 0.95), Color(red: 0.40, green: 0.82, blue: 0.86), Color(white: 0.85),
        Color(white: 0.55), Color(red: 1.0, green: 0.55, blue: 0.52), Color(red: 0.55, green: 0.90, blue: 0.60), Color(red: 1.0, green: 0.88, blue: 0.50),
        Color(red: 0.60, green: 0.72, blue: 1.0), Color(red: 0.88, green: 0.66, blue: 1.0), Color(red: 0.52, green: 0.92, blue: 0.95), Color.white,
    ]

    func attributed(_ r: Int, showCursor: Bool) -> AttributedString {
        var out = AttributedString()
        let line = r < lines.count ? lines[r] : []
        var i = 0
        func run(_ text: String, _ fg: Int?, _ bold: Bool, cursor: Bool = false) {
            var a = AttributedString(text)
            a.foregroundColor = cursor ? Color.black : (fg.map { Self.palette[$0 % 16] } ?? Color(white: 0.88))
            if bold { a.font = .system(size: 12.5, weight: .bold, design: .monospaced) }
            if cursor { a.backgroundColor = Color(white: 0.85) }
            out += a
        }
        while i < line.count {
            if showCursor && i == col { run(String(line[i].ch == "\u{0}" ? " " : line[i].ch), nil, false, cursor: true); i += 1; continue }
            var j = i, s = ""
            let fg = line[i].fg, bold = line[i].bold
            while j < line.count, line[j].fg == fg, line[j].bold == bold, !(showCursor && j == col) {
                if line[j].ch != "\u{0}" { s.append(line[j].ch) }
                j += 1
            }
            run(s, fg, bold)
            i = j
        }
        if showCursor && col >= line.count {
            run(String(repeating: " ", count: col - line.count), nil, false)
            run(" ", nil, false, cursor: true)
        }
        return out
    }

    var plainText: String {
        lines.map { String($0.compactMap { $0.ch == "\u{0}" ? nil : $0.ch }) }.joined(separator: "\n")
    }
}
