import Foundation

@MainActor
func registerMenuBarCellsTests() {
    test("menuClaudeLoginLabelAndTooltipInBothLanguages") {
        var cell = MenuBarCell(id: .claudePlan, kind: .quota(session: 80, weekly: 60, pace: nil),
                               severity: nil, stale: true, exhausted: false)
        cell.loginHint = L("cli.needsLogin")
        try checkEqual(cell.primaryText, L("menu.needsLogin"))
        try checkEqual(L10n.text("menu.needsLogin", [], lang: .en), "Sign in")
        try check(MenuBarCells.tooltip([cell], now: Date()).contains(cell.loginHint!))
    }

    func sample() -> AppData {
        let rows = [AppData.QuotaRow(id: "session", name: "", usedPercent: 53, isReset: false, reset: nil, paceRemainingPercent: 50, countdown: "3小时14分"),
                    AppData.QuotaRow(id: "weekly", name: "", usedPercent: 21, isReset: false, reset: nil)]
        return AppData(nowLocal: "", balance: .init(cny: 27.07, source: "平台", status: "可用", ageS: 0),
                       today: .init(costCny: 2, tokens: 0, source: "平台账单"), month: .init(costCny: 0, tokens: 0, source: nil),
                       models: [], trend7: [], burn: .init(cnyPerHourRate: nil, cnyPerDayRate: nil, avgCnyPerDayWeek: 4, runwayDays: 4, spike: false),
                       sides: [.init(id: "claudePlan", name: "Claude", tank: nil, currency: "PCT", todayCost: nil, status: L("side.ok"), quotaRows: rows),
                               .init(id: "codexPlan", name: "Codex", tank: nil, currency: "PCT", todayCost: nil, status: L("side.ok"), quotaRows: rows)])
    }
    test("menuCellsThreePlatformsAndOrder") {
        let cells = MenuBarCells.cells(sample(), main: .deepseek)
        try checkEqual(cells.map(\.id), [.deepseek, .claudePlan, .codexPlan])
        try checkEqual(cells[0].kind, .payg(runwayFraction: 4.0/7, todayFraction: 0.5, balanceText: "¥27.07"))
        try checkEqual(cells[1].kind, .quota(session: 47, weekly: 79, pace: 50))
        try checkEqual(cells[1].severity, nil)
    }
    test("menuCellsSingleWindowAndReset") {
        var d = sample(); d.sides[0].quotaRows.removeFirst(); d.sides[0].quotaRows[0].isReset = true
        try checkEqual(MenuBarCells.cells(d, main: .deepseek)[1].kind, .quota(session: nil, weekly: 100, pace: nil))
    }
    test("menuCellsExhaustedAndStale") {
        var d = sample(); d.sides[0].quotaRows[1].usedPercent = 100; d.sides[0].quotaStale = true
        let c = MenuBarCells.cells(d, main: .deepseek)[1]
        try check(c.exhausted && c.stale); try checkEqual(c.severity, .danger)
    }
    test("menuCellsUnknownFractions") {
        var d = sample(); d.burn = nil; d.today.source = "只有余额"
        try checkEqual(MenuBarCells.cells(d, main: .deepseek)[0].kind, .payg(runwayFraction: nil, todayFraction: nil, balanceText: "¥27.07"))
    }
    test("menuCellsPaygThresholdAndTwelveHours") {
        var d = sample()
        try checkEqual(MenuBarCells.cells(d, main: .deepseek, lowAlerts: [.deepseek: 30])[0].severity, .warn)
        d.burn?.runwayDays = 0.4
        try checkEqual(MenuBarCells.cells(d, main: .deepseek)[0].severity, .danger)
        d.burn = nil; d.balance.cny = 0
        try checkEqual(MenuBarCells.cells(d, main: .deepseek)[0].severity, .danger)
    }
    test("menuCellsTooltipChinese") {
        let cells = MenuBarCells.cells(sample(), main: .deepseek)
        try checkEqual(MenuBarCells.tooltip(Array(cells.prefix(2)), now: Date()), "DeepSeek 余额 ¥27.07，还能用约 4 天 · Claude 会话剩 47%（↻3小时14分）、本周剩 79%")
    }
    test("menuCellsTooltipEnglishStale") {
        let saved = L10n.lang; L10n.lang = .en; defer { L10n.lang = saved }
        var d = sample(); d.sides[0].quotaRows[0].countdown = "3h 14m"; d.sides[0].quotaStale = true
        let c = MenuBarCells.cells(d, main: .deepseek)[1]
        try checkEqual(MenuBarCells.tooltip([c], now: Date()), "Claude session 47% left (↻3h 14m), week 79% left (data stale)")
    }
    test("menuCellsMappedQuotaMainAndPaygSide") {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let quota = Quota(plan: nil, windows: [
            QuotaWindow(kind: .session, usedPercent: 53, resetsAt: now.addingTimeInterval(11640), windowMinutes: 300),
            QuotaWindow(kind: .weekly, usedPercent: 21, resetsAt: now.addingTimeInterval(86400), windowMinutes: 10080)
        ], observedAt: now)
        let main = PlatformState(id: .claudePlan, snapshot: ProviderSnapshot(provider: .claudePlan, balance: nil,
            today: nil, month: nil, byModel: [], trend7: [], source: .quota, fetchedAt: now, credential: .ok, quota: quota),
            burn: nil, status: .ok)
        let payg = PlatformState(id: .deepseek, snapshot: ProviderSnapshot(provider: .deepseek,
            balance: Money(amount: 27.07, currency: .cny), today: Money(amount: 2, currency: .cny), month: nil,
            byModel: [], trend7: [], source: .bill, fetchedAt: now, credential: .ok),
            burn: BurnStats(perHourRecent: nil, perHourDay: nil, avgPerDayWeek: 4, runwayDays: 4, spike: false), status: .ok)
        let absent = PlatformState(id: .siliconflow, snapshot: nil, burn: nil, status: .notAdded)
        let d = AppDataMapping.appData(main: main, others: [payg, absent], now: now, timeZone: .current)
        let cells = MenuBarCells.cells(d, main: .claudePlan, now: now)
        try checkEqual(cells.map(\.id), [.claudePlan, .deepseek])
        guard case .quota(let session, let weekly, let pace) = cells[0].kind else {
            throw TestFailure(description: "Expected quota cell")
        }
        try checkEqual(session, 47); try checkEqual(weekly, 79)
        try check(abs((pace ?? -1) - 11640.0 / 18000 * 100) < 0.000001)
        try checkEqual(cells[1].kind, .payg(runwayFraction: 4.0/7, todayFraction: 0.5, balanceText: "¥27.07"))
        try check(MenuBarCells.tooltip(cells, now: now).contains("↻3小时14分"))
        let back = try JSONDecoder().decode(AppData.Side.self, from: JSONEncoder().encode(d.sides[0]))
        try checkEqual(back, d.sides[0])
    }
    test("menuCellsFetchFailureAndOldPayg") {
        let now = Date()
        let failed = PlatformState(id: .siliconflow, snapshot: nil, burn: nil, status: .offline)
        let side = AppDataMapping.side(failed, now: now)
        var d = sample(); d.sides = [side]; d.balance.ageS = 601
        try check(MenuBarCells.cells(d, main: .deepseek).allSatisfy(\.stale))
        try checkEqual(MenuBarCells.cells(d, main: .deepseek)[1].kind,
                       .payg(runwayFraction: nil, todayFraction: nil, balanceText: nil))
    }
    test("menuCellsFractionsClampAndZeroAverage") {
        var d = sample(); d.burn?.runwayDays = 20; d.today.costCny = 10
        try checkEqual(MenuBarCells.cells(d, main: .deepseek)[0].kind,
                       .payg(runwayFraction: 1, todayFraction: 1, balanceText: "¥27.07"))
        d.burn?.avgCnyPerDayWeek = 0
        try checkEqual(MenuBarCells.cells(d, main: .deepseek)[0].kind,
                       .payg(runwayFraction: 1, todayFraction: nil, balanceText: "¥27.07"))
    }
    test("menuCellsLegacySideDecode") {
        let side = try JSONDecoder().decode(AppData.Side.self,
            from: Data(#"{"id":"deepseek","name":"DeepSeek","currency":"CNY","status":"正常"}"#.utf8))
        try checkEqual(side.runwayDays, nil); try checkEqual(side.avgCnyPerDayWeek, nil)
        try check(!side.dataStale)
    }
    test("menuCellsResetAtNowAndSessionOnly") {
        let now = Date(timeIntervalSince1970: 2_000_000)
        var d = sample(); d.sides[0].quotaRows.removeLast()
        d.sides[0].quotaRows[0].resetsAt = now
        d.sides[0].quotaRows[0].paceRemainingPercent = nil
        let c = MenuBarCells.cells(d, main: .deepseek, now: now)[1]
        try checkEqual(c.kind, .quota(session: 100, weekly: nil, pace: nil))
        try checkEqual(MenuBarCells.tooltip([c], now: now), "Claude 会话剩 100%")
    }
    test("menuCellsTooltipRunwayUnderOneDay") {
        var d = sample(); d.burn?.runwayDays = 0.25
        let c = MenuBarCells.cells(d, main: .deepseek)[0]
        try checkEqual(MenuBarCells.tooltip([c], now: Date()), "DeepSeek 余额 ¥27.07，还能用约 6 小时")
        d.burn?.runwayDays = -0.5
        try checkEqual(MenuBarCells.tooltip([MenuBarCells.cells(d, main: .deepseek)[0]], now: Date()), "DeepSeek 余额 ¥27.07，还能用不到 1 小时")
        let saved = L10n.lang; L10n.lang = .en; defer { L10n.lang = saved }
        d.burn?.runwayDays = 0.25
        try checkEqual(MenuBarCells.tooltip([MenuBarCells.cells(d, main: .deepseek)[0]], now: Date()), "DeepSeek balance ¥27.07, about 6 hours left")
    }
}
