import AppKit
import SwiftUI

// ---------------------------------------------------------------- logo：油量式圆形仪表

/// 汽车油量表风格：开口朝下的刻度弧 + 剩余弧 + 指针 + 中心轴。
/// 菜单栏用 template 图（交给系统着色），面板内用带色版（按油量档位绿/橙/红）。
enum GaugeIcon {
    static let startDeg = 210.0
    static let sweepDeg = 240.0

    /// weight：线宽倍数（菜单栏用 1.45，和 Wi‑Fi/电池这些系统图标的笔画粗细对齐）；trackAlpha：底轨不透明度
    static func draw(in rect: NSRect, value: Double, tint: NSColor?, showTicks: Bool = true,
                     weight: CGFloat = 1, trackAlpha: CGFloat? = nil) {
        let v = max(0.0, min(1.0, value))
        let cx = rect.midX, cy = rect.midY
        let lineW = max(1.1, rect.width * 0.10 * weight)
        let r = min(rect.width, rect.height) / 2 - lineW / 2 - 0.5
        guard r > 0.6 else { return }
        let base = tint ?? NSColor.black

        if showTicks && rect.width >= 22 {
            for i in 0...4 {
                let a = (startDeg - sweepDeg * Double(i) / 4) * .pi / 180
                let t = NSBezierPath()
                t.move(to: NSPoint(x: cx + cos(a) * (r + lineW * 0.7),
                                   y: cy + sin(a) * (r + lineW * 0.7)))
                t.line(to: NSPoint(x: cx + cos(a) * (r + lineW * 1.45),
                                   y: cy + sin(a) * (r + lineW * 1.45)))
                t.lineWidth = max(0.7, lineW * 0.30)
                t.lineCapStyle = .round
                base.withAlphaComponent(0.5).setStroke()
                t.stroke()
            }
        }

        let track = NSBezierPath()
        track.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: r,
                        startAngle: startDeg, endAngle: startDeg - sweepDeg, clockwise: true)
        track.lineWidth = lineW
        track.lineCapStyle = .round
        base.withAlphaComponent(trackAlpha ?? (tint == nil ? 0.32 : 0.22)).setStroke()
        track.stroke()

