import Foundation

@MainActor
func registerClaudePlanProviderTests() {
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
        try checkEqual(ProviderRegistry.all.last, .claudePlan)
        try checkEqual(Array(ProviderRegistry.all.suffix(2)), [.codexPlan, .claudePlan])
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
}
