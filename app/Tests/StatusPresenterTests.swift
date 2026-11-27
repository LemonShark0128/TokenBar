import Foundation

/// 界面状态判断（标题点、错误文案）在各种平台状态下的输出。
/// 期望值与搬到 Core 之前 App 里的判断一致：这是搬家，不改行为。
@MainActor
func registerStatusPresenterTests() {
    test("presenterClaudeInvalidKeepsDetailedLoginReasonWithSnapshot") {
        let now = Date()
        var st = PlatformState(id: .claudePlan, snapshot: snap(now), burn: nil, status: .credentialInvalid)
        st.errorDetail = L("cli.suspectedLogin")
        try checkEqual(StatusPresenter.error(for: st, name: "Claude"), st.errorDetail)
        let input = StatusPresenter.Input(state: st, data: nil, error: st.errorDetail, now: now, providerName: "Claude")
        try checkEqual(StatusPresenter.freshness(input).0, .offline)
        try checkEqual(AccountState.of(st), .invalid)
    }

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
        // OpenRouter：美元；日均按本周 / 本月累计算，覆盖几天就写几天（审查后续）
        let usd = StatusPresenter.spikeNotification(provider: "OpenRouter", cnyPerHour: 0.5, avgCnyPerDayWeek: 1.2,
                                                    currency: "USD", avgDays: 15)
        try checkEqual(usd.body, "近 1 小时 $0.50/时，是近 15 天平均的 10 倍。")
        L10n.lang = .en
        let en = StatusPresenter.spikeNotification(provider: "OpenRouter", cnyPerHour: 0.5, avgCnyPerDayWeek: 1.2,
                                                   currency: "USD", avgDays: 15).body
        L10n.lang = .zh
        try checkEqual(en, "Last hour: $0.50/h, 10× the 15-day average.")
    }
    test("spikeFloorByCurrency") {
        // 时速门槛 ¥0.2 / $0.03（同一量级）：$0.05/时、平时日均 $0.2 的美元平台算突增，人民币口径不算
        let t = Date(timeIntervalSince1970: 1_792_072_800)
        let rows = (0..<7).map { i in
            Sample(provider: .openrouter, t: t.addingTimeInterval(Double(i - 6) * 600), balance: nil,
                   cumulativeCost: Decimal(i) * Decimal(string: "0.00833")!, currency: .usd)
        }
        func spike(_ c: Currency) -> Bool {
            BurnCalculator.stats(samples: rows, now: t, tankRemaining: 10, weekCostByDay: [],
                                 dailyAverage: DailyAverage(perDay: Decimal(string: "0.2")!, days: 15), currency: c).spike
        }
        try check(spike(.usd))
        try check(!spike(.cny))
        try checkEqual(BurnCalculator.spikeMinPerHour(.cny), Decimal(string: "0.2")!)
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
        let older = Sample(provider: .deepseek, t: now.addingTimeInterval(-3 * 3600), balance: 27, cumulativeCost: nil, currency: .cny)
        let j = input(state(.offline, lastSample: older))
        try check(StatusPresenter.freshness(j) == (.stale, "离线 · 3 小时前的余额"), "\(StatusPresenter.freshness(j))")
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
        var old = state(.offline, snapshot: snap(now.addingTimeInterval(-86400)))
        old.snapshotFromDisk = true
        try check(StatusPresenter.freshness(input(old)) == (.stale, "离线 · 1 天前"), "\(StatusPresenter.freshness(input(old)))")
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
        // 11/6 用户定 round7-scout 第 5 条乙：按平台凭据类型统一说法（DeepSeek / Kimi 只有 API Key，没有「登录」）
        let i = input(state(.credentialInvalid))
        try checkEqual(i.error, "DeepSeek 的 API Key 无效，请在设置里更换 API Key")
        try check(StatusPresenter.freshness(i) == (.offline, "API Key 无效"), "\(StatusPresenter.freshness(i))")
        var sf = state(.credentialInvalid); sf.id = .siliconflow
        let web = input(sf, name: "硅基流动")
        try checkEqual(web.error, "硅基流动登录已过期，请在设置里重新登录")
        try check(StatusPresenter.freshness(web) == (.offline, "登录已过期"), "\(StatusPresenter.freshness(web))")
    }
    // 11/6 用户定 proposal-keychain-error-ui 乙：读钥匙串失败不说「登录失效 / Key 无效」
    test("presenterKeychainUnreadable") {
        let denied = input(state(.keychainUnreadable(status: -128)))
        try checkEqual(denied.error, "TokenBar 没能读取 DeepSeek 的钥匙串（被拒绝），点面板顶部的「重试」再读一次")
        try check(StatusPresenter.freshness(denied) == (.offline, "读不到钥匙串"), "\(StatusPresenter.freshness(denied))")
        let locked = input(state(.keychainUnreadable(status: -25308)))
        try checkEqual(locked.error, "钥匙串已锁，解锁后自动恢复")
        try check(StatusPresenter.freshness(locked) == (.stale, "钥匙串已锁"), "\(StatusPresenter.freshness(locked))")
        try checkEqual(StatusPresenter.errorText(.keychainUnreadable(status: -25293), name: "Kimi"),
                       "TokenBar 没能读取 Kimi 的钥匙串（错误码 -25293），点面板顶部的「重试」再读一次")
        // 横幅：钥匙串是一整条（所有平台共用），合成一条；锁着时不给「重试」
        func st(_ id: ProviderID, _ s: PlatformStatus) -> PlatformState { PlatformState(id: id, snapshot: nil, burn: nil, status: s) }
        try checkEqual(StatusPresenter.keychainBanner([st(.deepseek, .keychainUnreadable(status: -128)), st(.kimi, .keychainUnreadable(status: -128)),
                                                       st(.claudePlan, .ok)]),
                       KeychainBanner(text: "TokenBar 没能读取 DeepSeek、Kimi 的钥匙串（被拒绝）", canRetry: true))
        try checkEqual(StatusPresenter.keychainBanner([st(.deepseek, .keychainUnreadable(status: -25308))]),
                       KeychainBanner(text: "钥匙串已锁，解锁后自动恢复", canRetry: false))
        try checkEqual(StatusPresenter.keychainBanner([st(.deepseek, .ok), st(.kimi, .credentialInvalid)]), nil)
        // 锁着和被拒绝混着：只列被拒绝的，给「重试」
        try checkEqual(StatusPresenter.keychainBanner([st(.deepseek, .keychainUnreadable(status: -25308)), st(.kimi, .keychainUnreadable(status: -128))]),
                       KeychainBanner(text: "TokenBar 没能读取 Kimi 的钥匙串（被拒绝）", canRetry: true))
        // 读不到钥匙串时设置页不显示（磁盘上的旧）读数
        try check(!SettingsLayout.showsReading(state: .keychainUnreadable, stale: false))
        // 侧栏 / 设置
        try checkEqual(AppDataMapping.statusText(st(.kimi, .keychainUnreadable(status: -128)), now: now), "读不到钥匙串")
        try check(AppDataMapping.isCredentialProblem("读不到钥匙串"))
        try checkEqual(AccountState.of(st(.kimi, .keychainUnreadable(status: -128))), .keychainUnreadable)
        try checkEqual(AccountState.keychainUnreadable.label(for: .kimi), "读不到钥匙串")
        try checkEqual(FailureKind.from(.keychainUnreadable(status: -128)), .needsUser)
    }
    test("presenterStaleData") {
        let i = input(state(.stale(minutes: 15), snapshot: snap(now.addingTimeInterval(-900))))
        try checkEqual(i.error, nil)
        try check(StatusPresenter.freshness(i) == (.stale, "15 分钟未更新"), "\(StatusPresenter.freshness(i))")
        // 超过 60 分钟写小时、超过 24 小时写天
        let hours = input(state(.stale(minutes: 130), snapshot: snap(now.addingTimeInterval(-7800))))
        try check(StatusPresenter.freshness(hours) == (.stale, "2 小时未更新"), "\(StatusPresenter.freshness(hours))")
        let days = input(state(.stale(minutes: 3000), snapshot: snap(now.addingTimeInterval(-180000))))
        try check(StatusPresenter.freshness(days) == (.stale, "2 天未更新"), "\(StatusPresenter.freshness(days))")
    }
    test("presenterUsesProviderName") {
        let off = input(state(.offline), name: "硅基流动")
        try checkEqual(StatusPresenter.errorText(.offline, name: "硅基流动"), "连不上 硅基流动，检查网络")
        try checkEqual(off.error, "连不上 硅基流动，检查网络")
        try check(StatusPresenter.freshness(off) == (.offline, "连不上 硅基流动"), "\(StatusPresenter.freshness(off))")
        try checkEqual(StatusPresenter.errorText(.credentialInvalid, name: "Kimi", id: .kimi), "Kimi 的 API Key 无效，请在设置里更换 API Key")
        try checkEqual(StatusPresenter.errorText(.credentialInvalid, name: "Claude"), "Claude 登录失效，请在设置里重新登录")   // 不知道平台时的兜底
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
