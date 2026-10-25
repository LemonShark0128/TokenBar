import Foundation

/// Claude 桌面 App 的额度记录（plan-usage-history.json）：解析、重置时间推算、过期规则。样本全部是自己编的
@MainActor
func registerClaudeAppUsageSourceTests() {
    func at(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    let now = at("2026-10-17T06:00:00Z")
    func ms(_ d: Date) -> Int { Int(d.timeIntervalSince1970 * 1000) }
    func ago(_ secs: Double) -> Date { now.addingTimeInterval(-secs) }
    typealias S = ClaudeAppUsageSource.Sample
    func q(_ samples: [S]) -> Quota? { ClaudeAppUsageSource.quota(from: samples, now: now) }
    func win(_ q: Quota?, _ k: QuotaWindow.Kind) -> QuotaWindow? { q?.windows.first { $0.kind == k } }

    func tmpDir() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("tb claude app \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    // MARK: 解析

    test("claudeAppParsesV2") {
        let json = """
        {"version":2,"samples":[
          {"t":\(ms(ago(600))),"org":"00000000-0000-0000-0000-000000000000","u":{"fh":12,"sd":30.5,"so":4,"sn":7}},
          {"t":\(ms(ago(1200))),"org":"x","u":{"fh":8}}
        ]}
        """
        guard case .samples(let s) = ClaudeAppUsageSource.parse(Data(json.utf8)) else { throw TestFailure(description: "应解析出样本") }
        // 按时间排序
        try checkEqual(s.map(\.t), [ago(1200), ago(600)])
        try checkEqual(s[1], S(t: ago(600), fh: 12, sd: 30.5, so: 4, sn: 7, org: "00000000-0000-0000-0000-000000000000"))
        try checkEqual(s[0], S(t: ago(1200), fh: 8, org: "x"))
    }

    test("claudeAppParsesV1Flat") {
        let json = "{\"version\":1,\"samples\":[{\"t\":\(ms(ago(600))),\"fh\":20,\"sd\":41}]}"
        guard case .samples(let s) = ClaudeAppUsageSource.parse(Data(json.utf8)) else { throw TestFailure(description: "应解析出样本") }
        try checkEqual(s, [S(t: ago(600), fh: 20, sd: 41)])
    }

    test("claudeAppUnknownVersion") {
        for json in ["{\"version\":3,\"samples\":[]}", "{\"samples\":[]}", "{\"version\":\"2\",\"samples\":[]}"] {
            try checkEqual(ClaudeAppUsageSource.parse(Data(json.utf8)), .unknownVersion)
        }
    }

    test("claudeAppCorrupt") {
        for json in ["", "{\"version\":2,\"samp", "[1,2]", "{\"version\":2}", "{\"version\":2,\"samples\":{}}"] {
            try checkEqual(ClaudeAppUsageSource.parse(Data(json.utf8)), .corrupt)
        }
    }

    test("claudeAppSkipsBrokenSamplesAndMissingKeys") {
        let json = """
        {"version":2,"samples":[
          {"org":"x","u":{"fh":1}},
          {"t":"soon","u":{"fh":1}},
          {"t":\(ms(ago(900)))},
          {"t":\(ms(ago(600))),"u":{"sd":"many","sn":3}},
          "junk"
        ]}
        """
        guard case .samples(let s) = ClaudeAppUsageSource.parse(Data(json.utf8)) else { throw TestFailure(description: "应解析出样本") }
        try checkEqual(s, [S(t: ago(900)), S(t: ago(600), sn: 3)])
    }

    // MARK: 5 小时窗口

    test("claudeAppSessionResetFromRunStart") {
        let r = q([S(t: ago(3 * 3600), fh: 0), S(t: ago(2 * 3600), fh: 10), S(t: ago(3600), fh: 20), S(t: ago(600), fh: 30)])
        let w = win(r, .session)
        try checkEqual(w?.usedPercent, 30)
        try checkEqual(w?.resetsAt, ago(2 * 3600).addingTimeInterval(5 * 3600))
        try checkEqual(w?.windowMinutes, 300)
        try checkEqual(w?.resetIsEstimated, true)
        try checkEqual(r?.observedAt, ago(600))
    }

    test("claudeAppSessionRunBreaksOnDrop") {
        // 读数变小说明中间重置过：这一段从变小的那条开始
        let r = q([S(t: ago(4 * 3600), fh: 50), S(t: ago(3.5 * 3600), fh: 80), S(t: ago(3600), fh: 5), S(t: ago(600), fh: 12)])
        try checkEqual(win(r, .session)?.resetsAt, ago(3600).addingTimeInterval(5 * 3600))
    }

    test("claudeAppSessionZeroHasNoReset") {
        let r = q([S(t: ago(3600), fh: 10), S(t: ago(600), fh: 0)])
        let w = win(r, .session)
        try checkEqual(w?.usedPercent, 0)
        try checkEqual(w?.resetsAt, nil)
        try checkEqual(w?.resetIsEstimated, false)
    }

    test("claudeAppSessionStaleAfterFiveHours") {
        let r = q([S(t: ago(5 * 3600 + 60), fh: 40, sd: 10)])
        try checkEqual(win(r, .session), nil)
        try check(win(r, .weekly) != nil, "每周窗口不受 5 小时过期影响")
    }

    test("claudeAppSessionEstimatedResetPassed") {
        // 一直 >0 没有变小：起点 5.5 小时前，推算的重置时间已过 → 丢弃
        let r = q([S(t: ago(5.5 * 3600), fh: 5), S(t: ago(3 * 3600), fh: 20), S(t: ago(3600), fh: 30)])
        try checkEqual(win(r, .session), nil)
    }

    test("claudeAppSessionRunStopsAtFiveHourGap") {
        // 评审 I1：上个窗口最后一条 30，空闲超过 5 小时没有 0 的读数，新窗口从 40 开始：
        // 不能越过去把起点算到旧窗口（那样推算的重置时间已过，新鲜读数被丢掉）
        let r = q([S(t: ago(7 * 3600), fh: 30), S(t: ago(3600), fh: 40), S(t: ago(600), fh: 45)])
        try checkEqual(win(r, .session)?.usedPercent, 45)
        try checkEqual(win(r, .session)?.resetsAt, ago(3600).addingTimeInterval(5 * 3600))
        // 同一段里离最新一条超过 5 小时的读数也不算起点
        let r2 = q([S(t: ago(6 * 3600), fh: 5), S(t: ago(3 * 3600), fh: 20), S(t: ago(600), fh: 30)])
        try checkEqual(win(r2, .session)?.resetsAt, ago(3 * 3600).addingTimeInterval(5 * 3600))
    }

    test("claudeAppSessionIgnoresSamplesWithoutFh") {
        let r = q([S(t: ago(2 * 3600), fh: 10), S(t: ago(3600), sd: 3), S(t: ago(600), fh: 15)])
        try checkEqual(win(r, .session)?.resetsAt, ago(2 * 3600).addingTimeInterval(5 * 3600))
        try checkEqual(win(r, .session)?.usedPercent, 15)
    }

    // MARK: 每周窗口

    test("claudeAppWeeklyResetFromLastDrop") {
        let r = q([S(t: at("2026-10-10T08:00:00Z"), sd: 40), S(t: at("2026-10-10T09:20:00Z"), sd: 45),
                   S(t: at("2026-10-10T11:05:00Z"), sd: 3), S(t: ago(3600), sd: 10)])
        let w = win(r, .weekly)
        // 下降前一条之后的第一个 UTC 整点 10:00，往后推 7 天直到晚于最新读数
        try checkEqual(w?.resetsAt, at("2026-10-17T10:00:00Z"))
        try checkEqual(w?.usedPercent, 10)
        try checkEqual(w?.windowMinutes, 10080)
        try checkEqual(w?.resetIsEstimated, true)
    }

    test("claudeAppWeeklyExactHourGoesToNextHour") {
        let r = q([S(t: at("2026-10-12T09:00:00Z"), sd: 45), S(t: at("2026-10-12T12:00:00Z"), sd: 2), S(t: ago(600), sd: 6)])
        try checkEqual(win(r, .weekly)?.resetsAt, at("2026-10-19T10:00:00Z"))
    }

    test("claudeAppWeeklyUsesLastOfSeveralDrops") {
        let r = q([S(t: at("2026-10-11T01:10:00Z"), sd: 60), S(t: at("2026-10-11T02:10:00Z"), sd: 1),
                   S(t: at("2026-10-13T05:30:00Z"), sd: 30), S(t: at("2026-10-13T06:30:00Z"), sd: 20), S(t: ago(600), sd: 25)])
        try checkEqual(win(r, .weekly)?.resetsAt, at("2026-10-20T06:00:00Z"))
    }

    test("claudeAppWeeklyNoDropNoReset") {
        let r = q([S(t: ago(3 * 86400), sd: 10), S(t: ago(3600), sd: 20)])
        let w = win(r, .weekly)
        try checkEqual(w?.usedPercent, 20)
        try checkEqual(w?.resetsAt, nil)
        try checkEqual(w?.resetIsEstimated, false)
    }

    test("claudeAppWeeklyNoResetOlderThanADayDropped") {
        let r = q([S(t: ago(3 * 86400), sd: 10), S(t: ago(86400 + 60), sd: 20)])
        try checkEqual(win(r, .weekly), nil)
    }

    test("claudeAppWeeklyDropWithinOneHour") {
        // 下降的两条在同一个小时里（05:10 → 05:40）：整点 06:00 晚于最新读数，但重置其实已经发生，下一次是 7 天后
        let r = q([S(t: at("2026-10-17T05:10:00Z"), sd: 70), S(t: at("2026-10-17T05:40:00Z"), sd: 0)])
        try checkEqual(win(r, .weekly)?.resetsAt, at("2026-10-24T06:00:00Z"))
        try checkEqual(win(r, .weekly)?.usedPercent, 0)
    }

    test("claudeAppWeeklyEstimatedResetPassedDropped") {
        // 每周窗口：留下的读数都在 7 天内，推算出的下一次重置总晚于 now；这里直接验证「已过就丢弃」这条通用规则
        let w = ClaudeAppUsageSource.keepWindow(QuotaWindow(kind: .weekly, usedPercent: 5, resetsAt: ago(60), windowMinutes: 10080,
                                                            resetIsEstimated: true), latest: ago(3600), now: now)
        try checkEqual(w, nil)
    }

    test("claudeAppDropsSamplesOlderThanSevenDays") {
        // 唯一的下降发生在 7 天之外：看不到，就没有重置时间
        let r = q([S(t: ago(8 * 86400), sd: 60), S(t: ago(7.5 * 86400), sd: 1), S(t: ago(3 * 86400), sd: 5), S(t: ago(600), sd: 9)])
        try checkEqual(win(r, .weekly)?.resetsAt, nil)
        try checkEqual(win(r, .weekly)?.usedPercent, 9)
        try checkEqual(q([S(t: ago(7 * 86400 + 1), fh: 1, sd: 1)]), nil)
    }

    test("claudeAppModelWindowsIndependent") {
        let r = q([S(t: at("2026-10-14T03:40:00Z"), sd: 30, so: 50, sn: 20), S(t: at("2026-10-14T04:10:00Z"), sd: 31, so: 2, sn: 21),
                   S(t: ago(600), fh: 4, sd: 33, so: 6, sn: 22)])
        try checkEqual(r?.windows.map(\.kind), [.session, .weekly, .weeklyModel("Opus"), .weeklyModel("Sonnet")])
        try checkEqual(win(r, .weeklyModel("Opus"))?.resetsAt, at("2026-10-21T04:00:00Z"))
        try checkEqual(win(r, .weeklyModel("Sonnet"))?.resetsAt, nil)
        try checkEqual(win(r, .weekly)?.resetsAt, nil)
        try checkEqual(r?.plan, nil)
    }

    test("claudeAppNoSamplesNoQuota") {
        try checkEqual(q([]), nil)
        try checkEqual(q([S(t: ago(600))]), nil)
    }

    // MARK: 读文件

    test("claudeAppReadFile") {
        let dir = try tmpDir()
        let f = dir.appendingPathComponent("plan-usage-history.json")
        try checkEqual(ClaudeAppUsageSource.read(f, now: now), .missing)
        try Data("{\"version\":2,\"samples\":[{\"t\":\(ms(ago(600))),\"u\":{\"fh\":30,\"sd\":10}}]}".utf8).write(to: f)
        guard case .quota(let qq) = ClaudeAppUsageSource.read(f, now: now) else { throw TestFailure(description: "应读到额度") }
        try checkEqual(qq.windows.map(\.usedPercent), [30, 10])
        try Data("{\"version\":2,\"samples\":[{\"t\":\(ms(ago(30 * 86400))),\"u\":{\"fh\":30}}]}".utf8).write(to: f)
        try checkEqual(ClaudeAppUsageSource.read(f, now: now), .stale(ago(30 * 86400)))
        try Data("{\"version\":2,\"samples\":[]}".utf8).write(to: f)
        try checkEqual(ClaudeAppUsageSource.read(f, now: now), .noRecentData)
        try Data("{\"version\":9,\"samples\":[]}".utf8).write(to: f)
        try checkEqual(ClaudeAppUsageSource.read(f, now: now), .unknownVersion)
        try Data("not json".utf8).write(to: f)
        try checkEqual(ClaudeAppUsageSource.read(f, now: now), .corrupt)
        try Data(count: ClaudeAppUsageSource.maxBytes + 1).write(to: f)
        try checkEqual(ClaudeAppUsageSource.read(f, now: now), .tooLarge)
        try FileManager.default.removeItem(at: dir)
    }

    test("claudeAppReadDirectoryIsCorrupt") {
        let dir = try tmpDir().appendingPathComponent("plan-usage-history.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try checkEqual(ClaudeAppUsageSource.read(dir, now: now), .corrupt)
    }

    test("claudeAppStandardPath") {
        try check(ClaudeAppUsageSource.standardURL.path.hasSuffix("Library/Application Support/Claude/plan-usage-history.json"))
    }

    // MARK: 推算的重置时间：文案

    test("claudeAppEstimatedResetText") {
        let tz = TimeZone(identifier: "UTC")!
        let w = QuotaWindow(kind: .session, usedPercent: 30, resetsAt: now.addingTimeInterval(3 * 3600), windowMinutes: 300,
                            resetIsEstimated: true)
        try checkEqual(QuotaText.resetText(w, now: now, timeZone: tz), "约 3 小时后重置（推算）")
        try checkEqual(QuotaText.resetCompact(w, now: now, timeZone: tz), "约 3:00 后重置")
        var real = w; real.resetIsEstimated = false
        try checkEqual(QuotaText.resetText(real, now: now, timeZone: tz), "3 小时后重置")
        try checkEqual(QuotaText.resetCompact(real, now: now, timeZone: tz), "3:00 后重置")
        let far = QuotaWindow(kind: .weekly, usedPercent: 100, resetsAt: at("2026-10-20T10:00:00Z"), windowMinutes: 10080,
                              resetIsEstimated: true)
        try checkEqual(QuotaText.resetText(far, now: now, timeZone: tz), "约 周二 10:00 重置（推算）")
        try checkEqual(QuotaText.exhausted(name: "Claude 套餐", window: far, now: now, timeZone: tz),
                       "Claude 套餐 本周额度已用完，约 周二 10:00 恢复（推算）")
    }

    test("claudeAppEstimatedFlagDecodesFromOldCache") {
        // 旧快照缓存里没有这个键：照样能解码，按「真实时间」处理
        let old = "{\"kind\":{\"session\":{}},\"usedPercent\":5,\"windowMinutes\":300}"
        let w = try JSONDecoder().decode(QuotaWindow.self, from: Data(old.utf8))
        try checkEqual(w.resetIsEstimated, false)
    }

    test("claudeAppEstimatedResetInPanel") {
        let tz = TimeZone(identifier: "UTC")!
        let quota = Quota(plan: nil, windows: [
            QuotaWindow(kind: .session, usedPercent: 30, resetsAt: now.addingTimeInterval(2 * 3600), windowMinutes: 300, resetIsEstimated: true),
            QuotaWindow(kind: .weekly, usedPercent: 10, resetsAt: nil, windowMinutes: 10080),
        ], observedAt: ago(600))
        var snap = ProviderSnapshot(provider: .claudePlan, balance: nil, today: nil, month: nil, byModel: [], trend7: [],
                                    source: .quota, fetchedAt: now, credential: .ok)
        snap.quota = quota
        let st = PlatformState(id: .claudePlan, snapshot: snap, burn: nil, status: .ok)
        let side = AppDataMapping.side(st, now: now, timeZone: tz)
        try checkEqual(side.quotaReset, "约 2:00 后重置")
        try checkEqual(side.menuQuota?.reset, "约 2 小时后重置（推算）")
        let d = AppDataMapping.appData(main: st, others: [], now: now, timeZone: tz)
        try checkEqual(d.quota?.headline, "5 小时窗口 · 约 2 小时后重置（推算）")
        try checkEqual(d.quota?.headlineCompact, "5 小时窗口 · 约 2 小时后重置")
        // 窗口列表一行放不下「（推算）」：只写「约」
        try checkEqual(d.quota?.rows.first?.reset, "约 2 小时后重置")
    }

    // MARK: 来源二选一

    test("claudeSourceResolve") {
        var asked = 0
        func installed(_ v: Bool) -> () -> Bool { { asked += 1; return v } }
        try checkEqual(ClaudePlanSource.resolve(stored: "desktop", hookInstalled: installed(true)), .desktop)
        try checkEqual(ClaudePlanSource.resolve(stored: "terminal", hookInstalled: installed(false)), .terminal)
        try checkEqual(asked, 0)      // 存过就不看钩子
        // 老用户迁移：没存过时，钩子装好了当终端，否则当桌面
        try checkEqual(ClaudePlanSource.resolve(stored: nil, hookInstalled: installed(true)), .terminal)
        try checkEqual(ClaudePlanSource.resolve(stored: nil, hookInstalled: installed(false)), .desktop)
        try checkEqual(ClaudePlanSource.resolve(stored: "web", hookInstalled: installed(false)), .desktop)
        try checkEqual(ClaudePlanSource.defaultsKey, "claudePlan.source")
    }

    test("claudeSourceLoadPersistsMigration") {
        let suite = "tb claude source \(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        try checkEqual(ClaudePlanSource.load(d, hookInstalled: { true }), .terminal)
        try checkEqual(d.string(forKey: ClaudePlanSource.defaultsKey), "terminal")
        // 之后钩子状态变了也不再翻转
        try checkEqual(ClaudePlanSource.load(d, hookInstalled: { false }), .terminal)
        ClaudePlanSource.desktop.save(d)
        try checkEqual(ClaudePlanSource.load(d, hookInstalled: { true }), .desktop)
    }

    // MARK: Provider 按来源只用一种

    func writeHookFile(_ dir: URL) throws -> URL {
        let f = dir.appendingPathComponent("claude-ratelimits.json")
        try Data("{\"writtenAt\":\(Int(now.timeIntervalSince1970)),\"rate_limits\":{\"five_hour\":{\"used_percentage\":77,\"resets_at\":\(Int(now.timeIntervalSince1970) + 3600)}}}".utf8).write(to: f)
        return f
    }
    func fetch(_ p: ClaudePlanProvider) async -> Result<ProviderSnapshot, ProviderError> {
        await p.fetch(Credentials(values: [:]), now: now, timeZone: TimeZone(identifier: "UTC")!)
    }

    testAsync("claudeDesktopSourceReadsOnlyAppFile") {
        let dir = try tmpDir()
        let hook = try writeHookFile(dir)
        let app = dir.appendingPathComponent("plan-usage-history.json")
        let p = ClaudePlanProvider(quotaFile: hook, desktopFile: app, source: { .desktop }, desktopInstalled: { true })
        // 桌面 App 的文件还没有：不回落到钩子文件
        guard case .success(let s0) = await fetch(p) else { throw TestFailure(description: "应为 success") }
        try checkEqual(s0.quota, nil)
        try checkEqual(s0.quotaNote, ClaudePlanProvider.desktopWaitingNote + "。" + ClaudePlanProvider.cliMissingHint)
        try checkEqual(ClaudePlanProvider.desktopWaitingNote, "打开 Claude 桌面 App，Token Bar 会在它下次记录额度后显示（通常 15 分钟内）")
        try Data("{\"version\":2,\"samples\":[{\"t\":\(ms(ago(600))),\"u\":{\"fh\":30}}]}".utf8).write(to: app)
        guard case .success(let s1) = await fetch(p), let q1 = s1.quota else { throw TestFailure(description: "应读到额度") }
        try checkEqual(q1.windows.map(\.usedPercent), [30])
        try checkEqual(s1.source, .quota)
        // 太旧：写停在什么时候
        try Data("{\"version\":2,\"samples\":[{\"t\":\(ms(ago(9 * 86400))),\"u\":{\"fh\":30}}]}".utf8).write(to: app)
        guard case .success(let s2) = await fetch(p) else { throw TestFailure(description: "应为 success") }
        try checkEqual(s2.quota, nil)
        try check(s2.quotaNote?.hasPrefix("Claude 桌面 App 的额度记录停在 10月8日") == true, s2.quotaNote ?? "nil")
        try Data("{\"version\":5,\"samples\":[]}".utf8).write(to: app)
        try checkEqual(await fetch(p), .failure(.schemaChanged("Claude 桌面 App 的额度记录格式未知")))
        try Data("{oops".utf8).write(to: app)
        try checkEqual(await fetch(p), .failure(.schemaChanged("Claude 桌面 App 的额度记录读不出来")))
        try Data(count: ClaudeAppUsageSource.maxBytes + 1).write(to: app)
        try checkEqual(await fetch(p), .failure(.unavailable("Claude 桌面 App 的额度记录超过 1 MB，没有读取")))
        try FileManager.default.removeItem(at: dir)
    }

    testAsync("claudeTerminalSourceIgnoresAppFile") {
        let dir = try tmpDir()
        let hook = try writeHookFile(dir)
        let app = dir.appendingPathComponent("plan-usage-history.json")
        try Data("{\"version\":2,\"samples\":[{\"t\":\(ms(ago(600))),\"u\":{\"fh\":30}}]}".utf8).write(to: app)
        let p = ClaudePlanProvider(quotaFile: hook, desktopFile: app, source: { .terminal })
        guard case .success(let s) = await fetch(p), let qq = s.quota else { throw TestFailure(description: "应读到额度") }
        try checkEqual(qq.windows.map(\.usedPercent), [77])
        try checkEqual(qq.windows.first?.resetIsEstimated, false)
        // 钩子文件没有时：仍是终端版的等待说明
        try FileManager.default.removeItem(at: hook)
        guard case .success(let s2) = await fetch(p) else { throw TestFailure(description: "应为 success") }
        try checkEqual(s2.quotaNote, ClaudePlanProvider.waitingNote)
        try FileManager.default.removeItem(at: dir)
    }

    test("claudeRegistryReadsBothPaths") {
        let p = ProviderRegistry.makeProvider(.claudePlan, http: InlineHTTPClient { _ in (500, "") }) as? ClaudePlanProvider
        try checkEqual(p?.desktopFile, ClaudeAppUsageSource.standardURL)
    }

    // MARK: 设置页与移除确认的文案按来源

    test("claudeSourceAccountActions") {
        func titles(_ src: ClaudePlanSource, main: Bool) -> [String] {
            SettingsLayout.accountActions(.claudePlan, state: .ok, isMain: main, claudeSource: src).map(\.title)
        }
        try checkEqual(titles(.terminal, main: true), ["重装状态栏钩子", "改用 Claude 桌面 App", "数据目录…", "移除…"])
        try checkEqual(titles(.desktop, main: true), ["改用终端版 Claude Code", "数据目录…", "移除…"])
        try checkEqual(titles(.desktop, main: false), ["固定显示它", "改用终端版 Claude Code", "数据目录…", "移除…"])
        let t = SettingsLayout.menuActions(.claudePlan, state: .ok, isMain: false, claudeSource: .terminal, hookGone: true)
        try checkEqual(t.map(\.title), ["固定显示它", "改用 Claude 桌面 App", "数据目录…", "移除…"])
        let active = SettingsLayout.menuActions(.claudePlan, state: .ok, isMain: true, claudeSource: .terminal, hookGone: false)
        try checkEqual(active.map(\.kind), [.reinstallHook, .switchClaudeSource, .dataDir, .remove])
        let d = SettingsLayout.menuActions(.claudePlan, state: .ok, isMain: false, claudeSource: .desktop, hookGone: false)
        try checkEqual(d.map(\.title), ["固定显示它", "改用终端版 Claude Code", "数据目录…", "移除…"])
    }

    test("claudeSourceAccountDetail") {
        let r = AccountReading.session(59.4)
        try checkEqual(SettingsLayout.accountDetail(.claudePlan, state: .ok, reading: r, claudeSource: .desktop),
                       "5 小时窗口已用 41% · 来自 Claude 桌面 App")
        try checkEqual(SettingsLayout.accountDetail(.claudePlan, state: .ok, reading: nil, claudeSource: .desktop),
                       "来自 Claude 桌面 App · 打开它后通常 15 分钟内显示额度")
        try checkEqual(SettingsLayout.accountDetail(.claudePlan, state: .ok, reading: r, claudeSource: .terminal),
                       "5 小时窗口已用 41% · 来自终端版 Claude Code")
        try checkEqual(SettingsLayout.accountDetail(.claudePlan, state: .connecting, reading: nil, claudeSource: .terminal),
                       "来自终端版 Claude Code · 等你在终端里用一次")
        try checkEqual(SettingsLayout.accountDetail(.claudePlan, state: .offline, reading: nil, claudeSource: .desktop),
                       "来自 Claude 桌面 App")
        try checkEqual(SettingsLayout.accountDetail(.claudePlan, state: .ok, reading: r, stale: true, claudeSource: .terminal),
                       "来自终端版 Claude Code")
    }

    test("claudeSourceRemoveDetail") {
        try checkEqual(OnboardingPlan.removeDetail(.claudePlan, claudeRestoresHook: false),
                       "会删除它的预警线设置，面板不再显示它。不改动 Claude 桌面 App 和 ~/.claude 里的任何文件。")
        try check(OnboardingPlan.removeDetail(.claudePlan).contains("settings.json"))
        try check(OnboardingPlan.removeConfirm([.claudePlan], claudeRestoresHook: false).detail.contains("不改动"))
    }

    test("claudeSourceLabels") {
        try checkEqual(ClaudePlanSource.desktop.label, "来自 Claude 桌面 App")
        try checkEqual(ClaudePlanSource.terminal.label, "来自终端版 Claude Code")
        try checkEqual(ClaudePlanSource.desktop.switchTitle, "改用终端版 Claude Code")
        try checkEqual(ClaudePlanSource.terminal.switchTitle, "改用 Claude 桌面 App")
    }

    test("claudeMenuBarTooltipNote") {
        try checkEqual(MenuBarText.quotaTooltip(provider: "Claude 套餐", reading: nil, note: ClaudePlanProvider.desktopWaitingNote),
                       "Claude 套餐 额度未知 · 打开 Claude 桌面 App，Token Bar 会在它下次记录额度后显示（通常 15 分钟内）")
        try checkEqual(MenuBarText.quotaTooltip(provider: "Claude 套餐", reading: nil), "Claude 套餐 额度未知")
    }

    test("claudeSideCarriesNoteWithoutData") {
        var snap = ProviderSnapshot(provider: .claudePlan, balance: nil, today: nil, month: nil, byModel: [], trend7: [],
                                    source: .quota, fetchedAt: now, credential: .ok)
        snap.quotaNote = ClaudePlanProvider.desktopWaitingNote
        let side = AppDataMapping.side(PlatformState(id: .claudePlan, snapshot: snap, burn: nil, status: .ok), now: now)
        try checkEqual(side.quotaNote, ClaudePlanProvider.desktopWaitingNote)
        snap.quota = Quota(plan: nil, windows: [QuotaWindow(kind: .weekly, usedPercent: 1, resetsAt: nil, windowMinutes: 10080)],
                           observedAt: now)
        try checkEqual(AppDataMapping.side(PlatformState(id: .claudePlan, snapshot: snap, burn: nil, status: .ok), now: now).quotaNote, nil)
    }

    // MARK: 评审修复（第七批）

    test("claudeAppUsesLatestOrgOnly") {
        // 评审 I2：两个组织的读数交替时，只用最新一条所在组织的读数，不把来回跳当成重置
        let r = q([S(t: ago(4 * 3600), fh: 10, sd: 50, org: "a"), S(t: ago(3.5 * 3600), fh: 60, sd: 5, org: "b"),
                   S(t: ago(3 * 3600), fh: 20, sd: 55, org: "a"), S(t: ago(2.5 * 3600), fh: 65, sd: 6, org: "b"),
                   S(t: ago(600), fh: 30, sd: 60, org: "a")])
        try checkEqual(win(r, .session)?.usedPercent, 30)
        try checkEqual(win(r, .session)?.resetsAt, ago(4 * 3600).addingTimeInterval(5 * 3600))
        // a 组织里每周读数一直在涨，没有下降 → 没有推算的重置时间
        try checkEqual(win(r, .weekly)?.usedPercent, 60)
        try checkEqual(win(r, .weekly)?.resetsAt, nil)
    }

    test("claudeAppIgnoresFutureSamples") {
        // 评审 Minor 8：时间戳在未来（时钟回拨）的读数不当作最新
        let r = q([S(t: ago(600), fh: 20, sd: 10), S(t: now.addingTimeInterval(3 * 3600), fh: 90, sd: 90)])
        try checkEqual(win(r, .session)?.usedPercent, 20)
        try checkEqual(r?.observedAt, ago(600))
        // 几分钟内的小偏差照常使用
        let r2 = q([S(t: ago(600), fh: 20), S(t: now.addingTimeInterval(60), fh: 25)])
        try checkEqual(win(r2, .session)?.usedPercent, 25)
    }
}
