import SwiftUI
import AppKit

// 团子的样子：颜色取自 App 图标（米白气泡、深青描边、琥珀光标），不跟主题变，放在什么桌面上都认得出
enum PetInk {
    static let body = Color(red: 0.969, green: 0.914, blue: 0.812)
    static let sickBody = Color(red: 0.918, green: 0.914, blue: 0.808)
    static let line = Color(red: 0.055, green: 0.231, blue: 0.263)
    static let cheek = Color(red: 0.949, green: 0.612, blue: 0.522)
    static let amber = Color(red: 0.949, green: 0.702, blue: 0.239)
    static let mouth = Color(red: 0.776, green: 0.365, blue: 0.290)
    static let cool = Color(red: 0.659, green: 0.847, blue: 0.918)
    static let teal = Color(red: 0.122, green: 0.435, blue: 0.471)
    // 小螃蟹：Claude Code 欢迎界面里那只像素小螃蟹的橙色
    static let crab = Color(red: 0.851, green: 0.467, blue: 0.341)
    static let crabShade = Color(red: 0.741, green: 0.380, blue: 0.267)
    static let crabSick = Color(red: 0.800, green: 0.600, blue: 0.520)
    static let crabEye = Color(red: 0.118, green: 0.078, blue: 0.063)
}

/// 画一帧需要的全部信息（不碰 store，方便截图测试）
struct PetFrame {
    var pose: PetPose
    var t: Double              // 时钟秒数
    var actT: Double           // 这个动作开始了多久
    var look = CGVector.zero   // 看向鼠标：-1…1
    var place = ""
    var back = ""
    var character = PetCharacter.crab
    var perch = false          // 趴在窗口顶边：边线以下藏在窗口后面
    var focusLeft: Double?     // 专注剩下的秒数：头顶挂个倒计时
}

// 画笔：Core Graphics 上包一层，用法跟 SwiftUI 的 GraphicsContext 一样（复制一份就是独立的变换和透明度）。
// 不用 SwiftUI Canvas：它每一帧都要重新布局整个浮窗，发呆时也要吃 5% CPU；直接画只重绘这一小块
enum PenShade {
    case color(Color)
    var cg: CGColor { if case .color(let c) = self { return NSColor(c).cgColor }; return .black }
}

struct Pen {
    let cg: CGContext
    var ctm = CGAffineTransform.identity
    var opacity: Double = 1
    var clipRect: CGRect?      // 已换算到画布坐标

    /// 只画这个矩形里面（按当前坐标系）
    mutating func clip(_ r: CGRect) { clipRect = r.applying(ctm) }

    mutating func scaleBy(x: CGFloat, y: CGFloat) { ctm = ctm.scaledBy(x: x, y: y) }
    mutating func translateBy(x: CGFloat, y: CGFloat) { ctm = ctm.translatedBy(x: x, y: y) }
    mutating func rotate(by a: Angle) { ctm = ctm.rotated(by: a.radians) }

    private func run(_ body: (CGContext) -> Void) {
        cg.saveGState()
        if let clipRect { cg.clip(to: clipRect) }
        cg.concatenate(ctm); cg.setAlpha(opacity); body(cg)
        cg.restoreGState()
    }
    func fill(_ p: Path, with s: PenShade) { run { $0.addPath(p.cgPath); $0.setFillColor(s.cg); $0.fillPath() } }
    func stroke(_ p: Path, with s: PenShade, lineWidth: CGFloat) { stroke(p, with: s, style: StrokeStyle(lineWidth: lineWidth)) }
    func stroke(_ p: Path, with s: PenShade, style: StrokeStyle) {
        run { c in
            c.addPath(p.cgPath)
            c.setStrokeColor(s.cg); c.setLineWidth(style.lineWidth); c.setLineCap(style.lineCap); c.setLineJoin(style.lineJoin)
            c.strokePath()
        }
    }

