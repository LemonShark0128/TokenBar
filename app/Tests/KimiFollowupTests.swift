import Foundation

@MainActor
func registerKimiFollowupTests() {
    let tz = TimeZone(secondsFromGMT: 0)!
    func date(_ s: String) -> Date { ISODate.parse(s)! }
    func sample(_ time: String, _ balance: Decimal, _ id: ProviderID = .kimi) -> Sample {
        Sample(provider: id, t: date(time), balance: balance, cumulativeCost: nil, currency: .cny)
    }
    func state(_ id: ProviderID, _ source: SnapshotSource, currency: Currency = .cny) -> PlatformState {
        let snapshot = ProviderSnapshot(provider: id, balance: Money(amount: 8, currency: currency),
            today: Money(amount: 2, currency: currency), month: Money(amount: 3, currency: currency),
            byModel: [], trend7: [], source: source, fetchedAt: date("2026-11-20T08:00:00Z"), credential: .ok)
        return PlatformState(id: id, snapshot: snapshot, burn: nil, status: .ok, lastSampleAt: nil)
    }
    func data(_ main: PlatformState, _ others: [PlatformState] = []) -> AppData {
        AppDataMapping.appData(main: main, others: others, now: date("2026-11-20T08:00:00Z"), timeZone: tz)
    }
    test("kimiGapAllocatesBothDaysAndConservesTotal") {
        let samples = [sample("2026-11-19T22:00:00Z", 10), sample("2026-11-20T08:00:00Z", 8)]
        let result = BalanceSpendEstimate.estimate(samples: samples, now: samples[1].t, timeZone: tz, currency: .cny)
        try checkEqual(result.today, Decimal(string: "1.6")!)
        try checkEqual(result.week[5].cost?.amount, Decimal(string: "0.4")!)
        try checkEqual(result.month, 2)
        try checkEqual(result.week.compactMap { $0.cost?.amount }.reduce(0, +), 2)
    }
    test("kimiShortGapAndExactTwoHoursKeepEndpointRule") {
        for hours in [1, 2] {
            let end = date("2026-11-20T01:00:00Z")
            let samples = [Sample(provider: .kimi, t: end.addingTimeInterval(Double(-hours * 3600)), balance: 10, cumulativeCost: nil, currency: .cny),
                           sample("2026-11-20T01:00:00Z", 8)]
            let result = BalanceSpendEstimate.estimate(samples: samples, now: end, timeZone: tz, currency: .cny)
            try checkEqual(result.today, 2)
            try checkEqual(result.week[5].cost?.amount, 0)
        }
    }
    test("kimiGapAcrossMonthAndRecharge") {
        let samples = [sample("2026-10-31T22:00:00Z", 10), sample("2026-11-01T08:00:00Z", 8), sample("2026-11-01T09:00:00Z", 20)]
        let result = BalanceSpendEstimate.estimate(samples: samples, now: samples[2].t, timeZone: tz, currency: .cny)
        try checkEqual(result.month, Decimal(string: "1.6")!)
        try checkEqual(result.today, result.month)
    }
    test("kimiCacheMatchesFullHistoryAndOnlyReadsEightDaysOnPoll") {
        var cache = BalanceSpendCache()
        var all = [sample("2026-10-31T22:00:00Z", 100), sample("2026-11-01T08:00:00Z", 98),
                   sample("2026-11-19T22:00:00Z", 80), sample("2026-11-20T08:00:00Z", 78)]
        var reads: [Date] = []
        func load(_ start: Date) -> [Sample] {
            reads.append(start)
            return all.filter { $0.t < start }.suffix(1) + all.filter { $0.t >= start }
        }
        let now = date("2026-11-20T08:00:00Z")
        let first = cache.estimate(id: .kimi, now: now, timeZone: tz, currency: .cny, load: load)
        let full = BalanceSpendEstimate.estimate(samples: all, now: now, timeZone: tz, currency: .cny)
        try check(abs(first.month - full.month) < Decimal(string: "0.000000001")!)
        try checkEqual(first.week, full.week)
        try checkEqual(reads, [date("2026-11-12T00:00:00Z"), date("2026-11-01T00:00:00Z")])
        all.append(sample("2026-11-20T09:00:00Z", 77))
        reads = []
        let next = cache.estimate(id: .kimi, now: all.last!.t, timeZone: tz, currency: .cny, load: load)
        try checkEqual(reads.count, 1)
        try checkEqual(next.month, first.month + 1)
        cache.remove(.kimi)
        reads = []
        _ = cache.estimate(id: .kimi, now: now, timeZone: tz, currency: .cny, load: load)
        try checkEqual(reads.count, 2)
    }
    test("kimiCacheInvalidatesDayMonthZoneAndProvider") {
        var cache = BalanceSpendCache()
        let all = [sample("2026-10-31T22:00:00Z", 100), sample("2026-11-20T08:00:00Z", 80),
                   sample("2026-11-21T08:00:00Z", 78), sample("2026-12-01T08:00:00Z", 70)]
        for (id, time, zone) in [(ProviderID.kimi, "2026-11-20T08:00:00Z", tz), (.kimi, "2026-11-21T08:00:00Z", tz),
                                 (.deepseek, "2026-11-21T08:00:00Z", tz), (.kimi, "2026-11-21T08:00:00Z", TimeZone(secondsFromGMT: 28800)!),
                                 (.kimi, "2026-12-01T08:00:00Z", tz)] {
            let now = date(time)
            let result = cache.estimate(id: id, now: now, timeZone: zone, currency: .cny) { start in
                Array(all.filter { $0.t < start }.suffix(1)) + all.filter { $0.t >= start }
            }
            let full = BalanceSpendEstimate.estimate(samples: all, now: now, timeZone: zone, currency: .cny)
            try check(abs(result.month - full.month) < Decimal(string: "0.000000001")!)
            try checkEqual(result.today, full.today)
            try checkEqual(result.week, full.week)
        }
    }
    test("kimiCacheClosesHistoryAfterFirstPostMidnightSample") {
        var cache = BalanceSpendCache()
        var all = [sample("2026-11-19T22:00:00Z", 10)]
        func estimate(_ now: Date) -> BalanceSpendEstimate.Result {
            cache.estimate(id: .kimi, now: now, timeZone: tz, currency: .cny) { _ in all }
        }
        _ = estimate(date("2026-11-20T00:00:00Z"))
        all.append(sample("2026-11-20T08:00:00Z", 8))
        let result = estimate(all[1].t)
        try checkEqual(result.month, 2)
        try checkEqual(result.today, Decimal(string: "1.6")!)
    }
    test("kimiSampleWindowIncludesPredecessorAndBoundary") {
        let db = try SampleStore(path: ":memory:")
        let all = [sample("2026-10-20T00:00:00Z", 20), sample("2026-11-01T00:00:00Z", 10), sample("2026-11-20T08:00:00Z", 8)]
        for s in all { try db.append(s) }
        try db.append(sample("2026-11-19T00:00:00Z", 100, .deepseek))
        try checkEqual(try db.balanceSamples(.kimi, since: all[1].t), all)
        try checkEqual(try db.balanceSamples(.kimi, since: date("2026-11-12T00:00:00Z")), Array(all.suffix(2)))
    }
    test("kimiTotalsMarkMainAndSecondaryEstimates") {
        try check(data(state(.kimi, .balanceEstimate)).totalIsApprox)
        try check(data(state(.deepseek, .bill), [state(.kimi, .balanceEstimate)]).totalIsApprox)
        try check(!data(state(.deepseek, .bill)).totalIsApprox)
        try check(data(state(.deepseek, .bill, currency: .usd)).totalIsApprox)
        var removed = state(.kimi, .balanceEstimate); removed.status = .notAdded
        try check(!data(state(.deepseek, .bill), [removed]).totalIsApprox)
    }
    test("kimiMenuMarksOnlyKnownEstimatedCostAndKeepsSourceTag") {
        try checkEqual(BalanceEstimatePresentation.menuTitle("¥2.00", mode: "cost", source: "余额估算", hasAmount: true), "≈¥2.00")
        for (mode, source, amount) in [("balance", "余额估算", true), ("cost", "平台账单", true), ("cost", "余额估算", false)] {
            try checkEqual(BalanceEstimatePresentation.menuTitle("¥2.00", mode: mode, source: source, hasAmount: amount), "¥2.00")
        }
        try checkEqual(sourceTagLabel(costSourceTag("余额估算")), "估算")
    }
    test("kimiTokenPresentationHidesOnlyEstimateOnlyData") {
        let single = data(state(.kimi, .balanceEstimate))
        try check(!BalanceEstimatePresentation.showsTokenTrend(single))
        try check(BalanceEstimatePresentation.showsTokenTrend(data(state(.kimi, .balanceEstimate), [state(.deepseek, .bill)])))
        try check(BalanceEstimatePresentation.showsTokenTrend(data(state(.deepseek, .bill))))
        let tip = BalanceEstimatePresentation.usageTooltip(source: "余额估算", tokens: 0, freshness: "刚刚更新")
        try check(!tip.lowercased().contains("token"))
        try check(tip.contains("刚刚更新"))
        try checkEqual(BalanceEstimatePresentation.usageTooltip(source: "平台账单", tokens: 0, freshness: "新"), L("menu.tip.usage", cnCount(0), "新"))
    }
    test("kimiBusinessFailuresClassifyAuthCaseInsensitively") {
        for body in [#"{"code":401}"#, #"{"code":403}"#, #"{"code":5,"message":"AUTH failed"}"#,
                     #"{"status":false,"message":"invalid Key"}"#, #"{"code":0,"status":false,"error":{"message":"TOKEN expired"}}"#] {
            guard case .failure(.auth) = KimiProvider.parseBalance(Data(body.utf8)) else { throw TestFailure(description: "应归为 auth") }
        }
        for body in [#"{"code":5}"#, #"{"status":false,"message":"busy"}"#] {
            guard case .failure(.network) = KimiProvider.parseBalance(Data(body.utf8)) else { throw TestFailure(description: "应归为 network") }
        }
        guard case .success = KimiProvider.parseBalance(Data(#"{"code":0,"status":true,"message":"token ok","data":{"available_balance":8}}"#.utf8)) else { throw TestFailure(description: "成功不能误判") }
    }
}
