import Foundation

@MainActor
func registerClaudePlanProviderTests() {
    testAsync("claudeSuspectedLoginIsAuthAndExpiryBoundaries") {
        let now = Date(timeIntervalSince1970: 1_792_022_400)
        let q = Quota(plan: "max", windows: [], observedAt: now)
        let failed = ClaudePlanProvider(quotaFile: URL(fileURLWithPath: "/unused"), source: { .desktop },
                                        cli: { _ in ClaudeCLIUsage.suspectedLogin })
        try checkEqual(await failed.fetch(Credentials(values: [:]), now: now, timeZone: .gmt),
                       .failure(.auth(L("cli.suspectedLogin"))))
        for (seconds, credential): (Double, CredentialState) in [(259200, .expiring(days: 3)), (259201, .ok), (-1, .ok), (0, .ok), (1, .expiring(days: 0)), (86399, .expiring(days: 0)), (2.5 * 86400, .expiring(days: 3))] {
            let p = ClaudePlanProvider(quotaFile: URL(fileURLWithPath: "/unused"), source: { .desktop },
                                       cli: { _ in .quota(q) }, loginExpiry: { $0.addingTimeInterval(seconds) })
            let s = try await p.fetch(Credentials(values: [:]), now: now, timeZone: .gmt).get()
            try checkEqual(s.credential, credential)
        }
    }
    testAsync("claudeExpiryOnlyQueriesSuccessfulDesktopCLI") {
        actor Count { var n = 0; func hit() { n += 1 } }
        let calls = Count()
        for source in [ClaudePlanSource.desktop, .terminal, .web] {
            let p = ClaudePlanProvider(quotaFile: URL(fileURLWithPath: "/unused"), desktopFile: URL(fileURLWithPath: "/unused"),
                                       source: { source }, cli: { _ in .notInstalled },
                                       loginExpiry: { _ in await calls.hit(); return Date() })
            _ = await p.fetch(Credentials(values: [:]), now: Date(), timeZone: .gmt)
        }
        try checkEqual(await calls.n, 0)
    }
    testAsync("claudeLoginFailureIsAuth") {
        let p = ClaudePlanProvider(quotaFile: URL(fileURLWithPath: "/unused"), source: { .desktop },
                                   cli: { _ in ClaudeCLIUsage.needsLogin })
        let result = await p.fetch(Credentials(values: [:]), now: Date(), timeZone: .gmt)
        try checkEqual(result, .failure(.auth(L("cli.needsLogin"))))
    }

    let now = Date(timeIntervalSince1970: 1_792_022_400)
    let docExample = "{\"writtenAt\":1792022400,\"rate_limits\":{\"five_hour\":{\"used_percentage\":23.5,\"resets_at\":1792030000},\"seven_day\":{\"used_percentage\":41.2,\"resets_at\":1792500000}}}"
    let waitNote = "额度只在终端版 Claude Code 里更新，token 用量照常统计"

    func tmpDir() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("tb claude plan \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    func fetch(_ file: URL) async -> Result<ProviderSnapshot, ProviderError> {
        await ClaudePlanProvider(quotaFile: file).fetch(Credentials(values: [:]), now: now, timeZone: TimeZone(identifier: "UTC")!)
    }
    func fetch(content: String) async throws -> Result<ProviderSnapshot, ProviderError> {
        let f = try tmpDir().appendingPathComponent("claude-ratelimits.json")
        try Data(content.utf8).write(to: f)
        return await fetch(f)
    }

    testAsync("claudeDesktopRetriesAccurately") {
        actor Calls {
            var outcomes: [ClaudeCLIUsage.Outcome]
            var delays: [TimeInterval] = []
            var dates: [Date] = []
            init(_ outcomes: [ClaudeCLIUsage.Outcome]) { self.outcomes = outcomes }
            func next(_ now: Date) -> ClaudeCLIUsage.Outcome { dates.append(now); return outcomes.removeFirst() }
            func sleep(_ delay: TimeInterval) { delays.append(delay) }
        }
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("desktop.json")
        try Data("{\"version\":2,\"samples\":[{\"t\":\(Int(now.timeIntervalSince1970 * 1000)),\"u\":{\"fh\":30}}]}".utf8).write(to: file)
        let q = Quota(plan: nil, windows: [QuotaWindow(kind: .session, usedPercent: 70, resetsAt: nil, windowMinutes: nil)], observedAt: now)
        for outcomes in [[.unrecognized, .unrecognized, .quota(q)], [.failed("超时"), .failed("超时"), .failed("超时")], [.unrecognized, .notInstalled]] as [[ClaudeCLIUsage.Outcome]] {
            let calls = Calls(outcomes)
            let p = ClaudePlanProvider(quotaFile: dir.appendingPathComponent("hook.json"), desktopFile: file,
                                       source: { .desktop }, cli: { await calls.next($0) }, sleep: { await calls.sleep($0) })
            let result = await p.fetch(Credentials(values: [:]), now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
            switch outcomes.last! {
            case .quota: try checkEqual(try result.get().quota, q)
            case .notInstalled: try checkEqual(try result.get().quota?.estimated, true)
            default:
                guard case .failure(.unavailable(let why)) = result else { throw TestFailure(description: "不能退回有效桌面记录") }
                try checkEqual(why, "claude 命令行没查到额度：超时")
            }
            try checkEqual(await calls.delays, Array([5.0, 25.0].prefix(outcomes.count - 1)))
            try checkEqual(await calls.dates, Array(repeating: now, count: outcomes.count))
        }
    }

    testAsync("claudeDesktopDoesNotRetryThrottled") {
        actor Calls {
            var count = 0
            var delays: [TimeInterval] = []
            func next() -> ClaudeCLIUsage.Outcome { count += 1; return ClaudeCLIUsage.throttled }
            func sleep(_ delay: TimeInterval) { delays.append(delay) }
        }
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let calls = Calls()
        let p = ClaudePlanProvider(quotaFile: dir.appendingPathComponent("hook.json"),
                                   desktopFile: dir.appendingPathComponent("desktop.json"), source: { .desktop },
                                   cli: { _ in await calls.next() }, sleep: { await calls.sleep($0) })
        let result = await p.fetch(Credentials(values: [:]), now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        try checkEqual(result, .failure(.unavailable("claude 命令行没查到额度：Claude 暂时没给额度数据（多半是查得太勤被限流），稍后自动再查")))
        try checkEqual(await calls.count, 1)
        try checkEqual(await calls.delays, [])
    }

    test("claudeParsesDocExample") {
        guard case .success(let q?) = ClaudePlanProvider.parse(Data(docExample.utf8)) else {
            throw TestFailure(description: "应解析出额度")
        }
        try checkEqual(q.windows.map(\.kind), [.session, .weekly])
        try checkEqual(q.windows.map(\.usedPercent), [23.5, 41.2])
        try checkEqual(q.windows.map(\.windowMinutes), [300, 10080])
        try checkEqual(q.windows.map(\.resetsAt), [Date(timeIntervalSince1970: 1_792_030_000), Date(timeIntervalSince1970: 1_792_500_000)])
        try checkEqual(q.observedAt, Date(timeIntervalSince1970: 1_792_022_400))
        try check(q.plan == nil, "plan 应为 nil")
    }

    test("claudeMissingWindow") {
        let s = "{\"writtenAt\":1792022400,\"rate_limits\":{\"seven_day\":{\"used_percentage\":41.2,\"resets_at\":1792500000}}}"
        guard case .success(let q?) = ClaudePlanProvider.parse(Data(s.utf8)) else { throw TestFailure(description: "应解析出额度") }
        try checkEqual(q.windows.map(\.kind), [.weekly])
        try checkEqual(q.windows.map(\.usedPercent), [41.2])
    }

    testAsync("claudeEmptyAndHalfFile") {
        for content in ["", "{\"writtenAt\":17920"] {
            guard case .success(let snap) = try await fetch(content: content) else { throw TestFailure(description: "应为 success：\(content)") }
            try check(snap.quota == nil, "quota 应为 nil：\(content)")
            try checkEqual(snap.quotaNote, waitNote)
            try checkEqual(snap.source, .quota)
            try checkEqual(snap.provider, .claudePlan)
        }
    }

    testAsync("claudeNoFileWaits") {
        let f = try tmpDir().appendingPathComponent("claude-ratelimits.json")
        guard case .success(let snap) = await fetch(f) else { throw TestFailure(description: "应为 success") }
        try check(snap.quota == nil, "quota 应为 nil")
        try checkEqual(snap.quotaNote, waitNote)
    }

    testAsync("claudeEmptyRateLimitsNote") {
        guard case .success(let snap) = try await fetch(content: "{\"writtenAt\":1792022400,\"rate_limits\":{}}") else {
            throw TestFailure(description: "应为 success")
        }
        try check(snap.quota == nil, "quota 应为 nil")
        try checkEqual(snap.quotaNote, "没收到额度数据（只有 Pro/Max 订阅会提供）")
    }

    testAsync("claudeRenamedFieldSchemaChanged") {
        let renamed = docExample.replacingOccurrences(of: "used_percentage", with: "used_pct")
        try checkEqual(ClaudePlanProvider.parse(Data(renamed.utf8)), .failure(.schemaChanged("Claude 额度数据格式变了")))
        let r = try await fetch(content: renamed)
        guard case .failure(.schemaChanged) = r else { throw TestFailure(description: "期望 schemaChanged，实际 \(r)") }
        // 缺 writtenAt / rate_limits 也算格式变了
        try checkEqual(ClaudePlanProvider.parse(Data("{\"rate_limits\":{}}".utf8)), .failure(.schemaChanged("Claude 额度数据格式变了")))
        try checkEqual(ClaudePlanProvider.parse(Data("{\"writtenAt\":1792022400}".utf8)), .failure(.schemaChanged("Claude 额度数据格式变了")))
    }

    testAsync("claudeUnreadableFileUnavailable") {
        // 路径是个目录：存在但读不了
        let dir = try tmpDir().appendingPathComponent("claude-ratelimits.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try checkEqual(await fetch(dir), .failure(.unavailable("读不到 \(dir.path)")))
    }

    test("claudeRegistry") {
        try checkEqual(ProviderRegistry.displayName(.claudePlan), "Claude 套餐")
        try checkEqual(ProviderRegistry.meter(.claudePlan), .quota)
        try checkEqual(Array(ProviderRegistry.all.suffix(3)), [.codexPlan, .claudePlan, .geminiPlan])
        let p = ProviderRegistry.makeProvider(.claudePlan, http: InlineHTTPClient { _ in (500, "") })
        try checkEqual(p.id, .claudePlan)
        try checkEqual(p.capabilities.minPollInterval, 60)
        try checkEqual(p.capabilities.meter, .quota)
        try check(!p.capabilities.needsCredentials, "不需要凭据")
        try checkEqual((p as? ClaudePlanProvider)?.quotaFile, ClaudeStatusLineInstaller.standard.quotaFileURL)
    }

    testAsync("claudeEndToEndWithHook") {
        let root = try tmpDir()
        let settings = root.appendingPathComponent(".claude/settings.json")
        let installer = ClaudeStatusLineInstaller(settingsURL: settings,
                                                  supportDir: root.appendingPathComponent("Application Support/TokenBar"))
        guard case .installed = try installer.install() else { throw TestFailure(description: "应装上钩子") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [installer.hookURL.path]
        let inPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        let stdin = "{\"session_id\":\"s\",\"rate_limits\":{\"five_hour\":{\"used_percentage\":23.5,\"resets_at\":1792030000},\"seven_day\":{\"used_percentage\":41.2,\"resets_at\":1792500000}}}"
        inPipe.fileHandleForWriting.write(Data(stdin.utf8))
        try inPipe.fileHandleForWriting.close()
        p.waitUntilExit()
        try checkEqual(p.terminationStatus, 0)
        guard case .success(let snap) = await fetch(installer.quotaFileURL), let q = snap.quota else {
            throw TestFailure(description: "应读到额度")
        }
        try checkEqual(q.windows.first { $0.kind == .session }?.usedPercent, 23.5)
        try FileManager.default.removeItem(at: root)
    }
    test("claudeRouteDetect") {
        func route(_ json: String) -> ClaudeAPIRoute { ClaudeAPIRoute.detect(settings: Data(json.utf8)) }
        try checkEqual(ClaudeAPIRoute.detect(settings: nil), .subscription)
        try checkEqual(route("not json"), .subscription)
        try checkEqual(route("{\"theme\":\"auto\"}"), .subscription)
        try checkEqual(route("{\"env\":{\"ANTHROPIC_BASE_URL\":\"https://cf.api.fan\",\"ANTHROPIC_AUTH_TOKEN\":\"sk-x\"}}"), .relay(host: "cf.api.fan"))
        try checkEqual(route("{\"env\":{\"ANTHROPIC_BASE_URL\":\"relay.example.com/v1\"}}"), .relay(host: "relay.example.com"))
        try checkEqual(route("{\"env\":{\"ANTHROPIC_BASE_URL\":\"https://API.Anthropic.com\"}}"), .subscription)
        try checkEqual(route("{\"env\":{\"ANTHROPIC_BASE_URL\":\"  \"}}"), .subscription)
        try checkEqual(route("{\"env\":{\"ANTHROPIC_BASE_URL\":\"https://evilanthropic.com\"}}"), .relay(host: "evilanthropic.com"))
        try checkEqual(route("{\"env\":{\"ANTHROPIC_API_KEY\":\"sk-ant\"}}"), .apiBilling)
        try checkEqual(route("{\"env\":{\"ANTHROPIC_API_KEY\":\"\"}}"), .subscription)
        try checkEqual(route("{\"env\":{\"CLAUDE_CODE_USE_BEDROCK\":\"1\"}}"), .apiBilling)
        try checkEqual(route("{\"env\":{\"CLAUDE_CODE_USE_VERTEX\":\"0\"}}"), .subscription)
        try checkEqual(route("{\"apiKeyHelper\":\"~/bin/key.sh\"}"), .apiBilling)
        try checkEqual(route(#"{"env":{"ANTHROPIC_BASE_URL":"https://anthropic.com"}}"#), .subscription)
        try checkEqual(route(#"{"env":{"ANTHROPIC_BASE_URL":"RELAY.example:8080/v1"}}"#), .relay(host: "relay.example"))
        try checkEqual(route(#"{"env":{"ANTHROPIC_BASE_URL":"https://anthropic.com.evil.example"}}"#), .relay(host: "anthropic.com.evil.example"))
        try checkEqual(route(#"{"env":{"ANTHROPIC_BASE_URL":"https://[invalid?key=private"}}"#), .subscription)
        try checkEqual(ClaudeAPIRoute.subscription.note, nil)
        try check(ClaudeAPIRoute.relay(host: "cf.api.fan").note?.contains("cf.api.fan") == true, "说明里应带中转主机名")
    }

    for (host, expected) in [
        ("api.anthropic.com.", ClaudeAPIRoute.subscription),
        ("anthropic.com.", .subscription),
        ("cf.api.fan.", .relay(host: "cf.api.fan")),
        ("evilanthropic.com.", .relay(host: "evilanthropic.com"))
    ] {
        test("claudeRouteTrailingDNSDot-\(host)") {
            let data = try JSONSerialization.data(withJSONObject: ["env": ["ANTHROPIC_BASE_URL": "https://\(host)"]])
            try checkEqual(ClaudeAPIRoute.detect(settings: data), expected)
        }
    }

    test("claudeRouteFlagsAndEmptyValues") {
        for key in ["CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"] {
            for value in ["0", "false", "NO", " off ", "", "  ", "1", "true"] {
                let data = try JSONSerialization.data(withJSONObject: ["env": [key: value]])
                try checkEqual(ClaudeAPIRoute.detect(settings: data), ["1", "true"].contains(value) ? .apiBilling : .subscription)
            }
        }
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"] {
            for value in ["", " \n", "test-only-placeholder"] {
                let data = try JSONSerialization.data(withJSONObject: ["env": [key: value]])
                try checkEqual(ClaudeAPIRoute.detect(settings: data), value == "test-only-placeholder" ? .apiBilling : .subscription)
            }
        }
        try checkEqual(ClaudeAPIRoute.detect(settings: Data(#"{"apiKeyHelper":" \n "}"#.utf8)), .subscription)
    }

    test("claudeRouteReadsSymlinkAndUnreadableFile") {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = dir.appendingPathComponent("actual.json")
        let link = dir.appendingPathComponent("settings.json")
        try Data(#"{"env":{"ANTHROPIC_BASE_URL":"https://USER:private@RELAY.example:443/v1?key=private"}}"#.utf8).write(to: settings)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: settings)
        try checkEqual(ClaudeAPIRoute.read(link), .relay(host: "relay.example"))
        try checkEqual(ClaudeAPIRoute.read(dir), .subscription)
        try checkEqual(ClaudeAPIRoute.read(dir.appendingPathComponent("missing")), .subscription)
    }

    testAsync("claudeRelayTerminalNote") {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for relay in [ClaudeAPIRoute.relay(host: "cf.api.fan"), .apiBilling] {
            let p = ClaudePlanProvider(quotaFile: dir.appendingPathComponent("claude-ratelimits.json"), route: { relay })
            guard case .success(let snap) = await p.fetch(Credentials(values: [:]), now: now, timeZone: TimeZone(identifier: "UTC")!) else {
                throw TestFailure(description: "应为 success")
            }
            try check(snap.quota == nil, "quota 应为 nil")
            try checkEqual(snap.quotaNote, relay.note)
            for content in ["not JSON", #"{"writtenAt":1792022400,"rate_limits":{}}"#] {
                try Data(content.utf8).write(to: p.quotaFile)
                let empty = try await p.fetch(Credentials(values: [:]), now: now, timeZone: .gmt).get()
                try checkEqual(empty.quotaNote, relay.note)
                try checkEqual(empty.quota, nil)
            }
            // 额度文件里有数时照常显示
            let f = dir.appendingPathComponent("claude-ratelimits.json")
            try Data(docExample.utf8).write(to: f)
            guard case .success(let s2) = await p.fetch(Credentials(values: [:]), now: now, timeZone: TimeZone(identifier: "UTC")!) else {
                throw TestFailure(description: "应为 success")
            }
            try check(s2.quota != nil, "有额度文件时应显示额度")
            try checkEqual(s2.quotaNote, nil)
            try FileManager.default.removeItem(at: f)
        }
    }

    testAsync("claudeRelayDesktopSkipsCLI") {
        actor Count { var n = 0; func hit() { n += 1 } }
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let calls = Count()
        let relay = ClaudeAPIRoute.relay(host: "cf.api.fan")
        for relay in [relay, .apiBilling] {
            for installed in [true, false] {
                let p = ClaudePlanProvider(quotaFile: dir.appendingPathComponent("hook.json"), desktopFile: dir.appendingPathComponent("missing.json"),
                                           source: { .desktop }, cli: { _ in await calls.hit(); return .unrecognized },
                                           desktopInstalled: { installed }, route: { relay }, sleep: { _ in await calls.hit() })
                guard case .success(let snap) = await p.fetch(Credentials(values: [:]), now: now, timeZone: TimeZone(identifier: "UTC")!) else {
                    throw TestFailure(description: "走中转时应为 success，不报命令行失败")
                }
                if installed {
                    try checkEqual(snap.quotaNote, [ClaudePlanProvider.desktopWaitingNote, relay.cliHint!].joined(separator: L("common.sentenceSep")))
                } else {
                    try checkEqual(snap.quotaNote, relay.note)
                }
            }
        }
        try checkEqual(await calls.n, 0)
    }
    testAsync("claudeRelayDesktopKeepsQuotaAndHint") {
        actor Count { var n = 0; func hit() { n += 1 } }
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("desktop.json")
        try Data("{\"version\":2,\"samples\":[{\"t\":\(Int(now.timeIntervalSince1970 * 1000)),\"u\":{\"fh\":30}}]}".utf8).write(to: file)
        for route in [ClaudeAPIRoute.relay(host: "relay.example"), .apiBilling] {
            let cliCalls = Count()
            let sleeps = Count()
            let p = ClaudePlanProvider(quotaFile: dir.appendingPathComponent("hook.json"), desktopFile: file,
                                       source: { .desktop }, cli: { _ in await cliCalls.hit(); return .notInstalled },
                                       route: { route }, sleep: { _ in await sleeps.hit() })
            let snap = try await p.fetch(Credentials(values: [:]), now: now, timeZone: .gmt).get()
            try checkEqual(await cliCalls.n, 0)
            try checkEqual(await sleeps.n, 0)
            try checkEqual(snap.quota?.windows.first?.usedPercent, 30)
            try checkEqual(snap.quota?.estimated, true)
            try checkEqual(snap.quotaNote, route.cliHint)
        }
    }

}
