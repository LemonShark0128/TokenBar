import Foundation

/// 暂时隐藏平台（用户 11/6，proposal-hide-platform 甲 + 乙）：保留登录和「已添加」，不刷新、不提醒、不显示；可以再显示回来
@MainActor
func registerHidePlatformTests() {
    testAsync("hideStopsRefreshKeepsLogin") {
        let h = try await hideStore()
        await h.store.setHidden(.kimi, true)
        let st = h.store.platforms.first { $0.id == .kimi }
        try checkEqual(st?.status, .hidden)
        try check(st?.snapshot == nil, "隐藏后不留旧数")
        try check(h.store.isAdded(.kimi), "仍是已添加")
        try check(h.store.isHidden(.kimi))
        if case .found = h.creds.read(.kimi) {} else { throw TestFailure(description: "Key 应保留") }
        let before = h.kimi.calls
        await h.store.refresh()
        h.clock.now = h.clock.now.addingTimeInterval(3600)
        await h.store.tick()
        try checkEqual(h.kimi.calls, before)
        try checkEqual(h.store.hiddenPlatforms, [.kimi])
    }
    testAsync("hiddenSurvivesRestart") {
        let h = try await hideStore()
        await h.store.setHidden(.kimi, true)
        let kimi = FakeProvider([.success(kimiSnap(h.clock.now))], id: .kimi)
        let again = UsageStore(providers: [FakeProvider([.success(snap(h.clock.now))]), kimi], credentials: h.creds,
                               samples: try SampleStore(path: ":memory:"), intervalSeconds: 120,
                               clock: { h.clock.now }, defaults: h.defaults)
        try checkEqual(again.platforms.first { $0.id == .kimi }?.status, .hidden)
        await again.refresh()
        try checkEqual(kimi.calls, 0)
        try checkEqual(again.platforms.first { $0.id == .kimi }?.status, .hidden)
    }
    testAsync("unhideFetchesRightAway") {
        let h = try await hideStore()
        await h.store.setHidden(.kimi, true)
        h.kimi.results = [.success(kimiSnap(h.clock.now))]
        let before = h.kimi.calls
        await h.store.setHidden(.kimi, false)
        try checkEqual(h.kimi.calls, before + 1)
        try checkEqual(h.store.platforms.first { $0.id == .kimi }?.status, .ok)
        try check(!h.store.isHidden(.kimi))
        try checkEqual(h.store.hiddenPlatforms, [])
    }
    testAsync("unhideRetriesStoppedPlatform") {
        // Key 失效后自动刷新停了；隐藏再显示 = 用户要用它，要再试一次，不能一直停在「正在连接」
        let h = try await hideStore()
        h.kimi.results = [.failure(.auth("bad key"))]
        await h.store.refresh(.kimi)
        try checkEqual(h.store.platforms.first { $0.id == .kimi }?.status, .credentialInvalid)
        await h.store.setHidden(.kimi, true)
        h.kimi.results = [.success(kimiSnap(h.clock.now))]
        await h.store.setHidden(.kimi, false)
        try checkEqual(h.store.platforms.first { $0.id == .kimi }?.status, .ok)
    }
    testAsync("hidePinnedMainRestoresAuto") {
        let h = try await hideStore()
        h.store.pinMain(.kimi)
        h.store.setAutoMain(false)
        await h.store.setHidden(.kimi, true)
        try check(h.store.switchState.auto)
        try checkEqual(h.store.mainProvider, .deepseek)
        try checkEqual(h.store.menuBarProvider, .deepseek)
    }
    testAsync("hiddenLeavesOverviewAndAlerts") {
        let h = try await hideStore()
        await h.store.setHidden(.kimi, true)
        try check(!h.store.anomalies(lowThreshold: [.kimi: 1000]).contains(.lowTank(.kimi)))
        try check(!h.store.risks().contains { $0.id == .kimi })
        let main = h.store.platforms.first { $0.id == .deepseek }!
        let d = AppDataMapping.appData(main: main, others: h.store.platforms.filter { $0.id != .deepseek },
                                       now: h.clock.now, timeZone: TimeZone(secondsFromGMT: 0)!)
        try check(!d.sides.contains { $0.id == "kimi" }, "今天页 / 菜单栏不再有它")
    }
    testAsync("allHiddenThenShowOneBecomesMain") {
        let h = try await hideStore()
        await h.store.setHidden(.kimi, true)
        await h.store.setHidden(.deepseek, true)
        try check(h.store.allHidden)
        try checkEqual(h.store.hiddenPlatforms, [.deepseek, .kimi])
        await h.store.setHidden(.deepseek, false)
        try check(!h.store.allHidden)
        try checkEqual(h.store.mainProvider, .deepseek)
        try checkEqual(A11yText.noPlatforms(allHidden: true), L("today.allHidden"))
        try checkEqual(A11yText.noPlatforms(allHidden: false), L("a11y.noPlatforms"))
    }
    testAsync("reloginShowsHiddenPlatform") {
        // 重新登录 = 要用它：隐藏着的一并显示回来
        let h = try await hideStore()
        await h.store.setHidden(.kimi, true)
        h.kimi.results = [.success(kimiSnap(h.clock.now))]
        try await h.store.saveCredentials(["apiKey": "new"], for: .kimi)
        try check(!h.store.isHidden(.kimi))
        try checkEqual(h.store.platforms.first { $0.id == .kimi }?.status, .ok)
    }
    testAsync("hiddenNeverPreferred") {
        let h = try await hideStore()
        await h.store.setHidden(.kimi, true)
        h.store.setActiveMinutes([.kimi: 900, .deepseek: 10])
        try check(h.store.preferredPlatform != .kimi, "隐藏的平台不能当常用平台")
    }
    testAsync("hideDuringKeychainReadStaysHidden") {
        // 启动时就隐藏 → 点「显示」→ 读钥匙串（等授权框）途中又隐藏 → 用户拒绝授权：
        // 状态要留在「已隐藏」，不能变成「读不到钥匙串」又出现在面板里、却没有「显示」入口
        let clock = FakeClock()
        let d = freshDefaults()
        for id in [ProviderID.deepseek, .kimi] { d.set(true, forKey: UsageStore.addedKey(id)) }
        d.set(true, forKey: UsageStore.hiddenKey(.kimi))
        let creds = GatedCredentials()
        let store = UsageStore(providers: [FakeProvider([.success(snap(clock.now))]), FakeProvider([], id: .kimi)],
                               credentials: creds, samples: try SampleStore(path: ":memory:"), intervalSeconds: 120,
                               clock: { clock.now }, defaults: d)
        let show = Task { @MainActor in await store.setHidden(.kimi, false) }
        while !creds.started { await Task.yield(); try await Task.sleep(nanoseconds: 1_000_000) }
        await store.setHidden(.kimi, true)
        creds.release()
        await show.value
        try checkEqual(store.platforms.first { $0.id == .kimi }?.status, .hidden)
        try checkEqual(store.hiddenPlatforms, [.kimi])
    }
    testAsync("removeClearsHidden") {
        let h = try await hideStore()
        await h.store.setHidden(.kimi, true)
        try await h.store.removeAccount(.kimi)
        try check(!h.store.isHidden(.kimi))
        try checkEqual(h.store.platforms.first { $0.id == .kimi }?.status, .notAdded)
        try check(h.defaults.object(forKey: UsageStore.hiddenKey(.kimi)) == nil)
    }
    test("hiddenAccountState") {
        let st = PlatformState(id: .kimi, snapshot: nil, burn: nil, status: .hidden)
        try checkEqual(AccountState.of(st), .hidden)
        try checkEqual(AccountState.hidden.tone, .neutral)
        try checkEqual(AccountState.hidden.label, L("acct.hidden"))
        let states: [ProviderID: AccountState] = [.deepseek: .ok, .kimi: .hidden]
        try checkEqual(SettingsLayout.added(states), [.deepseek, .kimi])      // 管理页、设置里还在
        try checkEqual(SettingsLayout.shown(states), [.deepseek])             // 今天页、菜单栏选项里没有
        try check(!PlatformStatus.hidden.isShown)
        try check(!PlatformStatus.notAdded.isShown)
        try check(PlatformStatus.offline.isShown)
        let s = OnboardingPlan.addedStatus(.kimi, state: .hidden, reading: nil)
        try checkEqual(s.text, L("acct.hidden"))
        try check(!s.warn)
    }
    test("hiddenMenuText") {
        // 「添加 / 移除平台」右边的「已隐藏 2 ⌄」（用户 11/6 选 proposal-hidden-bottom 丁）
        try checkEqual(OnboardingPlan.hiddenMenuTitle([.kimi]), L("today.hiddenCount", 1))
        try checkEqual(OnboardingPlan.hiddenMenuTitle([.siliconflow, .kimi]), L("today.hiddenCount", 2))
        try checkEqual(OnboardingPlan.hiddenMenuA11y([.siliconflow, .kimi]),
                       L("today.hiddenCountA11y", 2, ProviderRegistry.displayName(.siliconflow) + L("common.listSep") + "Kimi"))
        try check(!OnboardingPlan.showsShowAll([.kimi]), "只隐藏一个时不写「全部显示」")
        try check(OnboardingPlan.showsShowAll([.siliconflow, .kimi]))
    }
    test("hiddenLineText") {
        try checkEqual(OnboardingPlan.hiddenLine([.kimi]), L("today.hiddenLine", "Kimi"))
        try checkEqual(OnboardingPlan.hiddenLine([.siliconflow, .kimi]),
                       L("today.hiddenLine", ProviderRegistry.displayName(.siliconflow) + L("common.listSep") + "Kimi"))
    }
}

