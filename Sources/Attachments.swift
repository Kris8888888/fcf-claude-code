import SwiftUI
import AppKit

// 附件卡片：类型图标 + 文件名 + 「类型 · 大小」
enum FileKind {
    static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic"]

    static func info(_ url: URL) -> (badge: String, color: Color, type: String) {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return ("folder.fill", T.accent, "文件夹")
        }
        switch url.pathExtension.lowercased() {
        case "doc", "docx", "pages", "rtf": return ("W", Color(red: 0.17, green: 0.37, blue: 0.86), "Word")
        case "pdf": return ("pdf", Color(red: 0.86, green: 0.22, blue: 0.20), "PDF")
        case "xls", "xlsx", "csv", "numbers": return ("X", Color(red: 0.12, green: 0.56, blue: 0.31), "Excel")
        case "ppt", "pptx", "key": return ("P", Color(red: 0.87, green: 0.42, blue: 0.13), "PPT")
        case "md", "txt": return ("doc.text", T.muted, url.pathExtension.lowercased() == "md" ? "Markdown" : "文本")
        case "zip", "rar", "7z", "gz": return ("archivebox", T.muted, "压缩包")
        case "fig", "sketch", "psd", "ai", "svg": return ("paintbrush.pointed", Color(red: 0.55, green: 0.33, blue: 0.85), url.pathExtension.uppercased())
        case "mp4", "mov", "m4v": return ("film", T.muted, "视频")
        case "mp3", "wav", "m4a": return ("waveform", T.muted, "音频")
        case "html", "htm": return ("chevron.left.forwardslash.chevron.right", Color(red: 0.49, green: 0.36, blue: 0.93), "网页")
        case "js", "ts", "swift", "py", "json", "css", "jsx", "tsx": return ("chevron.left.forwardslash.chevron.right", T.muted, url.pathExtension.uppercased())
        case "": return ("doc", T.muted, "文件")
        default: return ("doc", T.muted, url.pathExtension.uppercased())
        }
    }

    static func size(_ url: URL) -> String? {
        guard let n = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64,
              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else { return nil }
        if n < 1000 { return "\(n) B" }
        if n < 1_000_000 { return "\(Int((Double(n) / 1000).rounded())) KB" }
        return String(format: "%.1f MB", Double(n) / 1_000_000)
    }

    // 附件路径随消息发给 Claude，用标签包住，历史记录里能还原成卡片
    static let open = "<attached-files>", close = "</attached-files>"

    static func encode(_ urls: [URL]) -> String {
        "\n\n" + open + "\n" + urls.map(\.path).joined(separator: "\n") + "\n" + close
    }

    static func decode(_ s: String) -> (text: String, files: [URL]) {
        guard let r = s.range(of: open), let e = s.range(of: close, range: r.upperBound..<s.endIndex) else { return (s, []) }
        let files = s[r.upperBound..<e.lowerBound].split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
        let text = (String(s[..<r.lowerBound]) + String(s[e.upperBound...])).trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, files)
    }
}

struct FileBadge: View {
    let url: URL
    var body: some View {
        let i = FileKind.info(url)
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(i.color.opacity(0.12))
            if i.badge.count <= 3 && !i.badge.contains(".") && i.badge.lowercased() != "doc" {
                Text(i.badge == "pdf" ? "PDF" : i.badge)
                    .font(.system(size: i.badge == "pdf" ? 9 : 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(i.color)
            } else {
                Image(systemName: i.badge).font(.system(size: 14, weight: .semibold)).foregroundStyle(i.color)
            }
        }
        .frame(width: 32, height: 32)
    }
}

struct FileCard: View {
    let url: URL
    var onRemove: (() -> Void)? = nil
    @State private var hover = false