    private static var fonts: [String: NSFont] = [:]
    func text(_ s: String, size: CGFloat, weight: NSFont.Weight, mono: Bool = false, color: Color, at p: CGPoint) {
        let key = "\(size)-\(weight.rawValue)-\(mono)"
        let font = Self.fonts[key] ?? {
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            let f = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                : (base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base)
            Self.fonts[key] = f
            return f
        }()
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor(color)])
        let sz = a.size()
        run { c in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
            a.draw(at: CGPoint(x: p.x - sz.width / 2, y: p.y - sz.height / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

enum PetPainter {
    static let unit = CGSize(width: 120, height: 112)

    /// 头顶（团子含呆毛）在画布里的高度，气泡贴着它放
    static func headTop(_ c: PetCharacter, perch: Bool) -> CGFloat {
        c == .crab ? 48 + (perch ? 14 : 0) : 23 + (perch ? 6 : 0)
    }

    /// 小螃蟹身体宽几格
    static let crabW: CGFloat = 12
    /// 趴着时窗口顶边在画布里的位置
    static let perchEdge: CGFloat = 88

    static func draw(_ g: inout Pen, size: CGSize, f: PetFrame) {
        g.scaleBy(x: size.width / unit.width, y: size.height / unit.height)
        if f.pose == .away {
            if f.perch { g.translateBy(x: 0, y: -16) }
            drawTag(&g, f); return
        }
        defer { if let left = f.focusLeft, f.pose != .dragged { focusPill(&g, f, left) } }
        guard f.perch else { drawCharacter(&g, f); return }
        // 趴在窗口顶边：身子往下沉，边线以下剪掉（像躲在窗口后面），再把两只手搭在边上
        var body = g
        body.clip(CGRect(x: -60, y: -200, width: 240, height: 200 + perchEdge))
        body.translateBy(x: 0, y: f.character == .crab ? 14 : 6)
        drawCharacter(&body, f)
        paws(&g, f)
    }

    /// 专注倒计时：头顶上一个小牌子
    private static func focusPill(_ g: inout Pen, _ f: PetFrame, _ left: Double) {
        let top = headTop(f.character, perch: f.perch)
        let s = Int(left.rounded(.up))
        let text = String(format: "%d:%02d", s / 60, s % 60)
        let w: CGFloat = text.count > 4 ? 40 : 34
        let r = CGRect(x: 60 - w / 2, y: top - 21, width: w, height: 14)
        g.fill(Path(roundedRect: r, cornerRadius: 7), with: .color(PetInk.line))
        g.text(text, size: 9.5, weight: .bold, mono: true, color: PetInk.amber, at: CGPoint(x: r.midX, y: r.midY))
    }

    private static func drawCharacter(_ g: inout Pen, _ f: PetFrame) {
        if f.character == .crab { drawCrab(&g, f) } else { drawMochi(&g, f) }
    }

    /// 哪只手举着（举着的手不搭在窗口边上）
    private static func raised(_ p: PetPose, crab: Bool) -> (l: Bool, r: Bool) {
        switch p {
        case .celebrate, .stretch, .dragged: return (true, true)
        case .wave: return (false, true)
        case .waiting: return (false, crab)
        default: return (false, false)
        }
    }

    private static func paws(_ g: inout Pen, _ f: PetFrame) {
        let up = raised(f.pose, crab: f.character == .crab)
        let y = perchEdge
        if f.character == .crab {
            // 两只钳子从身体两侧伸出来，搭在窗口边上
            let c: CGFloat = 5.2, half = crabW / 2 * c
            for (i, x) in [60 - half - 1.6 * c, 60 + half - 0.6 * c].enumerated() where !(i == 0 ? up.l : up.r) {
                let r = CGRect(x: x, y: y - 1.3 * c, width: 2.2 * c, height: 1.6 * c)
                g.fill(Path(r), with: .color(PetInk.crab))
                g.fill(Path(CGRect(x: r.minX, y: r.maxY - 0.5 * c, width: r.width, height: 0.5 * c)), with: .color(PetInk.crabShade))
                g.fill(Path(CGRect(x: r.midX - 0.12 * c, y: r.minY, width: 0.24 * c, height: 0.7 * c)), with: .color(PetInk.crabShade))
            }
        } else {
            for (i, x) in [40.0, 80.0].enumerated() where !(i == 0 ? up.l : up.r) {
                let r = CGRect(x: x - 7.5, y: y - 5, width: 15, height: 9)
                g.fill(Path(ellipseIn: r), with: .color(PetInk.body))
                g.stroke(Path(ellipseIn: r), with: .color(PetInk.line), lineWidth: 2)
            }
        }
    }

    private static func drawMochi(_ g: inout Pen, _ f: PetFrame) {
        let p = f.pose, t = f.t, a = f.actT
        let ground: CGFloat = 100
        var bob: CGFloat = 0, sx: CGFloat = 1, sy: CGFloat = 1, dx: CGFloat = 0
        let breath = CGFloat(sin(t * 2 * .pi / (p == .sleeping ? 4.5 : 3.2)))
        sy += (p == .sleeping ? 0.035 : 0.022) * breath
        sx -= (p == .sleeping ? 0.018 : 0.012) * breath
        switch p {
        case .working: bob = -1.6 * CGFloat(abs(sin(t * 9)))
        case .waiting:
            let h = sin(t * 5.5)
            bob = -9 * CGFloat(max(0, h))
            if h < -0.75 { sy *= 0.94; sx *= 1.04 }
        case .celebrate, .wave: bob = -12 * CGFloat(abs(sin(a * 7))) * CGFloat(max(0, 1 - a / 2.6))
        case .poked:
            let k = CGFloat(max(0, 1 - a / 0.6))
            sy *= 1 - 0.14 * k; sx *= 1 + 0.1 * k
        case .dragged: sy = 1.12; sx = 0.9; bob = -4
        case .stretch:
            let k = CGFloat(sin(min(1, a / 2) * .pi))
            sy *= 1 + 0.14 * k; sx *= 1 - 0.07 * k
        case .pout: sx *= 1.05; dx = a < 0.45 ? 1.6 * CGFloat(sin(a * 45)) : 0
        case .eating: sy *= 1 + 0.03 * CGFloat(sin(a * 12))
        case .sick: dx = (t.truncatingRemainder(dividingBy: 5) < 0.5) ? 0.7 * CGFloat(sin(t * 40)) : 0
        default: break
        }
        let w = 80 * sx, h = 62 * sy
        let rect = CGRect(x: 60 - w / 2 + dx, y: ground - h + bob, width: w, height: h)

        // 影子：跳起来时变小
        let lift = min(0.45, -bob / 30)
        let sw = 58 * (1 - lift) * (p == .dragged ? 0.6 : 1)
        g.fill(Path(ellipseIn: CGRect(x: 60 - sw / 2, y: ground + 1, width: sw, height: 7)), with: .color(.black.opacity(p == .dragged ? 0.06 : 0.13)))

        // 脚
        for side in [-1.0, 1.0] {
            var fy = ground - 5 + bob, fx = 60 + CGFloat(side) * 16 + dx
            if p == .dragged { fy += 4; fx += 2.5 * CGFloat(sin(t * 6 + side)) }
            let r = CGRect(x: fx - 7.5, y: fy, width: 15, height: 8)
            g.fill(Path(ellipseIn: r), with: .color(PetInk.body))
            g.stroke(Path(ellipseIn: r), with: .color(PetInk.line), lineWidth: 2)
        }

        // 小手：伸懒腰、庆祝、挥手、被拎着时才露出来
        func arm(from: CGPoint, to: CGPoint) {
            var path = Path(); path.move(to: from); path.addLine(to: to)
            g.stroke(path, with: .color(PetInk.line), style: StrokeStyle(lineWidth: 9.5, lineCap: .round))
            g.stroke(path, with: .color(PetInk.body), style: StrokeStyle(lineWidth: 5.4, lineCap: .round))
        }
        switch p {
        case .dragged:
            arm(from: CGPoint(x: rect.minX + 7, y: rect.midY), to: CGPoint(x: rect.minX - 4, y: rect.minY + 6))
            arm(from: CGPoint(x: rect.maxX - 7, y: rect.midY), to: CGPoint(x: rect.maxX + 4, y: rect.minY + 6))
        case .stretch, .celebrate:
            arm(from: CGPoint(x: rect.minX + 6, y: rect.midY + 6), to: CGPoint(x: rect.minX - 9, y: rect.midY - 12))
            arm(from: CGPoint(x: rect.maxX - 6, y: rect.midY + 6), to: CGPoint(x: rect.maxX + 9, y: rect.midY - 12))
        case .wave:
            let ang = CGFloat(sin(a * 10)) * 0.5
            arm(from: CGPoint(x: rect.maxX - 7, y: rect.midY), to: CGPoint(x: rect.maxX + 6 + 6 * ang, y: rect.minY + 2 - 3 * ang))
        default: break
        }

        // 身体：一块麻薯
        let bodyPath = Path(roundedRect: rect, cornerRadius: min(w, h) * 0.47, style: .continuous)
        g.fill(bodyPath, with: .color(p == .sick || p == .medicine ? PetInk.sickBody : PetInk.body))
        g.stroke(bodyPath, with: .color(PetInk.line), lineWidth: 2.4)

        // 脸
        var look = f.look
        if p == .working { look = CGVector(dx: look.dx * 0.5, dy: 0.9) }
        if p == .waiting { look = CGVector(dx: look.dx * 0.5, dy: -0.8) }
        if p == .sleeping || p == .medicine { look = .zero }
        let fx = rect.midX + look.dx * 2.6, fy = rect.minY + rect.height * 0.46 + look.dy * 1.6
        drawEyes(&g, p: p, fx: fx, fy: fy, t: t, look: look)

        let cheekA: Double = (p == .sick || p == .pout || p == .petted) ? 0.85 : 0.55
        for side in [-1.0, 1.0] {
            let cw: CGFloat = p == .pout ? 11 : 9
            g.fill(Path(ellipseIn: CGRect(x: fx + CGFloat(side) * 21 - cw / 2, y: fy + 5, width: cw, height: 5.5)), with: .color(PetInk.cheek.opacity(cheekA)))
        }
        drawMouth(&g, p: p, x: fx, y: fy + 8.5, a: a)

        drawTuft(&g, p: p, base: CGPoint(x: rect.midX + dx, y: rect.minY + 1.5), t: t, a: a)

        // 附带的小东西
        switch p {
        case .petted: hearts(&g, rect: rect, a: a)
        case .celebrate: confetti(&g, rect: rect, a: a)
        case .eating: token(&g, to: CGPoint(x: fx, y: fy + 10), from: CGPoint(x: rect.maxX + 18, y: rect.minY - 4), a: a)
        case .medicine: pill(&g, to: CGPoint(x: fx, y: fy + 10), a: a)
        case .oops: sweat(&g, at: CGPoint(x: rect.maxX - 9, y: rect.minY + 10 + CGFloat(min(a, 1.5)) * 4))
        case .sick: sweat(&g, at: CGPoint(x: rect.maxX - 9, y: rect.minY + 12))
        case .sleeping: zees(&g, from: CGPoint(x: rect.maxX - 6, y: rect.minY + 4), t: t)
        case .working: glyphs(&g, from: CGPoint(x: rect.maxX - 4, y: rect.minY + 14), t: t)
        case .hungry: rumble(&g, rect: rect, t: t)
        default: break
        }
    }

    // MARK: 小螃蟹：像素风，一格一格画

    private static func drawCrab(_ g: inout Pen, _ f: PetFrame) {
        let p = f.pose, t = f.t, a = f.actT
        let c: CGFloat = 5.2, ground: CGFloat = 100, W: CGFloat = PetPainter.crabW
        var bob: CGFloat = 0, dx: CGFloat = 0
        switch p {
        case .working: bob = -CGFloat(Int(t * 6) % 2)
        case .waiting: bob = -8 * CGFloat(max(0, sin(t * 5.5)))
        case .celebrate, .wave: bob = -12 * CGFloat(abs(sin(a * 7))) * CGFloat(max(0, 1 - a / 2.6))
        case .poked: bob = a < 0.3 ? 3 : 0
        case .dragged: bob = -4
        case .pout: dx = a < 0.45 ? 2 * CGFloat(sin(a * 45)) : 0
        case .sick: dx = t.truncatingRemainder(dividingBy: 5) < 0.5 ? 0.8 * CGFloat(sin(t * 40)) : 0
        case .sleeping: bob = sin(t * 2 * .pi / 4.5) > 0 ? 1 : 2
        case .stretch: bob = -CGFloat(sin(min(1, a / 2) * .pi)) * 5
        default: bob = sin(t * 2 * .pi / 3.2) > 0.55 ? -1 : 0      // 发呆时一呼一吸，像素式地起伏一格
        }
        let x0 = 60 - W / 2 * c + dx, y0 = ground - 10 * c + bob
        let body = CGRect(x: x0, y: y0, width: W * c, height: 8 * c)
        let sick = p == .sick || p == .medicine
        let orange = PenShade.color(sick ? PetInk.crabSick : PetInk.crab)
        let shade = PenShade.color(PetInk.crabShade)
        let eye = PenShade.color(PetInk.crabEye)
        func cell(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ s: PenShade) { g.fill(Path(CGRect(x: x, y: y, width: w, height: h)), with: s) }

        // 影子
        let lift = min(0.45, -bob / 30)
        let sw = 64 * (1 - lift) * (p == .dragged ? 0.6 : 1)
        g.fill(Path(ellipseIn: CGRect(x: 60 - sw / 2, y: ground + 1, width: sw, height: 6)), with: .color(.black.opacity(p == .dragged ? 0.06 : 0.12)))

        // 四条腿
        for (i, col) in [1.0, 3.0, W - 4, W - 2].enumerated() {
            var len = 2 * c
            if p == .dragged { len = (i % 2 == Int(t * 4) % 2) ? 3 * c : 2.4 * c }
            cell(x0 + CGFloat(col) * c, body.maxY, c, len, shade)
        }

        // 两只钳子：默认在身体两边；干活时轮流敲键盘，举手、挥手、等你时举起来
        let up = raised(p, crab: true)
        var ly = y0 + 4 * c, ry = y0 + 4 * c
        if p == .working { let k = Int(t * 8) % 2; ly += CGFloat(k) * 0.6 * c; ry += CGFloat(1 - k) * 0.6 * c }
        if up.l { ly = y0 + 0.5 * c - (p == .celebrate ? CGFloat(Int(a * 6) % 2) * c : 0) }
        if up.r {
            ry = y0 + 0.5 * c
            if p == .wave || p == .waiting { ry -= CGFloat(Int((p == .wave ? a : t) * 5) % 2) * c }
            if p == .celebrate { ry -= CGFloat(1 - Int(a * 6) % 2) * c }
        }
        // 趴着时放下的手搭在窗口边上（paws 画），这里不画
        if !f.perch || up.l { cell(x0 - 2 * c, ly, 2 * c, 2 * c, orange); cell(x0 - 2 * c, ly + 1.4 * c, 2 * c, 0.6 * c, shade) }
        if !f.perch || up.r { cell(x0 + W * c, ry, 2 * c, 2 * c, orange); cell(x0 + W * c, ry + 1.4 * c, 2 * c, 0.6 * c, shade) }

        // 身体：顶上两个角缺一格，底下一排深一点
        cell(x0 + c, y0, (W - 2) * c, c, orange)
        cell(x0, y0 + c, W * c, 7 * c, orange)
        cell(x0, y0 + 7 * c, W * c, c, sick ? orange : shade)

        // 眼睛
        var look = f.look
        if p == .working { look = CGVector(dx: look.dx * 0.5, dy: 0.9) }
        if p == .waiting { look = CGVector(dx: 0, dy: -0.8) }
        let lx = (look.dx * 0.45 * c).rounded(), ly2 = (look.dy * 0.35 * c).rounded()
        let pix = StrokeStyle(lineWidth: 0.95 * c, lineCap: .square, lineJoin: .miter)
        for (i, col) in [3.0, W - 4].enumerated() {
            let ex = x0 + CGFloat(col) * c + lx, ey = y0 + 2 * c + ly2
            let s: CGFloat = i == 0 ? -1 : 1
            var path = Path()
            switch p {
            case .petted, .celebrate, .wave, .eating:
                path.move(to: CGPoint(x: ex - 0.3 * c, y: ey + 1.7 * c))
                path.addLine(to: CGPoint(x: ex + 0.5 * c, y: ey + 0.8 * c))
                path.addLine(to: CGPoint(x: ex + 1.3 * c, y: ey + 1.7 * c))
                g.stroke(path, with: eye, style: pix)
            case .sleeping, .medicine, .stretch:
                cell(ex - 0.3 * c, ey + 1.3 * c, 1.6 * c, 0.6 * c, eye)
            case .pout, .poked, .dragged:
                let x1 = s < 0 ? ex - 0.1 * c : ex + 1.1 * c, x2 = s < 0 ? ex + 1.0 * c : ex
                path.move(to: CGPoint(x: x1, y: ey + 0.3 * c))
                path.addLine(to: CGPoint(x: x2, y: ey + 1.1 * c))
                path.addLine(to: CGPoint(x: x1, y: ey + 1.9 * c))
                g.stroke(path, with: eye, style: StrokeStyle(lineWidth: 0.7 * c, lineCap: .square, lineJoin: .miter))
            case .sick, .hungry:
                cell(ex, ey + 0.9 * c, c, 1.1 * c, eye)
                path.move(to: CGPoint(x: ex - 0.3 * c, y: ey + (s < 0 ? 0.55 : 0.05) * c))
                path.addLine(to: CGPoint(x: ex + 1.3 * c, y: ey + (s < 0 ? 0.05 : 0.55) * c))
                g.stroke(path, with: eye, style: StrokeStyle(lineWidth: 0.4 * c, lineCap: .square))
            default:
                if t.truncatingRemainder(dividingBy: 4.7) < 0.13 {
                    cell(ex, ey + 1.2 * c, c, 0.6 * c, eye)
                } else {
                    let tall: CGFloat = (p == .waiting || p == .oops) ? 2.4 : 2
                    cell(ex, ey - (tall - 2) * c, c, tall * c, eye)
                }
            }
        }
        if [.petted, .pout, .sick, .celebrate, .eating].contains(p) {
            cell(x0 + 1.4 * c, y0 + 4.6 * c, 1.2 * c, 0.6 * c, .color(PetInk.cheek.opacity(0.9)))
            cell(x0 + (W - 2.6) * c, y0 + 4.6 * c, 1.2 * c, 0.6 * c, .color(PetInk.cheek.opacity(0.9)))
        }
        let mouth = CGPoint(x: body.midX, y: y0 + 5.2 * c)
        switch p {
        case .eating: let o = Int(a * 8) % 2 == 0; cell(mouth.x - 0.6 * c, mouth.y - (o ? 0.5 : 0.2) * c, 1.2 * c, (o ? 1.0 : 0.4) * c, eye)
        case .waiting, .oops, .poked: cell(mouth.x - 0.4 * c, mouth.y - 0.4 * c, 0.8 * c, 0.8 * c, eye)
        default: break
        }
        if sick {
            let patch = CGRect(x: x0 + 1.6 * c, y: y0 - 0.3 * c, width: 4.2 * c, height: 1.3 * c)
            g.fill(Path(patch), with: .color(PetInk.cool)); g.stroke(Path(patch), with: .color(PetInk.line), lineWidth: 1.2)
        }

        // 附带的小东西
        switch p {
        case .waiting:
            let y = y0 - 13 - 2 * CGFloat(abs(sin(t * 5.5)))
            g.text("?", size: 21, weight: .heavy, color: PetInk.line, at: CGPoint(x: body.midX + 1, y: y + 1))
            g.text("?", size: 21, weight: .heavy, color: PetInk.amber, at: CGPoint(x: body.midX, y: y))
        case .petted:
            heart(&g, center: CGPoint(x: body.midX, y: y0 - 8), size: 12, color: PetInk.cheek, outline: true)
            hearts(&g, rect: body, a: a)
        case .celebrate: confetti(&g, rect: body, a: a)
        case .eating: token(&g, to: mouth, from: CGPoint(x: body.maxX + 18, y: y0 - 6), a: a)
        case .medicine: pill(&g, to: mouth, a: a)
        case .oops: sweat(&g, at: CGPoint(x: body.maxX - 1.2 * c, y: y0 + 1.5 * c + CGFloat(min(a, 1.5)) * 4))
        case .sick: sweat(&g, at: CGPoint(x: body.maxX - 1.2 * c, y: y0 + 1.8 * c))
        case .sleeping: zees(&g, from: CGPoint(x: body.maxX - c, y: y0), t: t)
        case .working: glyphs(&g, from: CGPoint(x: body.maxX + c, y: y0 + c), t: t)
        case .hungry: rumble(&g, rect: body, t: t)
        default: break
        }
    }

    // MARK: 五官

    private static func drawEyes(_ g: inout Pen, p: PetPose, fx: CGFloat, fy: CGFloat, t: Double, look: CGVector) {
        let ink = PenShade.color(PetInk.line)
        let round = StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
        for side in [-1.0, 1.0] {
            let ex = fx + CGFloat(side) * 14
            var path = Path()
            switch p {
            case .petted, .celebrate, .wave, .eating:
                path.move(to: CGPoint(x: ex - 4, y: fy + 1.5))
                path.addQuadCurve(to: CGPoint(x: ex + 4, y: fy + 1.5), control: CGPoint(x: ex, y: fy - 4.5))
                g.stroke(path, with: ink, style: round)
            case .sleeping, .medicine, .stretch:
                path.move(to: CGPoint(x: ex - 4, y: fy))
                path.addQuadCurve(to: CGPoint(x: ex + 4, y: fy), control: CGPoint(x: ex, y: fy + 3.6))
                g.stroke(path, with: ink, style: round)
            case .pout, .poked, .dragged:
                let s = CGFloat(side)
                path.move(to: CGPoint(x: ex - 3.2 * s, y: fy - 3.4))
                path.addLine(to: CGPoint(x: ex + 2.6 * s, y: fy))
                path.addLine(to: CGPoint(x: ex - 3.2 * s, y: fy + 3.4))
                g.stroke(path, with: ink, style: round)
            case .sick, .hungry:
                g.fill(Path(ellipseIn: CGRect(x: ex - 3.2, y: fy - 1, width: 6.4, height: 5.5)), with: ink)
                // 饿了：八字眉（里高外低），看着委屈
                let tilt: CGFloat = p == .hungry ? 1.5 : 1
                path.move(to: CGPoint(x: ex - 4.4, y: fy - 1.6 + tilt * CGFloat(side) * -1))
                path.addLine(to: CGPoint(x: ex + 4.4, y: fy - 1.6 + tilt * CGFloat(side)))
                g.stroke(path, with: ink, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            default:
                // 普通的眼睛：会眨，会看鼠标
                if t.truncatingRemainder(dividingBy: 4.7) < 0.13 {
                    path.move(to: CGPoint(x: ex - 3.6, y: fy)); path.addLine(to: CGPoint(x: ex + 3.6, y: fy))
                    g.stroke(path, with: ink, style: round)
                } else {
                    let eh: CGFloat = p == .waiting || p == .oops ? 10.5 : 9
                    g.fill(Path(ellipseIn: CGRect(x: ex - 3.2, y: fy - eh / 2, width: 6.4, height: eh)), with: ink)
                    g.fill(Path(ellipseIn: CGRect(x: ex - 0.2 + look.dx * 0.8, y: fy - eh / 2 + 1.6, width: 2.6, height: 2.6)), with: .color(.white.opacity(0.9)))
                }
            }
        }
    }

    private static func drawMouth(_ g: inout Pen, p: PetPose, x: CGFloat, y: CGFloat, a: Double) {
        let ink = PenShade.color(PetInk.line)
        let st = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        var m = Path()
        switch p {
        case .petted, .celebrate, .wave:
            m.move(to: CGPoint(x: x - 5, y: y - 1)); m.addLine(to: CGPoint(x: x + 5, y: y - 1))
            m.addQuadCurve(to: CGPoint(x: x - 5, y: y - 1), control: CGPoint(x: x, y: y + 9))
            g.fill(m, with: .color(PetInk.mouth)); g.stroke(m, with: ink, lineWidth: 1.8)
        case .eating:
            let oh = 2 + 4.5 * CGFloat(abs(sin(a * 12)))
            m = Path(ellipseIn: CGRect(x: x - 3.6, y: y - oh / 2, width: 7.2, height: oh))
            g.fill(m, with: .color(PetInk.mouth)); g.stroke(m, with: ink, lineWidth: 1.6)
        case .sleeping:
            g.stroke(Path(ellipseIn: CGRect(x: x - 1.8, y: y - 1, width: 3.6, height: 3.6)), with: ink, lineWidth: 1.6)
        case .waiting, .poked, .oops:
            m = Path(ellipseIn: CGRect(x: x - 2.4, y: y - 1.5, width: 4.8, height: 5))
            g.fill(m, with: .color(PetInk.mouth)); g.stroke(m, with: ink, lineWidth: 1.5)
        case .sick, .medicine, .dragged:
            m.move(to: CGPoint(x: x - 5.5, y: y + 1))
            m.addQuadCurve(to: CGPoint(x: x, y: y + 1), control: CGPoint(x: x - 2.75, y: y - 2.2))
            m.addQuadCurve(to: CGPoint(x: x + 5.5, y: y + 1), control: CGPoint(x: x + 2.75, y: y + 4.2))
            g.stroke(m, with: ink, style: st)
        case .hungry:
            m.move(to: CGPoint(x: x - 3.5, y: y + 2)); m.addQuadCurve(to: CGPoint(x: x + 3.5, y: y + 2), control: CGPoint(x: x, y: y - 1.5))
            g.stroke(m, with: ink, style: st)
        case .pout, .working:
            m.move(to: CGPoint(x: x - 2.5, y: y + 0.8)); m.addLine(to: CGPoint(x: x + 2.5, y: y + 0.8))
            g.stroke(m, with: ink, style: st)
        default:
            m.move(to: CGPoint(x: x - 3.5, y: y)); m.addQuadCurve(to: CGPoint(x: x + 3.5, y: y), control: CGPoint(x: x, y: y + 3.4))
            g.stroke(m, with: ink, style: st)
        }
    }

    // MARK: 头顶的光标呆毛：团子的招牌，跟着状态变

    private static func drawTuft(_ g: inout Pen, p: PetPose, base: CGPoint, t: Double, a: Double) {
        switch p {
        case .waiting:
            let y = base.y - 13 - 2 * CGFloat(abs(sin(t * 5.5)))
            g.text("?", size: 21, weight: .heavy, color: PetInk.line, at: CGPoint(x: base.x + 1, y: y + 1))
            g.text("?", size: 21, weight: .heavy, color: PetInk.amber, at: CGPoint(x: base.x, y: y))
            return
        case .petted, .celebrate, .wave, .eating:
            heart(&g, center: CGPoint(x: base.x, y: base.y - 8), size: 13, color: PetInk.amber, outline: true)
            return
        default: break
        }
        var angle: Double = 0, len: CGFloat = 15, alpha: Double = 1
        switch p {
        case .sleeping: angle = 1.2; alpha = 0.75
        case .sick, .medicine: angle = 1.05; alpha = 0.6
        case .hungry: angle = 0.4
        case .dragged: angle = 0.45 * sin(t * 6)
        case .poked: angle = 0.55 * sin(a * 28) * max(0, 1 - a / 0.8)
        case .stretch: len = 19
        case .working: alpha = t.truncatingRemainder(dividingBy: 0.3) < 0.15 ? 1 : 0.35
        case .pout: angle = 0.12 * sin(a * 30)
        default: alpha = t.truncatingRemainder(dividingBy: 1.1) < 0.6 ? 1 : 0.3   // 像终端光标一样闪
        }
        var c = g
        c.translateBy(x: base.x, y: base.y)
        c.rotate(by: .radians(angle))
        let r = CGRect(x: -2.8, y: -len, width: 5.6, height: len)
        c.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(PetInk.amber.opacity(alpha)))
        c.stroke(Path(roundedRect: r, cornerRadius: 2), with: .color(PetInk.line.opacity(0.55 * alpha)), lineWidth: 1)
        if p == .sick || p == .medicine {
            // 额头上的退热贴
            let patch = CGRect(x: -11, y: 6, width: 22, height: 8)
            c.rotate(by: .radians(-angle))
            c.fill(Path(roundedRect: patch, cornerRadius: 2.5), with: .color(PetInk.cool))
            c.stroke(Path(roundedRect: patch, cornerRadius: 2.5), with: .color(PetInk.line), lineWidth: 1.3)
        }
    }

    // MARK: 小道具

    private static func heart(_ g: inout Pen, center c: CGPoint, size s: CGFloat, color: Color, outline: Bool) {
        var h = Path()
        h.move(to: CGPoint(x: c.x, y: c.y + s * 0.42))
        h.addCurve(to: CGPoint(x: c.x - s * 0.5, y: c.y - s * 0.12), control1: CGPoint(x: c.x - s * 0.18, y: c.y + s * 0.22), control2: CGPoint(x: c.x - s * 0.5, y: c.y + s * 0.12))
        h.addArc(center: CGPoint(x: c.x - s * 0.25, y: c.y - s * 0.12), radius: s * 0.25, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        h.addArc(center: CGPoint(x: c.x + s * 0.25, y: c.y - s * 0.12), radius: s * 0.25, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        h.addCurve(to: CGPoint(x: c.x, y: c.y + s * 0.42), control1: CGPoint(x: c.x + s * 0.5, y: c.y + s * 0.12), control2: CGPoint(x: c.x + s * 0.18, y: c.y + s * 0.22))
        g.fill(h, with: .color(color))
        if outline { g.stroke(h, with: .color(PetInk.line), lineWidth: 1.3) }
    }

    private static func hearts(_ g: inout Pen, rect: CGRect, a: Double) {
        for i in 0..<3 {
            let ph = (a * 0.7 + Double(i) * 0.33).truncatingRemainder(dividingBy: 1)
            let x = rect.midX + [-26, 2, 26][i] + 3 * CGFloat(sin(ph * 7))
            let y = rect.minY + 2 - 34 * CGFloat(ph)
            var c = g; c.opacity = 1 - ph
            heart(&c, center: CGPoint(x: x, y: y), size: 8 + 3 * CGFloat(1 - ph), color: PetInk.cheek, outline: false)
        }
    }

    private static func confetti(_ g: inout Pen, rect: CGRect, a: Double) {
        let colors = [PetInk.amber, PetInk.teal, PetInk.cheek]
        let k = CGFloat(min(1, a / 1.1))
        for i in 0..<12 {
            let ang = Double(i) / 12 * 2 * .pi + 0.3
            let r = 12 + 44 * k
            let x = rect.midX + CGFloat(cos(ang)) * r
            let y = rect.minY + 8 + CGFloat(sin(ang)) * r * 0.55 + 20 * k * k
            var c = g
            c.opacity = max(0, 1 - a / 2)
            c.translateBy(x: x, y: y); c.rotate(by: .radians(a * 6 + Double(i)))
            c.fill(Path(CGRect(x: -2.5, y: -1.2, width: 5, height: 2.4)), with: .color(colors[i % 3]))
        }
    }

    private static func token(_ g: inout Pen, to: CGPoint, from: CGPoint, a: Double) {
        guard a < 1.1 else { return }
        let k = CGFloat(min(1, a / 0.9)), e = k * k * (3 - 2 * k)
        let c = CGPoint(x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e - 12 * CGFloat(sin(Double(e) * .pi)))
        let r: CGFloat = 6 * (1 - 0.4 * e)
        let disc = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        g.fill(disc, with: .color(PetInk.amber)); g.stroke(disc, with: .color(PetInk.line), lineWidth: 1.2)
        g.text("T", size: 7 * (1 - 0.4 * e), weight: .heavy, color: PetInk.line, at: c)
    }

    private static func pill(_ g: inout Pen, to: CGPoint, a: Double) {
        guard a < 1.2 else { return }
        let k = CGFloat(min(1, a / 1)), from = CGPoint(x: to.x - 30, y: to.y - 18)
        let c = CGPoint(x: from.x + (to.x - from.x) * k, y: from.y + (to.y - from.y) * k)
        var p = g; p.translateBy(x: c.x, y: c.y); p.rotate(by: .degrees(-25))
        p.fill(Path(roundedRect: CGRect(x: -6, y: -2.6, width: 6, height: 5.2), cornerRadius: 2.6), with: .color(PetInk.cheek))
        p.fill(Path(roundedRect: CGRect(x: 0, y: -2.6, width: 6, height: 5.2), cornerRadius: 2.6), with: .color(.white))
        p.stroke(Path(roundedRect: CGRect(x: -6, y: -2.6, width: 12, height: 5.2), cornerRadius: 2.6), with: .color(PetInk.line), lineWidth: 1.1)
    }

    private static func sweat(_ g: inout Pen, at p: CGPoint) {
        var d = Path()
        d.move(to: CGPoint(x: p.x, y: p.y - 6))
        d.addQuadCurve(to: CGPoint(x: p.x, y: p.y + 4), control: CGPoint(x: p.x + 6.5, y: p.y + 2))
        d.addQuadCurve(to: CGPoint(x: p.x, y: p.y - 6), control: CGPoint(x: p.x - 6.5, y: p.y + 2))
        g.fill(d, with: .color(PetInk.cool)); g.stroke(d, with: .color(PetInk.line), lineWidth: 1.2)
    }

    private static func zees(_ g: inout Pen, from: CGPoint, t: Double) {
        for i in 0..<3 {
            let ph = (t * 0.28 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
            var c = g; c.opacity = sin(ph * .pi)
            c.text("z", size: 8 + 6 * CGFloat(ph), weight: .bold, color: PetInk.teal,
                   at: CGPoint(x: from.x + 4 + 12 * CGFloat(ph), y: from.y - 26 * CGFloat(ph)))
        }
    }

    private static func glyphs(_ g: inout Pen, from: CGPoint, t: Double) {
        let set = ["<", "/", ">", "{", "}", "_", ";"]
        for i in 0..<3 {
            let v = t * 0.7 + Double(i) / 3
            let ph = v.truncatingRemainder(dividingBy: 1)
            var c = g; c.opacity = 0.85 * sin(ph * .pi)
            c.text(set[(Int(v) * 3 + i) % set.count], size: 10, weight: .bold, mono: true, color: PetInk.teal,
                   at: CGPoint(x: from.x + 6 + 5 * CGFloat(sin(v * 3)), y: from.y - 30 * CGFloat(ph)))
        }
    }

    private static func rumble(_ g: inout Pen, rect: CGRect, t: Double) {
        guard t.truncatingRemainder(dividingBy: 6) < 1.2 else { return }
        for i in 0..<2 {
            var w = Path()
            let x = rect.maxX + 3 + CGFloat(i) * 4, y = rect.midY + 6
            w.move(to: CGPoint(x: x, y: y - 5)); w.addQuadCurve(to: CGPoint(x: x, y: y + 5), control: CGPoint(x: x + 4, y: y))
            g.stroke(w, with: .color(PetInk.line.opacity(0.6)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        }
    }

    /// 出门了：门口挂一张行李牌
    private static func drawTag(_ g: inout Pen, _ f: PetFrame) {
        var c = g
        c.translateBy(x: 60, y: 44)
        c.rotate(by: .radians(0.05 * sin(f.t * 1.4)))
        var string = Path()
        string.move(to: CGPoint(x: -33, y: 22)); string.addQuadCurve(to: CGPoint(x: -46, y: -6), control: CGPoint(x: -50, y: 14))
        c.stroke(string, with: .color(PetInk.amber), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        let card = CGRect(x: -42, y: 4, width: 86, height: 50)
        var tag = Path()
        tag.move(to: CGPoint(x: card.minX + 10, y: card.minY))
        tag.addLine(to: CGPoint(x: card.maxX - 6, y: card.minY))
        tag.addQuadCurve(to: CGPoint(x: card.maxX, y: card.minY + 6), control: CGPoint(x: card.maxX, y: card.minY))
        tag.addLine(to: CGPoint(x: card.maxX, y: card.maxY - 6))
        tag.addQuadCurve(to: CGPoint(x: card.maxX - 6, y: card.maxY), control: CGPoint(x: card.maxX, y: card.maxY))
        tag.addLine(to: CGPoint(x: card.minX + 10, y: card.maxY))
        tag.addLine(to: CGPoint(x: card.minX, y: card.maxY - 12))
        tag.addLine(to: CGPoint(x: card.minX, y: card.minY + 12))
        tag.closeSubpath()
        c.fill(tag, with: .color(PetInk.body)); c.stroke(tag, with: .color(PetInk.line), lineWidth: 2)
        c.stroke(Path(ellipseIn: CGRect(x: card.minX + 5, y: card.midY - 3.2, width: 6.4, height: 6.4)), with: .color(PetInk.line), lineWidth: 1.6)
        c.text("出去玩啦", size: 11, weight: .bold, color: PetInk.line, at: CGPoint(x: 6, y: card.minY + 13))
        c.text(f.place, size: 9.5, weight: .medium, color: PetInk.line, at: CGPoint(x: 6, y: card.minY + 27))
        c.text("约 \(f.back) 回来", size: 8.5, weight: .regular, color: PetInk.teal, at: CGPoint(x: 6, y: card.minY + 40))
    }
}

// MARK: 窗口

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PetWindow {
    static let shared = PetWindow()
    private(set) var panel: PetPanel?
    private var occ: NSObjectProtocol?
    private var screens: NSObjectProtocol?
    private var hostObs: [NSObjectProtocol] = []
    /// 客户端主窗口：宠物没事就趴在它顶上
    private(set) weak var host: NSWindow?

    static let base = CGSize(width: 250, height: 236)
    var scale: CGFloat { CGFloat(PetStore.shared.data.size) }
    var size: CGSize { CGSize(width: Self.base.width * scale, height: Self.base.height * scale) }
    /// 现在是不是趴在窗口上（画的时候用）
    var perched: Bool { panel?.parent != nil }

    func show() {
        if panel == nil { build() }
        relayout()
        if !perched { panel?.orderFrontRegardless() }
    }

    func hide() {
        if let occ { NotificationCenter.default.removeObserver(occ) }
        if let screens { NotificationCenter.default.removeObserver(screens) }
        occ = nil; screens = nil
        unwatchHost()
        if let p = panel { p.parent?.removeChildWindow(p) }
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    /// 主窗口出现时登记过来（RootView 里的 PetHostReader）
    func setHost(_ w: NSWindow?) {
        guard let w, w !== host else { return }
        host = w
        if panel != nil { watchHost(); relayout() }
    }

    private func watchHost() {
        unwatchHost()
        guard let h = host else { return }
        let nc = NotificationCenter.default
        let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                                          NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification, NSWindow.willCloseNotification]
        hostObs = names.map { n in
            nc.addObserver(forName: n, object: h, queue: .main) { [weak self] note in
                if note.name == NSWindow.willCloseNotification { self?.host = nil }
                DispatchQueue.main.async { self?.relayout() }
            }
        }
    }

    private func unwatchHost() {
        hostObs.forEach { NotificationCenter.default.removeObserver($0) }
        hostObs = []
    }

    private func build() {
        let p = PetPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.contentView = NSHostingView(rootView: PetRoot())
        panel = p
        occ = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: p, queue: .main) { [weak p] _ in
            guard let p else { return }
            let v = p.occlusionState.contains(.visible)
            if PetStore.shared.visible != v { PetStore.shared.visible = v }
        }
        screens = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.relayout()
        }
        watchHost()
    }

    /// 测试用：把浮窗当前的样子存成图片
    func selfShot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["DUIHUATAI_PET_SELFSHOT"], let v = panel?.contentView,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        if let p = panel, let h = host {
            let info = "panel \(NSStringFromRect(p.frame)) host \(NSStringFromRect(h.frame)) perched \(perched)\n"
            try? info.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
        }
    }

    /// 趴在窗口上时浮窗的位置；窗口顶上没地方（贴着菜单栏、全屏、最小化）就返回 nil
    private func perchFrame() -> CGRect? {
        guard let h = host, h.isVisible, !h.isMiniaturized, !h.styleMask.contains(.fullScreen),
              let vf = (h.screen ?? NSScreen.main)?.visibleFrame else { return nil }
        let edgeFromBottom = (PetPainter.unit.height - PetPainter.perchEdge) * scale
        // 露在窗口上面的部分（头 + 冒出来的问号、爱心）要放得下
        guard h.frame.maxY + 46 * scale <= vf.maxY + 1 else { return nil }
        let fromRight = min(max(CGFloat(PetStore.shared.data.perchFromRight ?? 150), 70 * scale), h.frame.width - 70 * scale)
        return CGRect(x: h.frame.maxX - fromRight - size.width / 2, y: h.frame.maxY - edgeFromBottom, width: size.width, height: size.height)
    }

    var canPerch: Bool { perchFrame() != nil }

    func relayout() {
        guard let p = panel else { return }
        let d = PetStore.shared.data
        if d.perch, d.perchedNow, let f = perchFrame(), let h = host {
            if p.parent !== h {
                p.parent?.removeChildWindow(p)
                p.collectionBehavior = [.ignoresCycle]
                p.level = .normal
                h.addChildWindow(p, ordered: .above)
            }
            p.setFrame(f, display: true)
            return
        }
        if let par = p.parent { par.removeChildWindow(p) }
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.level = .floating
        var origin: CGPoint
        if let x = d.x, let y = d.y {
            origin = CGPoint(x: x, y: y)
        } else {
            let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            origin = CGPoint(x: vf.maxX - size.width + 30 * scale, y: vf.minY + 4)
        }
        p.setFrame(CGRect(origin: origin, size: size), display: true)
        p.orderFrontRegardless()
        settle(save: false)
    }

    /// 开始拖：从窗口上拿下来，浮到最上层
    func beginDrag() {
        guard let p = panel, let par = p.parent else { return }
        par.removeChildWindow(p)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.level = .floating
    }

    /// 拖完：放在窗口顶边附近就趴上去，否则留在桌面上
    func endDrag() {
        guard let p = panel else { return }
        let st = PetStore.shared
        if st.data.perch, let h = host, h.isVisible, !h.isMiniaturized {
            let edgeY = p.frame.minY + (PetPainter.unit.height - PetPainter.perchEdge) * scale
            let x = p.frame.midX
            if abs(edgeY - h.frame.maxY) < 50 * scale, x > h.frame.minX + 40, x < h.frame.maxX - 40 {
                st.perched(fromRight: Double(h.frame.maxX - x))
                relayout()
                if perched { return }
            }
        }
        st.detached()
        settle()
    }

    /// 拖完或换屏后：保证宠物本身留在某个屏幕里
    func settle(save: Bool = true) {
        guard let p = panel, !perched else { return }
        var f = p.frame
        let center = CGPoint(x: f.midX, y: f.minY + 50 * scale)
        let scr = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let vf = scr?.visibleFrame else { return }
        let petHalf = 50 * scale
        f.origin.x = min(max(f.origin.x, vf.minX - f.width / 2 + petHalf), vf.maxX - f.width / 2 - petHalf)
        f.origin.y = min(max(f.origin.y, vf.minY - 6 * scale), vf.maxY - f.height)
        if f.origin != p.frame.origin { p.setFrameOrigin(f.origin) }
        if save { PetStore.shared.savePosition(f.origin) }
    }
}

/// 放在主窗口里：把主窗口告诉宠物
struct PetHostReader: NSViewRepresentable {
    final class V: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let w = window { DispatchQueue.main.async { PetWindow.shared.setHost(w) } }
        }
    }
    func makeNSView(context: Context) -> V { V() }
    func updateNSView(_ v: V, context: Context) {}
}

// MARK: 窗口内容：气泡 + 团子

struct PetRoot: View {
    @ObservedObject var store = PetStore.shared
    @State private var dragFrom: (mouse: CGPoint, origin: CGPoint)?
    @State private var stroke = StrokeTracker()

    private var s: CGFloat { CGFloat(store.data.size) }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if let b = store.bubble {
                PetBubble(text: b, s: s)
                    .onTapGesture { store.dismissBubble() }
                    .padding(.bottom, -bubblePull)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
            }
            pet
        }
        .frame(width: PetWindow.base.width * s, height: PetWindow.base.height * s, alignment: .bottom)
        .animation(.easeOut(duration: 0.18), value: store.bubble)
    }

    private var pet: some View {
        PetCanvas()
            .frame(width: PetPainter.unit.width * s, height: PetPainter.unit.height * s)
            .contentShape(PetHitShape(perch: PetWindow.shared.perched && store.pose != .away))
            .gesture(
                SpatialTapGesture(count: 2).onEnded { _ in store.showCard.toggle() }
                    .exclusively(before: SpatialTapGesture().onEnded { v in tap(v.location) })
            )
            .simultaneousGesture(drag)
            .onContinuousHover { phase in
                guard case .active(let p) = phase, p.y < headLine, store.pose != .away else { return }
                if stroke.feed(x: p.x) { store.pat() }
            }
            .onDrop(of: [.fileURL], isTargeted: Binding(get: { store.dropTargeted }, set: { store.dropTargeted = $0 })) { providers in
                receive(providers); return true
            }
            .contextMenu { PetMenu() }
            .background(Color.clear.popover(isPresented: $store.showRemind, arrowEdge: .top) { Themed { PetRemindInput() } })
            .popover(isPresented: $store.showCard, arrowEdge: .top) {
                Themed { PetCard() }
            }
    }

    /// 气泡往下拉到头顶附近：画布上方是给问号、爱心留的空，不拉的话气泡会飘得很远
    private var bubblePull: CGFloat {
        let perch = PetWindow.shared.perched && store.pose != .away
        let top = PetPainter.headTop(store.character, perch: perch)
        let props: Set<PetPose> = [.waiting, .petted, .celebrate, .eating, .sleeping, .working]
        let gap: CGFloat = props.contains(store.pose) || store.focusing ? 30 : 6
        return max(0, top - gap) * s
    }

    /// 这条线以上算头：趴着时身子沉下去了，线也跟着往下
    private var headLine: CGFloat { (PetWindow.shared.perched ? 68 : 54) * s }

    /// 拖进来的文件：取出路径交给新对话
    private func receive(_ providers: [NSItemProvider]) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { u, _ in
                if let u, u.isFileURL { DispatchQueue.main.async { urls.append(u) } }
                group.leave()
            }
        }
        group.notify(queue: .main) { store.handOff(urls) }
    }

    private func tap(_ p: CGPoint) {
        if store.pose == .away { store.showCard = true; return }
        if store.anyWaiting && store.data.reactToClaude && store.openWaiting() { return }
        if store.openLastDone() { return }
        if p.y < headLine { store.pat() } else { store.poke() }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { _ in
                guard let panel = PetWindow.shared.panel else { return }
                let m = NSEvent.mouseLocation
                if dragFrom == nil {
                    PetWindow.shared.beginDrag()
                    dragFrom = (m, panel.frame.origin)
                    if store.pose != .away { store.dragging = true }
                }
                guard let d = dragFrom else { return }
                panel.setFrameOrigin(CGPoint(x: d.origin.x + m.x - d.mouse.x, y: d.origin.y + m.y - d.mouse.y))
            }
            .onEnded { _ in
                dragFrom = nil
                store.dragging = false
                PetWindow.shared.endDrag()
            }
    }
}

