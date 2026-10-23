import SwiftUI
import AppKit

// 输入框：回车发送、Shift+回车换行；中文输入法组字时回车不发送；可粘贴图片
final class ComposerTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onImages: (([NSImage]) -> Void)?
    var onFiles: (([URL]) -> Void)?
    var onArrow: ((Int) -> Bool)?      // -1 上 / 1 下，返回 true 表示被斜杠菜单接管
    var onTab: (() -> Bool)?
    var onEscape: (() -> Void)?
    var placeholder = ""

    override func keyDown(with event: NSEvent) {
        let code = event.keyCode
        if hasMarkedText() { super.keyDown(with: event); return }
        if code == 36 || code == 76 {  // 回车
            if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option) {
                insertNewline(nil)
            } else {
                onSubmit?()
            }
            return
        }
        // ↑ 只在光标处于第一行、↓ 只在最后一行时交给菜单/历史，其余照常移动光标
        let caret = selectedRange().location
        let ns = string as NSString
        let onFirstLine = !ns.substring(to: min(caret, ns.length)).contains("\n")
        let onLastLine = !ns.substring(from: min(caret, ns.length)).contains("\n")
        if code == 126, onFirstLine, onArrow?(-1) == true { return }
        if code == 125, onLastLine, onArrow?(1) == true { return }
        if code == 48, onTab?() == true { return }
        if code == 53 { onEscape?(); return }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        if pasteAttachments(from: .general) { return }
        pasteAsPlainText(sender)
    }

    /// 剪贴板里是文件或图片就加成附件，返回 true；否则交给普通的文字粘贴
    @discardableResult
    func pasteAttachments(from pb: NSPasteboard) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            handleFiles(urls); return true
        }
        if pb.availableType(from: [.png, .tiff]) != nil, let imgs = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage], !imgs.isEmpty {
            onImages?(imgs); return true
        }
        return false
    }

    static func hasAttachments(_ pb: NSPasteboard) -> Bool {
        pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pb.availableType(from: [.png, .tiff]) != nil
    }

    // 纯文本输入框在剪贴板没有文字时会把「粘贴」置灰，⌘V 根本到不了 paste()。这里直接接管 ⌘V
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "v", window?.firstResponder === self {
            paste(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // 菜单栏「编辑 → 粘贴」也一样：有文件/图片时保持可用
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), Self.hasAttachments(.general) { return true }
        return super.validateUserInterfaceItem(item)
    }

    func handleFiles(_ raw: [URL]) {
        // 访达有时给的是 /.file/id=… 形式的引用，转成真实路径
        let urls = raw.map { (($0 as NSURL).filePathURL ?? $0).standardizedFileURL }
        var imgs: [NSImage] = []
        var files: [URL] = []
        for u in urls {
            if FileKind.imageExts.contains(u.pathExtension.lowercased()), let img = NSImage(contentsOf: u) {
                imgs.append(img)
            } else {
                files.append(u)
            }
        }
        if !imgs.isEmpty { onImages?(imgs) }
        if !files.isEmpty { onFiles?(files) }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            handleFiles(urls); return true
        }
        if let imgs = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage], !imgs.isEmpty {
            onImages?(imgs); return true
        }
        return super.performDragOperation(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: fs(14)), .foregroundColor: NSColor.placeholderTextColor]
        placeholder.draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height), withAttributes: attrs)
    }
}

struct InputTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String
    var focusToken: Int
    var onSubmit: () -> Void
    var onImages: ([NSImage]) -> Void
    var onFiles: ([URL]) -> Void
    var onArrow: (Int) -> Bool
    var onTab: () -> Bool
    var onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let tv = ComposerTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .systemFont(ofSize: fs(14))
        tv.textColor = .labelColor
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 2, height: 4)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.registerForDraggedTypes([.fileURL, .png, .tiff])
        scroll.documentView = tv
        context.coordinator.tv = tv
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = context.coordinator.tv else { return }
        context.coordinator.parent = self
        tv.placeholder = placeholder
        tv.onSubmit = onSubmit
        tv.onImages = onImages
        tv.onFiles = onFiles
        tv.onArrow = onArrow
        tv.onTab = onTab
        tv.onEscape = onEscape
        if tv.string != text {
            tv.string = text
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            context.coordinator.recalc()
        }
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
        tv.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InputTextView
        weak var tv: ComposerTextView?
        var focusToken = 0
        init(_ p: InputTextView) { parent = p; focusToken = p.focusToken }

        func textDidChange(_ n: Notification) {
            guard let tv else { return }
            parent.text = tv.string
            recalc()
        }

        func recalc() {
            guard let tv, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let h = min(max(lm.usedRect(for: tc).height + 10, 24), 220)
            if abs(h - parent.height) > 0.5 { DispatchQueue.main.async { self.parent.height = h } }
        }
    }
}
