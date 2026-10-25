import Foundation

private func usd(_ s: String) -> Money { Money(amount: Decimal(string: s)!, currency: .usd) }

/// 按美元计费、没有余额的按量付费平台（原来用 硅基流动；平台删除后借硅基流动的 id，只为保留美元换算的覆盖）
private func usdSnap(_ now: Date, month: String, week: Decimal = 5, credential: CredentialState = .ok) -> ProviderSnapshot {
    ProviderSnapshot(provider: .siliconflow, balance: nil, today: usd("1"), month: usd(month), byModel: [],
                     trend7: (0..<7).map { DayUsage(day: "d\($0)", tokens: 0, cost: Money(amount: week, currency: .usd)) },
                     source: .bill, fetchedAt: now, credential: credential)
}

private func cnySnap(_ now: Date, _ id: ProviderID, balance: String) -> ProviderSnapshot {
    var s = snap(now, balance: Decimal(string: balance)!)
    s.provider = id
    return s
}

@MainActor
private func multiStore(_ ps: [FakeProvider], clock: FakeClock, settings: ProviderSettings,
                        seed: [Sample] = []) throws -> UsageStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let samples = try SampleStore(path: dir.appendingPathComponent("s.sqlite").path)
    for x in seed { try samples.append(x) }
    let cs = InMemoryCredentialStore()
    for p in ps { try cs.save(Credentials(values: ["apiKey": "sk-test"]), for: p.id) }
    return UsageStore(providers: ps, credentials: cs, samples: samples, intervalSeconds: 120,
                      clock: { clock.now }, timeZone: { TimeZone(secondsFromGMT: 0)! },
                      defaults: freshDefaults(), settings: { settings })
}

private func usdPlatform(_ results: [Result<ProviderSnapshot, ProviderError>]) -> FakeProvider {
    FakeProvider(results, id: .siliconflow, hasBalance: false, currency: .usd)
}

