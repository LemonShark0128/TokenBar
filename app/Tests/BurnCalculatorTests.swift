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
        try checkEqual(BurnCalculator.spent(costSamples([100, 101, 2], spanMin: 60)), 3)
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
}
