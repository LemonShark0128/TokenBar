import Foundation

/// 套餐额度的文案：窗口名、重置时间、最近使用。涉及钟点的都传 now 和 timeZone，测试可固定
enum QuotaText {
    static func countdown(to at: Date, now: Date) -> String? {
        let seconds = at.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        let minutes = max(1, Int(seconds / 60))
        if minutes >= 1440 {
            let days = minutes / 1440, hours = (minutes % 1440) / 60
            return hours == 0 ? L("quota.countdown.days", days) : L("quota.countdown.daysHours", days, hours)
        }
        if minutes >= 60 {
            let hours = minutes / 60, rest = minutes % 60
            return rest == 0 ? L("quota.countdown.hours", hours) : L("quota.countdown.hoursMinutes", hours, rest)
        }
        return L("quota.countdown.minutes", minutes)
    }

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
        return L("quota.\(v).at", clock(at, now: now, timeZone: timeZone))
    }

    /// 「周四 08:00」（英文「Thu 08:00」），星期用固定的表，不依赖系统的日期格式。
    /// 和今天同一个星期几（7 天后）或隔了 7 天以上写「下周四 08:00」（英文「next Thu 08:00」）：
    /// 原来周四 10:00 看下周四 08:00 的重置写「周四 08:00」，像今天早上已经过去的时刻（11/6 用户定乙）
    private static func clock(_ at: Date, now: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.weekday, .hour, .minute], from: at)
        let day = weekdayName(at, now: now, calendar: cal, name: L("weekday.\((c.weekday ?? 1) - 1)"))
        return String(format: "%@ %02d:%02d", day, c.hour ?? 0, c.minute ?? 0)
    }

    /// 星期名：隔了 7 个日历日以上（同一个星期几已经是下周）加「下」/「next」，按 calendar 的时区数日历日。
    /// 不处理「今天」：重置文字 24 小时内另有写法；TodayCards.weekdayText 自己先判今天
    static func weekdayName(_ at: Date, now: Date, calendar: Calendar, name: String) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: at)).day ?? 0
        return days >= 7 ? L("weekday.next", name) : name
    }

    static func resetText(_ at: Date, now: Date, timeZone: TimeZone) -> String {
        when(at, now: now, timeZone: timeZone, verb: .reset)
    }

    /// 窄处用：不到 24 小时写「2:13 后重置」
    static func resetCompact(_ at: Date, now: Date, timeZone: TimeZone) -> String {
        compact(at, now: now, timeZone: timeZone, verb: .reset)
    }

    private static func compact(_ at: Date, now: Date, timeZone: TimeZone, verb: Verb) -> String {
        let secs = at.timeIntervalSince(now)
        guard secs > 0, secs < 86400 else { return when(at, now: now, timeZone: timeZone, verb: verb) }
        let mins = max(1, Int(secs / 60))
        return L("quota.\(verb.rawValue).inCompact", "\(mins / 60):\(String(format: "%02d", mins % 60))")
    }

    /// 按窗口写重置时间：推算的写「约 2 小时 13 分后重置（推算）」；marker = false 时不加「（推算）」
    /// （面板窗口列表一行放不下，同一屏的标题行已经写了）。没有重置时间为 nil
    /// restore：这个窗口就是卡住整个套餐的那个（Quota.blockingWindow）时写「…后恢复」（同横幅、胶囊、表盘），
    /// 否则写「…后重置」——两个窗口都用完时，先重置的那个写「恢复」会让人以为到点就能用（审核建议）
    static func resetText(_ w: QuotaWindow, now: Date, timeZone: TimeZone, marker: Bool = true, restore: Bool = false) -> String? {
        guard let at = w.resetsAt else { return nil }
        let t = when(at, now: now, timeZone: timeZone, verb: restore ? .restore : .reset)
        return w.resetIsEstimated && at > now ? L("quota.approx", t) + (marker ? L("quota.estMarker") : "") : t
    }

    /// 窄处用的按窗口版本：推算的只加「约」（放不下「（推算）」）
    static func resetCompact(_ w: QuotaWindow, now: Date, timeZone: TimeZone, restore: Bool = false) -> String? {
        guard let at = w.resetsAt else { return nil }
        let t = compact(at, now: now, timeZone: timeZone, verb: restore ? .restore : .reset)
        return w.resetIsEstimated && at > now ? L("quota.approx", t) : t
    }

    /// 旧版提醒记忆键「平台|窗口显示名|…」里的显示名（当时界面语言）换成窗口种类（session / weekly / weeklyModel:x）
    static func languageFreeKey(_ key: String) -> String {
        var parts = key.components(separatedBy: "|")
        guard parts.count >= 2 else { return key }
        let name = parts[1]
        if name == "session" || name == "weekly" || name.hasPrefix("weeklyModel:") { return key }
        if name == windowName(.session) { parts[1] = "session" }
        else if name == windowName(.weekly) { parts[1] = "weekly" }
        else {
            let template = L("quota.window.weeklyModel", "\u{1}")
            let pieces = template.components(separatedBy: "\u{1}")
            if pieces.count == 2, name.hasPrefix(pieces[0]), name.hasSuffix(pieces[1]), name.count > pieces[0].count + pieces[1].count {
                parts[1] = "weeklyModel:" + String(name.dropFirst(pieces[0].count).dropLast(pieces[1].count))
            }
        }
        return parts.joined(separator: "|")
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
        // 5 小时 / 每周窗口用完时按 blockingWindow（同表盘标题、续航；「本周（Opus）」恢复得再晚也不算）
        let done = q.windows.filter { isExhausted(remaining: 100 - $0.effectiveUsed(at: now)) }
        let last = q.blockingWindow(at: now).flatMap { $0.resetsAt == nil ? nil : $0 }
            ?? done.filter { $0.resetsAt != nil }.max { $0.resetsAt! < $1.resetsAt! }
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
        return ago(minutes: Int(secs / 60))
    }

    /// 「12 分钟前」「3 小时前」「2 天前」（英文「12 min ago」「3h ago」「2 days ago」）：
    /// 超过 60 分钟写小时、超过 24 小时写天，不写「1440 分钟前」；不到 1 分钟按 1 分钟（不写「0 分钟前」）
    static func ago(minutes: Int) -> String {
        let mins = max(1, minutes)
        if mins < 60 { return L("status.minAgo", mins) }
        if mins < 1440 { return L("quota.hoursAgo", mins / 60) }
        return L("quota.daysAgo", mins / 1440)
    }

    /// 「12 分钟未更新」「2 小时未更新」「1 天未更新」（按量付费的数据健康）
    static func notUpdatedFor(minutes: Int) -> String {
        let mins = max(1, minutes)
        if mins < 60 { return L("status.minNotUpdated", mins) }
        if mins < 1440 { return L("status.hoursNotUpdated", mins / 60) }
        return L("status.daysNotUpdated", mins / 1440)
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
    // 用完时一律说「恢复」（11/6 用户定 round7-scout 第 7 条乙；原来横幅「下次重置：08:00」、卡片「08:00 恢复」两种说法）
    /// 面板、右键卡：「08:00 恢复」
    var text: String { clock.map { L("quota.backAt", $0) } ?? L("quota.usedUp") }
    /// 菜单栏：「08:00 恢复」
    var menuBarText: String { clock.map { L("quota.backAtShort", $0) } ?? L("quota.usedUp") }
    /// 表盘：大字只写时刻（「10/16 08:00 恢复」放不下），上面一行小字「恢复时间」；不知道时刻写「已用完」
    var gaugeValue: String { clock ?? L("quota.usedUp") }
    var gaugeOverline: String? { clock == nil ? nil : L("quota.backLabel") }
    /// 读屏：「额度已用完，08:00 恢复」
    var a11y: String { L("quota.a11yUsedUp") + (clock.map { L("quota.a11yBackAt", $0) } ?? "") }
}