    var body: some View {
        let i = FileKind.info(url)
        HStack(spacing: 10) {
            FileBadge(url: url)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent).font(.system(size: 13)).foregroundStyle(T.ink)
                    .lineLimit(1).truncationMode(.middle)
                Text([i.type, FileKind.size(url)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(T.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(width: 210)
        .background(RoundedRectangle(cornerRadius: 12).fill(T.sunk))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(T.line.opacity(0.7), lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if let onRemove, hover {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15))
                        .foregroundStyle(.white, T.ink.opacity(0.55))
                }
                .buttonStyle(.plain).offset(x: 5, y: -5).help("移除")
            }
        }
        .onHover { hover = $0 }
        .help(url.path)
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .contextMenu {
            Button("打开") { NSWorkspace.shared.open(url) }
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}

struct ImageCard: View {
    let image: NSImage
    var onRemove: (() -> Void)? = nil
    @State private var hover = false
    var body: some View {
        Image(nsImage: image).resizable().scaledToFill()
            .frame(width: 50, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(T.line.opacity(0.7), lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if let onRemove, hover {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(.white, T.ink.opacity(0.55))
                    }
                    .buttonStyle(.plain).offset(x: 5, y: -5)
                }
            }
            .onHover { hover = $0 }
    }
}

// MARK: 文件产物：一轮回复里 Claude 新建 / 修改的文件

struct Artifact: Hashable {
    let url: URL
    let created: Bool      // Write = 新建（或整体覆盖），Edit = 修改
}

enum Artifacts {
    static let claudeHome = NSString(string: "~/.claude").expandingTildeInPath

    /// 从一段工具步骤里挑出产物：去重、只要成功的、排除 Claude 自己的配置和记忆
    static func collect(_ items: ArraySlice<ChatItem>) -> [Artifact] {
        var out: [Artifact] = []
        var seen = Set<String>()
        for it in items where it.kind == .tool && it.toolState != .failed {
            let created: Bool
            switch it.toolName {
            case "Write": created = true
            case "Edit", "MultiEdit", "NotebookEdit": created = false
            default: continue
            }
            guard let p = (it.toolInput["file_path"] ?? it.toolInput["notebook_path"]) as? String, !p.isEmpty else { continue }
            let path = (p as NSString).expandingTildeInPath
            if path.hasPrefix(claudeHome + "/") { continue }
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if let i = out.firstIndex(where: { $0.url.path == path }) {
                if created && !out[i].created { out[i] = Artifact(url: out[i].url, created: true) }
                continue
            }
            if seen.insert(path).inserted { out.append(Artifact(url: URL(fileURLWithPath: path), created: created)) }
        }
        return out
    }

    static func open(_ url: URL) {
        // HTML 用火狐打开（没装就用默认浏览器）
        if ["html", "htm"].contains(url.pathExtension.lowercased()),
           let ff = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.mozilla.firefox") {
            NSWorkspace.shared.open([url], withApplicationAt: ff, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// 系统快速查看（空格预览那个窗口）
    static func quickLook(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        p.arguments = ["-p", url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

struct ArtifactCard: View {
    let artifact: Artifact
    @State private var hover = false

    var body: some View {
        let url = artifact.url
        let exists = FileManager.default.fileExists(atPath: url.path)
        HStack(spacing: 12) {
            FileBadge(url: url).scaleEffect(1.1)
            VStack(alignment: .leading, spacing: 3) {
                Text(url.lastPathComponent).font(.system(size: 14, weight: .semibold)).foregroundStyle(T.ink)
                    .lineLimit(1).truncationMode(.middle)
                Text(exists ? [artifact.created ? "新建" : "修改", FileKind.size(url)].compactMap { $0 }.joined(separator: " · ") : "文件已不在原位置")
                    .font(.system(size: 12)).foregroundStyle(exists ? T.muted : T.err)
            }
            Spacer(minLength: 8)
            if exists {
                HStack(spacing: 2) {
                    iconButton("eye", "快速查看") { Artifacts.quickLook(url) }
                    iconButton("folder", "在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Menu {
                        Button("打开") { Artifacts.open(url) }
                        Button("复制路径") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.path, forType: .string)
                        }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 14)).foregroundStyle(T.muted).frame(width: 30, height: 30)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                .opacity(hover ? 1 : 0.75)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: 600, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(hover ? T.line.opacity(0.55) : T.sunk))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(T.line.opacity(0.7), lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { if exists { Artifacts.open(url) } }
        .help(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") + "\n双击打开")
    }

    func iconButton(_ icon: String, _ tip: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(T.muted).frame(width: 30, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(tip)
    }
}
