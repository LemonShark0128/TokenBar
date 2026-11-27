import Foundation

@MainActor
func registerGeminiPlanProviderTests() {
    let fixedNow = ISODate.parse("2026-11-24T15:40:00Z")!

    let sampleJSON = Data("""
    {
      "conversation_id": "",
      "status": "SUCCESS",
      "response": "Gemini Models\\tWeekly Limit Remaining\\t98%\\t2026-12-01T15:32:52Z\\nGemini Models\\tFive Hour Limit Remaining\\t92%\\t2026-11-24T20:32:52Z\\nClaude and GPT models\\tWeekly Limit Remaining\\t100%\\t2026-12-01T15:39:46Z\\nClaude and GPT models\\tFive Hour Limit Remaining\\t100%\\t2026-11-24T20:39:46Z\\n",
      "duration_seconds": 0,
      "num_turns": 0,
      "usage": {"input_tokens": 0, "output_tokens": 0, "thinking_tokens": 0, "cache_read_tokens": 0, "total_tokens": 0},
      "command": {
        "name": "usage",
        "data": {
          "groups": [
            {
              "name": "Gemini Models",
              "buckets": [
                {"id": "gemini-weekly", "name": "Weekly Limit Remaining", "window": "weekly", "remaining_fraction": 0.975408673286438, "reset_time": "2026-12-01T15:32:52Z"},
                {"id": "gemini-5h", "name": "Five Hour Limit Remaining", "window": "5h", "remaining_fraction": 0.9216347932815552, "reset_time": "2026-11-24T20:32:52Z"}
              ]
            },
            {
              "name": "Claude and GPT models",
              "buckets": [
                {"id": "3p-weekly", "name": "Weekly Limit Remaining", "window": "weekly", "remaining_fraction": 1, "reset_time": "2026-12-01T15:39:46Z"},
                {"id": "3p-5h", "name": "Five Hour Limit Remaining", "window": "5h", "remaining_fraction": 1, "reset_time": "2026-11-24T20:39:46Z"}
              ]
            }
          ]
        }
      }
    }
    """.utf8)

    test("geminiCLIParsesStructuredUsageJSON") {
        let out = GeminiCLIUsage.outcome(stdout: sampleJSON, exitCode: 0, now: fixedNow)
        guard case .quota(let q) = out else { throw TestFailure(description: "应解析出额度，实际：\(out)") }
        try checkEqual(q.observedAt, fixedNow)
        try checkEqual(q.windows.count, 3)
        // 5 小时窗口排第一、本周排第二、第三方模型组周窗口排第三
        try checkEqual(q.windows[0].kind, .session)
        try check(abs(q.windows[0].usedPercent - 7.83652067184448) < 0.001)
        try checkEqual(q.windows[0].windowMinutes, 300)
        try checkEqual(q.windows[0].resetsAt, ISODate.parse("2026-11-24T20:32:52Z"))
        try checkEqual(q.windows[1].kind, .weekly)
        try check(abs(q.windows[1].usedPercent - 2.4591326713562) < 0.001)
        try checkEqual(q.windows[1].windowMinutes, 10080)
        try checkEqual(q.windows[1].resetsAt, ISODate.parse("2026-12-01T15:32:52Z"))
        try checkEqual(q.windows[2].kind, .weeklyModel("Claude / GPT"))
        try checkEqual(q.windows[2].usedPercent, 0)
        try checkEqual(q.windows[2].windowMinutes, 10080)
    }

    test("geminiCLIRollsOverPastResetsAndSkipsDisabled") {
        let json = Data("""
        {
          "status": "SUCCESS",
          "command": {
            "name": "usage",
            "data": {
              "groups": [
                {
                  "name": "Gemini Models",
                  "buckets": [
                    {"id": "gemini-5h", "window": "5h", "remaining_fraction": 0.2, "reset_time": "2026-11-24T15:00:00Z"},
                    {"id": "gemini-weekly", "window": "weekly", "remaining_fraction": 0.5, "reset_time": "2026-11-24T15:00:00Z"}
                  ]
                },
                {
                  "name": "Claude and GPT models",
                  "buckets": [
                    {"id": "3p-weekly", "window": "weekly", "remaining_fraction": 0.4, "disabled": true, "reset_time": "2026-12-01T15:00:00Z"}
                  ]
                }
              ]
            }
          }
        }
        """.utf8)
        let out = GeminiCLIUsage.outcome(stdout: json, exitCode: 0, now: fixedNow)
        guard case .quota(let q) = out else { throw TestFailure(description: "应解析出额度") }
        try checkEqual(q.windows.count, 2)
        try checkEqual(q.windows[0].kind, .session)
        try checkEqual(q.windows[0].usedPercent, 0)
        try checkEqual(q.windows[0].resetsAt, nil)
        try checkEqual(q.windows[1].kind, .weekly)
        try checkEqual(q.windows[1].usedPercent, 0)
        try checkEqual(q.windows[1].resetsAt, ISODate.parse("2026-12-01T15:00:00Z"))
    }

    test("geminiCLIFallsBackToTSVResponse") {
        let json = Data("""
        {
          "status": "SUCCESS",
          "response": "Gemini Models\\tWeekly Limit Remaining\\t80%\\t2026-12-01T15:32:52Z\\nGemini Models\\tFive Hour Limit Remaining\\t65%\\t2026-11-24T20:32:52Z\\nClaude and GPT models\\tWeekly Limit Remaining\\t90%\\t2026-12-01T15:39:46Z\\n"
        }
        """.utf8)
        let out = GeminiCLIUsage.outcome(stdout: json, exitCode: 0, now: fixedNow)
        guard case .quota(let q) = out else { throw TestFailure(description: "应从 TSV 解析出额度，实际：\(out)") }
        try checkEqual(q.windows.map(\.kind), [.session, .weekly, .weeklyModel("Claude / GPT")])
        try checkEqual(q.windows[0].usedPercent, 35)
        try checkEqual(q.windows[1].usedPercent, 20)
        try checkEqual(q.windows[2].usedPercent, 10)
    }

    test("geminiCLIHandlesErrorsAndNoQuotas") {
        let empty = Data(#"{"status":"SUCCESS","command":{"name":"usage","data":{"groups":[]}}}"#.utf8)
        try checkEqual(GeminiCLIUsage.outcome(stdout: empty, exitCode: 0, now: fixedNow), .noQuotas)

        let authErr = Data(#"{"status":"ERROR","error":"authentication required: please sign in"}"#.utf8)
        try checkEqual(GeminiCLIUsage.outcome(stdout: authErr, exitCode: 1, now: fixedNow), GeminiCLIUsage.needsLogin)
        try check(GeminiCLIUsage.isLoginProblem(GeminiCLIUsage.needsLogin))

        let stderrAuth = Data("Error: authentication required\n".utf8)
        try checkEqual(GeminiCLIUsage.outcome(stdout: Data(), stderr: stderrAuth, exitCode: 1, now: fixedNow), GeminiCLIUsage.needsLogin)

        let rateErr = Data(#"{"status":"ERROR","error":"HTTP 429 Too Many Requests"}"#.utf8)
        try checkEqual(GeminiCLIUsage.outcome(stdout: rateErr, exitCode: 1, now: fixedNow), GeminiCLIUsage.throttled)

        let badJSON = Data("not json at all".utf8)
        try checkEqual(GeminiCLIUsage.outcome(stdout: badJSON, exitCode: 0, now: fixedNow), .unrecognized)
    }

    test("geminiCLIBackoffEscalatesAndResets") {
        var b = GeminiCLIUsage.Backoff()
        let t0 = fixedNow
        try check(!b.blocked(now: t0))
        b.record(GeminiCLIUsage.throttled, now: t0)
        try checkEqual(b.minutes, 5)
        try check(b.blocked(now: t0.addingTimeInterval(4 * 60)))
        try check(!b.blocked(now: t0.addingTimeInterval(5 * 60)))
        b.record(GeminiCLIUsage.throttled, now: t0.addingTimeInterval(5 * 60))
        try checkEqual(b.minutes, 10)
        b.record(GeminiCLIUsage.needsLogin, now: t0.addingTimeInterval(6 * 60))
        try checkEqual(b.minutes, 0)
        try check(!b.blocked(now: t0.addingTimeInterval(6 * 60)))
    }

    test("geminiCLICandidatesAndShortGroupName") {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let cands = GeminiCLIUsage.candidates(home: home)
        try checkEqual(cands.first?.path, "/Users/test/.local/bin/agy")
        try checkEqual(cands.count, Set(cands).count)
        try checkEqual(GeminiCLIUsage.shortGroupName("Claude and GPT models"), "Claude / GPT")
        try checkEqual(GeminiCLIUsage.shortGroupName("Partner Models"), "Partner")
    }

    testAsync("geminiPlanProviderRetriesAndMapsErrors") {
        final class Counter: @unchecked Sendable { var calls = 0; var sleeps: [TimeInterval] = [] }
        let counter = Counter()
        let q = Quota(plan: nil, windows: [QuotaWindow(kind: .session, usedPercent: 10, resetsAt: nil, windowMinutes: 300)], observedAt: fixedNow)
        let provider = GeminiPlanProvider(cli: { _ in
            counter.calls += 1
            return counter.calls == 1 ? .failed("临时网络抖动") : .quota(q)
        }, retryDelays: [5, 25], sleep: { counter.sleeps.append($0) })
        let res = await provider.fetch(Credentials(values: [:]), now: fixedNow, timeZone: .current)
        try checkEqual(counter.calls, 2)
        try checkEqual(counter.sleeps, [5])
        guard case .success(let snap) = res else { throw TestFailure(description: "重试后应成功") }
        try checkEqual(snap.provider, .geminiPlan)
        try checkEqual(snap.quota, q)

        // 登录失效不重试，返回 .auth
        let authCounter = Counter()
        let authProvider = GeminiPlanProvider(cli: { _ in authCounter.calls += 1; return GeminiCLIUsage.needsLogin },
                                              retryDelays: [5, 25], sleep: { authCounter.sleeps.append($0) })
        try checkEqual(await authProvider.fetch(Credentials(values: [:]), now: fixedNow, timeZone: .current),
                       .failure(.auth(L("gemini.cli.needsLogin"))))
        try checkEqual(authCounter.calls, 1)
        try checkEqual(authCounter.sleeps, [])

        // 限流不重试，返回 .unavailable（透传完整提示句供面板和卡片显示）
        let rateCounter = Counter()
        let rateProvider = GeminiPlanProvider(cli: { _ in rateCounter.calls += 1; return GeminiCLIUsage.throttled },
                                              retryDelays: [5, 25], sleep: { rateCounter.sleeps.append($0) })
        try checkEqual(await rateProvider.fetch(Credentials(values: [:]), now: fixedNow, timeZone: .current),
                       .failure(.unavailable(L("gemini.cli.throttled"))))
        try checkEqual(rateCounter.calls, 1)

        // 未安装不重试，返回 .unavailable
        let missingCounter = Counter()
        let missingProvider = GeminiPlanProvider(cli: { _ in missingCounter.calls += 1; return .notInstalled },
                                                 retryDelays: [5, 25], sleep: { missingCounter.sleeps.append($0) })
        try checkEqual(await missingProvider.fetch(Credentials(values: [:]), now: fixedNow, timeZone: .current),
                       .failure(.unavailable(L("gemini.cli.notInstalled"))))
        try checkEqual(missingCounter.calls, 1)

        // 无额度窗口：返回成功但 quota = nil + quotaNote
        let emptyProvider = GeminiPlanProvider(cli: { _ in .noQuotas }, retryDelays: [], sleep: { _ in })
        guard case .success(let emptySnap) = await emptyProvider.fetch(Credentials(values: [:]), now: fixedNow, timeZone: .current) else {
            throw TestFailure(description: "noQuotas 应返回 success")
        }
        try checkEqual(emptySnap.quota, nil)
        try checkEqual(emptySnap.quotaNote, L("gemini.noWindowsNote"))

        // 认不出：重试后返回 .schemaChanged
        let badProvider = GeminiPlanProvider(cli: { _ in .unrecognized }, retryDelays: [], sleep: { _ in })
        try checkEqual(await badProvider.fetch(Credentials(values: [:]), now: fixedNow, timeZone: .current),
                       .failure(.schemaChanged(L("gemini.cli.unrecognized"))))
    }

    testAsync("geminiCLIRunExecutesStubScript") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-gemini-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("agy")
        let body = """
        #!/bin/sh
        cat <<'EOF'
        {"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"gemini-5h","window":"5h","remaining_fraction":0.75,"reset_time":"2026-11-24T20:00:00Z"},{"id":"gemini-weekly","window":"weekly","remaining_fraction":0.9,"reset_time":"2026-12-01T15:00:00Z"}]}]}}}
        EOF
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let out = await GeminiCLIUsage.run(executable: script, cwd: dir, timeout: 10, now: fixedNow)
        guard case .quota(let q) = out else { throw TestFailure(description: "脚本输出应解析成功，实际：\(out)") }
        try checkEqual(q.windows.count, 2)
        try checkEqual(q.windows[0].kind, .session)
        try checkEqual(q.windows[0].usedPercent, 25)
        try checkEqual(q.windows[1].kind, .weekly)
        try check(abs(q.windows[1].usedPercent - 10) < 0.001)
    }

    test("geminiRegistryAndLoginUIStates") {
        try checkEqual(ProviderRegistry.displayName(.geminiPlan), "Gemini 套餐")
        try checkEqual(ProviderRegistry.logName(.geminiPlan), "Gemini 套餐")
        try checkEqual(ProviderRegistry.meter(.geminiPlan), .quota)
        try checkEqual(ProviderRegistry.credentialKind(.geminiPlan), .none)
        try checkEqual(ProviderRegistry.capabilities(.geminiPlan).credentialRetryInterval, 300)
        try checkEqual(ProviderRegistry.all.last, .geminiPlan)
        try checkEqual(StatusPresenter.offlineTitle(.geminiPlan), "读不到本机 Gemini 额度")
        try checkEqual(TokenChart.platformShort(.geminiPlan), "Gemini")
        try checkEqual(SettingsLayout.accountDetail(.geminiPlan, state: .ok, reading: .session(92)),
                       "5 小时窗口剩 92% · 来自本机 Antigravity CLI")

        // 登录失效时菜单栏写「需登录」、TodayCard 保留旧读数并显示登录提示
        let oldQuota = Quota(plan: nil, windows: [
            QuotaWindow(kind: .session, usedPercent: 10, resetsAt: fixedNow.addingTimeInterval(3600), windowMinutes: 300),
            QuotaWindow(kind: .weekly, usedPercent: 5, resetsAt: fixedNow.addingTimeInterval(86400), windowMinutes: 10080)
        ], observedAt: fixedNow.addingTimeInterval(-600))
        let snap = ProviderSnapshot(provider: .geminiPlan, balance: nil, today: nil, month: nil, byModel: [], trend7: [],
                                    source: .quota, fetchedAt: fixedNow, credential: .invalid, quota: oldQuota)
        var st = PlatformState(id: .geminiPlan, snapshot: snap, burn: nil, status: .credentialInvalid)
        st.errorDetail = L("gemini.cli.needsLogin")
        let d = AppDataMapping.appData(main: st, others: [], now: fixedNow, timeZone: TimeZone(secondsFromGMT: 0)!)
        let cells = MenuBarCells.cells(d, main: .geminiPlan, now: fixedNow)
        try checkEqual(cells.first?.primaryText, "需登录")
        try checkEqual(cells.first?.loginHint, L("gemini.cli.needsLogin"))
        let card = TodayCards.build(d, running: [], now: fixedNow).first { $0.provider == .geminiPlan }
        try checkEqual(card?.loginHint, L("gemini.cli.needsLogin"))
        try check(card?.loginOldQuota?.contains("90%") == true)

        // 经典菜单栏共用 helper + 辅助平台行 VoiceOver（即使旧快照已用完也优先报登录失效）
        let exhaustedQuota = Quota(plan: nil, windows: [
            QuotaWindow(kind: .session, usedPercent: 100, resetsAt: fixedNow.addingTimeInterval(3600), windowMinutes: 300)
        ], observedAt: fixedNow.addingTimeInterval(-600))
        var exhaustedSt = PlatformState(id: .geminiPlan,
                                        snapshot: ProviderSnapshot(provider: .geminiPlan, balance: nil, today: nil, month: nil, byModel: [], trend7: [],
                                                                   source: .quota, fetchedAt: fixedNow, credential: .invalid, quota: exhaustedQuota),
                                        burn: nil, status: .credentialInvalid)
        exhaustedSt.errorDetail = L("gemini.cli.needsLogin")
        let side = AppDataMapping.side(exhaustedSt, now: fixedNow, timeZone: TimeZone(secondsFromGMT: 0)!)
        try checkEqual(MenuBarCells.quotaLoginHint(for: side), L("gemini.cli.needsLogin"))
        let spoken = A11yText.side(side)
        try check(spoken.contains(L("gemini.cli.needsLogin")), "VoiceOver 应优先朗读登录失效提示：\(spoken)")
        try check(spoken.contains(L("a11y.notLatest")), "VoiceOver 应标注可能不是最新：\(spoken)")
    }

    test("geminiEdgeCasesAndDiagnosticRedaction") {
        // 全部 disabled → noQuotas
        let allDisabled = Data("""
        {"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"gemini-5h","window":"5h","remaining_fraction":0.5,"disabled":true}]}]}}}
        """.utf8)
        try checkEqual(GeminiCLIUsage.outcome(stdout: allDisabled, exitCode: 0, now: fixedNow), .noQuotas)

        // 布尔伪装 NSNumber 不得被当成 0/1
        let boolFraction = Data("""
        {"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"gemini-5h","window":"5h","remaining_fraction":true}]}]}}}
        """.utf8)
        try checkEqual(GeminiCLIUsage.outcome(stdout: boolFraction, exitCode: 0, now: fixedNow), .unrecognized)

        // 错误对象 dict + gRPC RESOURCE_EXHAUSTED + 纯文本 stdout 认证错误 + TSV 带空格百分比
        let dictErr = Data(#"{"status":"ERROR","error":{"message":"RESOURCE_EXHAUSTED (429)"}}"#.utf8)
        try checkEqual(GeminiCLIUsage.outcome(stdout: dictErr, exitCode: 1, now: fixedNow), GeminiCLIUsage.throttled)

        let plainAuth = Data("authentication required\n".utf8)
        try checkEqual(GeminiCLIUsage.outcome(stdout: plainAuth, exitCode: 1, now: fixedNow), GeminiCLIUsage.needsLogin)

        let spacedTSV = Data("""
        {"status":"SUCCESS","response":"Gemini Models\\tFive Hour Limit Remaining\\t98 %\\t2026-11-24T20:32:52Z\\n"}
        """.utf8)
        guard case .quota(let q) = GeminiCLIUsage.outcome(stdout: spacedTSV, exitCode: 0, now: fixedNow) else {
            throw TestFailure(description: "带空格百分比 TSV 应解析成功")
        }
        try check(abs(q.windows[0].usedPercent - 2) < 0.001)

        // noQuotas 应清零限流退避
        var b = GeminiCLIUsage.Backoff()
        b.record(GeminiCLIUsage.throttled, now: fixedNow)
        try checkEqual(b.minutes, 5)
        b.record(.noQuotas, now: fixedNow.addingTimeInterval(60))
        try checkEqual(b.minutes, 0)

        // 诊断日志：空白 stdout 回退到 stderr，且跨第 200 字符的长 token 仍被打码
        let padding = String(repeating: "a", count: 185)
        let longSecret = "Bearer secretToken1234567890ABCDEFGHIJKLMNOP"
        let diag = GeminiCLIUsage.diagnostic(stdout: Data("   \n".utf8), stderr: Data((padding + " " + longSecret).utf8))
        try check(!diag.contains("secretToken"), "跨 200 字符边界的 token 不应泄露：\(diag)")
    }

    test("geminiLoginAlertTrackerDedupRearmAndCompat") {
        // 旧版 JSON（无 geminiLoginNotified）可正常解码
        let legacyJSON = Data(#"{"below":{},"claudeExpiryDays":[],"claudeLoginNotified":false,"hourlyAt":{},"lowAt":{},"spikeAt":{}}"#.utf8)
        var tracker = try JSONDecoder().decode(PlatformAlertTracker.self, from: legacyJSON)
        var invalid = PlatformState(id: .geminiPlan, snapshot: nil, burn: nil, status: .credentialInvalid)
        invalid.errorDetail = L("gemini.cli.needsLogin")
        let first = tracker.geminiLoginAlerts([invalid])
        try checkEqual(first.count, 1)
        try checkEqual(first[0].title, L("alert.geminiLogin.title"))
        try checkEqual(first[0].body, L("gemini.cli.needsLogin"))
        // 重复刷新不重发；临时离线不重新武装
        try checkEqual(tracker.geminiLoginAlerts([invalid]).count, 0)
        try checkEqual(tracker.geminiLoginAlerts([PlatformState(id: .geminiPlan, snapshot: nil, burn: nil, status: .offline)]).count, 0)
        try checkEqual(tracker.geminiLoginAlerts([invalid]).count, 0)
        // 恢复 .ok 后重新武装；再掉线时发一次
        try checkEqual(tracker.geminiLoginAlerts([PlatformState(id: .geminiPlan, snapshot: nil, burn: nil, status: .ok)]).count, 0)
        try checkEqual(tracker.geminiLoginAlerts([invalid]).count, 1)
        // forget 后清零
        tracker.forget(.geminiPlan)
        try checkEqual(tracker.geminiLoginAlerts([invalid]).count, 1)
    }

    testAsync("geminiCLIRunTimeoutAndStderrAuth") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-gemini-edge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let slow = dir.appendingPathComponent("agy-slow")
        try "#!/bin/sh\nsleep 10\n".write(to: slow, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slow.path)
        let timedOut = await GeminiCLIUsage.run(executable: slow, cwd: dir, timeout: 0.3, now: fixedNow)
        try checkEqual(timedOut, .failed(L("cli.timeout")))

        let errScript = dir.appendingPathComponent("agy-err")
        try "#!/bin/sh\necho 'authentication required' >&2\nexit 1\n".write(to: errScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: errScript.path)
        let authRes = await GeminiCLIUsage.run(executable: errScript, cwd: dir, timeout: 5, now: fixedNow)
        try checkEqual(authRes, GeminiCLIUsage.needsLogin)
    }

    test("geminiRunningTasksAndMenuBarSelection") {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tb-gemini-tasks-\(UUID().uuidString)")
        let claudeProjects = root.appendingPathComponent("claude/projects", isDirectory: true)
        let codexSessions = root.appendingPathComponent("codex/sessions", isDirectory: true)
        let brain = root.appendingPathComponent("brain", isDirectory: true)
        let activeLogs = brain.appendingPathComponent("conv-active/.system_generated/logs", isDirectory: true)
        let doneLogs = brain.appendingPathComponent("conv-done/.system_generated/logs", isDirectory: true)
        let canceledLogs = brain.appendingPathComponent("conv-canceled/.system_generated/logs", isDirectory: true)
        let subagentLogs = brain.appendingPathComponent("conv-subagent/.system_generated/logs", isDirectory: true)
        try fm.createDirectory(at: activeLogs, withIntermediateDirectories: true)
        try fm.createDirectory(at: doneLogs, withIntermediateDirectories: true)
        try fm.createDirectory(at: canceledLogs, withIntermediateDirectories: true)
        try fm.createDirectory(at: subagentLogs, withIntermediateDirectories: true)

        let activeFile = activeLogs.appendingPathComponent("transcript.jsonl")
        let doneFile = doneLogs.appendingPathComponent("transcript.jsonl")
        let canceledFile = canceledLogs.appendingPathComponent("transcript.jsonl")
        let subagentFile = subagentLogs.appendingPathComponent("transcript.jsonl")
        let now = Date()
        let f = ISO8601DateFormatter()
        let t0 = f.string(from: now.addingTimeInterval(-30))
        let t1 = f.string(from: now.addingTimeInterval(-10))
        let t2 = f.string(from: now.addingTimeInterval(-2))

        // 同 step_index 出现 RUNNING → DONE 不应重复累加 output_tokens；cache_read > input_tokens 也不应出负数
        let activeContent = """
        {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE"}
        {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"RUNNING","created_at":"\(t1)","model":"gemini-4-neon-high","input_tokens":300,"cache_read_tokens":400,"output_tokens":100,"tool_calls":[{"id":"1"}]}
        {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"\(t1)","model":"gemini-4-neon-high","input_tokens":1000,"cache_read_tokens":400,"output_tokens":320,"tool_calls":[{"id":"1"}]}
        {"step_index":2,"source":"MODEL","type":"GENERIC","status":"DONE","created_at":"\(t2)"}
        """
        try activeContent.write(to: activeFile, atomically: true, encoding: .utf8)

        let doneContent = """
        {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"\(t0)"}
        {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"\(t1)","model":"gemini-4-neon-high","output_tokens":500}
        """
        try doneContent.write(to: doneFile, atomically: true, encoding: .utf8)

        // ERROR / CANCELED 终止态必须收轮（即便带 tool_calls）
        let canceledContent = """
        {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"\(t0)"}
        {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"CANCELED","created_at":"\(t1)","model":"gemini-4-neon-high","tool_calls":[{"id":"1"}]}
        """
        try canceledContent.write(to: canceledFile, atomically: true, encoding: .utf8)

        // 子代理以 SYSTEM_MESSAGE 开轮 + PLANNER_RESPONSE(RUNNING)
        let subagentContent = """
        {"step_index":0,"source":"SYSTEM","type":"SYSTEM_MESSAGE","status":"DONE","created_at":"\(t0)"}
        {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"RUNNING","created_at":"\(t2)","model":"gemini-3.8-flash-medium","output_tokens":80}
        """
        try subagentContent.write(to: subagentFile, atomically: true, encoding: .utf8)

        let cache = RunningTasksCache()
        let tasks = RunningTasks.scan(enabled: [.geminiPlan], claudeDir: root.appendingPathComponent("claude"),
                                      codexSessions: codexSessions, now: now, antigravityBrain: brain, cache: cache)
        try checkEqual(tasks.count, 2)
        let active = tasks.first { $0.sessionKey.hasSuffix("/conv-active/.system_generated/logs/transcript.jsonl") }
        try checkEqual(active?.provider, .geminiPlan)
        try checkEqual(active?.project, "Antigravity")
        try checkEqual(active?.model, "gemini 4 neon")
        try checkEqual(active?.tokens, 320)
        try checkEqual(active?.usage.input, 600)
        try check(active.map { RunningTaskText.a11y($0, now: now).hasPrefix("Gemini") } == true)

        let sub = tasks.first { $0.sessionKey.hasSuffix("/conv-subagent/.system_generated/logs/transcript.jsonl") }
        try checkEqual(sub?.model, "gemini 3.8 flash")
        try checkEqual(sub?.tokens, 80)

        // scanKnown + 缓存命中（与 StoreBridge 一致，传入 task.sessionKey 对应的 URL）
        let knownScan = RunningTasks.scanKnown([.geminiPlan: [URL(fileURLWithPath: active!.sessionKey)]], now: now, cache: cache)
        try checkEqual(knownScan.tasks.count, 1)
        try checkEqual(cache.parsedFileCount, 4)

        // FSEvents 触发规则：只认 transcript.jsonl，忽略 transcript_full.jsonl；嵌套目录不被外层短路
        let fullFile = activeLogs.appendingPathComponent("transcript_full.jsonl")
        try checkEqual(RunningScanTrigger.decide(changed: [fullFile.path], known: [], claudeProjects: claudeProjects, codexSessions: codexSessions, antigravityBrain: brain), .ignore)
        try checkEqual(RunningScanTrigger.decide(changed: [activeFile.path], known: [], claudeProjects: claudeProjects, codexSessions: codexSessions, antigravityBrain: brain), .full)
        try checkEqual(RunningScanTrigger.decide(changed: [activeFile.path], known: [], claudeProjects: root, codexSessions: root, antigravityBrain: brain), .full)
        try checkEqual(RunningScanTrigger.decide(changed: [activeFile.path], known: [activeFile.path], claudeProjects: claudeProjects, codexSessions: codexSessions, antigravityBrain: brain), .known)

        // 菜单栏（用户 2026-11-27）：只有 Gemini 在跑时只显示 Gemini 并亮绿点，收轮后停留 60 秒，之后回到面板第一个 Claude
        let cells = [
            MenuBarCell(id: .claudePlan, kind: .quota(session: 100, weekly: 1, pace: nil), severity: nil, stale: false, exhausted: false),
            MenuBarCell(id: .geminiPlan, kind: .quota(session: 36, weekly: 84, pace: nil), severity: nil, stale: false, exhausted: false)
        ]
        let sel = MenuBarSelection.select(cells: cells, order: [.claudePlan, .geminiPlan], paygActive: [],
                                          tasks: tasks, showRunning: true, mode: .double, lastActivity: [:], now: now)
        try checkEqual(sel.slots.main?.id, .geminiPlan)
        try checkEqual(sel.slots.secondary, nil)
        try check(sel.slots.mainRunning)
        let held = MenuBarSelection.select(cells: cells, order: [.claudePlan, .geminiPlan], paygActive: [],
                                           tasks: [], showRunning: true, mode: .double, lastActivity: sel.lastActivity, now: now.addingTimeInterval(59))
        try checkEqual(held.slots.main?.id, .geminiPlan)
        try check(!held.slots.mainRunning)
        let gone = MenuBarSelection.select(cells: cells, order: [.claudePlan, .geminiPlan], paygActive: [],
                                           tasks: [], showRunning: true, mode: .double, lastActivity: held.lastActivity, now: now.addingTimeInterval(60))
        try checkEqual(gone.slots.main?.id, .claudePlan)
        try checkEqual(gone.slots.secondary, nil)
    }

    testAsync("geminiPlanTierNormalizationCacheAndProbe") {
        // 1. 套餐名归一、词边界防误判与卡片徽章/来源行衔接
        try checkEqual(GeminiCLIUsage.normalizePlanTier("Google AI Pro"), "pro")
        try checkEqual(GeminiCLIUsage.normalizePlanTier("Google AI Pro (Trial)"), "pro")
        try checkEqual(GeminiCLIUsage.normalizePlanTier("Google AI Ultra"), "ultra")
        try checkEqual(GeminiCLIUsage.normalizePlanTier("Google AI Plus"), "plus")
        try checkEqual(GeminiCLIUsage.normalizePlanTier("Free"), "free")
        try checkEqual(GeminiCLIUsage.normalizePlanTier("Free (Promotional)"), "free")
        try checkEqual(GeminiCLIUsage.normalizePlanTier("Gemini Enterprise"), "enterprise")
        try checkEqual(GeminiCLIUsage.normalizePlanTier("Google Developer Program"), nil)
        try checkEqual(GeminiCLIUsage.normalizePlanTier("Nonprofit"), nil)
        try checkEqual(GeminiCLIUsage.normalizePlanTier("unknown"), nil)
        try checkEqual(GeminiCLIUsage.normalizePlanTier("user@example.com"), nil)
        try checkEqual(GeminiCLIUsage.normalizePlanTier("   "), nil)
        try checkEqual(TodayCards.planBadge(GeminiCLIUsage.normalizePlanTier("Google AI Pro")), "Pro")
        try checkEqual(TodayCards.planBadge(GeminiCLIUsage.normalizePlanTier("Google AI Ultra")), "Ultra")
        try checkEqual(QuotaText.planName(GeminiCLIUsage.normalizePlanTier("Google AI Pro")), "Pro 套餐")

        // 2. statusLine JSON 只取 plan_tier 与 agent_state
        let sl = Data(#"{"agent_state":"initializing","plan_tier":"Google AI Pro","email":"secret@example.com"}"#.utf8)
        let parsedSL = GeminiCLIUsage.parseStatusLinePlanTier(sl)
        try checkEqual(parsedSL.plan, "pro")
        try checkEqual(parsedSL.agentState, "initializing")

        // 3. 若未来 /usage JSON 直接带 plan_tier，outcome 直接提取
        let now = ISO8601DateFormatter().date(from: "2026-11-24T12:00:00Z")!
        let inlineJSON = Data(#"""
        {"status":"SUCCESS","command":{"name":"usage","data":{"plan_tier":"Google AI Ultra","groups":[
          {"name":"Gemini Models","buckets":[{"id":"gemini-5h","window":"5h","remaining_fraction":0.8,"reset_time":"2026-11-24T17:00:00Z"}]}
        ]}}}
        """#.utf8)
        if case .quota(let q) = GeminiCLIUsage.outcome(stdout: inlineJSON, exitCode: 0, now: now) {
            try checkEqual(q.plan, "ultra")
        } else {
            throw TestFailure(description: "expected quota with inline plan")
        }

        // 4. PlanTierCache：6 小时成功缓存、瞬时失败保留旧套餐名并 20 分钟重查、时钟回拨重查、invalidate 隔离在途旧请求
        let cache = GeminiCLIUsage.PlanTierCache()
        final class Counter: @unchecked Sendable { var n = 0 }
        let calls = Counter()
        let first = await cache.read(now: now) { calls.n += 1; return "pro" }
        try checkEqual(first, "pro")
        try checkEqual(calls.n, 1)
        let hit = await cache.read(now: now.addingTimeInterval(5 * 3600)) { calls.n += 1; return "ultra" }
        try checkEqual(hit, "pro")
        try checkEqual(calls.n, 1)
        // 6 小时后瞬时超时返回 nil：保留上次已知的 "pro"，20 分钟内不重复探，20 分钟后重探
        let transientMiss = await cache.read(now: now.addingTimeInterval(6 * 3600 + 1)) { calls.n += 1; return nil }
        try checkEqual(transientMiss, "pro")
        try checkEqual(calls.n, 2)
        let duringCooldown = await cache.read(now: now.addingTimeInterval(6 * 3600 + 600)) { calls.n += 1; return "ultra" }
        try checkEqual(duringCooldown, "pro")
        try checkEqual(calls.n, 2)
        let afterCooldown = await cache.read(now: now.addingTimeInterval(6 * 3600 + 20 * 60 + 5)) { calls.n += 1; return "ultra" }
        try checkEqual(afterCooldown, "ultra")
        try checkEqual(calls.n, 3)
        // 时钟回拨（now < checkedAt）触发重查
        let clockSkew = await cache.read(now: now) { calls.n += 1; return "pro" }
        try checkEqual(clockSkew, "pro")
        try checkEqual(calls.n, 4)
        // 并发合并 + invalidate 隔离：在途旧请求失效后不会污染新请求
        await cache.invalidate()
        async let slowOld = cache.read(now: now) {
            calls.n += 1
            try? await Task.sleep(nanoseconds: 120_000_000)
            return "pro"
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        await cache.invalidate()
        let freshAfterInvalidate = await cache.read(now: now.addingTimeInterval(1)) { calls.n += 1; return "ultra" }
        let oldResult = await slowOld
        try checkEqual(oldResult, nil)
        try checkEqual(freshAfterInvalidate, "ultra")
        try checkEqual(calls.n, 6)

        // 5. probePlanTier 端到端 stub 脚本测试（验证 PTY、TOKENBAR_PLAN_OUT、清理旧/新临时文件及启动失败安全返回）
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-plan-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 预先放一个 5 分钟前的旧探针残片，验证会被自动清扫
        let staleFile = dir.appendingPathComponent("plan-probe-stale.json")
        try Data("{}".utf8).write(to: staleFile)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-300)], ofItemAtPath: staleFile.path)

        let stub = dir.appendingPathComponent("fake-agy")
        let script = """
        #!/bin/sh
        printf '{"agent_state":"initializing","plan_tier":"Google AI Pro"}' > "$TOKENBAR_PLAN_OUT.tmp"
        mv -f "$TOKENBAR_PLAN_OUT.tmp" "$TOKENBAR_PLAN_OUT"
        sleep 5
        """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let probed = await GeminiCLIUsage.probePlanTier(executable: stub, cwd: dir, timeout: 5)
        try checkEqual(probed, "pro")
        try check(!FileManager.default.fileExists(atPath: staleFile.path), "stale probe file should be swept")
        let leftover = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        try check(!leftover.contains { $0.hasPrefix("plan-probe-") }, "probe files should be cleaned up: \(leftover)")

        // 启动失败时安全返回 nil 且不泄漏/不卡死
        let missing = dir.appendingPathComponent("does-not-exist")
        let failedProbe = await GeminiCLIUsage.probePlanTier(executable: missing, cwd: dir, timeout: 2)
        try checkEqual(failedProbe, nil)
    }
}
