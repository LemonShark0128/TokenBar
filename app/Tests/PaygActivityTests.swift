import Foundation

private let paygEpoch = Date(timeIntervalSince1970: 1_792_022_400)
private func paygSamples(_ rows: [(Double, String)]) -> [Sample] {
    rows.map { Sample(provider: .deepseek, t: paygEpoch.addingTimeInterval($0.0),
                      balance: Decimal(string: $0.1)!, cumulativeCost: nil, currency: .cny) }
}

@MainActor
func registerPaygActivityTests() {
    // 每行的期望独立手算；变异验证覆盖阈值、窗口、延续、充值和空输入。
    let cases: [(String, [(Double, String)], Double, Double?)] = [
        ("small", [(0,"10"),(60,"9.99")], 60, nil),
        ("threshold", [(0,"10"),(60,"9.95")], 60, 60),
        ("cumulative", [(0,"10"),(60,"9.98"),(660,"9.95")], 660, 660),
        ("outsideWindow", [(0,"10"),(60,"9.98"),(661,"9.95")], 661, nil),
        ("continued", [(0,"10"),(60,"9.95"),(660,"9.94")], 1200, 660),
        ("expired", [(0,"10"),(60,"9.95")], 661, nil),
        ("inclusiveExpiry", [(0,"10"),(60,"9.95")], 660, 60),
        ("restartNeedsThreshold", [(0,"10"),(60,"9.95"),(661,"9.94")], 661, nil),
        ("rechargeAccumulates", [(0,"10"),(60,"9.98"),(120,"20"),(180,"19.97")], 180, 180),
        ("rechargeKeepsActive", [(0,"10"),(60,"9.95"),(120,"20")], 120, 60),
        ("rechargeDoesNotStart", [(0,"10"),(60,"20")], 60, nil),
        ("empty", [], 60, nil),
        ("single", [(0,"10")], 60, nil),
        // 隔了很久才拿到的读数（重启、睡眠唤醒后）：那段时间的下降不算「过去 10 分钟」
        ("longGapIgnored", [(0,"10"),(1201,"9.5")], 1201, nil),
        ("gapAtLimitCounts", [(0,"10"),(1200,"9.5")], 1200, 1200),
        ("longGapThenRealUse", [(0,"10"),(3600,"9.5"),(3660,"9.45")], 3660, 3660)
    ]
    for (name, rows, now, expected) in cases {
        test("payg_\(name)") {
            try checkEqual(PaygActivity.lastActive(samples: paygSamples(rows), now: paygEpoch.addingTimeInterval(now)),
                           expected.map { paygEpoch.addingTimeInterval($0) })
        }
    }
    for id in [ProviderID.deepseek, .siliconflow, .kimi] {
        testAsync("paygStore_\(id.rawValue)") {
            let clock = FakeClock()
            let defaults = freshDefaults()
            for p in [id, .claudePlan] { defaults.set(true, forKey: UsageStore.addedKey(p)) }
            let p = FakeProvider([], id: id, needsCredentials: false)
            let claude = FakeProvider([], id: .claudePlan, meter: .quota, needsCredentials: false)
            let samples = try SampleStore(path: ":memory:")
            let logs = LogLines()
            let store = UsageStore(providers: [p, claude], credentials: InMemoryCredentialStore(), samples: samples,
                                   intervalSeconds: 120, clock: { clock.now }, defaults: defaults, log: { logs.add($0) })
            store.pinMain(.claudePlan)
            store.setAutoMain(true)
            func fetch(_ balance: Decimal, after: Double = 60) async {
                clock.now = clock.now.addingTimeInterval(after)
                var s = snap(clock.now, balance: balance)
                s.provider = id
                p.results.append(.success(s))
                await store.tick()
            }
            await fetch(10)
            await fetch(Decimal(string: "9.98")!, after: 120)
            await fetch(Decimal(string: "9.95")!, after: 120)
            try checkEqual(store.paygActiveIDs(now: clock.now), [id])
            try checkEqual(store.mainProvider, id)
            try checkEqual(store.pendingSwitchNotice, "\(ProviderRegistry.displayName(id)) 余额在减少，已切换显示")
            L10n.lang = .en
            let english = store.pendingSwitchNotice
            let englishName = ProviderRegistry.displayName(id)
            L10n.lang = .zh
            try checkEqual(english, "\(englishName) balance is dropping — now showing it")
            try checkEqual(store.currentInterval(id), 60)
            store.setRunningTasks([.claudePlan: clock.now])
            // 2026-11-06 乙：两个同时在用不轮流；还没有常用平台时留在正在显示的那个
            try checkEqual(store.mainProvider, id)
            try checkEqual(store.menuBarRotation, [id])
            store.pinMain(.claudePlan)
            await fetch(Decimal(string: "9.94")!)
            try checkEqual(store.mainProvider, .claudePlan)
            store.setAutoMain(false)
            await fetch(Decimal(string: "9.93")!)
            try checkEqual(store.mainProvider, .claudePlan)
            store.setAutoMain(true)
            // 超过一小时的小额下降仍应延续，不能因裁剪历史失去起始阈值。
            for n in 1...70 { await fetch(Decimal(string: "9.93")! - Decimal(n) / 1000) }
            try checkEqual(store.currentInterval(id), 60)
            for _ in 0..<10 { await fetch(Decimal(string: "9.86")!) }
            try checkEqual(store.currentInterval(id), 60)
            try checkEqual(store.paygActiveIDs(now: clock.now), [id])
            try checkEqual(store.paygActiveIDs(now: clock.now.addingTimeInterval(1)), [])
            // 正在用期间余额不变：不写「连续 N 次没变，改为…」（实际仍是每分钟一次）
            try check(!logs.lines.contains { $0.contains("没变，改为") })
            clock.now = clock.now.addingTimeInterval(1)
            store.setRunningTasks([.claudePlan: clock.now])
            try checkEqual(store.menuBarRotation, [.claudePlan])
            try checkEqual(store.currentInterval(id), 120)
            try checkEqual(store.paygActiveIDs(now: clock.now), [])
            try checkEqual(store.nextDueAt(id), clock.now.addingTimeInterval(119))
            for n in 1...3 {
                await fetch(Decimal(string: "9.86")!, after: 120)
                try checkEqual(store.currentInterval(id), n == 3 ? 240 : 120)
            }
            try checkEqual(logs.lines.filter { $0.contains("不再算正在使用") }.count, 1)
            await fetch(9, after: 240)
            try checkEqual(store.currentInterval(id), 60)
            try await store.removeAccount(id)
            defaults.set(true, forKey: UsageStore.addedKey(id))
            // 重新添加后的空样本不能恢复被删除的活动。
            try await store.saveCredentials([:], for: id)
            store.setRunningTasks([.claudePlan: clock.now])
            try checkEqual(store.menuBarRotation, [.claudePlan])
            try checkEqual(store.currentInterval(id), 120)
        }
    }
    // 正在用期间被限流：仍按限流退避翻倍，不被「每分钟一次」压回去（审核必须改）
    testAsync("paygActiveRateLimitStillBacksOff") {
        let clock = FakeClock()
        let defaults = freshDefaults()
        defaults.set(true, forKey: UsageStore.addedKey(.deepseek))
        let p = FakeProvider([], needsCredentials: false)
        let store = UsageStore(providers: [p], credentials: InMemoryCredentialStore(), samples: try SampleStore(path: ":memory:"),
                               intervalSeconds: 120, clock: { clock.now }, defaults: defaults)
        for b in ["10", "9.9"] {
            clock.now = clock.now.addingTimeInterval(60)
            p.results.append(.success(snap(clock.now, balance: Decimal(string: b)!)))
            await store.refresh(.deepseek)
        }
        try checkEqual(store.currentInterval(.deepseek), 60)
        var seen: [Double] = []
        for _ in 0..<3 {
            // 限流期间不会再取；等过了限流时间再试（仍在「正在用」的 10 分钟内）
            clock.now = clock.now.addingTimeInterval((seen.last ?? 29) + 1)
            p.results.append(.failure(.rateLimited))
            await store.refresh(.deepseek)
            try checkEqual(store.paygActiveIDs(now: clock.now), [])
            seen.append(store.currentInterval(.deepseek))
        }
        try checkEqual(seen, [120, 240, 480])
        // 限流结束、又扣了钱：回到每分钟一次
        clock.now = clock.now.addingTimeInterval(481)
        p.results.append(.success(snap(clock.now, balance: Decimal(string: "9.8")!)))
        await store.refresh(.deepseek)
        try checkEqual(store.currentInterval(.deepseek), 60)
        try checkEqual(store.paygActiveIDs(now: clock.now), [.deepseek])
        try checkEqual(store.nextDueAt(.deepseek), clock.now.addingTimeInterval(60))
    }
    // 没有余额的按量平台（OpenRouter 普通 Key 没设上限）：本月累计花费上涨也算「正在用」（2026-11-06 审查后续 1）
    func costSamples(_ rows: [(Double, String?, String?)]) -> [Sample] {
        rows.map { Sample(provider: .openrouter, t: paygEpoch.addingTimeInterval($0.0), balance: $0.1.map { Decimal(string: $0)! },
                          cumulativeCost: $0.2.map { Decimal(string: $0)! }, currency: .usd) }
    }
    test("paygCostRiseCountsWithoutBalance") {
        let at = paygEpoch.addingTimeInterval(60)
        try checkEqual(PaygActivity.lastActive(samples: costSamples([(0, nil, "1"), (60, nil, "1.05")]), now: at), at)
        try checkEqual(PaygActivity.lastActive(samples: costSamples([(0, nil, "1"), (60, nil, "1.005")]), now: at), nil)
        // 门槛按币种：美元 $0.01（约 ¥0.07，和人民币 ¥0.05 相当），$0.02 就算在用
        try checkEqual(PaygActivity.lastActive(samples: costSamples([(0, nil, "1"), (60, nil, "1.02")]), now: at), at)
        try checkEqual(PaygActivity.threshold(.cny), Decimal(string: "0.05")!)
        // 换月清零（累计变少）不算
        try checkEqual(PaygActivity.lastActive(samples: costSamples([(0, nil, "30"), (60, nil, "0")]), now: at), nil)
        // 一条有余额、一条只有花费：口径不同，不能拿 18 和 -12 比
        try checkEqual(PaygActivity.lastActive(samples: costSamples([(0, "18", "12"), (60, nil, "12")]), now: at), nil)
        // 有余额时照旧只看余额（花费涨了、余额没降：不算）
        try checkEqual(PaygActivity.lastActive(samples: costSamples([(0, "18", "12"), (60, "18", "12.5")]), now: at), nil)
    }
    testAsync("paygStoreCostOnlyPlatformSwitchesWithSpendNotice") {
        let clock = FakeClock()
        let defaults = freshDefaults()
        for p in [ProviderID.openrouter, .claudePlan] { defaults.set(true, forKey: UsageStore.addedKey(p)) }
        let p = FakeProvider([], id: .openrouter, currency: .usd, needsCredentials: false)
        let claude = FakeProvider([], id: .claudePlan, meter: .quota, needsCredentials: false)
        let store = UsageStore(providers: [p, claude], credentials: InMemoryCredentialStore(), samples: try SampleStore(path: ":memory:"),
                               intervalSeconds: 120, clock: { clock.now }, defaults: defaults)
        store.pinMain(.claudePlan)
        store.setAutoMain(true)
        for month in ["10", "10.03", "10.06"] {
            clock.now = clock.now.addingTimeInterval(120)
            p.results.append(.success(ProviderSnapshot(provider: .openrouter, balance: nil, today: Money(amount: 1, currency: .usd),
                                                       month: Money(amount: Decimal(string: month)!, currency: .usd), byModel: [],
                                                       trend7: [], source: .bill, fetchedAt: clock.now, credential: .ok)))
            await store.tick()
        }
        try checkEqual(store.mainProvider, .openrouter)
        // 没有余额：不能说「余额在减少」
        try checkEqual(store.pendingSwitchNotice, "OpenRouter 有新的花费，已切换显示")
        L10n.lang = .en
        let english = store.pendingSwitchNotice
        L10n.lang = .zh
        try checkEqual(english, "OpenRouter has new spending — now showing it")
    }
}