/// 趴着时，窗口边线以下的部分不接点击（那里是窗口的标题栏）
struct PetHitShape: Shape {
    let perch: Bool
    func path(in r: CGRect) -> Path {
        Path(perch ? CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height * (PetPainter.perchEdge + 3) / PetPainter.unit.height) : r)
    }
}

/// 在头上来回划几下 = 摸头
struct StrokeTracker {
    private var lastX: CGFloat?
    private var dir: CGFloat = 0
    private var turns: [Date] = []
    private var cooldown = Date.distantPast

    mutating func feed(x: CGFloat) -> Bool {
        defer { lastX = x }
        guard let lx = lastX, abs(x - lx) > 1.5 else { return false }
        let d: CGFloat = x > lx ? 1 : -1
        let now = Date()
        if d != dir {
            dir = d
            turns = turns.filter { now.timeIntervalSince($0) < 1.6 } + [now]
        }
        if turns.count >= 4, now > cooldown {
            turns.removeAll()
            cooldown = now.addingTimeInterval(1.2)
            return true
        }
        return false
    }
}

/// 团子本身：一个自己按节奏重画的 NSView。看不见时（被挡住、在别的桌面、锁屏）每秒只醒一次
final class PetDrawView: NSView {
    var fixed: PetFrame?            // 截图测试用：画固定的一帧
    var background: NSColor?
    private var timer: Timer?
    private var interval: Double = 0

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }      // 点击、拖动交给上面的 SwiftUI

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil; interval = 0
        if window != nil, fixed == nil { reschedule() }
    }

    private func reschedule() {
        let st = PetStore.shared
        let want = st.visible ? st.frameInterval : 1
        guard want != interval else { return }
        interval = want
        timer?.invalidate()
        let t = Timer(timeInterval: want, repeats: true) { [weak self] _ in self?.step() }
        t.tolerance = want * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func step() {
        guard window != nil else { timer?.invalidate(); return }
        reschedule()
        if PetStore.shared.visible { needsDisplay = true }
    }

    override func draw(_ r: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        if let background { cg.setFillColor(background.cgColor); cg.fill(bounds) }
        var pen = Pen(cg: cg)
        PetPainter.draw(&pen, size: bounds.size, f: fixed ?? PetCanvas.frame(Date()))
    }
}

