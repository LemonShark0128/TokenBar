import Foundation

@MainActor
func registerQuotaPaceTests() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    func window(_ seconds: Double?, _ minutes: Int?) -> QuotaWindow {
        QuotaWindow(kind: .session, usedPercent: 41, resetsAt: seconds.map { now.addingTimeInterval($0) }, windowMinutes: minutes)
    }
    test("quotaPaceFiveHours") {
        try checkEqual(QuotaPace.expectedRemainingPercent(window(4 * 3600, 300), now: now), 80)
        try checkEqual(QuotaPace.expectedRemainingPercent(window(5 * 3600, 300), now: now), 100)
        try checkEqual(QuotaPace.expectedRemainingPercent(window(6 * 3600, 300), now: now), 100)
    }
    test("quotaPaceUnavailable") {
        for w in [window(-1, 300), window(0, 300), window(100, nil), window(nil, 300), window(100, 0), window(100, -1)] {
            try checkEqual(QuotaPace.expectedRemainingPercent(w, now: now), nil)
        }
    }
    test("quotaPaceWeekly") {
        let value = QuotaPace.expectedRemainingPercent(window(71 * 3600, 7 * 24 * 60), now: now)!
        try check(abs(value - 42.2619) < 0.001)
    }
    test("quotaCountdownBothLanguages") {
        defer { L10n.lang = .zh }
        let cases: [(Double, String, String)] = [(150 * 3600, "6天6小时", "6d 6h"), (144 * 3600, "6天", "6d"), (194 * 60, "3小时14分", "3h 14m"), (3 * 3600, "3小时", "3h"), (14 * 60, "14分", "14m"), (1, "1分", "1m")]
        for (seconds, zh, en) in cases {
            L10n.lang = .zh
            try checkEqual(QuotaText.countdown(to: now.addingTimeInterval(seconds), now: now), zh)
            L10n.lang = .en
            try checkEqual(QuotaText.countdown(to: now.addingTimeInterval(seconds), now: now), en)
        }
        try checkEqual(QuotaText.countdown(to: now, now: now), nil)
        try checkEqual(QuotaText.countdown(to: now.addingTimeInterval(-1), now: now), nil)
    }
    test("quotaRowsDecodeLegacyJSON") {
        let row = try JSONDecoder().decode(AppData.QuotaRow.self, from: Data(#"{"id":"session","name":"会话","usedPercent":41,"isReset":false}"#.utf8))
        try checkEqual(row.paceRemainingPercent, nil)
        try checkEqual(row.countdown, nil)
        let side = try JSONDecoder().decode(AppData.Side.self, from: Data(#"{"id":"codexPlan","name":"Codex","currency":"PCT","status":"正常","quotaStale":false}"#.utf8))
        try checkEqual(side.quotaRows, [])
    }
    test("quotaRemainingRoundsDown") {
        try checkEqual(quotaRemainingPercent(99.9), "99%")
        try checkEqual(quotaRemainingPercent(58.9), "58%")
    }
    test("quotaPaceMappedForMainAndSide") {
        let windows = [window(4 * 3600, 300), QuotaWindow(kind: .weekly, usedPercent: 20, resetsAt: now, windowMinutes: 10080)]
        let state = PlatformState(id: .codexPlan, snapshot: ProviderSnapshot(provider: .codexPlan, balance: nil, today: nil, month: nil,
            byModel: [], trend7: [], source: .quota, fetchedAt: now, credential: .ok,
            quota: Quota(plan: nil, windows: windows, observedAt: now)), burn: nil, status: .ok)
        let tz = TimeZone(secondsFromGMT: 0)!
        let main = AppDataMapping.appData(main: state, others: [], now: now, timeZone: tz)
        let side = AppDataMapping.side(state, now: now, timeZone: tz)
        try checkEqual(main.quota?.rows, side.quotaRows)
        try checkEqual(side.quotaRows[0].paceRemainingPercent, 80)
        try checkEqual(side.quotaRows[0].countdown, "4小时")
        try checkEqual(side.quotaRows[1].paceRemainingPercent, nil)
        try checkEqual(side.quotaRows[1].countdown, nil)
        try check(side.quotaRows[1].isReset)
        let back = try JSONDecoder().decode(AppData.Side.self, from: JSONEncoder().encode(side))
        try checkEqual(back, side)
        let payg = PlatformState(id: .deepseek, snapshot: nil, burn: nil, status: .ok)
        try checkEqual(AppDataMapping.side(payg, now: now).quotaRows, [])
    }
    test("quotaPaceAccessibilityCountdownAndLeftCopy") {
        defer { L10n.lang = .zh }
        let row = AppData.QuotaRow(id: "s", name: "Session", usedPercent: 41.1, isReset: false,
            reset: "fallback", countdown: "3h 14m")
        L10n.lang = .en
        try checkEqual(quotaLeftText(99.9), "99% left")
        try checkEqual(A11yText.quotaWindow(row), "Session, 58% left, resets in 3h 14m")
        L10n.lang = .zh
        try checkEqual(quotaLeftText(99.9), "剩余 99%")
        var zh = row; zh.name = "会话"; zh.countdown = "3小时14分"
        try checkEqual(A11yText.quotaWindow(zh), "会话，剩余 58%，3小时14分后重置")
    }

}
