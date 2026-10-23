import SwiftUI
import AppKit

// 轻量 Markdown：标题 / 列表 / 引用 / 代码块 / 表格 / 分隔线，行内交给系统解析
enum MDBlock: Hashable {
    case heading(Int, String)
    case paragraph(String)
    case bullet(String, Int, String?)   // 内容、缩进层级、序号（nil 为圆点）
    case quote(String)
    case code(String, String)
    case table([[String]])
    case rule
}

enum MarkdownParser {
    static func parse(_ src: String) -> [MDBlock] {
        var out: [MDBlock] = []
        var para: [String] = []
        let lines = src.components(separatedBy: "\n")
        var i = 0
        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))); para = [] }
        }
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                flush()
                let lang = String(t.dropFirst(3))
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                out.append(.code(lang, code.joined(separator: "\n")))
                i += 1
                continue
            }
            if t.isEmpty { flush(); i += 1; continue }
            if t.hasPrefix("|") {
                flush()
                var rows: [[String]] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    let r = lines[i].trimmingCharacters(in: .whitespaces)
                    var cells = r.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                    if cells.first == "" { cells.removeFirst() }
                    if cells.last == "" { cells.removeLast() }
                    let isSep = cells.allSatisfy { c in !c.isEmpty && c.allSatisfy { "-:".contains($0) } }
                    if !isSep { rows.append(cells) }
                    i += 1
                }
                out.append(.table(rows))
                continue
            }
            if t == "---" || t == "***" || t == "___" { flush(); out.append(.rule); i += 1; continue }
            if let h = t.firstIndex(where: { $0 != "#" }), t.hasPrefix("#"), t[h] == " " {
                flush()
                out.append(.heading(t.distance(from: t.startIndex, to: h), String(t[h...]).trimmingCharacters(in: .whitespaces)))
                i += 1; continue
            }
            if t.hasPrefix(">") {
                flush()
                var q: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    q.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                out.append(.quote(q.joined(separator: "\n")))
                continue
            }
            let indent = line.prefix { $0 == " " }.count / 2
            if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") {
                flush(); out.append(.bullet(String(t.dropFirst(2)), indent, nil)); i += 1; continue
            }
            if let dot = t.firstIndex(of: "."), t[..<dot].allSatisfy(\.isNumber), !t[..<dot].isEmpty,
               t.index(after: dot) < t.endIndex, t[t.index(after: dot)] == " " {
                flush()
                out.append(.bullet(String(t[t.index(dot, offsetBy: 2)...]), indent, String(t[..<dot])))
                i += 1; continue
            }
            para.append(line)
            i += 1
        }
        flush()
        return out
    }

    static func inline(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                           failurePolicy: .returnPartiallyParsedIfPossible)
        var a = (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
        for run in a.runs where run.inlinePresentationIntent?.contains(.code) == true {
            a[run.range].font = .system(size: fs(13), design: .monospaced)
            a[run.range].backgroundColor = T.sunk
        }
        return a
    }
}

final class MDCache {
    static let shared = NSCache<NSString, Box>()
    final class Box { let blocks: [MDBlock]; init(_ b: [MDBlock]) { blocks = b } }
    static func blocks(_ text: String) -> [MDBlock] {
        let key = text as NSString
        if let b = shared.object(forKey: key) { return b.blocks }
        let b = MarkdownParser.parse(text)
        shared.setObject(Box(b), forKey: key)
        return b
    }
}

struct MarkdownView: View {
    let text: String
    var body: some View {
        // 整段回复排成一个可选中的富文本，能跨段落、跨列表、跨表格拖选复制
        SelectableText(attr: MarkdownAttr.cached(text))
    }
}

struct CodeBlock: View {
    let lang: String
    let code: String
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lang.isEmpty ? "代码" : lang).font(T.small).foregroundStyle(T.muted)
                Spacer()
                Button(copied ? "已复制" : "复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .buttonStyle(.plain).font(T.small).foregroundStyle(copied ? T.ok : T.accent)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Rectangle().fill(T.line).frame(height: 1)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(T.mono).foregroundStyle(T.ink).padding(12).textSelection(.enabled)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(T.sunk))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.line, lineWidth: 1))
    }
}

struct TableBlock: View {
    let rows: [[String]]

    /// 先量每列最长内容的宽度，再给每列定宽（最宽 300）：文字在列内换行，行高跟着撑开，不会叠在一起
    var widths: [CGFloat] {
        let cols = rows.map(\.count).max() ?? 0
        let body = NSFont.systemFont(ofSize: fs(13)), bold = NSFont.systemFont(ofSize: fs(13), weight: .semibold)
        return (0..<cols).map { ci in
            var w: CGFloat = 0
            for (ri, r) in rows.enumerated() where ci < r.count {
                let plain = String(MarkdownParser.inline(r[ci]).characters)
                let longest = plain.components(separatedBy: "\n").map { ($0 as NSString).size(withAttributes: [.font: ri == 0 ? bold : body]).width }.max() ?? 0
                w = max(w, longest)
            }
            return min(max(w + 22, 56), 300)
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) { TableGrid(rows: rows, widths: widths) }
    }
}

struct TableGrid: View {
    let rows: [[String]]
    let widths: [CGFloat]
    var body: some View {
        let ws = widths
        Group {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { ri, r in
                    GridRow(alignment: .top) {
                        ForEach(0..<ws.count, id: \.self) { ci in
                            Text(MarkdownParser.inline(ci < r.count ? r[ci] : ""))
                                .font(ri == 0 ? .system(size: fs(13), weight: .semibold) : .system(size: fs(13)))
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .frame(width: ws[ci], alignment: .topLeading)
                        }
                    }
                    .background(ri == 0 ? T.sunk : Color.clear)
                    if ri < rows.count - 1 { Divider().gridCellUnsizedAxes(.horizontal) }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.line, lineWidth: 1))
        }
    }
}
