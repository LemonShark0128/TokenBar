import Foundation

/// Codex 重置次数随 account/rateLimits/read 一起返回，由 parseRateLimits 解析
private func codexCredits(_ credits: String) -> String {
    #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":10}},"rateLimitResetCredits":"# + credits + "}}"
}

@MainActor
func registerResetCreditsTests() {
    test("claudeResetCreditsAreIncludedInQuota") {
        let data = Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"usage","response":{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":20},"cedar_ember":{"grants":[{"resets_left":1,"ends_at":"2026-11-30T00:00:00Z"},{"resets_left":2,"ends_at":"2026-12-30T00:00:00Z"}]}}}}}"#.utf8)
        guard case .quota(let quota) = ClaudeCLIUsage.controlOutcome(line: data, now: Date()) else {
            throw TestFailure(description: "Expected ordinary quota")
        }
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(quota)) as! [String: Any]
        let resets = encoded["resetCredits"] as? [String: Any]
        try checkEqual(resets?["available"] as? Int, 3)
    }
    test("resetCreditsOldQuotaDecodesAndNewQuotaRoundTrips") {
        let old = Data(#"{"windows":[],"observedAt":0}"#.utf8)
        var q = try JSONDecoder().decode(Quota.self, from: old)
        try checkEqual(q.resetCredits, nil)
        q.resetCredits = ResetCredits(available: 2, expiresAt: Date(timeIntervalSince1970: 100))
        try checkEqual(try JSONDecoder().decode(Quota.self, from: JSONEncoder().encode(q)), q)
    }
    test("codexResetCreditsEarliestExpiry") {
        let line = codexCredits(#"{"availableCount":3,"credits":[{}, {"expiresAt":"2026-11-30T00:00:00Z"},{"expiresAt":100}]}"#)
        try checkEqual(CodexAppServerUsage.parseRateLimits(Data(line.utf8))?.resetCredits, ResetCredits(available: 3, expiresAt: Date(timeIntervalSince1970: 100)))
    }
    test("codexResetCreditsZeroAndMissingOptionalFields") {
        try checkEqual(CodexAppServerUsage.parseRateLimits(Data(codexCredits(#"{"availableCount":0}"#).utf8))?.resetCredits, ResetCredits(available: 0, expiresAt: nil))
        let line = codexCredits(#"{"availableCount":1,"credits":[{"expiresAt":"2026-11-30T00:00:00.000Z"}]}"#)
        try checkEqual(CodexAppServerUsage.parseRateLimits(Data(line.utf8))?.resetCredits?.expiresAt, ISO8601DateFormatter().date(from: "2026-11-30T00:00:00Z"))
    }
    test("codexResetCreditsRejectsInvalidResponse") {
        for text in ["oops", #"{"id":2,"error":{}}"#] {
            try checkEqual(CodexAppServerUsage.parseRateLimits(Data(text.utf8)), nil)
        }
        // 次数字段不对：额度照常解析，只是没有重置次数
        let q = CodexAppServerUsage.parseRateLimits(Data(codexCredits(#"{"availableCount":true}"#).utf8))
        try checkEqual(q?.windows.count, 1)
        try checkEqual(q?.resetCredits, nil)
    }
    test("claudeResetCreditsMalformedDoesNotBreakUsage") {
        for cedar in ["null", #"{"grants":"oops"}"#, #"{"grants":[{"resets_left":1},{"resets_left":"bad"}]}"#] {
            let data = Data((#"{"type":"control_response","response":{"subtype":"success","request_id":"usage","response":{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":20},"cedar_ember":"# + cedar + "}}}}").utf8)
            guard case .quota(let q) = ClaudeCLIUsage.controlOutcome(line: data, now: Date()) else { throw TestFailure(description: "Lost ordinary quota") }
            try checkEqual(q.windows.first?.usedPercent, 20)
            try checkEqual(q.resetCredits, nil)
        }
    }
    test("claudeResetCreditsArrayFallbackAndNestedGrants") {
        let grants: [[String: Any]] = [["resets_left": 1, "ends_at": 200], ["resets_left": 2, "ends_at": 100]]
        let expected = ResetCredits(available: 3, expiresAt: Date(timeIntervalSince1970: 100))
        try checkEqual(ClaudeCLIUsage.parseResetCredits(grants), expected)
        try checkEqual(ClaudeCLIUsage.parseResetCredits(["nested": ["grants": grants]]), expected)
        try checkEqual(ClaudeCLIUsage.parseResetCredits([["resets_left": 1, "ends_at": "bad"]]), nil)
    }
    test("resetCreditsMappingPositiveZeroAndAbsent") {
        let now = Date(timeIntervalSince1970: 100)
        for count: Int? in [nil, 0, 3] {
            var q = Quota(plan: "plus", windows: [QuotaWindow(kind: .session, usedPercent: 20, windowMinutes: 300)], observedAt: now)
            q.resetCredits = count.map { ResetCredits(available: $0, expiresAt: ISO8601DateFormatter().date(from: "2026-11-30T00:00:00Z")) }
            var state = PlatformState(id: .codexPlan, snapshot: nil, burn: nil, status: .ok, lastSampleAt: nil, lastSample: nil)
            state.snapshot = ProviderSnapshot(provider: .codexPlan, balance: nil, today: nil, month: nil, byModel: [], trend7: [], source: .quota, fetchedAt: now, credential: .ok, quota: q)
            let d = AppDataMapping.appData(main: state, others: [], now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
            let side = AppDataMapping.side(state, now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
            try checkEqual(d.quota?.resetCredits, count.map { $0 == 0 ? "手动重置已用完" : "可手动重置 3 次（11-30 到期）" })
            try checkEqual(side.resetCredits, count == 3 ? "可手动重置 3 次（11-30 到期）" : nil)
        }
    }
    test("resetCreditsEnglishCopy") {
        let before = L10n.lang
        defer { L10n.lang = before }
        L10n.lang = .en
        let credits = ResetCredits(available: 3, expiresAt: ISO8601DateFormatter().date(from: "2026-11-30T00:00:00Z"))
        try checkEqual(credits.text(timeZone: TimeZone(secondsFromGMT: 0)!), "3 manual resets left (expires 11-30)")
        try checkEqual(ResetCredits(available: 0, expiresAt: nil).text(timeZone: .current), "No manual resets left")
    }
    testAsync("codexProviderAttachesResetCreditsWithoutChangingLogQuota") {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tb-reset-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let day = root.appendingPathComponent("2026/11/01")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try Data(#"{"timestamp":"2026-11-01T00:00:00Z","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":8,"window_minutes":300}}}}"#.utf8).write(to: day.appendingPathComponent("fake.jsonl"))
        let provider = CodexPlanProvider(root: { root }, resetCredits: { ResetCredits(available: 2, expiresAt: nil) })
        let snapshot = try await provider.fetch(Credentials(values: [:]), now: Date(), timeZone: .current).get()
        try checkEqual(snapshot.quota?.resetCredits?.available, 2)
        try checkEqual(snapshot.quota?.windows.first?.usedPercent, 8)
    }
    test("codexResetCreditsEnvironmentAndCandidates") {
        try checkEqual(CodexAppServerUsage.childEnvironment(base: ["CODEX_HOME": "/original"], customCodexDir: nil)["CODEX_HOME"], "/original")
        try checkEqual(CodexAppServerUsage.childEnvironment(base: [:], customCodexDir: "/custom")["CODEX_HOME"], "/custom")
        try check(CodexAppServerUsage.candidates(home: URL(fileURLWithPath: "/fake")).contains(URL(fileURLWithPath: "/fake/.local/bin/codex")))
    }


}
