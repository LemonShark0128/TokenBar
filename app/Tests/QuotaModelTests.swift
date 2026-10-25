import Foundation

@MainActor
func registerQuotaModelTests() {
    let now = Date(timeIntervalSince1970: 1_792_022_400)
    func w(_ k: QuotaWindow.Kind, _ used: Double, resetsIn: TimeInterval?) -> QuotaWindow {
        QuotaWindow(kind: k, usedPercent: used, resetsAt: resetsIn.map { now.addingTimeInterval($0) }, windowMinutes: nil)
    }
    test("displayWindowPrefersSessionAndKeepsAlertTightest") {
        var q = Quota(plan: nil, windows: [w(.weekly, 80, resetsIn: 600), w(.session, 20, resetsIn: 60)], observedAt: now)
        try checkEqual(q.displayWindow?.kind, .session)
        try checkEqual(q.displayRemainingPercent(at: now), 80)
        try checkEqual(q.remainingPercent(at: now), 20)
        try checkEqual(q.displayRemainingPercent(at: now.addingTimeInterval(60)), 100)
        q.windows.removeLast()
        try checkEqual(q.displayRemainingPercent(at: now), 20)
        q.windows.insert(w(.weeklyModel("opus"), 90, resetsIn: 600), at: 0)
        try checkEqual(q.displayWindow?.kind, .weekly)
        q.windows.removeLast()
        try checkEqual(q.displayRemainingPercent(at: now), 10)
        q.windows = []
        try checkEqual(q.displayRemainingPercent(at: now), nil)
    }
    test("resetWindowCountsAsZero") {
        try checkEqual(w(.weekly, 100, resetsIn: -1).effectiveUsed(at: now), 0)
        try check(w(.weekly, 100, resetsIn: 0).isReset(at: now))        // now >= resetsAt
        try checkEqual(w(.session, 35, resetsIn: 60).effectiveUsed(at: now), 35)
    }
    test("usedOver100ClampsTo100") { try checkEqual(w(.session, 130, resetsIn: 60).effectiveUsed(at: now), 100) }
    test("remainingIsTightestWindow") {
        let q = Quota(plan: "plus", windows: [w(.session, 35, resetsIn: 60), w(.weekly, 41, resetsIn: 600)], observedAt: now)
        try checkEqual(q.remainingPercent(at: now), 59)
        try checkEqual(q.tightest(at: now)?.kind, .weekly)
        try checkEqual(Quota(plan: nil, windows: [], observedAt: now).remainingPercent(at: now), nil)
    }
    test("tightestTieKeepsEarlierWindow") {
        let q = Quota(plan: nil, windows: [w(.weekly, 40, resetsIn: 600), w(.session, 40, resetsIn: 60)], observedAt: now)
        try checkEqual(q.tightest(at: now)?.kind, .weekly)
    }
    test("activityWindowPrefersSession") {
        let q = Quota(plan: nil, windows: [w(.weekly, 41, resetsIn: 600), w(.session, 35, resetsIn: 60)], observedAt: now)
        try checkEqual(q.activityWindow?.kind, .session)
        let weeklyOnly = Quota(plan: nil, windows: [w(.weeklyModel("opus"), 1, resetsIn: 60), w(.weekly, 41, resetsIn: 600)], observedAt: now)
        try checkEqual(weeklyOnly.activityWindow?.kind, .weekly)
        try check(Quota(plan: nil, windows: [], observedAt: now).activityWindow == nil)
    }
    test("riseIgnoresResetDrop") {
        // 基准点（1 小时前以外）80 → 90 → 重置后 2 → 6：涨幅 = 10 + 4 = 14
        let s = [(-4000.0, 80.0), (-1800, 90), (-900, 2), (-60, 6)].map {
            Sample(provider: .deepseek, t: now.addingTimeInterval($0.0), balance: nil, cumulativeCost: nil, currency: .cny, quotaUsed: $0.1)
        }
        try checkEqual(QuotaActivity.risePP(s, now: now), 14)
        try checkEqual(QuotaActivity.risePP([], now: now), 0)
    }
    test("quotaSnapshotRoundTripsAndOldCacheDecodes") {
        let q = Quota(plan: "plus", windows: [w(.session, 35, resetsIn: 60), w(.weeklyModel("opus"), 7, resetsIn: nil)], observedAt: now)
        var snap = ProviderSnapshot(provider: .deepseek, balance: nil, today: nil, month: nil,
                                    byModel: [], trend7: [], source: .quota, fetchedAt: now, credential: .ok)
        snap.quota = q
        snap.quotaNote = "还没读到额度"
        let data = try JSONEncoder().encode(snap)
        try checkEqual(try JSONDecoder().decode(ProviderSnapshot.self, from: data), snap)
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        obj.removeValue(forKey: "quota")
        obj.removeValue(forKey: "quotaNote")
        let old = try JSONDecoder().decode(ProviderSnapshot.self, from: JSONSerialization.data(withJSONObject: obj))
        try check(old.quota == nil)
        try check(old.quotaNote == nil)
    }
    test("registryMeterAndBalance") {
        try check(ProviderRegistry.hasBalance(.siliconflow) && !ProviderRegistry.hasBalance(.codexPlan))
        try check(ProviderRegistry.meter(.deepseek) == .money && ProviderRegistry.meter(.claudePlan) == .quota)
    }
}
