import Foundation

private func riskInput(_ id: ProviderID, status: PlatformStatus = .ok, hours: Double? = nil,
                       quota: QuotaRunway? = nil, low: Bool = false) -> RiskInput {
    RiskInput(id: id, status: status,
              payg: hours.map { PaygRunway(hours: $0, basis: .weekAverage, severity: Runway.severity(hours: $0),
                                          perHourRecent: nil, multiple: nil) }, quota: quota, belowThreshold: low)
}

@MainActor
func registerRiskRankerTests() {
    test("riskRankerOrdersUrgencyThenNoDataThenProvider") {
        let ids = ProviderID.allCases
        let q = QuotaRunway(window: QuotaWindow(kind: .session, usedPercent: 80, resetsAt: nil, windowMinutes: nil),
                           remainingPercent: 20, risePP: 30, hoursToEmpty: 2.0 / 3, resetsAt: nil,
                           state: .runsOut, severity: .danger)
        // 分两组覆盖顺序，兼容平台总数。
        let inputs = [riskInput(ids[0], status: .offline), riskInput(ids[1], hours: 5),
                      riskInput(ids[2], quota: q), riskInput(ids[3], low: true)]
        let ranked = RiskRanker.rank(inputs)
        try checkEqual(ranked.map(\.id), [ids[3], ids[2], ids[1], ids[0]])
        try checkEqual(ranked.map(\.hours), [0, 2.0 / 3, 5, nil])
        try checkEqual(ranked.first?.kind, .belowThreshold)
        try checkEqual(RiskRanker.mostAtRisk(inputs)?.id, ids[3])
        try checkEqual(RiskRanker.rank([riskInput(ids[0]), riskInput(ids[1], status: .offline)]).map(\.id), [ids[1], ids[0]])
        try checkEqual(RiskRanker.rank([riskInput(ids[1], hours: 5), riskInput(ids[0], hours: 5)]).map(\.id), [ids[0], ids[1]])
        try checkEqual(RiskRanker.rank([riskInput(ids[1]), riskInput(ids[0])]).map(\.id), [ids[0], ids[1]])
    }
    test("riskRankerIgnoresOldNumbersAndLoading") {
        for status: PlatformStatus in [.offline, .credentialInvalid, .schemaChanged, .stale(minutes: 5)] {
            let r = RiskRanker.risk(riskInput(.deepseek, status: status, hours: 1, low: true))
            try checkEqual(r.kind, .noData)
            try checkEqual(r.hours, nil)
            try checkEqual(r.atRisk, false)
            try checkEqual(r.severity, .ok)
        }
        for status: PlatformStatus in [.loading, .notAdded] {
            try checkEqual(RiskRanker.risk(riskInput(.deepseek, status: status, hours: 1, low: true)).kind, .none)
        }
        try checkEqual(RiskRanker.rank([riskInput(.deepseek, status: .notAdded)]), [])
        try checkEqual(RiskRanker.mostAtRisk([riskInput(.deepseek, hours: 12), riskInput(.siliconflow, status: .offline)]), nil)
        try checkEqual(RiskRanker.mostAtRisk([]), nil)
    }
    test("riskRankerPreservesQuotaAndPaygReadings") {
        for state: QuotaRunway.State in [.idle, .enough, .runsOut, .exhausted] {
            let risky = state == .runsOut || state == .exhausted
            let q = QuotaRunway(window: QuotaWindow(kind: .session, usedPercent: 90, resetsAt: nil, windowMinutes: nil),
                               remainingPercent: 10, risePP: 10, hoursToEmpty: risky ? (state == .exhausted ? 0 : 1) : nil,
                               resetsAt: nil, state: state, severity: risky ? .danger : .ok)
            let r = RiskRanker.risk(riskInput(.codexPlan, quota: q))
            try checkEqual(r.kind, .quota(q))
            try checkEqual(r.atRisk, risky)
            try checkEqual(r.hours, q.hoursToEmpty)
            try checkEqual(r.severity, q.severity)
        }
        let input = riskInput(.deepseek, hours: 12)
        let r = RiskRanker.risk(input)
        try checkEqual(r.kind, .payg(input.payg!))
        try checkEqual(r.hours, 12)
        try checkEqual(r.atRisk, false)
        try checkEqual(r.severity, .ok)
        try checkEqual(RiskRanker.risk(riskInput(.deepseek, hours: 1, low: true)).severity, .danger)
    }
    testAsync("storeRisksUsesThresholdsAndPlacesOfflineAfterRisk") {
        let clock = FakeClock()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-risk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let samples = try SampleStore(path: dir.appendingPathComponent("s.sqlite").path)
        let cs = InMemoryCredentialStore()
        for id: ProviderID in [.deepseek, .siliconflow] { try cs.save(Credentials(values: ["apiKey": "test"]), for: id) }
        let off = FakeProvider([.failure(.network("断网"))])
        var snapshot = snap(clock.now, balance: 5, week: 1)
        snapshot.provider = .siliconflow
        let low = FakeProvider([.success(snapshot)], id: .siliconflow)
        var settings = ProviderSettings(); settings.lowAlerts = [.siliconflow: 10]
        let config = settings
        let store = UsageStore(providers: [off, low], credentials: cs, samples: samples, intervalSeconds: 120,
                                     clock: { clock.now }, defaults: freshDefaults(), settings: { config })
        await store.refresh()
        let risks = store.risks()
        try checkEqual(risks.map(\.id), [.siliconflow, .deepseek])
        try checkEqual(risks.map(\.kind), [.belowThreshold, .noData])
        try checkEqual(risks.map(\.atRisk), [true, false])
        let disabled = store.risks(lowThreshold: [.siliconflow: 0])
        try checkEqual(disabled.first?.id, .deepseek)
        try checkEqual(RiskRanker.risk(riskInput(.deepseek)).kind, .none)
        let equal = store.risks(lowThreshold: [.siliconflow: 5])
        try checkEqual(equal.last?.atRisk, false)
    }
    testAsync("storeRisksQuotaThresholdUsesTightestWindow") {
        let clock = FakeClock()
        var snapshot = snap(clock.now)
        snapshot.quota = Quota(plan: nil, windows: [
            QuotaWindow(kind: .session, usedPercent: 10, resetsAt: nil, windowMinutes: 300),
            QuotaWindow(kind: .weekly, usedPercent: 95, resetsAt: nil, windowMinutes: nil)], observedAt: clock.now)
        let p = FakeProvider([.success(snapshot)], meter: .quota, needsCredentials: false)
        let (store, _) = try makeStore(p, clock: clock, creds: false)
        await store.addCredentialFree(.deepseek)
        try checkEqual(store.risks(lowThreshold: [.deepseek: 10]).first?.kind, .belowThreshold)
        let r = store.risks(lowThreshold: [:]).first!
        if case .quota(let q) = r.kind {
            try checkEqual(q.remainingPercent, 90)
            try checkEqual(q.state, .idle)
        } else { try check(false, "套餐应保留续航读数") }
    }
}
