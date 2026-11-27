import Foundation

@MainActor
func registerRefreshPolicyTests() {
    test("quotaCadenceVisibilityResetAndFailurePriority") {
        try checkEqual(QuotaCadence.interval(visible: true, renewedPending: false, failure: nil, failuresInARow: 0), 60)
        try checkEqual(QuotaCadence.interval(visible: false, renewedPending: false, failure: nil, failuresInARow: 0), 300)
        try checkEqual(QuotaCadence.interval(visible: false, renewedPending: true, failure: nil, failuresInARow: 0), 60)
        try checkEqual((1...6).map { QuotaCadence.interval(visible: true, renewedPending: true, failure: .transient, failuresInARow: $0) }, [300, 600, 1200, 1800, 1800, 1800])
        try checkEqual(QuotaCadence.interval(visible: true, renewedPending: true, failure: .needsUser, failuresInARow: 1), 1800)
    }
    test("refreshPauseTransitionsAreIdempotent") {
        var state = RefreshPauseState()
        try check(!state.setPaused(false))
        try check(state.setPaused(true))
        try check(state.paused)
        try check(!state.setPaused(true))
        try check(state.setPaused(false))
        try check(!state.paused)
        try check(!state.setPaused(false))
    }
    test("quotaFailureStatusMapping") {
        try checkEqual(FailureKind.from(.credentialInvalid), .needsUser)
        try checkEqual(FailureKind.from(.consoleLoginNeeded), .needsUser)
        try checkEqual(FailureKind.from(.schemaChanged), .transient)
        try checkEqual(FailureKind.from(.offline), .transient)
        try checkEqual(FailureKind.from(.ok), nil)
    }
    test("runningCadenceBoundary") {
        let now = Date()
        try checkEqual(RunningScanCadence.interval(visible: true, lastTask: now, now: now), 2)
        try checkEqual(RunningScanCadence.interval(visible: false, lastTask: now.addingTimeInterval(-1800), now: now), nil)
        try checkEqual(RunningScanCadence.interval(visible: true, lastTask: now.addingTimeInterval(-1800), now: now), 10)
    }
    let payload = Data(#"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":8,"windowDurationMins":300,"resetsAt":1793545995},"secondary":{"usedPercent":1,"windowDurationMins":10080,"resetsAt":1794132795},"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"planType":"plus"},"rateLimitResetCredits":{"availableCount":0,"credits":[]}}"#.utf8)
    test("codexLiveRateLimitsParse") {
        let q = CodexAppServerUsage.parseRateLimits(payload)
        try checkEqual(q?.plan, "plus")
        try checkEqual(q?.windows.map(\.usedPercent), [8, 1])
        try checkEqual(q?.windows.map(\.kind), [.session, .weekly])
        try checkEqual(q?.windows.map(\.windowMinutes), [300, 10080])
        try checkEqual(q?.windows.first?.resetsAt, Date(timeIntervalSince1970: 1793545995))
        try checkEqual(q?.resetCredits?.available, 0)
        try checkEqual(CodexAppServerUsage.parseRateLimits(Data("{}".utf8)), nil)
    }
    testAsync("codexLivePreferredWithoutLogDirectoryAndNoThrottle") {
        let p = CodexPlanProvider(root: { URL(fileURLWithPath: "/nonexistent-tokenbar") }, liveUsage: { CodexAppServerUsage.parseRateLimits(payload) })
        let now = Date()
        for offset in [0.0, 60.0] {
            let s = try await p.fetch(Credentials(values: [:]), now: now.addingTimeInterval(offset), timeZone: .current).get()
            try checkEqual(s.quota?.plan, "plus")
            try checkEqual(s.quota?.observedAt, now.addingTimeInterval(offset))
        }
    }
}
