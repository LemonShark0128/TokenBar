import Foundation

/// 桌面来源优先用 get_usage；保留 /usage 的旧版兼容测试。所有执行测试只跑临时假脚本。
@MainActor
func registerClaudeCLIUsageTests() {
    func at(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    let now = at("2026-10-17T20:00:00Z")   // 洛杉矶 13:00
    func win(_ q: Quota?, _ k: QuotaWindow.Kind) -> QuotaWindow? { q?.windows.first { $0.kind == k } }
    func wrap(_ result: String, isError: Bool = false) -> Data {
        let o: [String: Any] = ["type": "result", "subtype": "success", "is_error": isError, "num_turns": 0,
                                "result": result, "local_command": "usage"]
        return try! JSONSerialization.data(withJSONObject: o)
    }
    let sample = """
    You are currently using your subscription to power your Claude Code usage

    Current session: 12% used · resets Oct 17 at 3:40pm (America/Los_Angeles)
    Current week (all models): 34% used · resets Oct 23 at 9am (America/Los_Angeles)

    What's contributing to your limits usage?
    Last 24h · 100 requests · 3 sessions
      10% of your usage came from subagent-heavy sessions
    """

    // MARK: 解析文字

    test("cliUsageParsesSessionAndWeek") {
        let q = ClaudeCLIUsage.parseText(sample, now: now)
        try checkEqual(win(q, .session)?.usedPercent, 12)
        try checkEqual(win(q, .session)?.resetsAt, at("2026-10-17T22:40:00Z"))
        try checkEqual(win(q, .session)?.windowMinutes, 300)
        try checkEqual(win(q, .session)?.resetIsEstimated, false)
        try checkEqual(win(q, .weekly)?.usedPercent, 34)
        try checkEqual(win(q, .weekly)?.resetsAt, at("2026-10-23T16:00:00Z"))
        try checkEqual(win(q, .weekly)?.windowMinutes, 10080)
        try checkEqual(q?.observedAt, now)
        // 下面「用量构成」里的百分比不会被当成窗口
        try checkEqual(q?.windows.count, 2)
    }

    test("cliUsageParsesModelWeeks") {
        let text = """
        Current week (all models): 34% used · resets Oct 23 at 9am (America/Los_Angeles)
        Current week (Opus): 5% used · resets Oct 23 at 9am (America/Los_Angeles)
        Current week (Sonnet only): 7.5% used · resets Oct 23 at 9am (America/Los_Angeles)
        """
        let q = ClaudeCLIUsage.parseText(text, now: now)
        try checkEqual(win(q, .weeklyModel("Opus"))?.usedPercent, 5)
        try checkEqual(win(q, .weeklyModel("Sonnet"))?.usedPercent, 7.5)
        try checkEqual(win(q, .session), nil)
    }

    test("cliUsageExpiredSessionClearsReset") {
        let q = ClaudeCLIUsage.parseText("Current session: 42% used · resets Oct 17 at 9am (America/Los_Angeles)", now: now)
        try checkEqual(win(q, .session), QuotaWindow(kind: .session, usedPercent: 0, resetsAt: nil, windowMinutes: 300))
    }

    test("cliUsageExpiredWeekAdvancesSevenDays") {
        let q = ClaudeCLIUsage.parseText("Current week (all models): 34% used · resets Oct 17 at 9am (America/Los_Angeles)", now: now)
        try checkEqual(win(q, .weekly), QuotaWindow(kind: .weekly, usedPercent: 0,
                                                  resetsAt: at("2026-10-24T16:00:00Z"), windowMinutes: 10080))
    }

    test("cliUsageExpiredWeekAdvancesMultipleWeeks") {
        let q = ClaudeCLIUsage.parseText("Current week: 34% used · resets Oct 2 at 9am (UTC)", now: now)
        try checkEqual(win(q, .weekly), QuotaWindow(kind: .weekly, usedPercent: 0,
                                                  resetsAt: at("2026-10-23T09:00:00Z"), windowMinutes: 10080))
    }

    test("cliUsageExpiredModelWeeksReset") {
        for model in ["Opus", "Sonnet"] {
            let q = ClaudeCLIUsage.parseText("Current week (\(model)): 7.5% used · resets Oct 2 at 9am (UTC)", now: now)
            try checkEqual(win(q, .weeklyModel(model)), QuotaWindow(kind: .weeklyModel(model), usedPercent: 0,
                                                                   resetsAt: at("2026-10-23T09:00:00Z"), windowMinutes: 10080))
        }
    }

    test("cliUsageResetExactlyNowCountsAsExpired") {
        let text = """
        Current session: 42% used · resets Oct 17 at 8pm (UTC)
        Current week: 34% used · resets Oct 17 at 8pm (UTC)
        Current week (Opus): 7% used · resets Oct 10 at 8pm (UTC)
        """
        let q = ClaudeCLIUsage.parseText(text, now: now)
        try checkEqual(win(q, .session), QuotaWindow(kind: .session, usedPercent: 0, resetsAt: nil, windowMinutes: 300))
        for kind: QuotaWindow.Kind in [.weekly, .weeklyModel("Opus")] {
            try checkEqual(win(q, kind), QuotaWindow(kind: kind, usedPercent: 0,
                                                   resetsAt: at("2026-10-24T20:00:00Z"), windowMinutes: 10080))
        }
    }

    test("cliUsageFutureResetRemainsUnchanged") {
        for (label, kind, minutes): (String, QuotaWindow.Kind, Int) in [
            ("session", .session, 300), ("week", .weekly, 10080), ("week (Opus)", .weeklyModel("Opus"), 10080)
        ] {
            let q = ClaudeCLIUsage.parseText("Current \(label): 7.5% used · resets Oct 17 at 8:01pm (UTC)", now: now)
            try checkEqual(win(q, kind), QuotaWindow(kind: kind, usedPercent: 7.5,
                                                   resetsAt: at("2026-10-17T20:01:00Z"), windowMinutes: minutes))
        }
    }

    test("cliUsageMissingResetRemainsUnchanged") {
        for (label, kind, minutes): (String, QuotaWindow.Kind, Int) in [
            ("session", .session, 300), ("week", .weekly, 10080), ("week (Opus)", .weeklyModel("Opus"), 10080)
        ] {
            let q = ClaudeCLIUsage.parseText("Current \(label): 7.5% used", now: now)
            try checkEqual(win(q, kind), QuotaWindow(kind: kind, usedPercent: 7.5, resetsAt: nil, windowMinutes: minutes))
        }
    }

    test("cliUsageYearRollsOver") {
        let q = ClaudeCLIUsage.parseText("Current week (all models): 1% used · resets Jan 2 at 9am (UTC)",
                                         now: at("2026-12-30T12:00:00Z"))
        try checkEqual(win(q, .weekly)?.resetsAt, at("2027-01-02T09:00:00Z"))
    }

    test("cliUsageTimeWithoutDate") {
        // 只写时刻：取现在之后最近的那一次
        let q = ClaudeCLIUsage.parseText("Current session: 40% used · resets 3pm (UTC)", now: at("2026-10-17T12:00:00Z"))
        try checkEqual(win(q, .session)?.resetsAt, at("2026-10-17T15:00:00Z"))
        let q2 = ClaudeCLIUsage.parseText("Current session: 40% used · resets 11:30am (UTC)", now: at("2026-10-17T12:00:00Z"))
        try checkEqual(win(q2, .session)?.resetsAt, at("2026-10-18T11:30:00Z"))
        // 12am / 12pm
        let q3 = ClaudeCLIUsage.parseText("Current session: 1% used · resets Oct 18 at 12am (UTC)", now: at("2026-10-17T12:00:00Z"))
        try checkEqual(win(q3, .session)?.resetsAt, at("2026-10-18T00:00:00Z"))
        let q4 = ClaudeCLIUsage.parseText("Current session: 1% used · resets Oct 17 at 12:15pm (UTC)", now: at("2026-10-17T11:00:00Z"))
        try checkEqual(win(q4, .session)?.resetsAt, at("2026-10-17T12:15:00Z"))
    }

    test("cliUsageNoResetOrUnknownZone") {
        let q = ClaudeCLIUsage.parseText("Current session: 0% used", now: now)
        try checkEqual(win(q, .session)?.usedPercent, 0)
        try checkEqual(win(q, .session)?.resetsAt, nil)
        // 认不出的时区：百分比照用，不猜重置时间
        let q2 = ClaudeCLIUsage.parseText("Current session: 9% used · resets Oct 17 at 3pm (Mars/Olympus)", now: now)
        try checkEqual(win(q2, .session)?.usedPercent, 9)
        try checkEqual(win(q2, .session)?.resetsAt, nil)
    }

    test("cliUsageUnrecognizedText") {
        try checkEqual(ClaudeCLIUsage.parseText("Usage information is only available for subscription plans", now: now), nil)
        try checkEqual(ClaudeCLIUsage.parseText("", now: now), nil)
    }

    // MARK: 命令输出 → 结果

    test("cliUsageOutcomeFromJSON") {
        guard case .quota(let q) = ClaudeCLIUsage.outcome(stdout: wrap(sample), exitCode: 0, now: now) else {
            throw TestFailure(description: "应读到额度")
        }
        try checkEqual(q.windows.map(\.usedPercent), [12, 34])
        // 前面混了别的行也认最后那个 result 对象
        var mixed = Data("warning: something\n".utf8); mixed.append(wrap(sample))
        guard case .quota = ClaudeCLIUsage.outcome(stdout: mixed, exitCode: 0, now: now) else { throw TestFailure(description: "应读到额度") }
        try checkEqual(ClaudeCLIUsage.outcome(stdout: wrap("Not logged in · Please run /login\nmore"), exitCode: 0, now: now),
                       .unrecognized)
        try checkEqual(ClaudeCLIUsage.outcome(stdout: wrap("Invalid API key · Please run /login", isError: true), exitCode: 1, now: now),
                       .failed("Invalid API key · Please run /login"))
        try checkEqual(ClaudeCLIUsage.outcome(stdout: Data("boom".utf8), exitCode: 2, now: now), .failed("退出码 2"))
        try checkEqual(ClaudeCLIUsage.outcome(stdout: Data(), exitCode: 0, now: now), .unrecognized)
    }

    test("cliUsageRejectsNonzeroExitWithQuota") {
        try checkEqual(ClaudeCLIUsage.outcome(stdout: wrap(sample), exitCode: 2, now: now), .failed("退出码 2"))
    }

    test("cliUsageCaseInsensitiveSession") {
        let q = ClaudeCLIUsage.parseText("CURRENT SESSION: 12% used", now: now)
        try checkEqual(win(q, .session)?.usedPercent, 12)
        try checkEqual(win(q, .weekly), nil)
    }

    test("cliDiagnosticCurrentLinesAndPrefix") {
        let result = "其他文字\n  Current session: 未知\r\ncurrent week: 未知\n" + String(repeating: "字", count: 220)
        let d = ClaudeCLIUsage.diagnostic(stdout: wrap(result))
        try check(d.hasPrefix("Current session: 未知 | current week: 未知；前 200 字："))
        try check(d.hasSuffix(String(result.prefix(200)).components(separatedBy: .newlines).joined(separator: "⏎")))
        try check(!d.contains("\n") && !d.contains("\r"))
        try checkEqual(ClaudeCLIUsage.diagnostic(stdout: Data("普通\n文本".utf8)), "；前 200 字：普通⏎文本")
        try checkEqual(ClaudeCLIUsage.diagnostic(stdout: Data("提示\n".utf8) + wrap(result)), d)
    }


    // MARK: 结构化控制协议（使用用户提供的协议样本）
    func control(_ payload: String) -> Data {
        Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"usage","response":"#.utf8)
        + Data(payload.utf8) + Data("}}".utf8)
    }
    let usagePayload = #"""
    {"subscription_type":"pro","rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":56,"resets_at":"2026-10-18T07:39:59.649859+00:00"},"seven_day":{"utilization":19,"resets_at":"2026-10-24T15:59:59.649879+00:00"},"seven_day_opus":null,"seven_day_sonnet":null}}
    """#

    func usageWithAsOf(_ value: String) -> String {
        usagePayload.replacingOccurrences(of: #""seven_day_opus":null"#,
            with: #""seven_day_breakdown":{"as_of":"# + value + #"},"seven_day_opus":null"#)
    }

    test("cliControlRejectsStaleSnapshot") {
        for stamp in [#""2026-10-17T19:35:00Z""#, #""2026-10-17T19:35:00.123Z""#] {
            try checkEqual(ClaudeCLIUsage.controlOutcome(line: control(usageWithAsOf(stamp)), now: now),
                           ClaudeCLIUsage.stale)
        }
        try checkEqual(ClaudeCLIUsage.stale,
                       .failed("Claude 返回的是旧数据（没连上 Anthropic，检查代理），稍后自动再查"))
    }
    test("cliControlAcceptsFreshSnapshot") {
        for stamp in [#""2026-10-17T19:58:00Z""#, #""2026-10-17T19:58:00.123Z""#] {
            try checkEqual(ClaudeCLIUsage.controlOutcome(line: control(usageWithAsOf(stamp)), now: now),
                           ClaudeCLIUsage.controlOutcome(line: control(usagePayload), now: now))
        }
    }
    test("cliControlAcceptsMissingBreakdown") {
        guard case .quota(let q) = ClaudeCLIUsage.controlOutcome(line: control(usagePayload), now: now) else {
            throw TestFailure(description: "缺少 breakdown 仍应解析额度")
        }
        try checkEqual(q.windows.map(\.usedPercent), [56, 19])
    }
    test("cliControlAcceptsNullOrInvalidAsOf") {
        for value in ["null", #""bad date""#] {
            try checkEqual(ClaudeCLIUsage.controlOutcome(line: control(usageWithAsOf(value)), now: now),
                           ClaudeCLIUsage.controlOutcome(line: control(usagePayload), now: now))
        }
        let missing = usageWithAsOf("null").replacingOccurrences(of: #""as_of":null"#, with: "")
        try checkEqual(ClaudeCLIUsage.controlOutcome(line: control(missing), now: now),
                       ClaudeCLIUsage.controlOutcome(line: control(usagePayload), now: now))
    }
    test("cliControlStaleThresholdIsStrict") {
        for (stamp, isStale) in [
            (#""2026-10-17T19:50:00Z""#, false),
            (#""2026-10-17T19:49:59.999Z""#, true),
            (#""2026-10-17T20:01:00Z""#, false)
        ] {
            try checkEqual(ClaudeCLIUsage.controlOutcome(line: control(usageWithAsOf(stamp)), now: now),
                           isStale ? ClaudeCLIUsage.stale : ClaudeCLIUsage.controlOutcome(line: control(usagePayload), now: now))
        }
    }
    test("cliStaleDoesNotTriggerBackoff") {
        var backoff = ClaudeCLIUsage.Backoff()
        backoff.record(ClaudeCLIUsage.stale, now: now)
        try checkEqual(backoff.minutes, 0)
        try check(!backoff.blocked(now: now))
    }

    // MARK: 系统代理补全
    let httpsSystem: [String: Any] = ["HTTPSEnable": NSNumber(value: 1), "HTTPSProxy": "127.0.0.1", "HTTPSPort": NSNumber(value: 8890)]
    let httpSystem: [String: Any] = ["HTTPEnable": NSNumber(value: 1), "HTTPProxy": "localhost", "HTTPPort": NSNumber(value: 8080)]
    test("cliProxyHTTPSOnly") {
        try checkEqual(ClaudeCLIUsage.proxyEnvironment(system: httpsSystem, existing: [:]),
                       ["HTTPS_PROXY": "http://127.0.0.1:8890", "HTTP_PROXY": "http://127.0.0.1:8890"])
    }
    test("cliProxyHTTPSAndHTTP") {
        try checkEqual(ClaudeCLIUsage.proxyEnvironment(system: httpsSystem.merging(httpSystem) { _, new in new }, existing: [:]),
                       ["HTTPS_PROXY": "http://127.0.0.1:8890", "HTTP_PROXY": "http://localhost:8080"])
    }
    test("cliProxyHTTPOnly") {
        try checkEqual(ClaudeCLIUsage.proxyEnvironment(system: httpSystem, existing: [:]),
                       ["HTTPS_PROXY": "http://localhost:8080", "HTTP_PROXY": "http://localhost:8080"])
    }
    test("cliProxyPreservesExistingVariables") {
        for key in ["https_proxy", "HTTPS_PROXY", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"] {
            try checkEqual(ClaudeCLIUsage.proxyEnvironment(system: httpsSystem, existing: [key: "http://existing:1234"]), [:])
        }
        try checkEqual(ClaudeCLIUsage.proxyEnvironment(system: httpsSystem, existing: ["https_proxy": ""]),
                       ClaudeCLIUsage.proxyEnvironment(system: httpsSystem, existing: [:]))
    }
    test("cliProxyIgnoresSOCKSAndPAC") {
        for system: [String: Any] in [
            ["SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 8891],
            ["ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "http://localhost/proxy.pac"]
        ] {
            try checkEqual(ClaudeCLIUsage.proxyEnvironment(system: system, existing: [:]), [:])
        }
    }
    test("cliProxyNormalizesExceptions") {
        var system = httpsSystem
        system["ExceptionsList"] = ["*.local", "169.254/16", "<local>"]
        try checkEqual(ClaudeCLIUsage.proxyEnvironment(system: system, existing: [:])["NO_PROXY"], ".local,169.254/16")
        system["ExceptionsList"] = ["<local>"]
        try checkEqual(ClaudeCLIUsage.proxyEnvironment(system: system, existing: [:])["NO_PROXY"], nil)
        try checkEqual(ClaudeCLIUsage.proxyEnvironment(system: ["ExceptionsList": ["*.local"]], existing: [:]), [:])
    }
    test("cliProxyRequiresHost") {
        try checkEqual(ClaudeCLIUsage.proxyEnvironment(system: ["HTTPSEnable": 1, "HTTPSPort": 8890], existing: [:]), [:])
        var system = httpsSystem
        system["HTTPSProxy"] = ""
        try checkEqual(ClaudeCLIUsage.proxyEnvironment(system: system, existing: [:]), [:])
    }
    test("cliProxyRequiresEnabledValidPort") {
        for port in [0, -1, 65536, 8890.5] {
            var system = httpsSystem
            system["HTTPSPort"] = NSNumber(value: port)
            try checkEqual(ClaudeCLIUsage.proxyEnvironment(system: system, existing: [:]), [:])
        }
        for enabled in [0, 2] {
            var system = httpsSystem
            system["HTTPSEnable"] = NSNumber(value: enabled)
            try checkEqual(ClaudeCLIUsage.proxyEnvironment(system: system, existing: [:]), [:])
        }
    }

    test("cliControlMissingLimitsAreThrottled") {
        for payload in [
            #"{"subscription_type":"pro","rate_limits_available":true,"rate_limits":null}"#,
            #"{"subscription_type":"pro","rate_limits_available":true}"#
        ] {
            try checkEqual(ClaudeCLIUsage.controlOutcome(line: control(payload), now: now), ClaudeCLIUsage.throttled)
        }
        try checkEqual(ClaudeCLIUsage.controlOutcome(line: control(#"{"rate_limits_available":true,"rate_limits":{}}"#), now: now), .unrecognized)
    }

    test("cliBackoffEscalatesAndResetsOnQuota") {
        var backoff = ClaudeCLIUsage.Backoff()
        var date = now
        try check(!backoff.blocked(now: date))
        for minutes in [5, 10, 20, 30, 30] {
            backoff.record(ClaudeCLIUsage.throttled, now: date)
            try check(backoff.blocked(now: date))
            let end = date.addingTimeInterval(Double(minutes * 60))
            try check(backoff.blocked(now: end.addingTimeInterval(-1)))
            try check(!backoff.blocked(now: end))
            date = end
        }
        backoff.record(ClaudeCLIUsage.throttled, now: date)
        for outcome in [ClaudeCLIUsage.Outcome.unrecognized, .failed("超时"), .notInstalled, ClaudeCLIUsage.outdated] {
            backoff.record(outcome, now: date.addingTimeInterval(60))
            try check(backoff.blocked(now: date.addingTimeInterval(1799)))
            try check(!backoff.blocked(now: date.addingTimeInterval(1800)))
        }
        backoff.record(.quota(ClaudeCLIUsage.parseText(sample, now: date)!), now: date)
        try check(!backoff.blocked(now: date))
        backoff.record(ClaudeCLIUsage.throttled, now: date)
        try check(backoff.blocked(now: date.addingTimeInterval(299)))
        try check(!backoff.blocked(now: date.addingTimeInterval(300)))
    }

    test("cliControlParsesQuota") {
        guard case .quota(let q) = ClaudeCLIUsage.controlOutcome(line: control(usagePayload), now: now) else {
            throw TestFailure(description: "应读到结构化额度")
        }
        try checkEqual(q.plan, "pro")
        try checkEqual(q.observedAt, now)
        try checkEqual(q.windows.map(\.usedPercent), [56, 19])
        try checkEqual(q.windows.map(\.windowMinutes), [300, 10080])
        try check(abs(win(q, .session)!.resetsAt!.timeIntervalSince(at("2026-10-18T07:39:59Z")) - 0.649859) < 0.002)
        let models = usagePayload.replacingOccurrences(of: #""seven_day_opus":null"#, with: #""seven_day_opus":{"utilization":8}"#)
        guard case .quota(let qm) = ClaudeCLIUsage.controlOutcome(line: control(models), now: now) else {
            throw TestFailure(description: "应读到模型窗口")
        }
        try checkEqual(win(qm, .weeklyModel("Opus"))?.usedPercent, 8)
    }
    test("cliControlIgnoresOtherMessages") {
        for line in [#"{"type":"system"}"#, #"{"type":"control_response","response":{"subtype":"success","request_id":"initialize","response":{}}}"#, "bad json"] {
            try checkEqual(ClaudeCLIUsage.controlOutcome(line: Data(line.utf8), now: now), nil)
        }
    }
    test("cliControlErrors") {
        func error(_ message: String) -> ClaudeCLIUsage.Outcome? {
            let obj: [String: Any] = ["type": "control_response", "response": ["subtype": "error", "request_id": "usage", "error": message]]
            return ClaudeCLIUsage.controlOutcome(line: try! JSONSerialization.data(withJSONObject: obj), now: now)
        }
        try checkEqual(error("Unsupported control request subtype"), ClaudeCLIUsage.outdated)
        try checkEqual(error("unknown subtype"), ClaudeCLIUsage.outdated)
        try checkEqual(error("not logged in"), .failed("Claude Code 需要重新登录"))
        try checkEqual(error("Please sign in"), .failed("Claude Code 需要重新登录"))
        try checkEqual(error(""), .failed("命令行报错"))
        try checkEqual(error(String(repeating: "错", count: 100)), .failed(String(repeating: "错", count: 80)))
        try checkEqual(ClaudeCLIUsage.controlOutcome(line: control(#"{"rate_limits_available":false}"#), now: now),
                       .failed("没有订阅额度数据（需要 Pro/Max 登录）"))
    }
    test("cliControlValidatesWindowsAndDates") {
        let payload = #"{"subscription_type":"MAX","rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":true},"seven_day":{"utilization":119,"resets_at":"2026-10-24T17:59:59+02:00"},"seven_day_opus":{},"seven_day_sonnet":{"utilization":-5,"resets_at":"bad"}}}"#
        guard case .quota(let q) = ClaudeCLIUsage.controlOutcome(line: control(payload), now: now) else {
            throw TestFailure(description: "应跳过布尔值并保留有效窗口")
        }
        try checkEqual(q.plan, "max")
        try checkEqual(q.windows.map(\.usedPercent), [100, 0])
        try checkEqual(win(q, .weekly)?.resetsAt, at("2026-10-24T15:59:59Z"))
        try checkEqual(win(q, .weeklyModel("Sonnet"))?.resetsAt, nil)
        try checkEqual(ClaudeCLIUsage.controlOutcome(line: control(#"{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":true}}}"#), now: now), .unrecognized)
        guard case .quota(let old) = ClaudeCLIUsage.controlOutcome(line: control(usagePayload), now: at("2026-10-25T20:00:00Z")) else {
            throw TestFailure(description: "应处理已重置窗口")
        }
        try checkEqual(old.windows.map(\.usedPercent), [0, 0])
        try checkEqual(win(old, .session)?.resetsAt, nil)
        try check(win(old, .weekly)!.resetsAt! > at("2026-10-25T20:00:00Z"))
    }
    test("cliControlArgumentsAndRequests") {
        try checkEqual(ClaudeCLIUsage.controlArguments, ["--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--no-session-persistence", "--tools", "", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#, "--setting-sources", "", "--settings", #"{"disableAllHooks":true}"#])
        try checkEqual(String(decoding: ClaudeCLIUsage.controlRequests, as: UTF8.self),
                       "{\"type\":\"control_request\",\"request_id\":\"initialize\",\"request\":{\"subtype\":\"initialize\"}}\n{\"type\":\"control_request\",\"request_id\":\"usage\",\"request\":{\"subtype\":\"get_usage\",\"skip_behaviors\":true}}\n")
    }

    // MARK: 找命令、运行

    func tmpDir() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("tb claude cli \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    func script(_ dir: URL, _ body: String) throws -> URL {
        let f = dir.appendingPathComponent("claude")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: f)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        return f
    }


    testAsync("cliControlKillsTermIgnoringProcess") {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("pid")
        let reply = String(decoding: control(usagePayload), as: UTF8.self)
        let exe = try script(dir, """
        trap '' TERM
        echo $$ > '\(pidFile.path)'
        read first
        read second
        printf '%s\\n' '\(reply)'
        sleep 30
        """)
        let result = await ClaudeCLIUsage.runControl(executable: exe, cwd: dir, timeout: 4, now: now)
        let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        defer { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
        guard case .quota = result else { throw TestFailure(description: "应读到额度") }
        try await Task.sleep(nanoseconds: 3_500_000_000)
        try check(kill(pid, 0) != 0, "拿到结果后应杀掉忽略 TERM 的进程")
    }

    testAsync("cliControlReturnsBeforeExit") {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reply = String(decoding: control(usagePayload), as: UTF8.self)
        let exe = try script(dir, """
        IFS= read -r first
        IFS= read -r second
        [ "$DISABLE_AUTOUPDATER" = 1 ] || exit 8
        [ "${CLAUDECODE+x}" != x ] || exit 9
        [ "$first" = '{"type":"control_request","request_id":"initialize","request":{"subtype":"initialize"}}' ] || exit 10
        [ "$second" = '{"type":"control_request","request_id":"usage","request":{"subtype":"get_usage","skip_behaviors":true}}' ] || exit 11
        printf '%s\n' '{"type":"control_response","response":{"subtype":"success","request_id":"initialize"}}'
        printf '%s\n' '\(reply)'
        sleep 30
        """)
        let start = Date()
        let result = await ClaudeCLIUsage.runControl(executable: exe, cwd: dir.appendingPathComponent("work dir"), timeout: 4, now: now)
        guard case .quota(let q) = result else { throw TestFailure(description: "应立即拿到额度：\(result)") }
        try checkEqual(q.windows.map(\.usedPercent), [56, 19])
        try check(Date().timeIntervalSince(start) < 5)
    }

    testAsync("cliControlReassemblesPartialLine") {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reply = String(decoding: control(usagePayload), as: UTF8.self)
        let cut = reply.index(reply.startIndex, offsetBy: reply.count / 2)
        let exe = try script(dir, """
        read first
        read second
        printf '%s' '\(reply[..<cut])'
        sleep 0.1
        printf '%s\\n' '\(reply[cut...])'
        """)
        guard case .quota = await ClaudeCLIUsage.runControl(executable: exe, cwd: dir, timeout: 3, now: now) else {
            throw TestFailure(description: "应拼接跨批次的半行 JSON")
        }
    }

    testAsync("cliControlExitAndTimeout") {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let exe = try script(dir, "exit 3")
        try checkEqual(await ClaudeCLIUsage.runControl(executable: exe, cwd: dir, timeout: 2, now: now), .failed("退出码 3"))
        _ = try script(dir, "sleep 30")
        let start = Date()
        try checkEqual(await ClaudeCLIUsage.runControl(executable: exe, cwd: dir, timeout: 1, now: now), .failed("超时"))
        try check(Date().timeIntervalSince(start) < 3)
    }

    test("cliUsageLocateAndArguments") {
        let dir = try tmpDir()
        let missing = dir.appendingPathComponent("nope/claude")
        try checkEqual(ClaudeCLIUsage.locate([missing]), nil)
        let plain = dir.appendingPathComponent("not-exec")
        try Data("x".utf8).write(to: plain)
        try checkEqual(ClaudeCLIUsage.locate([plain]), nil)
        let exe = try script(dir, "exit 0")
        try checkEqual(ClaudeCLIUsage.locate([missing, plain, exe]), exe)
        // 不调用模型、不留会话记录、不启动 MCP、不加载用户设置里的钩子和插件
        try checkEqual(ClaudeCLIUsage.arguments, ["-p", "/usage", "--output-format", "json", "--no-session-persistence",
                                                  "--strict-mcp-config", "--setting-sources", "project"])
        let home = URL(fileURLWithPath: "/Users/x")
        try checkEqual(ClaudeCLIUsage.candidates(home: home).map(\.path).first, "/Users/x/.local/bin/claude")
        try checkEqual(ClaudeCLIUsage.candidates(home: home).map(\.path).last, "/Users/x/.npm-global/bin/claude")
        try FileManager.default.removeItem(at: dir)
    }

    testAsync("cliUsageRunsScript") {
        let dir = try tmpDir()
        let out = String(data: wrap(sample), encoding: .utf8)!.replacingOccurrences(of: "'", with: "'\\''")
        let exe = try script(dir, "[ \"$1 $2\" = \"-p /usage\" ] || exit 9\nprintf '%s' '\(out)'")
        let cwd = dir.appendingPathComponent("work dir")
        let r = await ClaudeCLIUsage.run(executable: exe, cwd: cwd, timeout: 10, now: now)
        guard case .quota(let q) = r else { throw TestFailure(description: "应读到额度，实际 \(r)") }
        try checkEqual(q.windows.map(\.usedPercent), [12, 34])
        // 工作目录不存在时自动建好
        try check(FileManager.default.fileExists(atPath: cwd.path))
        try FileManager.default.removeItem(at: dir)
    }

    testAsync("cliUsageTimeout") {
        let dir = try tmpDir()
        let exe = try script(dir, "sleep 5")
        let t0 = Date()
        let r = await ClaudeCLIUsage.run(executable: exe, cwd: dir, timeout: 0.5, now: now)
        try checkEqual(r, .failed("超时"))
        try check(Date().timeIntervalSince(t0) < 3, "超时后应立刻返回")
        try FileManager.default.removeItem(at: dir)
    }

    testAsync("cliUsageTimeoutAfterParentExits") {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 后台进程保留 stdout；主进程退出不代表输出已结束。
        let exe = try script(dir, "sleep 4 &\nexit 0")
        let start = Date()
        let result = await ClaudeCLIUsage.run(executable: exe, cwd: dir, timeout: 0.5, now: now)
        try checkEqual(result, .failed("超时"))
        try check(Date().timeIntervalSince(start) < 3, "不能等后台进程关闭 stdout")
    }

    testAsync("cliUsageDrainsLargeStdout") {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = String(data: wrap(sample), encoding: .utf8)!.replacingOccurrences(of: "'", with: "'\\''")
        let exe = try script(dir, "/usr/bin/head -c 262144 /dev/zero | /usr/bin/tr '\\000' 'x'\nprintf '\\n%s' '\(output)'")
        let result = await ClaudeCLIUsage.run(executable: exe, cwd: dir, timeout: 5, now: now)
        guard case .quota(let q) = result else { throw TestFailure(description: "大输出不应堵塞管道：\(result)") }
        try checkEqual(q.windows.map(\.usedPercent), [12, 34])
    }

    testAsync("cliUsageLaunchFailure") {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = await ClaudeCLIUsage.run(executable: dir.appendingPathComponent("missing"), cwd: dir, timeout: 0.5, now: now)
        try checkEqual(result, .failed("启动失败"))
    }

    // MARK: 桌面来源：命令行优先，没有时退回桌面记录

    func ms(_ d: Date) -> Int { Int(d.timeIntervalSince1970 * 1000) }
    func fetch(_ p: ClaudePlanProvider) async -> Result<ProviderSnapshot, ProviderError> {
        await p.fetch(Credentials(values: [:]), now: now, timeZone: TimeZone(identifier: "UTC")!)
    }

    testAsync("desktopPrefersCLI") {
        let dir = try tmpDir()
        let app = dir.appendingPathComponent("plan-usage-history.json")
        try Data("{\"version\":2,\"samples\":[{\"t\":\(ms(now.addingTimeInterval(-600))),\"u\":{\"fh\":90,\"sd\":90}}]}".utf8).write(to: app)
        let cliQ = ClaudeCLIUsage.parseText(sample, now: now)!
        let p = ClaudePlanProvider(quotaFile: dir.appendingPathComponent("hook.json"), desktopFile: app, source: { .desktop },
                                   cli: { _ in .quota(cliQ) })
        guard case .success(let s) = await fetch(p) else { throw TestFailure(description: "应为 success") }
        try checkEqual(s.quota, cliQ)
        try checkEqual(s.quotaNote, nil)
        // 终端来源不跑命令行
        let pt = ClaudePlanProvider(quotaFile: dir.appendingPathComponent("hook.json"), desktopFile: app, source: { .terminal },
                                    cli: { _ in throw TestFailure(description: "终端来源不该跑命令行") })
        guard case .success(let st) = await fetch(pt) else { throw TestFailure(description: "应为 success") }
        try checkEqual(st.quotaNote, ClaudePlanProvider.waitingNote)
        try FileManager.default.removeItem(at: dir)
    }

    testAsync("desktopFallsBackToAppFile") {
        let dir = try tmpDir()
        let app = dir.appendingPathComponent("plan-usage-history.json")
        func provider(_ o: ClaudeCLIUsage.Outcome) -> ClaudePlanProvider {
            ClaudePlanProvider(quotaFile: dir.appendingPathComponent("hook.json"), desktopFile: app, source: { .desktop },
                               cli: { _ in o }, sleep: { _ in })
        }
        // 记录新鲜：照旧按记录推算
        try Data("{\"version\":2,\"samples\":[{\"t\":\(ms(now.addingTimeInterval(-600))),\"u\":{\"fh\":30}}]}".utf8).write(to: app)
        guard case .success(let s1) = await fetch(provider(.notInstalled)), let q1 = s1.quota else {
            throw TestFailure(description: "应读到额度")
        }
        try checkEqual(q1.windows.map(\.usedPercent), [30])
        try checkEqual(q1.estimated, true)
        // 记录过旧（超过 1 小时）：不推算，直接写停在什么时候，并说明为什么没用命令行
        try Data("{\"version\":2,\"samples\":[{\"t\":\(ms(at("2026-10-16T22:37:00Z"))),\"u\":{\"fh\":30,\"sd\":10}}]}".utf8).write(to: app)
        guard case .success(let s2) = await fetch(provider(.notInstalled)) else { throw TestFailure(description: "应为 success") }
        try checkEqual(s2.quota, nil)
        try checkEqual(s2.quotaNote, "Claude 桌面 App 的额度记录停在 10月16日 22:37。装好 Claude Code 命令行后能读到实时额度和准确的重置时间")
        for outcome in [ClaudeCLIUsage.Outcome.failed("超时"), .unrecognized, ClaudeCLIUsage.outdated] {
            guard case .failure(.unavailable(let reason)) = await fetch(provider(outcome)) else {
                throw TestFailure(description: "失败不能使用桌面旧记录")
            }
            try checkEqual(reason, ClaudePlanProvider.cliHint(outcome))
        }
        // 今天停的写「今天」
        try Data("{\"version\":2,\"samples\":[{\"t\":\(ms(at("2026-10-17T08:05:00Z"))),\"u\":{\"fh\":30}}]}".utf8).write(to: app)
        guard case .success(let s5) = await fetch(provider(.notInstalled)) else { throw TestFailure(description: "应为 success") }
        try check(s5.quotaNote?.hasPrefix("Claude 桌面 App 的额度记录停在 今天 08:05。") == true, s5.quotaNote ?? "nil")
        // 文件也没有：等待说明加上原因
        try FileManager.default.removeItem(at: app)
        guard case .success(let s6) = await fetch(provider(.notInstalled)) else { throw TestFailure(description: "应为 success") }
        try checkEqual(s6.quotaNote, ClaudePlanProvider.desktopWaitingNote + "。" + ClaudePlanProvider.cliMissingHint)
        try FileManager.default.removeItem(at: dir)
    }

    test("appSourceStaleOutcome") {
        let dir = try tmpDir()
        let f = dir.appendingPathComponent("plan-usage-history.json")
        try Data("{\"version\":2,\"samples\":[{\"t\":\(ms(now.addingTimeInterval(-7200))),\"u\":{\"fh\":30}}]}".utf8).write(to: f)
        try checkEqual(ClaudeAppUsageSource.read(f, now: now), .stale(now.addingTimeInterval(-7200)))
        // 一小时内照常推算
        try Data("{\"version\":2,\"samples\":[{\"t\":\(ms(now.addingTimeInterval(-3000))),\"u\":{\"fh\":30}}]}".utf8).write(to: f)
        guard case .quota = ClaudeAppUsageSource.read(f, now: now) else { throw TestFailure(description: "应读到额度") }
        try FileManager.default.removeItem(at: dir)
    }
}
