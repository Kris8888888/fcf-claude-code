import SwiftUI
import AppKit

/// 把一段 Markdown 排成「一整块」富文本：段落、标题、列表、引用、代码块、表格都在同一个文本里，
/// 这样能跨段落、跨列表、跨表格拖选和复制（之前每段是单独的 Text，只能选中一段）
enum MarkdownAttr {
    private static let cache = NSCache<NSString, NSAttributedString>()

    static func cached(_ text: String) -> NSAttributedString {
        let key = "\(ThemeStore.shared.revision)|\(text)" as NSString
        if let a = cache.object(forKey: key) { return a }
        let a = build(text)
        cache.setObject(a, forKey: key)
        return a
    }

    static var ink: NSColor { NSColor(T.ink) }
    static var muted: NSColor { NSColor(T.muted) }
    static var line: NSColor { NSColor(T.line) }
    static var sunk: NSColor { NSColor(T.sunk) }
    static var accent: NSColor { NSColor(T.accent) }

    static let bodySize: CGFloat = 14

    static func para(lineSpacing: CGFloat = 4, after: CGFloat = 10, before: CGFloat = 0, indent: CGFloat = 0, head: CGFloat? = nil) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = lineSpacing
        p.paragraphSpacing = after
        p.paragraphSpacingBefore = before
        p.firstLineHeadIndent = indent
        p.headIndent = head ?? indent
        return p
    }

    /// 行内：粗体、斜体、行内代码、删除线、链接
    static func inline(_ s: String, font: NSFont, color: NSColor) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        let a = MarkdownParser.inline(s)
        for run in a.runs {
            let str = String(a[run.range].characters)
            var f = font
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
                if intent.contains(.code) {
                    f = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
                    attrs[.backgroundColor] = sunk
                }
                if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let link = run.link {
                attrs[.link] = link
                attrs[.foregroundColor] = accent
            }
            attrs[.font] = f
            out.append(NSAttributedString(string: str, attributes: attrs))
        }
        return out
    }

    static func build(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: bodySize)
        let blocks = MDCache.blocks(text)

        func add(_ s: NSAttributedString, _ p: NSParagraphStyle) {
            let m = NSMutableAttributedString(attributedString: s)
            m.append(NSAttributedString(string: "\n"))
            m.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: m.length))
            out.append(m)
        }

        // 表格、代码块后面留一点空，免得和下一段贴在一起
        func spacer() { add(NSAttributedString(string: "\u{200B}", attributes: [.font: NSFont.systemFont(ofSize: 4)]), para(lineSpacing: 0, after: 4)) }

        for b in blocks {
            switch b {
            case .heading(let lv, let s):
                let size: CGFloat = lv <= 1 ? 19 : lv == 2 ? 17 : 15
                add(inline(s, font: .systemFont(ofSize: size, weight: .semibold), color: ink), para(after: 6, before: 6))

            case .paragraph(let s):
                add(inline(s, font: body, color: ink), para())

            case .bullet(let s, let lv, let n):
                let indent = CGFloat(lv) * 18
                let marker = NSMutableAttributedString(string: (n.map { "\($0)." } ?? "•") + "\t",
                                                       attributes: [.font: body, .foregroundColor: muted])
                marker.append(inline(s, font: body, color: ink))
                let p = para(after: 5, indent: indent, head: indent + 22)
                p.tabStops = [NSTextTab(textAlignment: .left, location: indent + 22)]
                p.defaultTabInterval = 22
                add(marker, p)

            case .quote(let s):
                let block = NSTextBlock()
                block.setValue(100, type: .percentageValueType, for: .width)   // 不给宽度就不画边框
                block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
                block.setBorderColor(line, for: .minX)
                block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
                block.setWidth(4, type: .absoluteValueType, for: .margin, edge: .maxY)
                for l in s.components(separatedBy: "\n") {
                    let p = para(after: 2); p.textBlocks = [block]
                    add(inline(l, font: body, color: muted), p)
                }

            case .code(_, let code):
                let block = NSTextBlock()
                block.setValue(100, type: .percentageValueType, for: .width)
                block.backgroundColor = sunk
                block.setBorderColor(line)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
                block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .maxX)
                block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minY)
                block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .maxY)
                let mono = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
                let lines = code.components(separatedBy: "\n")
                for l in lines {
                    let p = para(lineSpacing: 2, after: 0); p.textBlocks = [block]
                    add(NSAttributedString(string: l.isEmpty ? " " : l, attributes: [.font: mono, .foregroundColor: ink]), p)
                }
                spacer()

            case .table(let rows):
                let cols = rows.map(\.count).max() ?? 0
                guard cols > 0 else { continue }
                let table = NSTextTable()
                table.numberOfColumns = cols
                table.layoutAlgorithm = .automaticLayoutAlgorithm
                table.collapsesBorders = true
                table.setWidth(10, type: .absoluteValueType, for: .margin, edge: .maxY)
                for (ri, r) in rows.enumerated() {
                    for ci in 0..<cols {
                        let cell = NSTextTableBlock(table: table, startingRow: ri, rowSpan: 1, startingColumn: ci, columnSpan: 1)
                        cell.setWidth(1, type: .absoluteValueType, for: .border)
                        cell.setBorderColor(line)
                        cell.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
                        cell.setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxX)
                        cell.setWidth(6, type: .absoluteValueType, for: .padding, edge: .minY)
                        cell.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxY)
                        if ri == 0 { cell.backgroundColor = sunk }
                        let p = para(lineSpacing: 2, after: 0); p.textBlocks = [cell]
                        let f: NSFont = ri == 0 ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 13)
                        add(inline(ci < r.count ? r[ci] : "", font: f, color: ink), p)
                    }
                }
                spacer()

            case .rule:
                let block = NSTextBlock()
                block.setValue(100, type: .percentageValueType, for: .width)
                block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
                block.setBorderColor(line, for: .maxY)
                block.setWidth(8, type: .absoluteValueType, for: .margin, edge: .maxY)
                let p = para(lineSpacing: 0, after: 0); p.textBlocks = [block]
                add(NSAttributedString(string: "\u{200B}", attributes: [.font: NSFont.systemFont(ofSize: 4)]), p)
            }
        }
        // 去掉末尾多余的换行
        while out.length > 0, out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        return out
    }
}

/// 只读、可选中的富文本视图，高度随内容撑开
struct SelectableText: NSViewRepresentable {
    let attr: NSAttributedString

    final class TV: NSTextView {
        // 让滚轮交给外层的对话列表滚动
        override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
    }

    func makeNSView(context: Context) -> TV {
        let tv = TV()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.isRichText = true
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.linkTextAttributes = [.foregroundColor: NSColor(T.accent), .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
        tv.textStorage?.setAttributedString(attr)
        return tv
    }

    func updateNSView(_ tv: TV, context: Context) {
        if tv.textStorage?.isEqual(to: attr) != true { tv.textStorage?.setAttributedString(attr) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: TV, context: Context) -> CGSize? {
        var w = proposal.width ?? 640
        if !w.isFinite || w <= 0 { w = 640 }
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
        tc.containerSize = NSSize(width: w, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let h = lm.usedRect(for: tc).height
        return CGSize(width: w, height: ceil(h) + 2)
    }
}
