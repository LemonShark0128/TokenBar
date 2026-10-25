import Foundation

/// 界面状态判断（标题点、错误文案）在各种平台状态下的输出。
/// 期望值与搬到 Core 之前 App 里的判断一致：这是搬家，不改行为。
@MainActor
func registerStatusPresenterTests() {
    let now = Date(timeIntervalSince1970: 1_792_022_400)      // 上海时间 2026-10-15 08:00:00
    let tz = TimeZone(secondsFromGMT: 28800)!

    /// 按 StoreBridge 的方式从平台状态得到界面输入：有快照或采样才有数据
    func input(_ st: PlatformState, name: String = "DeepSeek") -> StatusPresenter.Input {
        let hasData = st.status != .notAdded && (st.snapshot != nil || st.lastSample != nil)
        let data = hasData ? AppDataMapping.appData(main: st, others: [], now: now, timeZone: tz) : nil
        return StatusPresenter.Input(state: st, data: data, error: StatusPresenter.error(for: st, name: name),
                                     now: now,
                                     providerName: name)
    }
    func state(_ status: PlatformStatus, snapshot: ProviderSnapshot? = nil, lastSample: Sample? = nil) -> PlatformState {
        PlatformState(id: .deepseek, snapshot: snapshot, burn: nil, status: status, lastSampleAt: lastSample?.t,
                      lastSample: lastSample)
    }
    func balanceOnly(_ at: Date) -> ProviderSnapshot {
        var s = snap(at); s.source = .balanceOnly; s.today = nil; s.month = nil; return s
    }

    test("presenterQuotaStaleFreshness") {
        for minutes in [3, 10, 15] {
            var snapshot = snap(now.addingTimeInterval(Double(-minutes * 60)))
            snapshot.quota = Quota(plan: nil, windows: [QuotaWindow(kind: .session, usedPercent: 100, resetsAt: nil, windowMinutes: nil)], observedAt: now)
            let st = PlatformState(id: .claudePlan, snapshot: snapshot, burn: nil, status: .stale(minutes: 1), errorDetail: "超时")
            let i = input(st, name: "Claude 套餐")
            try checkEqual(StatusPresenter.error(for: st, name: "Claude 套餐"), nil)
            let fresh = StatusPresenter.freshness(i)
            try checkEqual(fresh.0, minutes > 10 ? .offline : .stale)
            try checkEqual(fresh.1, "\(minutes) 分钟前 · 未更新")
        }
    }
    test("presenterNormal") {
        let i = input(state(.ok, snapshot: snap(now.addingTimeInterval(-30))))
        try checkEqual(i.error, nil)
        try check(StatusPresenter.freshness(i) == (.ok, "30 秒前"), "\(StatusPresenter.freshness(i))")
    }
    // 第四批第 6 条：飙升提醒只说「用量异常增加」，不猜测原因（不写「空转」「失控」之类）
    test("spikeCopyStatesIncreaseOnly") {
        let n = StatusPresenter.spikeNotification(provider: "DeepSeek", cnyPerHour: 4.8, avgCnyPerDayWeek: 5.5)
        try checkEqual(n.title, "DeepSeek 用量异常增加")
        try checkEqual(n.body, "近 1 小时 ¥4.80/时，是近 7 天平均的 21 倍。")
        for text in [n.title, n.body] {
            for word in ["空转", "失控", "看看", "可能", "怀疑"] { try check(!text.contains(word), "「\(text)」含「\(word)」") }
        }
    }
    test("presenterBalanceOnly") {
        let i = input(state(.ok, snapshot: balanceOnly(now.addingTimeInterval(-120))))
        try check(StatusPresenter.freshness(i) == (.ok, "2 分钟前"), "\(StatusPresenter.freshness(i))")
    }
    test("presenterConsoleExpired") {
        let i = input(state(.consoleLoginNeeded, snapshot: balanceOnly(now.addingTimeInterval(-30))))
        try checkEqual(i.error, nil)
        try check(StatusPresenter.freshness(i) == (.estimate, "控制台登录已失效"), "\(StatusPresenter.freshness(i))")
    }
    test("presenterKeyNotRecognized") {
        var s = balanceOnly(now.addingTimeInterval(-30)); s.consoleProblem = "认不出这把 API Key"
        let i = input(state(.ok, snapshot: s))
        try checkEqual(i.error, nil)
        try check(StatusPresenter.freshness(i) == (.ok, "30 秒前"), "\(StatusPresenter.freshness(i))")
    }
    test("presenterOfflineWithSample") {
        let sample = Sample(provider: .deepseek, t: now.addingTimeInterval(-1500), balance: 27, cumulativeCost: nil, currency: .cny)
        let i = input(state(.offline, lastSample: sample))
        try checkEqual(i.error, "连不上 DeepSeek，检查网络")
        try check(StatusPresenter.freshness(i) == (.stale, "离线 · 25 分钟前的余额"), "\(StatusPresenter.freshness(i))")
    }
    test("presenterOfflineWithoutSample") {
        let i = input(state(.offline))
        try checkEqual(i.error, "连不上 DeepSeek，检查网络")
        try check(StatusPresenter.freshness(i) == (.offline, "连不上 DeepSeek"), "\(StatusPresenter.freshness(i))")
    }
    test("presenterOfflineDiskSnapshot") {
        var st = state(.offline, snapshot: snap(now.addingTimeInterval(-1500)))
        st.snapshotFromDisk = true
        let i = input(st)
        try check(StatusPresenter.freshness(i) == (.stale, "离线 · 25 分钟前"), "\(StatusPresenter.freshness(i))")
    }
    test("presenterNotAdded") {
        let i = input(state(.notAdded))
        try checkEqual(i.error, nil)
        try check(i.data == nil)
    }
    test("presenterRateLimited") {
        let i = input(state(.rateLimited(until: now.addingTimeInterval(240)), snapshot: snap(now.addingTimeInterval(-60))))
        try checkEqual(i.error, nil)
        try check(StatusPresenter.freshness(i) == (.stale, "请求太频繁，稍后重试"), "\(StatusPresenter.freshness(i))")
    }
    test("presenterLoading") {
        let i = input(state(.loading))
        try checkEqual(i.error, nil)
        try check(StatusPresenter.freshness(i) == (.stale, "正在连接 DeepSeek…"), "\(StatusPresenter.freshness(i))")
    }
    test("presenterCredentialInvalid") {
        let i = input(state(.credentialInvalid))
        try checkEqual(i.error, "DeepSeek 登录失效，请在设置里重新登录")
        try check(StatusPresenter.freshness(i) == (.offline, "需要重新登录"), "\(StatusPresenter.freshness(i))")
    }
    test("presenterStaleData") {
        let i = input(state(.stale(minutes: 15), snapshot: snap(now.addingTimeInterval(-900))))
        try checkEqual(i.error, nil)
        try check(StatusPresenter.freshness(i) == (.stale, "15 分钟未更新"), "\(StatusPresenter.freshness(i))")
    }
    test("presenterUsesProviderName") {
        let off = input(state(.offline), name: "硅基流动")
        try checkEqual(StatusPresenter.errorText(.offline, name: "硅基流动"), "连不上 硅基流动，检查网络")
        try checkEqual(off.error, "连不上 硅基流动，检查网络")
        try check(StatusPresenter.freshness(off) == (.offline, "连不上 硅基流动"), "\(StatusPresenter.freshness(off))")
        try checkEqual(StatusPresenter.errorText(.credentialInvalid, name: "Claude"), "Claude 登录失效，请在设置里重新登录")
        try checkEqual(StatusPresenter.errorText(.schemaChanged, name: "OpenAI"), "OpenAI 接口有变化，暂时取不到数据")
        let loading = input(state(.loading), name: "硅基流动")
        try check(StatusPresenter.freshness(loading) == (.stale, "正在连接 硅基流动…"), "\(StatusPresenter.freshness(loading))")
        try checkEqual(StatusPresenter.error(for: state(.ok), name: "硅基流动"), "正在连接 硅基流动…")
        _ = input(state(.consoleLoginNeeded, snapshot: balanceOnly(now.addingTimeInterval(-30))), name: "硅基流动")
    }
    test("providerRegistryNames") {
        try checkEqual(ProviderRegistry.displayName(.deepseek), "DeepSeek")
        try checkEqual(ProviderRegistry.displayName(.siliconflow), "硅基流动")
        try checkEqual(ProviderRegistry.displayName(.codexPlan), "Codex 套餐")
        try checkEqual(ProviderRegistry.displayName(.claudePlan), "Claude 套餐")
    }
    test("knownKeysCoverPhase2") {
        try checkEqual(KeychainCredentialStore.knownKeys, ["apiKey", "webToken", "adminKey", "subjectId", "webTokenExpiresAt"])
    }
}
