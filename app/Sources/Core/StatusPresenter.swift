import Foundation

/// 数据健康（标题栏那颗点）的级别
enum FreshnessLevel: Equatable { case ok, stale, estimate, offline }

/// 界面状态判断：输入平台状态、显示数据和设置，输出文案和级别。都是纯函数，App 只负责显示
enum StatusPresenter {
    struct Input {
        /// 主平台状态（离屏预览没有 store 时为 nil）
        var state: PlatformState?
        var data: AppData?
        var error: String?
        var now: Date
        /// 主平台的显示名（来自 ProviderRegistry）
        var providerName: String
    }

    /// 「花费飙升时提醒」开关存在 UserDefaults 的键（没存过 = 关）
    static let spikeAlertsKey = "spikeAlertsOn"

    /// 取不到数据时的标题：按量付费平台是「连不上 DeepSeek」；套餐平台读的是本机文件，不联网，写「读不到本机 Codex 记录」
    static func offlineTitle(_ id: ProviderID) -> String {
        switch id {
        case .codexPlan: return L("status.offlineCodex")
        case .claudePlan: return L("status.offlineClaude")
        case .geminiPlan: return L("status.offlineGemini")
        default: return L("status.cantReach", ProviderRegistry.displayName(id))
        }
    }

    /// 只有真的需要用户处理的状态才算错误（只显示余额、数据稍旧都不算）。
    /// id 给了且是套餐平台时，离线写「读不到本机 … 记录」而不是「连不上 …，检查网络」
    static func errorText(_ s: PlatformStatus, name: String, id: ProviderID? = nil) -> String? {
        switch s {
        case .credentialInvalid:
            switch id.map(ProviderRegistry.credentialKind) {
            case .apiKey?: return L("status.keyInvalid", name)
            case .accessToken?: return L("status.tokenInvalid", name)
            case .webLogin?: return L("status.webLoginExpired", name)
            default: return L("status.loginExpired", name)
            }
        case .schemaChanged: return L("status.schemaChanged", name)
        case .keychainUnreadable(let code):
            return code == lockedKeychain ? L("kc.locked") : L("kc.unreadable", name, keychainReason(code))
        case .offline:
            if let id, ProviderRegistry.meter(id) == .quota { return offlineTitle(id) }
            return L("status.cantReachCheckNetwork", name)
        default: return nil
        }
    }

    /// 钥匙串锁着（errSecInteractionNotAllowed）：下一轮自动再读，不给「重试」
    static let lockedKeychain: Int32 = -25308

    /// 读钥匙串失败的原因：被拒绝写「被拒绝」，其余写错误码
    static func keychainReason(_ code: Int32) -> String {
        code == -128 ? L("kc.denied") : L("kc.code", Int(code))
    }

    /// 面板横幅：钥匙串是一整条、所有平台共用，读不到时合成一条；都只是锁着时不给「重试」。没有为 nil
    static func keychainBanner(_ platforms: [PlatformState]) -> KeychainBanner? {
        let failed = platforms.compactMap { st -> (ProviderID, Int32)? in
            if case .keychainUnreadable(let code) = st.status { return (st.id, code) }
            return nil
        }
        guard !failed.isEmpty else { return nil }
        let blocked = failed.filter { $0.1 != lockedKeychain }
        guard let first = blocked.first else { return KeychainBanner(text: L("kc.locked"), canRetry: false) }
        let names = blocked.map { ProviderRegistry.displayName($0.0) }.joined(separator: L("kc.nameSep"))
        return KeychainBanner(text: L("kc.banner", names, keychainReason(first.1)), canRetry: true)
    }

    /// 界面上的错误文案：还没添加、第一次取数还没回来都不算错误
    static func error(for st: PlatformState, name: String) -> String? {
        if case .stale = st.status { return nil }
        if let detail = st.errorDetail { return detail }
        if !st.status.isShown || st.status == .loading { return nil }
        if st.snapshot != nil || st.lastSample != nil { return errorText(st.status, name: name, id: st.id) }
        return errorText(st.status, name: name, id: st.id) ?? L("status.connecting", name)
    }

