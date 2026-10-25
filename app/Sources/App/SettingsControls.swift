import AppKit
import Combine
import SwiftUI

// ---------------------------------------------------------------- 设置（系统设置式分组行）

/// 自绘开关：外观同系统 switch，但离屏自检能渲染（系统 NSSwitch 在 ImageRenderer 里是一块黄色占位）
struct PillSwitch: View {
    let on: Bool
    /// 读屏名称（行标签在开关外面）
    var title: String = ""
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? Accent.green : Color.gray.opacity(0.35)).frame(width: 32, height: 19)
                Circle().fill(Color.white).frame(width: 15, height: 15).padding(2)
                    .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
            }
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: on)
        .accessibilityLabel(title)
        .accessibilityValue(on ? L("set.on") : L("opt.off"))
        .accessibilityAddTraits(.isToggle)
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    let p: Palette
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty {
                Text(title).font(.system(size: 11)).foregroundColor(p.sub).padding(.leading, 4)
            }
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(p.group))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(p.border, lineWidth: 0.5))
        }
    }
}

struct SettingsRow<Trailing: View>: View {
    let label: String
    /// 标签下面的一句灰色说明（nil = 不写）
    var help: String? = nil
    var first = false
    let p: Palette
    @ViewBuilder var trailing: Trailing
    var body: some View {
        VStack(spacing: 0) {
            if !first { Hairline(p: p).padding(.leading, 12) }
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.system(size: 12.5)).foregroundColor(p.text)
                    if let help {
                        Text(help).font(.system(size: 11)).foregroundColor(p.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                trailing
            }
            .padding(.horizontal, 12).padding(.vertical, help == nil ? 0 : 7)
            .frame(minHeight: 36)
        }
    }
}

/// 汇率只读一行：自动取近 7 天平均（ExchangeRate），不再手填。live=false（离屏渲染）时按默认值画，不读本机设置
struct ExchangeRateRow: View {
    let live: Bool
    let p: Palette
    var body: some View {
        let d = UserDefaults.standard
        let rate = (live ? ProviderSettings.load(d) : ProviderSettings()).usdToCny
        let caption = live ? ExchangeRate.caption(d, now: Date())
            : ExchangeRate.caption(rate: rate, updated: nil, failedAt: nil, manual: false, now: Date())
        VStack(spacing: 0) {
            Hairline(p: p).padding(.leading, 12)
            VStack(alignment: .leading, spacing: 2) {
                LT("set.fxRate", NSDecimalNumber(decimal: rate).stringValue)
                    .font(.system(size: 12.5)).foregroundColor(p.text)
                Text(caption)
                    .font(.system(size: 10.5)).foregroundColor(p.sub)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(minHeight: 36)
        }
    }
}

/// 油箱刻度：满盘、预警线、当前余额画在同一条刻度上
struct TankScale: View {
    let balance: Double
    let full: Double
    let alert: Double
    /// 币种（nil = 人民币）
    var currency: String? = nil
    /// 套餐平台：数字都是百分比，满格 = 100%
    var percent = false
    let p: Palette
    private func amount(_ v: Double, _ digits: Int = 2) -> String {
        percent ? quotaPercent(v) : fmtMoney(v, currency, digits)
    }
    var body: some View {
        let lv = full > 0 ? max(0, min(1, balance / full)) : 0
        let al = full > 0 ? max(0, min(1, alert / full)) : 0
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .topLeading) {
                Capsule().fill(p.track).frame(width: w, height: 8).offset(y: 18)
                Capsule().fill(percent ? quotaTint(QuotaLevel.severity(remainingFraction: lv)) : levelTint(lv)).frame(width: max(8, w * lv), height: 8).offset(y: 18)
                if alert > 0 {
                    Rectangle().fill(Accent.orange).frame(width: 1.5, height: 20).offset(x: w * al, y: 12)
                    LT("set.alertTick", amount(alert, 0)).font(.num(11, .regular)).foregroundColor(p.warnText)
                        .fixedSize().offset(x: max(0, w * al - 22), y: -2)
                }
                RoundedRectangle(cornerRadius: 1.5).fill(p.text).frame(width: 3, height: 24)
                    .offset(x: w * lv - 1.5, y: 10)
                Text(amount(balance)).font(.num(11, .medium)).foregroundColor(p.text)
                    .fixedSize().offset(x: min(max(0, w * lv - 24), w - 52), y: 36)
                LT("set.fullTick", amount(full, 0)).font(.num(11, .regular)).foregroundColor(p.sub)
                    .fixedSize().frame(width: w, alignment: .trailing).offset(y: -2)
            }
        }
        .frame(height: 52)
    }
}

