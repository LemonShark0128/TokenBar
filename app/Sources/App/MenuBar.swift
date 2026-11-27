import AppKit
import Combine
import SwiftUI

// ---------------------------------------------------------------- 状态栏控制器（左键面板 / 右键菜单）

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let model: UsageModel
    private let statusItem: NSStatusItem
    var statusButton: NSStatusBarButton? { statusItem.button }
    private let popover = NSPopover()
    private var subs = Set<AnyCancellable>()
    private var lastMenuBarSig = ""
    private var lastMenuBarShown: Set<ProviderID> = []
    private var appearanceObservation: NSKeyValueObservation?
    /// 上一次画在菜单栏上的平台；换平台（轮流、切换）时才播过渡动画，数字刷新不播
    private var lastMenuBarPlatform: ProviderID?
    private var lastSecondary: ProviderID?
    private var lastMainShown: ProviderID?
    /// 上次刷新时有任务在跑的平台：任务消失那一刻记下时间，停留 60 秒从这里起算
    private var lastLive: Set<ProviderID> = []
    private var activityHistory: [ProviderID: Date] = [:]
    private var secondaryRotationTimer: Timer?
    private var secondaryLingerTimer: Timer?
    private var secondaryLingerUntil: Date?
    private var outsideClickMonitor: Any?
    private var reminderClock = PanelReminderTimer()
    private var reminderTimer: Timer?
    private var reminderRefit: DispatchWorkItem?

    init(model: UsageModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: kPanelWidth, height: 820)
        // 面板内容只在打开时建（见 togglePanel），关掉就放掉：常驻的话整棵界面一直占着内存，
        // 而且面板关着也会跟着每次刷新重算
        popover.delegate = self

        model.onClosePanel = { [weak self] in self?.popover.performClose(nil) }
        model.onOpenPanel = { [weak self] in
            guard let self = self, !self.popover.isShown else { return }
            self.togglePanel()
        }
        model.onRefit = { [weak self] in self?.fitPanel() }

        if let b = statusItem.button {
            b.target = self
            b.action = #selector(clicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.imagePosition = .imageLeading
            b.font = kStatusFont
            appearanceObservation = b.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        refresh()
        // 数据一变就重画状态栏，保证「顶部实时」
        model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.refresh()
                self?.updatePanelReminders()
            }
        }.store(in: &subs)
    }

    isolated deinit {
        secondaryRotationTimer?.invalidate()
        secondaryLingerTimer?.invalidate()
        reminderTimer?.invalidate()
        reminderRefit?.cancel()
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        NotificationCenter.default.removeObserver(self)
    }

    /// 菜单栏：一个数字 + 平台标志，不轮播。
    /// 颜色交给系统：文字用 labelColor、图标用 template —— 实测按钮的外观跟随菜单栏本身（本机是 VibrantDark），
    /// 不受 App 主题影响，所以不必再写死白色（写死白色在浅色菜单栏上看不见）。
    /// 只有异常才上色，而且只给图标（用户 10-27：数字一律正常颜色）：低于预警线 / 花费飙升 → 图标变橙；
    /// 套餐快用完 → 图标橙 / 红；数据不新鲜 → 整体变灰。
    private func refresh() {
        guard let b = statusItem.button else { return }
        if model.mbStyle != "classic" {
            refreshStyle(b)
            return
        }
        secondaryRotationTimer?.invalidate(); secondaryRotationTimer = nil
        secondaryLingerTimer?.invalidate(); secondaryLingerTimer = nil
        secondaryLingerUntil = nil; activityHistory = [:]; lastSecondary = nil; lastMainShown = nil; lastLive = []
        b.layer?.removeAnimation(forKey: "menuBarSecondarySwitch")
        let sig = model.menuSignal
        let d = model.data
        // 数字取「菜单栏平台」（固定的那个，或自动跟随到的那个）；没有 store（离屏）时取主平台
        let mb = model.menuBarSide
        syncMenuBarShown(model.needsSetup ? [] : [mb.flatMap { ProviderID(rawValue: $0.id) } ?? model.mainID])
        let cur = mb?.currency ?? d?.balance.currency
        let mbTank = mb != nil ? mb?.tank : d?.balance.cny
        // 主平台只有余额（没登录控制台）或离线时花费未知：不写 ¥0.00
        let mbToday = mb != nil ? mb?.todayCost : (d?.today.known == true ? d?.today.costCny : nil)
        let level = mb.map { model.fuelLevel(of: $0) } ?? model.fuelLevel
        let barName = mb?.name ?? model.mainName
        // 菜单栏平台是套餐平台：「余额/用量」「今日花费」两种模式都写当前会话（5 小时窗口）已用百分比，不加角标；
        // 按量付费的「今日花费」不写「今日」，靠图标右下角的「日」角标区分
        let quota = model.menuBarQuotaSide
        let loginHint = quota.flatMap { MenuBarCells.quotaLoginHint(for: $0) }
        // 有任务在跑时，悬停提示末尾多一行「当前 N 个任务」（图标和读数不变）；轮流显示时再加一行「轮流显示：A、B」
        let rotation = model.usageStore?.menuBarRotation ?? []
        let running = (RunningTaskText.tooltipLine(count: model.runningTasks.count).map { "\n" + $0 } ?? "")
            + (rotation.count > 1 ? L("menu.rotating", rotation.map(ProviderRegistry.displayName).joined(separator: L("common.listSep"))) : "")
        let text = MenuBarText.title(mode: model.mbMode, isQuota: quota != nil, balance: mbTank, today: mbToday,
                                     quotaUsed: quota?.menuQuota?.usedPercent, currency: cur, exhausted: quota?.menuQuota?.exhausted)
        // 有风险时：套餐平台写已用（红 / 橙按严重程度）；按量付费照常写余额 / 今日花费（用户 10-27：时长会一直跳），只图标模式加「!」角标
        let risk = model.usageStore?.menuBarRisk
        let exhausted = quota?.menuQuota?.exhausted != nil
        let riskText = exhausted ? nil : risk.flatMap { MenuBarText.riskTitle($0, mode: model.mbMode) }
        let badge = MenuBarText.alertBadge(mode: model.mbMode, spike: sig.spike, risk: risk)
        let riskTint: NSColor? = (riskText != nil || badge) && risk?.atRisk == true
            ? (risk?.severity == .danger ? AlertColor.danger : AlertColor.warn) : nil
        let quotaSeverity = MenuBarText.quotaSeverity(isQuota: quota != nil, usedPercent: quota?.menuQuota?.usedPercent,
                                                       risk: riskText != nil ? risk : nil)
        let quotaColor: NSColor? = quotaSeverity == .danger ? AlertColor.danger : (quotaSeverity == .warn ? AlertColor.warn : nil)
        // 套餐只看显示窗口的剩余；按量付费沿用风险、低余额和异常的颜色。
        // 用完时恢复正常标志和文字（用户 10-19 选白，不选灰）。
        let tint: NSColor? = loginHint != nil || exhausted ? nil
            : quotaSeverity != nil ? quotaColor : (riskTint ?? (sig.low || sig.spike ? AlertColor.warn : nil))
        let shown = loginHint != nil ? L("menu.needsLogin") : riskText ?? BalanceEstimatePresentation.menuTitle(text, mode: model.mbMode, source: d?.today.source, hasAmount: mbToday != nil && quota == nil)
        // 风险读数优先显示风险平台，否则跟随菜单栏平台；未设置时保留油量表
        let platformID: ProviderID? = model.needsSetup ? nil
            : (riskText != nil ? risk?.id : nil)
                ?? mb.flatMap { ProviderID(rawValue: $0.id) } ?? model.mainState?.id
        let key = "classic|\(b.effectiveAppearance.name.rawValue)|\(model.mbMode)|\(shown)|\(sig)|\(Int(level * 100))|\(quota != nil)|\(badge)|\(String(describing: tint))|\(String(describing: platformID))|\(String(describing: quotaSeverity))"
        if key != lastMenuBarSig {
            lastMenuBarSig = key
            // 用户 10-19：轮流时不要一下跳到新平台。新平台从下往上推入（减弱动态效果时只淡入淡出）
            if let prev = lastMenuBarPlatform, let now = platformID, prev != now {
                b.wantsLayer = true
                let t = CATransition()
                t.duration = 0.35
                t.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    t.type = .fade
                } else {
                    t.type = .push
                    t.subtype = .fromBottom
                }
                b.layer?.add(t, forKey: "menuBarPlatformSwitch")
            }
            if let platformID { lastMenuBarPlatform = platformID }
            // 飙升也让图标变橙（不再在数字后面挂橙点 —— 那个点要占位，用户嫌菜单栏太长）
            let dayBadge = model.mbMode == "cost" && quota == nil && riskText == nil
            b.image = platformID.map { PlatformGlyph.menuImage($0, tint: tint, dayBadge: dayBadge, alertBadge: badge) }
                ?? GaugeIcon.menuImage(value: level, template: tint == nil,
                                       tint: tint, dayBadge: dayBadge,
                                       alertBadge: badge)
            let t = NSMutableAttributedString(
                string: shown,                        // 不加前导空格：图文之间系统本来就留间距
                attributes: [.font: kStatusFont,
                             // 用户 10-27：所有平台统一，橙 / 红只给图标，数字一律正常颜色
                             .foregroundColor: NSColor.labelColor])
            b.attributedTitle = t
            b.appearsDisabled = sig.dim || loginHint != nil
        }
        if let loginHint {
            b.setAccessibilityLabel(A11yText.menuBarLabel)
            b.setAccessibilityValue(barName + " " + loginHint)
            b.toolTip = barName + " " + loginHint + running
            return
        }
        if let r = risk, let tip = MenuBarText.riskTooltip(r, name: barName, now: Date(), timeZone: .autoupdatingCurrent) {
            b.setAccessibilityLabel(A11yText.menuBarLabel)
            b.setAccessibilityValue(A11yText.speak(tip))
            b.toolTip = tip + running
            return
        }
        if let q = quota {
            b.setAccessibilityLabel(A11yText.menuBarLabel)
            b.setAccessibilityValue(A11yText.menuBarQuotaValue(provider: q.name, reading: q.menuQuota, low: sig.low, dim: sig.dim))
            b.toolTip = MenuBarText.quotaTooltip(provider: q.name, reading: q.menuQuota, note: q.quotaNote) + running
            return
        }
        b.setAccessibilityLabel(A11yText.menuBarLabel)
        b.setAccessibilityValue(A11yText.menuBarValue(provider: barName, needsSetup: model.needsSetup,
                                                      balanceCny: mbTank, runwayDays: mb == nil ? d?.burn?.runwayDays : nil,
                                                      todayCny: mbToday, showsTodayCost: model.mbMode == "cost",
                                                      low: sig.low, spike: sig.spike, dim: sig.dim,
                                                      currency: cur == "USD" ? .usd : .cny, allHidden: !model.hiddenIDs.isEmpty))
        b.toolTip = (d.map { dd in
            let c = dd.balance.currency
            // 只有一个平台时保持原文案（不写平台名、不写合计）
            let multi = !dd.sides.isEmpty
            let head = L(dd.mainCardSide?.tankIsKeyLimit == true ? "menu.tip.keyLimit" : "menu.tip.balance", multi ? model.mainName + L("menu.tip.nameSep") : "", fmtMoney(dd.balance.cny, c))
                + (dd.today.known ? L("menu.tip.today", fmtMoney(dd.today.costCny, c), sourceTagLabel(costSourceTag(dd.today.source)))
                    + L("menu.tip.month", fmtMoney(dd.month.costCny, c)) : L("menu.tip.source", sourceLabel(dd.today.source) ?? "—"))
            let total = (multi ? dd.totalTodayCny : nil).map { L("menu.tip.total", dd.totalIsApprox ? "≈" : "", fmtCNY($0)) } ?? ""
            return head + BalanceEstimatePresentation.usageTooltip(source: dd.today.source, tokens: dd.today.tokens, freshness: model.freshness.1) + total
        } ?? (model.needsSetup ? A11yText.noPlatforms(allHidden: !model.hiddenIDs.isEmpty) : L("status.connecting", model.mainName))) + running
    }

    /// 用户 2026-11-13 反馈「刷新慢」：只在显示集合变化时同步，避免重画数字反复排期。
    private func syncMenuBarShown(_ ids: Set<ProviderID>) {
        guard ids != lastMenuBarShown, let store = model.usageStore else { return }
        lastMenuBarShown = ids
        Task { @MainActor in await store.setMenuBarShown(ids) }
    }

    private func refreshStyle(_ b: NSStatusBarButton) {
        let now = model.fixedNow ?? Date()
        let main = model.needsSetup ? nil : model.mainID
        let stale = Set((model.usageStore?.platforms ?? []).filter { MenuBarCells.isStale($0, now: now) }.map(\.id))
        // 主平台首次取数失败时 model.data 为 nil，仍显示其他已添加平台。
        let data = model.data ?? model.mainState.flatMap { state -> AppData? in
            guard state.status.isShown else { return nil }
            return AppDataMapping.appData(main: state,
                others: model.usageStore?.platforms.filter { $0.id != state.id } ?? [],
                now: now, timeZone: .autoupdatingCurrent)
        }
        let cells = data.map {
            MenuBarCells.cells($0, main: main,
                               lowAlerts: ProviderSettings.load(.standard).lowAlerts.mapValues(AppDataMapping.double),
                               staleIDs: stale, now: now)
        } ?? []
        let mode = SettingsLayout.menuBarSlotMode(model.mbSlots)
        // 与 MenuBarSelection 同口径：停了 5 分钟以上的任务不算在跑，从它变成「已停」时起停留 60 秒
        let liveNow = Set(model.runningTasks.filter { !RunningTaskText.isStale($0, now: now) }.map(\.provider))
        for id in lastLive.subtracting(liveNow) { activityHistory[id] = max(activityHistory[id] ?? now, now) }
        lastLive = liveNow
        let history = activityHistory.merging(model.menuBarLastActivity, uniquingKeysWith: { max($0, $1) })
        // 用户 2026-11-13：跳过非平台卡片；选择器再按当前 cells 排除隐藏或未添加平台。
        let order = model.resolvedTodayLayout.compactMap { ProviderID(rawValue: $0.id) }
        let result = MenuBarSelection.select(cells: cells, order: order, paygActive: model.menuBarPaygActive,
            tasks: model.runningTasks, showRunning: model.mbShowRunning, mode: mode,
            lastActivity: history, now: now)
        let slots = result.slots
        let previous = [lastMainShown, lastSecondary].compactMap { $0 }
        let current = [slots.main?.id, slots.secondary?.id].compactMap { $0 }
        syncMenuBarShown(Set(current))
        // 用户 2026-11-13：整套组合变化才切换；任一平台退出组合时沿用淡出。
        let leaving = previous.contains { !current.contains($0) }
        activityHistory = result.lastActivity
        let mainDot = slots.main.map { MenuBarSecondary.dot(for: $0.id, tasks: model.runningTasks, now: now) } ?? .none
        let secondaryDot = slots.secondary.map { MenuBarSecondary.dot(for: $0.id, tasks: model.runningTasks, now: now) } ?? .none
        updateSecondaryTimers(rotate: result.shouldRotate, lingerUntil: result.expiresAt, now: now)
        // 11/6 起不轮流；11/13 用户反馈左侧空太大，宽度交给图标按 slots 实际内容计算。
        let key = "bars|\(b.effectiveAppearance.name.rawValue)|\(slots)|\(mainDot)|\(secondaryDot)|\(L10n.lang)"
        if key != lastMenuBarSig {
            lastMenuBarSig = key
            lastMenuBarPlatform = nil
            b.layer?.removeAnimation(forKey: "menuBarPlatformSwitch")
            if MenuBarSecondary.shouldAnimate(from: previous, to: current) {
                b.wantsLayer = true
                let transition = CATransition()
                transition.duration = leaving ? 0.8 : 0.35
                transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                if leaving || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    transition.type = .fade
                } else {
                    transition.type = .push
                    transition.subtype = .fromBottom
                }
                b.layer?.add(transition, forKey: "menuBarSecondarySwitch")
            }
            lastSecondary = slots.secondary?.id
            lastMainShown = slots.main?.id
            b.appearsDisabled = false
            b.image = slots.main == nil ? GaugeIcon.menuImage(value: 0, template: true, dayBadge: false)
                : MenuBarStyles.image(slots, appearance: b.effectiveAppearance, mainDot: mainDot, secondaryDot: secondaryDot)
            b.attributedTitle = NSAttributedString(string: "")
        }
        let tip = (cells.isEmpty ? A11yText.noPlatforms(allHidden: model.needsSetup && !model.hiddenIDs.isEmpty) : MenuBarCells.tooltip(cells, now: now))
            + (RunningTaskText.tooltipLine(count: model.runningTasks.count).map { "\n" + $0 } ?? "")
        b.toolTip = tip
        b.setAccessibilityLabel(A11yText.menuBarLabel)
        b.setAccessibilityValue(A11yText.speak(tip))
    }

    /// 只重画菜单栏，不触发取数；固定预览时间不启动计时器。
    private func updateSecondaryTimers(rotate: Bool, lingerUntil: Date?, now: Date) {
        if rotate && model.fixedNow == nil {
            if secondaryRotationTimer == nil {
                let timer = Timer(fire: MenuBarSecondary.nextRotation(after: now), interval: MenuBarSecondary.rotate, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.refresh() }
                }
                secondaryRotationTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        } else {
            secondaryRotationTimer?.invalidate(); secondaryRotationTimer = nil
        }
        let deadline = model.fixedNow == nil ? lingerUntil : nil
        if deadline != secondaryLingerUntil {
            secondaryLingerTimer?.invalidate(); secondaryLingerTimer = nil
            secondaryLingerUntil = deadline
            if let deadline {
                let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.refresh() }
                }
                secondaryLingerTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let right = NSApp.currentEvent?.type == .rightMouseUp
            || (NSApp.currentEvent?.modifierFlags.contains(.control) ?? false)
        if right { showMenu() } else { togglePanel() }
    }

    func togglePanel() {
        // 收起统一由 popoverDidClose 记「面板：已收起」
        if !popover.isShown { logLine("面板：打开") }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let b = statusItem.button else { return }
        model.fetch()
        // 先取切换提示再量高度，提示行算进面板高度；不靠 SwiftUI onAppear（popover 复用同一视图，不保证每次触发）
        model.panelAppeared()
        if popover.contentViewController == nil {
            popover.contentViewController = NSHostingController(rootView: RootView(model: model))
        }
        fitPanel()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        if popover.isShown {
            model.panelShown = true
            installPanelDismissalObservers()
            // 只有 show 成功才开始计时；离屏量高度和渲染预览不会走到这里。
            updatePanelReminders()
            // 定时器挂在主 RunLoop 上，但回调被声明成 @Sendable：用 Task { @MainActor } 让编译器检查；
            // 晚一拍执行时面板可能已经关了（定时器已停），那就不再更新
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in if self?.reminderTimer != nil { self?.updatePanelReminders() } }
            }
            timer.tolerance = 0.05
            reminderTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        // 被系统自动收起（transient：点别处、Esc）时其他地方不写日志，这里统一记一笔
        logLine("面板：已收起")
        removePanelDismissalObservers()
        reminderTimer?.invalidate()
        reminderTimer = nil
        reminderRefit?.cancel()
        reminderRefit = nil
        reminderClock.update(visible: false, keys: [], now: ProcessInfo.processInfo.systemUptime)
        model.panelDisappeared()
        // 下一轮再放掉面板内容（不在关闭回调里当场拆）；这期间又打开了就不放
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.popover.isShown else { return }
            self.popover.contentViewController = nil
        }
    }

    /// 用单调时钟分别跟踪提醒身份；普通数据刷新不会延长同一条提醒。
    private func updatePanelReminders() {
        let now = ProcessInfo.processInfo.systemUptime
        let banner = model.visibleBanner
        let bannerKey = banner.map { "风险:\($0.id):\($0.key)" }
        let notice = model.switchNotice
        let noticeKey = notice.map { "切换:\(model.switchNoticeGeneration):\($0)" }
        reminderClock.update(visible: popover.isShown && !kRendering,
                             keys: Set([bannerKey, noticeKey].compactMap { $0 }), now: now)
        let expired = reminderClock.takeExpired(now: now)
        guard !expired.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.5)) {
            if let key = bannerKey, expired.contains(key), let banner {
                logLine("面板：提醒 3 秒后自动收起：\(banner.text)")
                // 复用手动关闭的持久化规则；淡出期间先保留弹窗高度。
                model.dismissBanner(refit: false)
            }
            if let key = noticeKey, expired.contains(key), let notice {
                logLine("面板：提醒 3 秒后自动收起：\(notice)")
                model.switchNotice = nil
            }
        }
        reminderRefit?.cancel()
        let refit = DispatchWorkItem { [weak self] in
            guard let self, self.popover.isShown else { return }
            self.fitPanel()
        }
        reminderRefit = refit
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: refit)
    }

    private func installPanelDismissalObservers() {
        // 重复打开也只保留一组监听；全局监听不接收本 App（包括菜单栏图标）的点击。
        removePanelDismissalObservers()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            // AppKit 保证事件监听回调在主线程，同步关闭，避免旧事件延迟关闭新面板。
            self?.closePanelFromOutside()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationDidResignActive(_:)),
            name: NSApplication.didResignActiveNotification, object: NSApp
        )
    }

    private func removePanelDismissalObservers() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        NotificationCenter.default.removeObserver(
            self, name: NSApplication.didResignActiveNotification, object: NSApp
        )
    }

    @objc private func applicationDidResignActive(_ notification: Notification) {
        // AppKit 的前台状态通知在主线程发出，不额外监听本 App 内的窗口点击。
        closePanelFromOutside()
    }

    private func closePanelFromOutside() {
        guard popover.isShown else { return }
        logLine("面板：点外面收起")
        popover.performClose(nil)
    }

    /// 面板按内容定高（超过屏幕才滚动），去掉底部大片空白
    func fitPanel() {
        let natural = Fit.height(PanelView(model: model, p: Palette.of(model.dark)), width: kPanelWidth)
        let h = min(natural, Fit.maxHeight - 10)
        // 数据刷新时也会调到这里：高度没变就不动弹窗
        if model.panelHeight != h { model.panelHeight = h }
        if popover.contentSize != NSSize(width: kPanelWidth, height: h) { popover.contentSize = NSSize(width: kPanelWidth, height: h) }
    }

    /// 右键菜单：顶部先给答案（主平台余额/今日/本月/口径，下面每个辅助平台一行），异常时多一行橙色提示，下面只留常用操作。
    /// 预警线、轮播之类的配置都收进设置窗，菜单里不再嵌套三层。
    private func showMenu() {
        popover.performClose(nil)
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector?, key: String = "", attr: NSAttributedString? = nil) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
            it.target = self
            if let a = attr { it.attributedTitle = a }
            menu.addItem(it)
            return it
        }
        // 顶部整块信息卡（原来是 4 行各自高亮的菜单项，看着像 4 个按钮，其实都只是打开面板）
        let card = NSMenuItem()
        card.view = MenuCardHost(model: model) { [weak self] in self?.menuOpenPanel() }
        menu.addItem(card)
        menu.addItem(.separator())
        if let r = model.availableUpdate { _ = item(UpdateCheck.menuTitle(r), #selector(menuOpenRelease)) }
        _ = item(L("panel.refreshNow"), #selector(menuRefresh), key: "r")
        _ = item(L("menu.openUsagePage", model.mainName), #selector(menuOpenPlatform))
        menu.addItem(.separator())
        // 「菜单栏」一个子菜单分组放：显示哪个平台 / 正在跑的平台 / 样式（经典样式再加「菜单栏显示」）——用户 11/5 选方案甲
        let bar = item(L("menu.menuBar"), nil)
        let sub = NSMenu()
        sub.autoenablesItems = false
        func option(_ title: String, _ action: Selector, _ key: String, on: Bool) {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
            it.target = self
            it.representedObject = key
            it.state = on ? .on : .off
            sub.addItem(it)
        }
        if model.usageStore != nil {
            // 已添加平台和当前选择的算法与设置页（SettingsView.ctx）相同；选项和设置下拉同一份（用户 10-19）
            let inp = model.accountsInput
            let added = SettingsLayout.shown(UsageModel.accountStates(inp).states)   // 隐藏的平台不在选项里
            let selected = SettingsLayout.mainSelection(auto: inp.auto, main: inp.mainID, added: added)
            sub.addItem(.sectionHeader(title: L("set.showWhich")))
            for (key, title) in SettingsLayout.mainOptions(added: added) {
                option(title, #selector(menuSetMain(_:)), key, on: selected == key)
            }
            sub.addItem(.separator())
        }
        // 正在跑的平台：不显示 / 替换 / 并排三选一（= 原来的「显示正在跑的平台」勾选 + 替换 / 并排）
        sub.addItem(.sectionHeader(title: L("mb.slots")))
        let slot = SettingsLayout.menuBarSlotMode(model.mbSlots).rawValue
        option(L("mb.running.off"), #selector(menuSetRunning(_:)), "off", on: !model.mbShowRunning)
        for (key, title) in SettingsLayout.menuBarSlotOptions {
            option(title, #selector(menuSetRunning(_:)), key, on: model.mbShowRunning && slot == key)
        }
        sub.addItem(.separator())
        sub.addItem(.sectionHeader(title: L("mb.styleHeader")))
        for (key, title) in SettingsLayout.menuBarStyleOptions {
            option(title, #selector(menuSetMBStyle(_:)), key, on: model.mbStyle == key)
        }
        if model.mbStyle == "classic" {
            // 选项和设置里「菜单栏显示」下拉用同一份（SettingsLayout），两边永远一致
            sub.addItem(.separator())
            sub.addItem(.sectionHeader(title: L("set.menuBarShows")))
            for (key, title) in SettingsLayout.menuBarModeOptions {
                option(title, #selector(menuSetMBMode(_:)), key, on: model.mbMode == key)
            }
        }
        bar.submenu = sub
        _ = item(L("menu.settings"), #selector(menuSettings), key: ",")
        menu.addItem(.separator())
        _ = item(L("menu.quit", AppName.display), #selector(menuQuit), key: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuOpenPanel() {
        logLine("右键菜单：点了信息行 → 打开面板")
        DispatchQueue.main.async { self.model.onOpenPanel?() }
    }
    /// 调试：走和右键菜单信息行完全相同的路径
    func debugMenuOpenPanel() { menuOpenPanel() }
    @objc private func menuRefresh() { model.fetch(resetSlowdown: true) }
    @objc private func menuOpenRelease() {
        guard let r = model.availableUpdate else { return }
        logLine("右键菜单：打开新版本 \(r.version) 的下载页")
        NSWorkspace.shared.open(r.url)
    }
    @objc private func menuOpenPlatform() { NSWorkspace.shared.open(ProviderRegistry.usageURL(model.mainID)) }
    @objc private func menuSetMBStyle(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        model.mbStyle = key
    }
    @objc private func menuSetRunning(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        if key == "off" { model.mbShowRunning = false; return }
        model.mbShowRunning = true
        model.mbSlots = key
    }
    @objc private func menuSetMBMode(_ sender: NSMenuItem) {
        guard let k = sender.representedObject as? String else { return }
        model.mbMode = k
        logLine("右键菜单：菜单栏显示 → \(k)")
    }
    @objc private func menuSetMain(_ sender: NSMenuItem) {
        guard let k = sender.representedObject as? String else { return }
        model.chooseMain(k)
        logLine("右键菜单：显示哪个平台 → \(k)")
    }
    @objc private func menuSettings() { DispatchQueue.main.async { self.model.openSettings() } }
    @objc private func menuQuit() { model.quitForReal() }
}
