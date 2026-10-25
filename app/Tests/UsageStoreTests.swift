import Foundation

final class FakeClock { var now = Date(timeIntervalSince1970: 1_792_022_400) }

/// 按顺序返回预设结果；记录被调用次数
/// @unchecked Sendable：测试替身，只在一个测试里顺序使用
final class FakeProvider: UsageProvider, @unchecked Sendable {
    var results: [Result<ProviderSnapshot, ProviderError>]
    private(set) var calls = 0
    let pid: ProviderID, hasBalance: Bool, currency: Currency, meter: Meter, needsCredentials: Bool
    init(_ results: [Result<ProviderSnapshot, ProviderError>], id: ProviderID = .deepseek, hasBalance: Bool = true,
         currency: Currency = .cny, meter: Meter = .money, needsCredentials: Bool = true) {
        self.results = results; pid = id; self.hasBalance = hasBalance; self.currency = currency
        self.meter = meter; self.needsCredentials = needsCredentials
    }
    var id: ProviderID { pid }
    var displayName: String { "Fake" }
    var capabilities: Capabilities { Capabilities(hasBalance: hasBalance, currency: currency, minPollInterval: 60, dayBoundary: .local,
                                                  meter: meter, needsCredentials: needsCredentials) }
    var loginSteps: [LoginStep] { [.apiKey(required: true)] }
    func validate(_ c: Credentials) async -> ValidationResult { .ok(summary: "") }
    func fetch(_ c: Credentials, now: Date, timeZone: TimeZone) async -> Result<ProviderSnapshot, ProviderError> {
        calls += 1
        return results.isEmpty ? .failure(.network("没有预设")) : results.removeFirst()
    }
}

func snap(_ now: Date, balance: Decimal = Decimal(string: "27.07")!, month: Decimal = 10,
          week: Decimal = 1, console: Bool = false) -> ProviderSnapshot {
    ProviderSnapshot(provider: .deepseek, balance: Money(amount: balance, currency: .cny),
                     today: Money(amount: 1, currency: .cny), month: Money(amount: month, currency: .cny), byModel: [],
                     trend7: (0..<7).map { DayUsage(day: "d\($0)", tokens: 0, cost: Money(amount: week, currency: .cny)) },
                     source: .bill, fetchedAt: now, credential: .ok, consoleLoginNeeded: console)
}

@MainActor
func makeStore(_ p: FakeProvider, clock: FakeClock, creds: Bool = true, interval: Int = 120,
               cache: SnapshotCache? = nil) throws -> (UsageStore, SampleStore) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let samples = try SampleStore(path: dir.appendingPathComponent("s.sqlite").path)
    let cs = InMemoryCredentialStore()
    if creds { try cs.save(Credentials(values: ["apiKey": "sk-test"]), for: .deepseek) }
    let store = UsageStore(providers: [p], credentials: cs, samples: samples, intervalSeconds: interval,
                           clock: { clock.now }, timeZone: { TimeZone(secondsFromGMT: 28800)! },
                           defaults: freshDefaults(), snapshotCache: cache)     // 每个测试独立，「添加过」标记不串到别的测试
    return (store, samples)
}

