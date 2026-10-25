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
        await CodexPlanProvider(root: root).fetch(Credentials(values: [:]), now: now, timeZone: utc)
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
    testAsync("codexIgnoresAuthJson") {
        let base = try tmp()
        let root = base.appendingPathComponent("sessions")
        try writeSession(root: root, day: "2026/10/15", name: "a.jsonl", lines: [codexLine()], mtime: now)
        let auth = base.appendingPathComponent("auth.json")
        try Data("{\"secret\":1}".utf8).write(to: auth)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: auth.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path) }
        guard case .success(let s) = await fetch(root), s.quota != nil else { throw TestFailure(description: "should succeed") }
    }
    /// 把文件设成不可读，返回恢复权限的闭包（测试结束前调用，免得临时目录删不掉）
    func lock(_ f: URL) throws -> () -> Void {
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: f.path)
        return { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.path) }
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
