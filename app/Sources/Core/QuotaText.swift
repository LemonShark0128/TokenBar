import Foundation

/// 套餐额度的文案：窗口名、重置时间、最近使用。涉及钟点的都传 now 和 timeZone，测试可固定
enum QuotaText {
    static func windowName(_ k: QuotaWindow.Kind) -> String {
        switch k {
        case .session: return L("quota.window.session")
        case .weekly: return L("quota.window.weekly")
        case .weeklyModel(let m): return L("quota.window.weeklyModel", m)
        }
    }

    /// 额度用完提示里的窗口称呼（「5 小时额度」「本周额度」）
    private static func quotaLabel(_ k: QuotaWindow.Kind) -> String {
        switch k {
        case .session: return L("quota.label.session")
        case .weekly: return L("quota.label.weekly")
        case .weeklyModel(let m): return L("quota.label.weeklyModel", m)
        }
    }

    /// 重置时间：verb 是「重置」（窗口重置）或「恢复」（用完后恢复）
    private enum Verb: String { case reset, restore }

    private static func when(_ at: Date, now: Date, timeZone: TimeZone, verb: Verb) -> String {
        let v = verb.rawValue
        let secs = at.timeIntervalSince(now)
        if secs <= 0 { return L("quota.\(v).done") }
        if secs < 86400 {
            let mins = max(1, Int(secs / 60))
            if mins < 60 { return L("quota.\(v).inMin", mins) }
            return mins % 60 == 0 ? L("quota.\(v).inHours", mins / 60) : L("quota.\(v).inHoursMin", mins / 60, mins % 60)
        }
        return L("quota.\(v).at", clock(at, timeZone: timeZone))
    }

