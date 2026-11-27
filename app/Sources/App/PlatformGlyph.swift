import AppKit
import SwiftUI

/// 各平台的简化标志（自己用矢量画的单色小图形，不用官方图片）：菜单栏始终显示当前平台，
/// 让人一眼看出是哪个平台在消耗。都画在 16pt 见方的格子里，颜色由调用方给（模板图时用黑色）
enum PlatformGlyph {
    /// 菜单栏用的图：tint 为 nil 时是模板图（跟随菜单栏深浅）
    static func menuImage(_ id: ProviderID, tint: NSColor?) -> NSImage {
        menuImage(id, tint: tint, dayBadge: false, alertBadge: false)
    }

    static func menuImage(_ id: ProviderID, tint: NSColor?, dayBadge: Bool, alertBadge: Bool) -> NSImage {
        let pt = kMenuIconPt
        let img = NSImage(size: NSSize(width: pt, height: pt), flipped: false) { rect in
            draw(id, in: rect, color: tint ?? .black)
            GaugeIcon.drawBadges(in: rect, color: tint ?? .black, dayBadge: dayBadge, alertBadge: alertBadge)
            return true
        }
        img.isTemplate = tint == nil
        return img
    }

    static func image(_ id: ProviderID, size: CGFloat, tint: NSColor?) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(id, in: rect, color: tint ?? .black)
            return true
        }
        img.isTemplate = tint == nil
        return img
    }

    static func draw(_ id: ProviderID, in rect: NSRect, color: NSColor) {
        // 按 16pt 设计，其他尺寸等比缩放
        let s = min(rect.width, rect.height) / 16
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: rect.midX, yBy: rect.midY)
        t.scale(by: s)
        t.concat()
        color.setFill()
        color.setStroke()
        switch id {
        case .claudePlan: claude()
        case .codexPlan: codex()
        case .geminiPlan: gemini()
        case .deepseek: deepseek()
        case .siliconflow: siliconflow()
        case .kimi: kimi()
        case .openrouter: openrouter()
        case .packyapi: packyapi()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 放射状星芒：长短交替的圆头光线
    private static func claude() {
        let rays = 12
        for i in 0..<rays {
            let a = CGFloat(i) / CGFloat(rays) * 2 * .pi + .pi / 2
            let len: CGFloat = i % 2 == 0 ? 7.2 : 5.4
            let p = NSBezierPath()
            p.lineWidth = 1.9
            p.lineCapStyle = .round
            p.move(to: NSPoint(x: cos(a) * 1.4, y: sin(a) * 1.4))
            p.line(to: NSPoint(x: cos(a) * len, y: sin(a) * len))
            p.stroke()
        }
    }

    /// 三个圆角长条互相旋转 60°，组成六瓣的结
    private static func codex() {
        for k in 0..<3 {
            let p = NSBezierPath(roundedRect: NSRect(x: -6.6, y: -2.7, width: 13.2, height: 5.4), xRadius: 2.7, yRadius: 2.7)
            let r = NSAffineTransform()
            r.rotate(byDegrees: CGFloat(k) * 60 + 30)
            p.transform(using: r as AffineTransform)
            p.lineWidth = 1.35
            p.stroke()
        }
    }

    /// 四角星芒：四条向心凹弧汇成菱形星
    private static func gemini() {
        let r: CGFloat = 7.2
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 0, y: r))
        p.curve(to: NSPoint(x: r, y: 0), controlPoint1: NSPoint(x: 0.6, y: 1.8), controlPoint2: NSPoint(x: 1.8, y: 0.6))
        p.curve(to: NSPoint(x: 0, y: -r), controlPoint1: NSPoint(x: 1.8, y: -0.6), controlPoint2: NSPoint(x: 0.6, y: -1.8))
        p.curve(to: NSPoint(x: -r, y: 0), controlPoint1: NSPoint(x: -0.6, y: -1.8), controlPoint2: NSPoint(x: -1.8, y: -0.6))
        p.curve(to: NSPoint(x: 0, y: r), controlPoint1: NSPoint(x: -1.8, y: 0.6), controlPoint2: NSPoint(x: -0.6, y: 1.8))
        p.close()
        p.fill()
    }

    /// 鲸鱼：圆身子、上翘的尾巴、挖空的眼睛
    private static func deepseek() {
        let body = NSBezierPath()
        body.move(to: NSPoint(x: -7, y: 0.5))
        body.curve(to: NSPoint(x: 2.5, y: -5), controlPoint1: NSPoint(x: -7, y: -4), controlPoint2: NSPoint(x: -2.5, y: -5.6))
        body.curve(to: NSPoint(x: 5.2, y: 1.2), controlPoint1: NSPoint(x: 5.2, y: -4.6), controlPoint2: NSPoint(x: 5.6, y: -1.6))
        // 尾巴：从背后往右上甩出两片
        body.line(to: NSPoint(x: 7.6, y: 5.4))
        body.line(to: NSPoint(x: 4.6, y: 4.0))
        body.line(to: NSPoint(x: 2.6, y: 6.2))
        body.curve(to: NSPoint(x: -7, y: 0.5), controlPoint1: NSPoint(x: 1.6, y: 2.0), controlPoint2: NSPoint(x: -3.8, y: 3.8))
        body.close()
        body.fill()
        if let ctx = NSGraphicsContext.current {
            ctx.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: NSRect(x: -4.6, y: -1.2, width: 1.8, height: 1.8)).fill()
            ctx.compositingOperation = .sourceOver
        }
    }

    /// 弯月：大圆挖掉右上偏移的圆，缺口里点一颗星（不与月牙相接）
    private static func kimi() {
        NSBezierPath(ovalIn: NSRect(x: -7, y: -7, width: 14, height: 14)).fill()
        if let ctx = NSGraphicsContext.current {
            ctx.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: NSRect(x: -3.2, y: -3.6, width: 12.4, height: 12.4)).fill()
            ctx.compositingOperation = .sourceOver
        }
        NSBezierPath(ovalIn: NSRect(x: 2.4, y: -0.1, width: 2.2, height: 2.2)).fill()
    }

    /// 包裹：等轴测的方盒子（六边形外框 + 中间 Y 形棱线），上面一面涂实
    private static func packyapi() {
        let r: CGFloat = 7, h = r * 0.866
        let top = NSPoint(x: 0, y: r), ur = NSPoint(x: h, y: r / 2), lr = NSPoint(x: h, y: -r / 2)
        let bottom = NSPoint(x: 0, y: -r), ll = NSPoint(x: -h, y: -r / 2), ul = NSPoint(x: -h, y: r / 2)
        let center = NSPoint.zero
        let lid = NSBezierPath()
        lid.move(to: top); lid.line(to: ur); lid.line(to: center); lid.line(to: ul); lid.close()
        lid.fill()
        let box = NSBezierPath()
        box.lineWidth = 1.5
        box.lineJoinStyle = .round
        box.move(to: top)
        for pt in [ur, lr, bottom, ll, ul] { box.line(to: pt) }
        box.close()
        box.move(to: center); box.line(to: bottom)
        box.stroke()
    }

    /// 路由分叉：左边一个实心节点，一条线出来分成三路，各自停在一个空心小圆上
    private static func openrouter() {
        NSBezierPath(ovalIn: NSRect(x: -7.4, y: -2.2, width: 4.4, height: 4.4)).fill()
        for y in [5.0, 0.0, -5.0] as [CGFloat] {
            let p = NSBezierPath()
            p.lineWidth = 1.7
            p.lineCapStyle = .round
            p.move(to: NSPoint(x: -3.4, y: 0))
            p.curve(to: NSPoint(x: 3.6, y: y), controlPoint1: NSPoint(x: 0, y: 0), controlPoint2: NSPoint(x: 0, y: y))
            p.stroke()
            let dot = NSBezierPath(ovalIn: NSRect(x: 3.8, y: y - 1.6, width: 3.2, height: 3.2))
            dot.lineWidth = 1.4
            dot.stroke()
        }
    }

    /// 三条错开的圆头横条，像水流
    private static func siliconflow() {
        for (y, x0, x1) in [(4.6, -6.5, 3.0), (0.0, -3.5, 6.5), (-4.6, -6.5, 1.5)] as [(CGFloat, CGFloat, CGFloat)] {
            let p = NSBezierPath()
            p.lineWidth = 2.6
            p.lineCapStyle = .round
            p.move(to: NSPoint(x: x0, y: y))
            p.line(to: NSPoint(x: x1, y: y))
            p.stroke()
        }
    }
}
