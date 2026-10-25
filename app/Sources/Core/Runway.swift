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

    static func severity(hours: Double) -> RunwaySeverity {
        hours < dangerHours ? .danger : (hours < warnHours ? .warn : .ok)
    }

    static func durationText(hours: Double) -> String {
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

    static func compactText(hours: Double) -> String {
        if hours >= 2400 { return "99d+" }
        if hours >= 48 { return "\(Int(hours / 24))d" }
        let minutes = max(1, Int(max(0, hours) * 60))
        if hours < 1 { return "\(minutes)m" }
        return "\(minutes / 60)h\(String(format: "%02d", minutes % 60))m"
    }

    static func payg(balance: Decimal?, burn: BurnStats?) -> PaygRunway? {
        guard let balance = balance, let burn = burn else { return nil }
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
        let duration = r.hours < 1 ? L("common.underOneHour") : durationText(hours: r.hours)
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
        guard let window = q?.activityWindow else { return nil }
        let remaining = 100 - window.effectiveUsed(at: now)
        let reset = window.resetsAt.flatMap { $0 > now ? $0 : nil }
        let rise = risePP ?? 0
        var r = QuotaRunway(window: window, remainingPercent: remaining, risePP: rise,
                            hoursToEmpty: nil, resetsAt: reset, state: .idle, severity: .ok)
        if remaining <= 0 {
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

    static func quotaText(_ r: QuotaRunway, now: Date) -> String {
        let estimated = r.window.resetIsEstimated ? L("quota.approxPrefix") : ""
        let resetHours = r.resetsAt.map { $0.timeIntervalSince(now) / 3600 }
        let suffix = resetHours.map { L("runway.resetSuffix", estimated, durationText(hours: $0)) } ?? ""
        switch r.state {
        case .idle: return L("runway.idle") + suffix
        case .enough: return L("runway.enough") + suffix
        case .exhausted: return L("runway.exhausted") + suffix
        case .runsOut:
            let hours = r.hoursToEmpty ?? 0
            let head = L("runway.timeLeft", durationText(hours: hours))
            return head + (resetHours.map { L("runway.beforeReset", estimated, durationText(hours: $0 - hours)) } ?? "")
        }
    }
}
