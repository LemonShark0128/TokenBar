import AppKit
import SwiftUI

// ---------------------------------------------------------------- B：数字行、口径标记、辅助平台行、套餐窗口列表

/// 今日 / 本月 / 第三格 —— 一行，不用卡片
struct StatRow: View {
    let items: [(String, String)]
    let p: Palette
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                VStack(alignment: .leading, spacing: 2) {
                    Text(it.0).font(.system(size: 11)).foregroundColor(p.sub)
                    Text(it.1).font(.num(17, .semibold)).foregroundColor(p.text)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11yText.stats(items))
    }
}

/// 口径标记：估算=橙、只有余额=灰；平台账单是正常情况，不再写「平台账单口径」（第 4 节，来源放在今日 / 本月的悬停提示）
struct SourceTag: View {
    let source: String?
    var p: Palette? = nil
    var body: some View {
        let tag = costSourceTag(source)
        if tag != "账单" { label(tag) }
    }

    @ViewBuilder private func label(_ tag: String) -> some View {
        // 只有余额是正常状态（没登录控制台），用中性灰，不当成警告
        let c: Color = tag == "余额" ? .secondary : Accent.orange
        let text = tag == "余额" ? L("row.balanceOnlyHint") : (sourceLabel(source) ?? L("source.unknownBasis"))
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 5, height: 5)
            Text(text).font(.system(size: 10.5)).foregroundColor(tag == "余额" ? c : (p?.warnText ?? c))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("menu.dataBasisA11y", A11yText.speak(text)))
    }
}

/// 辅助平台的一行：小油量图标 · 名称 · 今日花费（或异常原因，标橙）· 余额。点一行设为主平台
/// 套餐平台：名称旁是重置时间，右侧是「剩余 59%」
struct SideRow: View {
    let side: AppData.Side
    let level: Double
    let p: Palette
    var match: SwitchMatch? = nil
    var body: some View {
        HStack(spacing: 8) {
            GaugeLogo(value: level, size: 15, quota: side.isQuota).switchGeometry(match, "gauge")
            Text(side.name).font(.system(size: 12)).foregroundColor(p.text).switchGeometry(match, "name")
            if let resets = side.resetCredits {
                Text(resets).font(.system(size: 10)).foregroundColor(p.sub).lineLimit(1).truncationMode(.tail)
            }
            // 用完时右边已写「下次重置：…」，中间不再写「低于预警线」或别的窗口的重置时间（会互相矛盾）
            if let text = side.riskText, side.quotaExhausted == nil {
                Text(text).font(.system(size: 11)).foregroundColor(riskTint(side.riskSeverity, ok: p.sub, p: p)).lineLimit(1)
            } else if side.needsAttention {
                Text(side.status).font(.system(size: 11)).foregroundColor(p.warnText).lineLimit(1)
            } else if side.isQuota, side.quotaExhausted == nil {
                if let r = side.quotaReset {
                    Text(r).font(.num(11, .regular)).foregroundColor(p.sub).lineLimit(1)
                }
            } else if let t = side.todayCost {
                LT("panel.todayMoney", fmtMoney(t, side.currency))
                    .font(.num(11, .regular)).foregroundColor(p.sub).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(side.isQuota ? side.quotaExhausted?.text ?? quotaLeftText(side.quotaRemaining)
                 : fmtMoney(side.tank, side.currency))
                .font(.num(13, .semibold)).foregroundColor(side.quotaStale ? p.sub : quotaRemainingTint(side, normal: p.text, p: p)).lineLimit(1)
                .layoutPriority(1)
                .switchGeometry(match, "value")
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11yText.side(side))
    }

}

/// 套餐剩余读数的颜色：正常时用 normal，橙 / 红档用调色板的警示色；已用完、非套餐时也用 normal
func quotaRemainingTint(_ side: AppData.Side, normal: Color, p: Palette) -> Color {
    if side.quotaExhausted != nil { return normal }
    guard side.isQuota, let remaining = side.quotaRemaining else { return normal }
    switch QuotaLevel.severity(usedPercent: 100 - remaining) {
    case .ok: return normal
    case .warn: return p.warnText
    case .danger: return p.dangerText
    }
}

/// 套餐窗口分两行：名称、倒计时和剩余读数，下方为剩余条与节奏竖线。
struct QuotaWindowList: View {
    let rows: [AppData.QuotaRow]
    let p: Palette
    var dimmed: Bool = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rows) { r in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(r.name).font(.system(size: 12)).foregroundColor(p.text)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        if !r.isReset, let countdown = r.countdown {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.clockwise")
                                Text(countdown)
                            }.font(.system(size: 11)).foregroundColor(p.sub)
                        } else if !r.isReset, let reset = r.reset {
                            Text(reset).font(.system(size: 11)).foregroundColor(p.sub).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(r.isReset ? L("quota.windowResetShort") : quotaLeftText(100 - r.usedPercent))
                            .font(.num(11.5, .medium)).foregroundColor(p.text).lineLimit(1)
                    }
                    PaceBar(remaining: r.isReset ? 100 : 100 - r.usedPercent,
                            pace: r.isReset ? nil : r.paceRemainingPercent,
                            tint: dimmed ? p.sub.opacity(0.5) : quotaTint(QuotaLevel.severity(usedPercent: r.usedPercent)),
                            track: p.track, height: 7)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(A11yText.quotaWindow(r) + (dimmed ? L("panel.noData") : ""))
            }
        }
    }
}

