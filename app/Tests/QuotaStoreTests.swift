import Foundation

/// 记录调用次数的凭据库替身：套餐平台免凭据，三个计数必须始终为 0
private final class CountingCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var counts = (read: 0, save: 0, delete: 0)
    var total: (read: Int, save: Int, delete: Int) { lock.lock(); defer { lock.unlock() }; return counts }
    func read(_ p: ProviderID) -> CredentialRead { lock.lock(); counts.read += 1; lock.unlock(); return .notFound }
    func save(_ c: Credentials, for p: ProviderID) throws { lock.lock(); counts.save += 1; lock.unlock() }
    func delete(_ p: ProviderID) throws { lock.lock(); counts.delete += 1; lock.unlock() }
}

private func window(_ kind: QuotaWindow.Kind, used: Double, resets: Date?) -> QuotaWindow {
    QuotaWindow(kind: kind, usedPercent: used, resetsAt: resets, windowMinutes: nil)
}

private func quotaSnap(observedAt: Date, fetchedAt: Date, session: Double = 30, weekly: Double = 20) -> ProviderSnapshot {
    var s = ProviderSnapshot(provider: .deepseek, balance: nil, today: nil, month: nil, byModel: [],
                             trend7: [], source: .quota, fetchedAt: fetchedAt, credential: .ok)
    s.quota = Quota(plan: "plus", windows: [window(.session, used: session, resets: fetchedAt.addingTimeInterval(7200)),
                                            window(.weekly, used: weekly, resets: fetchedAt.addingTimeInterval(86400))],
                    observedAt: observedAt)
    return s
}

@MainActor
private func quotaStore(_ p: FakeProvider, clock: FakeClock, cs: CredentialStore = InMemoryCredentialStore(),
                        settings: ProviderSettings = ProviderSettings(),
                        seed: [Sample] = []) throws -> (UsageStore, SampleStore) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let samples = try SampleStore(path: dir.appendingPathComponent("s.sqlite").path)
    for x in seed { try samples.append(x) }
    let store = UsageStore(providers: [p], credentials: cs, samples: samples, intervalSeconds: 120,
                           clock: { clock.now }, timeZone: { TimeZone(secondsFromGMT: 0)! },
                           defaults: freshDefaults(), settings: { settings })
    return (store, samples)
}

private func quotaProvider(_ r: [Result<ProviderSnapshot, ProviderError>]) -> FakeProvider {
    FakeProvider(r, id: .deepseek, meter: .quota, needsCredentials: false)
}

