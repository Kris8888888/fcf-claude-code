import AppKit
// 应用图标：深青底 + 米白对话气泡，气泡里是终端提示符 >_ ——「终端变成对话」
func C(_ h: UInt32) -> NSColor { NSColor(srgbRed: CGFloat(h >> 16 & 0xFF)/255, green: CGFloat(h >> 8 & 0xFF)/255, blue: CGFloat(h & 0xFF)/255, alpha: 1) }
func draw(size s: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: s, height: s)); img.lockFocus()
    let inset = s * 0.075
    let bg = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2), xRadius: s * 0.205, yRadius: s * 0.205)
    NSGradient(starting: C(0x1F6F78), ending: C(0x0E3B43))!.draw(in: bg, angle: -90)
    // 气泡（带左下角小尾巴），下方一层淡阴影让它浮起来
    let bubble = NSBezierPath(roundedRect: NSRect(x: s * 0.20, y: s * 0.30, width: s * 0.60, height: s * 0.44), xRadius: s * 0.13, yRadius: s * 0.13)
    let tail = NSBezierPath(); tail.move(to: NSPoint(x: s * 0.30, y: s * 0.33)); tail.line(to: NSPoint(x: s * 0.26, y: s * 0.20)); tail.line(to: NSPoint(x: s * 0.42, y: s * 0.31)); tail.close()
    bubble.append(tail)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor(white: 0, alpha: 0.28); sh.shadowBlurRadius = s * 0.025; sh.shadowOffset = NSSize(width: 0, height: -s * 0.012); sh.set()
    C(0xF6F1E4).setFill(); bubble.fill()
    NSGraphicsContext.restoreGraphicsState()
    // >
    let chevron = NSBezierPath()
    chevron.move(to: NSPoint(x: s * 0.33, y: s * 0.60)); chevron.line(to: NSPoint(x: s * 0.42, y: s * 0.52)); chevron.line(to: NSPoint(x: s * 0.33, y: s * 0.44))
    chevron.lineWidth = s * 0.055; chevron.lineCapStyle = .round; chevron.lineJoinStyle = .round
    C(0x0E3B43).setStroke(); chevron.stroke()
    // _ 光标（琥珀色）
    C(0xF2A93B).setFill()
    NSBezierPath(roundedRect: NSRect(x: s * 0.48, y: s * 0.415, width: s * 0.18, height: s * 0.055), xRadius: s * 0.02, yRadius: s * 0.02).fill()
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
