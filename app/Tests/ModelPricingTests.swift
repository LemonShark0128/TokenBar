import Foundation

@MainActor
func registerModelPricingTests() {
    let tiers: [(String, Double, Double, Double, Double)] = [
        ("CLAUDE-FABLE", 10, 1, 12.5, 50), ("claude-opus-4-7", 5, 0.5, 6.25, 25),
        ("sonnet", 3, 0.3, 3.75, 15), ("haiku", 1, 0.1, 1.25, 5),
        ("gpt-5.5-codex", 5, 0.5, 5, 30), ("gpt-5.2", 1.75, 0.175, 1.75, 14),
        ("gpt-5.3", 1.75, 0.175, 1.75, 14), ("gpt-5.4", 1.75, 0.175, 1.75, 14),
        ("gpt-5", 1.25, 0.125, 1.25, 10), ("gpt-5.1", 1.25, 0.125, 1.25, 10),
        ("gpt-5-codex", 1.25, 0.125, 1.25, 10), ("gpt-5.1-codex", 1.25, 0.125, 1.25, 10),
        ("gpt-6-astra", 5, 0.5, 5, 30), ("gpt-5.6", 5, 0.5, 5, 30)
    ]
    for (model, input, cached, write, output) in tiers {
        test("pricing tier \(model)") {
            let p = ModelPricing.price(model: model)!
            try check(abs(p.input - input) < 1e-10 && abs(p.cachedInput - cached) < 1e-10)
            try checkEqual(p.cacheWrite, write)
            try checkEqual(p.output, output)
        }
    }
    test("pricing unknown sum and USD") {
        let t = TokenBreakdown(input: 1000, cachedInput: 2000, cacheWrite: 3000, output: 4000)
        try checkEqual(t + t, TokenBreakdown(input: 2000, cachedInput: 4000, cacheWrite: 6000, output: 8000))
        try checkEqual(ModelPricing.price(model: "unknown"), nil)
        try checkEqual(ModelPricing.usd(t, model: "unknown"), nil)
        try check(abs(ModelPricing.usd(t, model: "opus")! - 0.12475) < 1e-10)
    }
    test("pricing Codex reasoning included separate and reset") {
        func total(_ value: Int) throws -> CodexTokenUsage {
            try JSONDecoder().decode(CodexTokenUsage.self, from: Data("{\"input_tokens\":100,\"cached_input_tokens\":40,\"output_tokens\":20,\"reasoning_output_tokens\":5,\"total_tokens\":\(value)}".utf8))
        }
        try checkEqual(try total(120).delta(from: .init()), TokenBreakdown(input: 60, cachedInput: 40, output: 20))
        try checkEqual(try total(125).delta(from: .init()).output, 25)
        try checkEqual(try total(120).delta(from: total(120)), TokenBreakdown())
        try checkEqual(try total(120).delta(from: total(125)).output, 20)
    }
    test("pricing AppData old JSON and round trip") {
        let st = PlatformState(id: .claudePlan, status: .ok)
        var d = AppDataMapping.appData(main: st, others: [], now: Date(), timeZone: .current)
        let old = try JSONEncoder().encode(d)
        try checkEqual(try JSONDecoder().decode(AppData.self, from: old).apiValue, nil)
        d.apiValue = ApiValue(todayUSD: 1, weekUSD: 2, perProvider: ["claudePlan": 1], partial: true)
        try checkEqual(try JSONDecoder().decode(AppData.self, from: JSONEncoder().encode(d)).apiValue, d.apiValue)
    }
    test("pricing absent removed and local calendar window") {
        let now = ISO8601DateFormatter().date(from: "2026-11-01T01:00:00Z")!
        let tz = TimeZone(secondsFromGMT: -8 * 3600)!
        let breakdowns: [ProviderID: DailyModelBreakdown] = [.claudePlan: [
            "2026-10-31": ["opus": TokenBreakdown(input: 1_000_000)],
            "2026-10-25": ["haiku": TokenBreakdown(input: 1_000_000)],
            "2026-10-24": ["unknown": TokenBreakdown(input: 1_000_000)],
            "2026-11-01": ["unknown": TokenBreakdown(input: 1_000_000)]
        ]]
        let value = LocalAgentUsage.apiValues(breakdowns, now: now, timeZone: tz)[.claudePlan]!
        try checkEqual(value, LocalAgentUsage.ProviderApiValue(todayUSD: 5, weekUSD: 6, partial: false))
        let removed = PlatformState(id: .claudePlan, status: .notAdded)
        try checkEqual(AppDataMapping.appData(main: removed, others: [], now: now, timeZone: tz, localBreakdowns: breakdowns).apiValue, nil)
        try checkEqual(LocalAgentUsage.apiValues([.claudePlan: [:], .codexPlan: [:]], now: now, timeZone: tz), [:])
    }
    test("pricing task English accessibility and cent boundary") {
        let old = L10n.lang
        L10n.lang = .en
        defer { L10n.lang = old }
        let now = Date()
        var t = RunningTask(provider: .codexPlan, sessionKey: "test", project: "demo", model: "gpt-5",
                            startedAt: now, lastActivity: now, tokens: 1000,
                            usage: TokenBreakdown(output: 1000), rawModel: "gpt-5")
        try check(RunningTaskText.detail(t).hasSuffix(" · ≈$0.01"))
        try check(RunningTaskText.a11y(t, now: now).hasSuffix(", about $0.01 at API prices"))
        t.usage.output = 999
        try check(RunningTaskText.detail(t).hasSuffix(" · <$0.01"))
        try check(RunningTaskText.a11y(t, now: now).hasSuffix(", less than $0.01 at API prices"))
    }
    test("pricing local breakdown mapping cache and unknown") {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tb-pricing space \(UUID())")
        defer { try? fm.removeItem(at: root) }
        let claude = root.appendingPathComponent("claude dir")
        let codex = root.appendingPathComponent("codex dir")
        let now = ISO8601DateFormatter().date(from: "2026-11-01T12:00:00Z")!
        let tz = TimeZone(secondsFromGMT: 0)!
        func write(_ path: URL, _ lines: [String]) throws {
            try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(lines.joined(separator: "\n").utf8).write(to: path)
            try fm.setAttributes([.modificationDate: now], ofItemAtPath: path.path)
        }
        let reply = #"{"type":"assistant","timestamp":"2026-11-01T11:59:00Z","message":{"id":"a","model":"claude-opus","usage":{"input_tokens":1000,"cache_read_input_tokens":2000,"cache_creation_input_tokens":3000,"output_tokens":4000}}}"#
        try write(claude.appendingPathComponent("projects/demo/a.jsonl"), [
            #"{"type":"user","timestamp":"2026-11-01T11:58:00Z","message":{"content":"test"}}"#, reply, reply])
        try write(codex.appendingPathComponent("2026/11/01/a.jsonl"), [
            #"{"type":"turn_context","payload":{"model":"gpt-5.5"}}"#,
            #"{"type":"event_msg","timestamp":"2026-10-31T12:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":120}}}}"#,
            #"{"type":"event_msg","timestamp":"2026-11-01T11:58:00Z","payload":{"type":"task_started"}}"#,
            #"{"type":"event_msg","timestamp":"2026-11-01T11:59:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1100,"cached_input_tokens":440,"output_tokens":220,"reasoning_output_tokens":55,"total_tokens":1320}}}}"#])
        let cache = LocalUsageCache()
        func read() -> LocalAgentUsage.DetailedUsage {
            LocalAgentUsage.readDetailed(enabled: [.claudePlan, .codexPlan], claudeDir: claude, codexSessions: codex, now: now, timeZone: tz, cache: cache)
        }
        let r = read()
        try checkEqual(read(), r)
        try checkEqual(cache.parsedFileCount, 2)
        try checkEqual(r.tokens[.claudePlan]?["2026-11-01"]?["claude-opus"], 10000)
        try checkEqual(r.breakdowns[.codexPlan]?["2026-11-01"]?["gpt-5.5"], TokenBreakdown(input: 600, cachedInput: 400, output: 200))
        let values = LocalAgentUsage.apiValues(r.breakdowns, now: now, timeZone: tz)
        try check(abs(values[.codexPlan]!.todayUSD - 0.0092) < 1e-10)
        try check(abs(values[.codexPlan]!.weekUSD - 0.01012) < 1e-10)
        let st = PlatformState(id: .claudePlan, status: .ok)
        let d = AppDataMapping.appData(main: st, others: [], now: now, timeZone: tz, localUsage: r.tokens, localBreakdowns: r.breakdowns)
        try check(abs(d.apiValue!.todayUSD - 0.12475) < 1e-10)
        try checkEqual(d.apiValue!.partial, false)
        let unknown = LocalAgentUsage.apiValues([.claudePlan: ["2026-11-01": ["unknown": TokenBreakdown(input: 10)]]], now: now, timeZone: tz)
        try checkEqual(unknown[.claudePlan]?.partial, true)
        try checkEqual(unknown[.claudePlan]?.todayUSD, 0)
        let runningCache = RunningTasksCache()
        let tasks = RunningTasks.scan(enabled: [.claudePlan, .codexPlan], claudeDir: claude, codexSessions: codex, now: now, cache: runningCache)
        try checkEqual(tasks.count, 2)
        try checkEqual(RunningTasks.scan(enabled: [.claudePlan, .codexPlan], claudeDir: claude, codexSessions: codex, now: now, cache: runningCache), tasks)
        for t in tasks {
            let expected = t.provider == .claudePlan ? 0.12475 : 0.0092
            try check(abs(t.costUSD! - expected) < 1e-10)
            try check(RunningTaskText.detail(t).contains(t.provider == .claudePlan ? "≈$0.12" : "<$0.01"))
            try check(RunningTaskText.a11y(t, now: now).contains("估算花费"))
            var unknownTask = t; unknownTask.rawModel = "unknown"
            try check(!RunningTaskText.detail(unknownTask).contains("$"))
        }
    }
}
