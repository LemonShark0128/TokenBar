import Foundation

@MainActor
func registerRemovePlatformLeftoversTests() {
    // 移除固定主平台必须释放固定；删掉 removeAccount 中的恢复自动逻辑，这两例应失败。
    for temporaryPin in [false, true] {
        testAsync(temporaryPin ? "removeTemporarilyPinnedMainRestoresAuto" : "removeFixedMainRestoresAuto") {
            let store = try await removalSwitchStore()
            if temporaryPin { store.pinMain(.deepseek) } else { store.setAutoMain(false) }
            try check(store.isMainPinned)
            try await store.removeAccount(.deepseek)
            try check(store.switchState.auto)
            try check(store.switchState.pinnedUntil == nil)
            try check(store.switchState.leader == nil)
            try check(store.switchState.leaderSince == nil)
            try checkEqual(store.mainProvider, .kimi)
            try checkEqual(store.menuBarProvider, .kimi)
        }
    }
    testAsync("removeOtherPlatformPreservesFixedMain") {
        let store = try await removalSwitchStore()
        store.setAutoMain(false)
        let before = store.switchState
        try await store.removeAccount(.kimi)
        try checkEqual(store.switchState, before)
    }
    testAsync("removeAutomaticMainPreservesAuto") {
        let store = try await removalSwitchStore()
        let before = store.switchState
        try await store.removeAccount(.deepseek)
        var expected = before
        expected.main = .kimi
        try checkEqual(store.switchState, expected)
    }
    testAsync("removeFailurePreservesPinnedMain") {
        let store = try await removalSwitchStore(credentials: RemovalFailingCredentials())
        store.pinMain(.deepseek)
        store.setAutoMain(false)
        let before = store.switchState
        let platforms = store.platforms
        do {
            try await store.removeAccount(.deepseek)
            throw TestFailure(description: "删除应失败")
        } catch is RemovalDeleteError { }
        try checkEqual(store.switchState, before)
        try checkEqual(store.platforms, platforms)
    }
    test("removeSamplesOnlyForSelectedPlatform") {
        let samples = try SampleStore(path: ":memory:")
        let now = Date(timeIntervalSince1970: 1_792_022_400)
        for id in [ProviderID.kimi, .deepseek] {
            try samples.append(Sample(provider: id, t: now, balance: 100, cumulativeCost: nil, currency: .cny))
        }
        try samples.remove(.kimi)
        try check(try samples.earliest(.kimi) == nil)
        try check(try samples.latest(.kimi) == nil)
        try checkEqual(try samples.samples(.kimi, since: .distantPast), [])
        try checkEqual(try samples.latest(.deepseek)?.balance, 100)
        try checkEqual(try samples.earliest(.deepseek), now)
    }
    testAsync("removeAccountClearsSamplesAndSchedule") {
        let clock = FakeClock()
        let p = FakeProvider([.success(snap(clock.now))])
        let (store, samples) = try makeStore(p, clock: clock)
        await store.refresh()
        try check(try samples.earliest(.deepseek) != nil)
        try check(store.nextDueAt(.deepseek) != nil)
        try await store.removeAccount(.deepseek)
        try check(try samples.earliest(.deepseek) == nil)
        try check(store.nextDueAt(.deepseek) == nil)
    }
    // 余额连续不变会把刷新间隔拉长；移除后同一账号再加回来，要从设置的间隔重新数（不沿用旧的「没变」次数）
    testAsync("removeAccountResetsSteadyBackoff") {
        let clock = FakeClock()
        let p = FakeProvider(Array(repeating: .success(snap(clock.now)), count: 6))
        let (store, _) = try makeStore(p, clock: clock, creds: false)
        for _ in 0..<5 {
            clock.now = clock.now.addingTimeInterval(60)
            try await store.saveCredentials(["apiKey": "sk-test"], for: .deepseek)
        }
        try check(store.currentInterval(.deepseek) > 120)
        try await store.removeAccount(.deepseek)
        clock.now = clock.now.addingTimeInterval(60)
        try await store.saveCredentials(["apiKey": "sk-test"], for: .deepseek)
        try checkEqual(store.currentInterval(.deepseek), 120)
    }
    testAsync("removeAccountNewLowBalanceDoesNotBecomeSpend") {
        let clock = FakeClock()
        var old = snap(clock.now, balance: 100)
        old.provider = .kimi
        old.source = .balanceOnly
        old.today = nil; old.month = nil; old.trend7 = []
        var new = old
        new.balance = Money(amount: 20, currency: .cny)
        let p = FakeProvider([.success(old), .success(new)], id: .kimi)
        let samples = try SampleStore(path: ":memory:")
        let store = UsageStore(providers: [BalanceOnlyRemovalProvider(base: p)], credentials: InMemoryCredentialStore(), samples: samples,
                               intervalSeconds: 120, clock: { clock.now }, defaults: freshDefaults())
        try await store.saveCredentials(["apiKey": "old-test"], for: .kimi)
        try await store.removeAccount(.kimi)
        clock.now = clock.now.addingTimeInterval(60)
        try await store.saveCredentials(["apiKey": "new-test"], for: .kimi)
        try checkEqual(store.platforms.first?.snapshot?.today?.amount, 0)
        try checkEqual(store.platforms.first?.snapshot?.month?.amount, 0)
        try checkEqual(try samples.earliest(.kimi), clock.now)
    }
    test("forgetPlatformAllowsImmediateAlertsAndPreservesOthers") {
        let now = Date()
        let d = freshDefaults()
        defer { d.removeObject(forKey: PlatformAlertTracker.defaultsKey) }
        var tracker = PlatformAlertTracker()
        let low: [Anomaly] = [.lowTank(.kimi), .lowTank(.deepseek)]
        let spike: [Anomaly] = [.spike(.kimi), .spike(.deepseek)]
        let rates: [ProviderID: Decimal] = [.kimi: 2, .deepseek: 2]
        let thresholds: [ProviderID: Decimal] = [.kimi: 1, .deepseek: 1]
        _ = tracker.lowToFire(low, now: now, repeatHours: 6)
        _ = tracker.spikeToFire(spike, now: now)
        _ = tracker.hourlyToFire(rates: rates, thresholds: thresholds, now: now)
        tracker.forget(.kimi)
        tracker.save(d)
        tracker = PlatformAlertTracker.load(d)
        try checkEqual(tracker.lowToFire(low, now: now, repeatHours: 6), [.kimi])
        try checkEqual(tracker.spikeToFire(spike, now: now), [.kimi])
        try checkEqual(tracker.hourlyToFire(rates: rates, thresholds: thresholds, now: now), [.kimi])
    }
    test("unmuteOnlySelectedPlatform") {
        let d = freshDefaults(), now = Date()
        defer { d.removeObject(forKey: AlertMute.key) }
        AlertMute.mute([.kimi, .deepseek], now: now, d: d)
        AlertMute.unmute(.kimi, d: d)
        try check(!AlertMute.isMuted(.kimi, now: now, d: d, calendar: .current))
        try check(AlertMute.isMuted(.deepseek, now: now, d: d, calendar: .current))
        AlertMute.unmute(.deepseek, d: d)
        try check(!AlertMute.isMuted(.deepseek, now: now, d: d, calendar: .current))
    }
    test("removeQuietBacklogPreservesOtherAndMergedAlerts") {
        let d = freshDefaults()
        defer { d.removeObject(forKey: QuietBacklog.key) }
        let removed = PendingAlert(provider: .kimi, title: "低余额", body: "测试", sound: false)
        let other = PendingAlert(provider: .deepseek, title: "低余额", body: "测试", sound: true)
        let merged = PendingAlert(provider: nil, title: "合并提醒", body: "测试", sound: false)
        var backlog = QuietBacklog()
        backlog.append([removed, other, removed, merged])
        backlog.remove(.kimi)
        backlog.save(d)
        try checkEqual(QuietBacklog.load(d).alerts, [other, merged])
    }
}