/// 透明度滑块：0% 不透明 … 100% 最透，拖动时所有窗口一起变。
/// 自绘（系统 Slider 在离屏渲染里是一块黄色占位）
struct TransparencySlider: View {
    @ObservedObject private var glass = Glass.shared
    let p: Palette
    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { g in
                let w = g.size.width, knob: CGFloat = 16
                let v = max(0, min(1, glass.transparency))
                ZStack(alignment: .leading) {
                    Capsule().fill(p.track).frame(height: 4)
                    Capsule().fill(Accent.blue).frame(width: max(4, (w - knob) * v + knob / 2), height: 4)
                    Circle().fill(Color.white).frame(width: knob, height: knob)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                        .offset(x: (w - knob) * v)
                }
                .frame(height: g.size.height)
                // 设置窗可以拖背景移动（isMovableByWindowBackground），自绘滑块不算控件，拖动会被窗口拿去移动窗口。
                // 所以叠一层不许拖窗口的 NSView 自己接鼠标；离屏渲染不放它（ImageRenderer 画不了 NSView，会是黄块）
                .overlay {
                    if !kRendering {
                        MouseTrack { x in glass.transparency = SliderMath.value(x: x, width: w, knob: knob) }
                    }
                }
            }
            .frame(width: 130, height: 18)
            .accessibilityElement()
            .accessibilityLabel(L("set.transparency"))
            .accessibilityValue("\(Int((glass.transparency * 100).rounded()))%")
            .accessibilityAdjustableAction { dir in
                let step = dir == .increment ? 0.05 : -0.05
                glass.transparency = max(0, min(1, glass.transparency + step))
            }
            Text("\(Int((glass.transparency * 100).rounded()))%")
                .font(.num(12, .regular)).foregroundColor(p.sub).frame(width: 36, alignment: .trailing)
        }
    }
}

/// 接住按下和拖动、不让窗口借机移动的透明层；回调鼠标在本视图里的横坐标
struct MouseTrack: NSViewRepresentable {
    let onX: (CGFloat) -> Void
    final class V: NSView {
        var onX: ((CGFloat) -> Void)?
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with e: NSEvent) { onX?(convert(e.locationInWindow, from: nil).x) }
        override func mouseDragged(with e: NSEvent) { onX?(convert(e.locationInWindow, from: nil).x) }
    }
    func makeNSView(context: Context) -> V { let v = V(); v.onX = onX; return v }
    func updateNSView(_ v: V, context: Context) { v.onX = onX }
}

// ---------------------------------------------------------------- 自绘下拉 / 「···」菜单
// 系统 Menu、Picker 在离屏渲染里都是黄色占位：外观自己画，点击时再弹真正的 NSMenu

@MainActor
enum PopMenu {
    final class Target: NSObject {
        let fn: () -> Void
        init(_ fn: @escaping () -> Void) { self.fn = fn }
        @objc func run() { fn() }
    }

    struct Item {
        var title: String
        var checked = false
        var destructive = false
        var separatorBefore = false
        var action: () -> Void
    }

    /// 在鼠标处弹出菜单；有勾选项时让它对准鼠标（同系统弹出按钮）
    static func show(_ items: [Item]) {
        guard !kRendering, !items.isEmpty else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        var selected: NSMenuItem?
        for it in items {
            if it.separatorBefore { menu.addItem(.separator()) }
            let mi = NSMenuItem(title: it.title, action: #selector(Target.run), keyEquivalent: "")
            let t = Target(it.action)
            mi.target = t
            mi.representedObject = t          // target 是弱引用：靠 representedObject 留住
            if it.checked { mi.state = .on; selected = mi }
            if it.destructive {
                mi.attributedTitle = NSAttributedString(string: it.title, attributes: [
                    .foregroundColor: NSColor.systemRed, .font: NSFont.menuFont(ofSize: 0)])
            }
            menu.addItem(mi)
        }
        var at = NSEvent.mouseLocation
        at.x -= 12
        at.y += selected == nil ? -6 : 8
        menu.popUp(positioning: selected, at: at, in: nil)
    }
}

/// 下拉：右侧一个小按钮（当前值 + ▾），点开是系统菜单
struct DropdownButton: View {
    /// 读屏名称（行标签在按钮外面），如「主平台」「DeepSeek 预警线」
    let title: String
    let options: [SettingsLayout.Option]
    let selected: String
    /// 选中值不在选项里时显示的文字（如旧版存的「¥30」）
    var fallback: String? = nil
    let p: Palette
    let onPick: (String) -> Void

    var body: some View {
        let current = SettingsLayout.label(of: selected, in: options, fallback: fallback)
        Button {
            PopMenu.show(options.map { o in PopMenu.Item(title: o.label, checked: o.key == selected) { onPick(o.key) } })
        } label: {
            HStack(spacing: 5) {
                Text(current).font(.system(size: 12)).foregroundColor(p.text).lineLimit(1).fixedSize()
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundColor(p.sub)
            }
            .padding(.leading, 9).padding(.trailing, 7).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(p.dark ? Color.white.opacity(0.08) : Color.white)
                .shadow(color: .black.opacity(p.dark ? 0 : 0.06), radius: 0.5, y: 0.5))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(p.border, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(current)
        .accessibilityHint(L("set.showOptions"))
    }
}

/// 账号行末尾的「···」：点开是这个账号的操作
struct MoreButton: View {
    /// 平台名：读屏念「DeepSeek 更多操作」
    var title: String = ""
    let p: Palette
    let items: () -> [PopMenu.Item]
    var body: some View {
        Button { PopMenu.show(items()) } label: {
            Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)).foregroundColor(p.sub)
                .frame(width: 24, height: 20)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(p.cardAlt))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title.isEmpty ? L("set.moreActions") : L("set.moreActionsFor", title))
    }
}
