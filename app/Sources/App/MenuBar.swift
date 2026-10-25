import AppKit
import Combine
import SwiftUI
import UserNotifications

// ---------------------------------------------------------------- 状态栏控制器（左键面板 / 右键菜单）

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let model: UsageModel
    private let statusItem: NSStatusItem
    var statusButton: NSStatusBarButton? { statusItem.button }
    private let popover = NSPopover()
    private var subs = Set<AnyCancellable>()
    private let iconSize: CGFloat = 11
    private var lastMenuBarSig = ""
    /// 上一次画在菜单栏上的平台；换平台（轮流、切换）时才播过渡动画，数字刷新不播
    private var lastMenuBarPlatform: ProviderID?
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
        reminderTimer?.invalidate()
        reminderRefit?.cancel()
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        NotificationCenter.default.removeObserver(self)
    }

    /// 菜单栏：一个数字 + 平台标志，不轮播。
    /// 颜色交给系统：文字用 labelColor、图标用 template —— 实测按钮的外观跟随菜单栏本身（本机是 VibrantDark），
    /// 不受 App 主题影响，所以不必再写死白色（写死白色在浅色菜单栏上看不见）。
    /// 只有异常才上色：低于预警线 → 图标和数字变橙；花费飙升 → 加一个橙点；数据不新鲜 → 整体变灰。
    private func refresh() {
        guard let b = statusItem.button else { return }
        let sig = model.menuSignal
        let d = model.data
        // 数字取「菜单栏平台」（固定的那个，或自动跟随到的那个）；没有 store（离屏）时取主平台
        let mb = model.menuBarSide
        let cur = mb?.currency ?? d?.balance.currency
        let mbTank = mb != nil ? mb?.tank : d?.balance.cny
        // 主平台只有余额（没登录控制台）或离线时花费未知：不写 ¥0.00
        let mbToday = mb != nil ? mb?.todayCost : (d?.today.known == true ? d?.today.costCny : nil)
        let level = mb.map { model.fuelLevel(of: $0) } ?? model.fuelLevel
        let barName = mb?.name ?? model.mainName
        // 菜单栏平台是套餐平台：「余额/用量」「今日花费」两种模式都写当前会话（5 小时窗口）已用百分比，不加角标；
        // 按量付费的「今日花费」不写「今日」，靠图标右下角的「日」角标区分
        let quota = model.menuBarQuotaSide
        // 有任务在跑时，悬停提示末尾多一行「当前 N 个任务」（图标和读数不变）；轮流显示时再加一行「轮流显示：A、B」
        let rotation = model.usageStore?.menuBarRotation ?? []
        let running = (RunningTaskText.tooltipLine(count: model.runningTasks.count).map { "\n" + $0 } ?? "")
            + (rotation.count > 1 ? L("menu.rotating", rotation.map(ProviderRegistry.displayName).joined(separator: L("common.listSep"))) : "")
        let text = MenuBarText.title(mode: model.mbMode, isQuota: quota != nil, balance: mbTank, today: mbToday,
                                     quotaUsed: quota?.menuQuota?.usedPercent, currency: cur, exhausted: quota?.menuQuota?.exhausted)
        // 自动跟随到有风险的平台：数字换成可用时长（「5h36m」），红 / 橙按严重程度；只图标模式加「!」角标
        let risk = model.usageStore?.menuBarRisk
        let exhausted = quota?.menuQuota?.exhausted != nil
        let riskText = exhausted ? nil : risk.flatMap { MenuBarText.riskTitle($0, mode: model.mbMode) }
        let badge = MenuBarText.alertBadge(mode: model.mbMode, spike: sig.spike, risk: risk)
        let riskTint: NSColor? = (riskText != nil || badge) && risk?.atRisk == true
            ? (risk?.severity == .danger ? .systemRed : .systemOrange) : nil
        let quotaSeverity = MenuBarText.quotaSeverity(isQuota: quota != nil, usedPercent: quota?.menuQuota?.usedPercent,
                                                       risk: riskText != nil ? risk : nil)
        let quotaColor: NSColor? = quotaSeverity == .danger ? .systemRed : (quotaSeverity == .warn ? .systemOrange : nil)
        // 套餐只看显示窗口的剩余；按量付费沿用风险、低余额和异常的颜色。
        // 用完时恢复正常标志和文字（用户 10-19 选白，不选灰）。
        let tint: NSColor? = exhausted ? nil
            : quotaSeverity != nil ? quotaColor : (riskTint ?? (sig.low || sig.spike ? NSColor.systemOrange : nil))
        let shown = riskText ?? text
        // 风险读数优先显示风险平台，否则跟随菜单栏平台；未设置时保留油量表
        let platformID: ProviderID? = model.needsSetup ? nil
            : (riskText != nil ? risk?.id : nil)
                ?? mb.flatMap { ProviderID(rawValue: $0.id) } ?? model.mainState?.id
        let key = "\(model.mbMode)|\(shown)|\(sig)|\(Int(level * 100))|\(quota != nil)|\(badge)|\(String(describing: tint))|\(String(describing: platformID))|\(String(describing: quotaSeverity))"
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
                             .foregroundColor: quotaSeverity != nil ? (tint ?? .labelColor) : (riskText != nil ? (riskTint ?? .labelColor) : (sig.low ? NSColor.systemOrange : NSColor.labelColor))])
            b.attributedTitle = t
            b.appearsDisabled = sig.dim
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
                                                      currency: cur == "USD" ? .usd : .cny))
        b.toolTip = (d.map { dd in
            let c = dd.balance.currency
            // 只有一个平台时保持原文案（不写平台名、不写合计）
            let multi = !dd.sides.isEmpty
            let head = L("menu.tip.balance", multi ? model.mainName + L("menu.tip.nameSep") : "", fmtMoney(dd.balance.cny, c))
                + (dd.today.known ? L("menu.tip.today", fmtMoney(dd.today.costCny, c), sourceTagLabel(costSourceTag(dd.today.source)))
                    + L("menu.tip.month", fmtMoney(dd.month.costCny, c)) : L("menu.tip.source", sourceLabel(dd.today.source) ?? "—"))
            let total = (multi ? dd.totalTodayCny : nil).map { L("menu.tip.total", dd.totalIsApprox ? "≈" : "", fmtCNY($0)) } ?? ""
            return head + L("menu.tip.usage", cnCount(dd.today.tokens), model.freshness.1) + total
        } ?? (model.needsSetup ? L("a11y.noPlatforms") : L("status.connecting", model.mainName))) + running
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let right = NSApp.currentEvent?.type == .rightMouseUp
            || (NSApp.currentEvent?.modifierFlags.contains(.control) ?? false)
        if right { showMenu() } else { togglePanel() }
    }

    func togglePanel() {
        logLine("面板：\(popover.isShown ? "收起" : "打开")")
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
        let mb = item(L("set.menuBarShows"), nil)
        let mbSub = NSMenu()
        // 选项和设置里「菜单栏显示」「菜单栏平台」两个下拉用同一份（SettingsLayout），两边永远一致
        for (key, title) in SettingsLayout.menuBarModeOptions {
            let it = NSMenuItem(title: title, action: #selector(menuSetMBMode(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = key
            it.state = model.mbMode == key ? .on : .off
            mbSub.addItem(it)
        }
        mb.submenu = mbSub
        if model.usageStore != nil {
            // 已添加平台和当前选择的算法与设置页（SettingsView.ctx）相同
            let inp = model.accountsInput
            var states: [ProviderID: AccountState] = [:]
            for id in ProviderRegistry.all { states[id] = UsageModel.accountState(for: inp.platforms.first { $0.id == id }) }
            let added = SettingsLayout.added(states)
            // 「显示哪个平台」：和设置下拉同一份选项、同一个选中值（面板和菜单栏共用，用户 10-19）
            let selected = SettingsLayout.mainSelection(auto: inp.auto, main: inp.mainID, added: added)
            let pf = item(L("set.showWhich"), nil)
            let pfSub = NSMenu()
            for (key, title) in SettingsLayout.mainOptions(added: added) {
                let it = NSMenuItem(title: title, action: #selector(menuSetMain(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = key
                it.state = selected == key ? .on : .off
                pfSub.addItem(it)
            }
            pf.submenu = pfSub
        }
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
    @objc private func menuRefresh() { model.fetch() }
    @objc private func menuOpenRelease() {
        guard let r = model.availableUpdate else { return }
        logLine("右键菜单：打开新版本 \(r.version) 的下载页")
        NSWorkspace.shared.open(r.url)
    }
    @objc private func menuOpenPlatform() { NSWorkspace.shared.open(ProviderRegistry.usageURL(model.mainID)) }
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