        if v > 0.002 {
            let used = NSBezierPath()
            used.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: r,
                           startAngle: startDeg, endAngle: startDeg - sweepDeg * v, clockwise: true)
            used.lineWidth = lineW
            used.lineCapStyle = .round
            base.setStroke()
            used.stroke()
        }

        let a = (startDeg - sweepDeg * v) * .pi / 180
        let needle = NSBezierPath()
        needle.move(to: NSPoint(x: cx, y: cy))
        needle.line(to: NSPoint(x: cx + cos(a) * r * 0.66, y: cy + sin(a) * r * 0.66))
        needle.lineWidth = max(1.0, lineW * 0.85)
        needle.lineCapStyle = .round
        base.setStroke()
        needle.stroke()

        let hubR = lineW * 0.62
        let hub = NSBezierPath(ovalIn: NSRect(x: cx - hubR, y: cy - hubR,
                                              width: hubR * 2, height: hubR * 2))
        base.setFill()
        hub.fill()
    }

    static func image(value: Double, size: CGFloat, template: Bool = true,
                      tint: NSColor? = nil) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect, value: value, tint: template ? NSColor.black : tint)
            return true
        }
        img.isTemplate = template
        return img
    }

    /// 菜单栏图标：油量表 + 可选角标「日」（今日花费模式）。角标用挖空的方式画，template 图也能正确显示
    static func menuImage(value: Double, template: Bool, tint: NSColor? = nil, dayBadge: Bool, alertBadge: Bool = false) -> NSImage {
        let pt = kMenuIconPt
        let img = NSImage(size: NSSize(width: pt, height: pt), flipped: false) { rect in
            let color = template ? NSColor.black : (tint ?? .black)
            draw(in: rect, value: value, tint: color, weight: 1.45, trackAlpha: 0.35)
            drawBadges(in: rect, color: color, dayBadge: dayBadge, alertBadge: alertBadge)
            return true
        }
        img.isTemplate = template
        return img
    }

    /// 菜单栏图标角标（油量表与平台标志共用）：右下「日」、右上「!」。挖空画法，template 图也能正确显示
    static func drawBadges(in rect: NSRect, color: NSColor, dayBadge: Bool, alertBadge: Bool) {
        for (on, text, size, top) in [(dayBadge, L("badge.day"), 5.6, false), (alertBadge, "!", 7.0, true)] where on {
            guard let ctx = NSGraphicsContext.current else { continue }
            let r: CGFloat = 3.9
            let c = NSPoint(x: rect.maxX - r, y: top ? rect.maxY - r : rect.minY + r)
            NSGraphicsContext.saveGraphicsState()
            ctx.compositingOperation = .destinationOut           // 先挖一圈缝，角标和图形分开
            NSBezierPath(ovalIn: NSRect(x: c.x - r - 1, y: c.y - r - 1, width: 2 * r + 2, height: 2 * r + 2)).fill()
            ctx.compositingOperation = .sourceOver
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
            ctx.compositingOperation = .destinationOut           // 字挖空
            let g = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .heavy)])
            let gs = g.size()
            g.draw(at: NSPoint(x: c.x - gs.width / 2, y: c.y - gs.height / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// 三档颜色（油量表、套餐色共用）
    static let okColor = NSColor(red: 0.20, green: 0.80, blue: 0.45, alpha: 1)
    static let warnColor = AlertColor.warn
    static let dangerColor = AlertColor.danger

    /// dark：给定时取固定的深 / 浅色（画进 NSImage 再交给 SwiftUI 的地方要用，否则会按画图那一刻的进程外观取色）；nil = 随外观自动
    static func levelColor(_ v: Double, dark: Bool? = nil) -> NSColor {
        if v <= 0.02 { return dark.map(AlertColor.danger(dark:)) ?? dangerColor }
        if v < 0.15 { return dark.map(AlertColor.warn(dark:)) ?? warnColor }
        return okColor
    }

    /// 套餐：按已用比例（QuotaLevel：≥80% 橙、≥95% 红），颜色同 levelColor 的三档
    static func quotaColor(_ remaining: Double, dark: Bool? = nil) -> NSColor {
        switch QuotaLevel.severity(remainingFraction: remaining) {
        case .ok: return levelColor(1, dark: dark)
        case .warn: return levelColor(0.1, dark: dark)
        case .danger: return levelColor(0, dark: dark)
        }
    }
}

struct GaugeLogo: View {
    let value: Double
    var size: CGFloat = 14
    var template: Bool = false
    /// 套餐平台：弧线、指针和颜色均按剩余比例
    var quota: Bool = false
    /// 读外观：切换深 / 浅色时重画，图标取对应的提醒色
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let dark = scheme == .dark
        Image(nsImage: GaugeIcon.image(value: GaugeGeometry.arcFraction(level: value), size: size * 2, template: template,
                                       tint: quota ? GaugeIcon.quotaColor(value, dark: dark) : GaugeIcon.levelColor(value, dark: dark)))
            .resizable()
            .frame(width: size, height: size)
            // 小图标只是装饰（旁边的文字已经写了读数），VoiceOver 跳过
            .accessibilityHidden(true)
    }
}

/// logo 自检板：不同尺寸 + 不同油量 + 菜单栏 template 版（深浅底各一）
struct LogoBoard: View {
    @ObservedObject var model: UsageModel
    let p: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("logo：油量式圆形仪表（指针 = 余额 ÷ 满格 ¥\(Int(model.fuelFullCny))）")
                .font(.system(size: 11, weight: .semibold)).foregroundColor(p.sub)
            HStack(alignment: .bottom, spacing: 20) {
                ForEach([14.0, 22.0, 32.0, 48.0, 72.0], id: \.self) { s in
                    VStack(spacing: 6) {
                        GaugeLogo(value: model.fuelLevel, size: s)
                        Text("\(Int(s))pt").font(.system(size: 9)).foregroundColor(p.sub)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 20) {
                ForEach([0.0, 0.08, 0.35, 0.72, 1.0], id: \.self) { v in
                    VStack(spacing: 6) {
                        GaugeLogo(value: v, size: 42)
                        Text(String(format: "油量 %.0f%%", v * 100))
                            .font(.system(size: 9)).foregroundColor(p.sub)
                    }
                }
            }
            HStack(spacing: 10) {
                GaugeLogo(value: model.fuelLevel, size: 34, template: true)
                    .padding(7)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.13)))
                GaugeLogo(value: model.fuelLevel, size: 34, template: true)
                    .padding(7)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.93)))
                Text("菜单栏 template 版：深色/浅色菜单栏（由系统着色）")
                    .font(.system(size: 10)).foregroundColor(p.sub)
            }
        }
        .padding(14)
        .background(LinearGradient(colors: [p.bgTop, p.bgBottom], startPoint: .top, endPoint: .bottom))
    }
}
