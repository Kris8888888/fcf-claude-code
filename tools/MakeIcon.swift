import AppKit
// 应用图标：靛蓝底 + 一条活动轨（竖线串三个节点），呼应界面里的工具步骤轨
func draw(size s: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: s, height: s)); img.lockFocus()
    let inset = s * 0.075
    let bg = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2), xRadius: s * 0.205, yRadius: s * 0.205)
    NSGradient(starting: NSColor(srgbRed: 0x45/255, green: 0x58/255, blue: 0xCC/255, alpha: 1),
               ending: NSColor(srgbRed: 0x26/255, green: 0x34/255, blue: 0x8F/255, alpha: 1))!.draw(in: bg, angle: -90)
    let x = s * 0.36
    let line = NSBezierPath(); line.move(to: NSPoint(x: x, y: s * 0.24)); line.line(to: NSPoint(x: x, y: s * 0.76))
    line.lineWidth = s * 0.025; NSColor(white: 1, alpha: 0.45).setStroke(); line.stroke()
    let ys: [CGFloat] = [0.70, 0.50, 0.30]
    let widths: [CGFloat] = [0.30, 0.22, 0.26]
    for (i, y) in ys.enumerated() {
        let r = s * 0.045
        (i == 1 ? NSColor(srgbRed: 0xF2/255, green: 0xB4/255, blue: 0x4A/255, alpha: 1) : NSColor.white).setFill()
        NSBezierPath(ovalIn: NSRect(x: x - r, y: s * y - r, width: r * 2, height: r * 2)).fill()
        let h = s * 0.05
        NSColor(white: 1, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: NSRect(x: x + s * 0.08, y: s * y - h / 2, width: s * widths[i], height: h), xRadius: h / 2, yRadius: h / 2).fill()
    }
    img.unlockFocus(); return img
}
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let img = draw(size: CGFloat(px))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px)); NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out + "/\(name).png"))
}
