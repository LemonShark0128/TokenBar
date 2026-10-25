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
    // ---------------------------------------------------------------- 纯函数

    test("powerIdleIntervals") {
        try checkEqual(PollCadence.idleInterval(.claudePlan), 1800)
        try checkEqual(PollCadence.idleInterval(.codexPlan), 600)
        try checkEqual(PollCadence.idleInterval(.deepseek), nil)
        try checkEqual(PollCadence.idleInterval(.siliconflow), nil)
    }
    test("powerIsActiveWindow") {
        let now = Date(timeIntervalSince1970: 1_792_022_400)
        try check(!PollCadence.isActive(lastActivity: nil, now: now))
        try check(PollCadence.isActive(lastActivity: now.addingTimeInterval(-14 * 60), now: now))
        try check(!PollCadence.isActive(lastActivity: now.addingTimeInterval(-16 * 60), now: now))
        try check(PollCadence.isActive(lastActivity: now.addingTimeInterval(60), now: now), "略在未来（时钟误差）算活动")
        try check(!PollCadence.isActive(lastActivity: now.addingTimeInterval(3 * 3600), now: now), "时钟回拨后远在未来的不算")
    }
    test("powerQuotaInterval") {
        try checkEqual(PollCadence.quotaInterval(base: 120, idle: 1800, active: true), 120)
        try checkEqual(PollCadence.quotaInterval(base: 120, idle: 1800, active: false), 1800)
        try checkEqual(PollCadence.quotaInterval(base: 300, idle: 600, active: false), 600)
        try checkEqual(PollCadence.quotaInterval(base: 300, idle: nil, active: false), 300)
    }
    test("powerSteadyInterval") {
        try checkEqual((0...7).map { PollCadence.steadyInterval(base: 60, unchanged: $0) }, [60, 60, 60, 120, 240, 480, 600, 600])
        try checkEqual((0...4).map { PollCadence.steadyInterval(base: 300, unchanged: $0) }, [300, 300, 300, 600, 600])
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
        try checkEqual(RunningScanCadence.interval(visible: false, lastTask: now.addingTimeInterval(-120), now: now), 10)
        try checkEqual(RunningScanCadence.interval(visible: false, lastTask: now.addingTimeInterval(-360), now: now), 30)
        try checkEqual(RunningScanCadence.interval(visible: false, lastTask: nil, now: now), 30)
    }
    test("powerDesktopChangedAt") {
        typealias S = ClaudeAppUsageSource.Sample
        let t = { (m: Double) in Date(timeIntervalSince1970: 1_792_022_400 + m * 60) }
        // 桌面 App 开着就每 15 分钟记一条，额度不变的记录不算活动
        try checkEqual(PlanActivity.desktopChangedAt([S(t: t(0), fh: 10, sd: 5), S(t: t(15), fh: 10, sd: 5)]), nil)
        try checkEqual(PlanActivity.desktopChangedAt([S(t: t(0), fh: 10), S(t: t(15), fh: 12), S(t: t(30), fh: 12)]), t(15))
        try checkEqual(PlanActivity.desktopChangedAt([S(t: t(0), fh: 10, sd: 5), S(t: t(15), fh: 10, sd: 6)]), t(15))
        try checkEqual(PlanActivity.desktopChangedAt([S(t: t(0), fh: 10)]), nil)
    }
    test("powerDesktopProbeCachesByMtime") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("plan-usage-history.json")
        let probe = DesktopActivityProbe()
        try checkEqual(probe.changedAt(f), nil)   // 文件不在
        let ms = 1_792_022_400_000.0
        try Data(#"{"version":2,"samples":[{"t":\#(ms),"u":{"fh":10}},{"t":\#(ms + 900_000),"u":{"fh":14}}]}"#.utf8).write(to: f)
        try checkEqual(probe.changedAt(f), Date(timeIntervalSince1970: 1_792_022_400 + 900))
        try checkEqual(probe.changedAt(f), Date(timeIntervalSince1970: 1_792_022_400 + 900))
        try checkEqual(probe.parseCount, 1)   // 文件没变不再解析
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

    testAsync("powerClaudeIdleSlowsTo30Minutes") {
        let clock = FakeClock()
        let start = clock.now
        let p = plan(.claudePlan, 5, now: start)
        let log = LogBox()
        let store = try powerStore([p], clock: clock, added: [.claudePlan], log: log)
        try checkEqual(store.currentInterval(.claudePlan), 120)   // 还没扫过活动：照旧
        await store.tick()
        try checkEqual(p.calls, 1)
        await store.setPlanActivity([:])
        try checkEqual(store.currentInterval(.claudePlan), 1800)
        try check(log.lines.contains("Claude 套餐：空闲，改为每 30 分钟一次"), "\(log.lines)")
        await store.setPlanActivity([:])
        try checkEqual(log.lines.filter { $0.contains("空闲") }.count, 1)   // 状态没变不重复写
        clock.now = start.addingTimeInterval(120)
        await store.tick()
        try checkEqual(p.calls, 1)   // 空闲后 2 分钟那一拍不刷
        clock.now = start.addingTimeInterval(1800)
        await store.tick()
        try checkEqual(p.calls, 2)
    }
    testAsync("powerClaudeBecomingActiveRefreshesNow") {
        let clock = FakeClock()
        let start = clock.now
        let p = plan(.claudePlan, 5, now: start)
        let log = LogBox()
        let store = try powerStore([p], clock: clock, added: [.claudePlan], log: log)
        await store.tick()
        await store.setPlanActivity([:])
        clock.now = start.addingTimeInterval(300)
        await store.setPlanActivity([.claudePlan: clock.now])
        try checkEqual(p.calls, 2)   // 从空闲变成有活动：立即刷一次
        try checkEqual(store.currentInterval(.claudePlan), 120)
        try check(log.lines.contains { $0.hasPrefix("Claude 套餐：有活动") }, "\(log.lines)")
        await store.setPlanActivity([.claudePlan: clock.now])
        try checkEqual(p.calls, 2)   // 一直有活动不重复刷
    }
    testAsync("powerFirstScanActiveDoesNotDoubleFetch") {
        let clock = FakeClock()
        let p = plan(.claudePlan, 5, now: clock.now)
        let store = try powerStore([p], clock: clock, added: [.claudePlan])
        await store.tick()
        await store.setPlanActivity([.claudePlan: clock.now])
        try checkEqual(p.calls, 1)   // 启动时第一次扫到有活动：刚取过，不再补一次
    }
    testAsync("powerResetNudgeWhileIdle") {
        let clock = FakeClock()
        let start = clock.now
        let p = plan(.claudePlan, 5, now: start, reset: start.addingTimeInterval(600))
        let store = try powerStore([p], clock: clock, added: [.claudePlan])
        await store.setPlanActivity([:])
        await store.tick()
        try checkEqual(p.calls, 1)
        clock.now = start.addingTimeInterval(600 + PollCadence.resetSlack)
        await store.tick()
        try checkEqual(p.calls, 2)   // 5 小时窗口重置后补刷一次
    }
    testAsync("powerCodexIdleIs10Minutes") {
        let clock = FakeClock()
        let p = plan(.codexPlan, 3, now: clock.now)
        let log = LogBox()
        let store = try powerStore([p], clock: clock, added: [.codexPlan], log: log)
        await store.setPlanActivity([:])
        try checkEqual(store.currentInterval(.codexPlan), 600)
        try check(log.lines.contains("Codex 套餐：空闲，改为每 10 分钟一次"), "\(log.lines)")
    }
    testAsync("powerNotAddedPlanIsQuiet") {
        let clock = FakeClock()
        let p = plan(.claudePlan, 3, now: clock.now)
        let log = LogBox()
        let store = try powerStore([p], clock: clock, log: log)
        await store.setPlanActivity([:])
        await store.setPlanActivity([.claudePlan: clock.now])
        try checkEqual(p.calls, 0)
        try checkEqual(log.lines.filter { $0.contains("Claude 套餐：") }, [])
    }
    testAsync("powerManualRefreshIgnoresIdle") {
        let clock = FakeClock()
        let p = plan(.claudePlan, 5, now: clock.now)
        let store = try powerStore([p], clock: clock, added: [.claudePlan])
        await store.setPlanActivity([:])
        await store.tick()
        clock.now = clock.now.addingTimeInterval(30)
        await store.refresh()
        try checkEqual(p.calls, 2)   // 打开面板 / 唤醒照旧立即刷
    }

    testAsync("powerSteadyBalanceDoublesAndResets") {
        let clock = FakeClock()
        let start = clock.now
        let same = (0..<8).map { _ in Result<ProviderSnapshot, ProviderError>.success(snap(start)) }
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
        try checkEqual(seen, [60, 60, 60, 120, 240, 480])
        try check(log.lines.contains("DeepSeek：余额连续 3 次没变，改为每 2 分钟一次"), "\(log.lines)")
        await store.tick()
        try checkEqual(store.currentInterval(.deepseek), 600)   // 最多 10 分钟
        // 手动刷新（打开面板）回到基础间隔
        clock.now = clock.now.addingTimeInterval(5)
        await store.refresh()
        try checkEqual(store.currentInterval(.deepseek), 60)
        try check(log.lines.contains("DeepSeek：恢复每 1 分钟一次"), "\(log.lines)")
        // 余额变了也回到基础间隔
        clock.now = clock.now.addingTimeInterval(60)
        await store.tick()
        try checkEqual(store.currentInterval(.deepseek), 60)
    }
    testAsync("powerSteadyThenRateLimitedTakesLonger") {
        let clock = FakeClock()
        let start = clock.now
        let same = (0..<5).map { _ in Result<ProviderSnapshot, ProviderError>.success(snap(start)) }
        let p = FakeProvider(same + [.failure(.rateLimited(retryAfter: nil))])
        let store = try powerStore([p], clock: clock, interval: 60)
        for _ in 0..<5 {
            await store.tick()
            clock.now = clock.now.addingTimeInterval(store.currentInterval(.deepseek))
        }
        try checkEqual(store.currentInterval(.deepseek), 240)
        await store.tick()
        try checkEqual(store.currentInterval(.deepseek), 480)   // 限流退避从放慢后的间隔再翻倍
    }
}
