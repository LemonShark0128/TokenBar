import AppKit
import Combine
import SwiftUI
import UserNotifications

// ---------------------------------------------------------------- 右键菜单顶部信息卡

/// 悬停状态（菜单里的自定义视图拿不到系统高亮，自己跟踪）
@MainActor
final class HoverState: ObservableObject { @Published var on = false }

/// 右键菜单顶部的整块信息卡：小油量表 + 余额/可用天数/时速，今日/本月/命中，口径+新鲜度，下面每个辅助平台一行。
/// 颜色跟着菜单本身的深浅走，过时套餐读数使用次要文字色。
struct MenuInfoCard: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var hover: HoverState
    /// 读屏「打开面板」用（鼠标点击由 MenuCardHost 处理）；离屏预览不传
    var onOpen: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    private var p: Palette { Palette.of(colorScheme == .dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let d = model.data, d.balance.isQuota {
                // 套餐平台：一行文字（已用百分比 + 重置时间），没有今日 / 本月
                HStack(spacing: 10) {
                    GaugeLogo(value: model.fuelLevel, size: 30, template: d.quota?.stale == true, quota: true)
                        .foregroundColor(d.quota?.stale == true ? p.sub.opacity(0.5) : p.text)
                    if d.quota?.remainingPercent == nil {
                        // 没有额度数据时是一句引导（如「打开 Claude 桌面 App…」）：允许折行，不截断
                        LT("menu.quotaNoteLine", model.mainName, d.quota?.note ?? L("codex.noDataNote"))
                            .font(.system(size: 12.5, weight: .medium)).foregroundColor(.primary).lineLimit(5)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.mainQuotaSide?.quotaLine ?? model.mainName)
                                .font(.system(size: 12.5, weight: .medium)).foregroundColor(d.quota?.stale == true ? p.sub : .primary).lineLimit(1).minimumScaleFactor(0.8)
                            if let chip = d.runway {
                                Text(chip.short).font(.system(size: 11.5))
                                    .foregroundColor(chip.muted ? .secondary : riskTint(chip.severity, ok: .secondary)).lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 6)
                    LT("menu.panelLink").font(.system(size: 11.5)).foregroundColor(Accent.blue)
                        .opacity(hover.on ? 1 : 0.75)
                }
                .mainA11y(d.quota?.remainingPercent == nil
                          ? A11yText.quotaNoData(provider: model.mainName, note: d.quota?.note)
                          : A11yText.gaugeValue(base: model.gaugeA11y(d), chipTitle: d.runway?.short, chipDetail: nil)
                            + (d.quota?.stale == true ? L("panel.noData") : ""),
                          onOpen: onOpen)
                runningRows()
                sideRows(d)
            } else if let d = model.data {
                let (cap, spike) = burnCaption(d, fuelFull: model.fuelFullCny, compact: true)
                HStack(spacing: 10) {
                    GaugeLogo(value: model.fuelLevel, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        if d.sides.isEmpty {
                            Text(fmtMoney(d.balance.cny, d.balance.currency)).font(.num(17, .semibold)).foregroundColor(.primary)
                        } else {
                            // 不止一个平台时写明主卡是哪个平台
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text(fmtMoney(d.balance.cny, d.balance.currency)).font(.num(17, .semibold)).foregroundColor(.primary)
                                Text(model.mainName)
                                    .font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                            }
                        }
                        Text(d.runway?.short ?? cap).font(.system(size: 11.5))
                            .foregroundColor(d.runway.map { $0.muted ? .secondary : riskTint($0.severity, ok: .secondary) } ?? (spike ? Accent.orange : .secondary)).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    LT("menu.panelLink").font(.system(size: 11.5)).foregroundColor(Accent.blue)
                        .opacity(hover.on ? 1 : 0.75)
                }
                .mainA11y(A11yText.gaugeValue(base: model.gaugeA11y(d), chipTitle: d.runway?.short ?? cap, chipDetail: nil),
                          onOpen: onOpen)
                HStack(alignment: .top, spacing: 0) {
                    // 花费未知（只有余额 / 离线）写「—」，不写 ¥0.00
                    ForEach([(L("panel.today"), d.today.known ? fmtMoney(d.today.costCny, d.balance.currency) : "—"),
                              (L("panel.month"), d.month.known ? fmtMoney(d.month.costCny, d.balance.currency) : "—"),
                             (L("panel.cacheHit"), overallHitRate(d.models))], id: \.0) { it in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(it.0).font(.system(size: 11)).foregroundColor(.secondary)
                            Text(it.1).font(.num(13, .semibold)).foregroundColor(.primary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(A11yText.stats([(L("panel.today"), d.today.known ? fmtMoney(d.today.costCny, d.balance.currency) : "—"),
                                                    (L("panel.month"), d.month.known ? fmtMoney(d.month.costCny, d.balance.currency) : "—"),
                                                    (L("panel.cacheHit"), overallHitRate(d.models))]))
                HStack(spacing: 6) {
                    let f = model.freshness
                    Circle().fill(f.0 == .ok ? Accent.green : (f.0 == .offline ? Accent.red : Accent.orange))
                        .frame(width: 6, height: 6)
                    Text("\(sourceLabel(d.today.source) ?? "—") · \(f.1)")
                        .font(.num(11, .regular)).foregroundColor(.secondary)
                    Spacer(minLength: 6)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L("menu.dataBasisA11y", A11yText.speak("\(sourceLabel(d.today.source) ?? L("source.unknown")) · \(model.freshness.1)")))
                runningRows()
                sideRows(d)
            } else {
                HStack(spacing: 8) {
                    Circle().fill(Accent.red).frame(width: 6, height: 6)
                    Text(model.error ?? (model.needsSetup ? L("a11y.noPlatforms") : L("status.connecting", model.mainName))).font(.system(size: 12)).foregroundColor(.secondary)
                    Spacer()
                    LT("menu.panelLink").font(.system(size: 11.5)).foregroundColor(Accent.blue)
                }
                .mainA11y(model.error ?? (model.needsSetup ? L("a11y.noPlatforms") : L("a11y.connecting", model.mainName)), onOpen: onOpen)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(hover.on ? 0.09 : 0.045)))
        .padding(.horizontal, 6).padding(.top, 2).padding(.bottom, 4)
        // 至少 300pt；菜单被更长的一行撑宽时跟着变宽，和菜单对齐
        .frame(minWidth: MenuCardHost.width, maxWidth: .infinity)
    }

    /// 辅助平台：每个一行（名称 · 今日花费或异常原因 · 余额；套餐平台是重置时间 · 已用百分比）
    /// 正在跑的任务：主平台区和其他平台行之间，没有任务时不占地方
    @ViewBuilder
    private func runningRows() -> some View {
        if !model.runningTasks.isEmpty {
            Divider()
            RunningTasksSection(tasks: model.runningTasks, fixedNow: model.fixedNow, p: p, compact: true)
        }
    }

    @ViewBuilder
    private func sideRows(_ d: AppData) -> some View {
        if !d.sides.isEmpty {
            Divider()
            ForEach(d.sides) { sd in
                HStack(spacing: 6) {
                    Text(sd.name).font(.system(size: 11.5)).foregroundColor(.primary)
                    // 用完时右边已写「下次重置：…」，中间不再写风险或别的窗口的重置时间（同面板 SideRow）
                    if let text = sd.riskText, sd.quotaExhausted == nil {
                        Text(text).font(.system(size: 11)).foregroundColor(riskTint(sd.riskSeverity, ok: .secondary)).lineLimit(1)
                    } else if sd.needsAttention {
                        Text(sd.status).font(.system(size: 11)).foregroundColor(Accent.orange).lineLimit(1)
                    } else if sd.isQuota, sd.quotaExhausted == nil {
                        if let r = sd.quotaReset {
                            Text(r).font(.num(11, .regular)).foregroundColor(.secondary).lineLimit(1)
                        }
                    } else if let t = sd.todayCost {
                        LT("panel.todayMoney", fmtMoney(t, sd.currency))
                            .font(.num(11, .regular)).foregroundColor(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Text(sd.isQuota ? sd.quotaExhausted?.text ?? L("panel.used", quotaUsedPercent(remaining: sd.quotaRemaining))
                         : fmtMoney(sd.tank, sd.currency))
                        .font(.num(11.5, .semibold)).foregroundColor(sd.quotaStale ? p.sub : quotaRemainingTint(sd))
                        .lineLimit(1).layoutPriority(1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(A11yText.side(sd))
            }
            if let t = d.totalTodayCny {
                HStack {
                    Spacer()
                    LT("panel.todayTotal", d.totalIsApprox ? "≈" : "", fmtCNY(t)).font(.num(11, .regular)).foregroundColor(.secondary)
                        .accessibilityLabel(A11yText.speak(L("panel.todayTotal", d.totalIsApprox ? "≈" : "", fmtCNY(t))))
                }
            }
        }
    }
    private func quotaRemainingTint(_ side: AppData.Side) -> Color {
        if side.quotaExhausted != nil { return .primary }
        guard side.isQuota, let remaining = side.quotaRemaining else { return .primary }
        switch QuotaLevel.severity(usedPercent: 100 - remaining) {
        case .ok: return .primary
        case .warn: return p.warnText
        case .danger: return p.dangerText
        }
    }

}

/// 把信息卡塞进 NSMenuItem.view：自己跟踪悬停、自己处理点击（自定义视图的菜单项不会触发 action）
final class MenuCardHost: NSView {
    static let width: CGFloat = 300
    private let hover = HoverState()
    private let onClick: () -> Void

    init(model: UsageModel, onClick: @escaping () -> Void) {
        self.onClick = onClick
        var card = MenuInfoCard(model: model, hover: hover)
        let h = Fit.height(card, width: MenuCardHost.width)
        super.init(frame: NSRect(x: 0, y: 0, width: MenuCardHost.width, height: h))
        // VoiceOver 按下信息卡：和鼠标点击一样收起菜单、打开面板
        card.onOpen = { [weak self] in self?.open() }
        // 宽度可伸缩：NSMenu 会把菜单项视图拉到菜单的实际宽度（菜单被提醒行等撑宽时，信息卡跟着对齐）
        autoresizingMask = [.width]
        let hosting = NSHostingView(rootView: card)
        hosting.sizingOptions = []      // 不让 SwiftUI 按内容钉死宽度，跟着菜单项伸缩
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hover.on = true }
    override func mouseExited(with event: NSEvent) { hover.on = false }
    /// 子视图（SwiftUI）不接点击，全部交给这里
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseUp(with event: NSEvent) { open() }
    private func open() {
        hover.on = false
        enclosingMenuItem?.menu?.cancelTracking()
        onClick()
    }
}

private extension View {
    /// 信息卡第一行：一句话读主平台，按下 = 打开面板（「面板 ›」不单独读）
    func mainA11y(_ text: String, onOpen: (() -> Void)?) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(A11yText.speak(text))
            .accessibilityAddTraits(onOpen != nil ? .isButton : [])
            .accessibilityHint(onOpen != nil ? L("menu.openPanel") : "")
            .accessibilityAction { onOpen?() }
    }
}

/// 菜单栏各状态的离屏预览（真菜单栏由系统绘制，截不到）
struct MenuBarPreview: View {
    @ObservedObject var model: UsageModel
    /// 套餐平台版（Codex 套餐）：写当前会话已用百分比，「今日花费」模式也一样
    var quota = false
    private func item(_ label: String, mode: String, low: Bool = false, spike: Bool = false, value: Double? = nil,
                      currency: String? = nil, riskHours: Double? = nil, danger: Bool = false, alertBadge: Bool = false,
                      risk: PlatformRisk? = nil) -> some View {
        let d = model.data
        // 与 StatusBarController.refresh 同一个函数生成文字；图标显示当前平台标志
        let exhausted = quota && value == nil && risk == nil ? model.menuBarQuotaSide?.menuQuota?.exhausted : nil
        let riskTitle = risk.flatMap { MenuBarText.riskTitle($0, mode: mode) }
        let amount = riskTitle ?? riskHours.map { Runway.compactText(hours: $0) } ?? MenuBarText.title(mode: mode, isQuota: quota, balance: value ?? d?.balance.cny, today: value ?? d?.today.costCny,
                                       quotaUsed: value ?? model.menuBarQuotaSide?.menuQuota?.usedPercent, currency: currency,
                                       exhausted: exhausted)
        let quotaSeverity = MenuBarText.quotaSeverity(isQuota: quota,
            usedPercent: value ?? model.menuBarQuotaSide?.menuQuota?.usedPercent, risk: risk)
        let quotaColor: Color = quotaSeverity == .danger ? Color(nsColor: .systemRed)
            : quotaSeverity == .warn ? Color(nsColor: .systemOrange) : .white
        let color: Color = exhausted != nil ? .white
            : quotaSeverity != nil ? quotaColor : danger ? Color(nsColor: .systemRed) : (low || spike || riskHours != nil || riskTitle != nil) ? Color(nsColor: .systemOrange) : .white
        return HStack(spacing: 12) {
            HStack(spacing: 0) {
                Image(nsImage: PlatformGlyph.menuImage(risk?.id ?? (quota ? .codexPlan : .deepseek), tint: nil,
                                                      dayBadge: mode == "cost" && !quota, alertBadge: alertBadge))
                    .renderingMode(.template).foregroundColor(color)
                if !amount.isEmpty {
                    Text(amount).font(Font(kStatusFont)).foregroundColor(color).padding(.leading, 4)
                }
            }
            .padding(.horizontal, 8).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.12)))
            Text(label).font(.system(size: 10)).foregroundColor(.white.opacity(0.7))
            Spacer()
        }
    }
    /// 预览用的风险读数
    static func quotaRisk(_ id: ProviderID, remaining: Double) -> PlatformRisk {
        let w = QuotaWindow(kind: .session, usedPercent: 100 - remaining, resetsAt: nil, windowMinutes: 300)
        let q = QuotaRunway(window: w, remainingPercent: remaining, risePP: 20, hoursToEmpty: 0.5, resetsAt: nil,
                            state: .runsOut, severity: .danger)
        return PlatformRisk(id: id, kind: .quota(q), hours: 0.5, atRisk: true, severity: .danger)
    }
    static func paygRisk(_ id: ProviderID, hours: Double) -> PlatformRisk {
        let p = PaygRunway(hours: hours, basis: .recentSpike, severity: hours < 2 ? .danger : .warn, perHourRecent: 4.8, multiple: 21)
        return PlatformRisk(id: id, kind: .payg(p), hours: hours, atRisk: true, severity: p.severity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if quota {
                item("余额/用量：当前会话已用", mode: "balance")
                item("今日花费模式（同样写已用，不加日角标）", mode: "cost")
                item("低于预警线", mode: "balance", low: true, value: 92)
                item("还没有额度数据", mode: "balance", value: .nan)
                item("只图标", mode: "icon")
                item("有风险：Codex 剩余不足 20%，写已用", mode: "balance", danger: true, risk: Self.quotaRisk(.codexPlan, remaining: 10.6))
                item("有风险：Claude", mode: "balance", risk: Self.quotaRisk(.claudePlan, remaining: 22))
            } else {
                item("余额/用量", mode: "balance")
                item("今日花费（日角标）", mode: "cost")
                item("只图标", mode: "icon")
                item("个位数 ¥6.27（同宽）", mode: "balance", value: 6.27)
                item("低于预警线", mode: "balance", low: true, value: 8.40)
                item("用量异常增加", mode: "balance", spike: true)
                item("只图标 · 用量异常增加（角标 !）", mode: "icon", spike: true, alertBadge: true)
                item("有风险：跟随最危险的平台，显示可用时长", mode: "balance", risk: Self.paygRisk(.deepseek, hours: 5.6))
                item("有风险（红）：硅基流动 40m", mode: "balance", danger: true, risk: Self.paygRisk(.siliconflow, hours: 2.0 / 3))
            }
        }
        .padding(10)
        .frame(width: quota ? 300 : 430, height: quota ? 286 : 286, alignment: .topLeading)
        .background(Color(red: 0.18, green: 0.36, blue: 0.60))
        .environment(\.colorScheme, .dark)
    }
}
