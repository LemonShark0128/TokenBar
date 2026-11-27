import Foundation

@MainActor
func registerTodayCardStateTests() {
    let now = Date(timeIntervalSince1970: 1792022400)
    let day: TimeInterval = 86400
    func data() -> AppData {
        var d = AppData(nowLocal: "2026-10-15 00:00:00", balance: .init(cny: 28, source: "平台", status: "可用", ageS: 0),
                        today: .init(costCny: 6.27, tokens: 20, source: "平台账单"),
                        month: .init(costCny: 38.99, tokens: 20, source: "平台账单"), models: [], trend7: [], burn: nil)
        d.sides = [.init(id: "codexPlan", name: "Codex 套餐", tank: nil, currency: "PCT", todayCost: nil, status: L("side.ok")),
                   .init(id: "claudePlan", name: "Claude 套餐", tank: nil, currency: "PCT", todayCost: nil, status: L("side.ok")),
                   .init(id: "siliconflow", name: "硅基流动", tank: 10, currency: "CNY", todayCost: 0.5, status: L("side.ok"))]
        d.totalTodayCny = 6.77
        return d
    }
    /// 本周窗口：已用 used%，still = 离重置还有几天
    func weekly(used: Double, still: Double) -> AppData.QuotaRow {
        .init(id: "weekly", name: "本周", usedPercent: used, isReset: false, reset: nil, windowKind: "weekly",
              resetsAt: now.addingTimeInterval(still * day))
    }
    func session(used: Double) -> AppData.QuotaRow {
        .init(id: "session", name: "会话", usedPercent: used, isReset: false, reset: nil, windowKind: "session",
              resetsAt: now.addingTimeInterval(3 * 3600))
    }
    func card(_ d: AppData, _ id: String) -> TodayCard { TodayCards.build(d, running: [], now: now).first { $0.id == id }! }

    test("todayWeeklyForecast") {
        // 过了 3 天用了 30% → 7 天约 70%，重置时剩 30%
        let left = TodayCards.weeklyForecast(weekly(used: 30, still: 4), now: now)
        try check(abs((left?.remainingAtReset ?? 0) - 30) < 0.001); try checkEqual(left?.runsOutAt, nil)
        // 过了 2 天用了 80% → 再过 0.5 天用完
        let out = TodayCards.weeklyForecast(weekly(used: 80, still: 5), now: now)
        try checkEqual(out?.remainingAtReset, nil)
        try check(abs((out?.runsOutAt?.timeIntervalSince(now) ?? 0) - 0.5 * day) < 1)
        // 窗口刚开始、没用、已用完、已重置都不预测
        try checkEqual(TodayCards.weeklyForecast(weekly(used: 10, still: 6.5), now: now) == nil, true)
        try checkEqual(TodayCards.weeklyForecast(weekly(used: 0, still: 3), now: now) == nil, true)
        try checkEqual(TodayCards.weeklyForecast(weekly(used: 100, still: 3), now: now) == nil, true)
        var reset = weekly(used: 30, still: 3); reset.isReset = true
        try checkEqual(TodayCards.weeklyForecast(reset, now: now) == nil, true)
    }
    test("todayQuotaStateAndHint") {
        var d = data()
        d.sides[1].quotaRows = [session(used: 20), weekly(used: 30, still: 4)]
        let ok = card(d, "claudePlan")
        try checkEqual(ok.status, nil)
        try checkEqual(ok.stateLine, L("runway.enough")); try check(!ok.stateWarn)
        try checkEqual(ok.hint, L("today.weekAtReset", 30)); try check(!ok.hintWarn)
        try check(ok.a11y.contains(A11yText.speak(L("today.weekAtReset", 30))))
        // 本周会在重置前用完：状态行写用完的日子（橙），底注不重复
        d.sides[1].quotaRows = [session(used: 20), weekly(used: 80, still: 5)]
        let tight = card(d, "claudePlan")
        let when = TodayCards.weekdayText(now.addingTimeInterval(0.5 * day), now: now)
        try checkEqual(tight.stateLine, L("today.weekRunsOut", when)); try check(tight.stateWarn)
        try checkEqual(tight.hint, nil)
        // 有重置次数：底注照旧写重置次数，不写预测
        d.sides[1].quotaRows = [session(used: 20), weekly(used: 30, still: 4)]
        d.sides[1].resetCreditsCount = 1
        try checkEqual(card(d, "claudePlan").hint, nil)
    }
    test("todayWeekdayTextSameWeekdayNextWeek") {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let thu = Date(timeIntervalSince1970: 1_792_022_400)     // 2026-10-15 周四 00:00 UTC
        try checkEqual(TodayCards.weekdayText(thu.addingTimeInterval(3600), now: thu, calendar: cal), L("today.weekday.today"))
        try checkEqual(TodayCards.weekdayText(thu.addingTimeInterval(86400), now: thu, calendar: cal), "周五")
        try checkEqual(TodayCards.weekdayText(thu.addingTimeInterval(7 * 86400), now: thu, calendar: cal), "下周四")
    }
    test("todayQuotaUsedUpShowsBackTimeAndWeekHint") {
        var d = data()
        d.sides[0].quotaRows = [session(used: 100), weekly(used: 80, still: 5)]
        d.sides[0].riskText = L("quota.usedUp"); d.sides[0].riskSeverity = 2
        d.sides[0].quotaExhausted = QuotaExhausted(clock: "21:36")
        let c = card(d, "codexPlan")
        try checkEqual(c.status, L("today.usedUpBack", "21:36"))
        let when = TodayCards.weekdayText(now.addingTimeInterval(0.5 * day), now: now)
        try checkEqual(c.hint, L("today.weekRunsOut", when)); try check(c.hintWarn)
    }
    test("todayQuotaEmptyWindowNeverSaysEnough") {
        var d = data()
        d.sides[1].quotaRows = [session(used: 100), weekly(used: 30, still: 4)]
        let c = card(d, "claudePlan")
        try checkEqual(c.stateLine, L("quota.usedUp")); try check(c.stateWarn)
        try checkEqual(c.riskSeverity, RunwaySeverity.danger.rawValue)
    }
    test("todayUsedUpBackCrossDayShowsDateOnly") {
        var side = data().sides[0]
        side.quotaExhausted = QuotaExhausted(clock: "≈11/12 21:36")
        try checkEqual(TodayCards.usedUpBack(side), L("today.usedUpBackDay", "≈11/12"))
        side.quotaExhausted = QuotaExhausted(clock: "21:36")
        try checkEqual(TodayCards.usedUpBack(side), L("today.usedUpBack", "21:36"))
        side.quotaExhausted = nil
        try checkEqual(TodayCards.usedUpBack(side), nil)
    }
    test("todayQuotaDimmedHasNoState") {
        var d = data()
        d.sides[1].quotaRows = [session(used: 20), weekly(used: 30, still: 4)]
        d.sides[1].quotaStale = true
        let c = card(d, "claudePlan")
        try checkEqual(c.stateLine, nil); try checkEqual(c.hint, nil)
    }
    test("todayPaygStateLineAndAverage") {
        var d = data()
        d.sides[2].monthCost = 3; d.sides[2].avgCnyPerDayWeek = 1.62
        for (days, expected, warn) in [(1.0, L("today.runwayTopUp", "1"), true), (12, L("today.runwayChip", "12"), false),
                                       (45, L("today.runwayLong"), false)] {
            d.sides[2].runwayDays = days
            let c = card(d, "siliconflow")
            try checkEqual(c.stateLine, expected); try checkEqual(c.stateWarn, warn)
            try checkEqual(c.stats.map(\.label), [L("today.statToday"), L("today.statMonth"), L("today.statAvg")])
            try checkEqual(c.stats.last?.value, "¥1.62")
        }
        // 近 7 天没花、今天也没花
        d.sides[2].avgCnyPerDayWeek = 0; d.sides[2].todayCost = 0; d.sides[2].runwayDays = nil
        try checkEqual(card(d, "siliconflow").stateLine, L("today.unused7d"))
        // 日均只覆盖了几天（OpenRouter 用本周 / 本月累计算，月初又是周初）：不能说「近 7 天」（审查后续 3）
        d.sides[2].avgDays = 3
        try checkEqual(card(d, "siliconflow").stateLine, "近 3 天未使用")
        d.sides[2].avgDays = 1          // 只有今天：今日 $0 已经写在下面，不再说
        try checkEqual(card(d, "siliconflow").stateLine, nil)
        d.sides[2].avgDays = 15
        try checkEqual(card(d, "siliconflow").stateLine, L("today.unused7d"))
        d.sides[2].avgDays = nil
        // 没有花费数据（monthCost 为 nil）：不写日均，也不当作「未使用」
        d.sides[2].monthCost = nil
        let none = card(d, "siliconflow")
        try checkEqual(none.stateLine, nil); try check(!none.stats.contains { $0.label == L("today.statAvg") })
    }
    test("todaySpendNoteVsAverage") {
        var d = data()
        // 主平台 DeepSeek 日均 ¥4 + 硅基流动 ¥1 = ¥5
        d.burn = .init(cnyPerHourRate: nil, cnyPerDayRate: nil, avgCnyPerDayWeek: 4, runwayDays: nil, spike: nil)
        d.sides[2].avgCnyPerDayWeek = 1
        d.totalTodayCny = 7.7
        try checkEqual(TodayCards.build(d, running: [], now: now).first { $0.id == "spend" }!.spendNote, L("today.paidAboveAvg", 54))
        d.totalTodayCny = 3   // 低于日均不提示
        try checkEqual(TodayCards.build(d, running: [], now: now).first { $0.id == "spend" }!.spendNote, nil)
        d.totalTodayCny = 6
        try checkEqual(TodayCards.build(d, running: [], now: now).first { $0.id == "spend" }!.spendNote, nil)
        // 有平台缺日均：不写
        d.totalTodayCny = 7.7; d.sides[2].avgCnyPerDayWeek = nil
        try checkEqual(TodayCards.build(d, running: [], now: now).first { $0.id == "spend" }!.spendNote, nil)
    }
    test("runningCostDetail") {
        var t = RunningTask(provider: .claudePlan, sessionKey: "k", project: "demo", model: "opus 5.5", startedAt: now, lastActivity: now, tokens: 10)
        try checkEqual(RunningTaskText.costDetail(t), RunningTaskText.detail(t))   // 没有花费：照旧
        t.rawModel = "claude-opus-5-5"; t.usage = TokenBreakdown(input: 100_000, output: 10_000)
        try checkEqual(RunningTaskText.costDetail(t), "opus 5.5 · ≈$0.75")
    }
    test("todayPaygRunwayUnderOneDayWritesHours") {
        // 续航不到 1 天：原来写「约 0 天 · 建议充值」，改写小时 / 不到 1 小时
        for (days, unit, chip, topUp) in [(3.4, "约 3 天", "约 3 天", "约 3 天 · 建议充值"), (0.5, "约 12 小时", "约 12 小时", "约 12 小时 · 建议充值"),
                                          (0.99, "约 24 小时", "约 24 小时", "约 24 小时 · 建议充值"), (0.03, "不到 1 小时", "不到 1 小时", "不到 1 小时 · 建议充值"),
                                          (0, "不到 1 小时", "不到 1 小时", "不到 1 小时 · 建议充值"), (-1, "不到 1 小时", "不到 1 小时", "不到 1 小时 · 建议充值")] {
            try checkEqual(Runway.paygDays(days, days: "today.runwayChip", hours: "today.runwayHoursChip", underHour: "today.runwayUnderHourChip"), unit)
            var d = data()
            d.sides[2].monthCost = 3; d.sides[2].avgCnyPerDayWeek = 1.62; d.sides[2].runwayDays = days
            let c = card(d, "siliconflow")
            try checkEqual(c.runwayChip, chip); try checkEqual(c.stateLine, topUp)
            try check(c.stateWarn && c.runwayWarn)
        }
        var d = data()
        d.sides[2].monthCost = 3; d.sides[2].avgCnyPerDayWeek = 1.62; d.sides[2].runwayDays = 0.25
        try checkEqual(card(d, "siliconflow").stateLine, "约 6 小时 · 建议充值")
        // 卡片变灰（凭据失效）时状态行不写，续航进朗读文字
        d.sides[2].status = L("side.credentialInvalid")
        try check(card(d, "siliconflow").a11y.contains("还能用 6 小时"))
        // 按凭据类型的新说法（11/6 第 5 条乙）同样变灰
        for status in [L("side.keyInvalid"), L("side.loginExpired")] {
            d.sides[2].status = status
            try check(card(d, "siliconflow").dimmed, status)
        }
        d.sides[2].status = L("side.ok"); d.sides[2].runwayDays = 5
        try checkEqual(card(d, "siliconflow").stateLine, "约 5 天 · 建议充值")
        // 天数向下取整：6.6 天原来写「约 7 天 · 建议充值」却按不到 7 天标橙
        d.sides[2].runwayDays = 6.6
        try checkEqual(card(d, "siliconflow").stateLine, "约 6 天 · 建议充值")
        d.sides[2].runwayDays = 12.9
        try checkEqual(card(d, "siliconflow").stateLine, "约 12 天")
        // 不到 1 分钟前的过时状态写「1 分钟前」，不写「0 分钟前」
        try checkEqual(AppDataMapping.side(PlatformState(id: .deepseek, snapshot: nil, burn: nil, status: .stale(minutes: 0)), now: now).status,
                       L("status.minAgo", 1))
        let saved = L10n.lang; L10n.lang = .en; defer { L10n.lang = saved }
        d.sides[2].runwayDays = 0.25
        try checkEqual(card(d, "siliconflow").stateLine, "About 6 hours · Top up")
        d.sides[2].runwayDays = 0.02
        try checkEqual(card(d, "siliconflow").runwayChip, "Under 1 hour")
        try checkEqual(L("runway.chipReset", L("quota.approxPrefix"), "2h"), "resets in ≈ 2h")   // 原来「≈ resets in 2h」
        try checkEqual(Runway.paygDays(1.0 / 24, days: "today.runway", hours: "today.runwayHours", underHour: "today.runwayUnderHour"), "1 hour left")
    }
}
