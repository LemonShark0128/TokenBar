import AppKit
import Combine
import SwiftUI

// ---------------------------------------------------------------- 右键菜单顶部信息卡

/// 悬停状态（菜单里的自定义视图拿不到系统高亮，自己跟踪）
@MainActor
final class HoverState: ObservableObject { @Published var on = false }

/// 右键菜单顶部的整块信息卡：每个平台一行（状态话同「今天」页），正在跑的任务挂在所属平台下，底部今日实付 + 更新时间。
/// 颜色跟着菜单本身的深浅走，过时套餐读数使用次要文字色。
struct MenuInfoCard: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var hover: HoverState
    /// 读屏「打开面板」用（鼠标点击由 MenuCardHost 处理）；离屏预览不传
    var onOpen: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    private var p: Palette { Palette.of(colorScheme == .dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let d = model.data {
                let now = model.fixedNow ?? Date()
                let rows = MenuCardRows.build(d, running: model.runningTasks, now: now,
                                              recentAgents: model.fixedNow == nil ? model.recentRunningAgents : nil,
                                              paygActive: model.menuBarPaygActive)
                // 每个平台一行（方案甲）：主平台排第一、名称加粗，和其他平台之间一条分隔线
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index == 1 { Divider() }
                    platformRow(row, now: now)
                }
                Divider()
                footer(d, now: now, shownNotes: Set(rows.filter(\.stateMultiline).compactMap(\.state)))
            } else {
                HStack(spacing: 8) {
                    Circle().fill(Accent.red).frame(width: 6, height: 6)
                    Text(model.error ?? (model.needsSetup ? A11yText.noPlatforms(allHidden: !model.hiddenIDs.isEmpty) : L("status.connecting", model.mainName))).font(.system(size: 12)).foregroundColor(.secondary)
                    Spacer()
                    LT("menu.panelLink").font(.system(size: 11.5)).foregroundColor(Accent.blue)
                }
                .mainA11y(model.error ?? (model.needsSetup ? A11yText.noPlatforms(allHidden: !model.hiddenIDs.isEmpty) : L("a11y.connecting", model.mainName)), onOpen: onOpen)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(hover.on ? 0.09 : 0.045)))
        .padding(.horizontal, 6).padding(.top, 2).padding(.bottom, 4)
        // 至少 300pt；菜单被更长的一行撑宽时跟着变宽，和菜单对齐
        .frame(minWidth: MenuCardHost.width, maxWidth: .infinity)
    }

    /// 状态话颜色：风险红 / 橙优先，其余提醒橙或灰（同今天卡）
    private func tint(_ row: MenuCardRow) -> Color {
        riskTint(row.severity, ok: row.warn ? p.warnText : .secondary, p: p)
    }

    /// 一行：图标 · 名称 · 状态话 · 读数；套餐下挂会话 / 本周细条；正在跑的任务挂在所属平台下
    private func platformRow(_ row: MenuCardRow, now: Date) -> some View {
        let alert = row.severity.map { $0 > 0 } ?? false || row.warn
        let updateHelp = row.dimmed ? StaleTime.help(row.lastUpdated, now: now) : nil
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let id = row.provider {
                    Image(nsImage: PlatformGlyph.image(id, size: 12, tint: nil)).renderingMode(.template)
                        .foregroundColor(alert ? tint(row) : Color(nsColor: PlatformColor.color(id)))
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1.5 }
                }
                Text(row.name).font(.system(size: 12, weight: row.isMain ? .semibold : .regular))
                    .foregroundColor(.primary).lineLimit(1).fixedSize()
                if let activity = row.activity {
                    RunningDot(activity: activity).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                }
                if let state = row.state, !row.stateMultiline {
                    AlertLine(glyph: row.glyph, iconSize: 11) {
                        Text(state).lineLimit(1).truncationMode(.tail)
                    }
                    .font(.system(size: 11)).foregroundColor(tint(row)).helpIfPresent(updateHelp)
                }
                Spacer(minLength: 6)
                // 有会话 / 本周细条时读数就在细条右边，这里不重复，把位置让给状态话
                if row.windows.isEmpty {
                    Text(row.value).font(.num(12, .semibold)).foregroundColor(.primary).opacity(row.dimmed && row.loginHint ? 0.55 : 1).lineLimit(1).fixedSize()
                }
            }
            if let state = row.state, row.stateMultiline {
                // 没有额度数据时的引导：允许折行，不截断
                AlertLine(glyph: row.glyph, iconSize: 11) {
                    Text(state).lineLimit(5).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11)).foregroundColor(tint(row)).helpIfPresent(updateHelp).padding(.leading, 18)
            }
            ForEach(row.windows) { w in
                HStack(spacing: 6) {
                    Text(w.title).font(.system(size: 10.5)).foregroundColor(p.sub)
                        .frame(width: 64, alignment: .leading).lineLimit(1).minimumScaleFactor(0.8)
                    PaceBar(remaining: w.remaining, pace: w.pace, tint: quotaTint(w.severity), track: p.track, height: 5)
                    Text(w.value).font(.num(10.5, .regular)).foregroundColor(.primary)
                        .frame(width: 56, alignment: .trailing).lineLimit(1).minimumScaleFactor(0.8)
                }
                .padding(.leading, 18)
            }
            ForEach(row.tasks, id: \.sessionKey) { t in
                let stale = RunningTaskText.isStale(t, now: now)
                HStack(spacing: 6) {
                    Text(t.project).font(.system(size: 11)).foregroundColor(.primary).lineLimit(1).truncationMode(.middle)
                    Text(RunningTaskText.costDetail(t)).font(.system(size: 10.5)).foregroundColor(p.sub).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(RunningTaskText.clock(t, now: now, short: true)).font(.num(10.5, .regular))
                        .foregroundColor(stale ? p.warnText : .secondary).lineLimit(1).fixedSize()
                }
                .padding(.leading, 18)
            }
        }
        .opacity(row.dimmed && !row.loginHint ? 0.55 : 1)
        .helpIfPresent(updateHelp)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.a11y)
    }

    /// 底部：今日实付（有按量付费花费时）· 更新时间 · 面板 ›
    private func footer(_ d: AppData, now: Date, shownNotes: Set<String>) -> some View {
        let f = model.freshness
        let lastUpdated = d.mainCardSide?.lastUpdated ?? d.balance.ageS.map { now.addingTimeInterval(-Double($0)) }
        // 新鲜度只在它就是平台行里已写出的引导时省略；离线 / 过时提示都要留着
        let showFresh = !shownNotes.contains(f.1) && f.1 != d.quota?.note
        return HStack(spacing: 6) {
            if let paid = MenuCardRows.paidLine(d) {
                Text(paid).font(.num(11, .regular)).foregroundColor(.secondary).lineLimit(1).minimumScaleFactor(0.85)
            }
            Spacer(minLength: 6)
            if showFresh {
                Circle().fill(f.0 == .ok ? Accent.green : (f.0 == .offline ? Accent.red : Accent.orange))
                    .frame(width: 6, height: 6).accessibilityHidden(true)
                Text(f.1).font(.num(11, .regular)).foregroundColor(.secondary).lineLimit(1).minimumScaleFactor(0.85)
                    .truncationMode(.tail).layoutPriority(1)   // 离线 / 过时提示比实付更要紧
                    .helpIfPresent(f.0 == .stale || f.0 == .offline ? StaleTime.help(lastUpdated, now: now) : nil)
            }
            LT("menu.panelLink").font(.system(size: 11.5)).foregroundColor(Accent.blue)
                .opacity(hover.on ? 1 : 0.75)
        }
        .mainA11y([MenuCardRows.paidLine(d), showFresh ? L("menu.dataBasisA11y", A11yText.speak(f.1)) : nil, L("menu.openPanel")]
                    .compactMap { $0 }.joined(separator: L("a11y.sep")),
                  onOpen: onOpen)
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
                      currency: String? = nil, danger: Bool = false, alertBadge: Bool = false,
                      risk: PlatformRisk? = nil) -> some View {
        let d = model.data
        // 与 StatusBarController.refresh 同一个函数生成文字；图标显示当前平台标志
        let exhausted = quota && value == nil && risk == nil ? model.menuBarQuotaSide?.menuQuota?.exhausted : nil
        let riskTitle = risk.flatMap { MenuBarText.riskTitle($0, mode: mode) }
        let amount = riskTitle ?? MenuBarText.title(mode: mode, isQuota: quota, balance: value ?? d?.balance.cny, today: value ?? d?.today.costCny,
                                       quotaUsed: value ?? model.menuBarQuotaSide?.menuQuota?.usedPercent, currency: currency,
                                       exhausted: exhausted)
        let quotaSeverity = MenuBarText.quotaSeverity(isQuota: quota,
            usedPercent: value ?? model.menuBarQuotaSide?.menuQuota?.usedPercent, risk: risk)
        let quotaColor: Color = quotaSeverity == .danger ? Color(nsColor: AlertColor.danger)
            : quotaSeverity == .warn ? Color(nsColor: AlertColor.warn) : .white
        let color: Color = exhausted != nil ? .white
            : quotaSeverity != nil ? quotaColor : danger ? Color(nsColor: AlertColor.danger) : (low || spike || riskTitle != nil) ? Color(nsColor: AlertColor.warn) : .white
        return HStack(spacing: 12) {
            HStack(spacing: 0) {
                Image(nsImage: PlatformGlyph.menuImage(risk?.id ?? (quota ? .codexPlan : .deepseek), tint: nil,
                                                      dayBadge: mode == "cost" && !quota, alertBadge: alertBadge))
                    .renderingMode(.template).foregroundColor(color)
                if !amount.isEmpty {
                    Text(amount).font(Font(kStatusFont)).foregroundColor(.white).padding(.leading, 4)   // 颜色只给图标
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
                // 用户 10-27：按量付费撑不过 12 小时也只写余额 / 今日花费，可用时长在悬停提示和面板里
                item("撑不过 12 小时：仍写余额", mode: "balance", risk: Self.paygRisk(.deepseek, hours: 5.6))
                item("撑不过 12 小时 · 今日花费模式：仍写今日花费", mode: "cost", risk: Self.paygRisk(.deepseek, hours: 2.0 / 3))
            }
        }
        .padding(10)
        .frame(width: quota ? 300 : 430, height: 286, alignment: .topLeading)
        .background(Color(red: 0.18, green: 0.36, blue: 0.60))
        .environment(\.colorScheme, .dark)
    }
}
