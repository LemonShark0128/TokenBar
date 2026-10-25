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
            for (on, text, size, top) in [(dayBadge, L("badge.day"), 5.6, false), (alertBadge, "!", 7.0, true)] where on {
                guard let ctx = NSGraphicsContext.current else { continue }
                let r: CGFloat = 3.9
                let c = NSPoint(x: rect.maxX - r, y: top ? rect.maxY - r : rect.minY + r)
                NSGraphicsContext.saveGraphicsState()
                ctx.compositingOperation = .destinationOut
                NSBezierPath(ovalIn: NSRect(x: c.x - r - 1, y: c.y - r - 1, width: 2 * r + 2, height: 2 * r + 2)).fill()
                ctx.compositingOperation = .sourceOver
                (tint ?? .black).setFill()
                NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
                ctx.compositingOperation = .destinationOut
                let g = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .heavy)])
                let gs = g.size()
                g.draw(at: NSPoint(x: c.x - gs.width / 2, y: c.y - gs.height / 2))
                NSGraphicsContext.restoreGraphicsState()
            }
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
        case .deepseek: deepseek()
        case .siliconflow: siliconflow()
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
