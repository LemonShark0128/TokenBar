import Foundation

/// 按活动决定刷新频率（10-19 省电改动）
private final class LogBox { var lines: [String] = [] }

@MainActor
private func powerStore(_ ps: [UsageProvider], clock: FakeClock, interval: Int = 120, added: [ProviderID] = [],
                        log: LogBox = LogBox()) throws -> UsageStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-power-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let samples = try SampleStore(path: dir.appendingPathComponent("s.sqlite").path)
    let cs = InMemoryCredentialStore()
    for p in ps where p.capabilities.needsCredentials { try cs.save(Credentials(values: ["apiKey": "sk-test"]), for: p.id) }
    let d = freshDefaults()
    for id in added { d.set(true, forKey: "accountAdded.\(id.rawValue)") }
    return UsageStore(providers: ps, credentials: cs, samples: samples, intervalSeconds: interval,
                      clock: { clock.now }, timeZone: { TimeZone(secondsFromGMT: 28800)! }, defaults: d,
                      log: { log.lines.append($0) })
}

private func planSnap(_ id: ProviderID, now: Date, sessionReset: Date?) -> ProviderSnapshot {
    var s = ProviderSnapshot(provider: id, balance: nil, today: nil, month: nil, byModel: [],
                             trend7: [], source: .quota, fetchedAt: now, credential: .ok)
    s.quota = Quota(plan: nil, windows: [QuotaWindow(kind: .session, usedPercent: 30, resetsAt: sessionReset, windowMinutes: 300)],
                    observedAt: now)
    return s
}

private func plan(_ id: ProviderID, _ n: Int, now: Date, reset: Date? = nil) -> FakeProvider {
    FakeProvider((0..<n).map { _ in .success(planSnap(id, now: now, sessionReset: reset)) },
                 id: id, hasBalance: false, meter: .quota, needsCredentials: false)
}

