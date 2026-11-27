import AppKit
import SwiftUI

/// 新菜单栏样式共用的平台填充色；提示色只用于平台图标。
enum PlatformColor {
    static func color(_ id: ProviderID) -> NSColor {
        switch id {
        case .claudePlan: return NSColor(srgbRed: 0xD0/255.0, green: 0x80/255.0, blue: 0x5F/255.0, alpha: 1)
        case .codexPlan: return NSColor(srgbRed: 0x7F/255.0, green: 0x93/255.0, blue: 0xE8/255.0, alpha: 1)
        case .geminiPlan: return NSColor(srgbRed: 0x3A/255.0, green: 0xA7/255.0, blue: 0xF2/255.0, alpha: 1)
        default: return NSColor(srgbRed: 0x34/255.0, green: 0xC7/255.0, blue: 0x59/255.0, alpha: 1)
        }
    }
}

enum MenuBarStyles {
    static func color(_ id: ProviderID) -> NSColor { PlatformColor.color(id) }
    private static let iconWidth: CGFloat = 13
    private static let iconSpacing: CGFloat = 1
    private static var valueFont: NSFont { .monospacedDigitSystemFont(ofSize: 12, weight: .semibold) }
    /// 两组之间：数字后 5pt、分隔线 1pt、主平台图标前 5pt（组本身不再带尾部留白，系统按钮两边已有边距）
    /// 用户 2026-11-27 要求压缩总长：13 → 11
    private static let groupGap: CGFloat = 11
    /// 竖条到数字的间距（3 → 2）
    private static let numberGap: CGFloat = 2
    /// 「%」用小一号字，数字本身不变（每组省约 2.5pt）
    private static var percentFont: NSFont { .systemFont(ofSize: 9, weight: .semibold) }
    /// 竖条：外框 6×16、1pt 描边、两条间隔 1pt；颜色画在框内，四周与描边留 0.5pt 缝（用户 2026-11-27：参照系统监控类 App，颜色不压在框上）
    private static let barWidth: CGFloat = 6
    private static let barStep: CGFloat = 7
    private static let barFillInset: CGFloat = 1.5

    private static func fractions(_ cell: MenuBarCell) -> [Double?] {
        switch cell.kind {
        case .quota(let session, let weekly, _):
            return [session.map { $0 / 100 }, weekly.map { $0 / 100 }]
        case .payg(let runway, _, _): return [runway]
        }
    }

    private static func groupWidth(_ cell: MenuBarCell) -> CGFloat {
        iconWidth + iconSpacing + CGFloat(fractions(cell).count) * barStep - (barStep - barWidth)
    }

    /// 菜单栏数字：结尾的「%」换小一号字，其余（金额、「需登录」）照常
    static func numberText(_ cell: MenuBarCell, color: NSColor = .labelColor) -> NSAttributedString {
        let text = cell.primaryText
        let out = NSMutableAttributedString(string: text, attributes: [.font: valueFont, .foregroundColor: color])
        if text.hasSuffix("%") {
            let r = NSRange(location: (text as NSString).length - 1, length: 1)
            out.addAttributes([.font: percentFont, .baselineOffset: 0], range: r)
        }
        return out
    }

    static func measuredGroupWidth(_ cell: MenuBarCell) -> CGFloat {
        groupWidth(cell) + numberGap + ceil(numberText(cell).size().width)
    }

    static func displayedWidth(_ slots: MenuBarSlots) -> CGFloat {
        guard let main = slots.main else { return 1 }
        return measuredGroupWidth(main) + (slots.secondary.map { groupGap + measuredGroupWidth($0) } ?? 0)
    }