struct PetCanvas: NSViewRepresentable {
    @ObservedObject var store = PetStore.shared
    func makeNSView(context: Context) -> PetDrawView { PetDrawView() }
    func updateNSView(_ v: PetDrawView, context: Context) { v.needsDisplay = true }

    static var drawn = 0
    static func frame(_ now: Date) -> PetFrame {
        drawn += 1
        let store = PetStore.shared
        var f = PetFrame(pose: store.pose, t: now.timeIntervalSinceReferenceDate, actT: now.timeIntervalSince(store.actStart))
        f.character = store.character
        if store.focusing { f.focusLeft = store.focusLeft }
        f.perch = PetWindow.shared.perched && store.pose != .dragged
        if let trip = store.data.trip { f.place = trip.place; f.back = PetStore.hm(trip.back) }
        if let p = PetWindow.shared.panel {
            let m = NSEvent.mouseLocation
            let c = CGPoint(x: p.frame.midX, y: p.frame.minY + 56 * CGFloat(store.data.size))
            f.look = CGVector(dx: max(-1, min(1, (m.x - c.x) / 260)), dy: max(-1, min(1, -(m.y - c.y) / 260)))
        }
        return f
    }
}

struct PetBubble: View {
    let text: String
    let s: CGFloat
    var body: some View {
        Text(text)
            .font(.system(size: 12.5 * s, weight: .medium, design: .rounded))
            .foregroundStyle(PetInk.line)
            .lineSpacing(2.5 * s)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 11 * s)
            .padding(.top, 7 * s)
            .padding(.bottom, 7 * s + 7)
            .background(BubbleShape().fill(PetInk.body))
            .overlay(BubbleShape().stroke(PetInk.line, lineWidth: 1.6))
            .frame(maxWidth: 226 * s)
            .contentShape(BubbleShape())
    }
}

