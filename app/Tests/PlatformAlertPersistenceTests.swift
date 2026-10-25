import Foundation

/// 遗留评审 Minor 10：各平台提醒状态存进 UserDefaults，重装 / 重启后不重复提醒
@MainActor
func registerPlatformAlertPersistenceTests() {
    let t0 = Date(timeIntervalSince1970: 2_000_000)
    func defaults() -> UserDefaults { UserDefaults(suiteName: "tb-test-\(UUID().uuidString)")! }
    func reloaded(_ tr: PlatformAlertTracker) -> PlatformAlertTracker {
        let d = defaults()
        tr.save(d)
        return PlatformAlertTracker.load(d)
    }
    func quotaRisk(_ id: ProviderID, state: QuotaRunway.State, resetsAt: Date?) -> PlatformRisk {
        let w = QuotaWindow(kind: .session, usedPercent: 88, resetsAt: resetsAt, windowMinutes: 300)
        let q = QuotaRunway(window: w, remainingPercent: 12, risePP: 18, hoursToEmpty: state == .runsOut ? 2.0 / 3 : nil,
                            resetsAt: resetsAt, state: state, severity: state == .runsOut ? .danger : .ok)
        var r = PlatformRisk(id: id, kind: .quota(q), hours: state == .runsOut ? 2.0 / 3 : nil,
                             atRisk: state == .runsOut, severity: state == .runsOut ? .danger : .ok)
        r.quotaReading = q
        return r
    }

    test("alertStateLowSurvivesReload") {
        var tr = PlatformAlertTracker()
        let low: [Anomaly] = [.lowTank(.deepseek)]
        try checkEqual(tr.lowToFire(low, now: t0, repeatHours: 6), [.deepseek])
        var back = reloaded(tr)
        try checkEqual(back, tr)
        // 重启后仍在线下：间隔内不重发，到间隔照常再提醒
        try checkEqual(back.lowToFire(low, now: t0.addingTimeInterval(60), repeatHours: 6), [])
        try checkEqual(back.lowToFire(low, now: t0.addingTimeInterval(6 * 3600), repeatHours: 6), [.deepseek])
    }
    test("alertStateRearmsAfterRecoveryAcrossReload") {
        var tr = PlatformAlertTracker()
        let low: [Anomaly] = [.lowTank(.siliconflow)]
        try checkEqual(tr.lowToFire(low, now: t0, repeatHours: 6), [.siliconflow])
        try checkEqual(tr.lowToFire([], now: t0.addingTimeInterval(60), repeatHours: 6), [])
        var back = reloaded(tr)
        // 回到线上的状态也要存下来：再跌破立即提醒
        try checkEqual(back.lowToFire(low, now: t0.addingTimeInterval(120), repeatHours: 6), [.siliconflow])
    }
    test("alertStateRunoutSameWindowNotRepeated") {
        var tr = PlatformAlertTracker()
        let reset1 = t0.addingTimeInterval(7200)
        try checkEqual(tr.runoutToFire([quotaRisk(.claudePlan, state: .runsOut, resetsAt: reset1)], now: t0), [.claudePlan])
        try checkEqual(tr.runoutToFire([quotaRisk(.codexPlan, state: .runsOut, resetsAt: nil)], now: t0), [.codexPlan])
        var back = reloaded(tr)
        try checkEqual(back.runoutToFire([quotaRisk(.claudePlan, state: .runsOut, resetsAt: reset1),
                                          quotaRisk(.codexPlan, state: .runsOut, resetsAt: nil)],
                                         now: t0.addingTimeInterval(60)), [])
        // 新窗口照常提醒
        let reset2 = reset1.addingTimeInterval(5 * 3600)
        try checkEqual(back.runoutToFire([quotaRisk(.claudePlan, state: .runsOut, resetsAt: reset2)],
                                         now: reset1.addingTimeInterval(60)), [.claudePlan])
    }
    test("alertStateCooldownsSurviveReload") {
        var tr = PlatformAlertTracker()
        try checkEqual(tr.spikeToFire([.spike(.deepseek)], now: t0), [.deepseek])
        let th: [ProviderID: Decimal] = [.siliconflow: 5]
        try checkEqual(tr.hourlyToFire(rates: [.siliconflow: 6], thresholds: th, now: t0), [.siliconflow])
        var back = reloaded(tr)
        try checkEqual(back.spikeToFire([.spike(.deepseek)], now: t0.addingTimeInterval(3600)), [])
        try checkEqual(back.hourlyToFire(rates: [.siliconflow: 6], thresholds: th, now: t0.addingTimeInterval(1800)), [])
        try checkEqual(back.spikeToFire([.spike(.deepseek)], now: t0.addingTimeInterval(PlatformAlertTracker.spikeCooldown)), [.deepseek])
        try checkEqual(back.hourlyToFire(rates: [.siliconflow: 6], thresholds: th,
                                         now: t0.addingTimeInterval(PlatformAlertTracker.hourlyCooldown)), [.siliconflow])
    }
    test("alertStateMissingOrCorruptLoadsEmpty") {
        let d = defaults()
        try checkEqual(PlatformAlertTracker.load(d), PlatformAlertTracker())
        d.set(Data("not json".utf8), forKey: PlatformAlertTracker.defaultsKey)
        try checkEqual(PlatformAlertTracker.load(d), PlatformAlertTracker())
        d.set("garbage", forKey: PlatformAlertTracker.defaultsKey)
        try checkEqual(PlatformAlertTracker.load(d), PlatformAlertTracker())
    }
    test("alertStateSkipsUnknownPlatform") {
        let d = defaults()
        let json = #"{"below":{"deepseek":true,"gone":true},"lowAt":{"deepseek":0,"gone":0},"spikeAt":{},"hourlyAt":{},"runoutWindow":{}}"#
        d.set(Data(json.utf8), forKey: PlatformAlertTracker.defaultsKey)
        var back = PlatformAlertTracker.load(d)
        // 认识的平台记录保留：仍在线下、间隔内不重发
        try checkEqual(back.lowToFire([.lowTank(.deepseek)], now: Date(timeIntervalSinceReferenceDate: 60), repeatHours: 6), [])
    }
}