    /// 数据健康：账单退回估算、数据太久没更新、采集服务连不上，都要让人一眼看到
    static func freshness(_ i: Input) -> (FreshnessLevel, String) {
        if let st = i.state {
            switch st.status {
            case .stale(let minutes) where ProviderRegistry.meter(st.id) == .quota:
                let mins = st.quotaAge(now: i.now).map { Int($0 / 60) } ?? minutes
                return (st.quotaTooOld(now: i.now) ? .offline : .stale, L("status.agoNotUpdated", QuotaText.ago(minutes: mins)))
            case .loading: return (.stale, L("status.connecting", i.providerName))
            case .credentialInvalid:
                switch ProviderRegistry.credentialKind(st.id) {
                case .apiKey: return (.offline, L("status.keyInvalidShort"))
                case .accessToken: return (.offline, L("status.tokenInvalidShort"))
                case .webLogin: return (.offline, L("status.loginExpiredShort"))
                case .none: return (.offline, L("status.needsRelogin"))
                }
            case .schemaChanged: return (.offline, L("status.apiChanged"))
            case .keychainUnreadable(let code):
                return code == lockedKeychain ? (.stale, L("kc.lockedShort")) : (.offline, L("kc.unreadableShort"))
            case .consoleLoginNeeded: return (.estimate, L("status.consoleLoginExpired"))
            case .rateLimited: return (.stale, L("status.rateLimited"))
            case .offline where st.snapshotFromDisk && st.snapshot != nil:
                // 冷启动断网：显示的是上次成功取到的完整数据，标明是多久以前的
                let mins = Int(i.now.timeIntervalSince(st.snapshot!.fetchedAt) / 60)
                return (.stale, L("status.offlineAgo", QuotaText.ago(minutes: mins)))
            case .offline where st.lastSample == nil:
                return (.offline, ProviderRegistry.meter(st.id) == .quota ? offlineTitle(st.id) : L("status.cantReach", i.providerName))
            case .offline:
                // 冷启动断网但有历史采样：显示的是那次的余额，标明是多久以前的
                let mins = Int(i.now.timeIntervalSince(st.lastSample!.t) / 60)
                return (.stale, L("status.offlineBalanceAgo", QuotaText.ago(minutes: mins)))
            default: break
            }
        }
        // 套餐平台：数据来自本机，只说最近一次使用，不报过时
        if let st = i.state, ProviderRegistry.meter(st.id) == .quota, st.status == .ok {
            if let q = st.snapshot?.quota { return (.ok, QuotaText.lastUsed(q.observedAt, now: i.now)) }
            return (.ok, i.data?.quota?.note ?? "")
        }
        guard i.error == nil, let d = i.data else {
            if let st = i.state, ProviderRegistry.meter(st.id) == .quota { return (.offline, offlineTitle(st.id)) }
            return (.offline, L("status.cantReach", i.providerName))
        }
        let age = max(0, d.balance.ageS ?? 0)     // 时钟回拨时不写负数
        if age > 600 { return (.stale, QuotaText.notUpdatedFor(minutes: age / 60)) }
        return (.ok, age < 60 ? L("status.secAgo", age) : L("status.minAgo", age / 60))
    }

    /// 低油量通知的文字（系统通知 / 浮动警示卡）：写明平台名
    /// keyLimit：金额是 API Key 的剩余花费上限（OpenRouter），写「Key 剩余额度不足」
    static func lowTankNotification(name: String, amount: Double, threshold: Double, currency: String?,
                                    keyLimit: Bool = false) -> (title: String, body: String) {
        let amt = fmtMoney(amount, currency), th = fmtMoney(threshold, currency, 0)
        if keyLimit { return (L("alert.keyLimit.title", name), L("alert.keyLimit.body", amt, th)) }
        return (L("alert.lowTank.title", name), L("alert.lowTank.body", amt, th))
    }

    /// 套餐低额度通知的文字
    static func quotaLowNotification(name: String, remaining: Double, threshold: Double) -> (title: String, body: String) {
        (L("alert.quotaLow.title", name), L("alert.quotaLow.body", String(format: "%.0f", remaining.rounded(.down)), String(format: "%.0f", threshold)))
    }

    /// 花费飙升的系统通知 / 提醒卡文案：只陈述用量增加了多少，不猜原因
    /// currency：平台币种（金额前的符号）；avgDays：日均覆盖的天数（平台只给周 / 月累计时，如 OpenRouter），nil = 近 7 天
    static func spikeNotification(provider: String, cnyPerHour: Double, avgCnyPerDayWeek: Double?,
                                  currency: String? = nil, avgDays: Int? = nil) -> (title: String, body: String) {
        let x = cnyPerHour * 24 / max(avgCnyPerDayWeek ?? 1, 0.01)
        let rate = fmtMoney(cnyPerHour, currency), times = String(format: "%.0f", x)
        let body = avgDays.map { L("alert.spike.bodyDays", rate, times, $0) } ?? L("alert.spike.body", rate, times)
        return (L("alert.spike.title", provider), body)
    }

    /// 「每小时花费超过」的系统通知 / 提醒卡：「DeepSeek 每小时花费超过 ¥2」「每小时 ¥4.80，预计可用时间：5 小时 36 分」
    static func hourlyNotification(name: String, perHour: Double, threshold: Double, currency: String?,
                                   runwayHours: Double?) -> (title: String, body: String) {
        let digits = threshold == threshold.rounded() ? 0 : 2
        let body = L("alert.hourly.body", fmtMoney(perHour, currency)) + (runwayHours.map { L("alert.hourly.runway", Runway.spanText(hours: $0)) } ?? "")
        return (L("alert.hourly.title", name, fmtMoney(threshold, currency, digits)), body)
    }

}

/// 面板顶部「读不到钥匙串」横幅（proposal-keychain-error-ui 乙）
struct KeychainBanner: Equatable {
    var text: String
    var canRetry: Bool
}