struct BubbleShape: Shape {
    func path(in r: CGRect) -> Path {
        let rad: CGFloat = 11, bb = r.maxY - 7
        var p = Path()
        p.move(to: CGPoint(x: r.minX + rad, y: r.minY))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: bb), radius: rad)
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: bb), tangent2End: CGPoint(x: r.minX, y: bb), radius: rad)
        p.addLine(to: CGPoint(x: r.midX + 6, y: bb))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.midX - 6, y: bb))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: bb), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: rad)
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: rad)
        p.closeSubpath()
        return p
    }
}

// MARK: 右键菜单

struct PetMenu: View {
    @ObservedObject var store = PetStore.shared
    var body: some View {
        let name = store.data.name
        if store.data.trip != nil {
            Button("叫\(name)回来") { store.callBack() }
        } else {
            Button("摸摸头") { store.pat() }
            Button(store.snacksLeft > 0 ? "喂零食（今天还剩 \(store.snacksLeft) 份）" : "今天的零食吃完了") { store.feedSnack() }
                .disabled(store.snacksLeft == 0)
            if store.data.sick { Button("喂药") { store.giveMedicine() } }
            Button(store.canTravel.ok ? "出去玩一会儿" : "出去玩（\(store.canTravel.why)）") { store.goTravel() }
                .disabled(!store.canTravel.ok)
            Button(store.asleep ? "叫醒它" : "哄它睡觉") { store.toggleSleep() }
        }
        Divider()
        Button("提醒我…") { NSApp.activate(ignoringOtherApps: true); store.showRemind = true }
        if store.focusing {
            Button("结束专注（还剩 \(Int(store.focusLeft / 60) + 1) 分钟）") { store.stopFocus() }
        } else {
            Menu("专注一会儿") {
                Button("25 分钟") { store.startFocus(minutes: 25) }
                Button("50 分钟") { store.startFocus(minutes: 50) }
                Button("15 分钟") { store.startFocus(minutes: 15) }
            }
        }
        Divider()
        Button("看看状态") { store.showCard = true }
        Button("\(name)的日记") { PetDiaryWindow.show() }
        Button("安静一小时") { store.quietForAnHour() }
        Divider()
        Button("宠物设置…") { PetSettingsOpener.open() }
        Button("先收起来") { store.setEnabled(false) }
    }
}

