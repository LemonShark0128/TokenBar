import Foundation

// 用户 11/7 选 proposal-openrouter-balance 乙：OpenRouter 读不到账户余额、显示的是 Key 剩余上限时，
// 凡是给这个数起名字的地方都叫「Key 剩余额度」，不叫「余额」
@MainActor
func registerKeyLimitLabelTests() {
    let now = Date(timeIntervalSince1970: 1_792_072_800)
    let tz = TimeZone(secondsFromGMT: 28800)!
    let creds = Credentials(values: ["apiKey": "sk-or-v1-test"])
    let limitedKey = #"{"data":{"limit":100,"limit_remaining":74.5,"usage_daily":1.25,"usage_weekly":6.5,"usage_monthly":25.5}}"#
    let unlimitedKey = #"{"data":{"limit":null,"limit_remaining":null,"usage_daily":0.4,"usage_weekly":1,"usage_monthly":3}}"#
    let forbidden = #"{"error":{"code":403,"message":"Only management keys can perform this operation"}}"#

    testAsync("openRouterMarksKeyLimitBalance") {
        func fetch(_ key: String, _ credits: (Int, String)) async throws -> ProviderSnapshot {
            try await OpenRouterProvider(http: OpenRouterHTTPClient(key: (200, key), credits: credits)).fetch(creds, now: now, timeZone: tz).get()
        }
        try checkEqual(try await fetch(limitedKey, (403, forbidden)).balanceIsKeyLimit, true)
        // 账户余额比 Key 上限少：显示的是账户余额
        try checkEqual(try await fetch(limitedKey, (200, #"{"data":{"total_credits":10,"total_usage":8}}"#)).balanceIsKeyLimit, nil)
        // Key 上限比账户余额少：显示的是 Key 上限
        try checkEqual(try await fetch(limitedKey, (200, #"{"data":{"total_credits":500,"total_usage":8}}"#)).balanceIsKeyLimit, true)
        try checkEqual(try await fetch(unlimitedKey, (200, #"{"data":{"total_credits":10,"total_usage":8}}"#)).balanceIsKeyLimit, nil)
    }

    func state(keyLimit: Bool) -> PlatformState {
        var s = ProviderSnapshot(provider: .openrouter, balance: Money(amount: Decimal(string: "74.5")!, currency: .usd),
                                 today: Money(amount: 1, currency: .usd), month: Money(amount: 3, currency: .usd),
                                 byModel: [], trend7: [], source: .bill, fetchedAt: now, credential: .ok)
        s.balanceIsKeyLimit = keyLimit ? true : nil
        return PlatformState(id: .openrouter, snapshot: s, burn: nil, status: .ok, lastSampleAt: now)
    }

    test("keyLimitReadingText") {
        let r = AccountReading.from(snapshot: state(keyLimit: true).snapshot, meter: .money, now: now)
        try checkEqual(r?.text, "Key 剩余额度 $74.50")
        try checkEqual(AccountReading.from(snapshot: state(keyLimit: false).snapshot, meter: .money, now: now)?.text, "余额 $74.50")
        try checkEqual(SettingsLayout.alertBarFraction(r, fuelFull: 100, scale: "USD", usdToCny: 7), 0.745)
        // 管理页「已连接 · Key 剩余额度 $74.50」
        try checkEqual(OnboardingPlan.addedStatus(.openrouter, state: .ok, reading: r).text, "已连接 · Key 剩余额度 $74.50")
        try checkEqual(SettingsLayout.alertLineLabel(.openrouter, keyLimit: true), "Key 剩余额度低于")
        try checkEqual(SettingsLayout.alertLineLabel(.deepseek, keyLimit: false), "余额低于")
        try checkEqual(SettingsLayout.alertLineLabel(.codexPlan, keyLimit: false), L("set.alert.remainingBelow"))
    }

    test("keyLimitSideCardMenuAndA11y") {
        let d = AppDataMapping.appData(main: state(keyLimit: true), others: [], now: now, timeZone: tz)
        let side = try checkUnwrap(d.mainCardSide)
        try check(side.tankIsKeyLimit)
        try check(try JSONDecoder().decode(AppData.Side.self, from: JSONEncoder().encode(side)).tankIsKeyLimit)
        // 今天页卡片：大数字上面那行（底注放不下，会把大数字挤小）
        let card = TodayCards.build(d, running: [], now: now).first { $0.id == "openrouter" }
        try checkEqual(card?.stateLine, "Key 剩余额度")
        try checkEqual(card?.footnote, nil)
        var withRunway = d
        withRunway.mainCardSide?.runwayDays = 19; withRunway.mainCardSide?.avgCnyPerDayWeek = 1
        try checkEqual(TodayCards.build(withRunway, running: [], now: now).first { $0.id == "openrouter" }?.stateLine, "Key 额度 · 约 19 天")
        // 快用完：不是「建议充值」（充值没用，要调高 Key 上限）；窄处的短写也带「Key 额度」
        withRunway.mainCardSide?.runwayDays = 3
        let warn = TodayCards.build(withRunway, running: [], now: now).first { $0.id == "openrouter" }
        try checkEqual(warn?.stateLine, "Key 额度约 3 天用完")
        try checkEqual(warn?.stateLineShort, "Key 额度约 3 天用完")
        try check(warn?.stateWarn == true)
        let plain = AppDataMapping.appData(main: state(keyLimit: false), others: [], now: now, timeZone: tz)
        try checkEqual(TodayCards.build(plain, running: [], now: now).first { $0.id == "openrouter" }?.stateLine, nil)
        // 面板顶部横幅：辅助平台低于预警线
        var banner = AppDataMapping.appData(main: PlatformState(id: .deepseek, snapshot: nil, burn: nil, status: .ok, lastSampleAt: nil),
                                            others: [state(keyLimit: true)], now: now, timeZone: tz)
        AppDataMapping.applyRisks(&banner, main: .deepseek,
                                    risks: [PlatformRisk(id: .openrouter, kind: .belowThreshold, hours: 0, atRisk: true, severity: .danger)],
                                    now: now, timeZone: tz, currency: "CNY")
        try checkEqual(banner.banner?.text, "OpenRouter：Key 剩余额度低于预警线")
        // 自动切换提示：Key 剩余额度在减少不说「余额在减少」
        try checkEqual(UsageStore.switchNoticeKey(state(keyLimit: true).snapshot), "switch.noticePaygSpend")
        try checkEqual(UsageStore.switchNoticeKey(state(keyLimit: false).snapshot), "switch.noticePayg")
        var noBalance = state(keyLimit: false).snapshot; noBalance?.balance = nil
        try checkEqual(UsageStore.switchNoticeKey(noBalance), "switch.noticePaygSpend")
        try checkEqual(UsageStore.switchNoticeKey(nil), "switch.noticePayg")
        // 菜单栏悬停
        let tip = MenuBarCells.tooltip(MenuBarCells.cells(d, main: .openrouter, now: now), now: now)
        try check(tip.hasPrefix("OpenRouter Key 剩余额度 $74.50"), tip)
        // 读屏
        try check(A11yText.side(side).contains("Key 剩余额度 74.50 美元"), A11yText.side(side))
        try checkEqual(A11yText.gauge(provider: "OpenRouter", balanceCny: 74.5, runwayDays: nil, currency: .usd, keyLimit: true),
                       "OpenRouter Key 剩余额度 74.50 美元")
        // 低额度提醒
        let n = StatusPresenter.lowTankNotification(name: "OpenRouter", amount: 4, threshold: 5, currency: "USD", keyLimit: true)
        try checkEqual(n.title, "OpenRouter Key 剩余额度不足")
        try checkEqual(n.body, "Key 剩余额度 $4.00，已低于预警线 $5")
        L10n.lang = .en
        let en = (AccountReading.from(snapshot: state(keyLimit: true).snapshot, meter: .money, now: now)?.text,
                  StatusPresenter.lowTankNotification(name: "OpenRouter", amount: 4, threshold: 5, currency: "USD", keyLimit: true).title)
        L10n.lang = .zh
        try checkEqual(en.0, "Key limit left $74.50")
        try checkEqual(en.1, "OpenRouter key limit is low")
    }
}

func checkUnwrap<T>(_ v: T?, file: String = #file, line: Int = #line) throws -> T {
    guard let v else { throw TestFailure(description: "\((file as NSString).lastPathComponent):\(line) 值为 nil") }
    return v
}