private func kimiSnap(_ now: Date) -> ProviderSnapshot {
    var s = snap(now, balance: 15)
    s.provider = .kimi
    s.source = .balanceOnly
    return s
}

@MainActor
private func hideStore() async throws -> (store: UsageStore, kimi: FakeProvider, creds: InMemoryCredentialStore,
                                          defaults: UserDefaults, clock: FakeClock) {
    let clock = FakeClock()
    let creds = InMemoryCredentialStore()
    for id in [ProviderID.deepseek, .kimi] { try creds.save(Credentials(values: ["apiKey": "test"]), for: id) }
    let d = freshDefaults()
    for id in [ProviderID.deepseek, .kimi] { d.set(true, forKey: UsageStore.addedKey(id)) }
    let kimi = FakeProvider([.success(kimiSnap(clock.now))], id: .kimi)
    let store = UsageStore(providers: [FakeProvider((0..<5).map { _ in .success(snap(clock.now)) }), kimi], credentials: creds,
                           samples: try SampleStore(path: ":memory:"), intervalSeconds: 120,
                           clock: { clock.now }, defaults: d)
    await store.refresh()
    return (store, kimi, creds, d, clock)
}

/// Kimi 的钥匙串读取卡住，直到 release()，然后回「拒绝授权」
private final class GatedCredentials: CredentialStore, @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _started = false
    var started: Bool { lock.lock(); defer { lock.unlock() }; return _started }
    func read(_ p: ProviderID) -> CredentialRead {
        guard p == .kimi else { return .found(Credentials(values: ["apiKey": "test"])) }
        lock.lock(); _started = true; lock.unlock()
        gate.wait()
        return .error(-128)
    }
    func release() { gate.signal() }
    func save(_ c: Credentials, for p: ProviderID) throws {}
    func delete(_ p: ProviderID) throws {}
    func clearFailure() {}
}
