import Foundation

/// 用户 10-19：套餐用完时不要一直挂着「剩 0%」，改写下次重置时间
@MainActor
func registerExhaustedResetTests() {
    // 2026-10-15 周四 05:47 UTC
    let now = Date(timeIntervalSince1970: 1_792_043_220)
    let utc = TimeZone(secondsFromGMT: 0)!
    let h: TimeInterval = 3600, m: TimeInterval = 60

    func quota(session: Double, sessionIn: TimeInterval?, weekly: Double, weeklyIn: TimeInterval, estimated: Bool = false) -> Quota {
        Quota(plan: "plus", windows: [
            QuotaWindow(kind: .session, usedPercent: session, resetsAt: sessionIn.map { now.addingTimeInterval($0) }, windowMinutes: 300,
                        resetIsEstimated: estimated),
            QuotaWindow(kind: .weekly, usedPercent: weekly, resetsAt: now.addingTimeInterval(weeklyIn), windowMinutes: 10080)],
              observedAt: now.addingTimeInterval(-2 * m))
    }
    func planState(_ q: Quota) -> PlatformState {
        var s = ProviderSnapshot(provider: .codexPlan, balance: nil, today: nil, month: nil, byModel: [],
                                 trend7: [], source: .quota, fetchedAt: now, credential: .ok)
        s.quota = q
        return PlatformState(id: .codexPlan, snapshot: s, burn: nil, status: .ok, lastSampleAt: nil, lastSample: nil)
    }
    let soon = 2 * h + 13 * m              // 当天 08:00
    let tomorrow = 86400 + 2 * h + 13 * m  // 10/16 08:00

    test("exhaustedMeansShownAsZero") {
        try checkEqual(QuotaText.isExhausted(remaining: 0.4), true)
        try checkEqual(QuotaText.isExhausted(remaining: 0), true)
        try checkEqual(QuotaText.isExhausted(remaining: 1.0), false)
        try checkEqual(QuotaText.isExhausted(remaining: nil), false)
        try checkEqual(QuotaText.isExhausted(remaining: .nan), false)
    }
    test("exhaustionClockFormats") {
        func e(_ q: Quota) -> QuotaExhausted? { QuotaText.exhaustion(q, now: now, timeZone: utc) }
        try checkEqual(e(quota(session: 100, sessionIn: soon, weekly: 41, weeklyIn: 5 * 86400)), QuotaExhausted(clock: "08:00"))
        try checkEqual(e(quota(session: 99.6, sessionIn: tomorrow, weekly: 41, weeklyIn: 5 * 86400)), QuotaExhausted(clock: "10/16 08:00"))
        try checkEqual(e(quota(session: 100, sessionIn: soon, weekly: 41, weeklyIn: 5 * 86400, estimated: true)), QuotaExhausted(clock: "约 08:00"))
        try checkEqual(e(quota(session: 100, sessionIn: nil, weekly: 41, weeklyIn: 5 * 86400)), QuotaExhausted(clock: nil))
        // 重置时间已过：窗口按已重置算，不是用完
        try checkEqual(e(quota(session: 100, sessionIn: -m, weekly: 41, weeklyIn: 5 * 86400)), nil)
        try checkEqual(e(quota(session: 35, sessionIn: soon, weekly: 41, weeklyIn: 5 * 86400)), nil)
        // 会话和本周都用完：两个都恢复才能用，写晚的那个
        try checkEqual(e(quota(session: 100, sessionIn: soon, weekly: 100, weeklyIn: tomorrow)), QuotaExhausted(clock: "10/16 08:00"))
    }
    test("exhaustionTexts") {
        try checkEqual(QuotaExhausted(clock: "08:00").text, "08:00 恢复")
        try checkEqual(QuotaExhausted(clock: nil).text, "已用完")
        try checkEqual(QuotaExhausted(clock: "10/16 08:00").menuBarText, "10/16 08:00 恢复")
        try checkEqual(QuotaExhausted(clock: nil).menuBarText, "已用完")
        try checkEqual(QuotaExhausted(clock: "10/16 08:00").gaugeValue, "10/16 08:00")
        try checkEqual(QuotaExhausted(clock: "10/16 08:00").gaugeOverline, "恢复时间")
        try checkEqual(QuotaExhausted(clock: nil).gaugeValue, "已用完")
        try checkEqual(QuotaExhausted(clock: nil).gaugeOverline, nil)
    }
    // 11/6 用户定 round7-scout 第 7 条乙：用完时一律说「恢复」（横幅、菜单栏、表盘、胶囊、悬停、读屏），不再混写「下次重置」
    test("exhaustedSaysBackNotReset") {
        let q = quota(session: 100, sessionIn: soon, weekly: 41, weeklyIn: 5 * 86400)
        let r = Runway.quota(q, risePP: 0, now: now)!
        let chip = Runway.quotaChip(r, now: now, timeZone: utc)
        try checkEqual(chip.title, "额度已用完")
        try checkEqual(chip.detail, "2 小时 13 分后恢复")
        try checkEqual(MenuBarText.quotaReading(q, now: now, timeZone: utc)?.reset, "2 小时 13 分后恢复")
        let rows = AppDataMapping.quotaRows(q.windows, now: now, timeZone: utc)
        try checkEqual(rows.map(\.resetShort), ["2:13 后恢复", "\(QuotaText.resetText(now.addingTimeInterval(5 * 86400), now: now, timeZone: utc))"])
        let weeklyOut = AppDataMapping.quotaRows(quota(session: 30, sessionIn: soon, weekly: 100, weeklyIn: tomorrow).windows, now: now, timeZone: utc)
        try checkEqual(weeklyOut.map(\.resetShort), ["2:13 后重置", "周五 08:00 恢复"])
        // 两个都用完、每周恢复得晚：只有每周那行写「恢复」，5 小时那行写「重置」（不让人以为 2 小时后就能用）
        let both = quota(session: 100, sessionIn: soon, weekly: 100, weeklyIn: tomorrow)
        try checkEqual(AppDataMapping.quotaRows(both.windows, now: now, timeZone: utc).map(\.resetShort), ["2:13 后重置", "周五 08:00 恢复"])
        try checkEqual(MenuBarText.quotaReading(both, now: now, timeZone: utc)?.reset, "周五 08:00 恢复")
        // 没用完的照旧写「重置」
        let ok = quota(session: 30, sessionIn: soon, weekly: 41, weeklyIn: 5 * 86400)
        try checkEqual(MenuBarText.quotaReading(ok, now: now, timeZone: utc)?.reset, "2 小时 13 分后重置")
        L10n.lang = .en
        defer { L10n.lang = .zh }
        try checkEqual(QuotaExhausted(clock: "08:00").menuBarText, "Back at 08:00")
        try checkEqual(AppDataMapping.quotaRows(q.windows, now: now, timeZone: utc).first?.resetShort, "back in 2:13")
        try checkEqual(QuotaExhausted(clock: "08:00").gaugeOverline, "Back at")
        try checkEqual(QuotaExhausted(clock: "08:00").a11y, "Quota used up, back at 08:00")
    }
    test("menuBarTitleShowsResetWhenExhausted") {
        let e = QuotaExhausted(clock: "08:00")
        try checkEqual(MenuBarText.title(mode: "balance", isQuota: true, balance: nil, today: nil, quotaUsed: 100, currency: nil, exhausted: e), "08:00 恢复")
        try checkEqual(MenuBarText.title(mode: "cost", isQuota: true, balance: nil, today: nil, quotaUsed: 100, currency: nil,
                                         exhausted: QuotaExhausted(clock: nil)), "已用完")
        try checkEqual(MenuBarText.title(mode: "icon", isQuota: true, balance: nil, today: nil, quotaUsed: 100, currency: nil, exhausted: e), "")
        try checkEqual(MenuBarText.title(mode: "balance", isQuota: true, balance: nil, today: nil, quotaUsed: 41, currency: nil), "已用 41%")
    }
    test("menuBarTitleRoundsRemainingBeforeShowingUsed") {
        try checkEqual(MenuBarText.title(mode: "balance", isQuota: true, balance: nil, today: nil, quotaUsed: 99.6, currency: nil), "已用 100%")
        try checkEqual(MenuBarText.title(mode: "balance", isQuota: true, balance: nil, today: nil, quotaUsed: 99.6, currency: nil,
                                         exhausted: QuotaExhausted(clock: "10:13")), "10:13 恢复")
    }
    test("sideAndReadingCarryExhaustion") {
        let done = planState(quota(session: 100, sessionIn: soon, weekly: 41, weeklyIn: 5 * 86400))
        try checkEqual(AppDataMapping.side(done, now: now, timeZone: utc).quotaExhausted, QuotaExhausted(clock: "08:00"))
        try checkEqual(MenuBarText.quotaReading(done.snapshot?.quota, now: now, timeZone: utc)?.exhausted, QuotaExhausted(clock: "08:00"))
        let fine = planState(quota(session: 35, sessionIn: soon, weekly: 41, weeklyIn: 5 * 86400))
        try checkEqual(AppDataMapping.side(fine, now: now, timeZone: utc).quotaExhausted, nil)
        try checkEqual(MenuBarText.quotaReading(fine.snapshot?.quota, now: now, timeZone: utc)?.exhausted, nil)
    }
    test("a11yReadsExhaustion") {
        try checkEqual(A11yText.quotaGauge(provider: "Codex 套餐", remainingPercent: 0.4, reset: "额度已用完",
                                           exhausted: QuotaExhausted(clock: "08:00")), "Codex 套餐 额度已用完，08:00 恢复")
        try checkEqual(A11yText.quotaGauge(provider: "Codex 套餐", remainingPercent: 0, reset: nil,
                                           exhausted: QuotaExhausted(clock: nil)), "Codex 套餐 额度已用完")
        let r = AppData.MenuQuota(usedPercent: 100, window: "当前会话", reset: "2 小时 13 分后重置", exhausted: QuotaExhausted(clock: "08:00"))
        try checkEqual(A11yText.menuBarQuotaValue(provider: "Codex 套餐", reading: r, low: true, dim: false),
                       "Codex 套餐 额度已用完，08:00 恢复，低于预警线")
    }
}