enum PetSettingsOpener {
    /// 主窗口里的 SwiftUI 环境才有 openSettings，启动时交过来
    static var action: (() -> Void)?
    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        UserDefaults.standard.set(SettingsSection.pet.rawValue, forKey: "settingsSection")
        action?()
    }
}

// MARK: 双击出来的状态卡

struct PetCard: View {
    @ObservedObject var store = PetStore.shared

    var body: some View {
        let d = store.data
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(d.name).font(.system(size: fs(17), weight: .semibold, design: .rounded)).foregroundStyle(T.ink)
                Text("Lv\(store.level.n) \(store.level.title)").font(T.small).foregroundStyle(T.muted)
                Spacer()
                Text("在一起 \(store.daysTogether) 天").font(T.small).foregroundStyle(T.muted)
            }
            Text(store.statusLine).font(.system(size: fs(13))).foregroundStyle(T.ink)
            if let today = d.days[PetStore.today], today.tokens > 0 || today.tasks > 0 || today.focus > 0 {
                Text(todayLine(today)).font(T.small).foregroundStyle(T.muted)
            }
            if !store.activeSessions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.activeSessions, id: \.id) { s in
                        Button { store.open(s) } label: {
                            HStack(spacing: 6) {
                                Circle().fill(s.needsAttention ? PetInk.amber : PetInk.teal).frame(width: 6, height: 6)
                                Text(store.title(of: s)).lineLimit(1).truncationMode(.tail).foregroundStyle(T.ink)
                                Spacer()
                                Text(s.needsAttention ? "等你确认" : "在忙").foregroundStyle(T.muted)
                            }
                            .font(T.small)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !d.reminders.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(d.reminders.prefix(5)) { r in
                        HStack(spacing: 6) {
                            Text(r.due.map { PetCard.when($0) } ?? "便签").foregroundStyle(T.muted).frame(width: 64, alignment: .leading)
                            Text(r.text).lineLimit(1).foregroundStyle(T.ink)
                            Spacer()
                            Button { store.removeReminder(r) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                                .buttonStyle(.plain).foregroundStyle(T.muted).help(r.due == nil ? "删掉这张便签" : "取消这个提醒")
                        }
                        .font(T.small)
                    }
                }
            }
            if d.trip == nil {
                VStack(spacing: 7) {
                    bar("饱腹", d.fullness, PetInk.amber)
                    bar("心情", d.mood, PetInk.cheek)
                    bar("精力", d.energy, PetInk.teal)
                    bar("亲密", affinityProgress, T.accent)
                }
                HStack(spacing: 8) {
                    Button("摸摸") { store.pat() }
                    if d.sick { Button("喂药") { store.giveMedicine() } }
                    else { Button("零食 \(store.snacksLeft)") { store.feedSnack() }.disabled(store.snacksLeft == 0) }
                    Button("出去玩") { store.goTravel() }.disabled(!store.canTravel.ok).help(store.canTravel.why)
                    Spacer()
                    Button("提醒") { store.showCard = false; NSApp.activate(ignoringOtherApps: true); DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { store.showRemind = true } }
                    if store.focusing { Button("结束专注") { store.stopFocus() } }
                    else { Button("专注") { store.startFocus(minutes: 25) }.help("专注 25 分钟") }
                    Button("日记") { store.showCard = false; PetDiaryWindow.show() }
                }
                .controlSize(.small)
            } else {
                HStack {
                    Button("日记") { store.showCard = false; PetDiaryWindow.show() }
                    Spacer()
                    Button("叫它回来") { store.showCard = false; store.callBack() }.buttonStyle(PrimaryButton())
                }
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func todayLine(_ t: PetDay) -> String {
        var parts = ["今天吃了 \(PetStore.tokenText(t.tokens)) token", "做完 \(t.tasks) 件事"]
        if t.focus > 0 { parts.append("专注 \(t.focus) 分钟") }
        return parts.joined(separator: "，")
    }

    static func when(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : (Calendar.current.isDateInTomorrow(d) ? "明天 HH:mm" : "M/d HH:mm")
        return f.string(from: d)
    }

    private var affinityProgress: Double {
        let marks: [Double] = [0, 30, 100, 250, 500]
        let a = store.data.affection
        guard let i = marks.lastIndex(where: { a >= $0 }), i + 1 < marks.count else { return 100 }
        return (a - marks[i]) / (marks[i + 1] - marks[i]) * 100
    }

    private func bar(_ label: String, _ v: Double, _ c: Color) -> some View {
        HStack(spacing: 10) {
            Text(label).font(T.small).foregroundStyle(T.muted).frame(width: 30, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(T.sunk)
                    Capsule().fill(c).frame(width: max(6, geo.size.width * CGFloat(min(100, max(0, v)) / 100)))
                }
            }
            .frame(height: 7)
            Text("\(Int(v.rounded()))").font(.system(size: fs(11), design: .monospaced)).foregroundStyle(T.muted).frame(width: 26, alignment: .trailing)
        }
    }
}

