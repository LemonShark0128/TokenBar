import Foundation

// Kimi：余额解析 + 按余额变化估算花费（11-05 新平台）
@MainActor
func registerKimiProviderTests() {
    test("kimiParsesAvailableBalance") {
        let ok = #"{"code":0,"data":{"available_balance":49.58894,"voucher_balance":46.58893,"cash_balance":3.00001},"scode":"0x0","status":true}"#
        let m = try KimiProvider.parseBalance(Data(ok.utf8)).get()
        try checkEqual(m.currency, .cny)
        try checkEqual(m.amount, Decimal(string: "49.58894")!)
        if case .success = KimiProvider.parseBalance(Data(#"{"code":5,"status":false}"#.utf8)) { throw TestFailure(description: "业务码非 0 应失败") }
        if case .success = KimiProvider.parseBalance(Data(#"{"code":0,"data":{}}"#.utf8)) { throw TestFailure(description: "缺字段应失败") }
    }
    test("kimiRegistryCapabilities") {
        let c = ProviderRegistry.capabilities(.kimi)
        try check(c.hasBalance && c.estimatesSpendFromBalance && c.meter == .money)
        try check(ProviderRegistry.all.contains(.kimi))
        try check(!ProviderRegistry.capabilities(.deepseek).estimatesSpendFromBalance)
    }
    test("balanceSpendEstimateTodayMonthWeek") {
        let tz = TimeZone(secondsFromGMT: 28800)!
        let now = Date(timeIntervalSince1970: 1_792_072_800)   // 2026-10-15 22:00 +08
        func s(_ back: TimeInterval, _ b: String) -> Sample {
            Sample(provider: .kimi, t: now.addingTimeInterval(-back), balance: Decimal(string: b), cumulativeCost: nil, currency: .cny)
        }
        // 昨天 23:00 → 今天：10 → 9（跨零点算今天）→ 充值 20 → 18.5
        let e = BalanceSpendEstimate.estimate(samples: [s(23 * 3600, "10"), s(21 * 3600, "9"), s(3600, "20"), s(60, "18.5")],
                                              now: now, timeZone: tz, currency: .cny)
        try checkEqual(e.today, Decimal(string: "2.5")!)
        try checkEqual(e.week.count, 7)
        try checkEqual(e.week.last?.cost?.amount, Decimal(string: "2.5")!)
        try checkEqual(e.week.last?.day, "2026-10-15")
    }
}