@MainActor
func registerMultiPlatformStoreTests() {
    testAsync("expiringCredentialAnomaly") {
        let clock = FakeClock()
        let store = try multiStore([usdPlatform([.success(usdSnap(clock.now, month: "1", credential: .expiring(days: 2)))])],
                                         clock: clock, settings: ProviderSettings())
        await store.refresh()
        try check(store.anomalies().contains(.expiring(.siliconflow)))
    }
    testAsync("perPlatformLowAlert") {
        let clock = FakeClock()
        var set = ProviderSettings(); set.lowAlerts[.siliconflow] = 5; set.lowAlerts[.deepseek] = 10
        let sf = FakeProvider([.success(cnySnap(clock.now, .siliconflow, balance: "3"))], id: .siliconflow)
        let ds = FakeProvider([.success(cnySnap(clock.now, .deepseek, balance: "27"))], id: .deepseek)
        let store = try multiStore([sf, ds], clock: clock, settings: set)
        await store.refresh()
        try checkEqual(store.anomalies(), [.lowTank(.siliconflow)])
    }
    testAsync("usdConvertedBeforeCompare") {
        let clock = FakeClock()
        let now = clock.now
        // 近 1 小时：DeepSeek 累计花费 5 → 6（¥1.0/时），硅基流动 10 → 10.2（$0.2/时 × 7.1 = ¥1.42）
        var seed: [Sample] = []
        for i in 0..<6 {
            let t = now.addingTimeInterval(-3600 + 600 * Double(i))
            seed.append(Sample(provider: .deepseek, t: t, balance: nil,
                               cumulativeCost: 5 + Decimal(i) * Decimal(string: "0.1")!, currency: .cny))
            seed.append(Sample(provider: .siliconflow, t: t, balance: nil,
                               cumulativeCost: 10 + Decimal(i) * Decimal(string: "0.03")!, currency: .usd))
        }
        let ds = FakeProvider([.success(snap(now, month: 6))], id: .deepseek)
        let cl = usdPlatform([.success(usdSnap(now, month: "10.2"))])
        let store = try multiStore([ds, cl], clock: clock, settings: ProviderSettings(), seed: seed)
        await store.refresh()
        let rates = store.ratesCny()
        try checkEqual(rates[.deepseek], Decimal(1))
        try checkEqual(rates[.siliconflow], Decimal(string: "1.42")!)
        // 2026-10-18 起主平台只按在跑的任务自动切换，花费多少不切
        try checkEqual(store.mainProvider, .deepseek)
        try check(store.lastAutoSwitch == nil)
    }
    for (name, failure) in [("staleRateExcludedAfterAuth", ProviderError.auth("401")),
                            ("staleRateExcludedWhenStale", ProviderError.network("断网"))] {
        testAsync(name) {
            let clock = FakeClock()
            let now = clock.now
            var seed: [Sample] = []
            for i in 0..<6 {
                let t = now.addingTimeInterval(-3600 + 600 * Double(i))
                seed.append(Sample(provider: .deepseek, t: t, balance: nil, cumulativeCost: 5, currency: .cny))
                seed.append(Sample(provider: .siliconflow, t: t, balance: nil,
                                   cumulativeCost: 10 + Decimal(i) * Decimal(string: "0.1")!, currency: .usd))
            }
            let ds = FakeProvider([.success(snap(now, month: 5)), .success(snap(now.addingTimeInterval(60), month: 5)),
                                   .success(snap(now.addingTimeInterval(660), month: 5))], id: .deepseek)
            // 硅基流动 第一轮 ¥7.1/时 领先，之后取数失败：旧时速不能再参与比较
            let cl = usdPlatform([.success(usdSnap(now, month: "11")), .failure(failure), .failure(failure)])
            let store = try multiStore([ds, cl], clock: clock, settings: ProviderSettings(), seed: seed)
            await store.refresh()
            clock.now = now.addingTimeInterval(60)
            await store.refresh()
            let st = store.platforms.first { $0.id == .siliconflow }?.status
            try check(st != .ok, "硅基流动 这轮应失败：\(String(describing: st))")
            try check(store.ratesCny()[.siliconflow] == nil, "失败平台的旧时速不应参与比较")
            clock.now = now.addingTimeInterval(660)
            await store.refresh()
            try checkEqual(store.mainProvider, .deepseek)
            try check(store.lastAutoSwitch == nil)
        }
    }
    testAsync("unavailableMainIsNotSwitchedAway") {
        let clock = FakeClock()
        let now = clock.now
        var seed: [Sample] = []
        for i in 0..<6 {
            let t = now.addingTimeInterval(-3600 + 600 * Double(i))
            seed.append(Sample(provider: .deepseek, t: t, balance: nil, cumulativeCost: 5 + Decimal(i) * 2, currency: .cny))
            seed.append(Sample(provider: .siliconflow, t: t, balance: nil,
                               cumulativeCost: 10 + Decimal(i) * Decimal(string: "0.1")!, currency: .usd))
        }
        // DeepSeek ¥15/时，之后断网；硅基流动 约 ¥7–12/时，一直正常
        let ds = FakeProvider([.success(snap(now, month: 20)), .failure(.network("断网")), .failure(.network("断网"))],
                              id: .deepseek)
        let cl = usdPlatform([.success(usdSnap(now, month: "11")),
                         .success(usdSnap(now.addingTimeInterval(60), month: "11.1")),
                         .success(usdSnap(now.addingTimeInterval(660), month: "11.7"))])
        let store = try multiStore([ds, cl], clock: clock, settings: ProviderSettings(), seed: seed)
        await store.refresh()
        clock.now = now.addingTimeInterval(60)
        await store.refresh()
        try check(store.ratesCny()[.deepseek] == nil, "主平台取数失败，旧时速不参与")
        clock.now = now.addingTimeInterval(660)
        await store.refresh()
        try checkEqual(store.mainProvider, .deepseek)
        try check(store.lastAutoSwitch == nil)
    }
    // 2026-10-18：主平台「自动」按 10 分钟内在跑的任务切换（任务扫描每 10 秒交给 store）
    testAsync("storeAutoSwitchSetsLastAutoSwitch") {
        let clock = FakeClock()
        let now = clock.now
        let ds = FakeProvider([.success(snap(now, month: 5))], id: .deepseek)
        let cl = usdPlatform([.success(usdSnap(now, month: "11"))])
        let store = try multiStore([ds, cl], clock: clock, settings: ProviderSettings())
        await store.refresh()
        try checkEqual(store.mainProvider, .deepseek)
        store.setRunningTasks([.siliconflow: now])
        try checkEqual(store.mainProvider, .siliconflow)
        try checkEqual(store.lastAutoSwitch?.to, .siliconflow)
        try checkEqual(store.lastAutoSwitch?.at, now)
        // 任务停了：保持上一次
        clock.now = now.addingTimeInterval(900)
        store.setRunningTasks([:])
        try checkEqual(store.mainProvider, .siliconflow)
    }
    testAsync("oneProviderFailureIsolated") {
        let clock = FakeClock()
        let ds = FakeProvider([.success(snap(clock.now)), .success(snap(clock.now.addingTimeInterval(121)))], id: .deepseek)
        let cl = usdPlatform(Array(repeating: .failure(.rateLimited(retryAfter: nil)), count: 5))
        let sf = FakeProvider(Array(repeating: .failure(.network("断网")), count: 5), id: .codexPlan)
        let store = try multiStore([ds, cl, sf], clock: clock, settings: ProviderSettings())
        await store.refresh()
        let st = store.platforms
        try checkEqual(st.first { $0.id == .deepseek }?.status, .ok)
        try checkEqual(st.first { $0.id == .siliconflow }?.status, .rateLimited(until: clock.now.addingTimeInterval(240)))
        try checkEqual(st.first { $0.id == .codexPlan }?.status, .offline)
        try checkEqual(store.currentInterval(.deepseek), 120)
        try checkEqual(store.currentInterval(.siliconflow), 240)
        try checkEqual(store.nextDueAt(.deepseek), clock.now.addingTimeInterval(120))
        try checkEqual(store.nextDueAt(.siliconflow), clock.now.addingTimeInterval(240))
        // 到点后 DeepSeek 照常刷新；硅基流动 还在退避期，不发请求
        clock.now = clock.now.addingTimeInterval(121)
        await store.tick()
        try checkEqual(ds.calls, 2)
        try checkEqual(cl.calls, 1)
        try checkEqual(sf.calls, 2)
        try checkEqual(store.platforms.first { $0.id == .deepseek }?.status, .ok)
        try checkEqual(store.currentInterval(.deepseek), 120)
        try checkEqual(store.nextDueAt(.deepseek), clock.now.addingTimeInterval(120))
    }
    testAsync("mainFallsBackToAddedPlatform") {
        let clock = FakeClock()
        let cs = InMemoryCredentialStore()
        try cs.save(Credentials(values: ["apiKey": "sk-test"]), for: .siliconflow)      // 只添加了 硅基流动
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let samples = try SampleStore(path: dir.appendingPathComponent("s.sqlite").path)
        let ds = FakeProvider([], id: .deepseek)
        let cl = usdPlatform([.success(usdSnap(clock.now, month: "1"))])
        let store = UsageStore(providers: [ds, cl], credentials: cs, samples: samples, intervalSeconds: 120,
                                     clock: { clock.now }, defaults: freshDefaults(), settings: { ProviderSettings() })
        try checkEqual(store.mainProvider, .deepseek)
        await store.refresh()
        try checkEqual(store.platforms.first { $0.id == .deepseek }?.status, .notAdded)
        try checkEqual(store.mainProvider, .siliconflow)
        try checkEqual(store.menuBarProvider, .siliconflow)
        try check(store.switchState.lastSwitchAt == nil, "回落不算切换")
        try check(store.lastAutoSwitch == nil)
    }
    testAsync("menuBarIgnoresLegacyStoredProvider") {
        let clock = FakeClock()
        let d = freshDefaults()
        d.set("siliconflow", forKey: "menuBarProvider")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let samples = try SampleStore(path: dir.appendingPathComponent("s.sqlite").path)
        let store = UsageStore(providers: [FakeProvider([]), usdPlatform([])], credentials: InMemoryCredentialStore(),
                                     samples: samples, intervalSeconds: 120, clock: { clock.now }, defaults: d,
                                     settings: { ProviderSettings() })
        // 10-19 起菜单栏不再单独选平台：旧键删掉，菜单栏跟着主平台
        try checkEqual(store.menuBarProvider, .deepseek)
        try checkEqual(store.mainProvider, .deepseek)
        try check(d.object(forKey: "menuBarProvider") == nil)
    }
    testAsync("mainSwitchPersisted") {
        let clock = FakeClock()
        let d = freshDefaults()
        @MainActor func make() throws -> UsageStore {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-store-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let samples = try SampleStore(path: dir.appendingPathComponent("s.sqlite").path)
            return UsageStore(providers: [FakeProvider([]), usdPlatform([])], credentials: InMemoryCredentialStore(),
                              samples: samples, intervalSeconds: 120, clock: { clock.now }, defaults: d,
                              settings: { ProviderSettings() })
        }
        let a = try make()
        a.pinMain(.siliconflow)
        a.setAutoMain(false)
        let b = try make()
        try checkEqual(b.mainProvider, .siliconflow)
        try checkEqual(b.switchState.auto, false)
        try checkEqual(b.switchState.pinnedUntil, clock.now.addingTimeInterval(7200))
        d.set(Data("not json".utf8), forKey: "mainSwitch")
        let c = try make()
        try checkEqual(c.switchState, MainSwitchState(main: .deepseek, auto: true))
    }
}
