import Foundation

/// 轮流显示用的小工具（纯函数）：主平台「当前使用」轮流（MainSwitcher）用它们。
/// 用户 10-19：菜单栏不再单独选平台，永远和面板显示同一个（含轮流），所以这里只剩列表工具
enum MenuBarRotation {
    /// 任务最后活动在这么久以内算「在跑」
    static let runningWindow: TimeInterval = 600
    /// 各平台最近一次任务活动时间 → 10 分钟内在跑的平台
    static func running(_ lastActivity: [ProviderID: Date], now: Date) -> Set<ProviderID> {
        Set(lastActivity.filter { now.timeIntervalSince($0.value) <= runningWindow }.keys)
    }

    /// 列表变了：正在显示的还在就留着，否则从第一个开始
    static func keep(_ list: [ProviderID], current: ProviderID) -> ProviderID {
        list.contains(current) ? current : (list.first ?? current)
    }

    /// 轮到下一个（不在列表里时从第一个开始）
    static func next(_ list: [ProviderID], after current: ProviderID) -> ProviderID {
        guard let i = list.firstIndex(of: current) else { return list.first ?? current }
        return list[(i + 1) % list.count]
    }
}


/// 菜单栏的文字（纯函数；StatusBarController 和离屏预览共用）
enum MenuBarText {
    /// 套餐标志和数字只看所显示窗口的剩余；nil 表示按量付费，沿用原有着色规则。
    static func quotaSeverity(isQuota: Bool, usedPercent: Double?, risk: PlatformRisk?) -> RunwaySeverity? {
        if let risk, ProviderRegistry.meter(risk.id) == .quota, case .quota(let q) = risk.kind {
            return q.remainingPercent.isFinite ? QuotaLevel.severity(usedPercent: 100 - q.remainingPercent) : .ok
        }
        guard isQuota else { return nil }
        guard let usedPercent, usedPercent.isFinite else { return .ok }
        return QuotaLevel.severity(usedPercent: usedPercent)
    }

    /// mode：balance（余额/用量）/ cost（今日花费）/ icon（只图标）。
    /// 按量付费平台：余额 / 今日花费；套餐平台：余额/用量和今日花费两种模式都写当前会话已用。
    /// 用户 10-19 改为已用：100 - 向下取整的剩余，与风险读数同口径。
    static func title(mode: String, isQuota: Bool, balance: Double?, today: Double?, quotaUsed: Double?,
                      currency: String?, exhausted: QuotaExhausted? = nil) -> String {
        if mode == "icon" { return "" }
        if isQuota, let exhausted { return exhausted.menuBarText }     // 用完不挂「剩 0%」，写下次重置（用户 10-19）
        if isQuota {
            return L("menuText.used", quotaUsedPercent(remaining: quotaUsed.map { 100 - $0 }))
        }
        return menuBarAmount(mode == "cost" ? today : balance, currency: currency)
    }

    /// 自动跟随到有风险的平台时菜单栏的读数（图标换成平台标志）：按量付费写可用时长（「5h36m」）；
    /// 套餐写快用完的那个窗口已用多少（「已用 88%」，与「剩 N%」互补，时长放进悬停提示）。
    /// 只图标、低于预警线、已用完时为 nil（照常显示读数）
    static func riskTitle(_ r: PlatformRisk, mode: String) -> String? {
        guard mode != "icon", let h = r.hours, h > 0 else { return nil }
        switch r.kind {
        case .payg: return Runway.compactText(hours: h)
        case .quota(let q) where q.state == .runsOut:
            return L("menuText.used", quotaUsedPercent(remaining: q.remainingPercent))
        default: return nil
        }
    }

    /// 有风险时的悬停提示和读屏：「Claude 套餐 预计可用时间：40 分钟，下次重置：10:00」
    static func riskTooltip(_ r: PlatformRisk, name: String, now: Date, timeZone: TimeZone) -> String? {
        switch r.kind {
        case .belowThreshold: return L("menuText.belowLine", name)
        case .payg(let p):
            return L("menuText.timeLeft", name, p.hours < 1 ? L("common.underOneHour") : Runway.durationText(hours: p.hours))
        case .quota(let q):
            switch q.state {
            case .exhausted: return L("menuText.exhausted", name)
            case .runsOut:
                let reset = Runway.resetClock(q, now: now, timeZone: timeZone).map { L("alert.runout.reset", $0) } ?? ""
                return L("menuText.timeLeft", name, Runway.durationText(hours: q.hoursToEmpty ?? 0)) + reset
            default: return nil
            }
        default: return nil
        }
    }

    /// 只图标模式的「!」角标：用量异常或有风险时加（不只靠颜色）；低于预警线不加——表盘本身已经变空
    static func alertBadge(mode: String, spike: Bool, risk: PlatformRisk?) -> Bool {
        guard mode == "icon" else { return false }
        if spike { return true }
        guard let r = risk, r.atRisk else { return false }
        return r.kind != .belowThreshold
    }

    /// 套餐平台菜单栏读数：优先 5 小时窗口（当前会话），没有时用每周窗口，再取第一个窗口；没有窗口为 nil
    static func quotaReading(_ q: Quota?, now: Date, timeZone: TimeZone) -> AppData.MenuQuota? {
        guard let q, let w = q.displayWindow else { return nil }
        let reset = w.isReset(at: now) ? nil : QuotaText.resetText(w, now: now, timeZone: timeZone)
        var r = AppData.MenuQuota(usedPercent: w.effectiveUsed(at: now), window: windowName(w.kind), reset: reset,
                                  exhausted: QuotaText.exhaustion(q, now: now, timeZone: timeZone))
        // 读数使用显示窗口；最紧的是别的窗口时，把它的已用也写出来
        if let t = q.tightest(at: now), t != w {
            r.tighter = L("quota.windowUsedPct", windowName(t.kind), quotaUsedPercent(remaining: 100 - t.effectiveUsed(at: now)))
        }
        return r
    }

    /// 菜单栏读屏和提示里的窗口称呼：5 小时窗口说「当前会话」（与 Claude 原生一致）
    static func windowName(_ k: QuotaWindow.Kind) -> String {
        if case .session = k { return L("quota.currentSession") }
        return QuotaText.windowName(k)
    }

    /// 「Claude 套餐 当前会话已用 23%」；没有额度数据为「Claude 套餐 额度未知」
    static func quotaUsedText(provider: String, reading: AppData.MenuQuota?) -> String {
        guard let r = reading, r.usedPercent.isFinite else { return L("menuText.quotaUnknown", provider) }
        return L("menuText.providerWindowUsed", provider, r.window, quotaUsedPercent(remaining: 100 - r.usedPercent))
    }

    /// 菜单栏悬停提示：「Claude 套餐 当前会话已用 23% · 2 小时 13 分后重置」；
    /// 没有额度数据时带上平台给的说明（如「打开 Claude 桌面 App…」）
    static func quotaTooltip(provider: String, reading: AppData.MenuQuota?, note: String? = nil) -> String {
        ([quotaUsedText(provider: provider, reading: reading)] + [reading?.tighter, reading?.reset].compactMap { $0 }
            + (reading == nil ? [note].compactMap { $0 } : []))
            .joined(separator: " · ")
    }
}
