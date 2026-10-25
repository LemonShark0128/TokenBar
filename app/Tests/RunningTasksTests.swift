import Foundation

// 正在跑的任务：本机 Claude Code / Codex 会话日志 → 未收轮的轮次。样本全部是编出来的，只含结构字段
@MainActor
func registerRunningTasksTests() {
    let now = Date(timeIntervalSince1970: 1_792_022_400)   // 2026-10-15T00:00:00Z
    let fm = FileManager.default
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    /// 相对 now 的秒数 → ISO 时间戳
    func ts(_ back: TimeInterval) -> String { iso.string(from: now.addingTimeInterval(-back)) }
    /// 名字里带空格的临时目录，下面建好 claude / codex 两个根
    func roots() throws -> (claude: URL, codex: URL) {
        let u = fm.temporaryDirectory.appendingPathComponent("tb running tasks \(UUID().uuidString)")
        try fm.createDirectory(at: u, withIntermediateDirectories: true)
        return (u.appendingPathComponent(".claude"), u.appendingPathComponent(".codex/sessions"))
    }
    func write(_ url: URL, _ lines: [String], mtime: Date = now) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }
    func claudeFile(_ r: (claude: URL, codex: URL), _ name: String = "s1") -> URL {
        r.claude.appendingPathComponent("projects/-Users-x-proj/\(name).jsonl")
    }
    func codexFile(_ r: (claude: URL, codex: URL), _ name: String = "rollout-1") -> URL {
        r.codex.appendingPathComponent("2026/10/14/\(name).jsonl")
    }
    func scan(_ r: (claude: URL, codex: URL), enabled: Set<ProviderID> = [.claudePlan, .codexPlan]) -> [RunningTask] {
        RunningTasks.scan(enabled: enabled, claudeDir: r.claude, codexSessions: r.codex, now: now)
    }

    // ---------------------------------------------------------------- 样本行
    func prompt(_ back: TimeInterval, text: String = "示例提示", cwd: String? = "/Users/x/token-dashboard",
                sidechain: Bool = false, array: Bool = false) -> String {
        let content = array ? "[{\"type\":\"text\",\"text\":\"\(text)\"}]" : "\"\(text)\""
        let c = cwd.map { ",\"cwd\":\"\($0)\"" } ?? ""
        return "{\"type\":\"user\",\"isSidechain\":\(sidechain),\"timestamp\":\"\(ts(back))\",\"sessionId\":\"s\"\(c),\"message\":{\"role\":\"user\",\"content\":\(content)}}"
    }
    func toolResult(_ back: TimeInterval) -> String {
        "{\"type\":\"user\",\"isSidechain\":false,\"timestamp\":\"\(ts(back))\",\"cwd\":\"/Users/x/token-dashboard\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"t1\",\"content\":\"示例\"}]}}"
    }
    func reply(_ back: TimeInterval, stop: String? = "tool_use", id: String? = nil, model: String = "claude-opus-4-7",
               usage: (Int, Int, Int, Int) = (10, 20, 30, 40), sidechain: Bool = false) -> String {
        let s = stop.map { "\"\($0)\"" } ?? "null"
        let mid = id ?? UUID().uuidString
        return "{\"type\":\"assistant\",\"isSidechain\":\(sidechain),\"timestamp\":\"\(ts(back))\",\"cwd\":\"/Users/x/token-dashboard\",\"requestId\":\"req_\(mid)\",\"message\":{\"id\":\"\(mid)\",\"model\":\"\(model)\",\"role\":\"assistant\",\"stop_reason\":\(s),\"content\":[{\"type\":\"text\",\"text\":\"示例\"}],\"usage\":{\"input_tokens\":\(usage.0),\"output_tokens\":\(usage.1),\"cache_creation_input_tokens\":\(usage.2),\"cache_read_input_tokens\":\(usage.3)}}}"
    }
    func codexContext(_ back: TimeInterval, model: String = "gpt-5.5", cwd: String = "/w/demo-app") -> String {
        "{\"timestamp\":\"\(ts(back))\",\"type\":\"turn_context\",\"payload\":{\"cwd\":\"\(cwd)\",\"model\":\"\(model)\",\"summary\":\"auto\"}}"
    }
    func codexEvent(_ back: TimeInterval, _ type: String) -> String {
        "{\"timestamp\":\"\(ts(back))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"\(type)\",\"turn_id\":\"t\"}}"
    }
    func codexCount(_ back: TimeInterval, _ total: Int) -> String {
        "{\"timestamp\":\"\(ts(back))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":1,\"output_tokens\":\(total),\"total_tokens\":\(total * 10)},\"last_token_usage\":{\"total_tokens\":1}},\"rate_limits\":null}}"
    }
    func task(_ provider: ProviderID = .claudePlan, key: String = "k", project: String = "token-dashboard",
              model: String? = "opus 4.7", started: TimeInterval = 724, last: TimeInterval = 10, tokens: Int = 18_234) -> RunningTask {
        RunningTask(provider: provider, sessionKey: key, project: project, model: model,
                    startedAt: now.addingTimeInterval(-started), lastActivity: now.addingTimeInterval(-last), tokens: tokens)
    }

    // 每 10 秒扫一次：文件修改时间和大小都没变就用上次的结果，不再读文件；变了才重读，没再列到的从缓存里清掉
    test("RunningTasks cacheSkipsUnchangedFiles") {
        let r = try roots()
        let f = claudeFile(r), g = codexFile(r)
        try write(f, [prompt(120), reply(60)], mtime: now.addingTimeInterval(-60))
        try write(g, [], mtime: now.addingTimeInterval(-60))
        let cache = RunningTasksCache()
        func scanCached() -> [RunningTask] {
            RunningTasks.scan(enabled: [.claudePlan, .codexPlan], claudeDir: r.claude, codexSessions: r.codex, now: now, cache: cache)
        }
        let first = scanCached()
        try checkEqual(first.count, 1)
        try checkEqual(cache.parsedFileCount, 2)
        try checkEqual(scanCached(), first)
        try checkEqual(cache.parsedFileCount, 2)     // 没变的文件不再读
        try write(f, [prompt(120), reply(60), reply(30, stop: "end_turn")], mtime: now.addingTimeInterval(-30))
        try checkEqual(scanCached(), [])     // 收轮后不再算在跑
        try checkEqual(cache.parsedFileCount, 3)     // 只重读变了的那个
        try fm.removeItem(at: g)
        _ = scanCached()
        try checkEqual(cache.cachedFileCount, 1)
    }
    test("RunningTasks resumedOldDirectoryIsRunning") {
        let r = try roots()
        defer { try? fm.removeItem(at: r.codex.deletingLastPathComponent().deletingLastPathComponent()) }
        try write(r.codex.appendingPathComponent("2026/10/01/resumed.jsonl"),
                  [codexContext(120), codexEvent(60, "task_started")])
        try checkEqual(scan(r, enabled: [.codexPlan]).map(\.provider), [.codexPlan])
    }

    // ---------------------------------------------------------------- Claude Code

    test("RunningTasks claudeOpenTurn：提示后只有 tool_use 回复 → 进行中") {
        let r = try roots()
        try write(claudeFile(r), [prompt(600), reply(60)])
        let t = scan(r)
        try checkEqual(t.count, 1)
        try checkEqual(t[0].provider, .claudePlan)
        try checkEqual(t[0].project, "token-dashboard")
        try checkEqual(t[0].model, "opus 4.7")
        try checkEqual(t[0].startedAt, now.addingTimeInterval(-600))
        try checkEqual(t[0].lastActivity, now.addingTimeInterval(-60))
        try checkEqual(t[0].tokens, 20)
    }

    test("RunningTasks claudeEndTurnCloses：end_turn / stop_sequence / max_tokens / refusal 收轮") {
        for stop in ["end_turn", "stop_sequence", "max_tokens", "refusal"] {
            let r = try roots()
            try write(claudeFile(r), [prompt(600), reply(60), reply(30, stop: stop)])
            try checkEqual(scan(r).count, 0)
        }
    }

    test("RunningTasks claudeInterruptCloses：打断 / 本地命令前缀收轮") {
        let r1 = try roots()
        try write(claudeFile(r1), [prompt(600), reply(60), prompt(30, text: "[Request interrupted by user]")])
        try checkEqual(scan(r1).count, 0)
        let r2 = try roots()
        try write(claudeFile(r2), [prompt(600), reply(60), prompt(30, text: "<local-command-stdout>x", array: true)])
        try checkEqual(scan(r2).count, 0)
    }

    test("RunningTasks claudeToolResultKeepsStart：工具结果不开新轮") {
        let r = try roots()
        try write(claudeFile(r), [prompt(600), reply(500), toolResult(400), reply(30)])
        let t = scan(r)
        try checkEqual(t.count, 1)
        try checkEqual(t[0].startedAt, now.addingTimeInterval(-600))
    }

    test("RunningTasks claudeQueuedPromptKeepsStart：轮次中的新提示不重置开始时间") {
        let r = try roots()
        try write(claudeFile(r), [prompt(600), reply(500), prompt(300, text: "再加一点"), reply(10)])
        let t = scan(r)
        try checkEqual(t.count, 1)
        try checkEqual(t[0].startedAt, now.addingTimeInterval(-600))
    }

    test("RunningTasks claudeSidechainNeitherOpensNorCloses：子代理不开不收，但输出 token 计入本轮") {
        let r1 = try roots()
        try write(claudeFile(r1), [prompt(600, sidechain: true), reply(60, stop: "end_turn", sidechain: true)])
        try checkEqual(scan(r1).count, 0)
        let r2 = try roots()
        try write(claudeFile(r2), [prompt(600), reply(300, stop: "end_turn", usage: (10, 10, 10, 20), sidechain: true), reply(60)])
        let t = scan(r2)
        try checkEqual(t.count, 1)
        try checkEqual(t[0].tokens, 30)
    }

    test("RunningTasks claudeDedupByMessageId：同一 message.id 取最后一行") {
        let r = try roots()
        try write(claudeFile(r), [prompt(600), reply(100, id: "m1"), reply(60, id: "m1", usage: (10, 90, 30, 100))])
        try checkEqual(scan(r).first?.tokens, 90)
    }

    test("RunningTasks subdirKeepsProject：中途进了子目录，项目名仍是最短的上级目录") {
        let r = try roots()
        let sub = reply(60).replacingOccurrences(of: "/Users/x/token-dashboard\"", with: "/Users/x/token-dashboard/app\"")
        try write(claudeFile(r), [prompt(600), reply(300), sub])
        try checkEqual(scan(r).first?.project, "token-dashboard")
        // 上一轮就进了子目录，这一轮开头已经在子目录里
        let r3 = try roots()
        try write(claudeFile(r3), [prompt(900), reply(800), sub.replacingOccurrences(of: "\"tool_use\"", with: "\"end_turn\""),
                                   prompt(100, cwd: "/Users/x/token-dashboard/app"), sub])
        try checkEqual(scan(r3).first?.project, "token-dashboard")
        let r2 = try roots()
        let other = reply(60).replacingOccurrences(of: "/Users/x/token-dashboard\"", with: "/Users/x/notes\"")
        try write(claudeFile(r2), [prompt(600), reply(300), other])
        try checkEqual(scan(r2).first?.project, "notes")
    }

    test("RunningTasks noProjectName：没有 cwd 写「未知项目」") {
        let r = try roots()
        let noCwd = reply(60).replacingOccurrences(of: ",\"cwd\":\"/Users/x/token-dashboard\"", with: "")
        try write(claudeFile(r), [prompt(600, cwd: nil), noCwd])
        try checkEqual(scan(r).first?.project, "未知项目")
    }

    // ---------------------------------------------------------------- Codex

    test("RunningTasks codexTurns：task_started 开轮，task_complete / turn_aborted 收轮") {
        let r = try roots()
        try write(codexFile(r), [codexContext(310), codexEvent(300, "task_started"), codexCount(100, 5000)])
        let t = scan(r)
        try checkEqual(t.count, 1)
        try checkEqual(t[0].provider, .codexPlan)
        try checkEqual(t[0].project, "demo-app")
        try checkEqual(t[0].model, "gpt-5.5")
        try checkEqual(t[0].tokens, 5000)
        try checkEqual(t[0].startedAt, now.addingTimeInterval(-300))
        for end in ["task_complete", "turn_aborted"] {
            let r2 = try roots()
            try write(codexFile(r2), [codexContext(310), codexEvent(300, "task_started"), codexCount(100, 5000), codexEvent(50, end)])
            try checkEqual(scan(r2).count, 0)
        }
    }

    test("RunningTasks codexSecondTurnTokensDelta：第二轮 token 从开轮前的累计值算差") {
        let r = try roots()
        try write(codexFile(r), [codexContext(900), codexCount(890, 1000), codexEvent(880, "task_started"), codexCount(870, 1200),
                                 codexEvent(860, "task_complete"), codexCount(850, 1200), codexEvent(60, "task_started"),
                                 codexCount(30, 4200)])
        let t = scan(r)
        try checkEqual(t.count, 1)
        try checkEqual(t[0].startedAt, now.addingTimeInterval(-60))
        try checkEqual(t[0].tokens, 3000)
    }

    // ---------------------------------------------------------------- 共同规则

    test("RunningTasks staleAndDrop：5 分钟停住，30 分钟不列") {
        try check(!RunningTaskText.isStale(task(last: 299), now: now))
        try checkEqual(RunningTaskText.clock(task(started: 724, last: 299), now: now), "12:04")
        try check(RunningTaskText.isStale(task(last: 420), now: now))
        try checkEqual(RunningTaskText.clock(task(last: 420), now: now), "停了 7 分钟")
        let r = try roots()
        try write(claudeFile(r), [prompt(2000), reply(1801)])
        try checkEqual(scan(r).count, 0)
    }

    test("RunningTasks oldLastActivityDropped：按行时间判断，不按文件修改时间") {
        let r = try roots()
        try write(claudeFile(r), [prompt(2000), reply(1900), "{\"type\":\"custom-title\",\"customTitle\":\"x\"}"])
        try checkEqual(scan(r).count, 0)
    }

    test("RunningTasks brokenLinesSkipped：坏行和末尾半行跳过") {
        let r = try roots()
        try write(claudeFile(r), [prompt(600), "{\"type\":\"assistant\",", reply(60), "{\"type\":\"assistant\",\"timestamp\":\"\(ts(5))\",\"message\":{\"usage\":{\"input_tok"])
        let t = scan(r)
        try checkEqual(t.count, 1)
        try checkEqual(t[0].tokens, 20)
    }

    test("RunningTasks onlyEnabledScanned：没添加的平台不扫") {
        let r = try roots()
        try write(claudeFile(r), [prompt(600), reply(60)])
        try write(codexFile(r), [codexContext(310), codexEvent(300, "task_started")])
        let t = scan(r, enabled: [.codexPlan])
        try checkEqual(t.map(\.provider), [.codexPlan])
        try checkEqual(scan(r, enabled: []).count, 0)
    }

    test("RunningTasks oldFilesIgnored：30 分钟前改过的文件不读") {
        let r = try roots()
        try write(claudeFile(r), [prompt(600), reply(60)], mtime: now.addingTimeInterval(-1900))
        try checkEqual(scan(r).count, 0)
    }

    test("RunningTasks sortAndVisible：按开始时间排，最多 3 个") {
        let r = try roots()
        try write(claudeFile(r, "s100"), [prompt(100), reply(50)])
        try write(claudeFile(r, "s200"), [prompt(200), reply(50)])
        try write(claudeFile(r, "b"), [prompt(400), reply(50)])
        try write(claudeFile(r, "a"), [prompt(400), reply(50)])
        let t = scan(r)
        try checkEqual(t.map { ($0.sessionKey as NSString).lastPathComponent }, ["a.jsonl", "b.jsonl", "s200.jsonl", "s100.jsonl"])
        let v = RunningTaskText.visible(t)
        try checkEqual(v.shown.count, 3)
        try checkEqual(v.more, 1)
        try checkEqual(RunningTaskText.moreLine(1), "还有 1 个")
        try checkEqual(RunningTaskText.header(count: 4), "当前 · 4")
        try checkEqual(RunningTaskText.visible(Array(t.prefix(2))).more, 0)
    }

    test("RunningTasks textFormats：计时、token、第二行、悬停提示、模型简写") {
        try checkEqual(RunningTaskText.clock(task(started: 724, last: 1), now: now), "12:04")
        try checkEqual(RunningTaskText.clock(task(started: 3724, last: 1), now: now), "1:02:04")
        try checkEqual(RunningTaskText.clock(task(started: 5, last: 1), now: now), "0:05")
        try checkEqual(RunningTaskText.tokens(0), "0")
        try checkEqual(RunningTaskText.tokens(999), "999")
        try checkEqual(RunningTaskText.tokens(1000), "1k")
        try checkEqual(RunningTaskText.tokens(18_234), "18.2k")
        try checkEqual(RunningTaskText.tokens(1_340_000), "1.3M")
        try checkEqual(RunningTaskText.detail(task()), "opus 4.7 · 已写 18.2k")
        try checkEqual(RunningTaskText.detail(task(model: nil, tokens: 0)), "已写 0")
        try checkEqual(RunningTaskText.tooltipLine(count: 0), nil)
        try checkEqual(RunningTaskText.tooltipLine(count: 2), "当前 2 个任务")
        try checkEqual(RunningTasks.shortModel("claude-opus-4-7"), "opus 4.7")
        try checkEqual(RunningTasks.shortModel("claude-sonnet-4-5-20250929"), "sonnet 4.5")
        try checkEqual(RunningTasks.shortModel("claude-haiku-4-5"), "haiku 4.5")
        try checkEqual(RunningTasks.shortModel("claude-opus-5-5"), "opus 5.5")
        try checkEqual(RunningTasks.shortModel("gpt-5.5"), "gpt-5.5")
        try checkEqual(RunningTasks.shortModel("<synthetic>"), "<synthetic>")
    }

    test("RunningTasks a11yText：读屏文案") {
        try checkEqual(RunningTaskText.a11y(task(last: 1), now: now), "Claude，token-dashboard，已跑 12 分钟，opus 4.7，已写 2万 token")
        try checkEqual(RunningTaskText.a11y(task(last: 420), now: now), "Claude，token-dashboard，停了 7 分钟，opus 4.7，已写 2万 token")
        try checkEqual(RunningTaskText.a11y(task(.codexPlan, project: "demo-app", model: "gpt-5.5", last: 1, tokens: 950), now: now),
                       "Codex，demo-app，已跑 12 分钟，gpt-5.5，已写 950 token")
    }
}
