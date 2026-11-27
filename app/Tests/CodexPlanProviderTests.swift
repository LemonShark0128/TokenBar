import Foundation

@MainActor
func registerCodexPlanProviderTests() {
    let utc = TimeZone(identifier: "UTC")!
    let now = Date(timeIntervalSince1970: 1_792_022_400)   // 2026-10-15 00:00:00 UTC
    let ts = "2026-10-15T00:26:18.526Z"

    func codexLine(used: Double = 35, weeklyUsed: Double? = 100, resets: Int = 1792041780,
                   usedKey: String = "used_percent", stamp: String = "2026-10-15T00:26:18.526Z") -> String {
        let sec = weeklyUsed.map { "{\"\(usedKey)\":\($0),\"window_minutes\":10080,\"resets_at\":1792472859}" } ?? "null"
        return "{\"timestamp\":\"\(stamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"limit_id\":\"codex\",\"primary\":{\"\(usedKey)\":\(used),\"window_minutes\":300,\"resets_at\":\(resets)},\"secondary\":\(sec),\"plan_type\":\"plus\"}}}"
    }
    let premiumLine = "{\"timestamp\":\"2026-10-15T00:30:00.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"limit_id\":\"premium\",\"primary\":null,\"secondary\":null,\"plan_type\":\"plus\"}}}"

    func tmp() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("tb-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    /// day 形如 "2026/10/15"
    @discardableResult
    func writeSession(root: URL, day: String, name: String, lines: [String], mtime: Date) throws -> URL {
        let dir = root.appendingPathComponent(day, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent(name)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: f)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: f.path)
        return f
    }
    func fetch(_ root: URL) async -> Result<ProviderSnapshot, ProviderError> {
        await CodexPlanProvider(root: root, resetCredits: { nil }, resetCreditsMemory: ResetCreditsMemory()).fetch(Credentials(values: [:]), now: now, timeZone: utc)
    }

    testAsync("codexRemembersLiveResetCreditsOnLogFallback") {
        let root = try tmp()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSession(root: root, day: "2026/10/15", name: "a.jsonl", lines: [codexLine()], mtime: now)
        actor LiveSequence {
            var calls = 0
            func next() -> Quota? {
                calls += 1
                guard calls == 1 else { return nil }
                var q = Quota(plan: "plus", windows: [], observedAt: Date(timeIntervalSince1970: 0))
                q.resetCredits = ResetCredits(available: 2, expiresAt: nil)
                return q
            }
        }
        let live = LiveSequence()
        let memory = ResetCreditsMemory()
        let provider = CodexPlanProvider(root: { root }, liveUsage: { await live.next() }, resetCreditsMemory: memory)
        let first = try await provider.fetch(Credentials(values: [:]), now: now, timeZone: utc).get()
        try checkEqual(first.quota?.resetCredits?.available, 2)
        let second = try await provider.fetch(Credentials(values: [:]), now: now.addingTimeInterval(60), timeZone: utc).get()
        try checkEqual(second.quota?.windows.first?.usedPercent, 35)
        try checkEqual(second.quota?.resetCredits?.available, 2)
    }
    testAsync("codexRecreatedProviderUsesMemoryAndLoaderTakesPriority") {
        let root = try tmp()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSession(root: root, day: "2026/10/15", name: "a.jsonl", lines: [codexLine()], mtime: now)
        let memory = ResetCreditsMemory()
        let live = CodexPlanProvider(root: { root }, liveUsage: {
            var q = Quota(plan: "plus", windows: [], observedAt: now)
            q.resetCredits = ResetCredits(available: 2, expiresAt: nil)
            return q
        }, resetCreditsMemory: memory)
        _ = try await live.fetch(Credentials(values: [:]), now: now, timeZone: utc).get()
        let fallback = CodexPlanProvider(root: root, resetCredits: { nil }, resetCreditsMemory: memory)
        let recalled = try await fallback.fetch(Credentials(values: [:]), now: now, timeZone: utc).get()
        try checkEqual(recalled.quota?.resetCredits?.available, 2)
        let override = CodexPlanProvider(root: { root }, resetCredits: { ResetCredits(available: 0, expiresAt: nil) }, resetCreditsMemory: memory)
        let loaded = try await override.fetch(Credentials(values: [:]), now: now, timeZone: utc).get()
        try checkEqual(loaded.quota?.resetCredits?.available, 0)
        let expired = try await fallback.fetch(Credentials(values: [:]), now: now.addingTimeInterval(86400), timeZone: utc).get()
        try checkEqual(expired.quota?.resetCredits, nil)
    }
    testAsync("codexChoosesNewestObservationAcrossSessions") {
        let root = try tmp()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSession(root: root, day: "2026/10/15", name: "a.jsonl",
                         lines: [codexLine(used: 10, stamp: "2026-10-14T22:00:00Z"), "{}"], mtime: now)
        try writeSession(root: root, day: "2026/10/15", name: "b.jsonl",
                         lines: [codexLine(used: 90, stamp: "2026-10-14T21:00:00Z"),
                                 codexLine(used: 42, stamp: "2026-10-14T23:00:00Z")], mtime: now.addingTimeInterval(-60))
        guard case .success(let s) = await fetch(root) else { throw TestFailure(description: "expected quota") }
        try checkEqual(s.quota?.windows.first?.usedPercent, 42)
    }
    testAsync("codexReadsResumedSessionInOldDirectory") {
        let root = try tmp()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSession(root: root, day: "2026/10/01", name: "resumed.jsonl", lines: [codexLine(used: 42)], mtime: now)
        guard case .success(let s) = await fetch(root) else { throw TestFailure(description: "expected quota") }
        try checkEqual(s.quota?.windows.first?.usedPercent, 42)
    }
    testAsync("codexSchemaFailureAfterValidCandidateStillFails") {
        let root = try tmp()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSession(root: root, day: "2026/10/15", name: "a.jsonl", lines: [codexLine()], mtime: now)
        try writeSession(root: root, day: "2026/10/15", name: "b.jsonl",
                         lines: [codexLine(usedKey: "usedPercent")], mtime: now.addingTimeInterval(-60))
        guard case .failure(.schemaChanged) = await fetch(root) else { throw TestFailure(description: "expected schemaChanged") }
    }
    testAsync("codexReadsLatestCodexLine") {
        let root = try tmp()
        try writeSession(root: root, day: "2026/10/15", name: "a.jsonl",
                         lines: [codexLine(used: 10, weeklyUsed: 90, stamp: "2026-10-14T23:00:00.000Z"), codexLine(), premiumLine], mtime: now)
        guard case .success(let s) = await fetch(root), let q = s.quota else { throw TestFailure(description: "no quota") }
        try checkEqual(q.windows.map(\.kind), [.session, .weekly])
        try checkEqual(q.windows.map(\.usedPercent), [35, 100])
        try checkEqual(q.plan, "plus")
        try checkEqual(q.observedAt, ISO8601DateFormatter.fractional(ts))
        try checkEqual(q.windows[0].resetsAt, Date(timeIntervalSince1970: 1792041780))
        try checkEqual(s.source, .quota)
        try checkEqual(s.fetchedAt, now)
        try checkEqual(s.credential, .ok)
        try check(s.balance == nil && s.today == nil && s.month == nil && s.quotaNote == nil)
    }
    testAsync("codexSkipsPremiumAcrossFiles") {
        let root = try tmp()
        try writeSession(root: root, day: "2026/10/15", name: "new.jsonl", lines: [premiumLine], mtime: now)
        try writeSession(root: root, day: "2026/10/14", name: "old.jsonl", lines: [codexLine(used: 22)], mtime: now.addingTimeInterval(-86400))
        guard case .success(let s) = await fetch(root), let q = s.quota else { throw TestFailure(description: "no quota") }
        try checkEqual(q.windows[0].usedPercent, 22)
    }
    testAsync("codexTruncatedHeadLine") {
        let root = try tmp()
        let junk = String(repeating: "x", count: 300 * 1024)
        try writeSession(root: root, day: "2026/10/15", name: "big.jsonl", lines: [junk, codexLine(used: 41)], mtime: now)
        guard case .success(let s) = await fetch(root), let q = s.quota else { throw TestFailure(description: "no quota") }
        try checkEqual(q.windows[0].usedPercent, 41)

        // 第 256 KB 的起点恰好切在唯一一条 codex 行中间：半行被丢掉，不是 schemaChanged
        let root2 = try tmp()
        let line = codexLine()
        let L = line.utf8.count
        let fillerLen = Int(CodexPlanProvider.tailBytes) + L / 2 - L - 1     // 含换行共这么多字节
        let filler = String(repeating: "y", count: fillerLen - 1)
        let f = try writeSession(root: root2, day: "2026/10/15", name: "cut.jsonl", lines: [line, filler], mtime: now)
        let size = (try FileManager.default.attributesOfItem(atPath: f.path)[.size] as? NSNumber)?.intValue ?? 0
        try checkEqual(size - Int(CodexPlanProvider.tailBytes), L / 2)
        guard case .success(let s2) = await fetch(root2) else { throw TestFailure(description: "should succeed") }
        try check(s2.quota == nil)
        try checkEqual(s2.quotaNote, "还没有额度数据")

        // 第 256 KB 的起点恰好落在半行里一条完整记录的「{」上：这半截本身是合法的 codex 行，
        // 但整行没读全，必须丢掉（漏了 dropFirst 会读成已用 99%）
        let root3 = try tmp()
        let rest = String(codexLine(used: 99).dropFirst())
        let padLen = Int(CodexPlanProvider.tailBytes) - 1 - "{\"pad\":\"\",".utf8.count - rest.utf8.count
        let inner = "{\"pad\":\"" + String(repeating: "z", count: padLen) + "\"," + rest
        try checkEqual(inner.utf8.count + 1, Int(CodexPlanProvider.tailBytes))
        let head = String(repeating: "y", count: 100)
        let f3 = try writeSession(root: root3, day: "2026/10/15", name: "cut2.jsonl", lines: [head + inner], mtime: now)
        let size3 = (try FileManager.default.attributesOfItem(atPath: f3.path)[.size] as? NSNumber)?.intValue ?? 0
        try checkEqual(size3 - Int(CodexPlanProvider.tailBytes), head.utf8.count)
        guard case .success(.some(let whole)) = CodexPlanProvider.parseRateLimitLine(Data(inner.utf8)) else {
            throw TestFailure(description: "fragment should parse on its own")
        }
        try checkEqual(whole.windows[0].usedPercent, 99)
        guard case .success(let s3) = await fetch(root3) else { throw TestFailure(description: "should succeed") }
        try check(s3.quota == nil)
        try checkEqual(s3.quotaNote, "还没有额度数据")
    }
    testAsync("codexMissingSecondary") {
        let root = try tmp()
        try writeSession(root: root, day: "2026/10/15", name: "a.jsonl", lines: [codexLine(weeklyUsed: nil)], mtime: now)
        guard case .success(let s) = await fetch(root), let q = s.quota else { throw TestFailure(description: "no quota") }
        try checkEqual(q.windows.count, 1)
        try checkEqual(q.windows[0].kind, .session)
    }
    testAsync("codexWindowAlreadyReset") {
        let root = try tmp()
        try writeSession(root: root, day: "2026/10/15", name: "a.jsonl",
                         lines: [codexLine(used: 90, weeklyUsed: 80, resets: 1792022399)], mtime: now)
        guard case .success(let s) = await fetch(root), let q = s.quota else { throw TestFailure(description: "no quota") }
        // 5 小时窗口已重置按 0%，周窗口仍是 80% → 最紧的是周窗口
        try checkEqual(q.windows[0].effectiveUsed(at: now), 0)
        try checkEqual(q.remainingPercent(at: now), 20)
        let only = Quota(plan: nil, windows: [q.windows[0]], observedAt: now)
        try checkEqual(only.remainingPercent(at: now), 100)
    }
    testAsync("codexRenamedFieldIsSchemaChanged") {
        let root = try tmp()
        try writeSession(root: root, day: "2026/10/15", name: "a.jsonl", lines: [codexLine(usedKey: "usedPercent")], mtime: now)
        let r = await fetch(root)
        guard case .failure(let e) = r else { throw TestFailure(description: "expected failure") }
        try checkEqual(e, .schemaChanged("Codex 日志格式变了，等待 Token Bar 更新"))
    }
    testAsync("codexNoRootHasSetupNote") {
        let s = try await fetch(try tmp().appendingPathComponent("nope")).get()
        try check(s.quota == nil)
        try checkEqual(s.quotaNote, "没找到 Codex 的使用记录：装好并登录 Codex、用一次后再看")
    }
    testAsync("codexNoRecentLinesHasNote") {
        let root = try tmp()
        try writeSession(root: root, day: "2026/10/07", name: "old.jsonl", lines: [codexLine()], mtime: now.addingTimeInterval(-8 * 86400))
        guard case .success(let s) = await fetch(root) else { throw TestFailure(description: "should succeed") }
        try check(s.quota == nil)
        try checkEqual(s.quotaNote, "还没有额度数据")
    }
    /// 把文件设成不可读，返回恢复权限的闭包（测试结束前调用，免得临时目录删不掉）
    func lock(_ f: URL) throws -> () -> Void {
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: f.path)
        return { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.path) }
    }
    testAsync("codexIgnoresAuthJson") {
        // 不可读的 auth.json 放在 sessions 根目录和日期目录里（遍历一定会经过）：照样取到额度、不报「读不到」
        let root = try tmp()
        let day = try writeSession(root: root, day: "2026/10/15", name: "a.jsonl", lines: [codexLine()], mtime: now)
            .deletingLastPathComponent()
        var unlocks: [() -> Void] = []
        defer { unlocks.forEach { $0() } }
        for dir in [root, day] {
            let auth = dir.appendingPathComponent("auth.json")
            try Data("{\"secret\":1}".utf8).write(to: auth)
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: auth.path)
            unlocks.append(try lock(auth))
        }
        guard case .success(let s) = await fetch(root), s.quota != nil else { throw TestFailure(description: "should succeed") }
        // 代码里（注释除外）不出现 auth.json
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Core/CodexPlanProvider.swift")
        let code = try String(contentsOf: src, encoding: .utf8).split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        try check(!code.contains { $0.contains("auth.json") })
    }
    // 已知小问题 Task 3：某个 jsonl 读不出来时继续试下一个文件
    testAsync("codexUnreadableNewestFallsBackToOlder") {
        let root = try tmp()
        let bad = try writeSession(root: root, day: "2026/10/15", name: "new.jsonl", lines: [codexLine(used: 50)], mtime: now)
        try writeSession(root: root, day: "2026/10/14", name: "old.jsonl", lines: [codexLine(used: 22)], mtime: now.addingTimeInterval(-3600))
        let unlock = try lock(bad)
        defer { unlock() }
        guard case .success(let s) = await fetch(root), let q = s.quota else { throw TestFailure(description: "should fall back to older file") }
        try checkEqual(q.windows[0].usedPercent, 22)
    }
    testAsync("codexOnlyFileUnreadableIsUnavailable") {
        let root = try tmp()
        let bad = try writeSession(root: root, day: "2026/10/15", name: "a.jsonl", lines: [codexLine()], mtime: now)
        let unlock = try lock(bad)
        defer { unlock() }
        try checkEqual(await fetch(root), .failure(.unavailable("读不到 \(bad.path)")))
    }
    testAsync("codexUnreadablePlusNoDataIsUnavailable") {
        // 读失败的文件里可能有额度，不能说成「还没有额度数据」
        let root = try tmp()
        try writeSession(root: root, day: "2026/10/15", name: "new.jsonl", lines: [premiumLine], mtime: now)
        let bad = try writeSession(root: root, day: "2026/10/14", name: "old.jsonl", lines: [codexLine()], mtime: now.addingTimeInterval(-3600))
        let unlock = try lock(bad)
        defer { unlock() }
        try checkEqual(await fetch(root), .failure(.unavailable("读不到 \(bad.path)")))
    }
    test("quotaAlertDefaultsTo10") {
        try checkEqual(ProviderRegistry.meter(.codexPlan), .quota)
        let d = freshDefaults()
        try checkEqual(ProviderSettings.load(d).lowAlerts[.codexPlan], 10)
        var s = ProviderSettings.load(d)
        s.lowAlerts[.codexPlan] = nil
        s.save(d)
        try checkEqual(ProviderSettings.load(d).lowAlerts[.codexPlan], nil)
    }
}

private extension ISO8601DateFormatter {
    static func fractional(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}