    /// 「周四 08:00」（英文「Thu 08:00」），星期用固定的表，不依赖系统的日期格式
    private static func clock(_ at: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.weekday, .hour, .minute], from: at)
        return String(format: "%@ %02d:%02d", L("weekday.\((c.weekday ?? 1) - 1)"), c.hour ?? 0, c.minute ?? 0)
    }

    static func resetText(_ at: Date, now: Date, timeZone: TimeZone) -> String {
        when(at, now: now, timeZone: timeZone, verb: .reset)
    }

    /// 窄处用：不到 24 小时写「2:13 后重置」
    static func resetCompact(_ at: Date, now: Date, timeZone: TimeZone) -> String {
        let secs = at.timeIntervalSince(now)
        guard secs > 0, secs < 86400 else { return resetText(at, now: now, timeZone: timeZone) }
        let mins = max(1, Int(secs / 60))
        return L("quota.reset.inCompact", "\(mins / 60):\(String(format: "%02d", mins % 60))")
    }

    /// 按窗口写重置时间：推算的写「约 2 小时 13 分后重置（推算）」；marker = false 时不加「（推算）」
    /// （面板窗口列表一行放不下，同一屏的标题行已经写了）。没有重置时间为 nil
    static func resetText(_ w: QuotaWindow, now: Date, timeZone: TimeZone, marker: Bool = true) -> String? {
        guard let at = w.resetsAt else { return nil }
        let t = resetText(at, now: now, timeZone: timeZone)
        return w.resetIsEstimated && at > now ? L("quota.approx", t) + (marker ? L("quota.estMarker") : "") : t
    }

    /// 窄处用的按窗口版本：推算的只加「约」（放不下「（推算）」）
    static func resetCompact(_ w: QuotaWindow, now: Date, timeZone: TimeZone) -> String? {
        guard let at = w.resetsAt else { return nil }
        let t = resetCompact(at, now: now, timeZone: timeZone)
        return w.resetIsEstimated && at > now ? L("quota.approx", t) : t
    }

    /// 剩余向下取整为 0（已用读数为 100%）就算用完
    static func isExhausted(remaining: Double?) -> Bool {
        guard let r = remaining, r.isFinite else { return false }
        return r < 1
    }

    /// 重置时刻：当天「08:00」，跨天「10/16 08:00」，推算的前面加「约 」；没有或已过为 nil
    static func resetClock(_ at: Date?, estimated: Bool, now: Date, timeZone: TimeZone) -> String? {
        guard let at, at > now else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.month, .day, .hour, .minute], from: at)
        let date = cal.isDate(at, inSameDayAs: now) ? "" : "\(c.month ?? 1)/\(c.day ?? 1) "
        return (estimated ? L("quota.approxPrefix") : "") + date + String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// 显示的窗口用完时：用完的窗口都恢复才能再用，取其中最晚的重置时刻；没用完为 nil
    static func exhaustion(_ q: Quota?, now: Date, timeZone: TimeZone) -> QuotaExhausted? {
        guard let q, isExhausted(remaining: q.displayRemainingPercent(at: now)) else { return nil }
        let done = q.windows.filter { isExhausted(remaining: 100 - $0.effectiveUsed(at: now)) }
        let last = done.filter { $0.resetsAt != nil }.max { $0.resetsAt! < $1.resetsAt! }
        return QuotaExhausted(clock: last.flatMap { resetClock($0.resetsAt, estimated: $0.resetIsEstimated, now: now, timeZone: timeZone) })
    }

    /// 按窗口的「额度已用完」：推算的恢复时间写「约 … 恢复（推算）」
    static func exhausted(name: String, window w: QuotaWindow, now: Date, timeZone: TimeZone) -> String {
        guard w.resetIsEstimated, let at = w.resetsAt, at > now else {
            return exhausted(name: name, window: w.kind, resetsAt: w.resetsAt, now: now, timeZone: timeZone)
        }
        let back = L("quota.approx", when(at, now: now, timeZone: timeZone, verb: .restore)) + L("quota.estMarker")
        return L("quota.exhaustedUntil", name, quotaLabel(w.kind), back)
    }

    /// 套餐名：plan_type「plus」→「Plus 套餐」；没有套餐名（Claude）为 nil
    static func planName(_ raw: String?) -> String? {
        guard let r = raw?.trimmingCharacters(in: .whitespaces), let first = r.first else { return nil }
        return L("quota.planName", first.uppercased() + r.dropFirst())
    }

    static func lastUsed(_ observedAt: Date, now: Date) -> String {
        let short = lastUsedShort(observedAt, now: now)
        return now.timeIntervalSince(observedAt) < 60 ? short : L("quota.lastUsed", short)
    }

    /// 短写（标题栏用）：「刚刚」「12 分钟前」「3 小时前」「2 天前」
    static func lastUsedShort(_ observedAt: Date, now: Date) -> String {
        let secs = now.timeIntervalSince(observedAt)
        if secs < 60 { return L("quota.justNow") }
        let mins = Int(secs / 60)
        if mins < 60 { return L("status.minAgo", mins) }
        if mins < 1440 { return L("quota.hoursAgo", mins / 60) }
        return L("quota.daysAgo", mins / 1440)
    }

    /// 如「Codex 套餐 本周额度已用完，周四 08:00 恢复」；不知道重置时间时只说已用完
    static func exhausted(name: String, window: QuotaWindow.Kind, resetsAt: Date?, now: Date, timeZone: TimeZone) -> String {
        guard let at = resetsAt else { return L("quota.exhausted", name, quotaLabel(window)) }
        return L("quota.exhaustedUntil", name, quotaLabel(window), when(at, now: now, timeZone: timeZone, verb: .restore))
    }
}

/// 套餐额度用完（用户 10-19：不要一直挂着「剩 0%」，写下次重置时间）。clock 为「08:00」「10/16 08:00」「约 08:00」，不知道为 nil
struct QuotaExhausted: Codable, Equatable {
    var clock: String?
    /// 面板、右键卡、表盘：「下次重置：08:00」
    var text: String { clock.map { L("quota.nextReset", $0) } ?? L("quota.usedUp") }
    /// 菜单栏放不下长句：「08:00 重置」
    var menuBarText: String { clock.map { L("quota.resetsAtShort", $0) } ?? L("quota.usedUp") }
    /// 表盘：大字只写时刻（「下次重置：10/16 08:00」放不下），上面一行小字「下次重置」；不知道时刻写「已用完」
    var gaugeValue: String { clock ?? L("quota.usedUp") }
    var gaugeOverline: String? { clock == nil ? nil : L("quota.nextResetLabel") }
    /// 读屏：「额度已用完，下次重置 08:00」
    var a11y: String { L("quota.a11yUsedUp") + (clock.map { L("quota.a11yNextReset", $0) } ?? "") }
}
