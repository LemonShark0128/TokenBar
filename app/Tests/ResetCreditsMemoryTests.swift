import Foundation

@MainActor
func registerResetCreditsMemoryTests() {
    let now = Date(timeIntervalSince1970: 1_792_022_400)
    testAsync("resetCreditsMemoryStartsEmpty") {
        try checkEqual(await ResetCreditsMemory().recall(now: now), nil)
    }
    testAsync("resetCreditsMemoryWithoutExpiryLastsLessThan24Hours") {
        let memory = ResetCreditsMemory()
        await memory.remember(ResetCredits(available: 3, expiresAt: nil), at: now)
        try checkEqual(await memory.recall(now: now.addingTimeInterval(23 * 3600))?.available, 3)
        try checkEqual(await memory.recall(now: now.addingTimeInterval(24 * 3600)), nil)
        try checkEqual(await memory.recall(now: now.addingTimeInterval(25 * 3600)), nil)
    }
    testAsync("resetCreditsMemoryUsesExplicitExpiry") {
        let memory = ResetCreditsMemory()
        let credits = ResetCredits(available: 3, expiresAt: now.addingTimeInterval(3600))
        await memory.remember(credits, at: now)
        try checkEqual(await memory.recall(now: now.addingTimeInterval(3599)), credits)
        try checkEqual(await memory.recall(now: now.addingTimeInterval(3600)), nil)
        try checkEqual(await memory.recall(now: now.addingTimeInterval(3601)), nil)
        let later = ResetCredits(available: 2, expiresAt: now.addingTimeInterval(48 * 3600))
        await memory.remember(later, at: now)
        try checkEqual(await memory.recall(now: now.addingTimeInterval(25 * 3600)), later)
    }
    testAsync("resetCreditsMemoryZeroReplacesPositiveAndRefreshesAge") {
        let memory = ResetCreditsMemory()
        await memory.remember(ResetCredits(available: 3, expiresAt: nil), at: now)
        await memory.remember(ResetCredits(available: 0, expiresAt: nil), at: now.addingTimeInterval(23 * 3600))
        try checkEqual(await memory.recall(now: now.addingTimeInterval(25 * 3600))?.available, 0)
    }
    testAsync("codexMissingLiveCreditsUsesMemoryWithoutRefreshingAge") {
        let memory = ResetCreditsMemory()
        await memory.remember(ResetCredits(available: 3, expiresAt: nil), at: now)
        let provider = CodexPlanProvider(liveUsage: { Quota(plan: "plus", windows: [], observedAt: now) }, resetCreditsMemory: memory)
        let fresh = try await provider.fetch(Credentials(values: [:]), now: now.addingTimeInterval(23 * 3600), timeZone: .current).get()
        try checkEqual(fresh.quota?.resetCredits?.available, 3)
        let expired = try await provider.fetch(Credentials(values: [:]), now: now.addingTimeInterval(25 * 3600), timeZone: .current).get()
        try checkEqual(expired.quota?.resetCredits, nil)
    }
}