@MainActor
func registerUsageStoreTests() {
    testAsync("failureKeepsLastSnapshot") {
        let clock = FakeClock()
        let p = FakeProvider([.success(snap(clock.now)), .failure(.network("断网"))])
        let (store, _) = try makeStore(p, clock: clock)
        await store.refresh()
        let first = store.platforms[0].snapshot
        clock.now = clock.now.addingTimeInterval(300)
        await store.refresh()
        let st = store.platforms[0]
        try checkEqual(st.snapshot, first)
        try checkEqual(st.status, .stale(minutes: 5))
    }
    testAsync("authStopsPolling") {
        let clock = FakeClock()
        let p = FakeProvider([.failure(.auth("401")), .success(snap(clock.now))])
        let (store, _) = try makeStore(p, clock: clock)
        await store.refresh()
        try checkEqual(store.platforms[0].status, .credentialInvalid)
        clock.now = clock.now.addingTimeInterval(3600)
        await store.tick()
        await store.tick()
        try checkEqual(p.calls, 1)
    }
    testAsync("backoffCapsAt900") {
        let clock = FakeClock()
        let p = FakeProvider(Array(repeating: .failure(.rateLimited(retryAfter: nil)), count: 6))
        let (store, _) = try makeStore(p, clock: clock)
        var seq: [TimeInterval] = []
        for _ in 0..<6 {
            await store.refresh()
            seq.append(store.currentInterval(.deepseek))
            clock.now = clock.now.addingTimeInterval(seq.last! + 1)     // 等过退避期再试（刷新会遵守退避）
        }
        try checkEqual(seq, [240, 480, 900, 900, 900, 900])
    }
    testAsync("backoffNeverShortensLongBaseInterval") {
        let clock = FakeClock()
        let p = FakeProvider(Array(repeating: .failure(.rateLimited(retryAfter: nil)), count: 3))
        let (store, _) = try makeStore(p, clock: clock, interval: 1800)
        var seq: [TimeInterval] = []
        for _ in 0..<3 {
            await store.refresh()
            seq.append(store.currentInterval(.deepseek))
            clock.now = clock.now.addingTimeInterval(seq.last! + 1)
        }
        try check(seq.allSatisfy { $0 >= 1800 }, "基础间隔 1800 秒，遇 429 后不应缩短：\(seq)")
    }
    testAsync("missingCredentialNeverAddedIsNotAdded") {
        let clock = FakeClock()
        let p = FakeProvider([.success(snap(clock.now))])
        let (store, _) = try makeStore(p, clock: clock, creds: false)
        await store.refresh()
        try checkEqual(p.calls, 0)
        try checkEqual(store.platforms[0].status, .notAdded)
    }
    testAsync("coldStartOfflineUsesLastSample") {
        let clock = FakeClock()
        let p = FakeProvider([.failure(.network("断网"))])
        let (store, samples) = try makeStore(p, clock: clock)
        let earlier = clock.now.addingTimeInterval(-1800)
        try samples.append(Sample(provider: .deepseek, t: earlier, balance: 27, cumulativeCost: nil, currency: .cny))
        await store.refresh()
        let st = store.platforms[0]
        try checkEqual(st.status, .offline)
        try checkEqual(st.lastSampleAt, earlier)
        try checkEqual(st.lastSample?.balance, Decimal(27))
        try check(st.snapshot == nil)
    }
    testAsync("coldStartOfflineWithoutHistory") {
        let clock = FakeClock()
        let (store, _) = try makeStore(FakeProvider([.failure(.network("断网"))]), clock: clock)
        await store.refresh()
        let st = store.platforms[0]
        try checkEqual(st.status, .offline)
        try check(st.lastSampleAt == nil)
    }
    testAsync("newStoreStartsLoadingNotOffline") {
        let clock = FakeClock()
        let (store, _) = try makeStore(FakeProvider([]), clock: clock)
        try checkEqual(store.platforms[0].status, .loading)
        try check(store.anomalies(lowThreshold: [.deepseek: 10]).isEmpty, "首次取数前不应有任何异常（尤其不能报离线）")
    }
    testAsync("consoleLoginNeededStatus") {
        let clock = FakeClock()
        let (store, _) = try makeStore(FakeProvider([.success(snap(clock.now, console: true))]), clock: clock)
        await store.refresh()
        try checkEqual(store.platforms[0].status, .consoleLoginNeeded)
    }
    testAsync("samplesAppendedOnSuccess") {
        let clock = FakeClock()
        let (store, samples) = try makeStore(FakeProvider([.success(snap(clock.now))]), clock: clock)
        await store.refresh()
        try checkEqual(try samples.samples(.deepseek, since: .distantPast).count, 1)
    }
    testAsync("anomalyOrder") {
        let clock = FakeClock()
        let start = clock.now
        let p = FakeProvider([.success(snap(start.addingTimeInterval(3600), balance: 5, month: 2))])
        let (store, samples) = try makeStore(p, clock: clock)
        for i in 0..<6 {   // 一小时里累计花费 0 → 1.67，再加 refresh 时的 2 → 时速 2/时，7 天日均 1 → 飙升
            try samples.append(Sample(provider: .deepseek, t: start.addingTimeInterval(Double(i) * 600),
                                      balance: nil, cumulativeCost: Decimal(i) / 3, currency: .cny))
        }
        clock.now = start.addingTimeInterval(3600)
        await store.refresh()
        try checkEqual(store.anomalies(lowThreshold: [.deepseek: 10]),
                       [.lowTank(.deepseek), .spike(.deepseek)])
    }
}