// MARK: 日记本

enum PetDiaryWindow {
    private static var window: NSWindow?

    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = window { w.title = "\(PetStore.shared.data.name)的日记"; w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 660), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "\(PetStore.shared.data.name)的日记"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: Themed { PetDiaryView() })
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}

struct PetDiaryView: View {
    @ObservedObject var store = PetStore.shared
    @State private var tab = 0

    private var days: [(String, PetDay)] {
        store.data.days.filter { $0.value.tokens > 0 || $0.value.tasks > 0 || $0.value.pets > 0 || $0.value.snacks > 0 || !$0.value.trips.isEmpty }
            .sorted { $0.key > $1.key }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("日记").tag(0)
                Text("明信片 \(store.data.postcards.count)").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 220).padding(.vertical, 12)
            Divider()
            ScrollView {
                if tab == 0 { diary } else { cards }
            }
        }
        .background(T.canvas)
    }

    @ViewBuilder private var diary: some View {
        if days.isEmpty {
            Text("还没有日记。今天陪它干点活，晚上就有第一篇了。")
                .font(T.body).foregroundStyle(T.muted).padding(40)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(days, id: \.0) { key, d in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Self.title(key)).font(.system(size: fs(14), weight: .semibold)).foregroundStyle(T.ink)
                        Text(PetDiary.text(day: key, d: d, name: store.data.name))
                            .font(.system(size: fs(14))).foregroundStyle(T.ink).lineSpacing(6)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 32).padding(.vertical, 18)
                    Divider().padding(.horizontal, 32)
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private var cards: some View {
        if store.data.postcards.isEmpty {
            Text("还没出过门。右键它选「出去玩一会儿」，回来会带一张明信片。")
                .font(T.body).foregroundStyle(T.muted).padding(40)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                ForEach(store.data.postcards.reversed()) { PostcardView(card: $0) }
            }
            .padding(24)
        }
    }

    static func title(_ key: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: key) else { return key }
        if Calendar.current.isDateInToday(d) { return "今天" }
        if Calendar.current.isDateInYesterday(d) { return "昨天" }
        let o = DateFormatter(); o.locale = Locale(identifier: "zh_CN"); o.dateFormat = "M月d日 EEEE"
        return o.string(from: d)
    }
}

