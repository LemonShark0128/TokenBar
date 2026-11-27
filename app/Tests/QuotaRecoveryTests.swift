import Foundation

@MainActor
func registerQuotaRecoveryTests() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    func plan(_ remaining: Double, status: PlatformStatus = .ok) -> PlatformState {
        let w = QuotaWindow(kind: .session, usedPercent: 100 - remaining, resetsAt: now.addingTimeInterval(3600), windowMinutes: 300)
        return PlatformState(id: .codexPlan, snapshot: ProviderSnapshot(provider: .codexPlan, balance: nil, today: nil, month: nil,
            byModel: [], trend7: [], source: .bill, fetchedAt: now, credential: .ok,
            quota: Quota(plan: nil, windows: [w], observedAt: now)), burn: nil, status: status)
    }
    test("quotaRecoveryResetOnce") {
        var m = QuotaRecoveryMemory()
        try checkEqual(m.toFire([plan(0)], lowAlerts: [:], now: now).count, 0)
        let alerts = m.toFire([plan(0)], lowAlerts: [:], now: now.addingTimeInterval(3600))
        try checkEqual(alerts.map(\.id), [.codexPlan])
        try checkEqual(m.toFire([plan(100)], lowAlerts: [:], now: now).count, 0)
    }
    test("quotaRecoveryLowThenHalf") {
        var m = QuotaRecoveryMemory()
        try checkEqual(m.toFire([plan(30)], lowAlerts: [.codexPlan: 40], now: now).count, 0)
        try checkEqual(m.toFire([plan(45)], lowAlerts: [.codexPlan: 40], now: now).count, 0)
        try checkEqual(m.toFire([plan(80)], lowAlerts: [.codexPlan: 40], now: now).count, 1)
        try checkEqual(m.toFire([plan(80)], lowAlerts: [.codexPlan: 40], now: now).count, 0)
    }
    test("quotaRecoveryNoThreshold") {
        var m = QuotaRecoveryMemory()
        _ = m.toFire([plan(30)], lowAlerts: [:], now: now)
        try checkEqual(m.toFire([plan(80)], lowAlerts: [:], now: now).count, 0)
    }
    test("quotaRecoveryRemovedClears") {
        var m = QuotaRecoveryMemory()
        _ = m.toFire([plan(0)], lowAlerts: [:], now: now)
        _ = m.toFire([plan(0, status: .notAdded)], lowAlerts: [:], now: now)
        try checkEqual(m.toFire([plan(100)], lowAlerts: [:], now: now).count, 0)
    }
    test("quotaRecoveryMissingQuotaKeepsMemory") {
        var m = QuotaRecoveryMemory()
        _ = m.toFire([plan(0)], lowAlerts: [:], now: now)
        var missing = plan(0); missing.snapshot?.quota = nil
        try checkEqual(m.toFire([missing], lowAlerts: [:], now: now).count, 0)
        try checkEqual(m.toFire([plan(100)], lowAlerts: [:], now: now).count, 1)
    }
    test("quotaRecoveryPersistence") {
        let suite = testSuiteName("recovery")
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        var m = QuotaRecoveryMemory.load(d)
        _ = m.toFire([plan(0)], lowAlerts: [:], now: now)
        m.save(d)
        var back = QuotaRecoveryMemory.load(d)
        try checkEqual(back, m)
        try checkEqual(back.toFire([plan(50)], lowAlerts: [:], now: now).count, 1)
    }
}
