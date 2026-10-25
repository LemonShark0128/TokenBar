import Foundation

/// 第一次取数挂起到 release()，返回 first；之后每次返回 rest。记录每次用的凭据
final class GatedOnceProvider: UsageProvider, @unchecked Sendable {
    private(set) var used: [Credentials] = []
    private var gate: CheckedContinuation<Void, Never>?
    let first: Result<ProviderSnapshot, ProviderError>
    let rest: Result<ProviderSnapshot, ProviderError>
    init(first: Result<ProviderSnapshot, ProviderError>, rest: Result<ProviderSnapshot, ProviderError>) {
        self.first = first; self.rest = rest
    }
    var id: ProviderID { .deepseek }
    var displayName: String { "GatedOnce" }
    var capabilities: Capabilities { Capabilities(hasBalance: true, currency: .cny, minPollInterval: 60, dayBoundary: .local) }
    var loginSteps: [LoginStep] { [] }
    func validate(_ c: Credentials) async -> ValidationResult { .ok(summary: "") }
    func fetch(_ c: Credentials, now: Date, timeZone: TimeZone) async -> Result<ProviderSnapshot, ProviderError> {
        used.append(c)
        if used.count > 1 { return rest }
        await withCheckedContinuation { gate = $0 }
        return first
    }
    var waiting: Bool { gate != nil }
    func release() { gate?.resume(); gate = nil }
}

@MainActor
func waitUntil(_ cond: () -> Bool) async throws {
    for _ in 0..<1000 where !cond() { await Task.yield() }
    try check(cond(), "等待超时")
}

@MainActor
func registerFollowupFixTests() {
    // 整分支评审 I-5 后半：重新登录时旧凭据的取数还没回来，它的登录失效不能覆盖新凭据
    testAsync("staleCredentialAuthFailureDoesNotOverrideNewLogin") {
        let clock = FakeClock()
        let cs = RecordingCredentialStore(.found(Credentials(values: ["webToken": "old"])))
        let p = GatedOnceProvider(first: .failure(.auth("登录已失效")), rest: .success(snap(clock.now)))
        let store = try makeStore(p, clock: clock, cs: cs, defaults: freshDefaults())
        let running = Task { await store.refresh() }
        try await waitUntil { p.waiting }
        try await store.saveCredentials(["webToken": "new"], for: .deepseek)
        p.release()
        await running.value
        try checkEqual(store.platforms[0].status, .ok)
        // 旧结果作废，按新凭据马上补取一次
        try checkEqual(p.used.map { $0.values["webToken"] }, ["old", "new"])
        // 没被「停止自动刷新」：之后到点照常取
        clock.now = clock.now.addingTimeInterval(600)
        await store.tick()
        try checkEqual(p.used.count, 3)
    }
    // 旧凭据的成功结果同样作废（不能拿上一个账号的数据顶替）
    testAsync("staleCredentialSuccessIsDiscarded") {
        let clock = FakeClock()
        let cs = RecordingCredentialStore(.found(Credentials(values: ["webToken": "old"])))
        let p = GatedOnceProvider(first: .success(snap(clock.now, balance: 1)), rest: .success(snap(clock.now, balance: 2)))
        let store = try makeStore(p, clock: clock, cs: cs, defaults: freshDefaults())
        let running = Task { await store.refresh() }
        try await waitUntil { p.waiting }
        try await store.saveCredentials(["webToken": "new"], for: .deepseek)
        p.release()
        await running.value
        try checkEqual(store.platforms[0].snapshot?.balance?.amount, 2)
    }
    // 取数途中移除了账号：回来的结果不能把平台从「未添加」改回来
    testAsync("removedWhileFetchingStaysNotAdded") {
        let clock = FakeClock()
        let cs = RecordingCredentialStore(.found(someKey))
        let p = GatedOnceProvider(first: .failure(.auth("登录已失效")), rest: .success(snap(clock.now)))
        let store = try makeStore(p, clock: clock, cs: cs, defaults: freshDefaults())
        let running = Task { await store.refresh() }
        try await waitUntil { p.waiting }
        try await store.removeAccount(.deepseek)
        p.release()
        await running.value
        try checkEqual(store.platforms[0].status, .notAdded)
        try checkEqual(p.used.count, 1)
    }
}

@MainActor
func registerReloginNoteTests() {
    // 评审：设置里重新登录硅基流动失败时静默关窗 → 账号行下写明结果
    test("reloginNoteCopy") {
        let fail = ReloginNote.make(provider: .siliconflow, ok: false, message: "登录没有成功，请重新登录硅基流动")
        try checkEqual(fail, ReloginNote(text: "登录没有成功，请重新登录硅基流动", isError: true))
        let keychain = ReloginNote.make(provider: .siliconflow, ok: false, message: "存进钥匙串失败：x")
        try checkEqual(keychain, ReloginNote(text: "重新登录没有成功：存进钥匙串失败：x", isError: true))
        let ok = ReloginNote.make(provider: .siliconflow, ok: true, message: "已连接，余额 ¥9.98")
        try checkEqual(ok, ReloginNote(text: "已重新登录：已连接，余额 ¥9.98", isError: false))
        // DeepSeek 控制台登录成功时只有「已登录」
        try checkEqual(ReloginNote.make(provider: .deepseek, ok: true, message: "已登录"),
                       ReloginNote(text: "已重新登录", isError: false))
    }
}
