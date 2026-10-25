import Foundation

private func runwayBurn(_ recent: Decimal?, _ average: Decimal, spike: Bool = false) -> BurnStats {
    BurnStats(perHourRecent: recent, perHourDay: nil, avgPerDayWeek: average, runwayDays: nil, spike: spike)
}

@MainActor
func registerRunwayTests() {
    test("runwaySeverityBoundaries") {
        for (hours, expected) in [(1.99, RunwaySeverity.danger), (2, .warn), (11.99, .warn), (12, .ok)] {
            try checkEqual(Runway.severity(hours: hours), expected)
        }
        try check(RunwaySeverity.ok < .warn && RunwaySeverity.warn < .danger)
    }
    test("runwayDurationBoundaries") {
        let cases: [(Double, String, String)] = [
            (0, "1 分钟", "1m"), (0.3, "18 分钟", "18m"),
            (1, "1 小时", "1h00m"), (5.6, "5 小时 36 分", "5h36m"),
            (24, "1 天", "24h00m"), (30, "1 天 6 小时", "30h00m"),
            (30 + 5.0 / 60, "1 天 6 小时", "30h05m"),
            (48, "2 天", "2d"), (120, "5 天", "5d"), (2400, "很久", "99d+")]
        for (hours, full, compact) in cases {
            try checkEqual(Runway.durationText(hours: hours), full)
            try checkEqual(Runway.compactText(hours: hours), compact)
        }
    }
    test("runwayPaygSpikeUsesRecentRate") {
        let r = Runway.payg(balance: 24, burn: runwayBurn(Decimal(string: "4.8")!, Decimal(string: "5.5")!, spike: true))!
        try checkEqual(r.hours, 5)
        try checkEqual(r.basis, .recentSpike)
        try checkEqual(r.severity, .warn)
        try checkEqual(r.perHourRecent, Decimal(string: "4.8"))
        try check(abs(r.multiple! - 20.9454545454545) < 0.000001)
        let t = Runway.paygText(r, currency: "CNY")
        try checkEqual(t.title, "预计可用时间：5 小时")
        try checkEqual(t.detail, "近 1 小时 ¥4.80/时 · 平时的 21 倍")
        try checkEqual(Runway.paygText(r, currency: "USD").detail, "近 1 小时 $4.80/时 · 平时的 21 倍")
    }
    test("runwayPaygAverageAndIdle") {
        for recent: Decimal? in [nil, 1, 0] {
            let r = Runway.payg(balance: 10, burn: runwayBurn(recent, 48))!
            try checkEqual(r.hours, 5)
            try checkEqual(r.basis, recent == 0 ? .idleRecent : .weekAverage)
            try checkEqual(r.multiple, nil)
            try checkEqual(r.perHourRecent, recent)
            let t = Runway.paygText(r, currency: nil)
            try checkEqual(t.title, recent == 0 ? "近 1 小时没花费 · 按平时还能用 5 小时" : "按平时的速度还能用 5 小时")
            try checkEqual(t.detail, nil)
        }
    }
    test("runwayPaygMissingRateAndNonpositiveBalance") {
        try checkEqual(Runway.payg(balance: nil, burn: runwayBurn(1, 24)), nil)
        try checkEqual(Runway.payg(balance: 10, burn: nil), nil)
        try checkEqual(Runway.payg(balance: 10, burn: runwayBurn(1, 0)), nil)
        for balance: Decimal in [0, -5] {
            let r = Runway.payg(balance: balance, burn: runwayBurn(nil, 24))!
            try checkEqual(r.hours, 0)
            try checkEqual(r.severity, .danger)
            try checkEqual(Runway.paygText(r, currency: nil).title, "按平时的速度还能用 不到 1 小时")
        }
        let r = Runway.payg(balance: 2400, burn: runwayBurn(nil, 24))!
        try checkEqual(Runway.paygText(r, currency: nil).title, "按平时的速度还能用 很久")
        try checkEqual(Runway.payg(balance: 10, burn: runwayBurn(0, 24, spike: true))?.basis, .idleRecent)
    }
    let now = Date(timeIntervalSince1970: 1_792_022_400)
    func quota(_ used: Double, resetHours: Double? = 4, estimated: Bool = false) -> Quota {
        Quota(plan: nil, windows: [QuotaWindow(kind: .session, usedPercent: used,
              resetsAt: resetHours.map { now.addingTimeInterval($0 * 3600) }, windowMinutes: 300,
              resetIsEstimated: estimated)], observedAt: now)
    }
    test("runwayQuotaStatesAndText") {
        let cases: [(Double, Double?, QuotaRunway.State, Double?, RunwaySeverity, String)] = [
            (60, 0.5, .idle, nil, .ok, "近 1 小时没用 · 4 小时 后重置"),
            (60, nil, .idle, nil, .ok, "近 1 小时没用 · 4 小时 后重置"),
            (60, 10, .enough, nil, .ok, "够用到重置 · 4 小时 后重置"),
            (60, 20, .runsOut, 2, .warn, "预计可用时间：2 小时 · 比重置早 2 小时"),
            (80, 20, .runsOut, 1, .danger, "预计可用时间：1 小时 · 比重置早 3 小时"),
            (100, nil, .exhausted, 0, .danger, "额度已用完 · 4 小时 后重置")]
        for (used, rise, state, hours, severity, text) in cases {
            let r = Runway.quota(quota(used), risePP: rise, now: now)!
            try checkEqual(r.state, state)
            try checkEqual(r.hoursToEmpty, hours)
            try checkEqual(r.remainingPercent, 100 - used)
            try checkEqual(r.risePP, rise ?? 0)
            try checkEqual(r.severity, severity)
            try checkEqual(Runway.quotaText(r, now: now), text)
        }
    }
    test("runwayQuotaWithoutResetAndExpiredReset") {
        for (used, rise, state, text) in [
            (88.0, 1.0, QuotaRunway.State.enough, "够用到重置"),
            (89, 1, .runsOut, "预计可用时间：11 小时"),
            (50, 0.5, .idle, "近 1 小时没用"),
            (100, 0, .exhausted, "额度已用完")] {
            let r = Runway.quota(quota(used, resetHours: nil), risePP: rise, now: now)!
            try checkEqual(r.state, state)
            try checkEqual(r.resetsAt, nil)
            try checkEqual(Runway.quotaText(r, now: now), text)
        }
        for reset in [-1.0, 0] {
            let r = Runway.quota(quota(100, resetHours: reset), risePP: 10, now: now)!
            try checkEqual(r.remainingPercent, 100)
            try checkEqual(r.resetsAt, nil)
            try checkEqual(r.hoursToEmpty, 10)
        }
    }
    test("runwayQuotaEstimatedResetAndWindowChoice") {
        let r = Runway.quota(quota(60, estimated: true), risePP: 0, now: now)!
        try checkEqual(Runway.quotaText(r, now: now), "近 1 小时没用 · 约 4 小时 后重置")
        let running = Runway.quota(quota(60, estimated: true), risePP: 20, now: now)!
        try checkEqual(Runway.quotaText(running, now: now), "预计可用时间：2 小时 · 比重置早 约 2 小时")
        try checkEqual(Runway.quota(nil, risePP: 1, now: now), nil)
        try checkEqual(Runway.quota(Quota(plan: nil, windows: [], observedAt: now), risePP: 1, now: now), nil)
        var q = quota(60)
        q.windows.insert(QuotaWindow(kind: .weekly, usedPercent: 99, resetsAt: nil, windowMinutes: nil), at: 0)
        try checkEqual(Runway.quota(q, risePP: 20, now: now)?.window.kind, .session)
        q.windows.removeLast()
        try checkEqual(Runway.quota(q, risePP: 20, now: now)?.window.kind, .weekly)
        q.windows[0].kind = .weeklyModel("模型")
        try checkEqual(Runway.quota(q, risePP: 20, now: now), nil)
    }
}
