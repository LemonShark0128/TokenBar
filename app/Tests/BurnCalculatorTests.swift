import Foundation

@MainActor
func registerBurnCalculatorTests() {
    let now = Date(timeIntervalSince1970: 1_792_022_400)
    /// n 个点均匀分布在 [now - spanMin 分钟, now]
    func costSamples(_ costs: [Decimal], spanMin: Double) -> [Sample] {
        costs.enumerated().map { i, c in
            Sample(provider: .deepseek,
                   t: now.addingTimeInterval(-spanMin * 60 + spanMin * 60 * Double(i) / Double(max(costs.count - 1, 1))),
                   balance: nil, cumulativeCost: c, currency: .cny)
        }
    }
    func stats(_ s: [Sample], tank: Decimal? = nil, week: [Decimal] = Array(repeating: 1, count: 7)) -> BurnStats {
        BurnCalculator.stats(samples: s, now: now, tankRemaining: tank, weekCostByDay: week)
    }

    test("spentAcrossMonthReset") {
        // 10-31 23:20 / 23:50 → 11-01 00:20（东八区）：跨月变少是月初清零，加新值
        let tz = TimeZone(secondsFromGMT: 28800)!
        let midnight = Date(timeIntervalSince1970: 1_793_462_400)   // 2026-11-01 00:00 +08:00
        let s = [(-40.0, Decimal(100)), (-10, 101), (20, 2)].map {
            Sample(provider: .deepseek, t: midnight.addingTimeInterval($0.0 * 60), balance: nil, cumulativeCost: $0.1, currency: .cny)
        }
        try checkEqual(BurnCalculator.spent(s, timeZone: tz), 3)
        // 同一组时刻按 UTC 算都在 10 月：变少不是清零，记 0
        try checkEqual(BurnCalculator.spent(s, timeZone: TimeZone(secondsFromGMT: 0)!), 1)
        // 上月很少（¥2）、新月第一次读已 ¥5：新月花的是 5，不是 3
        let small = [(-10.0, Decimal(2)), (20, 5)].map {
            Sample(provider: .deepseek, t: midnight.addingTimeInterval($0.0 * 60), balance: nil, cumulativeCost: $0.1, currency: .cny)
        }
        try checkEqual(BurnCalculator.spent(small, timeZone: tz), 5)
    }
    test("spentSameMonthDropIsNotReset") {
        // 同一个月里本月累计变少（退款、账单修正）：原来当清零算成花了 ¥99.80
        try checkEqual(BurnCalculator.spent(costSamples([100, Decimal(string: "99.8")!, 100.3], spanMin: 60)), Decimal(string: "0.5")!)
        let r = stats(costSamples([100, 100.1, 100.2, Decimal(string: "99.8")!, 99.9, 100, 100.1], spanMin: 60), week: Array(repeating: 10, count: 7))
        try checkEqual(r.perHourRecent, Decimal(string: "0.5")!)
        try check(!r.spike)
    }
    test("spentMonotonic") {
        try checkEqual(BurnCalculator.spent(costSamples([1, 3, 6], spanMin: 60)), 5)
    }
    test("recentRequires45Minutes") {
        try check(stats(costSamples([10, 10.5, 11, 11.2, 11.3, 11.4, 11.5], spanMin: 40)).perHourRecent == nil)
    }
    test("recentRequiresSixPoints") {
        try check(stats(costSamples([10, 10.5, 11, 11.1, 11.2], spanMin: 50)).perHourRecent == nil)
    }
    test("recentRate") {
        let r = stats(costSamples([10, 10.2, 10.4, 10.6, 10.8, 11.0, 11.2], spanMin: 60)).perHourRecent
        try checkEqual(r, Decimal(string: "1.2")!)
    }
    test("spikeThreshold") {
        let week = Array(repeating: Decimal(15), count: 7)
        let fast = stats(costSamples([0, 0.4, 0.8, 1.2, 1.6, 1.8, 2.0], spanMin: 60), week: week)
        try checkEqual(fast.perHourRecent, Decimal(2))
        try check(fast.spike, "2.0×24=48 > 45 应判为飙升")
        let slow = stats(costSamples([0, 0.3, 0.6, 0.9, 1.2, 1.5, 1.8], spanMin: 60), week: week)
        try check(!slow.spike, "1.8×24=43.2 不应判为飙升")
    }
    test("spikeIgnoresTinyRates") {
        // 平时几乎不花：7 天日均 ¥0.01，近 1 小时 ¥0.06/时 是平均的上百倍，但低于 ¥0.2/时，不算异常
        let week = Array(repeating: Decimal(string: "0.01")!, count: 7)
        let tiny = stats(costSamples([0, 0.01, 0.02, 0.03, 0.04, 0.05, 0.06], spanMin: 60), week: week)
        try check(!tiny.spike, "时速 0.06 < 0.2 不应判为飙升")
        let real = stats(costSamples([0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6], spanMin: 60), week: week)
        try check(real.spike, "时速 0.6 ≥ 0.2 且远超平均，应判为飙升")
    }
    test("rechargeIsNotNegativeSpend") {
        let balances: [Decimal] = [30, 28, 25, 75, 74, 73, 72]
        let s = balances.enumerated().map { i, b in
            Sample(provider: .deepseek, t: now.addingTimeInterval(-3600 + 600 * Double(i)),
                   balance: b, cumulativeCost: nil, currency: .cny)
        }
        let r = stats(s).perHourRecent
        try checkEqual(r, Decimal(8))
    }
    test("runway") {
        let st = stats([], tank: Decimal(string: "27.07")!, week: Array(repeating: Decimal(string: "5.57")!, count: 7))
        var v = st.runwayDays ?? -1, rounded = Decimal()
        NSDecimalRound(&rounded, &v, 1, .plain)
        try checkEqual(rounded, Decimal(string: "4.9")!)
    }
    test("runwayNilWithoutTankOrSpend") {
        try check(stats([], tank: nil).runwayDays == nil)
        try check(stats([], tank: 10, week: Array(repeating: 0, count: 7)).runwayDays == nil)
    }
    test("dayRateFallsBackWhenRecentMissing") {
        let s = costSamples([0, 6, 12], spanMin: 600)   // 10 小时花 12 → 1.2/时；近 1 小时点不够
        let st = stats(s)
        try check(st.perHourRecent == nil)
        try checkEqual(st.perHourDay, Decimal(string: "1.2")!)
    }

    // 日均按「有数据的天数」除（新账号头一周不再偏乐观）
    let day: TimeInterval = 86400
    func since(_ seconds: TimeInterval, _ week: [Decimal], tank: Decimal? = nil,
               samples: [Sample] = []) -> BurnStats {
        BurnCalculator.stats(samples: samples, now: now, tankRemaining: tank, weekCostByDay: week,
                             observedSince: now.addingTimeInterval(-seconds))
    }
    test("avgWithoutObservedSinceKeepsSevenDays") {
        try checkEqual(stats([], week: Array(repeating: 1, count: 7)).avgPerDayWeek, 1)
        try checkEqual(stats([], week: [0, 0, 0, 0, 0, 0, 7]).avgPerDayWeek, 1)
        try check(stats([], week: [0, 0, 0, 0, 0, 0, 7]).enoughData)
    }
    test("avgNewAccountTwoDays") {
        let st = since(2 * day, [0, 0, 0, 0, 0, 10, 10], tank: 100)
        try checkEqual(st.avgPerDayWeek, 10)
        try checkEqual(st.runwayDays, 10)
        try check(st.enoughData)
    }
    test("avgBillHistoryWinsForJustAddedPlatform") {
        let st = since(3600, [0, 0, 0, 5, 5, 5, 5], tank: 50)
        try checkEqual(st.avgPerDayWeek, 5)
        try check(st.enoughData)
        try checkEqual(st.runwayDays, 10)
    }
    test("avgNotEnoughDataUnderOneDay") {
        let fast = costSamples([0, 0.4, 0.8, 1.2, 1.6, 1.8, 2.0], spanMin: 60)
        let st = since(3600, [0, 0, 0, 0, 0, 0, 3], tank: 100, samples: fast)
        try check(!st.enoughData)
        try check(st.runwayDays == nil)
        try check(!st.spike, "数据不足 1 天不判异常")
        try checkEqual(st.avgPerDayWeek, 3)
        try check(Runway.payg(balance: 100, burn: st) == nil, "数据不足时不写续航")
    }
    test("avgEstimateCrossingMidnightIsNotHistory") {
        // 余额估算平台 23:30 加进来，0:30 时两个日历日都有花费，但只记了 1 小时
        let st = BurnCalculator.stats(samples: [], now: now, tankRemaining: 100, weekCostByDay: [0, 0, 0, 0, 0, 1, 1],
                                      observedSince: now.addingTimeInterval(-3600), billHistory: false)
        try check(!st.enoughData)
        try check(st.runwayDays == nil)
        try check(Runway.payg(balance: 100, burn: st) == nil)
        let later = BurnCalculator.stats(samples: [], now: now, tankRemaining: 100, weekCostByDay: [0, 0, 0, 0, 2, 2, 2],
                                         observedSince: now.addingTimeInterval(-2.5 * day), billHistory: false)
        try checkEqual(later.avgPerDayWeek, 2)
        try check(later.enoughData)
    }
    test("avgOldPlatformLeadingZerosAreReal") {
        try checkEqual(since(30 * day, [0, 0, 0, 0, 0, 0, 7]).avgPerDayWeek, 1)
    }
    test("avgNoSpendIsZero") {
        let st = since(3 * day, Array(repeating: 0, count: 7), tank: 10)
        try checkEqual(st.avgPerDayWeek, 0)
        try check(st.runwayDays == nil)
    }
    test("avgGapsInsideWindow") {
        try checkEqual(since(30 * day, [0, 0, 4, 0, 0, 4, 6]).avgPerDayWeek, 2)
    }
    test("sampleStoreEarliest") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-earliest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SampleStore(path: dir.appendingPathComponent("s.sqlite").path)
        try check(try store.earliest(.deepseek) == nil)
        try store.append(Sample(provider: .deepseek, t: now, balance: 5, cumulativeCost: nil, currency: .cny))
        try store.append(Sample(provider: .deepseek, t: now.addingTimeInterval(-day), balance: 6, cumulativeCost: nil, currency: .cny))
        try store.append(Sample(provider: .siliconflow, t: now.addingTimeInterval(-9 * day), balance: 6, cumulativeCost: nil, currency: .cny))
        try checkEqual(try store.earliest(.deepseek), now.addingTimeInterval(-day))
    }
}