/// 保留真实余额估算链路，只替换联网取数。
private struct BalanceOnlyRemovalProvider: UsageProvider {
    let base: FakeProvider
    var id: ProviderID { base.id }
    var capabilities: Capabilities {
        var c = base.capabilities
        c.estimatesSpendFromBalance = true
        return c
    }
    func validate(_ c: Credentials) async -> ValidationResult { await base.validate(c) }
    func fetch(_ c: Credentials, now: Date, timeZone: TimeZone) async -> Result<ProviderSnapshot, ProviderError> {
        await base.fetch(c, now: now, timeZone: timeZone)
    }
}

/// 只用内存凭据和数据库，两个平台都已添加，不访问真实钥匙串。
@MainActor
private func removalSwitchStore(credentials: CredentialStore = InMemoryCredentialStore()) async throws -> UsageStore {
    let clock = FakeClock()
    let providers = try [ProviderID.deepseek, .kimi].map { id -> FakeProvider in
        try credentials.save(Credentials(values: ["apiKey": "test"]), for: id)
        var snapshot = snap(clock.now)
        snapshot.provider = id
        return FakeProvider([.success(snapshot)], id: id)
    }
    let store = UsageStore(providers: providers, credentials: credentials, samples: try SampleStore(path: ":memory:"),
                           intervalSeconds: 120, clock: { clock.now }, defaults: freshDefaults())
    await store.refresh()
    store.pinMain(.deepseek)
    store.setAutoMain(true)
    return store
}

private struct RemovalDeleteError: Error { }

/// 仅替换删除失败这一边界，其余读写仍走内存存储。
private final class RemovalFailingCredentials: CredentialStore, @unchecked Sendable {
    private let base = InMemoryCredentialStore()
    func read(_ p: ProviderID) -> CredentialRead { base.read(p) }
    func save(_ c: Credentials, for p: ProviderID) throws { try base.save(c, for: p) }
    func delete(_ p: ProviderID) throws { throw RemovalDeleteError() }
}