struct PostcardView: View {
    let card: Postcard
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(card.place).font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(PetInk.line)
                Spacer()
                // 邮票：琥珀色虚线框里一个小光标
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(PetInk.amber, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                    .frame(width: 26, height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 1).fill(PetInk.amber).frame(width: 4, height: 11))
            }
            Text(card.line).font(.system(size: 13, design: .rounded)).foregroundStyle(PetInk.line.opacity(0.88))
                .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Text("带回来：\(card.gift)").font(.system(size: 11.5, design: .rounded)).foregroundStyle(PetInk.teal)
                Spacer()
                Text(card.date.formatted(.dateTime.month().day())).font(.system(size: 11, design: .rounded)).foregroundStyle(PetInk.teal.opacity(0.8))
            }
        }
        .padding(14)
        .frame(minHeight: 150, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(PetInk.body))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(PetInk.line, lineWidth: 1.5))
    }
}

// MARK: 测试：把每个姿势画成图片（DUIHUATAI_PET_SNAPSHOT=目录）

enum PetSnapshot {
    @MainActor static func run(_ dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for pose in PetPose.allCases {
            for (i, at) in [0.35, 1.0].enumerated() {
              for ch in PetCharacter.allCases {
               for perch in [false, true] {
                let f = PetFrame(pose: pose, t: 1000.6 + at, actT: at, look: CGVector(dx: 0.6, dy: 0.2), place: "杭州西湖", back: "15:40", character: ch, perch: perch)
                let v = PetDrawView(frame: CGRect(x: 0, y: 0, width: 240, height: 224))
                v.fixed = f; v.background = NSColor(white: 0.93, alpha: 1)
                if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    guard let png = rep.representation(using: .png, properties: [:]) else { continue }
                    try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(ch.rawValue)\(perch ? "-perch" : "")-\(pose.rawValue)-\(i).png"))
                }
               }
              }
            }
        }
        let b = ImageRenderer(content: PetBubble(text: "我回来啦！去了杭州西湖，在断桥边等了半天，没等到雪，等到一只鸭子。", s: 1).padding(20).background(Color(white: 0.93)))
        b.scale = 2
        if let img = b.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("bubble.png"))
        }
    }
}


// MARK: 提醒我：一句话说时间和事

struct PetRemindInput: View {
    @ObservedObject var store = PetStore.shared
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("20分钟后 开会 / 15:30 交周报 / 明天9点 周会", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { submit() }
            HStack {
                Text("不写时间就记成便签").font(T.small).foregroundStyle(T.muted)
                Spacer()
                Button("记下") { submit() }.buttonStyle(PrimaryButton()).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func submit() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.addReminder(text)
        text = ""
        store.showRemind = false
    }
}