@MainActor
func registerPowerCadenceTests() {
    testAsync("claudeAuthKeepsQuotaLogsReasonChangesAndRecovers") {
        let clock = FakeClock(), logs = LogBox()
        let old = planSnap(.claudePlan, now: clock.now, sessionReset: nil)
        let p = FakeProvider([.success(old), .failure(.unavailable("限流")), .failure(.unavailable("限流")),
                              .failure(.auth(L("cli.needsLogin"))), .failure(.auth(L("cli.needsLogin"))), .success(old)],
                             id: .claudePlan, meter: .quota, needsCredentials: false)
        let store = try powerStore([p], clock: clock, added: [.claudePlan], log: logs)
        await store.refresh()
        await store.refresh()
        await store.refresh()
        await store.refresh()
        try checkEqual(store.platforms[0].snapshot, old)
        try checkEqual(store.platforms[0].status, .credentialInvalid)
        try checkEqual(store.anomalies(), [.credentialInvalid(.claudePlan)])
        try checkEqual(logs.lines.filter { $0.contains("取数失败") }.count, 2)
        // 原因没变（还是需要登录）不重复记日志
        await store.refresh()
        try checkEqual(logs.lines.filter { $0.contains("取数失败") }.count, 2)
        // 终端里重新登录后下一次取数（定时 5 分钟或打开面板时 togglePanel 的全量刷新）就恢复
        await store.refresh()
        try checkEqual(p.calls, 6)
        try checkEqual(store.platforms[0].status, .ok)
        try checkEqual(logs.lines.filter { $0.contains("取数恢复") }.count, 1)
    }
    testAsync("claudeSourceControlsAuthRetryCadence") {
        let clock = FakeClock()
        for source in [ClaudePlanSource.desktop, .terminal, .web] {
            let p = ClaudePlanProvider(quotaFile: URL(fileURLWithPath: "/unused"), source: { source },
                                       cli: { _ in ClaudeCLIUsage.needsLogin })
            try checkEqual(p.capabilities.credentialRetryInterval, source == .web ? nil : 300)
            if source == .terminal { continue }
            let store = try powerStore([p], clock: clock, added: [.claudePlan])
            await store.refresh()
            try checkEqual(store.currentInterval(.claudePlan), source == .web ? 1800 : 300)
        }
    }
    testAsync("quotaExpiringDoesNotHideLowAndInvalidDoesNotRearmLow") {
        let clock = FakeClock()
        var old = planSnap(.claudePlan, now: clock.now, sessionReset: nil)
        old.quota?.windows[0].usedPercent = 95
        old.credential = .expiring(days: 2)
        let p = FakeProvider([.success(old), .failure(.auth("登录失效")), .success(old)],
                             id: .claudePlan, meter: .quota, needsCredentials: false)
        let store = try powerStore([p], clock: clock, added: [.claudePlan])
        var tracker = PlatformAlertTracker()
        await store.refresh()
        let first = store.anomalies(lowThreshold: [.claudePlan: 10])
        try check(first.contains(.expiring(.claudePlan)))
        try checkEqual(tracker.lowToFire(first, now: clock.now, repeatHours: 0), [.claudePlan])
        await store.refresh()
        let invalid = store.anomalies(lowThreshold: [.claudePlan: 10])
        try checkEqual(invalid, [.credentialInvalid(.claudePlan)])
        try checkEqual(tracker.lowToFire(invalid, now: clock.now, repeatHours: 0), [])
        await store.refresh()
        try checkEqual(tracker.lowToFire(store.anomalies(lowThreshold: [.claudePlan: 10]), now: clock.now, repeatHours: 0), [])
    }
    // ---------------------------------------------------------------- 纯函数

    test("powerSteadyInterval") {
        try checkEqual((0...7).map { PollCadence.steadyInterval(base: 60, unchanged: $0) }, [60, 60, 60, 120, 240, 240, 240, 240])
        try checkEqual((0...4).map { PollCadence.steadyInterval(base: 300, unchanged: $0) }, [300, 300, 300, 300, 300])
        try checkEqual(PollCadence.steadyInterval(base: 900, unchanged: 9), 900)   // 基础间隔本身更长时不缩短
    }
    test("powerNextDueResetNudge") {
        let now = Date(timeIntervalSince1970: 1_792_022_400)
        try checkEqual(PollCadence.nextDue(anchor: now, interval: 1800, resetAt: nil, now: now), now.addingTimeInterval(1800))
        try checkEqual(PollCadence.nextDue(anchor: now, interval: 1800, resetAt: now.addingTimeInterval(600), now: now),
                       now.addingTimeInterval(600 + PollCadence.resetSlack))
        try checkEqual(PollCadence.nextDue(anchor: now, interval: 1800, resetAt: now.addingTimeInterval(-60), now: now),
                       now.addingTimeInterval(1800))   // 重置时间已过不提前
        try checkEqual(PollCadence.nextDue(anchor: now, interval: 120, resetAt: now.addingTimeInterval(600), now: now),
                       now.addingTimeInterval(120))
    }
    test("powerIsDueHandlesClockRollback") {
        let now = Date(timeIntervalSince1970: 1_792_022_400)
        try check(PollCadence.isDue(nextDue: nil, now: now, interval: 120))
        try check(PollCadence.isDue(nextDue: now.addingTimeInterval(0.5), now: now, interval: 120))
        try check(!PollCadence.isDue(nextDue: now.addingTimeInterval(100), now: now, interval: 120))
        try check(PollCadence.isDue(nextDue: now.addingTimeInterval(3 * 3600), now: now, interval: 1800), "时钟往回拨了：马上补一次")
    }
    test("powerLabel") {
        try checkEqual(PollCadence.label(1800), "30 分钟")
        try checkEqual(PollCadence.label(120), "2 分钟")
        try checkEqual(PollCadence.label(90), "90 秒")
    }
    test("powerRunningScanInterval") {
        let now = Date(timeIntervalSince1970: 1_792_022_400)
        try checkEqual(RunningScanCadence.interval(visible: true, lastTask: nil, now: now), 10)
        try checkEqual(RunningScanCadence.interval(visible: false, lastTask: now.addingTimeInterval(-120), now: now), 2)
        try checkEqual(RunningScanCadence.interval(visible: false, lastTask: now.addingTimeInterval(-360), now: now), 2)
        try checkEqual(RunningScanCadence.interval(visible: false, lastTask: nil, now: now), nil)
    }
    test("powerScanReportsLatestLogChange") {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tb-scan-\(UUID().uuidString)")
        let proj = root.appendingPathComponent("claude/projects/p1", isDirectory: true)
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let f = proj.appendingPathComponent("a.jsonl")
        try Data("{}\n".utf8).write(to: f)
        let m = Date().addingTimeInterval(-120)
        try FileManager.default.setAttributes([.modificationDate: m], ofItemAtPath: f.path)
        let r = RunningTasks.scanDetailed(enabled: [.claudePlan, .codexPlan], claudeDir: root.appendingPathComponent("claude"),
                                          codexSessions: root.appendingPathComponent("codex"), now: Date())
        try checkEqual(r.tasks, [])
        try check(abs((r.lastChange[.claudePlan] ?? .distantPast).timeIntervalSince(m)) < 1)
        try checkEqual(r.lastChange[.codexPlan], nil)
    }

    // ---------------------------------------------------------------- UsageStore

    testAsync("quotaVisibilityRefreshesOnlyOldReadings") {
        let clock = FakeClock()
        let p = plan(.claudePlan, 8, now: clock.now)
        let store = try powerStore([p], clock: clock, added: [.claudePlan])
        await store.tick()
        try checkEqual(store.currentInterval(.claudePlan), 300)
        clock.now = clock.now.addingTimeInterval(61)
        await store.setSurfaceVisible(true)
        try checkEqual(p.calls, 2)
        try checkEqual(store.currentInterval(.claudePlan), 60)
        await store.setSurfaceVisible(true)
        try checkEqual(p.calls, 2)
        await store.setSurfaceVisible(false)
        try checkEqual(store.currentInterval(.claudePlan), 300)
    }
    // 用户 2026-11-13 反馈「刷新慢」：菜单栏显示的套餐也应按可见节奏刷新。
    testAsync("quotaMenuBarVisibilityReschedulesOnlyChangedProviders") {
        let clock = FakeClock()
        let start = clock.now
        let p = plan(.claudePlan, 8, now: start)
        let other = plan(.codexPlan, 8, now: start)
        let payg = FakeProvider([.success(snap(start))])
        let store = try powerStore([p, other, payg], clock: clock, added: [.claudePlan, .codexPlan])
        await store.tick()
        let paygDue = store.nextDueAt(.deepseek)
        clock.now = start.addingTimeInterval(61)
        await store.setMenuBarShown([.claudePlan, .deepseek])
        try checkEqual(store.currentInterval(.claudePlan), 60)
        try checkEqual(store.currentInterval(.codexPlan), 300)
        try checkEqual(p.calls, 2)
        try checkEqual(other.calls, 1)
        try checkEqual(store.currentInterval(.deepseek), 120)
        try checkEqual(store.nextDueAt(.deepseek), paygDue)
        let due = store.nextDueAt(.claudePlan)
        clock.now = start.addingTimeInterval(122)
        await store.setMenuBarShown([.claudePlan, .deepseek])
        try checkEqual(p.calls, 2)
        try checkEqual(store.nextDueAt(.claudePlan), due)
        await store.setMenuBarShown([])
        try checkEqual(store.currentInterval(.claudePlan), 300)
        try checkEqual(store.nextDueAt(.claudePlan), start.addingTimeInterval(361))
        await store.tick()
        try checkEqual(p.calls, 2)
        await store.setSurfaceVisible(true)
        await store.setMenuBarShown([.claudePlan])
        await store.setSurfaceVisible(false)
        try checkEqual(store.currentInterval(.claudePlan), 60)
        try checkEqual(store.currentInterval(.codexPlan), 300)
    }
    testAsync("quotaMenuBarVisibilityPreservesFailureBackoff") {
        for failure: ProviderError in [.network("offline"), .auth("expired")] {
            let clock = FakeClock()
            let p = FakeProvider([.failure(failure), .failure(failure)], id: .claudePlan,
                                 hasBalance: false, meter: .quota, needsCredentials: false)
            let store = try powerStore([p], clock: clock, added: [.claudePlan])
            await store.tick()
            let interval = store.currentInterval(.claudePlan)
            let due = store.nextDueAt(.claudePlan)
            clock.now = clock.now.addingTimeInterval(61)
            await store.setMenuBarShown([.claudePlan])
            try checkEqual(store.currentInterval(.claudePlan), interval)
            try checkEqual(store.nextDueAt(.claudePlan), due)
            await store.tick()
            try checkEqual(p.calls, 1)
            clock.now = due!
            await store.tick()
            try checkEqual(p.calls, 2)
            try checkEqual(store.currentInterval(.claudePlan), interval == 300 ? 600 : 1800)
        }
    }
    testAsync("quotaMenuBarVisibilityWhilePausedDoesNotFetch") {
        let clock = FakeClock()
        let p = plan(.claudePlan, 4, now: clock.now)
        let store = try powerStore([p], clock: clock, added: [.claudePlan])
        store.setPaused(true)
        await store.setMenuBarShown([.claudePlan])
        try checkEqual(store.currentInterval(.claudePlan), 60)
        await store.tick()
        await store.refresh()
        try checkEqual(p.calls, 0)
    }
    test("menuBarSynchronizesShownProvidersInBothStyles") {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let menu = try String(contentsOf: app.appendingPathComponent("Sources/App/MenuBar.swift"), encoding: .utf8)
        try check(menu.contains("syncMenuBarShown(Set(current))"), "双槽选择后须同步显示集合")
        try check(menu.contains("syncMenuBarShown(model.needsSetup ? [] : [mb.flatMap { ProviderID(rawValue: $0.id) } ?? model.mainID])"), "经典样式须同步显示平台")
        try check(menu.contains("await store.setMenuBarShown(ids)"), "须调用 Store 同步接口")
        try check(menu.contains("guard ids != lastMenuBarShown"), "集合不变时不得重复同步")
    }
    testAsync("quotaFailuresBackoffAndSuccessClears") {
        let clock = FakeClock()
        let p = FakeProvider([.failure(.network("offline")), .failure(.network("offline")),
                              .success(planSnap(.claudePlan, now: clock.now, sessionReset: nil)),
                              .failure(.network("offline"))],
                             id: .claudePlan, hasBalance: false, meter: .quota, needsCredentials: false)
        let store = try powerStore([p], clock: clock, added: [.claudePlan])
        for expected: TimeInterval in [300, 600, 300, 300] {
            await store.tick()
            try checkEqual(store.currentInterval(.claudePlan), expected)
            clock.now = clock.now.addingTimeInterval(expected)
        }
        try checkEqual(p.calls, 4)
    }
    testAsync("quotaAuthSettlesThenRetries") {
        let clock = FakeClock()
        let start = clock.now
        let p = FakeProvider([.failure(.auth("expired")), .success(planSnap(.claudePlan, now: start, sessionReset: nil))],
                             id: .claudePlan, hasBalance: false, meter: .quota, needsCredentials: false)
        let store = try powerStore([p], clock: clock, added: [.claudePlan])
        await store.tick()
        try checkEqual(store.currentInterval(.claudePlan), 1800)
        clock.now = start.addingTimeInterval(1700)
        await store.tick()
        try checkEqual(p.calls, 1)
        clock.now = start.addingTimeInterval(1800)
        await store.tick()
        try checkEqual(p.calls, 2)
        try checkEqual(store.currentInterval(.claudePlan), 300)
    }
    testAsync("quotaPausedStoreSkipsTickAndManualFetch") {
        let clock = FakeClock()
        let p = plan(.claudePlan, 4, now: clock.now)
        let store = try powerStore([p], clock: clock, added: [.claudePlan])
        store.setPaused(true)
        store.setPaused(true)
        await store.tick()
        await store.refresh()
        await store.setSurfaceVisible(true)
        try checkEqual(p.calls, 0)
    }
    testAsync("powerFirstScanActiveDoesNotDoubleFetch") {
        let clock = FakeClock()
        let p = plan(.claudePlan, 5, now: clock.now)
        let store = try powerStore([p], clock: clock, added: [.claudePlan])
        await store.tick()
        try checkEqual(p.calls, 1)   // 启动时第一次扫到有活动：刚取过，不再补一次
    }
    testAsync("powerResetNudgeWhileIdle") {
        let clock = FakeClock()
        let start = clock.now
        let p = plan(.claudePlan, 5, now: start, reset: start.addingTimeInterval(600))
        let store = try powerStore([p], clock: clock, added: [.claudePlan])
        await store.tick()
        try checkEqual(p.calls, 1)
        clock.now = start.addingTimeInterval(600 + PollCadence.resetSlack)
        await store.tick()
        try checkEqual(p.calls, 2)   // 5 小时窗口重置后补刷一次
    }
    testAsync("powerNotAddedPlanIsQuiet") {
        let clock = FakeClock()
        let p = plan(.claudePlan, 3, now: clock.now)
        let log = LogBox()
        let store = try powerStore([p], clock: clock, log: log)
        await store.tick()
        try checkEqual(p.calls, 0)
        try checkEqual(log.lines.filter { $0.contains("Claude 套餐：") }, [])
    }
    testAsync("powerManualRefreshIgnoresIdle") {
        let clock = FakeClock()
        let p = plan(.claudePlan, 5, now: clock.now)
        let store = try powerStore([p], clock: clock, added: [.claudePlan])
        await store.tick()
        clock.now = clock.now.addingTimeInterval(30)
        await store.refresh()
        try checkEqual(p.calls, 2)   // 打开面板 / 唤醒照旧立即刷
    }

    testAsync("powerSteadyBalanceDoublesAndResets") {
        let clock = FakeClock()
        let start = clock.now
        let same = (0..<9).map { _ in Result<ProviderSnapshot, ProviderError>.success(snap(start)) }
        let p = FakeProvider(same + [.success(snap(start, balance: 20)), .success(snap(start, balance: 20))])
        let log = LogBox()
        let store = try powerStore([p], clock: clock, interval: 60, log: log)
        var seen: [TimeInterval] = []
        for _ in 0..<6 {
            await store.tick()
            seen.append(store.currentInterval(.deepseek))
            clock.now = clock.now.addingTimeInterval(seen.last!)
        }
        // 第 1 次没得比；第 2、3 次没变（1、2 次）；第 4 次连续 3 次没变 → 翻倍
        try checkEqual(seen, [60, 60, 60, 120, 240, 240])
        try check(log.lines.contains("DeepSeek：余额连续 3 次没变，改为每 2 分钟一次"), "\(log.lines)")
        await store.tick()
        try checkEqual(store.currentInterval(.deepseek), 240)   // 最多 4 分钟
        // 打开面板只立刻取一次，不清零放慢（11/6 用户定 round7-scout 第 1 条乙）
        clock.now = clock.now.addingTimeInterval(5)
        await store.refresh()
        try checkEqual(p.calls, 8)
        try checkEqual(store.currentInterval(.deepseek), 240)
        try checkEqual(store.nextDueAt(.deepseek), clock.now.addingTimeInterval(240))   // 开面板取过一次，下次自动查从现在按放慢的间隔算
        try check(!log.lines.contains("DeepSeek：恢复每 1 分钟一次"), "\(log.lines)")
        // 点「刷新」按钮才回到基础间隔
        clock.now = clock.now.addingTimeInterval(5)
        await store.refresh(resetSlowdown: true)
        try checkEqual(store.currentInterval(.deepseek), 60)
        try check(log.lines.contains("DeepSeek：恢复每 1 分钟一次"), "\(log.lines)")
        // 余额变了也回到基础间隔
        clock.now = clock.now.addingTimeInterval(60)
        await store.tick()
        try checkEqual(store.currentInterval(.deepseek), 60)
    }
    // 解锁 / 改刷新间隔会调 start()：原来 interval = [:] 把正在限流的退避也清了，限流一结束就按基础间隔再撞
    testAsync("startKeepsRateLimitBackoff") {
        let clock = FakeClock()
        let start = clock.now
        let same = (0..<5).map { _ in Result<ProviderSnapshot, ProviderError>.success(snap(start)) }
        let p = FakeProvider(same + [.failure(.rateLimited)])
        let store = try powerStore([p], clock: clock, interval: 60)
        for _ in 0..<5 {
            await store.tick()
            clock.now = clock.now.addingTimeInterval(store.currentInterval(.deepseek))
        }
        await store.tick()
        try checkEqual(store.currentInterval(.deepseek), 480)
        store.start(intervalSeconds: 60)
        store.setPaused(true)            // 关掉 start 建的定时器，测试里不让它跑
        try checkEqual(store.currentInterval(.deepseek), 480)
        // 用户把间隔调到比退避还长：按新间隔，不能反而更勤
        store.setPaused(false)
        store.start(intervalSeconds: 1800)
        store.setPaused(true)
        try checkEqual(store.currentInterval(.deepseek), 1800)
    }
    testAsync("powerSteadyThenRateLimitedTakesLonger") {
        let clock = FakeClock()
        let start = clock.now
        let same = (0..<5).map { _ in Result<ProviderSnapshot, ProviderError>.success(snap(start)) }
        let p = FakeProvider(same + [.failure(.rateLimited)])
        let store = try powerStore([p], clock: clock, interval: 60)
        for _ in 0..<5 {
            await store.tick()
            clock.now = clock.now.addingTimeInterval(store.currentInterval(.deepseek))
        }
        try checkEqual(store.currentInterval(.deepseek), 240)
        await store.tick()
        try checkEqual(store.currentInterval(.deepseek), 480)   // 限流退避从放慢后的间隔再翻倍
    }
    test("panelOpenFetchesOnce") {
        // 打开面板只取一次数：togglePanel 已调 model.fetch()，面板根视图出现时不能再取一次
        // （11/6 日志：每次开面板同一平台 1 秒内取两次，「余额没变」计数一次 +2，放慢被抬得太快）
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App")
        let panels = try String(contentsOf: app.appendingPathComponent("Panels.swift"), encoding: .utf8)
        let root = panels.components(separatedBy: "struct RootView").dropFirst().first?
            .components(separatedBy: "\nstruct ").first ?? ""
        try check(!root.isEmpty, "Panels.swift 里找不到 RootView")
        try check(!root.contains("fetch("), "RootView 不应再取数（togglePanel 已取）")
        try check(!root.contains("onAppear") && !root.contains(".task"), "RootView 出现时不应再做事（取数在 togglePanel）")
        let menu = try String(contentsOf: app.appendingPathComponent("MenuBar.swift"), encoding: .utf8)
        let toggle = menu.components(separatedBy: "func togglePanel()").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        try checkEqual(toggle.components(separatedBy: "model.fetch()").count - 1, 1)
    }
}
