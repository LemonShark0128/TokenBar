import Foundation

enum RunwaySeverity: Int, Comparable {
    case ok, warn, danger
    static func < (lhs: RunwaySeverity, rhs: RunwaySeverity) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct PaygRunway: Equatable {
    enum Basis: Equatable { case recentSpike, weekAverage, idleRecent }
    var hours: Double
    var basis: Basis
    var severity: RunwaySeverity
    var perHourRecent: Decimal?
    var multiple: Double?
}

struct QuotaRunway: Equatable {
    enum State: Equatable { case idle, enough, runsOut, exhausted }
    var window: QuotaWindow
    var remainingPercent: Double
    var risePP: Double
    var hoursToEmpty: Double?
    var resetsAt: Date?
    var state: State
    var severity: RunwaySeverity
}

/// 续航读数与文案；时间由调用方传入。
enum Runway {
    static let dangerHours: Double = 2
    static let warnHours: Double = 12

    /// 按量付费「还能用几天」的写法：≥1 天写整天数（向下取整，报少不报多，与 durationText「还能用 4 天」一致；
    /// 原来四舍五入，6.6 天写「约 7 天」却按不到 7 天标橙）；不到 1 天写小时（四舍五入，1–24）；
    /// 不到 1 小时（含 0 和负数）写「不到 1 小时」——原来一律写天数，0.3 天成了「约 0 天」
    static func paygDays(_ days: Double, days daysKey: String, hours hoursKey: String, underHour underKey: String) -> String {
        if days >= 1 { return L(daysKey, String(Int(days))) }
        let hours = days * 24
        guard hours >= 1 else { return L(underKey) }
        return L(hoursKey, min(24, Int(hours.rounded())))
    }

    static func severity(hours: Double) -> RunwaySeverity {
        hours < dangerHours ? .danger : (hours < warnHours ? .warn : .ok)
    }

    static func durationText(hours: Double) -> String {
        // 非有限数：+∞ 同「很久」，其余（−∞、NaN）按最短写
        guard hours.isFinite else { return hours > 0 ? L("dur.long") : L("dur.minutes", 1) }
        if hours >= 2400 { return L("dur.long") }
        if hours >= 48 { return L("dur.days", Int(hours / 24)) }
        if hours >= 24 {
            let h = Int(hours) - 24
            return h == 0 ? L("dur.oneDay") : L("dur.oneDayHours", h)
        }
        let minutes = max(1, Int(max(0, hours) * 60))
        if hours < 1 { return L("dur.minutes", minutes) }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? L("dur.hours", h) : L("dur.hoursMin", h, m)
    }

    /// 可用时长：不到 1 小时写「不到 1 小时」，否则同 durationText（面板胶囊、风险条、提醒、菜单栏提示共用）
    static func spanText(hours: Double) -> String {
        hours < 1 ? L("common.underOneHour") : durationText(hours: hours)
    }

    static func payg(balance: Decimal?, burn: BurnStats?) -> PaygRunway? {
        // 数据不足 1 天（新平台头一天）：日均只是今天的数，不写续航
        guard let balance = balance, let burn = burn, burn.enoughData else { return nil }
        let remaining = max(0, balance)
        let hours: Double
        let basis: PaygRunway.Basis
        var multiple: Double?
        if burn.spike, let recent = burn.perHourRecent, recent > 0 {
            hours = NSDecimalNumber(decimal: remaining / recent).doubleValue
            basis = .recentSpike
            if burn.avgPerDayWeek > 0 {
                multiple = NSDecimalNumber(decimal: recent * 24 / burn.avgPerDayWeek).doubleValue
            }
        } else if burn.avgPerDayWeek > 0 {
            hours = NSDecimalNumber(decimal: remaining / burn.avgPerDayWeek * 24).doubleValue
            basis = burn.perHourRecent == 0 ? .idleRecent : .weekAverage
        } else { return nil }
        return PaygRunway(hours: hours, basis: basis, severity: severity(hours: hours),
                          perHourRecent: burn.perHourRecent, multiple: multiple)
    }

    static func paygText(_ r: PaygRunway, currency: String?) -> (title: String, detail: String?) {
        let duration = spanText(hours: r.hours)
        switch r.basis {
        case .recentSpike:
            let rate = r.perHourRecent.map { NSDecimalNumber(decimal: $0).doubleValue }
            var detail = L("runway.recentRate", fmtMoney(rate, currency))
            if let multiple = r.multiple { detail += L("runway.multiple", Int(multiple.rounded())) }
            return (L("runway.timeLeft", duration), detail)
        case .weekAverage: return (L("runway.weekAvg", duration), nil)
        case .idleRecent: return (L("runway.idleRecent", duration), nil)
        }
    }

    static func quota(_ q: Quota?, risePP: Double?, now: Date) -> QuotaRunway? {
        guard let q, let active = q.activityWindow else { return nil }
        // 每周窗口已用完（5 小时窗口还有余）也算用完：两个都恢复才能再用，取最晚恢复的那个
        // （原来只看活动窗口，每周用完时还写「够用到重置」）。口径同界面读数 Quota.blockingWindow
        let window = q.blockingWindow(at: now) ?? active
        let remaining = 100 - window.effectiveUsed(at: now)
        let reset = window.resetsAt.flatMap { $0 > now ? $0 : nil }
        let rise = risePP ?? 0
        var r = QuotaRunway(window: window, remainingPercent: remaining, risePP: rise,
                            hoursToEmpty: nil, resetsAt: reset, state: .idle, severity: .ok)
        if window.isExhausted(at: now) {
            r.state = .exhausted
            r.hoursToEmpty = 0
            r.severity = .danger
        } else if rise >= 1 {
            let hours = remaining / rise
            let runsOut = reset.map { hours < $0.timeIntervalSince(now) / 3600 } ?? (hours < warnHours)
            r.state = runsOut ? .runsOut : .enough
            if runsOut {
                r.hoursToEmpty = hours
                r.severity = hours < dangerHours ? .danger : .warn
            }
        }
        return r
    }
}