    static func image(_ slots: MenuBarSlots, appearance: NSAppearance,
                      mainDot: MenuBarTaskDot = .none, secondaryDot: MenuBarTaskDot = .none) -> NSImage {
        guard let main = slots.main else { return NSImage(size: NSSize(width: 1, height: 22)) }
        let mainWidth = measuredGroupWidth(main)
        // 11/6 起不再轮流显示；11/13 用户反馈左侧空太大，只按实际内容留宽。
        let width = displayedWidth(slots)
        let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
            appearance.performAsCurrentDrawingAppearance {
                let label = NSColor.labelColor
                func group(_ cell: MenuBarCell, x: CGFloat, dot: MenuBarTaskDot) {
                    NSGraphicsContext.saveGraphicsState()
                    let ctx = NSGraphicsContext.current?.cgContext
                    ctx?.setAlpha(cell.stale ? 0.35 : 1)
                    ctx?.beginTransparencyLayer(auxiliaryInfo: nil)
                    let alert: NSColor? = cell.severity == .danger ? AlertColor.danger : cell.severity == .warn ? AlertColor.warn : nil
                    let iconRect = NSRect(x: x, y: (22 - iconWidth) / 2, width: iconWidth, height: iconWidth)
                    PlatformGlyph.draw(cell.id, in: iconRect, color: alert ?? label.withAlphaComponent(0.85))
                    let values = fractions(cell)
                    let lowest = values.indices.filter { values[$0] != nil }.min { values[$0]! < values[$1]! }
                    for (index, fraction) in values.enumerated() {
                        let rect = NSRect(x: x + iconWidth + iconSpacing + CGFloat(index) * barStep, y: 3, width: barWidth, height: 16)
                        // 1pt 描边完全位于外框内，始终可见；颜色只填在描边内侧留缝后的区域，从下往上按比例升高。
                        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
                        outline.lineWidth = 1
                        label.withAlphaComponent(0.55).setStroke()
                        outline.stroke()
                        if let fraction, fraction.isFinite, fraction > 0 {
                            let inner = rect.insetBy(dx: barFillInset, dy: barFillInset)
                            // 有余量时至少留 1pt 高，避免 1%~5% 看起来和 0 一样
                            let height = max(1, inner.height * min(1, fraction))
                            NSGraphicsContext.saveGraphicsState()
                            NSBezierPath(roundedRect: inner, xRadius: 1, yRadius: 1).addClip()
                            (index == lowest ? alert ?? color(cell.id) : color(cell.id)).setFill()
                            NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: height).fill()
                            NSGraphicsContext.restoreGraphicsState()
                        }
                    }
                    if cell.exhausted, let graphics = NSGraphicsContext.current {
                        // 挂在图标右上角，与竖条右上角的运行圆点留开距离。
                        let center = NSPoint(x: iconRect.maxX - 3, y: 18)
                        NSGraphicsContext.saveGraphicsState()
                        graphics.compositingOperation = .destinationOut
                        NSBezierPath(ovalIn: NSRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)).fill()
                        graphics.compositingOperation = .sourceOver
                        AlertColor.danger.setFill()
                        NSBezierPath(ovalIn: NSRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)).fill()
                        graphics.compositingOperation = .destinationOut
                        let badge = NSAttributedString(string: L("mb.badge.exhausted"), attributes: [.font: NSFont.systemFont(ofSize: 6, weight: .heavy)])
                        badge.draw(at: NSPoint(x: center.x - badge.size().width / 2, y: center.y - badge.size().height / 2))
                        NSGraphicsContext.restoreGraphicsState()
                    }
                    if dot != .none {
                        let rect = NSRect(x: x + groupWidth(cell) - 4, y: 16, width: 5, height: 5)
                        // 先画外圈再画圆点，保留完整 1pt 边框，不被填充盖掉一半。
                        NSColor.windowBackgroundColor.setFill()
                        NSBezierPath(ovalIn: rect.insetBy(dx: -1, dy: -1)).fill()
                        (dot == .running ? NSColor.systemGreen : NSColor.systemGray).setFill()
                        NSBezierPath(ovalIn: rect).fill()
                    }
                    do {
                        let number = numberText(cell, color: label)
                        let digits = NSAttributedString(string: "0", attributes: [.font: valueFont])
                        number.draw(at: NSPoint(x: x + groupWidth(cell) + numberGap, y: (22 - digits.size().height) / 2))
                    }
                    ctx?.endTransparencyLayer()
                    NSGraphicsContext.restoreGraphicsState()
                }
                // 用户 2026-11-13：main / secondary 分别是左组 / 右组，严格按面板顺序从左到右画。
                group(main, x: 0, dot: mainDot)
                if let secondary = slots.secondary {
                    label.withAlphaComponent(0.25).setFill()
                    NSRect(x: mainWidth + groupGap / 2, y: 4, width: 1, height: 14).fill()
                    group(secondary, x: mainWidth + groupGap, dot: secondaryDot)
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

struct MenuBarStylesPreview: View {
    var cells: [MenuBarCell]
    var dark: Bool
    private var appearance: NSAppearance { NSAppearance(named: dark ? .darkAqua : .aqua)! }

    private func row(_ main: MenuBarCell, secondary: MenuBarCell? = nil,
                     mainRunning: Bool = false, secondaryRunning: Bool = false, text: String) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: MenuBarStyles.image(
                MenuBarSlots(main: main, secondary: secondary, mainRunning: mainRunning, secondaryRunning: secondaryRunning),
                appearance: appearance, mainDot: mainRunning ? .running : .none, secondaryDot: secondaryRunning ? .running : .none))
                .fixedSize().overlay(Rectangle().stroke(Color.gray.opacity(0.5), lineWidth: 0.5))
                .frame(width: 180, alignment: .leading)
            Text(L(text)).font(.system(size: 11))
            Spacer(minLength: 0)
        }.frame(height: 22)
    }

    var body: some View {
        let claude = cells.first { $0.id == .claudePlan }!
        let codex = cells.first { $0.id == .codexPlan }!
        let deepseek = cells.first { $0.id == .deepseek }!
        let warn = MenuBarCell(id: .codexPlan, kind: .quota(session: 12, weekly: 79, pace: nil), severity: .warn, stale: false, exhausted: false)
        let exhausted = MenuBarCell(id: .codexPlan, kind: .quota(session: 0, weekly: 65, pace: nil), severity: .danger, stale: false, exhausted: true)
        var stale = claude
        stale.stale = true
        return VStack(alignment: .leading, spacing: 15) {
            row(claude, text: "mb.preview.singleIdle")
            row(codex, mainRunning: true, text: "mb.preview.singleRunning")
            row(claude, text: "mb.preview.doubleIdle")
            row(claude, secondary: codex, secondaryRunning: true, text: "mb.preview.doubleRunning")
            row(deepseek, secondary: codex, secondaryRunning: true, text: "mb.preview.payg")
            row(warn, text: "mb.preview.warn")
            row(exhausted, text: "mb.preview.exhausted")
            row(stale, text: "mb.preview.stale")
            HStack(spacing: 12) {
                HStack(spacing: 3) {
                    Image(nsImage: PlatformGlyph.menuImage(.claudePlan, tint: nil))
                    Text(MenuBarText.title(mode: "balance", isQuota: true, balance: nil, today: nil,
                                           quotaUsed: 53, currency: "PCT", exhausted: nil)).font(Font(kStatusFont))
                }.frame(width: 140, alignment: .leading)
                Text(L("mb.preview.classic")).font(.system(size: 11))
                Spacer(minLength: 0)
            }.frame(height: 22)
        }
        .foregroundColor(dark ? .white : .black)
        .padding(16).frame(width: 520, height: 360)
        .background(dark ? Color(white: 0.13) : Color(white: 0.96))
    }
}
