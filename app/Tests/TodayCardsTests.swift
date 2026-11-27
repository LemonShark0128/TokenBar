import Foundation

@MainActor
func registerTodayCardsTests() {
    let now = Date(timeIntervalSince1970: 1792022400)
    func data() -> AppData {
        var d = AppData(nowLocal: "2026-10-15 00:00:00", balance: .init(cny: 28, source: "平台", status: "可用", ageS: 0),
                        today: .init(costCny: 6.27, tokens: 20, source: "平台账单"),
                        month: .init(costCny: 38.99, tokens: 20, source: "平台账单"), models: [], trend7: [], burn: nil)
        d.sides = [.init(id: "codexPlan", name: "Codex", tank: nil, currency: "PCT", todayCost: nil, status: L("side.ok")),
                   .init(id: "claudePlan", name: "Claude", tank: nil, currency: "PCT", todayCost: nil, status: L("side.ok")),
                   .init(id: "siliconflow", name: "硅基流动", tank: 10, currency: "CNY", todayCost: 0.5, status: L("side.ok"))]
        d.totalTodayCny = 6.77
        return d
    }
    for severity in [1, 2] {
        test("todayRiskSeverityPreserved\(severity)") {
            var d = data()
            d.sides[0].riskText = "预计可用时间：4 小时"
            d.sides[0].riskSeverity = severity
            let c = TodayCards.build(d, running: [], now: now).first { $0.id == "codexPlan" }!
            try checkEqual(c.riskSeverity, severity)
            try checkEqual(c.status, d.sides[0].riskText)
        }
    }
    let task = RunningTask(provider: .codexPlan, sessionKey: "test", project: "demo", model: "gpt", startedAt: now, lastActivity: now, tokens: 10)
    for count in [1, 3] {
        test("todayRunningTotalNoCost\(count)") {
            let tasks = Array(repeating: task, count: count)
            let total = TodayCards.runningTotal(tasks)
            try checkEqual(total.tokens, 10 * count); try checkEqual(total.costUSD, nil)
            let card = TodayCards.build(data(), running: tasks, now: now).last!
            try checkEqual(card.footnote, L("today.runningTotal", RunningTaskText.tokens(10 * count)))
        }
    }
    test("todayRunningTotalWithCost") {
        var priced = task; priced.rawModel = "gpt-5.5"; priced.usage = TokenBreakdown(input: 1000, output: 100)
        let total = TodayCards.runningTotal([priced, priced, task])
        try checkEqual(total.tokens, 30); try checkEqual(total.costUSD, priced.costUSD.map { $0 * 2 })
        try check(TodayCards.build(data(), running: [priced], now: now).last!.footnote!.contains("≈$"))
    }
    for cash in [false, true] {
        for api in [false, true] {
            test("todaySpendColumns_\(cash)_\(api)") {
                var d = data(); d.totalTodayCny = cash ? 6.77 : nil
                d.apiValue = api ? .init(todayUSD: 2, weekUSD: 4, perProvider: ["codexPlan": 2], partial: true) : nil
                let card = TodayCards.build(d, running: [], now: now).first { $0.id == "spend" }!
                try checkEqual(card.spendCash, cash ? "¥6.77" : "—")
                try checkEqual(card.spendAPI, api ? "≈$2.00 起" : "—")
                try checkEqual(card.spendEmpty, !cash && !api)
            }
        }
    }
    test("todaySpendBarExcludesUnavailableCashColumn") {
        var d = data(); d.totalTodayCny = nil
        d.apiValue = .init(todayUSD: 2, weekUSD: 4, perProvider: ["codexPlan": 2], partial: false)
        let card = TodayCards.build(d, running: [], now: now).first { $0.id == "spend" }!
        try checkEqual(card.segments.map(\.id), [.codexPlan])
        try checkEqual(card.segments.first?.fraction, 1)
    }
    test("todaySpendBarMatchesBothColumnsValue") {
        var d = data(); d.cardExchangeRate = 10
        d.today.costCny = 10; d.sides = [d.sides[0]]; d.totalTodayCny = 10
        d.apiValue = .init(todayUSD: 2, weekUSD: 4, perProvider: ["codexPlan": 2], partial: false)
        let card = TodayCards.build(d, running: [], now: now).first { $0.id == "spend" }!
        try checkEqual(card.spendCash, "¥10.00"); try checkEqual(card.spendAPI, "≈$2.00")
        try checkEqual(card.segments.map(\.id), [.deepseek, .codexPlan])
        try check(abs(card.segments[0].fraction - 1.0 / 3) < 0.00001)
        try check(abs(card.segments[1].fraction - 2.0 / 3) < 0.00001)
    }
    test("todaySpendAPIDropsCentsFromHundredDollars") {
        var d = data()
        d.apiValue = .init(todayUSD: 552.03, weekUSD: 951, perProvider: ["codexPlan": 552.03], partial: false)
        try checkEqual(TodayCards.build(d, running: [], now: now).first { $0.id == "spend" }!.spendAPI, "≈$552")
        d.apiValue = .init(todayUSD: 99.5, weekUSD: 951, perProvider: ["codexPlan": 99.5], partial: false)
        try checkEqual(TodayCards.build(d, running: [], now: now).first { $0.id == "spend" }!.spendAPI, "≈$99.50")
        d.apiValue = .init(todayUSD: 99.996, weekUSD: 951, perProvider: ["codexPlan": 99.996], partial: false)
        try checkEqual(TodayCards.build(d, running: [], now: now).first { $0.id == "spend" }!.spendAPI, "≈$100")
    }
    test("todayCardOrderAndRunning") {
        let cards = TodayCards.build(data(), running: [task], now: now)
        try checkEqual(cards.map(\.kind), [.platform, .platform, .platform, .platform, .spend, .running])
        try checkEqual(cards.prefix(4).map(\.id), ["deepseek", "codexPlan", "claudePlan", "siliconflow"])
    }
    test("todayNoTasksShowsEmptyRunningCard") {
        // 加了 Claude / Codex：没任务也留「正在跑」写空状态（固定格子里右边不空着）
        let cards = TodayCards.build(data(), running: [], now: now)
        let running = cards.first { $0.kind == .running }
        try checkEqual(running?.status, L("today.runningEmpty"))
        try checkEqual(running?.badge, nil)
        try checkEqual(running?.footnote, L("today.runningEmptyHint"))
        // 只有按量付费平台：不会有任务，不放这张卡
        // 空状态说明不让同排平台卡多留一行状态行
        let placements = [TodayLayout.Placement(id: "siliconflow", size: .small, row: 0, column: 0),
                          TodayLayout.Placement(id: "running", size: .small, row: 0, column: 1)]
        var quiet = cards
        if let i = quiet.firstIndex(where: { $0.id == "siliconflow" }) { quiet[i].status = nil; quiet[i].stateLine = nil; quiet[i].runwayChip = nil }
        try check(!TodayCards.needsRiskRow(id: "siliconflow", cards: quiet, placements: placements))
        var d = data(); d.sides = d.sides.filter { $0.id == "siliconflow" }
        try check(!TodayCards.build(d, running: [], now: now).contains { $0.kind == .running })
    }
    test("todayPlansOnlySpendHasNoCash") {
        var d = data(); d.mainProvider = .codexPlan; d.balance.source = AppData.quotaSource
        d.sides = [d.sides[1]]; d.totalTodayCny = nil
        d.apiValue = .init(todayUSD: 23.1, weekUSD: 148, perProvider: [:], partial: false)
        let c = TodayCards.build(d, running: [], now: now).first { $0.id == "spend" }!
        try checkEqual(c.value, "")
        try checkEqual(c.lines, ["套餐折合 API ≈$23.10", "近 7 天 ≈$148"])
    }
    test("todayPartialAndApprox") {
        var d = data(); d.totalIsApprox = true
        d.apiValue = .init(todayUSD: 23.1, weekUSD: 148, perProvider: [:], partial: true)
        let c = TodayCards.build(d, running: [], now: now).first { $0.id == "spend" }!
        try checkEqual(c.value, "≈¥6.77")
        try checkEqual(c.lines.first, "套餐折合 API ≈$23.10 起")
        try check(c.a11y.contains("23.10"))
    }
    test("todayBadgeAndAccessibility") {
        var d = data(); d.sides[0].plan = "plus"
        let c = TodayCards.build(d, running: [], now: now)[1]
        try checkEqual(c.badge, "Plus")
        try check(c.a11y.contains("Codex") && c.a11y.contains("Plus"))
    }
    test("todaySettingsAndDefaults") {
        let rows = SettingsLayout.sections(.display, added: [], main: nil, customOpen: []).flatMap(\.rows)
        try check(rows.contains(.panelHome))
        try checkEqual(SettingsLayout.panelHomeOptions.map(\.key), ["today", "single"])
        try check(TodayCards.showsHome(preference: "today", platformCount: 2))
        try check(!TodayCards.showsHome(preference: "single", platformCount: 4))
        try check(!TodayCards.showsHome(preference: "today", platformCount: 1))
        try checkEqual(TodayCards.widgetPage(saved: nil, platformCount: 2), "overview")
        try checkEqual(TodayCards.widgetPage(saved: "tokens", platformCount: 2), "tokens")
    }
    test("widgetPlanMultiplePlatformsOmitsTokens") {
        let state = TodayCards.widgetNavigation(isPlan: true, platformCount: 2, saved: nil)
        try checkEqual(state.items.map { $0.0 }, ["balance", "overview"])
        try checkEqual(state.selected, "overview")
    }
    test("widgetMeteredMultiplePlatformsHasThreePages") {
        let state = TodayCards.widgetNavigation(isPlan: false, platformCount: 3, saved: "tokens")
        try checkEqual(state.items.map { $0.0 }, ["balance", "tokens", "overview"])
        try checkEqual(state.selected, "tokens")
    }
    test("widgetPlanSavedTokensSelectsBalanceWithoutLosingPreference") {
        let saved = "tokens"
        try checkEqual(TodayCards.widgetNavigation(isPlan: true, platformCount: 2, saved: saved).selected, "balance")
        try checkEqual(TodayCards.widgetNavigation(isPlan: false, platformCount: 2, saved: saved).selected, "tokens")
        try checkEqual(TodayCards.widgetNavigation(isPlan: true, platformCount: 2, saved: "overview").selected, "overview")
    }
    test("widgetSinglePlatformKeepsExistingPagesAndDefaults") {
        for isPlan in [false, true] {
            let state = TodayCards.widgetNavigation(isPlan: isPlan, platformCount: 1, saved: nil)
            // The plan picker remains hidden in the view, retaining its layout space.
            try checkEqual(state.items.map { $0.0 }, ["balance", "tokens"])
            try checkEqual(state.selected, "balance")
            try checkEqual(TodayCards.widgetNavigation(isPlan: isPlan, platformCount: 1, saved: "tokens").selected,
                           isPlan ? "balance" : "tokens")
        }
    }
    test("todayWidgetSessionAndMissingSpend") {
        var d = data(); d.sides[0].quotaRows = [.init(id: "session", name: "会话", usedPercent: 53, isReset: false, reset: nil, windowKind: "session")]
        d.sides[3 - 1].todayCost = nil
        let cards = TodayCards.build(d, running: [], now: now)
        try checkEqual(cards[1].compactValue, "47%")
        try checkEqual(cards[3].compactDetail, "")
    }
    test("todaySpendSegmentsConvertCurrency") {
        var d = data(); d.cardExchangeRate = 10
        d.apiValue = .init(todayUSD: 2, weekUSD: 3, perProvider: ["codexPlan": 2], partial: false)
        d.sides[2].currency = "USD"
        let card = TodayCards.build(d, running: [], now: now).first { $0.id == "spend" }!
        try checkEqual(card.segments.map(\.id), [.deepseek, .codexPlan, .siliconflow])
        try check(abs(card.segments.reduce(0) { $0 + $1.fraction } - 1) < 0.00001)
        try check(abs(card.segments[1].fraction - 20 / 31.27) < 0.00001)
    }
    test("todayTrendLastAndAccessible") {
        var d = data()
        d.trend7 = [.init(date: "10-15", iso: "2026-10-15", totalTokens: 100, byModel: ["test": 100], detail: nil)]
        let card = TodayCards.build(d, running: [task], now: now).last!
        try checkEqual(card.kind, .trend)
        try check(card.fullWidth && !card.a11y.isEmpty)
    }
    test("todayStaleResetAndBadges") {
        var d = data(); d.sides[0].quotaStale = true; d.sides[0].status = L("side.credentialInvalid")
        d.sides[0].quotaRows = [.init(id: "session", name: "会话", usedPercent: 100, isReset: false, reset: nil,
                                    windowKind: "session", resetsAt: now.addingTimeInterval(-1))]
        let c = TodayCards.build(d, running: [], now: now)[1]
        try check(c.dimmed)
        try checkEqual(c.status, L("side.credentialInvalid"))
        try checkEqual(c.compactValue, "100%")
        try checkEqual(TodayCards.planBadge("Pro 套餐"), "Pro")
        try checkEqual(TodayCards.planBadge("max"), "Max")
        try checkEqual(TodayCards.planBadge("Google AI Pro"), "Pro")
        try checkEqual(TodayCards.planBadge("ultra"), "Ultra")
        try checkEqual(TodayCards.planBadge("free"), "Free")
        try checkEqual(TodayCards.planBadge("team"), "Team")
        try checkEqual(TodayCards.planBadge("enterprise"), "Enterprise")
        try checkEqual(TodayCards.planBadge("Google Developer Program"), nil)
        try checkEqual(TodayCards.planBadge("Free (Promotional)"), "Free")
        try checkEqual(TodayCards.planBadge("Nonprofit"), nil)
        try checkEqual(TodayCards.planBadge(nil), nil)
        try check(c.a11y.contains(L("side.credentialInvalid")))
    }
    test("todayEnglishCopy") {
        let saved = L10n.lang; L10n.lang = .en; defer { L10n.lang = saved }
        var d = data(); d.apiValue = .init(todayUSD: 1, weekUSD: 2, perProvider: [:], partial: true)
        let c = TodayCards.build(d, running: [], now: now).first { $0.id == "spend" }!
        try checkEqual(c.title, "Today's spend")
        try checkEqual(c.lines.first, "Plans at API prices ≈$1.00+")
        try checkEqual(L("today.overview"), "Overview")
    }
    test("todayAddedMetadataRoundTrips") {
        var d = data(); d.mainProvider = .siliconflow; d.cardExchangeRate = 8
        d.sides[0].plan = "plus"; d.sides[0].monthCost = 3; d.sides[0].resetCredits = "reset"; d.sides[0].resetCreditsCount = 1
        let copy = try JSONDecoder().decode(AppData.self, from: JSONEncoder().encode(d))
        try checkEqual(copy.mainProvider, .siliconflow)
        try checkEqual(copy.cardExchangeRate, 8)
        try checkEqual(copy.sides[0].plan, "plus")
        try checkEqual(copy.sides[0].monthCost, 3)
        try checkEqual(copy.sides[0].resetCredits, "reset")
        try checkEqual(copy.sides[0].resetCreditsCount, 1)
    }

    test("todayCashDoesNotJoinOldDetailLine") {
        var d = data(); d.sides[2].monthCost = 4.47; d.sides[2].runwayDays = 3008
        let c = TodayCards.build(d, running: [], now: now)[3]
        try check(c.lines.isEmpty, "按量卡不应再拼接今日、本月和还能用天数")
    }

    test("todayPlanFootnotePriorityAndFullAccessibility") {
        var d = data()
        d.sides[0].resetCredits = "可手动重置 1 次（12-01 到期）"
        d.sides[0].resetCreditsCount = 1
        d.sides[0].riskText = "预计可用时间：4 小时"; d.sides[0].riskSeverity = 1
        var c = TodayCards.build(d, running: [], now: now)[1]
        try checkEqual(c.footnote, d.sides[0].riskText)
        try check(c.footnoteWarn && c.reservesFootnote)
        try checkEqual(c.title, "Codex")
        try check(c.lines.isEmpty)
        try check(c.a11y.contains("12-01") && c.a11y.contains("1"))
        d.sides[0].riskSeverity = nil
        c = TodayCards.build(d, running: [], now: now)[1]
        try checkEqual(c.footnote, "可手动重置 1 次")
        try check(!c.footnoteWarn)
        d.sides[0].resetCreditsCount = nil
        try checkEqual(TodayCards.build(d, running: [], now: now)[1].footnote, d.sides[0].resetCredits)
        d.sides[0].resetCredits = nil
        c = TodayCards.build(d, running: [], now: now)[1]
        try checkEqual(c.footnote, nil)
        try check(c.reservesFootnote)
        d.sides[0].status = L("side.credentialInvalid")
        c = TodayCards.build(d, running: [], now: now)[1]
        try check(c.dimmed && c.footnoteWarn)
        try checkEqual(c.footnote, L("side.credentialInvalid"))
    }
    test("todayEmptyPlanShowsQuotaNoteWithoutWarning") {
        var d = data()
        d.sides[1].quotaNote = "还没读到额度"
        d.sides[1].resetCreditsCount = 1
        let c = TodayCards.build(d, running: [], now: now)[2]
        try check(c.windows.isEmpty && c.status == nil)
        try checkEqual(c.footnote, d.sides[1].quotaNote)
        try check(c.footnoteMultiline && !c.footnoteWarn)
    }
    test("todayClaudeLoginHintTakesPriorityOverShortStatus") {
        var d = data()
        d.sides[1].quotaNote = L("cli.needsLogin")
        d.sides[1].status = L("side.credentialInvalid")
        let c = TodayCards.build(d, running: [], now: now)[2]
        try check(c.windows.isEmpty)
        try checkEqual(c.footnote, d.sides[1].quotaNote)
        try check(c.footnoteMultiline && c.footnoteWarn)
    }
    // 用户 11/6：Claude Code 退出登录时卡片只写「读不到记录」，看不到原因——上面留状态，底注写原因（怎么重新登录）
    test("todayEmptyPlanNoRecordsShowsReason") {
        var d = data()
        d.sides[1].status = L("side.noRecords")
        d.sides[1].quotaNote = "Claude Code 没有用 Pro/Max 账号登录：在终端运行 claude，输入 /login"
        let c = TodayCards.build(d, running: [], now: now)[2]
        try checkEqual(c.status, L("side.noRecords"))
        try checkEqual(c.footnote, d.sides[1].quotaNote)
        try checkEqual(TodayCards.bottomNote(c), d.sides[1].quotaNote)
        try check(c.a11y.contains("/login"), c.a11y)
        // 没有原因时照旧
        d.sides[1].quotaNote = nil
        try checkEqual(TodayCards.build(d, running: [], now: now)[2].footnote, L("side.noRecords"))
    }
    // 11-18：Claude 登录失效时保留旧读数，但不带倒计时（旧数据的倒计时会误导），并且一行写完
    test("todayClaudeLoginKeepsOldQuotaWithoutCountdown") {
        var d = data()
        d.sides[1].quotaNote = L("cli.needsLogin")
        d.sides[1].status = L("side.credentialInvalid")
        d.sides[1].quotaRows = [.init(id: "session", name: "会话", usedPercent: 41, isReset: false, reset: nil, windowKind: "session"),
                                .init(id: "weekly", name: "本周", usedPercent: 23, isReset: false, reset: nil, windowKind: "weekly")]
        let c = TodayCards.build(d, running: [], now: now)[2]
        try checkEqual(c.loginHint, L("cli.needsLogin"))
        try checkEqual(c.loginOldQuota, L("today.loginOldQuota", L("today.session") + " " + c.windows[0].value + L("today.loginOldQuotaSep") + L("today.weekly") + " " + c.windows[1].value))
        try check(c.dimmed)
    }
    test("todayClaudeLoginWithoutQuotaHasNoOldReading") {
        var d = data()
        d.sides[1].quotaNote = L("cli.needsLogin")
        d.sides[1].status = L("side.credentialInvalid")
        let c = TodayCards.build(d, running: [], now: now)[2]
        try checkEqual(c.loginOldQuota, nil)
    }
    test("todayPlanWithWindowsKeepsSingleLineFootnote") {
        var d = data()
        d.sides[1].quotaNote = L("cli.needsLogin")
        d.sides[1].resetCreditsCount = 1
        d.sides[1].quotaRows = [.init(id: "session", name: "会话", usedPercent: 20, isReset: false, reset: nil, windowKind: "session")]
        let c = TodayCards.build(d, running: [], now: now)[2]
        try checkEqual(c.footnote, "可手动重置 1 次")
        try check(!c.footnoteMultiline && !c.footnoteWarn)
    }
    test("todayCashStatsRunwayAndAccessibility") {
        var d = data(); d.sides[2].monthCost = 4.47
        for (days, chip, warn) in [(4.0, "约 4 天", true), (20.0, "约 20 天", false), (30.0, "约 30 天", false), (7.0, "约 7 天", false), (3008.0, "", false)] {
            d.sides[2].runwayDays = days
            let c = TodayCards.build(d, running: [], now: now)[3]
            try checkEqual(c.stats.map { $0.label }, ["今日", "本月"])
            try checkEqual(c.stats.map { $0.value }, ["¥0.50", "¥4.47"])
            try checkEqual(c.runwayChip, chip.isEmpty ? nil : chip)
            try checkEqual(c.runwayWarn, warn)
            try check(c.a11y.contains(String(Int(days))))
            try checkEqual(c.compactDetail, "今日 ¥0.50")
            try check(c.footnote == nil && !c.reservesFootnote)
        }
        d.sides[2].runwayDays = nil; d.sides[2].monthCost = nil
        try checkEqual(TodayCards.build(d, running: [], now: now)[3].stats.count, 1)
        d.sides[2].todayCost = nil
        var c = TodayCards.build(d, running: [], now: now)[3]
        try check(c.stats.isEmpty && c.runwayChip == nil)
        d.sides[2].status = L("side.credentialInvalid")
        c = TodayCards.build(d, running: [], now: now)[3]
        try checkEqual(c.footnote, L("side.credentialInvalid"))
        try check(c.footnoteWarn)
    }
    test("todayNewEnglishCopy") {
        let saved = L10n.lang; L10n.lang = .en; defer { L10n.lang = saved }
        var d = data(); d.sides[2].runwayDays = 4; d.sides[2].monthCost = 1
        d.sides[0].resetCreditsCount = 1
        let cards = TodayCards.build(d, running: [], now: now)
        try checkEqual(cards[1].footnote, "1 manual reset left")
        try checkEqual(cards[3].runwayChip, "About 4 days")
        try checkEqual(cards[3].stats.map { $0.label }, ["Today", "Month"])
    }

    test("todayResetCountMapsFromQuota") {
        var snapshot = snap(now)
        snapshot.quota = Quota(plan: "plus", windows: [
            QuotaWindow(kind: .session, usedPercent: 20, resetsAt: now.addingTimeInterval(3600), windowMinutes: nil)
        ], observedAt: now, resetCredits: ResetCredits(available: 1, expiresAt: now.addingTimeInterval(86400)))
        let state = PlatformState(id: .codexPlan, snapshot: snapshot, burn: nil, status: .ok)
        let mapped = AppDataMapping.appData(main: state, others: [], now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        try checkEqual(mapped.quota?.resetCreditsCount, 1)
        try checkEqual(AppDataMapping.side(state, now: now).resetCreditsCount, 1)
        let card = TodayCards.build(mapped, running: [], now: now)[0]
        try checkEqual(card.footnote, "可手动重置 1 次")
        try check(card.a11y.contains("到期"))
    }

}