/// 填充表示剩余额度；竖线仅表示按时间计算的剩余，不影响数字颜色。
struct PaceBar: View {
    let remaining: Double
    let pace: Double?
    let tint: Color
    let track: Color
    let height: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(tint)
                    .frame(width: g.size.width * CGFloat(min(100, max(0, remaining))) / 100)
                if let pace {
                    Rectangle().fill(colorScheme == .dark ? Color.white : Color.primary.opacity(0.85))
                        .frame(width: min(2, g.size.width), height: height + 4)
                        .offset(x: min(max(0, g.size.width - 2), max(0, g.size.width * CGFloat(min(100, max(0, pace))) / 100 - 1)))
                }
            }
            .frame(height: height)
        }
        .frame(height: height)
        .contentShape(Rectangle())
        .helpIfPresent(pace.map { PaceText.describe(remaining: remaining, pace: $0) })
        .accessibilityHidden(true)
    }
}

/// 平台全都隐藏时面板正文：每个隐藏平台一行「已隐藏：Kimi　显示」（这时面板里没别的，直接列出来）
struct HiddenPlatformsLine: View {
    let ids: [ProviderID]
    let p: Palette
    let onShow: (ProviderID) -> Void

    // 没有隐藏的平台时什么都不画（不占位，面板高度不变）
    @ViewBuilder var body: some View {
        if !ids.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ids, id: \.self) { id in
                HStack(spacing: 6) {
                    Image(systemName: "eye.slash").font(.system(size: 11)).foregroundColor(p.sub).accessibilityHidden(true)
                    Text(OnboardingPlan.hiddenLine([id])).font(.system(size: 11.5)).foregroundColor(p.sub).lineLimit(1)
                    Spacer(minLength: 6)
                    Button(L("today.show")) { onShow(id) }
                        .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundColor(Accent.blue)
                        .accessibilityLabel(L("today.showA11y", ProviderRegistry.displayName(id)))
                }
            }
        }
        }
    }
}

/// 「添加 / 移除平台」那一行右边的灰字「已隐藏 2 ⌄」（用户 11/6 选 proposal-hidden-bottom 丁）：
/// 不占新行，隐藏几个面板高度都不变；点开小弹窗，每个平台一行「显示」，两个以上时底下有「全部显示」。没有隐藏时不画
struct HiddenPlatformsButton: View {
    let ids: [ProviderID]
    let p: Palette
    /// nil = 全部显示
    let onShow: (ProviderID?) -> Void
    @State private var open = false

    @ViewBuilder var body: some View {
        if !ids.isEmpty {
            Button { open.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "eye.slash").font(.system(size: 11))
                    Text(OnboardingPlan.hiddenMenuTitle(ids)).font(.system(size: 11.5)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .foregroundColor(p.sub).contentShape(Rectangle())
            }
            .buttonStyle(.plain).fixedSize()
            .help(L("today.hiddenHint"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(OnboardingPlan.hiddenMenuA11y(ids))
            .accessibilityValue(open ? L("panel.expanded") : L("panel.collapsed"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open.toggle() }
            .modifier(HiddenListPopover(open: $open, ids: ids, p: p, onShow: { id in open = false; onShow(id) }))
        }
    }
}

/// 弹窗本体；离屏渲染时不挂
private struct HiddenListPopover: ViewModifier {
    @Binding var open: Bool
    let ids: [ProviderID]
    let p: Palette
    let onShow: (ProviderID?) -> Void
    @ViewBuilder func body(content: Content) -> some View {
        if kRendering {
            content
        } else {
            content.popover(isPresented: $open, arrowEdge: .bottom) {
                HiddenPlatformsList(ids: ids, p: p, onShow: onShow).padding(12).frame(width: 220)
            }
        }
    }
}

/// 弹窗里的列表：图标、平台名、「显示」；两个以上时底下「全部显示」
struct HiddenPlatformsList: View {
    let ids: [ProviderID]
    let p: Palette
    let onShow: (ProviderID?) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ids, id: \.self) { id in
                HStack(spacing: 8) {
                    Image(nsImage: PlatformGlyph.image(id, size: 12, tint: nil)).renderingMode(.template)
                        .foregroundColor(Color(nsColor: PlatformColor.color(id))).accessibilityHidden(true)
                    Text(ProviderRegistry.displayName(id)).font(.system(size: 12)).foregroundColor(p.text).lineLimit(1)
                    Spacer(minLength: 8)
                    Button(L("today.show")) { onShow(id) }
                        .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundColor(Accent.blue)
                        .accessibilityLabel(L("today.showA11y", ProviderRegistry.displayName(id)))
                }
            }
            if OnboardingPlan.showsShowAll(ids) {
                Hairline(p: p)
                HStack {
                    Spacer()
                    Button(L("today.showAllHidden")) { onShow(nil) }
                        .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundColor(Accent.blue)
                }
            }
        }
    }
}
