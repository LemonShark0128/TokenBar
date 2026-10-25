import Foundation

// 本机 Claude Code / Codex 会话日志 → 「本地日期 × 模型 → token」。样本全部是编出来的，只含用量字段
@MainActor
func registerLocalAgentUsageTests() {
    func unwrap<T>(_ v: T?) throws -> T {
        guard let v else { throw TestFailure(description: "应有值") }
        return v
    }
    let tz8 = TimeZone(secondsFromGMT: 8 * 3600)!
    let now = Date(timeIntervalSince1970: 1_792_022_400)   // 2026-10-15 08:00 +08:00（00:00 UTC）
    let fm = FileManager.default

    /// 名字里带空格的临时目录
    func tmp() throws -> URL {
        let u = fm.temporaryDirectory.appendingPathComponent("tb local usage \(UUID().uuidString)")
        try fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    @discardableResult
    func write(_ url: URL, _ lines: [String], mtime: Date = now) throws -> URL {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        return url
    }
    /// 编出来的 assistant 行：只有 LocalAgentUsage 关心的字段，外加一个不该被解码的 content
    func claudeLine(id: String = "msg_a", req: String = "req_1", model: String = "claude-opus-5-5",
                    input: Int = 10, output: Int = 20, create: Int = 30, read: Int = 40,
                    ts: String = "2026-10-14T23:00:00.000Z", type: String = "assistant") -> String {
        "{\"type\":\"\(type)\",\"timestamp\":\"\(ts)\",\"requestId\":\"\(req)\",\"message\":{\"id\":\"\(id)\",\"model\":\"\(model)\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"示例\"}],\"usage\":{\"input_tokens\":\(input),\"cache_creation_input_tokens\":\(create),\"cache_read_input_tokens\":\(read),\"output_tokens\":\(output),\"service_tier\":\"standard\"}}}"
    }
    func codexTurn(_ model: String, ts: String = "2026-10-14T23:00:00.000Z") -> String {
        "{\"timestamp\":\"\(ts)\",\"type\":\"turn_context\",\"payload\":{\"cwd\":\"/tmp/示例\",\"model\":\"\(model)\",\"summary\":\"auto\"}}"
    }
    func codexCount(_ total: Int?, ts: String = "2026-10-14T23:05:00.000Z") -> String {
        let info = total.map { "{\"total_token_usage\":{\"input_tokens\":1,\"cached_input_tokens\":0,\"output_tokens\":1,\"reasoning_output_tokens\":0,\"total_tokens\":\($0)},\"last_token_usage\":{\"total_tokens\":1},\"model_context_window\":272000}" } ?? "null"
        return "{\"timestamp\":\"\(ts)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":\(info),\"rate_limits\":null}}"
    }

    // ---------------------------------------------------------------- Claude Code

    test("localClaudeDedupesByMessageAndRequest") {
        let dir = try tmp()
        // 同一条回复写成三行（流式：output 逐步变大），只算最后一行；另一个 requestId 单独算
        try write(dir.appendingPathComponent("projects/my project/s1.jsonl"), [
            claudeLine(output: 1),
            claudeLine(output: 5),
            claudeLine(output: 20),
            claudeLine(id: "msg_a", req: "req_2", input: 1, output: 1, create: 1, read: 1),
        ])
        let r = LocalAgentUsage.claude(root: dir, now: now, timeZone: tz8)
        try checkEqual(r, ["2026-10-15": ["claude-opus-5-5": 100 + 4]])
    }
    test("localClaudeSkipsSyntheticUserAndBadLines") {
        let dir = try tmp()
        try write(dir.appendingPathComponent("projects/p/s.jsonl"), [
            claudeLine(id: "m1", model: "<synthetic>"),
            // user 行里文字恰好含 "usage"：粗筛能过，但 type 不是 assistant
            "{\"type\":\"user\",\"timestamp\":\"2026-10-14T23:00:00.000Z\",\"message\":{\"role\":\"user\",\"content\":\"\\\"usage\\\" 是什么\"}}",
            "{\"type\":\"assistant\",\"usage\" 坏行",
            "{\"type\":\"summary\",\"summary\":\"无关\"}",
            claudeLine(id: "m2", model: "claude-sonnet-5", input: 1, output: 2, create: 3, read: 4),
        ])
        let r = LocalAgentUsage.claude(root: dir, now: now, timeZone: tz8)
        try checkEqual(r, ["2026-10-15": ["claude-sonnet-5": 10]])
    }
    test("localClaudeBucketsByLocalDateAndWindow") {
        let dir = try tmp()
        try write(dir.appendingPathComponent("projects/p/s.jsonl"), [
            claudeLine(id: "a", ts: "2026-10-14T15:59:59.999Z"),     // +08:00 是 10-14 23:59
            claudeLine(id: "b", ts: "2026-10-14T16:00:00.000Z"),     // +08:00 是 10-15 00:00
            claudeLine(id: "c", ts: "2026-10-08T15:00:00.000Z"),     // 10-08 23:00：7 天窗口（10-09…10-15）之外
            claudeLine(id: "d", ts: "2026-10-09T00:00:00Z"),         // 不带毫秒也认
        ])
        let r = LocalAgentUsage.claude(root: dir, now: now, timeZone: tz8)
        try checkEqual(r, ["2026-10-14": ["claude-opus-5-5": 100], "2026-10-15": ["claude-opus-5-5": 100],
                           "2026-10-09": ["claude-opus-5-5": 100]])
        // 换成 UTC：同样的行落到不同日期
        let u = LocalAgentUsage.claude(root: dir, now: now, timeZone: TimeZone(identifier: "UTC")!)
        try checkEqual(u["2026-10-14"]?["claude-opus-5-5"], 200)
    }
    test("localClaudeReadsSubagentsAndSkipsOldFiles") {
        let dir = try tmp()
        try write(dir.appendingPathComponent("projects/p q/s1.jsonl"), [claudeLine(id: "main")])
        try write(dir.appendingPathComponent("projects/p q/s1/subagents/agent a.jsonl"),
                  [claudeLine(id: "sub", model: "claude-haiku-5", input: 1, output: 0, create: 0, read: 0)])
        // 8 天前修改的文件不读（哪怕里面的时间戳在窗口内）
        try write(dir.appendingPathComponent("projects/old/s.jsonl"), [claudeLine(id: "old")],
                  mtime: now.addingTimeInterval(-8 * 86400))
        // 不是 jsonl、或在别的层级的文件不读
        try write(dir.appendingPathComponent("projects/p q/notes.txt"), [claudeLine(id: "txt")])
        try write(dir.appendingPathComponent("settings.jsonl"), [claudeLine(id: "top")])
        let r = LocalAgentUsage.claude(root: dir, now: now, timeZone: tz8)
        try checkEqual(r, ["2026-10-15": ["claude-opus-5-5": 100, "claude-haiku-5": 1]])
    }
    test("localClaudeFileCountAndTailLimits") {
        let dir = try tmp()
        // 最多读 2 个文件：只读最近修改的两个
        for (i, back) in [0, 60, 120].enumerated() {
            try write(dir.appendingPathComponent("projects/p/s\(i).jsonl"),
                      [claudeLine(id: "m\(i)", input: 1, output: 0, create: 0, read: 0)], mtime: now.addingTimeInterval(TimeInterval(-back)))
        }
        let limits = LocalAgentUsage.Limits(maxFiles: 2, tailBytes: 1 << 20)
        try checkEqual(LocalAgentUsage.claude(root: dir, now: now, timeZone: tz8, limits: limits),
                       ["2026-10-15": ["claude-opus-5-5": 2]])
        // 只读末尾 N 字节：起点切在一行中间时丢掉残行，不报错也不误算
        let dir2 = try tmp()
        let keep = claudeLine(id: "tail", input: 7, output: 0, create: 0, read: 0)
        let cut = claudeLine(id: "cut", input: 1000, output: 0, create: 0, read: 0)
        try write(dir2.appendingPathComponent("projects/p/big.jsonl"), [cut, keep])
        let small = LocalAgentUsage.Limits(maxFiles: 400, tailBytes: UInt64(keep.utf8.count + 1 + cut.utf8.count / 2))
        try checkEqual(LocalAgentUsage.claude(root: dir2, now: now, timeZone: tz8, limits: small),
                       ["2026-10-15": ["claude-opus-5-5": 7]])
    }
    test("localClaudeDefaultsAndMissingRoot") {
        try checkEqual(LocalAgentUsage.Limits.standard.maxFiles, 400)
        try checkEqual(LocalAgentUsage.Limits.standard.tailBytes, 8 * 1024 * 1024)
        let r = LocalAgentUsage.claude(root: try tmp().appendingPathComponent("nope"), now: now, timeZone: tz8)
        try check(r.isEmpty)
    }

    // ---------------------------------------------------------------- Codex

    test("localCodexCountsTotalDeltasPerModel") {
        let root = try tmp().appendingPathComponent("sessions")
        try write(root.appendingPathComponent("2026/10/15/rollout a.jsonl"), [
            "{\"timestamp\":\"2026-10-14T22:59:00.000Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"x\"}}",
            codexTurn("gpt-5"),
            codexCount(nil),                       // info 为空：跳过
            codexCount(100),
            codexCount(100),                       // 重复的 token_count：增量 0
            codexCount(250),
            codexTurn("gpt-5-codex", ts: "2026-10-14T23:10:00.000Z"),
            codexCount(400, ts: "2026-10-14T23:11:00.000Z"),
        ])
        let r = LocalAgentUsage.codex(root: root, now: now, timeZone: tz8)
        try checkEqual(r, ["2026-10-15": ["gpt-5": 250, "gpt-5-codex": 150]])
    }
    test("localCodexSplitsDaysAndIgnoresOldFiles") {
        let root = try tmp().appendingPathComponent("sessions")
        // 会话跨日：增量按各自时间戳的本地日期记
        try write(root.appendingPathComponent("2026/10/14/r.jsonl"), [
            codexTurn("gpt-5", ts: "2026-10-14T10:00:00.000Z"),
            codexCount(40, ts: "2026-10-14T10:01:00.000Z"),     // +08:00 10-14 18:01
            codexCount(100, ts: "2026-10-14T16:30:00.000Z"),    // +08:00 10-15 00:30
        ])
        try write(root.appendingPathComponent("2026/10/01/old.jsonl"),
                  [codexTurn("gpt-4"), codexCount(999)], mtime: now.addingTimeInterval(-14 * 86400))
        let r = LocalAgentUsage.codex(root: root, now: now, timeZone: tz8)
        try checkEqual(r, ["2026-10-14": ["gpt-5": 40], "2026-10-15": ["gpt-5": 60]])
    }
    test("localCodexTruncatedFileUsesFirstTotalAsBaseline") {
        let root = try tmp().appendingPathComponent("sessions")
        let head = [codexTurn("gpt-5"), codexCount(5_000)]
        let tail = [codexCount(5_300), codexCount(5_350)]
        let tailText = tail.joined(separator: "\n") + "\n"
        try write(root.appendingPathComponent("2026/10/15/t.jsonl"), head + tail)
        // 只读到 tail 两行再多半行：模型名不知道（记成 codex），第一条 total 只当起点
        let limits = LocalAgentUsage.Limits(maxFiles: 400, tailBytes: UInt64(tailText.utf8.count + 10))
        let r = LocalAgentUsage.codex(root: root, now: now, timeZone: tz8, limits: limits)
        try checkEqual(r, ["2026-10-15": ["codex": 50]])
        // 读全文时从 0 起算
        try checkEqual(LocalAgentUsage.codex(root: root, now: now, timeZone: tz8), ["2026-10-15": ["gpt-5": 5_350]])
    }
    test("localCodexMissingRootIsEmpty") {
        try check(LocalAgentUsage.codex(root: try tmp().appendingPathComponent("nope"), now: now, timeZone: tz8).isEmpty)
    }

    // ---------------------------------------------------------------- 只读添加了的平台 + 节流

    test("localReadOnlyEnabledPlatforms") {
        let base = try tmp()
        let claudeDir = base.appendingPathComponent("claude dir")
        let codexDir = base.appendingPathComponent("codex dir/sessions")
        try write(claudeDir.appendingPathComponent("projects/p/s.jsonl"), [claudeLine()])
        try write(codexDir.appendingPathComponent("2026/10/15/r.jsonl"), [codexTurn("gpt-5"), codexCount(10)])
        let both = LocalAgentUsage.read(enabled: [.claudePlan, .codexPlan], claudeDir: claudeDir, codexSessions: codexDir,
                                        now: now, timeZone: tz8)
        try checkEqual(both[.claudePlan], ["2026-10-15": ["claude-opus-5-5": 100]])
        try checkEqual(both[.codexPlan], ["2026-10-15": ["gpt-5": 10]])
        let onlyCodex = LocalAgentUsage.read(enabled: [.codexPlan, .deepseek], claudeDir: claudeDir, codexSessions: codexDir,
                                             now: now, timeZone: tz8)
        try check(onlyCodex[.claudePlan] == nil)
        try checkEqual(Set(onlyCodex.keys), [.codexPlan])
        try check(LocalAgentUsage.read(enabled: [], claudeDir: claudeDir, codexSessions: codexDir, now: now, timeZone: tz8).isEmpty)
    }
    test("localUsageThrottleFiveMinutes") {
        var t = LocalUsageThrottle()
        try check(t.begin(enabled: [], now: now) == nil)                       // 没添加套餐平台：不读
        let g1 = try unwrap(t.begin(enabled: [.claudePlan], now: now))
        try check(t.finish(g1))
        try check(t.begin(enabled: [.claudePlan], now: now.addingTimeInterval(299)) == nil)
        let g2 = try unwrap(t.begin(enabled: [.claudePlan], now: now.addingTimeInterval(300)))
        try check(t.finish(g2))
        // 新添加了一个套餐平台：马上读，不等 5 分钟
        let g3 = try unwrap(t.begin(enabled: [.claudePlan, .codexPlan], now: now.addingTimeInterval(310)))
        try check(t.finish(g3))
        try check(t.begin(enabled: [.claudePlan, .codexPlan], now: now.addingTimeInterval(320)) == nil)
        try checkEqual(LocalUsageThrottle.minInterval, 300)
    }
    // 评审：读取还没结束时添加了平台，晚结束的旧读取不能把新结果盖掉；正在读时不按时间再开一次
    test("localUsageThrottleDropsStaleResult") {
        var t = LocalUsageThrottle()
        let old = try unwrap(t.begin(enabled: [.claudePlan], now: now))
        try check(t.begin(enabled: [.claudePlan], now: now.addingTimeInterval(400)) == nil, "正在读：不重复开始")
        let new = try unwrap(t.begin(enabled: [.claudePlan, .codexPlan], now: now.addingTimeInterval(10)))
        try check(t.finish(new), "新的结果要用")
        try check(!t.finish(old), "晚结束的旧结果丢掉")
        try check(t.begin(enabled: [.claudePlan, .codexPlan], now: now.addingTimeInterval(100)) == nil)
    }
}

// 本机日志缓存：按「路径 + 修改时间 + 大小」缓存每个文件的解析结果，没变的文件不再打开
@MainActor
func registerLocalUsageCacheTests() {
    let tz8 = TimeZone(secondsFromGMT: 8 * 3600)!
    let now = Date(timeIntervalSince1970: 1_792_022_400)   // 2026-10-15 08:00 +08:00
    let fm = FileManager.default
    func tmp() throws -> URL {
        let u = fm.temporaryDirectory.appendingPathComponent("tb local cache \(UUID().uuidString)")
        try fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    @discardableResult
    func write(_ url: URL, _ lines: [String], mtime: Date = now) throws -> URL {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        return url
    }
    func cl(_ id: String?, _ req: String? = "r", input: Int = 1, ts: String = "2026-10-14T23:00:00.000Z",
            model: String = "claude-opus-5-5") -> String {
        let idPart = id.map { "\"id\":\"\($0)\"," } ?? ""
        let reqPart = req.map { "\"requestId\":\"\($0)\"," } ?? ""
        return "{\"type\":\"assistant\",\"timestamp\":\"\(ts)\",\(reqPart)\"message\":{\(idPart)\"model\":\"\(model)\",\"content\":[{\"type\":\"text\",\"text\":\"示例\"}],\"usage\":{\"input_tokens\":\(input),\"output_tokens\":0}}}"
    }
    func cxTurn(_ model: String) -> String {
        "{\"timestamp\":\"2026-10-14T23:00:00.000Z\",\"type\":\"turn_context\",\"payload\":{\"model\":\"\(model)\"}}"
    }
    func cxCount(_ total: Int, ts: String = "2026-10-14T23:05:00.000Z") -> String {
        "{\"timestamp\":\"\(ts)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":\(total)}}}}"
    }
    func readBoth(_ base: URL, now: Date = now, tz: TimeZone = tz8, limits: LocalAgentUsage.Limits = .standard,
                  cache: LocalUsageCache?) -> [ProviderID: DailyModelTokens] {
        LocalAgentUsage.read(enabled: [.claudePlan, .codexPlan], claudeDir: base.appendingPathComponent("claude dir"),
                             codexSessions: base.appendingPathComponent("codex dir/sessions"), now: now, timeZone: tz,
                             limits: limits, cache: cache)
    }

    test("localCacheSkipsUnchangedFiles") {
        let base = try tmp()
        try write(base.appendingPathComponent("claude dir/projects/p/a.jsonl"), [cl("m1", input: 5)])
        try write(base.appendingPathComponent("claude dir/projects/p/b.jsonl"), [cl("m2", input: 7)])
        try write(base.appendingPathComponent("codex dir/sessions/2026/10/15/r.jsonl"), [cxTurn("gpt-5"), cxCount(10)])
        let cache = LocalUsageCache()
        let first = readBoth(base, cache: cache)
        try checkEqual(cache.parsedFileCount, 3)
        try checkEqual(cache.cachedFileCount, 3)
        let second = readBoth(base, cache: cache)
        try checkEqual(cache.parsedFileCount, 3)          // 都没变：一个也不重读
        try checkEqual(first, second)
        try checkEqual(second, readBoth(base, cache: nil))
    }
    test("localCacheRereadsOnlyChangedFile") {
        let base = try tmp()
        let a = base.appendingPathComponent("claude dir/projects/p/a.jsonl")
        try write(a, [cl("m1", input: 5)])
        try write(base.appendingPathComponent("claude dir/projects/p/b.jsonl"), [cl("m2", input: 7)])
        let r = base.appendingPathComponent("codex dir/sessions/2026/10/15/r.jsonl")
        try write(r, [cxTurn("gpt-5"), cxCount(10)])
        let cache = LocalUsageCache()
        _ = readBoth(base, cache: cache)
        try checkEqual(cache.parsedFileCount, 3)
        // 追加内容：大小和修改时间都变
        try write(a, [cl("m1", input: 5), cl("m3", input: 100)], mtime: now.addingTimeInterval(1))
        try write(r, [cxTurn("gpt-5"), cxCount(10), cxCount(30)], mtime: now.addingTimeInterval(1))
        let after = readBoth(base, now: now.addingTimeInterval(2), cache: cache)
        try checkEqual(cache.parsedFileCount, 5)
        try checkEqual(after[.claudePlan], ["2026-10-15": ["claude-opus-5-5": 112]])
        try checkEqual(after[.codexPlan], ["2026-10-15": ["gpt-5": 30]])
        // 只改修改时间（大小不变）也重读
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(5)], ofItemAtPath: a.path)
        _ = readBoth(base, now: now.addingTimeInterval(6), cache: cache)
        try checkEqual(cache.parsedFileCount, 6)
    }
    test("localCacheNextDayFiltersWindowButHits") {
        let base = try tmp()
        try write(base.appendingPathComponent("claude dir/projects/p/a.jsonl"), [
            cl("old", input: 3, ts: "2026-10-09T01:00:00.000Z"),    // +08:00 10-09
            cl("new", input: 4, ts: "2026-10-14T23:00:00.000Z"),    // +08:00 10-15
        ])
        try write(base.appendingPathComponent("codex dir/sessions/2026/10/15/r.jsonl"),
                  [cxTurn("gpt-5"), cxCount(10, ts: "2026-10-09T01:00:00.000Z"), cxCount(25)])
        let cache = LocalUsageCache()
        let d0 = readBoth(base, cache: cache)
        try checkEqual(d0[.claudePlan], ["2026-10-09": ["claude-opus-5-5": 3], "2026-10-15": ["claude-opus-5-5": 4]])
        try checkEqual(d0[.codexPlan], ["2026-10-09": ["gpt-5": 10], "2026-10-15": ["gpt-5": 15]])
        // 过了一天：10-09 出了窗口，文件没变不重读
        let next = now.addingTimeInterval(86400)
        let d1 = readBoth(base, now: next, cache: cache)
        try checkEqual(cache.parsedFileCount, 2)
        try checkEqual(d1[.claudePlan], ["2026-10-15": ["claude-opus-5-5": 4]])
        try checkEqual(d1[.codexPlan], ["2026-10-15": ["gpt-5": 15]])
        try checkEqual(d1, readBoth(base, now: next, cache: nil))
    }
    test("localCacheKeepsOnlyWindowEntries") {
        let base = try tmp()
        try write(base.appendingPathComponent("claude dir/projects/p/a.jsonl"), [
            cl("old", input: 3, ts: "2026-10-01T01:00:00.000Z"),    // 窗口外
            cl("edge", input: 5, ts: "2026-10-08T16:00:00.000Z"),   // +08:00 10-09：窗口第一天
            cl("new", input: 4),
        ])
        try write(base.appendingPathComponent("codex dir/sessions/2026/10/15/r.jsonl"),
                  [cxTurn("gpt-5"), cxCount(10, ts: "2026-10-01T01:00:00.000Z"), cxCount(25)])
        let cache = LocalUsageCache()
        let got = readBoth(base, cache: cache)
        try checkEqual(cache.cachedEntryCount, 3)          // 窗口外的 Claude 一条、Codex 一段都不进缓存
        try checkEqual(got, readBoth(base, cache: nil))
        try checkEqual(got[.codexPlan], ["2026-10-15": ["gpt-5": 15]])   // 增量仍按全文算，丢的只是窗口外那段
    }
    test("localCacheNextDayPrunesWithoutReread") {
        let base = try tmp()
        try write(base.appendingPathComponent("claude dir/projects/p/a.jsonl"), [
            cl("old", input: 3, ts: "2026-10-09T01:00:00.000Z"),
            cl("new", input: 4),
        ])
        try write(base.appendingPathComponent("codex dir/sessions/2026/10/15/r.jsonl"),
                  [cxTurn("gpt-5"), cxCount(10, ts: "2026-10-09T01:00:00.000Z"), cxCount(25)])
        let cache = LocalUsageCache()
        _ = readBoth(base, cache: cache)
        try checkEqual(cache.cachedEntryCount, 4)
        let next = now.addingTimeInterval(86400)
        _ = readBoth(base, now: next, cache: cache)
        try checkEqual(cache.parsedFileCount, 2)           // 文件没变：不重读
        try checkEqual(cache.cachedEntryCount, 2)          // 10-09 出了窗口：从缓存里丢掉
        // 时钟回拨，窗口往前移：已丢的条目要找回来，整个缓存作废重读
        let back = readBoth(base, now: now, cache: cache)
        try checkEqual(cache.parsedFileCount, 4)
        try checkEqual(back, readBoth(base, now: now, cache: nil))
        try checkEqual(back[.claudePlan], ["2026-10-09": ["claude-opus-5-5": 3], "2026-10-15": ["claude-opus-5-5": 4]])
    }
    test("localCacheTimeZoneOrLimitsChangeInvalidates") {
        let base = try tmp()
        try write(base.appendingPathComponent("claude dir/projects/p/a.jsonl"), [
            cl("a", input: 1, ts: "2026-10-14T15:59:59.000Z"),
            cl("b", input: 2, ts: "2026-10-14T16:00:00.000Z"),
        ])
        try write(base.appendingPathComponent("codex dir/sessions/2026/10/15/r.jsonl"), [cxTurn("gpt-5"), cxCount(10)])
        let cache = LocalUsageCache()
        _ = readBoth(base, cache: cache)
        try checkEqual(cache.parsedFileCount, 2)
        let utc = TimeZone(identifier: "UTC")!
        let u = readBoth(base, tz: utc, cache: cache)
        try checkEqual(cache.parsedFileCount, 4)           // 时区变了：全部重读
        try checkEqual(u[.claudePlan], ["2026-10-14": ["claude-opus-5-5": 3]])
        try checkEqual(u, readBoth(base, tz: utc, cache: nil))
        _ = readBoth(base, tz: utc, cache: cache)
        try checkEqual(cache.parsedFileCount, 4)
        _ = readBoth(base, tz: utc, limits: .init(maxFiles: 10, tailBytes: 1 << 20), cache: cache)
        try checkEqual(cache.parsedFileCount, 6)           // Limits 变了：全部重读
    }
    test("localCacheDropsUnlistedFiles") {
        let base = try tmp()
        let a = try write(base.appendingPathComponent("claude dir/projects/p/a.jsonl"), [cl("m1")])
        try write(base.appendingPathComponent("claude dir/projects/p/b.jsonl"), [cl("m2")], mtime: now.addingTimeInterval(-10))
        let r = try write(base.appendingPathComponent("codex dir/sessions/2026/10/15/r.jsonl"), [cxTurn("gpt-5"), cxCount(10)])
        let cache = LocalUsageCache()
        _ = readBoth(base, cache: cache)
        try checkEqual(cache.cachedFileCount, 3)
        try fm.removeItem(at: a)
        try fm.removeItem(at: r)
        let after = readBoth(base, cache: cache)
        try checkEqual(cache.cachedFileCount, 1)
        try checkEqual(after[.claudePlan], ["2026-10-15": ["claude-opus-5-5": 1]])
        try checkEqual(after[.codexPlan], [:])
        // 超出 maxFiles 的也清掉
        try write(base.appendingPathComponent("claude dir/projects/p/c.jsonl"), [cl("m3")])
        let lim = LocalAgentUsage.Limits(maxFiles: 1, tailBytes: LocalAgentUsage.Limits.standard.tailBytes)
        _ = readBoth(base, limits: lim, cache: cache)
        try checkEqual(cache.cachedFileCount, 1)
        // 关掉某个平台：它的缓存也清掉
        _ = readBoth(base, cache: cache)
        try checkEqual(cache.cachedFileCount, 2)
        _ = LocalAgentUsage.read(enabled: [.codexPlan], claudeDir: base.appendingPathComponent("claude dir"),
                                 codexSessions: base.appendingPathComponent("codex dir/sessions"), now: now, timeZone: tz8, cache: cache)
        try checkEqual(cache.cachedFileCount, 0)
    }
    test("localCacheMatchesUncachedDedupeAndTruncation") {
        let base = try tmp()
        // Claude：同一 id+req 跨文件出现，取 recent() 顺序里最后一行（b 比 a 旧，所以 a 先读、b 后读）
        try write(base.appendingPathComponent("claude dir/projects/p/a.jsonl"), [
            cl("dup", input: 50), cl(nil, nil, input: 2), cl("zero", input: 9),
            cl("syn", input: 9, model: "<synthetic>"),
        ])
        try write(base.appendingPathComponent("claude dir/projects/q/s1/subagents/b.jsonl"), [
            cl("dup", input: 70, ts: "2026-10-13T01:00:00.000Z"), cl(nil, nil, input: 3), cl("zero", input: 0),
            cl("old", input: 9, ts: "2026-10-01T01:00:00.000Z"),
        ], mtime: now.addingTimeInterval(-60))
        // Codex：截断（第一条只当起点、不知道模型记 codex）+ 累计值变小当作从 0 重来
        let tail = [cxCount(5_300), cxCount(5_350), cxCount(20), cxCount(45)]
        // 中间一行很长的无关行：截断点落在它里面，Claude 的小文件不受 tailBytes 影响
        let filler = "{\"type\":\"session_meta\",\"payload\":{\"pad\":\"" + String(repeating: "x", count: 8_000) + "\"}}"
        try write(base.appendingPathComponent("codex dir/sessions/2026/10/15/t.jsonl"), [cxTurn("gpt-5"), cxCount(5_000), filler] + tail)
        try write(base.appendingPathComponent("codex dir/sessions/2026/10/15/u.jsonl"), [cxTurn("gpt-5-codex"), cxCount(7)])
        let limits = LocalAgentUsage.Limits(maxFiles: 400, tailBytes: 4_000)
        let plain = readBoth(base, limits: limits, cache: nil)
        try checkEqual(plain[.claudePlan], ["2026-10-13": ["claude-opus-5-5": 70], "2026-10-15": ["claude-opus-5-5": 5]])
        try checkEqual(plain[.codexPlan], ["2026-10-15": ["codex": 50 + 45, "gpt-5-codex": 7]])
        let cache = LocalUsageCache()
        try checkEqual(readBoth(base, limits: limits, cache: cache), plain)
        try checkEqual(readBoth(base, limits: limits, cache: cache), plain)
        try checkEqual(cache.parsedFileCount, 4)
    }
}