@MainActor
func registerQuotaStoreTests() {
    testAsync("credentialFreeNotAddedUntilAdded") {
        let clock = FakeClock()
        let p = quotaProvider([.success(quotaSnap(observedAt: clock.now, fetchedAt: clock.now))])
        let (store, _) = try quotaStore(p, clock: clock)
        await store.refresh()
        try checkEqual(store.platforms[0].status, .notAdded)
        try checkEqual(p.calls, 0)
        await store.addCredentialFree(.deepseek)
        try checkEqual(store.platforms[0].status, .ok)
        try checkEqual(p.calls, 1)
        try check(store.platforms[0].snapshot?.quota != nil)
    }
    // 引导「选平台」判断已添加：启动时状态是 .loading，不能当成已添加；以「已添加」标记为准
    testAsync("isAddedFollowsAddedFlagNotStatus") {
        let clock = FakeClock()
        let p = quotaProvider([.success(quotaSnap(observedAt: clock.now, fetchedAt: clock.now))])
        let (store, _) = try quotaStore(p, clock: clock)
        try checkEqual(store.platforms[0].status, .loading)
        try checkEqual(store.isAdded(.deepseek), false)
        await store.addCredentialFree(.deepseek)
        try checkEqual(store.isAdded(.deepseek), true)
    }
    testAsync("credentialFreeNeverTouchesKeychain") {
        let clock = FakeClock()
        let p = quotaProvider(Array(repeating: .success(quotaSnap(observedAt: clock.now, fetchedAt: clock.now)), count: 4))
        let cs = CountingCredentialStore()
        let (store, _) = try quotaStore(p, clock: clock, cs: cs)
        await store.addCredentialFree(.deepseek)
        await store.refresh()
        clock.now = clock.now.addingTimeInterval(200)
        await store.refresh()
        try await store.removeAccount(.deepseek)
        let t = cs.total
        try checkEqual(t.read, 0)
        try checkEqual(t.save, 0)
        try checkEqual(t.delete, 0)
        try checkEqual(store.platforms[0].status, .notAdded)
    }
    testAsync("quotaSampleOnlyOnNewObservation") {
        let clock = FakeClock()
        let t = clock.now
        let p = quotaProvider([.success(quotaSnap(observedAt: t, fetchedAt: t)),
                               .success(quotaSnap(observedAt: t, fetchedAt: t)),
                               .success(quotaSnap(observedAt: t.addingTimeInterval(120), fetchedAt: t, session: 42))])
        let (store, samples) = try quotaStore(p, clock: clock)
        await store.addCredentialFree(.deepseek)
        for _ in 0..<2 {
            clock.now = clock.now.addingTimeInterval(130)
            await store.refresh()
        }
        let all = try samples.samples(.deepseek, since: .distantPast)
        try checkEqual(all.count, 2)
        try checkEqual(all.last?.t, t.addingTimeInterval(120))
        try checkEqual(all.last?.quotaUsed, 42)
        try check(all.last?.balance == nil && all.last?.cumulativeCost == nil)
    }
    testAsync("quotaFailurePreservesSnapshotAsStale") {
        let clock = FakeClock()
        let p = quotaProvider([.success(quotaSnap(observedAt: clock.now, fetchedAt: clock.now)),
                               .failure(.unavailable("读不到 /x"))])
        let (store, _) = try quotaStore(p, clock: clock)
        await store.addCredentialFree(.deepseek)
        clock.now = clock.now.addingTimeInterval(900)
        await store.refresh()
        try checkEqual(store.platforms[0].status, .stale(minutes: 15))
        try checkEqual(store.platforms[0].errorDetail, "读不到 /x")
        try check(!(store.anomalies(lowThreshold: [:])).contains(.stale(.deepseek)))
        // 取数成功后原因清空
        p.results = [.success(quotaSnap(observedAt: clock.now, fetchedAt: clock.now))]
        clock.now = clock.now.addingTimeInterval(200)
        await store.refresh()
        try check(store.platforms[0].errorDetail == nil)
    }
    testAsync("quotaStaleRiskExpiresAfterTenMinutes") {
        let clock = FakeClock()
        let original = quotaSnap(observedAt: clock.now, fetchedAt: clock.now, session: 95)
        let p = quotaProvider([.success(original), .failure(.unavailable("超时"))])
        let (store, _) = try quotaStore(p, clock: clock)
        await store.addCredentialFree(.deepseek)
        clock.now = clock.now.addingTimeInterval(180)
        await store.refresh()
        try checkEqual(store.platforms[0].status, .stale(minutes: 3))
        try checkEqual(store.platforms[0].snapshot, original)
        try check(store.risks(lowThreshold: [.deepseek: 10]).first?.atRisk == true)
        try check(store.anomalies(lowThreshold: [.deepseek: 10]).contains(.lowTank(.deepseek)))
        clock.now = clock.now.addingTimeInterval(720)
        try checkEqual(store.risks(lowThreshold: [.deepseek: 10]).first?.kind, .noData)
        try check(store.risks(lowThreshold: [.deepseek: 10]).first?.atRisk == false)
        try check(!(store.anomalies(lowThreshold: [.deepseek: 10])).contains(.lowTank(.deepseek)))
    }
    testAsync("quotaColdFailureUsesDiskOrStaysOffline") {
        let clock = FakeClock()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = SnapshotCache(url: dir.appendingPathComponent("cache.json"))
        let original = quotaSnap(observedAt: clock.now, fetchedAt: clock.now.addingTimeInterval(-180))
        for hasCache in [false, true] {
            if hasCache { try cache.save(original) }
            let store = UsageStore(providers: [quotaProvider([.failure(.unavailable("超时"))])],
                                         credentials: InMemoryCredentialStore(), samples: try SampleStore(path: dir.appendingPathComponent("samples.sqlite").path),
                                         intervalSeconds: 120, clock: { clock.now }, defaults: freshDefaults(), snapshotCache: cache)
            await store.addCredentialFree(.deepseek)
            try checkEqual(store.platforms[0].status, hasCache ? .stale(minutes: 3) : .offline)
            try checkEqual(store.platforms[0].snapshotFromDisk, hasCache)
            try checkEqual(store.platforms[0].snapshot, hasCache ? original : nil)
        }
    }
    testAsync("quotaSchemaChangedKeepsStatus") {
        let clock = FakeClock()
        let p = quotaProvider([.failure(.schemaChanged("字段变了"))])
        let (store, _) = try quotaStore(p, clock: clock)
        await store.addCredentialFree(.deepseek)
        try checkEqual(store.platforms[0].status, .schemaChanged)
        try checkEqual(store.platforms[0].errorDetail, "字段变了")
    }
    testAsync("quotaWeeklyLowTankDespiteSessionDisplay") {
        let clock = FakeClock()
        let snapshot = quotaSnap(observedAt: clock.now, fetchedAt: clock.now, session: 20, weekly: 80)
        let (store, _) = try quotaStore(quotaProvider([.success(snapshot)]), clock: clock)
        await store.addCredentialFree(.deepseek)
        try check(store.anomalies(lowThreshold: [.deepseek: 30]).contains(.lowTank(.deepseek)))
    }
    testAsync("quotaLowTankUsesPercent") {
        let clock = FakeClock()
        let low = quotaProvider([.success(quotaSnap(observedAt: clock.now, fetchedAt: clock.now, session: 92))])
        let (s1, _) = try quotaStore(low, clock: clock)
        await s1.addCredentialFree(.deepseek)
        try check(s1.anomalies(lowThreshold: [.deepseek: 10]).contains(.lowTank(.deepseek)))
        let ok = quotaProvider([.success(quotaSnap(observedAt: clock.now, fetchedAt: clock.now, session: 41))])
        var set = ProviderSettings(); set.lowAlerts[.deepseek] = 10
        let (s2, _) = try quotaStore(ok, clock: clock, settings: set)
        await s2.addCredentialFree(.deepseek)
        try check(!(s2.anomalies()).contains(.lowTank(.deepseek)))
    }
    testAsync("quotaRiseFromSamples") {
        let clock = FakeClock()
        let now = clock.now
        let seed = [(-3000.0, 55.0), (-2000, 60), (-1000, 70)].map {
            Sample(provider: .deepseek, t: now.addingTimeInterval($0.0), balance: nil, cumulativeCost: nil,
                   currency: .cny, quotaUsed: $0.1)
        }
        let p = quotaProvider([.success(quotaSnap(observedAt: now.addingTimeInterval(-1000), fetchedAt: now))])
        let (store, _) = try quotaStore(p, clock: clock, seed: seed)
        try check(store.quotaRise(.deepseek) == nil, "取数前不是 .ok")
        await store.addCredentialFree(.deepseek)
        try checkEqual(store.quotaRise(.deepseek), 15)
    }
    testAsync("moneyPlatformHasNoQuotaRise") {
        let clock = FakeClock()
        let (store, _) = try makeStore(FakeProvider([.success(snap(clock.now))]), clock: clock)
        await store.refresh()
        try check(store.quotaRise(.deepseek) == nil)
    }
    testAsync("activitiesIncludeQuotaPlatforms") {
        let clock = FakeClock()
        let p = quotaProvider([.success(quotaSnap(observedAt: clock.now, fetchedAt: clock.now))])
        let (store, _) = try quotaStore(p, clock: clock)
        try check(store.activities().isEmpty, "未添加不出现")
        await store.addCredentialFree(.deepseek)
        try checkEqual(store.activities()[.deepseek], Activity.quota(risePP: 0))
        let off = quotaProvider([.failure(.network("x"))])
        let (s2, _) = try quotaStore(off, clock: clock)
        await s2.addCredentialFree(.deepseek)
        try check(s2.activities()[.deepseek] == nil, ".offline 的套餐平台不出现")
    }
}
